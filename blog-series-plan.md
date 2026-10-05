# Blog Series Plan: "LLM Inference on Kubernetes — from Silicon to Service"

> Working series title: **"Serving LLMs on EKS: a systems engineer's tour from NVIDIA silicon to vLLM to llm-d"**
>
> Format: ~16 articles in 6 phases. Companion doc: `research-and-doubt-map.md`
> (per-topic clarifications, verified facts with sources, and a research-question backlog).
>
> Status tags used below: **[K]** = you already know it (just structure it), **[L]** = to learn,
> **[V]** = verify before publishing (fast-moving area).
>
> Verified 2026-10-03: EKS 1.36 is the current GA version (2026-06-02); vLLM ≥ 0.17;
> Qwen3.5-0.8B supported since vLLM 0.17.

---

## 1. Series positioning

- **Audience:** platform/ML-infra engineers who can run pods, but who see "GPU + vLLM + EKS" as one
  opaque box. You take the box apart layer by layer.
- **Thesis of the whole series:** LLM inference is a *systems* problem, not a model problem.
  Every answer (throughput, TTFT, cost per 1M tokens) is determined by a stack of decisions:
  silicon → interconnect → driver/kernel modules → K8s device plumbing → vLLM internals →
  cluster scheduling → gateway/routing → disaggregation. Each article removes one layer of fog.
- **Series arc:** "follow one request" — a token's journey from a chat prompt, through the gateway,
  into vLLM, through CUDA and NVLink/EFA, and back out as a streamed token — retold with increasing
  depth in each phase.

### The running case study (reuse in every article)

Keep one consistent lab across all posts so readers (and you) can compare numbers between articles:

| Item | Primary choice | Budget fallback |
| --- | --- | --- |
| Cluster | **EKS 1.36** (GA 2026-06-02; DRA GA since 1.34), Karpenter | EKS Auto Mode for a hands-off start |
| GPU nodes | g6 (L4, no NVLink) → **g6e (L40S, no NVLink)** → **p5.48xlarge (H100, NVSwitch)** | p4de or spot-g6 if budget-limited |
| Models | **Qwen3.5-0.8B (default)** — hybrid GDN + gated attention, native MTP, 262k ctx; Llama-3.1-8B-Instruct (dense, classic GQA KV math); Qwen3-30B-A3B / Mixtral-8x7B (MoE, for EP); DeepSeek-R1-Distill (long-context/RAG) | Qwen2.5-3B / 7B for cheap dense loops |
| Precision ladder | BF16 → FP8 (weights + KV) → NVFP4 (Blackwell only) | INT8/AWQ on older GPUs |
| Load | `inference-perf` / `vllm bench serve`: chat-shaped ISL/OSL, concurrency sweep 1→512 | locust for smoke tests |
| SLO targets | chat: TTFT < 2s, TPOT < 50ms | report what you measure |

**Qwen3.5-0.8B, verified and load-bearing for the series:** supported in vLLM since v0.17.0
(support merged Feb 2026; GA in the Mar-2026 release with FlashAttention-4). It is a *hybrid*
architecture — 24 layers arranged as `6 × (3 × Gated DeltaNet → 1 × Gated Attention)` — so 18 of
24 layers are linear attention with constant-size state (no per-token KV growth), and only 6 layers
carry classic GQA KV cache (8 Q / 2 KV heads, head-dim 256). Bonus teaching assets: **native MTP
heads** (speculative-decoding labs run on the same default model), 248,320 padded vocab with tied
embeddings, 262k native context. Use Llama-3.1-8B as the textbook dense-GQA KV-math model and
Qwen3.5-0.8B as the hybrid-architecture counterexample.

**Why the g6e → p5 progression is a gift, not a compromise:** L40S has **no NVLink**, which makes it
the perfect foil for article 4 (you will *feel* why TP hurts without NVLink and PP wins) and article 5.
The L40S-vs-H100 contrast is a whole article's worth of evidence by itself. [V]

---

## 2. Self-test ritual (the "blog as an exam" method)

Your stated motive is testing yourself. Bake this ritual into *every* article; it is the series'
signature:

