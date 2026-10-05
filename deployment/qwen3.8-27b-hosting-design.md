# Design Brief — Hosting Qwen3.8-27B on AWS: high throughput, minimal TTFT/TPOT, cost-optimized

> Rev 2 (2026-10-04) — full verification pass. All prior [V]s resolved against primary sources:
> HF `config.json`/model card (Qwen3.8-27B & -FP8), AWS g7e launch blog + pricing feeds, vLLM
> SM120-NVFP4 issue tracker, AWS P5 price-cut blog.
> Deployment sequence (per decision): **Phase 1 = EKS + 1 GPU node + Karpenter scale-out.**
> **Phase 2 = llm-d / P/D disaggregation only after phase-1 SLO/cost data.** Bootstrap checklist
> in §5. Final decision table in §4.

## 0. The model — now exact (verified from config.json + model card)

`Qwen/Qwen3.8-27B` · `Qwen3_5ForConditionalGeneration` (VLM: native image+video; thinking mode
default w/ `reasoning_effort` xhigh/medium/low). Text config:

| Property | Value |
| --- | --- |
| Layers | **64**, layout `16 × (3 × Gated DeltaNet → 1 × Gated Attention)` → **48 GDN + 16 full-attn layers** (`full_attention_interval: 4`) |
| Gated attention | **24 Q / 4 KV heads (GQA-4), head_dim 256**, partial RoPE (0.25, dim 64) |
| GDN | 48 V heads + 16 QK heads, head_dim 128, conv kernel 4, **ssm dtype float32** |
| FFN / vocab | 17,408 / 248,320 (padded) |
| Context | **262,144 native**, 1M extensible (Qwen Cloud will host 1M) |
| **MTP** | **native, trained multi-step, 1-layer MTP head** (spec-decode ready) |
| Checkpoints | **Official FP8: `Qwen/Qwen3.8-27B-FP8`** (fine-grained FP8, block-128, "nearly identical" metrics); community NVFP4 W4A4 (~23.4 GB, Blackwell-only); BF16 (~54–56 GB [E]) |

**KV-cache math (the D4 claim, now exact):**
- Only the **16 gated-attention layers** carry KV: per token = 2 × 16 × 4 × 256 × bytes
  = **64 KiB/token @BF16 → 32 KiB/token @FP8-KV**. (Compare dense-32B GQA-8: 128 KiB/token —
  **half**, exactly as you suspected.)
- **But the GDN layers hold constant per-sequence state**: ≈ 48 layers × 48 V-heads × 128 × 128 ×
  4 B (fp32) ≈ **~142 MiB per sequence, independent of context** [E — confirm at load time from
  engine logs]. This is the hidden concurrency cost: at batch B, GDN state = B × 142 MiB *always
  resident*, while KV grows with context.
- Per-sequence totals [E]: @4k ≈ 128 (KV-FP8) + 142 ≈ **270 MiB**; @16k ≈ 512 + 142 ≈ **654 MiB**;
  @64k ≈ 2.0 + 0.14 ≈ **2.2 GiB**.

## 1. g7e — verified (the Blackwell wildcard, now a primary candidate)

[GA 2026-01-20; **us-east-1/us-east-2 only at launch**; EKS-optimized AL2023-NVIDIA AMI covers
g7e (verified in the accelerated-AMI matrix); Auto Mode supports it too.]

RTX PRO 6000 Blackwell Server Edition, **96 GB/GPU** (2× G6e memory, 1.85× BW); up to 8 GPUs
(768 GB); Emerald Rapids; up to 1600 Gbps EFA; GPUDirect **P2P** multi-GPU; GPUDirect RDMA w/
EFAv4 in UltraClusters; **up to 2.3× inference vs g6e**; "models up to 70B with FP8 on a single
GPU." Sizes/pricing (us-east-1, verified feeds):

