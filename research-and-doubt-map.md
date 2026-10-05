# Research & Doubt Map — companion to `blog-series-plan.md`

> This file converts your 15 known/unknown topic areas into: crisp definitions, corrections to
> common framing mistakes, a **research-question backlog** (your "tons of doubts" made concrete),
> verified facts with sources, and a hands-on validation idea per topic.
>
> **Verified as of 2026-10-03.** Baseline: EKS 1.36 (GA 2026-06-02), vLLM ≥ 0.17.0,
> default deployment model Qwen/Qwen3.5-0.8B.
> Rules: anything marked **[V]** must be re-verified at publish time; anything marked **[?]**
> is a genuine open research question — answer it in the corresponding article.

---

## 0. Corrections to your original framing (read this first)

| # | You said / assumed | Correction |
| --- | --- | --- |
| 1 | "InfiniBand for node-to-node… in AWS there's Elastic Network Adapter" | Two different things. **ENA** (Elastic Network Adapter) is the ordinary VPC NIC. What you want is **EFA (Elastic Fabric Adapter)** — ENA + an OS-bypass device using AWS's **SRD** protocol, plus RDMA/GPUDirect on select instances. AWS does **not** offer InfiniBand; EFA *is* the InfiniBand-alternative. There's also **EFA-only** interfaces (no IP stack) used by EKS/GPUDirect setups. |
| 2 | "cuDNN and NCCL" as the NVIDIA inference duo | **NCCL** is core (TP collectives). **cuDNN** is nearly incidental for dense-LLM inference: vLLM lives on cuBLAS/cuBLASLt, CUTLASS, Triton, FlashAttention/FlashInfer, DeepGEMM. cuDNN does ship attention kernels and vLLM has backend experiments [V] — but "the cuDNN article" would be wrong for this series. |
| 3 | "Unsure where vLLM uses Ray" | Two distinct slots: (1) **distributed executor** (`--distributed-executor-backend ray`) for multi-node TP/PP/DP launches; (2) **Ray Serve LLM** as an optional serving layer on top (KubeRay `RayService`). Ray is *not* used by llm-d or KServe's LLMInferenceService. |
| 4 | "Bottlerocket AMI with nvidia drivers and plugins… correct AMI tagged with NVIDIA" | Right idea, sharpen it: EKS ships **EKS-optimized accelerated AMIs** (AL2023 x86_64-NVIDIA / ARM-NVIDIA) and **Bottlerocket `aws-k8s-nvidia` variants**. The Bottlerocket NVIDIA variant **ships the NVIDIA device plugin enabled by default** (disable it if you adopt DRA), plus driver, CUDA user-mode, container toolkit, fabric manager, persistenced, IMEX, NVLink subnet manager, MIG manager. The EFA device plugin is still separate. |
| 5 | "Nvlink as an alternative to PCI-E" | Scope it: NVLink/NVSwitch is an **intra-instance** GPU-to-GPU domain (900 GB/s bidir per H100; 3.6 TB/s bisection on p5; 1.8 TB/s per B200; 130 TB/s domain on GB200 NVL72). It never crosses nodes — cross-node is exactly where EFA/RDMA begins. TP *needs* the NVLink domain; PP/DP/EP tolerate the network. |
| 6 | vLLM = "paged attention + continuous batching" | That's the V0-era headline. Since 2025 the engine is **V1** (fully migrated): a unified scheduler emitting per-step token budgets `{request_id: num_tokens}`, ZeroMQ-separated API server and `EngineCore`, symmetric workers with incremental state diffs, prefix caching by default, async scheduling, piecewise CUDA graphs. PagedAttention is now "the KV block manager", one component among many. |

---

## 1. Verified current-state snapshot (Oct 2026, with sources)