1. **Predict before measuring.** Before each lab, write down a numeric estimate (Fermi-style),
   e.g. "KV cache for Llama-3.1-8B @ 4k tokens ≈ 0.5 GiB" or "TP=2 over PCIe will cost ≥30% vs NVLink".
2. **Measure.** Run the reproducible benchmark harness.
3. **Reconcile.** Publish the delta between estimate and measurement, and explain the gap.
   Gaps are the best content — they're exactly where your understanding was wrong.
4. **Explain to a novice.** End every article with a 5-line "explain it at dinner" version.
5. **Publish the artifacts.** Manifests, scripts, raw CSVs, and a Grafana screenshot per article.

One repo mirrors the series: `labs/NN-article-slug/` per article, each with
`README.md`, `k8s/` manifests, `bench/` scripts + results, `notes.md` (your estimate vs measured).

---

## 3. Master topic inventory (the complete list)

This is the flat list you asked for. Grouped into 12 clusters, each tagged with the article that
owns it, plus your knowledge status.

### Cluster A — EKS & cluster plumbing (articles 01–02)
- [K→L] EKS 1.36 (GA 2026-06-02; 1.34–1.36 in standard support) control plane; addons stack: VPC CNI, CoreDNS, kube-proxy, EBS CSI, EFS CSI,
  Mountpoint-for-S3 CSI (weight loading), Karpenter
- [L] EKS Auto Mode vs self-managed: what Auto Mode manages for GPUs (drivers + device plugin,
  invisible as a DaemonSet); when to NOT use it
- [L] NVIDIA device plugin (extended resource `nvidia.com/gpu`) vs **DRA (Dynamic Resource
  Allocation, GA in K8s 1.34)**: ResourceSlice/DeviceClass/ResourceClaim, rich device attributes,
  dynamic MIG/MPS/time-slicing, ComputeDomains for multi-node NVLink [V]
- [L] GPU feature discovery / NFD labels; topology-aware GPU scheduling
- [L] EFA device plugin (`vpc.amazonaws.com/efa`), efa-only vs EFA-with-ENA interfaces [V]
- [K] Bottlerocket NVIDIA AMI family (`aws-k8s-nvidia`): preinstalled driver, container toolkit,
  fabric manager, persistenced, MIG manager, NVLink subnet manager, IMEX; built-in device plugin and
  how to disable it for DRA [V]
- [L] EKS-optimized accelerated AMI (AL2023 x86_64 NVIDIA / ARM NVIDIA) vs Bottlerocket decision table
- [L] Gang scheduling (Kueue / Volcano / KAI) for multi-pod GPU jobs
- [L] Node pools & taints (`nvidia.com/gpu` taint + toleration), placement groups for p5/p6 [V]
- [L] Model storage & weight-loading time as a first-class cost (S3 → NVMe warm pool, sleep mode)

### Cluster B — GPU silicon & topology (article 03)
- [K] NVLink 4/5, NVSwitch, NVLink domain vs PCIe Gen5 (per-direction ~64 GB/s)
- [K] Bandwidth hierarchy table: HBM3e (~26.8 TB/s on H100 SXM... [V] per-GPU figure) ≫ NVLink
  (900 GB/s bidir H100 / 1.8 TB/s B200) ≫ NVSwitch bisection (3.6 TB/s p5) ≫ PCIe ≫ EFA (per-port)
  ≫ ENA ≫ EBS
- [L] Reading `nvidia-smi topo -m`, `nvidia-smi nvlink`, fabric manager logs
- [L] Instance anatomy: p5.48xlarge (8×H100, 900 GB/s NVSwitch interconnect, 3.2 Tbps EFA aggregate,
  GPUDirect RDMA, 8×3.84 TB NVMe, 192 vCPU, 2 TiB) vs p5e/p5en (H200) vs p6-b200/p6e-gb200 [V]
- [L] MIG (partition), time-slicing, MPS — inference use cases and pitfalls
- [L] DCGM: what health/metrics it exposes (used again in article 14)

### Cluster C — AWS network fabric (article 04)
- [K→L] **ENA vs EFA vs EFA-only** (not InfiniBand!): ENA = VPC IP networking; EFA = ENA + OS-bypass
  device with SRD transport; EFA-only = no IP stack, used by EKS/GPUDirect setups