| Size | GPUs | $/hr OD | Spot (low) | Notes |
| --- | --- | --- | --- | --- |
| g7e.2xlarge | 1×96 GB | **$3.36** | ~$1.92 | cheapest 96 GB Blackwell |
| g7e.4xlarge | 1×96 GB | **$4.00** | ~$1.81 | 16 vCPU/128 GiB — capacity tier pick |
| g7e.8xlarge | 1×96 GB | **$5.27** | ~$3.58 | 32 vCPU/256 GiB — NVFP4 tier pick |
| **g7e.12xlarge** | **2×192 GB** | $8.29 | ~$5.05 | **the TP=2 shape that exists** (P2P over PCIe) |
| g7e.24xlarge / .48xlarge | 4 / 8 | $16.57 / **$33.14** | ~$7.6 / ~$13.7 | oversized for this model |

vs H100: **p5.4xlarge = $6.88/hr for 1×80 GB** (P5 OD cut 44% in June 2025 — the old ~$98/8-GPU
figure is pre-cut; current AWS feed ≈ $55/hr for p5.48xlarge). So g7e.4xlarge gives **more VRAM
(96 vs 80 GB), newer arch (FP4 tensor cores + native MTP paths), 2.3×-vs-g6e inference, at 58% of
p5.4xlarge's price.**