- **Kubernetes/EKS:** DRA core APIs are **GA in K8s 1.34** (`resource.k8s.io/v1`, on by default);
  EKS **1.36** GA'd 2026-06-02 (user namespaces GA, mutating admission policies, in-place
  pod-level resource resize, **Resource Health Status** for devices in Pod status).
  Sources: [K8s DRA GA blog](https://kubernetes.io/blog/2025/09/01/kubernetes-v1-34-dra-updates/),
  [DRA docs](https://v1-34.docs.kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/),
  [EKS version lifecycle](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html),
  [EKS 1.36 what's-new](https://aws.amazon.com/about-aws/whats-new/2026/06/amazon-eks-distro-kubernetes-version-1-36/).
- **EKS GPU plumbing:** [NVIDIA DRA driver vs device plugin on EKS](https://docs.aws.amazon.com/eks/latest/userguide/device-management-nvidia-dra-device-plugin.html)
  (DRA driver needs 1.34+, Karpenter *static* capacity only; cannot coexist with the device plugin;
  Bottlerocket: disable built-in plugin via `settings.kubelet-device-plugins.nvidia.enabled=false`,
  Bottlerocket ≥ 1.63.0). [EKS Auto Mode manages NVIDIA drivers + device plugin](https://docs.aws.amazon.com/eks/latest/userguide/auto-accelerated.html)
  (not visible as a DaemonSet; supports g6/g6e/g7e/p5/p5e/p5en/p6-b200/p6-b300/trn2/…).
  [Accelerated AMI matrix](https://docs.aws.amazon.com/eks/latest/userguide/ml-eks-optimized-ami.html)
  (AL2023 x86_64-NVIDIA covers p6-b300…g4dn; Bottlerocket `aws-k8s-nvidia` same list + aarch64;
  Bottlerocket NVIDIA contents incl. NVLink SM, MIG manager, IMEX; NVIDIA 580 driver for 1.34+;
  EFA device plugin installed separately).
- **vLLM:** [V1 architecture blog](https://vllm.ai/blog/2025-01-27-v1-alpha-release)
  (unified scheduler, EngineCore, KV manager, symmetric workers); fully migrated to V1 by the
  [large-scale serving post](https://vllm.ai/blog/2025-12-17-large-scale-serving)
  (DeepSeek wide-EP: 2.2k tok/s/H200; async scheduling; dual-batch overlap; DeepEP; EPLB
  `--enable-eplb`; CUDA graph `FULL_AND_PIECEWISE`). v0.17.0 (2026-03-07) adds FlashAttention-4 and
  the **Qwen3.5 family with Gated DeltaNet (GDN)**, dense + MoE + MTP variants
  ([support PR #34110](https://github.com/vllm-project/vllm/pull/34110)).
- **Qwen3.5-0.8B** ([HF card](https://huggingface.co/Qwen/Qwen3.5-0.8B)): 0.8B params, hidden 1024,
  24 layers as `6 × (3 × (Gated DeltaNet → FFN) → 1 × (Gated Attention → FFN))`; GDN: 16 V/QK heads,
  head-dim 128; Gated Attention: 8 Q / **2 KV** heads, head-dim 256, RoPE 64; FFN 3584; vocab
  248,320 (padded, tied); **MTP: trained with multi-steps**; 262,144 native context.
- **Network fabric:** [EFA docs](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html):
  ENA vs EFA(with ENA) vs **EFA-only**; SRD transport; RDMA read (all Nitro v4+), RDMA write
  (most v4+), **GPUDirect RDMA (GDR)** and **GPUDirect Async (GDA)** on select Nitro v4+; libfabric
  API; NCCL + **NIXL** are the AI/ML consumers. EFA OS-bypass is **same-AZ only**; ENA Express uses
  SRD for TCP/UDP (different feature). [P5 spec](https://aws.amazon.com/ec2/instance-types/p5/):
  8×H100, 900 GB/s NVSwitch per GPU (3.6 TB/s bisectional), **3.2 Tbps EFA aggregate**, GPUDirect
  RDMA, 8×3.84 TB NVMe, 2 TiB RAM; p5en = H200 + 2nd-gen EFA (Nitro v5, ~35% lower latency).
- **Serving stack:** [Gateway API Inference Extension intro](https://kubernetes.io/blog/2025/06/05/introducing-gateway-api-inference-extension/)
  (InferencePool + endpoint selection via ext-proc); by [GAIE v1.6 releases](https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases)
  the full-featured EPP, body-based routing, and latency predictor **moved to llm-d**; GAIE keeps
  CRDs/conformance + lightweight EPP (lwepp); `endpointPickerRef` now optional.
  [llm-d architecture](https://llm-d.ai/docs/0.7/architecture): Router (Envoy proxy + EPP via
  ext-proc) / InferencePool / Model Server; [EPP internals](https://llm-d.ai/docs/dev/architecture/core/router/epp)
  (parser → flow control → Filter/Score/Pick scheduler → data layer with kv-indexer, prefix tree,
  latency predictor); [P/D disagg](https://llm-d.ai/docs/dev/architecture/advanced/disaggregation)
  (`disagg-profile-handler`, role labels, routing-proxy sidecar, vLLM `nixlv2` protocol, NIXL
  transfers, TCP fallback discouraged).
- **KServe:** [LLMInferenceService overview](https://kserve.github.io/website/docs/model-serving/generative-inference/llmisvc/llmisvc-overview)
  — GenAI-first CRD **built on llm-d architecture**; `spec.template` (single-node) / `spec.worker`
  (→ LeaderWorkerSet multi-node) / `spec.prefill` (disagg); `parallelism: {tensor, data, dataLocal,
  expert}`; HPA or KEDA actuators; Workload Variant Autoscaler (WVA); Gateway-API router.
- **Ray Serve LLM** ([architecture](https://docs.ray.io/en/latest/serve/llm/architecture/overview.html)):
  `LLMServer` wraps a vLLM engine via Ray's distributed executor; placement groups (world_size =
  TP×PP); modes: isolated / coordinated (DP attention) / across deployments (P/D disagg);
  ingress:LLMServer replica ratio ≥ 2:1; engine-agnostic (vLLM, SGLang).
- **vLLM P/D disaggregation** ([disagg prefill docs](https://docs.vllm.ai/en/latest/features/disagg_prefill/),
  [NixlConnector guide](https://docs.vllm.ai/en/latest/features/nixl_connector_usage/)):
  `--kv-transfer-config` with `NixlConnector` (UCX default; backends e.g. UCX/GDS), LMCache, Multi,
  FlexKV connectors; `kv_role=kv_producer|kv_consumer` (`kv_both` deprecated for Nixl);
  `kv_load_failure_policy=fail|recompute`; **bidirectional KV transfer** for multi-turn (D→P RDMA
  pull, `kv_recompute_threshold`).

---

## 2. Doubt map (per topic)

### A1. EKS cluster + "appropriate plugins"
- **Crisp:** a GPU-capable EKS cluster = control plane + addon set: VPC CNI, CoreDNS, kube-proxy,
  EBS/EFS CSI, Mountpoint-for-S3 CSI (weights), Karpenter, then **one of** {NVIDIA device plugin,
  NVIDIA DRA driver, EKS Auto Mode}, plus NFD/GFD labels, DCGM exporter, and — for multi-node
  inference — EFA device plugin + a gang scheduler (Kueue/Volcano/KAI).
- **Research questions:** Does Auto Mode manage the EFA device plugin? [?] · When is DRA (1.36)
  production-ready for vLLM serving vs the device plugin? [?] · DCGM exporter placement under
  Auto Mode? [?] · Mountpoint-S3 cold-start cost vs pre-pulled weights on NVMe? [?]
- **Hands-on:** empty account → `nvidia-smi` pod green, DCGM dashboard, ResourceSlice visible.

### A2. AMIs (Bottlerocket etc.)
- **Crisp:** see correction #4. Key differentiators: AL2023-NVIDIA (no bundled device plugin — you
  add GPU Operator/plugin addon) vs Bottlerocket NVIDIA (bundled plugin, locked-down host OS, admin
  container for debugging) vs Auto Mode (AWS manages drivers entirely, no AMI choice).
- **Research questions:** Karpenter AMI alias syntax for Bottlerocket NVIDIA today? [V] ·
  Driver 580/CUDA 13 pairing on 1.34+ AMIs? [V] · How to run admin/diagnostic containers on
  Bottlerocket? · EFA kernel module presence in each variant? [V]
- **Hands-on:** one pod image across all three strategies; diff `kubectl describe node`.

### A3. NVIDIA software stack
- **Crisp:** AMI = driver + kernel modules (nvidia, efa, nvidia-peermem, gdrcopy, fabric manager).
  Container = CUDA user-space, NCCL, kernels. Libraries by role: cuBLAS/cuBLASLt (GEMM),
  CUTLASS (GEMM templates vLLM instantiates), Triton (DSL kernels), FlashAttention/FlashInfer/
  DeepGEMM (attention/MoE kernels), **NCCL (collectives: all-reduce/all-gather/all-to-all; rides
  NVLink intra-node, EFA cross-node via aws-ofi-nccl)**, NVSHMEM (partitioned global memory),
  cuDNN (DNN primitives — minor here [V]).
- **Research questions:** Which vLLM ops actually hit cuDNN? [?] · NCCL↔driver↔CUDA version matrix
  for the vLLM image on 580 drivers? [V] · Where CUDA Graphs change launch overhead (and what
  PIECEWISE captures)? [?] · torch.compile: which subgraphs? [?]
- **Hands-on:** nsys flamegraph of one Llama layer; label each kernel with its library.

### A4. NVLink vs PCIe
- **Crisp:** NVLink 4 (H100): 900 GB/s bidirectional/GPU, NVSwitch all-to-all single-hop;
  NVLink 5 (B200): 1.8 TB/s; GB200 NVL72: 130 TB/s coherent domain. PCIe Gen5 x16 ≈ 64 GB/s per
  direction. NCCL picks transports automatically (NVLink/NVLS/PCIe P2P/sockets).
- **Research questions:** Does NVLS (SHARP in-switch reduction) engage on p5 for all-reduce? [V] ·
  MIG slices & NVLink P2P interactions? [?] · Measured allreduce busbw: p5 intra vs g6e (PCIe) vs
  cross-node EFA — the article-3 hero table.
- **Hands-on:** `nccl-tests` allreduce matrix; `nvidia-smi topo -m` annotated.

### A5. ENA vs EFA vs EFA-only vs InfiniBand
- **Crisp:** correction #1. EFA = ENI + OS-bypass device; SRD (scalable reliable datagram);
  libfabric provider `efa`; consumers: MPI (HPC), NCCL via aws-ofi-nccl, NIXL/UCX (inference).
  EFA-only = no IP/VPC stack (what EKS EFA deployments use). Constraints: same-AZ only, attach at
  launch, SG all-traffic rule, placement groups for p5/p6. GDR/GDA depend on Nitro version.
- **Research questions:** Exact EFA interface count/topology on p5.48xlarge? [V] · efa-only vs
  EFA-with-ENA practical differences on EKS (CNI mode, MTU)? [?] · GDA adoption in vLLM/NIXL? [?] ·
  NCCL env matrix for EFA (`FI_PROVIDER=efa`, NCCL_PROTO, channel settings) with measured busbw? [?]
- **Hands-on:** allreduce across 2 nodes: EFA vs TCP/ENA; intentionally break the same-AZ rule.

### A6. vLLM V1 architecture
- **Crisp:** API server (OpenAI-compatible) ⇄ `EngineCore` (dedicated proc, ZeroMQ); V1 scheduler
  emits `{request_id: num_tokens}` under a per-step token budget (chunked prefill is just budget
  math); KVCacheManager = paged blocks + hash-tree prefix cache (+ Coordinator for hybrid models);
  model runner executes via pluggable attention backend; workers symmetric, receive incremental
  diffs; overlap/async scheduling; CUDA graphs FULL/PIECEWISE; preemption = recompute (swap removed).
- **Research questions:** How does the KVCacheCoordinator lay out **hybrid GDN state vs KV blocks**
  for Qwen3.5? [?] (this is the article-07 flagship demo) · Where exactly does async scheduling
  reorder work? [?] · Metric export path (`/metrics`)? [?] · Structured-output backend integration?
  [?]
- **Hands-on:** run Qwen3.5-0.8B with scheduler debug logs; annotate one step end-to-end.

### A7. Prefill/decode & disaggregation
- **Crisp:** prefill FLOPs-bound (parallel over prompt), decode bandwidth-bound (one token/step,
  reads all weights + KV); chunked prefill co-schedules both (Sarathi); disaggregation splits
  engines (P pool, D pool) and ships KV via connectors; NIXL does RDMA-class transfers; llm-d adds
  the orchestration (decider + routing proxy + role labels).
- **Research questions:** At what (ISL, concurrency) mix does disagg beat chunked prefill? [?] ·
  P:D ratio formula from ISL/OSL + hardware? [?] · Cost of KV transfer vs recompute (the
  `kv_recompute_threshold` logic) [?] · TTFT p95 improvement under bursty long-prompt load? [?]
- **Hands-on:** co-located vs P/D (NixlConnector), bursty load, TTFT p50/p95; RDMA vs TCP fallback.

### A8. TP / PP / DP (+ DP attention)
- **Crisp:** TP = shard weights per layer, all-reduce per block (needs NVLink to be fast); PP =
  shard layers, 1F1B microbatches, bubble cost, uneven splits, composes TP intra-node + PP
  inter-node (`TP=8, PP=2` on 2×8-GPU nodes); DP = replicas (or **DP attention for MLA models**:
  TP duplicates MLA latent KV on every rank; DP+EP partitions KV via all-to-all; crossover
  ~256–512 concurrent [V]). No NVLink (L40S) → prefer PP over TP [V].
- **Research questions:** PP + spec decode still incompatible? [V] · DP-attention on EKS: what NCCL
  all-to-all backend works over EFA? [?] · `mp` vs `ray` executor for DP/wide-EP? [?] · Measured
  TP=2 PCIe vs NVSwitch vs PP=2 vs 2×DP replicas (article-9 hero chart).
- **Hands-on:** the four-bar chart; then EP on/off for a MoE model at two concurrencies.

### A9. KV cache + quantization + numeric formats
- **Crisp:** KV per token = 2 × layers × kv_heads × head_dim × bytes. Llama-3.1-8B (GQA-8, 32L,
  d=128, BF16): ≈ 128 KiB/token → 4k ctx ≈ 0.5 GiB. Qwen3.5-0.8B: only 6 attention layers × 2 KV
  × 256 × 2 × 2B ≈ **12 KiB/token** + constant GDN state (context-length-independent) [V compute].
  Formats: BF16 (training-time reference), FP16, **FP8 E4M3 (weights/acts/KV fwd) vs E5M2 (range)**
  with per-tensor or per-token/channel scales, INT8 W8A8, weight-only W4A16 (AWQ/GPTQ), **NVFP4 =
  E2M1 nibble + per-16-element FP8(E4M3) block scales + per-tensor FP32 global scale** (ModelOpt
  layout; Blackwell SM100/SM120 native FP4 GEMM — FlashInfer TRT-LLM & CUTLASS kernels [V]),
  MXFP4 = E2M1 + E8M0 power-of-2 scales per 32 [V]. FP8 KV via `--kv-cache-dtype fp8`.
- **Research questions:** Quality deltas (BF16 vs FP8 vs FP4) on a small eval you own? [?] ·
  When does FP8 KV *change* outputs visibly (long-context retrieval)? [?] · NVFP4 KV cache support
  matrix on your GPUs? [V] · PagedAttention block size vs fragmentation for 262k-context models? [?]
- **Hands-on:** hand-compute KV/token, verify against `gpu_cache_usage`; precision ladder A/B.

### A10. Speculative decoding
- **Crisp:** draft k tokens, verify in one forward pass, accept by the target's distribution —
  mathematically lossless. Expected tokens/step ≈ (1−α^(k+1))/(1−α) for acceptance rate α.
  vLLM methods: n-gram/prompt-lookup, suffix, draft model, **EAGLE-3**, **MTP** (DeepSeek-style and
  Qwen3.5's natively-trained heads), Medusa, MLP speculators, parallel drafting; PP × spec decode
  incompatibility [V]; best at low QPS (latency), can lose at high QPS (verification cost + KV).
- **Research questions:** Measure α and effective accepted-length distribution on your chat load? [?]
  · MTP on Qwen3.5-0.8B vs n-gram vs EAGLE-3 on Llama-8B — same SLO, three charts? [?] ·
  Verification batch interaction with continuous batching at concurrency 32/64? [?]
- **Hands-on:** the "gains evaporate with load" chart; report TTFT/TPOT not just "1.4× faster".

### A11. llm-d
- **Crisp:** three concepts — Router (Envoy proxy + EPP via ext-proc), InferencePool (the pool of
  model-server pods), Model Server (vLLM pod). EPP = parser → flow control (saturation, priority
  bands, fairness policies) → ProfileHandler running Filter→Score→Pick plugin chains (prefix-cache
  affinity w/ TTFT load gate, kv-cache-utilization, queue-depth, latency, lora-affinity,
  session-affinity, no-hit scorers; max-score/weighted-random pickers) → async data layer (K8s
  watch, metrics probing, kv-indexer, prefix tree, latency predictor). P/D: `disagg-profile-handler`
  + `llm-d.ai/role` labels + routing-proxy sidecar speaking vLLM's `nixlv2` (two-phase) or SGLang
  bootstrap protocol; KV transfer via NIXL (RDMA; TCP fallback for dev only). KV management:
  precise prefix routing, event-driven indexing, tiered offload (CPU/SSD via LMCache).
- **Research questions:** Deploy via current Helm charts on EKS 1.36 (which gateway impl)? [V] ·
  Wire vLLM KV events → EPP kv-indexer and *show* a prefix-cache hit changing routing? [?] ·
  EPP flow control vs HPA/KEDA interplay (who scales, who queues)? [?] · GAIE v1.6's EPP→llm-d
  move: what stays upstream, what you pin? [V]
- **Hands-on:** llm-d quickstart with Qwen3.5-0.8B; two-scenario demo (warm prefix vs cold).

### A12. Expert parallelism (your T2)
- **Crisp:** MoE routes each token to top-k experts; EP places experts across ranks (tokens travel
  via all-to-all instead of weights being replicated). vLLM: `--enable-expert-parallel`, fused-MoE
  kernels, DeepEP all-to-all (high-throughput vs low-latency modes), **EPLB** (`--enable-eplb`,
  hierarchical/global load balancing with live weight shuffles), **wide-EP = EP + DP** (vLLM Dec-25:
  2.2k tok/s/H200 on DeepSeek; NVIDIA TRT-LLM wide-EP on GB200 NVL72: EP32 ≈ 1.8× EP8, needs the
  130 TB/s NVLink domain to make cross-GPU token gathers cheap). Rule of thumb: ultra-sparse MoE
  (<1% activation density) → EP overhead can exceed benefit [V].
- **Research questions:** EP=8 vs TP=8 for Qwen3-30B-A3B on one p5 at two concurrencies? [?] ·
  EPLB rebalance interval effects under skewed routing? [?] · DeepEP over EFA cross-node? [?] ·
  EP × MTP × P/D interactions (the capstone grid)? [?]
- **Hands-on:** EP on/off chart; expert-hotness histogram from your load.

### A13. KServe (your T3)
- **Crisp:** classic `InferenceService` (predictive AI, serverless via Knative or raw) vs the new
  **LLMInferenceService**: GenAI-first, built on llm-d patterns — `spec.template` (single-node),
  `spec.worker` (multi-node via LeaderWorkerSet), `spec.prefill` (disagg), `parallelism`
  (tensor/data/dataLocal/expert), Gateway-API router + scheduler config, HPA/KEDA/WVA autoscaling,
  `rdma/roce` resource requests. v2 protocol; InferenceService still fine for simple single-node
  LLM serving.
- **Research questions:** LLMISVC maturity/GA status in the version you'd pin? [V] ·
  LLMISVC vs raw llm-d Helm: what does the CRD add operationally? [?] · `rdma/roce` on EKS (vs
  EFA)? [V] · WVA vs KEDA on your metrics? [?]
- **Hands-on:** same model via InferenceService vs LLMISVC vs raw Deployment; compare cold start,
  autoscale latency, surface area.

### A14. Ray & KubeRay (your T4)
- **Crisp:** three roles. (1) **Executor backend**: `--distributed-executor-backend ray` launches
  vLLM worker actors for multi-node TP/PP/DP (mp = single-node only). (2) **Serving layer**: Ray
  Serve LLM `LLMServer` deployments wrap vLLM; placement groups pin TP×PP bundles (PACK strategy);
  composite patterns: DP attention, EP (DeepSeek-V3, GPT-OSS), P/D disagg across deployments;
  ingress:LLMServer ≥ 2:1; engine-agnostic (vLLM/SGLang); deployed via KubeRay `RayService` CR.
  (3) **Batch**: Ray Data + vLLM for offline corpus jobs. llm-d and KServe LLMISVC do **not** use
  Ray — that's the "when do I actually need Ray?" answer.
- **Research questions:** Ray vs mp vs external-launch for your multi-node TP case? [?] ·
  RayService zero-downtime model upgrades (cluster-level update semantics)? [?] · Ray autoscaler +
  K8s cluster autoscaler interaction on EKS? [?]
- **Hands-on:** RayService with Qwen3.5-0.8B; scale from 1→3 replicas and measure autoscale latency.

### A15. RDMA / GPUDirect (your T5)
- **Crisp:** RDMA = NIC moves data between memory regions without CPU; on AWS the transport is EFA
  (SRD-based, verbs-compatible via libfabric). **GPUDirect RDMA** registers GPU memory with the NIC
  so packets land directly in VRAM (needs `nvidia-peermem`-style registration — GPU Operator deploys
  it; Nitro v4+ on select instance types; **GDA** = async variant [V]). In vLLM-land it shows up
  twice: NCCL collectives (TP across nodes) and **NIXL** KV transfers (P/D disagg; UCX with EFA
  plugin; TCP fallback is dev-only). `gdrcopy` = fast host↔GPU copies (not networking).
- **Research questions:** Enable peermem on EKS (GPU Operator component) + verify with NIXL bench? [V]
  · KV transfer bandwidth: RDMA vs TCP on your instance pair? [?] · UCX-EFA env tuning for NIXL? [?]
  · When is bidirectional multi-turn KV pull (D→P) worth it? [?]
- **Hands-on:** `nixl` bench P↔D pair; compare against the article-4 allreduce numbers.

---

## 3. Suggested study order (maps to series phases)

1. **Foundation reading (2–3 evenings):** vLLM V1 blog + V1 guide; K8s DRA GA blog + EKS DRA/device
   plugin doc; EFA doc (ENA/EFA/EFA-only table + SRD); EKS accelerated AMI doc. This alone answers
   corrections #1, #4 and most of A1/A2.
2. **Then, in phase order:** PagedAttention paper + Orca (A6/A7) → EKS docs + EFA-on-EKS (A1–A5)
   → vLLM parallelism/scaling docs + AMD/vLLM decision matrix (A8/A12) → disagg docs + DistServe/
   Mooncake (A7/A15) → spec-decode docs + EAGLE-3/MTP (A10) → llm-d docs in this order: architecture →
   EPP → scheduling plugins → disaggregation (A11) → GAIE blog + releases (A13 context) → KServe
   LLMISVC docs (A13) → Ray Serve LLM architecture (A14).
3. **Lab-first rule:** every doc-reading block ends in the matching hands-on from section 2 — the
   numbers you generate become the article's evidence.