- [L] SRD (Scalable Reliable Datagram): why AWS built it instead of using InfiniBand; multitenancy
- [L] libfabric (ofi) as the API layer; MPI vs **NCCL via aws-ofi-nccl** vs **NIXL** on top
- [L] RDMA on AWS: RDMA read/write semantics, **GPUDirect RDMA**, GPUDirect Async [V]
- [L] EFA constraints: same-AZ only, attach at launch, security-group rules, placement groups,
  MTU, why ENA Express (SRD for TCP/UDP) is a different thing
- [L] InfiniBand context (what the rest of the industry uses: ConnectX-7, RoCE vs IB) so you can
  contrast AWS's choice; NCCL tuned for p5/p6 topology

### Cluster D — NVIDIA software stack (article 05)
- [K→L] The "who does what" matrix: CUDA driver/runtime vs **cuBLAS/cuBLASLt (GEMM)**,
  **cuDNN (DNN primitives — attention kernels exist in newer cuDNN; minor role in LLM inference)**,
  **CUTLASS (kernel templates vLLM compiles)**, **Triton (DSL kernels)**, **NCCL (collectives:
  all-reduce/all-gather/all-to-all)**, **NVSHMEM**, FlashAttention/FlashInfer, DeepGEMM
- [L] What lives in the AMI (driver, kernel modules: efa, nvidia-peermem, gdrcopy) vs what ships in
  the container (CUDA runtime, NCCL, kernels)