**The SM120 caveat set (verified — this is why g7e isn't an instant win):** RTX PRO 6000 is
**SM120**, *not* SM100: no tcgen05/UMMA, 99 KB smem, SM80-era `mma.sync`. Practical consequences
in vLLM: (a) NVFP4 **dense** GEMM runs via **FlashInfer CUTLASS JIT** — requires CUDA 13.0 nvcc
matching torch + `FLASHINFER_CUDA_ARCH_LIST=12.0f`, else **silent Marlin fallback**; (b) NVFP4
**MoE** native kernels exist but are opt-in (`--moe-backend flashinfer_b12x`); (c) community
patch sets (lna-lab) fix FA/MoE/JIT paths for full speed. Qwen3.8-27B is **dense** (no MoE) ⇒ the
dense-JIT path is what matters; the W4A4 checkpoint (per-token activation scales) selects
`FlashInferCutlassNvFp4LinearKernel` on supported SM120 [V in lab]. Reference points: patched
RTX PRO 6000 runs Qwen3.5-27B-Dense NVFP4 ≈ **57 tok/s** single-stream [E context]; the GB10
NVFP4 card measured 23.65 tok/s decode w/ MTP n=3.

## 2. Decisions (rev 2)

- **D1 Weights → FP8 (official `Qwen3.8-27B-FP8`).** Native on SM89/SM90/SM120; ~28–31 GB [V
  safetensors sum]; zero-setup risk. NVFP4 W4A4 only on g7e (23.4 GB) — take it as tier C, after
  the SM120 JIT validation. Marlin-W4A16-FP4 on L40S/H100: **no**.
- **D2 KV → FP8.** Model ships calibrated FP8 KV scales (NVFP4 card explicitly; FP8 checkpoint
  family standard). Halves KV to 32 KiB/token. Quality gate: one retrieval eval (F2 lab).
- **D2b GDN state is the real concurrency tax:** budget B × 142 MiB fp32 [E]. On 48 GB this is
  why concurrency caps at ~16, not ~32 (earlier estimate corrected).
- **D3 Parallelism → 1 GPU/replica.** TP=2 exists only on g7e.12xlarge (PCIe P2P) — use only if
  a single 96 GB GPU provably can't hold your batch; TP=4/8 shapes are all oversized for 27B.
- **D4 Instance tiers (verified pricing):**
  - **Tier-1 cost floor: g6e.2xlarge (1×L40S 48 GB) $2.24/hr** (spot $0.5–2.2): FP8 weights
    ~30 GB → ~14 GB budget − GDN(16×142 MiB ≈ 2.2 GB) → **~16 seqs @4k, ~4–6 @16k** [E].
  - **Tier-2 capacity: g7e.4xlarge (1×96 GB Blackwell) $4.00/hr** (spot ~$1.81): FP8 → ~55 GB
    budget → **~64 seqs @4k, ~24 @16k** [E]; NVFP4 W4A4 → weights 23.4 GB → even more.
  - **Tier-3 NVFP4: g7e.8xlarge (1×96 GB) $5.27/hr** with the W4A4 checkpoint (after SM120 JIT
    validation) — biggest KV headroom + native FP4/MTP.
  - H100 (p5.4xlarge $6.88): the *de-risked* fallback (proven SM90 stack, no JIT caveats) — keep
    as alternative if g7e kernel pain bites.
  - Rejected: g6e.24xlarge (4×L40S, $15.07, PCIe), p5.48xlarge (8×H100, ~$55, oversized),
    p6-b200 (8×B200, oversized), p4de (no FP8).
- **D5 P/D disagg → Phase 2.** Single-GPU serving makes it structurally wrong at this size
  (needs ≥2 pods + NIXL KV transfer + role-aware routing). Flip conditions: prefill-share >~70%
  w/ hard TPOT SLO after `max_num_batched_tokens` tuning; ≥3 replicas; 64k+ RAG mix dominating
  TTFT p95.
- **D6 llm-d → Phase 2.** Phase 1 = raw vLLM Deployment + Service + HPA/KEDA on
  `vllm:num_requests_running` + Karpenter. Add llm-d at ≥3 replicas *and* heavy shared prefixes
  (prefix-aware routing pays — E4 math), or when D5 flips (llm-d PD mode).
- **D7 Checklist:** MTP spec-decode `{"method":"mtp","num_speculative_tokens":2}` (A/B at high
  concurrency — I3's "gains evaporate" chart); prefix caching ON (E4: shared prefixes → ~free
  TTFT); chunked prefill (V1 default) + **explicit `max_num_batched_tokens` 8192–16384** (2048 =
  test-default trap, E3); CUDA graphs default FULL_AND_PIECEWISE; `--gpu-memory-utilization
  0.92`; sleep mode + `VLLM_SERVER_DEV_MODE=1` for scale-to-zero; YaRN 1M only if a workload
  needs it; thinking-mode sampling defaults (temp 1.0 / top_p 0.95 / top_k 20) per model card;
  quality gates (FP8 vs BF16 eval, FP8-KV retrieval delta, MTP acceptance α).

## 3. Cost model (verified $ inputs; [E] throughput to be measured)

`$/1M out tokens ≈ $/hr ÷ (aggregate tok/s × 3600/1e6)`

| Tier | $/hr | Conc. @4k [E] | Agg tok/s [E] | $/1M out [E] |
| --- | --- | --- | --- | --- |
| g6e.2xlarge FP8 | 2.24 | ~16 | ~0.8–1.5k | **$0.41–0.78** |
| g7e.4xlarge FP8 (+MTP) | 4.00 | ~64 | ~3–6k | **$0.19–0.37** |
| g7e.8xlarge NVFP4 (+MTP) | 5.27 | ~96+ | ~4–8k | **$0.18–0.37** |
| Spot on any tier | ×0.3–0.6 | — | — | **÷2–3** |

Rev-2 correction: g7e's 2.3×-vs-g6e throughput *and* bigger VRAM mean the Blackwell tier projects
cheapest per token despite higher $/hr — **measure before committing** (LAB 14 rig).

## 4. FINAL DESIGNS TABLE

| # | Decision | Final | Rationale | Alternative (when) |
| --- | --- | --- | --- | --- |
| 1 | Checkpoint | `Qwen/Qwen3.8-27B-FP8` (official) | block-128 FP8, "nearly identical" metrics, KV-scale friendly | NVFP4 W4A4 (tier-3 g7e); BF16 (offline eval only) |
| 2 | Weights precision | FP8 block-128 | 2× vs BF16; native on all candidate GPUs | NVFP4 W4A4 on g7e after SM120-JIT validation; never Marlin-FP4 on L40S/H100 |
| 3 | KV precision | FP8 (32 KiB/token) | calibrated scales ship w/ model | BF16 KV (if retrieval eval regresses) |
| 4 | Parallelism | 1 GPU / replica (DP replicas) | no collectives; AWS shapes favor it; simplest autoscale | TP=2 on g7e.12xlarge ($8.29) if batch >1-GPU capacity; TP=8 H100 rejected |
| 5 | Phase-1 instance (dev/pilot) | **g6e.2xlarge** ($2.24) | cheapest GPU; FP8 fits; spot floors $0.5 | g6e.xlarge ($1.86) for tiny pilots |
| 6 | Phase-1 production tier | **g7e.4xlarge** ($4.00) — 96 GB Blackwell | 2.3× g6e perf, ~64 seqs @4k, FP4-ready | p5.4xlarge ($6.88) if SM120 kernel pain (proven SM90 stack) |
| 7 | NVFP4 tier | g7e.8xlarge ($5.27) + W4A4 | 23.4 GB weights → max KV + native FP4/MTP | hold until FlashInfer SM120 JIT validated in your image |
| 8 | P/D disaggregation | **No (Phase-2 gate)** | single-GPU; chunked prefill suffices | llm-d PD mode when ≥3 replicas + prefill-share >70% / 64k+ RAG mix |
| 9 | Serving stack | raw vLLM + Gateway/Service + HPA/KEDA | simplest, cheapest ops | llm-d (≥3 replicas + shared prefixes); KServe LLMISVC (multi-node future) |
| 10 | Spec decode | native MTP, n=2 | 1-layer MTP head; big TPOT win low-QPS | off at high concurrency (verify); ngram for code |
| 11 | Region | us-east-1 | g7e GA regions | us-west-2 (only g6e/p5 tiers) |
| 12 | Scaling economics | Karpenter GPU NodePool; HPA on `num_requests_running`; ODCR baseline + spot burst | 1-GPU replicas = horizontal scale | Capacity Blocks not needed at this size |

## 5. Fresh-AWS-account bootstrap checklist (Phase 1: 1-GPU vLLM on EKS, scaled by Karpenter)

**0. Account & quotas (day 0)**
- [ ] IAM admin user or SSO; IMDSv2 default; billing alarms + Cost Explorer.
- [ ] **Service-quota increases** in us-east-1: `g6e.2xlarge`, `g7e.4xlarge/8xlarge` (vCPU limits
  for G family); consider an ODCR for the always-on baseline (A9).

**1. Tooling**
- [ ] AWS CLI v2 (+SSO/login), `kubectl`, `eksctl` (current), Helm 3; pin Karpenter v1.14.x.

**2. VPC + EKS 1.36**
- [ ] `eksctl create cluster` (managed addons auto): VPC CNI, CoreDNS, kube-proxy, **EBS CSI**,
  **EKS Pod Identity Agent**; OIDC; add-ons with `autoApplyPodIdentityAssociations: true` (A1).
- [ ] Compute path: **Auto Mode (Path A — fastest pilot)** vs **Karpenter (Path B — the series
  recipe; required for phase-2 control)**. Pick one; Auto Mode + Karpenter mixing is fine later.

**3. Karpenter + GPU node pool (Path B)**
- [ ] Helm-install Karpenter (Pod Identity); `EC2NodeClass` `amiFamily: AL2023` with alias
  (accelerated AMI auto-selected) or SSM-pinned **Bottlerocket `aws-k8s-1.36-nvidia`** (A6).
- [ ] GPU `NodePool`: `eks.amazonaws.com/instance-family: [g7e|g6e]`, capacity-type mix
  (reserved baseline + on-demand), **taint `nvidia.com/gpu:NoSchedule`**, `do-not-disrupt`
  policies (A9). Placement groups only when multi-node EFA arrives (phase 2).

**4. AMI / host components**
- [ ] EKS-optimized accelerated **AL2023-NVIDIA AMI** (driver 580/CUDA 13 + toolkit preinstalled;
  `nodeadm` sets `nvidia.com/gpu.present=true` — A4/A7). No device plugin bundled → step 5.
- [ ] (Bottlerocket route: bundled plugin ON; remember the disable-knob if DRA later.)

**5. Device plumbing**
- [ ] **NVIDIA device plugin** helm with `gfd.enabled=true` (auto-installs NFD + GFD labels; A4)
  — keep **MOFED disabled** unless EFA (A5's ≥v0.19 trap).
- [ ] *(Optional, phase 2)* **DRA driver** v0.5.0 chart instead — requires disabling the plugin
  on those nodes (A3/A6); the 1-GPU phase doesn't need it.
- [ ] *(Phase 2 only)* EFA device plugin + self-referencing SG + placement group for multi-node.

**6. Observability**
- [ ] dcgm-exporter Helm (Prometheus path) **or** `amazon-cloudwatch-observability` add-on
  (manages DCGM + GPU/EFA metrics by default; B6's eight-metric dashboard).

**7. Model & images**
- [ ] ECR repo (or pull-through cache) for the vLLM image, **≥ the version pinned by the
  Qwen3.8 recipe** [V recipes.vllm.ai/Qwen/Qwen3.8-27B].
- [ ] Upload `Qwen3.8-27B-FP8` to S3; serve via `--load-format runai_streamer s3://…` (A10) or
  Mountpoint-S3 CSI; EBS scratch for warm weights; record "Loading weights took".

**8. Deploy vLLM (1 GPU)**
- [ ] Deployment: `nvidia.com/gpu: 1` + toleration; args per §2 D7 (`--kv-cache-dtype fp8`,
  `--speculative-config '{"method":"mtp","num_speculative_tokens":2}'`, `--max-num-batched-tokens
  8192`, `--max-num-seqs 64`, `--gpu-memory-utilization 0.92`, prefix caching explicit).
- [ ] Readiness probe (healthz + a 1-token completion), PDB, `karpenter.sh/do-not-disrupt`.
- [ ] Service + Ingress (Gateway API) with API-key auth; HPA/KEDA on `vllm:num_requests_running`;
  sleep-mode eval for dev/staging scale-to-zero.

**9. Validate & baseline (the D3 evidence gate)**
- [ ] `nvidia-smi` pod green; KV-usage + prefix-hit metrics live (B6 recipe); `vllm bench serve`
  sweeps at concurrency {8, 16, 32, 64}: TTFT p50/p95, TPOT p50/p99, aggregate tok/s → fill §3.
- [ ] Tier decision point: stay g6e vs move g7e (and FP8 vs NVFP4) **on measured numbers**.

**10. Scale & cost ops**
- [ ] Karpenter autoscaling on replica count; spot NodePool for burst (+PDBs); ODCR/Savings-Plan
  baseline; weekly $/1M-token report (K2/K4 rig).
- [ ] **Phase-2 review** (llm-d / P-D) once ≥3 replicas or a D5/D6 flip condition hits.

## 6. Residual [V] list (short — most claims now verified)

1. FP8 checkpoint safetensors size + vLLM pinned version from the recipe page [V].
2. GDN-state ~142 MiB/seq [E] — confirm from engine startup logs and refine §2/§3 concurrency
  numbers.
3. SM120 FlashInfer-JIT inside your chosen image (CUDA 13.0 nvcc + `FLASHINFER_CUDA_ARCH_LIST`)
  — only matters for tier-3 NVFP4 [V in lab].
4. MTP acceptance rate & high-concurrency penalty on your workload [V in lab].