- [L] CUDA Graphs (capture/replay; vLLM's FULL/PIECEWISE modes), torch.compile / Dynamo-Inductor
- [L] NVIDIA GPU Operator components on EKS vs AMI-bundled components; when each
- [L] DCGM exporter, gpu-feature-discovery, driver-upgrade DaemonSets

### Cluster E — vLLM core architecture (articles 06–07)
- [K→L] V1 engine (default): API server ⇄ EngineCore over ZeroMQ IPC; scheduler issuing
  `{request_id: num_tokens}` budgets; symmetric workers with incremental state updates [V]
- [K] **PagedAttention**: block table, logical→physical KV blocks, block size (default 16),
  copy-on-write for beam/parallel sampling
- [K] **Continuous batching** (iteration-level scheduling, Orca lineage) and chunked prefill
- [K] **Prefix caching**: automatic prefix caching (APC), block-hash tree, hit-rate math, eviction
- [L] KVCacheManager/Coordinator internals, preemption (recompute; CPU-swap removed in V1), watermark
- [L] Attention backend zoo: FlashAttention-4 (v0.17+), FlashInfer, Triton, FlexAttention, SDPA, GDN/linear-attention kernels for hybrid models, (cuDNN) [V]
- [L] Model runner, sampler, detokenizer/output processor, logprobs, structured output (xgrammar)
- [L] `vllm serve` config surface that matters on EKS: `--gpu-memory-utilization`, block size,
  `--max-num-seqs`, `--enable-prefix-caching`, `--kv-cache-dtype fp8`, CUDA-graph modes
- [L] Multi-LoRA serving (hot adapters), VLM input processing, sleep mode (`--enable-sleep-mode`)

### Cluster F — Memory, KV cache & numerics (articles 07–08)
- [K→L] KV cache sizing math per token (worked example: Llama-3.1-8B, GQA-8: ~128 KiB/token @ FP16
  KV; 4k-token context ≈ 0.5 GiB), per-model table; GQA/MHA/MLA effect on KV size
- [K] **FP8 KV cache** (e4m3), scales, quality/throughput tradeoffs; `--kv-cache-dtype fp8`
- [K→L] Numeric formats field guide: FP32/TF32, BF16 vs FP16 (why BF16 won), **FP8 E4M3 vs E5M2**
  (range vs mantissa; per-tensor vs per-token/per-channel scales), INT8 W8A8, weight-only
  (AWQ/GPTQ/INT4), **NVFP4 = E2M1 + per-16-group FP8(E4M3) scales + per-tensor FP32 scale**
  (ModelOpt layout; Blackwell SM100/SM120 native FP4 tensor cores), MXFP4 (E8M0 power-of-2 scales) [V]
- [L] KV offload tiers: CPU, LMCache, Mooncake, FlexKV; MultiConnector chaining
- [L] Quantization tooling: llm-compressor/ModelOpt; calibrating FP8; FP4 checkpoints today

### Cluster G — Parallelism (articles 09)
- [K] **Tensor parallelism** (Megatron-style column/row split; all-reduce per layer; loves NVLink)
- [K→L] **Pipeline parallelism** (1F1B, bubbles, uneven splits; wins without NVLink, e.g. L40S;
  composes TP within node + PP across nodes) [V]
- [K] **Data parallelism**: replicas vs **DP attention for MLA models** (DeepSeek: TP duplicates
  latent KV projections; DP+EP partitions KV via all-to-all) — concurrency crossover ~256–512 [V]
- [L→K] **Expert parallelism**: MoE routing, fused-MoE kernels, **DeepEP** all-to-all kernels
  (high-throughput vs low-latency), **EPLB** (`--enable-eplb`), **wide-EP = EP + DP** (vLLM:
  2.2k tok/s/H200; NVIDIA TRT-LLM wide-EP on GB200 NVL72: 130 TB/s NVLink domain, EP32 ≈ 1.8× EP8) [V]
- [L] vLLM multi-node launch modes (`--distributed-executor-backend ray|mp`, external launch),
  NCCL env tuning on EFA (`FI_PROVIDER=efa`, NCCL_* vars), topology files
- [L] Decision matrix: dense vs sparse-MoE vs MLA; low vs high concurrency; activation density
  (ultra-sparse MoE: EP can *lose* to plain TP/DP) [V]

### Cluster H — Prefill/decode economics & disaggregation (articles 10, 13)
- [K→L] Prefill = compute-bound (FLOPs), decode = memory-bandwidth-bound (arithmetic intensity ~1);
  roofline framing; TTFT vs TPOT/ITL as separate SLOs
- [K] Chunked prefill, priority scheduling, interference (a long prefill spikes ITL of decodes)
- [K→L] **P/D disaggregation**: DistServe/Splitwise/Mooncake lineage; vLLM `--kv-transfer-config`
  (`NixlConnector`, `LMCacheConnectorV1`, `MultiConnector`, `FlexKVConnectorV1`; kv_producer/
  kv_consumer; `kv_load_failure_policy`) [V]
- [L] KV transfer over RDMA vs TCP fallback; bidirectional KV transfer for multi-turn (D→P pull) [V]
- [L] Sizing P vs D pools (ISL/OSL mix), when disagg is *not* worth it
- [L] Frontier: wide-EP + disagg + MTP together (vLLM Dec-2025 DeepSeek results; GB200 era) [V]

### Cluster I — Speculative decoding (article 11)
- [K→L] Draft-then-verify; lossless (same distribution); expected tokens/step from acceptance rate α
- [K→L] Method catalog (vLLM): n-gram/prompt-lookup, suffix, draft model, **EAGLE-3**, **MTP**
  (DeepSeek-style and Qwen3.5's natively-trained heads [V]), Medusa, MLP speculator, parallel drafting; PP×spec
  incompatibility [V]
- [L] When it wins (low QPS, latency-bound chat) vs loses (high QPS, KV/memory pressure) — the docs'
  own gain table, reproduced with your measurements
- [L] Config mechanics: `--speculative-config '{"method": "eagle3", ...}'`, draft loading,
  CUDA-graph interplay, batching cost of verification

### Cluster J — Serving platforms on EKS (articles 12–13)
- [K→L] **Ray's actual roles in vLLM-land** (resolves your T4): (1) `--distributed-executor-backend
  ray` for multi-node TP/PP; (2) Ray Serve LLM as a serving layer (LLMServer deployments, placement
  groups, ingress:engine 2:1 ratio, engine-agnostic, supports PD-disagg + DP-attention + EP);
  (3) Ray Data for offline batch inference. llm-d and KServe do **not** need Ray. [V]
- [L→K] **KServe**: classic InferenceService vs the new **LLMInferenceService (LLMISVC)** —
  GenAI-first CRD built on llm-d architecture: `spec.template` (single-node), `spec.worker`
  (→ LeaderWorkerSet multi-node), `spec.prefill` (disagg), `parallelism: {tensor, data, dataLocal,
  expert}`, Gateway-API router + scheduler, HPA/KEDA/WVA autoscaling, `rdma/roce` resources [V]
- [L] **Gateway API Inference Extension (GAIE)**: InferencePool + endpoint selection via Envoy
  ext-proc; v1.4–v1.6 history; **EPP full-featured implementation moved to llm-d in v1.6**;
  InferenceModel deprecation path [V]
- [K→L] **llm-d** (your T1): Router (Envoy proxy + EPP), InferencePool, Model Server; EPP plugin
  architecture (Parser → Flow Control → ProfileHandler → Filter/Score/Pick; Data layer with
  kv-indexer, prefix-cache tree, latency-predictor consultants); routing-proxy sidecar (nixlv2
  protocol); KV-cache management (precise prefix routing, indexing, tiered offload); PD via
  `disagg-profile-handler` + role labels (`llm-d.ai/role`); deploy on EKS via Helm [V]

### Cluster K — Observability, benchmarking, SLOs (article 14)
- [L] Metrics that matter: TTFT/p50/p95/p99, TPOT/ITL, goodput, queue depth, KV utilization,
  prefix hit-rate, step time, per-step token budget, DCGM (SM util, NVLink/PCIe RX/TX, ECC)
- [L] vLLM `/metrics` endpoint tour; EPP/llm-d dashboards; Prometheus + Grafana + kube-prometheus-stack
- [L] Benchmark methodology: inference-perf / vllm bench; tokenized-input length control, warmup,
  concurrency sweeps, per-SLO reporting; publishing raw CSVs
- [L] Building your reusable harness (the "test rig" every article uses)

### Cluster L — Production operation & cost (article 15 + capstone)
- [L] Autoscaling inference: HPA on concurrency vs EPP/llm-d load signals vs KEDA; scale-to-zero cost
  (weight reload), sleep mode; prefix-cache-aware autoscaling (llm-d + KEDA/WVA)
- [L] Scheduling & placement: topology-aware scheduling via DRA, gang scheduling, placement groups,
  AZ-pinched EFA, Karpenter consolidation of GPU nodes, ODCRs/savings plans
- [L] Failure modes catalog: CUDA OOM vs KV-cache OOM & preemption storms, NCCL timeouts, EFA flaps,
  driver/CUDA mismatch, cold prefix-cache storms after rollout
- [L] Cost model: $/1M tokens = f(throughput, SLO, quantization, parallelism); spot for prefill?
- [L] Multi-tenancy: quotas, fairness (EPP flow control: priority bands, FairnessPolicy), rate limits
- [L] Rollouts: gateway-level traffic split (Gateway API weights), LoRA adapter canary, blue/green of
  model servers without cold-cache storms
- [L] Security basics: token auth at gateway, network policies to GPUs, model provenance
- [L] K8s 1.36 GPU-ops gems: Resource Health Status (device health in Pod status — catches
  hardware-caused crash loops), in-place pod-level resource resize, user namespaces GA, mutating
  admission policies [V]

### Capstone (article 16, optional but recommended)
- Serve **DeepSeek-R1-style MoE** (or Qwen3-30B-A3B if budget-bound) end-to-end on EKS: EP + DP
  attention, MTP/EAGLE-3, FP8, P/D disaggregation, llm-d routing, full observability; publish the
  complete reference architecture + benchmark grid. This is the "exam with no answer key."

---

## 4. Series map — 16 articles in 6 phases

| # | Phase | Working title | One-line thesis | Doubts it kills |
| --- | --- | --- | --- | --- |
| 00 | 0. Orientation | Why LLM inference is a systems problem | The full-stack map + series case study setup | — |
| 01 | 1. Hardware & Fabric | Building the GPU cluster: EKS + the right plugins | Addons, device plugin vs DRA, EFA plugin, gang scheduling — what a GPU EKS cluster actually needs | #1 |
| 02 | 1 | Bottlerocket & friends: choosing the right NVIDIA AMI | What's inside EKS-optimized AL2023-NVIDIA vs Bottlerocket aws-k8s-nvidia vs Auto Mode; device discovery end-to-end | #2 |
| 03 | 1 | GPU instance anatomy: NVLink, NVSwitch, and the bandwidth hierarchy | Read `nvidia-smi topo -m` like a systems engineer; why topology dictates parallelism | #4 |
| 04 | 1 | ENA, EFA, EFA-only: AWS's answer to InfiniBand | SRD, OS-bypass, libfabric, placement groups; what "elastic fabric" buys you and its limits | #5 |
| 05 | 1 | The NVIDIA software stack, demystified | cuDNN vs cuBLAS vs CUTLASS vs NCCL vs Triton; what the AMI ships vs what the container ships | #3 |
| 06 | 2. vLLM internals | A request's journey through vLLM V1 | API server → EngineCore → scheduler → model runner; continuous batching & paged attention with receipts | #6 |
| 07 | 2 | Memory is the constraint: KV cache deep dive | Sizing math, paged blocks, prefix caching, preemption, offload tiers | #9a |
| 08 | 2 | A field guide to FP8, NVFP4, BF16 (and when to trust them) | Numeric formats + weight/activation/KV quantization on real runs | #9b |
| 09 | 2 | TP, PP, DP, EP: choosing a parallelism strategy on EKS | Decision matrix from L40S (no NVLink) to p5 (NVSwitch); multi-node launch modes | #8, T2 |
| 10 | 3. Speed & disagg | Prefill vs decode: the two speeds of LLM inference | Compute-bound vs bandwidth-bound; chunked prefill; why disaggregation exists | #7a |
| 11 | 3 | Speculative decoding: free tokens, with terms & conditions | Draft-verify theory + EAGLE-3/MTP/n-gram measured on EKS | #10 |
| 12 | 4. Serving platform | Serving stacks compared: raw vLLM, KServe, Ray Serve, llm-d | Where Ray actually fits (executor vs serving layer) and when you need each platform | T3, T4 |
| 13 | 4 | Disaggregated prefill/decode in production | vLLM KV connectors + NIXL + llm-d PD mode; TTFT wins and the RDMA bill | #7b, T5 |
| 14 | 5. Production | The benchmark rig: TTFT/TPOT/goodput you can defend | Observability stack + methodology; the harness used across the series | — |
| 15 | 5 | Running it for real: scheduling, autoscaling, failure modes, cost | DRA/topology-aware placement, KEDA/WVA autoscaling, OOM/NCCL/EFA failure catalog, $/1M tokens | #1b |
| 16 | 6. Capstone | MoE at scale on EKS (optional flagship) | EP + DP-attention + MTP + FP8 + P/D + llm-d in one reference architecture | T2b |

Each article card (detailed): **Goal → Topics → Hero experiment → Artifacts → Verify-list → Sources.**
Keep cards short; the `research-and-doubt-map.md` file holds the depth.

### Article highlights (hero experiments)

- **01:** from empty account → cluster that runs `nvidia-smi` pod, DCGM exporter green, DRA
  ResourceSlice visible, EFA plugin counted, Kueue gang-scheduling a 2-pod NCCL test.
- **02:** same pod image on three AMI strategies; diff `kubectl describe node` (labels, resources,
  driver version); time-to-first-healthy-GPU-pod for each.
- **03:** `nccl-tests` busbw matrix intra-node (NVSwitch) vs cross-node (EFA); `topo -m` annotated;
  the bandwidth hierarchy table measured, not copied.
- **04:** all-reduce over EFA vs TCP/ENA at TP=8 across 2 nodes; attach efa-only interfaces via
  plugin; demonstrate same-AZ constraint failure mode.
- **05:** trace one Llama layer: which library executes which op (Nsight or `CUDA_LAUNCH_BLOCKING`
  + nsys flamegraph); prove cuDNN's minor role in dense-LLM inference; NCCL env tuning table.
- **06:** `/metrics` + scheduler logs walkthrough; show chunked prefill interleaving prefills and
  decodes in one step; prefix-cache hit demo with repeated system prompt.
- **07:** compute KV per token by hand, then read `gpu_cache_usage` under load to confirm; force
  preemption at `--gpu-memory-utilization` edge; FP8-KV A/B; hybrid counterexample: same token count
  on Qwen3.5-0.8B (6 KV layers + GDN state) vs Llama-3.1-8B (all layers KV).
- **08:** same model served BF16 / FP8-weights / FP8-KV / (NVFP4 on Blackwell if you get access):
  throughput, TTFT, and a small eval delta (e.g. MMLU-5shot or your own rubric).
- **09:** Llama-8B: TP=2 (PCIe, g6e) vs TP=2 (NVSwitch, p5) vs PP=2 (g6e) vs 2×DP replicas — four
  bars, one clear story. Then MoE: EP on/off for Qwen3-30B-A3B at 2 concurrencies.
- **10:** ITL-under-long-prefill demo: chunked prefill vs not; then disagg preview.
- **11:** native MTP on Qwen3.5-0.8B + EAGLE-3/n-gram on Llama-8B at concurrency 1/8/32: the
  "gains evaporate with load" chart.
- **12:** deploy the same model 3 ways (Deployment+Service / KServe LLMISVC / RayService) — measure
  cold start, autoscale latency, and operational surface area.
- **13:** llm-d PD mode vs co-located: TTFT p95 under bursty long-prompt load; NIXL RDMA vs TCP.
- **14:** the harness article: repo others can run; "publish the CSV or it didn't happen."
- **15:** break things on purpose (kill a worker, fill KV, flap EFA) → incident postmortems.
- **16:** the flagship grid: {TP/EP/DP} × {BF16/FP8} × {aggregated/PD} × {spec on/off}.

---

## 5. Cadence, scope & publishing notes

- **Cadence:** Phase 1 articles are infrastructure-heavy; front-load them, then alternate heavy/light
  (e.g. one lab article + one concept article per fortnight).
- **Every article must stand alone** but link the map (a small series nav header).
- **Diagrams:** one canonical architecture diagram per phase, evolving (use your archify/diagram
  tooling); the "request journey" diagram gets annotated further in each phase.
- **Republication guard:** mark anything `[V]` above as "verified on <date>, vLLM <ver>, EKS <ver>,
  driver <ver>" in the post — versions are content in this space.
- **Cross-links to write:** ENA/EFA (04) ↔ NIXL RDMA (13); NVLink (03) ↔ TP vs PP (09) ↔ wide-EP (16);
  KV sizing (07) ↔ FP8-KV (08) ↔ KV-aware routing (llm-d, 12–13).

## 6. Suggested reading spine (canonical sources)

- vLLM docs: V1 guide, parallelism & scaling, speculative decoding, disagg prefill, NixlConnector,
  quantization; vLLM blog (V1 alpha Jan-2025; large-scale serving Dec-2025); v0.17.0 release notes
  (FlashAttention-4, Qwen3.5/GDN family, Mar-2026)
- Papers: PagedAttention (SOSP'23), Orca (OSDI'22), FlashAttention 1/2/3, DistServe (OSDI'24),
  Splitwise (ISCA'24), Mooncake (FAST'25), Sarathi-Serve (OSDI'24), EAGLE-1/2/3, Medusa, DeepSeek-V3
  (MLA, MTP, aux-loss-free MoE)
- Kubernetes: DRA in 1.34 (GA blog), Gateway API + Inference Extension (intro blog; GAIE repo
  releases), LeaderWorkerSet
- llm-d docs: architecture, EPP, scheduling plugins, disaggregated serving, KV-cache management
- AWS: EFA docs (incl. ENA/EFA/EFA-only table, Nitro/GDR/GDA support), P5/P5en pages, EKS accelerated
  AMI docs (incl. Bottlerocket NVIDIA contents), EKS Auto Mode accelerated workloads, NVIDIA
  DRA/device-plugin-on-EKS docs, EFA-on-EKS guide, EKS Kubernetes-version lifecycle (1.36 GA
  2026-06-02)
- NVIDIA: GPU Operator docs, NCCL, aws-ofi-nccl, NIXL, TensorRT-LLM wide-EP blog, DCGM
- KServe: LLMInferenceService overview/configuration docs
- Ray: Ray Serve LLM architecture, KubeRay RayService production guide

Full per-topic source lists with links live in `research-and-doubt-map.md`.
