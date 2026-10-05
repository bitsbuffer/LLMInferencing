# Learning & Coverage Tracker — "LLM Inference on EKS" series

> Topic source of truth: `blog-series-plan.md` §3 (master topic inventory).
> Companion: `research-and-doubt-map.md` (per-topic crisp notes, doubt backlog, verified facts).
> Created: 2026-10-03 · Last updated: 2026-10-03
>
> Method: one topic at a time, in queue order. Each deep-dive ends with a tracker update —
> status, depth, date, and an artifact pointer. Nothing else gets edited mid-dive.

---

## How to use this file

**Statuses:** ⬜ pending → 🟨 in-progress → 🟩 covered → 📢 published (article shipped)

**Definition of done for "🟩 covered"** (all five must be true):
1. Crisp understanding written down (what it is, why it exists, where it sits in the stack).
2. Every research question for the topic in `research-and-doubt-map.md` answered or explicitly
   deferred with a reason.
3. Facts verified against current official docs (dated) or measured on the lab.
4. Hands-on validation done or scheduled as an explicit lab task.
5. Notes appended to `notes/<ID>-<slug>.md` and this tracker's row + log updated.

**Depth scale:**
- **D1** concept-only (can explain it, no hands-on)
- **D2** + mechanics (know how it works internally, can reason about configs)
- **D3** + hands-on evidence (ran it, observed it)
- **D4** + reconciled numbers (prediction vs measurement, blog-ready)

**IDs are stable** — reference them as `A3`, `G4`, etc. in notes, chats, and articles.

---

## Current focus

| Field | Value |
| --- | --- |
| In progress | — |
| Next up (queue head) | **E5 — KVCacheManager/Coordinator internals; preemption (recompute), watermark** |
| Queue position | 32 of 74 |
| Stats | **31 covered / 74 total** |

## Study queue (order of attack)

Queue follows article order (A → CAP); foundation reading (vLLM V1 guide, K8s DRA GA blog + EKS
DRA docs, EFA docs, EKS accelerated-AMI doc) is folded into the first five deep-dives where each
item needs it. One deep-dive = one topic; batch at most 3 related topics per session.

`A1 → A2 → A3 → … → A10 → B1 → … → B6 → C1 → … → C6 → D1 → … → D5 → E1 → … → E9 → F1 → … → F5 →
G1 → … → G6 → H1 → … → H6 → I1 → … → I4 → J1 → … → J4 → K1 → … → K4 → L1 → … → L8 → CAP1`

---

## Your original 15 areas → where they live

| You asked about | Tracker topics |
| --- | --- |
| #1 EKS + appropriate plugins | A1–A5, A8–A10 |
| #2 Bottlerocket NVIDIA AMI / device discovery | A6, A7 (+B3, D5) |
| #3 NVIDIA library ecosystem (cuDNN, NCCL) | D1, D2 (+C3, E6) |
| #4 NVLink vs PCIe | B1–B4 |
| #5 "InfiniBand"/ENA → actually EFA/SRD | C1–C5 |
| #6 vLLM core (paged attn, cont. batching, prefix cache, architecture) | E1–E9 |
| #7 Prefill/decode + disaggregated inference | H1–H6 |
| #8 TP / PP / DP | G1–G3, G6 |
| #9 KV cache (+quant) & numeric formats (NVFP4/FP8/BF16) | F1–F5 |
| #10 Speculative decoding | I1–I4 |
| T1 llm-d | J4 (+J3 context) |
| T2 Expert parallelism | G4 (+G6) |
| T3 KServe | J2 |
| T4 Ray / where vLLM uses it | J1 |
| T5 RDMA / GPUDirect | C3, C4, H4 (+B4, D2) |

---

## Coverage board

### Cluster A — EKS & cluster plumbing (articles 01–02) — 10 topics
| ID | Topic | Status | Depth | Covered on | Artifact / notes |
| --- | --- | --- | --- | --- | --- |
| A1 | EKS 1.36 control plane + addon stack (VPC CNI, CoreDNS, kube-proxy, EBS/EFS CSI, Mountpoint-S3, Karpenter) | 🟩 | D2 | 2026-10-03 | `notes/A1-eks-136-cluster-addons.md` · `labs/01-cluster-addons/LAB.md` |
| A2 | EKS Auto Mode vs self-managed GPU management | 🟩 | D2 | 2026-10-03 | `notes/A2-eks-auto-mode-vs-self-managed.md` · `labs/01-cluster-addons/LAB.md` (Path A) |
| A3 | Device plugin vs DRA (GA in 1.34): ResourceSlice/DeviceClass/ResourceClaim, MIG/MPS/time-slice, ComputeDomains | 🟩 | D2 | 2026-10-03 | `notes/A3-nvidia-device-plugin-vs-dra.md` · `labs/01-cluster-addons/LAB.md` (Path C) |
| A4 | NFD / GPU feature discovery labels; topology-aware GPU scheduling | 🟩 | D2 | 2026-10-03 | `notes/A4-nfd-gfd-topology-scheduling.md` · `labs/01-cluster-addons/LAB.md` (step 6) |
| A5 | EFA device plugin (`vpc.amazonaws.com/efa`), efa-only vs EFA-with-ENA | 🟩 | D2 | 2026-10-03 | `notes/A5-efa-device-plugin.md` · `labs/01-cluster-addons/LAB.md` (step 7) |
| A6 | Bottlerocket NVIDIA AMI contents + built-in device plugin (disable for DRA) | 🟩 | D2 | 2026-10-03 | `notes/A6-bottlerocket-nvidia-ami.md` · `labs/01-cluster-addons/LAB.md` (step 8) |
| A7 | EKS-optimized AL2023-NVIDIA vs Bottlerocket decision table | 🟩 | D2 | 2026-10-03 | `notes/A7-al2023-vs-bottlerocket.md` |
| A8 | Gang scheduling (Kueue / Volcano / KAI) | 🟩 | D2 | 2026-10-03 | `notes/A8-gang-scheduling.md` · `labs/01-cluster-addons/LAB.md` (step 9) |
| A9 | Node pools & taints; placement groups for p5/p6 | 🟩 | D2 | 2026-10-03 | `notes/A9-node-pools-taints-placement-groups.md` · `labs/01-cluster-addons/LAB.md` (step 10) |
| A10 | Model storage & weight-loading cost (S3→NVMe warm pool, sleep mode) | 🟩 | D2 | 2026-10-03 | `notes/A10-model-storage-weight-loading.md` · `labs/01-cluster-addons/LAB.md` (step 11) |

### Cluster B — GPU silicon & topology (article 03) — 6 topics
| ID | Topic | Status | Depth | Covered on | Artifact / notes |
| --- | --- | --- | --- | --- | --- |
| B1 | NVLink 4/5, NVSwitch, NVLink domain vs PCIe Gen5 | 🟩 | D2 | 2026-10-03 | `notes/B1-nvlink-nvswitch-pcie.md` · `labs/01-cluster-addons/LAB.md` (step 12) |
| B2 | Bandwidth hierarchy table — measured, not copied | 🟩 | D2 | 2026-10-03 | `notes/B2-bandwidth-hierarchy.md` · `labs/03-gpu-anatomy/LAB.md` (measured cols pending) |
| B3 | Reading `nvidia-smi topo -m`, `nvlink`, fabric manager logs | 🟩 | D2 | 2026-10-03 | `notes/B3-topo-nvlink-fabric-logs.md` · `labs/03-gpu-anatomy/LAB.md` (step 1 ext.) |
| B4 | Instance anatomy: p5/p5e/p5en/p6-b200/p6e-gb200, EFA interface counts | 🟩 | D2 | 2026-10-03 | `notes/B4-instance-anatomy.md` |
| B5 | MIG, time-slicing, MPS for inference | 🟩 | D2 | 2026-10-03 | `notes/B5-mig-timeslicing-mps.md` · `labs/03-gpu-anatomy/LAB.md` (step 9) |
| B6 | DCGM health & metrics exposure | 🟩 | D2 | 2026-10-03 | `notes/B6-dcgm-health-metrics.md` · `labs/03-gpu-anatomy/LAB.md` (step 8) |

### Cluster C — AWS network fabric (article 04) — 6 topics
| ID | Topic | Status | Depth | Covered on | Artifact / notes |
| --- | --- | --- | --- | --- | --- |
| C1 | ENA vs EFA vs EFA-only vs InfiniBand (SRD) | 🟩 | D2 | 2026-10-03 | `notes/C1-ena-efa-efa-only-infiniband.md` · `labs/03-gpu-anatomy/LAB.md` (step 5 ext.) |
| C2 | SRD protocol — why AWS built it, multitenancy | 🟩 | D2 | 2026-10-03 | `notes/C2-srd-protocol-depth.md` |
| C3 | libfabric layer; MPI vs NCCL (aws-ofi-nccl) vs NIXL | 🟩 | D2 | 2026-10-03 | `notes/C3-libfabric-consumers-mpi-nccl-nixl.md` |
| C4 | RDMA on AWS: RDMA read/write, GPUDirect RDMA (GDR), GDA | 🟩 | D2 | 2026-10-03 | `notes/C4-rdma-gdr-gda.md` · `labs/03-gpu-anatomy/LAB.md` (step 4 ext.) |
| C5 | EFA operational constraints (same-AZ, attach-at-launch, SG, placement groups, MTU); ENA Express distinction | 🟩 | D2 | 2026-10-03 | `notes/C5-efa-operational-constraints.md` |
| C6 | InfiniBand industry context; NCCL topology tuning for p5/p6 | 🟩 | D2 | 2026-10-03 | `notes/C6-ib-context-nccl-tuning.md` |

### Cluster D — NVIDIA software stack (article 05) — 5 topics
| ID | Topic | Status | Depth | Covered on | Artifact / notes |
| --- | --- | --- | --- | --- | --- |
| D1 | Library role matrix: cuBLAS(Lt), CUTLASS, Triton, NCCL, NVSHMEM, cuDNN, FlashAttention/FlashInfer, DeepGEMM | 🟩 | D2 | 2026-10-03 | `notes/D1-nvidia-library-role-matrix.md` |
| D2 | AMI vs container responsibilities (kernel modules vs user-space) | 🟩 | D2 | 2026-10-03 | `notes/D2-ami-vs-container-responsibilities.md` |
| D3 | CUDA Graphs (FULL/PIECEWISE), torch.compile / Dynamo-Inductor | 🟩 | D2 | 2026-10-03 | `notes/D3-cuda-graphs-torch-compile.md` |
| D4 | NVIDIA GPU Operator components vs AMI-bundled; when each | 🟩 | D2 | 2026-10-03 | `notes/D4-gpu-operator-vs-ami-bundled.md` |
| D5 | DCGM exporter, GFD, driver-upgrade DaemonSets | 🟩 | D2 | 2026-10-03 | `notes/D5-dcgm-gfd-driver-daemonsets.md` |

### Cluster E — vLLM core architecture (articles 06–07) — 9 topics
| ID | Topic | Status | Depth | Covered on | Artifact / notes |
| --- | --- | --- | --- | --- | --- |
| E1 | V1 engine process model: API server ⇄ EngineCore (ZeroMQ), symmetric workers, incremental diffs | 🟩 | D2 | 2026-10-03 | `notes/E1-vllm-v1-process-model.md` |
| E2 | PagedAttention: block tables, logical→physical, copy-on-write | 🟩 | D2 | 2026-10-03 | `notes/E2-paged-attention.md` |
| E3 | Continuous batching + chunked prefill (unified token-budget scheduler) | 🟩 | D2 | 2026-10-03 | `notes/E3-continuous-batching-chunked-prefill.md` |
| E4 | Prefix caching: APC, block-hash tree, hit-rate math, eviction | 🟩 | D2 | 2026-10-03 | `notes/E4-prefix-caching.md` |
| E5 | KVCacheManager/Coordinator internals; preemption (recompute), watermark | ⬜ | — | — | — |
| E6 | Attention backend zoo: FA-4, FlashInfer, Triton, FlexAttention, SDPA, GDN/linear kernels, (cuDNN) | ⬜ | — | — | — |
| E7 | Model runner, sampler, output processor, logprobs, structured output | ⬜ | — | — | — |
| E8 | `vllm serve` config surface that matters on EKS | ⬜ | — | — | — |
| E9 | Multi-LoRA serving, VLM input processing, sleep mode | ⬜ | — | — | — |

### Cluster F — Memory, KV cache & numerics (articles 07–08) — 5 topics
| ID | Topic | Status | Depth | Covered on | Artifact / notes |
| --- | --- | --- | --- | --- | --- |
| F1 | KV sizing math (Llama-3.1-8B ≈128 KiB/token) + hybrid case (Qwen3.5-0.8B: 6 KV layers ≈12 KiB/token + GDN state) | ⬜ | — | — | — |
| F2 | FP8 KV cache (e4m3), scales, quality/throughput tradeoffs | ⬜ | — | — | — |
| F3 | Numeric formats field guide: BF16/FP16, FP8 E4M3 vs E5M2, INT8 W8A8, weight-only, NVFP4, MXFP4 | ⬜ | — | — | — |
| F4 | KV offload tiers: CPU, LMCache, Mooncake, FlexKV; MultiConnector | ⬜ | — | — | — |
| F5 | Quantization tooling: llm-compressor / ModelOpt, FP8 calibration | ⬜ | — | — | — |

### Cluster G — Parallelism (article 09) — 6 topics
| ID | Topic | Status | Depth | Covered on | Artifact / notes |
| --- | --- | --- | --- | --- | --- |
| G1 | Tensor parallelism (Megatron split, per-layer all-reduce, NVLink dependence) | ⬜ | — | — | — |
| G2 | Pipeline parallelism (1F1B, bubbles, uneven splits; no-NVLink case; TP×PP composition) | ⬜ | — | — | — |
| G3 | Data parallelism + DP-attention for MLA (KV partitioning, concurrency crossover) | ⬜ | — | — | — |
| G4 | Expert parallelism: routing, fused-MoE, DeepEP, EPLB, wide-EP (EP+DP) | ⬜ | — | — | — |
| G5 | Multi-node launch modes (ray/mp/external) + NCCL env tuning on EFA | ⬜ | — | — | — |
| G6 | Parallelism decision matrix: dense/MoE/MLA × concurrency; activation-density rule | ⬜ | — | — | — |

### Cluster H — Prefill/decode & disaggregation (articles 10, 13) — 6 topics
| ID | Topic | Status | Depth | Covered on | Artifact / notes |
| --- | --- | --- | --- | --- | --- |
| H1 | Prefill vs decode economics (roofline, arithmetic intensity, TTFT/TPOT SLOs) | ⬜ | — | — | — |
| H2 | Chunked prefill, priority scheduling, ITL interference | ⬜ | — | — | — |
| H3 | P/D disaggregation: vLLM `--kv-transfer-config`, connectors (Nixl/LMCache/Multi/FlexKV) | ⬜ | — | — | — |
| H4 | KV transfer: RDMA vs TCP fallback; bidirectional multi-turn pull | ⬜ | — | — | — |
| H5 | P/D pool sizing (ISL/OSL mix); when disagg is not worth it | ⬜ | — | — | — |
| H6 | Frontier: wide-EP + disagg + MTP together | ⬜ | — | — | — |

### Cluster I — Speculative decoding (article 11) — 4 topics
| ID | Topic | Status | Depth | Covered on | Artifact / notes |
| --- | --- | --- | --- | --- | --- |
| I1 | Draft-then-verify theory; losslessness; expected tokens/step from α | ⬜ | — | — | — |
| I2 | Method catalog: ngram, suffix, draft model, EAGLE-3, MTP (incl. Qwen3.5 native), Medusa, MLP | ⬜ | — | — | — |
| I3 | When spec decode wins/loses (QPS & memory effects) | ⬜ | — | — | — |
| I4 | Config mechanics (`--speculative-config`), CUDA-graph & batching interplay, PP×spec limits | ⬜ | — | — | — |

### Cluster J — Serving platforms on EKS (articles 12–13) — 4 topics
| ID | Topic | Status | Depth | Covered on | Artifact / notes |
| --- | --- | --- | --- | --- | --- |
| J1 | Ray's roles: distributed executor, Ray Serve LLM (LLMServer, placement groups, 2:1 ingress), Ray Data; KubeRay | ⬜ | — | — | — |
| J2 | KServe: InferenceService vs LLMInferenceService (template/worker/prefill, LWS, parallelism fields, WVA, HPA/KEDA) | ⬜ | — | — | — |
| J3 | Gateway API Inference Extension: InferencePool, ext-proc, EPP, v1.6 EPP→llm-d split | ⬜ | — | — | — |
| J4 | llm-d: Router (Envoy+EPP), EPP plugin chain (flow control, Filter/Score/Pick, data layer), routing proxy (nixlv2), KV mgmt, PD mode | ⬜ | — | — | — |

### Cluster K — Observability & benchmarking (article 14) — 4 topics
| ID | Topic | Status | Depth | Covered on | Artifact / notes |
| --- | --- | --- | --- | --- | --- |
| K1 | Metrics that matter: TTFT/TPOT/ITL p50-p99, goodput, queue depth, KV util, prefix hit-rate, step time | ⬜ | — | — | — |
| K2 | Stack: vLLM `/metrics`, DCGM, Prometheus/Grafana, EPP/llm-d dashboards | ⬜ | — | — | — |
| K3 | Benchmark methodology: inference-perf / vllm bench, warmup, concurrency sweeps, length control | ⬜ | — | — | — |
| K4 | Reusable benchmark harness (the series' test rig) | ⬜ | — | — | — |

### Cluster L — Production operation & cost (articles 15–16) — 8 topics
| ID | Topic | Status | Depth | Covered on | Artifact / notes |
| --- | --- | --- | --- | --- | --- |
| L1 | Autoscaling: HPA vs EPP signals vs KEDA/WVA; scale-to-zero & sleep; cache-aware autoscale | ⬜ | — | — | — |
| L2 | Scheduling & placement: DRA topology-awareness, gang scheduling, placement groups, Karpenter consolidation, ODCRs | ⬜ | — | — | — |
| L3 | Failure modes catalog: CUDA OOM vs KV OOM, preemption storms, NCCL timeouts, EFA flaps, driver mismatch | ⬜ | — | — | — |
| L4 | Cost model: $/1M tokens; spot vs on-demand per phase | ⬜ | — | — | — |
| L5 | Multi-tenancy: quotas, EPP flow-control fairness, rate limits | ⬜ | — | — | — |
| L6 | Rollouts: gateway traffic split, LoRA canary, cold-cache storms | ⬜ | — | — | — |
| L7 | Security basics: auth at gateway, network policies, model provenance | ⬜ | — | — | — |
| L8 | K8s 1.36 GPU-ops gems: Resource Health Status, in-place pod resize, user namespaces, mutating admission policies | ⬜ | — | — | — |

### Capstone (article 16) — 1 topic
| ID | Topic | Status | Depth | Covered on | Artifact / notes |
| --- | --- | --- | --- | --- | --- |
| CAP1 | Flagship MoE grid: {TP/EP/DP} × {BF16/FP8} × {aggregated/PD} × {spec on/off} + llm-d + full observability | ⬜ | — | — | — |

---

## Article-level rollup

| # | Article (working title) | Owns topics | Status | Drafted? |
| --- | --- | --- | --- | --- |
| 00 | Why LLM inference is a systems problem | (map) | ⬜ | — |
| 01 | Building the GPU cluster: EKS + the right plugins | A1–A5, A8–A10 | ⬜ | — |
| 02 | Bottlerocket & friends: choosing the right NVIDIA AMI | A6, A7 (+B3) | ⬜ | — |
| 03 | GPU instance anatomy: NVLink, NVSwitch, bandwidth hierarchy | B1–B6 | ⬜ | — |
| 04 | ENA, EFA, EFA-only: AWS's answer to InfiniBand | C1–C6 | ⬜ | — |
| 05 | The NVIDIA software stack, demystified | D1–D5 | ⬜ | — |
| 06 | A request's journey through vLLM V1 | E1–E3, E7, E8 | ⬜ | — |
| 07 | Memory is the constraint: KV cache deep dive | E4, E5, E9, F1, F4 | ⬜ | — |
| 08 | A field guide to FP8, NVFP4, BF16 | F2, F3, F5 | ⬜ | — |
| 09 | TP, PP, DP, EP: choosing a parallelism strategy on EKS | G1–G6 | ⬜ | — |
| 10 | Prefill vs decode: the two speeds of LLM inference | H1, H2 | ⬜ | — |
| 11 | Speculative decoding: free tokens, with terms & conditions | I1–I4 | ⬜ | — |
| 12 | Serving stacks compared: raw vLLM, KServe, Ray Serve, llm-d | J1–J3 | ⬜ | — |
| 13 | Disaggregated prefill/decode in production | H3–H6, J4 | ⬜ | — |
| 14 | The benchmark rig: TTFT/TPOT/goodput you can defend | K1–K4 | ⬜ | — |
| 15 | Running it for real: scheduling, autoscaling, failures, cost | L1–L8 | ⬜ | — |
| 16 | MoE at scale on EKS (capstone) | CAP1 | ⬜ | — |

Article status: ⬜ pending → 🟨 drafting → 🟩 draft ready → 📢 published.
An article can only reach 🟩 when all of its topics are ≥ D3 and its hero experiment has numbers.

---

## Session log (append-only)

| Date | Topics advanced | Depth | Artifacts produced | Notes |
| --- | --- | --- | --- | --- |
| 2026-10-03 | Series plan + research/doubt map + this tracker created | — | `blog-series-plan.md`, `research-and-doubt-map.md`, `progress-tracker.md` | Baselines locked: EKS 1.36, vLLM ≥0.17, Qwen3.5-0.8B default model. All 74 topics pending. |
| 2026-10-03 (goal round 1) | A1, A2 | D2 | `notes/A1-eks-136-cluster-addons.md`, `notes/A2-eks-auto-mode-vs-self-managed.md`, `labs/01-cluster-addons/LAB.md` | Verified: K8s 1.36 DRA wave (partitionable devices, device taints, extended-resources bridge = beta; AdminAccess + prioritized lists = stable); VPC CNI 1.36 build discrepancy v1.22.4 vs v1.23.1 [V]; Karpenter v1.14.x current; Auto Mode = no DRA, EFA via NodeClass `advancedNetworking`, MOFED ≥v0.19 default conflict with EFA plugin; Auto Mode fee ~12% on c6a.2xlarge. Lab scheduled (not run). |
| 2026-10-03 (goal round 2) | A3 | D2 | `notes/A3-nvidia-device-plugin-vs-dra.md`, LAB 01 Path C added | Verified: NVIDIA DRA driver GPU-allocation GA (v25.12.0 → kubernetes-sigs v0.5.0, 2026-08-19, chart at registry.k8s.io, GPU Operator v26.7); dynamic MIG alpha (H100+, 1.36 default partitionable devices); consumable capacity / multi-user MPS / FabricManager partitioning / host-managed IMEX alpha; ComputeDomains ~10s at k-node scale; EKS = static Karpenter/MNG only, never Auto Mode, never with device plugin; vLLM needs no core changes for DRA (issue #23900 — examples missing). Verdict: device plugin stays default; DRA for selection/topology/health. |
| 2026-10-03 (goal round 3) | A4 | D2 | `notes/A4-nfd-gfd-topology-scheduling.md`, LAB 01 step 6 added | Verified: NFD v0.19.0 (2026-07-10), chart moved to registry.k8s.io/nfd; GFD label set incl. MIG overrides (gpu.product/count/memory/family, cuda.driver.*, mig.strategy); NRT + NodeResourceTopologyMatch (4 scoring strategies; scheduler picks node, kubelet Topology Manager picks NUMA; overreserving Reserve cache ≥5s; homogeneous-NUMA prerequisite); DRA absorbs NUMA attrs on 1.36 (DRAListTypeAttributes alpha in driver v0.5.0). Guidance: NFD+GFD always; NRT = interim; DRA = durable path. |
| 2026-10-03 (goal round 4) | A5 | D2 | `notes/A5-efa-device-plugin.md`, LAB 01 step 7 added | Verified: EFA = 3 layers (provisioning at launch via Karpenter `networkInterfaces` [CEL: primary=interface, 1 EFA device/card] / Auto Mode NodeClass / launch templates; device plugin `eks/aws-efa-k8s-device-plugin` counting `vpc.amazonaws.com/efa`; AMI host components). EFA-only = recommended (no IP, no conntrack); p5/p5e = 32 cards, 3.2 Tbps shared w/ 800 Gbps IP cap; p5en = 16. aws-ofi-nccl env matrix: modern stack (libfabric ≥1.18, ofi ≥1.7.0) needs nothing; ≤1.5.0 needs FI_PROVIDER+NCCL_PROTO; FI_EFA_USE_HUGE_PAGE=0 for fork OOM; p5 mins cuda≥12/nccl≥2.18.5/ofi≥1.7.3/efa≥1.29.0. DRANET = EFA DRA driver; plugin+DRA mutually exclusive. |
| 2026-10-03 (goal round 5) | A6 | D2 | `notes/A6-bottlerocket-nvidia-ami.md`, LAB 01 step 8 added | Verified: Bottlerocket `aws-k8s-1.36-nvidia` contents (device plugin enabled by default, driver 580, fabric manager/persistenced/IMEX/NVLink-SM/MIG manager, EFA minimal in all variants); SSM pattern `/aws/service/bottlerocket/aws-k8s-1.36-nvidia/x86_64/latest/image_id`; Karpenter alias pinning guidance; v1.63.0 added the disable knob (`settings.kubelet-device-plugins.nvidia.enabled=false`) with coupled MIG-manager/MPS side effects; default `device-list-strategy: cdi-cri` (CDI injection); admin container + patched nvidia-bug-report.sh + `kubectl debug --profile=sysadmin` debug flow. Karpenter -nvidia variant auto-resolution [V at lab]. |
| 2026-10-03 (goal round 6) | A7 | D2 | `notes/A7-al2023-vs-bottlerocket.md` | Verified: AL2 EKS AMIs dead (no AMIs ≥1.33, EOS 2025-11-26, cgroupv1 maintenance); AL2023-NVIDIA ships NO device plugin but nodeadm sets `nvidia.com/gpu.present=true` at boot; GPU Operator on AL2023 = disable driver+toolkit, on Bottlerocket = disable driver+toolkit+plugin (maintainers discourage); topology-aligned GPU↔EFA automatic ONLY on AL2023 plugin path; Bottlerocket in-place atomic updates (Brupop recommended, SSM docs) vs node replacement; AL2023 = series default recipe, Bottlerocket = security/fleet story, Auto Mode = fast path. |
| 2026-10-03 (goal round 7) | A8 | D2 | `notes/A8-gang-scheduling.md`, LAB 01 step 9 added | Verified: Kueue v0.19.2 (Workload=admission unit; LWS one-Workload-per-group, `podset-required-topology`/`podset-group-name` TAS annotations, LWSImmutableGroupSize beta, MultiKueue atomic LWS dispatch, TAS bug-heavy 0.19.x); Volcano v1.15.2 (gang-aware preemption/reclamation alpha, HyperNodes, DRA queue quota in capacity plugin, scheduling gates for quota-only blockers); KAI (podgroups+fair-share queues, consolidation, hierarchical gangs, Grove/Dynamo integration 2025-11, DRA GB200/300). Series pick = Kueue; Volcano = DRA quota; KAI = NVIDIA fleet. Gang needed only for multi-pod launches (multi-node TP/PP/EP, P/D pools, Ray); not for single-node TP. |
| 2026-10-03 (goal round 8) | A9 | D2 | `notes/A9-node-pools-taints-placement-groups.md`, LAB 01 step 10 added | Verified: Karpenter `placementGroupSelector` (one NodeClass = one PG; cluster/partition/spread strategies; PlacementGroupReady gate; consolidation simulation), cluster PG single-AZ w/ 10 Gbps single-flow (vs 5 outside), same-instance-type advice, ODCR-in-PG reservation (zonal RIs can't); Karpenter native ODCR/Capacity-Block/Interruptible support (v1.3/1.6/1.10, `ReservedCapacity` gate, `capacity-type: reserved`, reserved modeled free, capacity-block drain 10 min before EC2 termination, no open matching when enabled); Auto Mode open-matching default; Capacity Blocks auto-placed close in UltraClusters; `karpenter.sh/do-not-disrupt` semantics (voluntary only; PDB complement; vLLM = weights reload + KV cache loss); one-PG-per-AZ → one NodeClass per AZ for multi-AZ fleets. |
| 2026-10-03 (goal round 9) | A10 | D2 | `notes/A10-model-storage-weight-loading.md`, LAB 01 step 11 added · **Cluster A complete (10/10)** | Verified: sleep-mode levels (L1 = weights→CPU RAM + KV discarded; L2 = both discarded, restore via wake_up tags=weights + collective_rpc reload_weights; endpoints gated behind VLLM_SERVER_DEV_MODE=1 + --enable-sleep-mode); runai_streamer loads from s3:// directly; Mountpoint-S3 defaults = instance-bandwidth ceiling, --maximum-throughput-gbps, --max-threads 16, 8 MiB parts, ≤2 GiB prefetch/file, CSI cache + agent-not-ready taint; safetensors mmap-over-networkFS pathology quantified (94 min→14 min eager on Lustre; 4 h for 7B on GCSFuse; 130→542 GiB/node CPU peak; warm page cache ~100 s→~1 s). Fermi load table written; LAB 11 to measure. Cluster A done → article 01/02 topics all at D2. |
| 2026-10-03 (goal round 10) | B1 | D2 | `notes/B1-nvlink-nvswitch-pcie.md`, LAB 01 step 12 added | Verified: NVLink gen table (900 GB/s/18 links Hopper; 1.8 TB/s/18 Blackwell; 3.6 TB/s/36 Rubin; domains 8 → 72 GB200 130 TB/s → Vera Rubin NVL72 260 TB/s); HGX H100 = 4× gen-3 NVSwitch @ 25.6 Tbps each, non-blocking 900 GB/s all-to-all (20 GB ≈ 22 ms example); NVLink SHARP/NVLS = NCCL ≥2.17 algo w/ NVSwitch arithmetic offload + multicast (CUDA 12.1 cuMulticast, multimem PTX), allreduce busbw ~370→~480 GB/s; MIG P2P same-GPU-only (R570+); topo -m legend (NV##/PIX/PXB/PHB/NODE/SYS) + NIC-GPU PIX affinity; PCIe Gen5 x16 ≈ 64 GB/s/dir = the 14× cliff. Cluster B begun. |
| 2026-10-03 (goal round 11) | B2 | D2 | `notes/B2-bandwidth-hierarchy.md`, **`labs/03-gpu-anatomy/LAB.md` created** | Verified: HBM ladder (H100 3.35 / H200 141 GB @ 4.8 / B200 180 GB @ 8 TB/s; HGX node aggregates 38.4/64 TB/s; B300 288 GB); NVIDIA spec lists PCIe Gen5 as 128 GB/s *bidir* (=64/dir); p5 ENA = 100 Gbps (1 ENA) → 800 Gbps (8-ENA pattern); nccl-tests busbw factors (AllReduce 2(n−1)/n; RS/AG/A2A (n−1)/n; B/R =1) + tree/NVLS hierarchical caveat (busbw = flat-fabric equivalent). Hierarchy table (10 rows) written with measurement protocol; measured column → LAB 03 run. |
| 2026-10-03 (goal round 12) | B3 | D2 | `notes/B3-topo-nvlink-fabric-logs.md`, LAB 03 step 1 extended | Verified: diagnostic triad (shape/state/trust): topo -m/-mp legend + CPU-affinity + NIC columns (multi-root-complex SYS quirk; >1 min runtime); nvlink --status/-e/-p per-link state + error counters (NVML APIs incl. utilization rx/tx + resets); fabric section of nvidia-smi -q (state Completed/In Progress/Not Started + probe NVML_SUCCESS; health summary fields Bandwidth-degraded/Route-Unhealthy/etc.); fabricmanager.log default /var/log/fabricmanager.log + nvlsm state files; SXid = NVSwitch events vs Xid = GPU driver events (Xid 74 = NVLink); failure playbook (uncorrectable → reseat/bridge/RMA, CUDA_VISIBLE_DEVICES workaround; Ampere FM-reset rule vs Hopper+ relaxation); K8s access per AMI strategy (Bottlerocket chroot, AL2023 SSH; continuous = DCGM). |
| 2026-10-03 (goal round 13) | B4 | D2 | `notes/B4-instance-anatomy.md` | Verified full anatomy table: p5/p5e (32 EFA IFs, EFAv2, 3.2 Tbps, IP ≤800 Gbps), p5en (16 IFs, EFAv3/Nitro v5, −35% latency), p6-b200 (8×400 Gbps EFAv4, 1440 GB HBM, 1800 GB/s P2P NVLink5), p6-b300 (2144 GB, 6.4 Tbps), p6e-gb200.36xl (UltraServer-only: u-x36/x72 = 36/72 GPUs in ONE NVLink domain, 28.8 Tbps EFA, 130 TB/s domain, Capacity Blocks in DFW-2a Local Zone, superchip = 2 Blackwell + 1 Grace @ 372 GB); GB300 NVL72 GA 2025-12-01 (1.5× vs GB200). Structural: NVLink-across-instances exists only via UltraServers; EFA interface count shrinks 32→16→8 as per-interface BW grows; EFA generation = part of the NCCL tuning matrix. |
| 2026-10-03 (goal round 14) | B5 | D2 | `notes/B5-mig-timeslicing-mps.md`, LAB 03 step 9 added | Verified: sharing-mechanism table (MIG = HW partition w/ memory+fault isolation, H100 profiles 7×1g.10gb etc.; time-slice = compute interleave, NO memory/fault isolation, replicas = access grants not proportional compute, renameByDefault/failRequestsGreaterThanOne semantics, one config per node, GPU Operator ignores config-map edits, DCGM container-metrics broken under it; MPS = per-client address spaces, 1 server/user, ~60 contexts/server, -multiuser-server drops isolation, mem cap = equal fraction via control daemon; TS×MPS mutually exclusive); vLLM×MIG bug #41848 (CUDA_VISIBLE_DEVICES=MIG-<uuid> crash; numeric-ID trap = parent-GPU memory; fix #41850 → #46132 NVML-by-UUID, e2e on A100 2g.10gb); verdict: best sharing = bigger batch; MIG for multi-tenant small models; TP across slices impossible. |
| 2026-10-03 (goal round 15) | B6 | D2 | `notes/B6-dcgm-health-metrics.md` · **Cluster B complete (6/6)** | Verified: metric families mapped to topics (PROF_DRAM_ACTIVE = HBM roofline; per-gen NVLink counter naming pre-Hopper/Hopper/Blackwell+; NVLINK_BANDWIDTH_TOTAL/L0; XID + new DCGM_EXP_XID_ERRORS_COUNT/TOTAL, EXP_GPU_HEALTH_STATUS w/ severity labels, EXP_P2P_STATUS per pair; remapped rows + ECC SBE/DBE; clock events); dcgm-exporter = KubeletPodResources pod mapping + ServiceMonitor (helm nvidia.github.io/dcgm-exporter); **Auto Mode answer: amazon-cloudwatch-observability add-on manages DCGM exporter + collects GPU *and EFA* metrics by default** (v1.3.0-eksbuild.1 / agent 1.300034.0; opt-out accelerated_compute_metrics=false) vs self-managed Prometheus path. A1/A2 deferred DCGM question answered. 8-metric dashboard recipe written. |
| 2026-10-03 (goal round 16) | C1 | D2 | `notes/C1-ena-efa-efa-only-infiniband.md`, LAB 03 step 5 extended | Verified: SRD design story (relaxed in-order delivery → no head-of-line blocking → p99 tail ↓~10×; packet spray 64-of-thousands paths; Nitro-card implementation; UD-like QPs w/ reliability, O(p) connectivity; "MPI should just work" via libfabric); why no IB on AWS (always-on multitenancy, Ethernet investment, no maintenance windows); measured EFA-vs-IB gaps (latency ~20× worse <512 B / 10× at 8 kB; depth ≈256 + ≥8 kB to saturate; ~2 M msg/s per NIC PU vs 17 M RC) + implication for LLM collectives (deep bulk pipelines fine); ENA Express = SRD for TCP/UDP (cross-AZ OK, 5→25 Gbps single flow, UDP opt-in, MTU cost, fallback semantics); IB/RoCE/Ethernet latency context (~0.9/1.0/12.7 µs @ 8 B). Cluster C begun. |
| 2026-10-03 (goal round 17) | C2 | D2 | `notes/C2-srd-protocol-depth.md` | Verified (Amazon Science paper): SRD congestion control = fair share w/ minimum in-flight bytes, per-connection rate limit + inflight limit, ACK-timing rate estimation, congestion = RTT up on majority of paths (BBR-like); path selection via encapsulation-manipulated ECMP; reroute-on-retransmit w/o routing convergence; FCT results (TCP median +50%, tail 1–2 orders; SRD median +15%, max < TCP avg); QP semantics (UD-like + reliability, at-most-once, AH, no segmentation); ordering restored by libfabric efa RDM reassembly (send-after-send; 128B-aligned opt-in; FI_EFA_RECVWIN_SIZE window = error if exceeded); efa vs efa-direct fabrics (emulations vs native, MTU ~8 KiB cap); fair-share ~2 Gb/s/flow @100 Gb/s; UEC/UET standardizing spray + flexible ordering + receiver-credit CC + packet trimming (SRD was early). SRD itself = no host knobs. |
| 2026-10-03 (goal round 18) | C3 | D2 | `notes/C3-libfabric-consumers-mpi-nccl-nixl.md` | Verified: aws-ofi-nccl v1.21.1 (tested NCCL v2.31.2-1, compat ≥2.17.1; net v12 interface since v1.20; **two modes: host-proxy vs EFA GDA kernel backend — NCCL rings NIC doorbell from GPU, requires NCCL ≥2.31.2-1 + GDRCopy ≥2.5 + libfabric ≥2.6**); plugin loading = NCCL_NET_PLUGIN=ofi → libnccl-net-ofi.so (vs NCCL_NET = impl-by-name; unset → dlopen default w/ silent TCP fallback); version-matrix example (HyperPod efa1.31/libfabric1.18.2/nccl2.20.3/ofi1.8.1); UCX-on-EFA (UD-over-verbs + SRD AM/get; 2021 12 GB/s, 10× vs TCP; historical no-RDMA-WRITE; **ucx#10966 GDR detection: efa_nv_peermem/dmabuf checks → software-emulation fallback on p5/p5en**; UCX_CUDA_COPY_DMABUF); NIXL plugin architecture (UCX/GDS/LIBFABRIC backends, agent + getPublicData metadata) + AWS recipe `backends:["LIBFABRIC"]` (note: AWS example uses deprecated kv_both → prefer producer/consumer [V]). |
| 2026-10-03 (goal round 19) | C4 | D2 | `notes/C4-rdma-gdr-gda.md`, LAB 03 step 4 extended | Verified: three fast paths (GDR = NIC DMA↔GPU mem; GDA = GPU-initiated WQ/doorbell control path, CPU out of critical path — IBGDA numbers: 9.5× <1 KiB, 180 MOPS put rate, saturation @2 KiB w/ 64 CTAs; GDRCopy = host↔GPU BAR1); support matrix (RDMA read all Nitro v4+, write most, **GDR/GDA only select instances — m8-class EFA = GDR No**); peermem lineage (nv_peer_mem deprecated → nvidia_peermem in-driver → **DMA-BUF recommended** (ibv_reg_dmabuf_mr, no perf delta); EFA's own `efa_nv_peermem` via nv-p2p API, build-flag -DENABLE_P2P); GDA on AWS = aws-ofi-nccl v1.21 kernel backend; EKS enablement table (EKS-AMI: efa_nv_peermem auto; GPU Operator: driver.rdma.enabled or dmabuf default; UCX/NIXL detection w/ silent software-emulation fallback; MNNVL cumem needs UCX_CUDA_IPC_ENABLE_MNNVL + --enable-cumem-allocator). |
| 2026-10-03 (goal round 20) | C5 | D2 | `notes/C5-efa-operational-constraints.md` | Verified official limitations list verbatim: RDMA write not on all types; **P4d/P4de/DL1 ↔ other instance types EFA traffic unsupported (mixed-fleet trap)**; 1 EFA device per card (else 1/instance); EFA traffic can't cross AZ/VPC; **EFA traffic not routable**; no Outposts; Windows = CDI-SDK only, EFA-only unsupported. Attach: launch-time or stopped-instance only, no subnet moves → node replacement required to change EFA layout. SG = self-referencing all-traffic rule (protocol -1, source-group self) + security-review rationale (EFA not IP-routable, SG = only fabric policy control). MTU: EFA ≈ 8 KiB SRD, FI_EFA_MTU_SIZE/FI_EFA_RX_WINDOW_SIZE knobs, ENA jumbo 9001 = IP path only. ENA Express ≠ EFA recap. EFA-IMDS [V at publish]. |
| 2026-10-03 (goal round 21) | C6 | D2 | `notes/C6-ib-context-nccl-tuning.md` · **Cluster C complete (6/6)** | Verified: NCCL topology files (static XMLs under /opt/aws-ofi-nccl/.../xml/; auto-set w/ --enable-platform-aws + "NET/OFI Configuring AWS-specific options" log; **v1.19.0 (Apr 2026) auto-generates P5 topology from detection + fixed GB200-in-Docker NUMA bug**); NCCL env semantics (NCCL_NVLS_ENABLE 1/2/0 — 2 = silent disable on ranks-per-GPU>1, 1 = init failure; NCCL_ALGO function-scoped lists; NCCL_SOCKET_IFNAME prefixes/=/^ with kernel-routes-source subtlety + same-subnet multi-NIC breakage nccl#1580 + NCCL_OOB_NET_*); OFI_NCCL_* runtime table (SENDRECV vs RDMA protocol, multi-rail FORCE_NUM_RAILS + MIN_STRIPE 128 KiB, GDR checks/flushes, MR cache, CQ 12288, eager auto-detect v1.20); legacy set (FI_PROVIDER/NCCL_PROTO) = ≤1.5 only; VPC CNI multi-NIC (ENABLE_MULTI_NIC + nicConfig annotation; skips efa-only cards; not on Auto Mode). IB context recap → C1. Modern stack needs no required NCCL envs. |
| 2026-10-03 (goal round 22) | D1 | D2 | `notes/D1-nvidia-library-role-matrix.md` | Verified (vLLM attention-backends doc): default = first-compatible in priority list, errors list incompatibilities; Blackwell priority = FLASHINFER (native+XQA+trtllm-gen) → FLASH_ATTN (FA4 default SM100+) → TRITON/FLEX/TURBOQUANT; Hopper = FLASH_ATTN (FA3) first; MLA family incl. TRT-LLM Ragged + DeepSeek-V4 sparse MLA; FP8 GEMM chain = FlashInfer/DeepGEMM hybrid (Hopper) → DeepGEMM → CUTLASS → Marlin → Triton → PyTorch, logged "Selected for"; --linear-backend vs --moe-backend split; Machete = CUTLASS-based Marlin successor (Hopper w4a16, prepacked); **DeepEP V2 = NCCL-Gin backend (was NVSHMEM in V1), fewer SMs, JIT compile, NVLink 643–740 GB/s SM100**; cuDNN Frontend 9.18 SDPA = paged-attn + FP8 capable but NOT in vLLM default backends; cuBLAS = fallback. Doubt #3 resolved: NCCL = collectives; cuDNN = capable guest star; cuBLAS = floor. |
| 2026-10-03 (goal round 23) | D2 | D2 | `notes/D2-ami-vs-container-responsibilities.md` | Verified: two-layer contract (host/AMI = kernel modules nvidia/efa/efa_nv_peermem/gdrcopy + driver user-space libcuda/NVML + toolkit; container = CUDA runtime + kernels, NO driver/libcuda); injection via CDI (toolkit ≥1.12, JIT-CDI, nvidia-cdi-refresh) or prestart hook; NVIDIA_DRIVER_CAPABILITIES = **replace** not add (compute/utility default); NVIDIA_VISIBLE_DEVICES semantics (all/none/void); Bottlerocket = cdi-cri default; CUDA compat rules (minor-version compat = same-major on newer driver w/ PTX JIT; forward compat = cuda-compat-<maj>-<min> across majors, NO PTX JIT, table 535→615; EKS 1.34+ = driver 580/CUDA 13+); failure catalog (NVML version mismatch → relaunch containers/reboot/modprobe -r; libcuda missing = capability trap; forward-compat escape hatch). Driver upgrades = node events (drift/BRupop) vs GPU Operator driver containers. |
| 2026-10-03 (goal round 24) | D3 | D2 | `notes/D3-cuda-graphs-torch-compile.md` | Verified: five cudagraph modes (NONE/PIECEWISE/FULL/**FULL_DECODE_ONLY**/**FULL_AND_PIECEWISE = V1 default**) + dispatcher design (priority FULL>PIECEWISE>NONE, batch-descriptor keys, nested wrappers, per-backend downgrade, min-capability for hybrid models); capture economics (auto sizes [1,2,4]+range(8,256,8)+…, max=min(max_num_seqs×2,512), padding, warmups, LoRA-specialized graphs, ~64 KB/launch/graph memory from PyTorch docs); Inductor integration (Dynamo-once + per-shape compiles w/ AlwaysHitShapeEnv, use_inductor_graph_partition @ cudagraph_unsafe ops = N+1 partitions); fusion-pass table w/ measured gains (AllReduce+RMSNorm 5–20% @O2 TP>1; AsyncTP GEMM+collective 7–10%; RMSNorm+Quant 1–4%; Attn+Quant fullgraph-only) + fullgraph-vs-piecewise conflict (splitting_ops=[] fallback). Config: --enforce-eager, --compilation-config JSON. |
| 2026-10-03 (goal round 25) | D4 | D2 | `notes/D4-gpu-operator-vs-ami-bundled.md` | Verified: three management models (AMI-bundled = driver in AMI + separate plugins, upgrades = node replacement; GPU Operator = driver container + full operand set via ClusterPolicy, upgrades = **in-place upgrade controller w/ state machine on nvidia.com/gpu-driver-upgrade-state** (cordon→pod-deletion→drain-fallback→pod-restart→validation; autoUpgrade pause, waitForCompletion, drain last-resort; legacy k8s-driver-manager deprecated; client workloads auto-restarted via gpu.deploy.client); Auto Mode = AWS-managed, no DRA). Operator v26.7: **GPUCluster CRD = DRA driver + ComputeDomains + DCGM managed by operator (mutually exclusive w/ ClusterPolicy; k8s ≥1.34.2, driver 580+, CDI)**; KubeVirt+DRA VFIO passthrough (containers+VMs same node); DRA driver v25.3.0 MNNVL+IMEX; operands incl. GFD/GDRCopy/GDS/KubeVirt/vGPU/ccManager; EKS constraints (no AL2 mix; eksctl can't provision non-AL2 MNG). |
| 2026-10-03 (goal round 26) | D5 | D2 | `notes/D5-dcgm-gfd-driver-daemonsets.md` · **Cluster D complete (5/5)** | Verified: GFD merged into k8s-device-plugin (v0.15+; gfd.enabled=true auto-pulls NFD; standalone mode via devicePlugin.enabled=false; standalone repo archived); DCGM exporter 4 deployment modes (package/standalone container/Helm/GPU-Operator-default w/ operator-owned ConfigMap + internalTrafficPolicy); driver DaemonSet anatomy (privileged pods, hostPID/hostIPC; sidecars: nvidia-driver-ctr [init, /run/nvidia bidirectional mount, startup probe, preStop marker], **nvidia-peermem-ctr [reload_nvidia_peermem on MOFED reinstall]**, nvidia-fs-ctr [GDS], nvidia-gdrcopy-ctr [gdrdrv]; legacy k8s-driver-manager envs); classic failures (nouveau blocks nvidia module; operands stuck Init until driver+toolkit healthy; internet needed for runtime packages; CRI-O v25.10 transient Inits). Cluster D done → article 05 topics all at D2. |
| 2026-10-03 (goal round 27) | E1 | D2 | `notes/E1-vllm-v1-process-model.md` | Verified (arch overview + current sources): V1 process model = API server(s) [InputProcessor/OutputProcessor/detokenizer/output_handler; --api-server-count, auto-scales w/ DP, many-to-many ZMQ; VLLM_MEDIA_LOADING_THREAD_COUNT=8] ⇄ EngineCore per DP rank [busy loop: input queue→counts→step→outputs; ZMQ DEALER inputs + XSUB coordinator outputs on background threads; DP coordinator stats; fault-tolerance sentinel; tensor-IPC for multimodal; elastic EP; world_size = TP×PP×PCP] → MultiprocExecutor [rpc_broadcast_mq (ZMQ) + **SchedulerOutput via shared-memory handle** + per-rank response MQs; NUMA-bound workers; driver_worker; health monitor]; **async scheduling default-on** (PR #27614; auto-off for PP + spec decode; execute_model/sample_tokens split; CPU→GPU input-token copy NOT overlapped); frontend scaling per-API-server-rank caching (PR #23717). Cluster E begun. |
| 2026-10-03 (goal round 28) | E2 | D2 | `notes/E2-paged-attention.md` | Verified (SOSP'23 paper + V1 source): block tables (entry = physical block + #filled), left-to-right fill, per-layer/head separate blocks+tables (deliberate), internal fragmentation ≤ 1 block, external eliminated, 2–4× vs FasterTransformer/Orca, CoW on shared blocks (ref counts; PR #32 single block-copy kernel); paper's 7-token worked example; **V1 KVCacheManager**: DEFAULT_BLOCK_SIZE 16 (DSA/hybrid → block_size 1 / per-group sizes), gpu_memory_utilization default 0.92, allocate_slots signature = series ToC (num_lookahead_tokens = spec decode; num_external_computed_tokens + delay_cache_blocks = P/D connectors; full_sequence_must_fit admission gate; reserved_blocks = async-connector gating; watermark_blocks anti-preemption-storm; free-in-reverse; non-committable draft tokens excluded from cache commits); hybrid KV cache groups (full/sliding-window/mamba; Unitary/Hybrid/NoPrefixCache coordinators; SW needs last sw−1 tokens); **prefix_match_unit = hash_block_size finer than physical block → cache hits inside blocks**. |
| 2026-10-03 (goal round 29) | E3 | D2 | `notes/E3-continuous-batching-chunked-prefill.md` | Verified: Orca (iteration-level scheduling + selective batching; 36.9× vs FasterTransformer GPT-3 175B); Sarathi-Serve (generation stalls — vLLM prefills-first, stall up to seconds; naive hybrid batching up to 28.3× TBT inflation; chunked prefill ≈512-token chunks saturate compute; stall-free batching order = running decodes → partial prefills → admit; combined 2.6×/3.7×/5.6× capacity; uniform batches shrink PP bubbles); V1 scheduler internals (token_budget loop over running; num_new_tokens = with_spec + placeholders − computed; long_prefill_token_threshold; mamba block-aligned split; encoder compute budget; preemption: FCFS pops newest, PRIORITY preempts max(priority, arrival), continue-not-break so lower priority still schedules); SchedulerOutput anatomy (scheduled_new_reqs cached-in-workers vs scheduled_cached_reqs **diffs**, num_scheduled_tokens, spec tokens, encoder inputs, num_common_prefix_blocks [cascade attention], finished/preempted ids, structured-output flags for async scheduling, num_invalid_spec_tokens, kv/ec_connector_metadata, **new_block_ids_to_zero**); defaults trap (2048/128 = test defaults; real set in create_engine_config; batched-DP 256; validation rules max_num_batched_tokens ≥ max_model_len w/o chunked prefill, ≥ max_num_seqs). |
| 2026-10-03 (goal round 30) | E4 | D2 | `notes/E4-prefix-caching.md` | Verified: hash chain = hash(parent, block_tokens, extra_keys) — extra keys incl. LoRA/mm/prompt-embeds/**cache_salt (first block only)**; hash_block_size rules (single group = block size; multi-group = GCD or prefix_match_unit override w/ divisibility ValueError; mamba non-align backoff; hashing active for KV connectors too); hash algorithms (--prefix-caching-hash-algo: sha256 default since v0.11 w/ pickle non-reproducibility; sha256_cbor recommended reproducible; xxhash/xxhash_cbor fast w/ collision-leak warnings); **deterministic seed → identical hashes across independent processes → cross-node KV reuse w/o config**; cache_salt = timing-attack isolation; eviction = FreeBlockQueue intrusive LRU (ref-0 first, deepest-chain-tail tiebreak = RadixAttention-equivalent policy; free-in-reverse maintains order); metrics = prefix_cache_queries/hits counters (not gauge; PromQL rate hit formula; 1k-recent log rate); APC = prefill-only accelerator (long-doc/multi-round); Fermi hit-rate math (2k-token prompt ≈ 128 blocks ≈ 100–200 ms TTFT saved per hit @ 8B/H100). |
| 2026-10-04 | Design brief (applies A–E4 research to one deployment) | — | `deployment/qwen3.8-27b-hosting-design.md` | **Qwen3.8-27B hosting decisions**: FP8 weights + FP8 KV (NVFP4 only on Blackwell — g7e/p6 candidates; Marlin-W4A16 trap on Hopper/Ada); **single GPU** (AWS has no 2-GPU L40S/H100 shapes; TP=8 H100 ≈$55/hr oversized); primary = p5.4xlarge 1×H100 $6.88/hr (≈85 seqs @4k w/ FP8-KV) or g6e.2xlarge 1×L40S $2.24/hr (≈30 seqs), spot floors $0.5–3.4; P/D = no (flip conditions listed); llm-d = not yet (trigger: ≥3 replicas + shared prefixes); native **MTP head** → spec decode for TPOT; prefix caching on + explicit `max_num_batched_tokens 8192` (test-defaults trap); sleep mode for scale-to-zero; cost formula + [E] table ($/1M out tokens ≈ $0.25–0.45 on B, $0.27–0.50 on A; spot ÷2); open [V]s = g7e pricing + NVFP4-on-sm120 support, exact config.json (param count/layer mix), KV/token for hybrid layout, MTP acceptance rate, Qwen3.8 FP8 checkpoint name. |
| 2026-10-04 (rev 2) | Design brief verification pass | — | `deployment/qwen3.8-27b-hosting-design.md` (rewritten) | **All [V]s resolved**: config.json exact — 64 layers = 48 GDN + 16 gated-attn (interval 4), GQA-4 head_dim 256, ssm fp32; **KV = 64 KiB/token BF16 → 32 KiB FP8 (half of dense-32B, as suspected) BUT GDN state ≈ 142 MiB fp32/seq constant (the real concurrency tax: 48 GB ⇒ ~16 seqs @4k)**; official **Qwen3.8-27B-FP8 exists** (block-128); **g7e verified**: GA 2026-01-20 us-east-1/2, RTX PRO 6000 Blackwell 96 GB/GPU, 1-GPU sizes ($3.36/$4.00/$5.27), **g7e.12xlarge = 2-GPU TP=2 shape** (corrects "no 2-GPU shape" — true only for g6e/p5), 2.3× vs g6e, ~$33/8-GPU; SM120 ≠ SM100 (JIT-only NVFP4 dense w/ FLASHINFER_CUDA_ARCH_LIST=12.0f else silent Marlin; MoE via flashinfer_b12x opt-in; lna-lab patches; Qwen3.5-27B dense NVFP4 ≈57 tok/s on RTX PRO 6000); P5 OD cut 44% (Jun 2025) → p5.4xlarge $6.88 confirmed. **Rev-2 verdicts**: tier-2 = g7e.4xlarge $4.00 (96 GB Blackwell, FP4-ready, 58% of p5.4xlarge price), tier-3 = g7e.8xlarge + NVFP4 W4A4 after JIT validation; final 12-row decision table w/ alternatives; 10-step fresh-account bootstrap checklist; Phase 1 = 1-GPU + Karpenter, Phase 2 = llm-d/P-D gates. |
| 2026-10-04 | Phase-1 deploy kit (manifests) | — | `labs/deploy-qwen3.8/` (README, cluster.yaml, karpenter/{ec2nodeclass,nodepools}, device-plugin-values, s3-weights.sh, vllm/{deployment,service,autoscale}, validate/bench-and-gate.sh) | Runnable Phase-1 kit: EKS 1.36 + addons (EBS CSI + Pod Identity Agent; tiny CPU MNG for addons); Karpenter v1.14 w/ EC2NodeClass `al2023@latest` (NVIDIA variant auto-resolve [V first launch]) + NodePools: CPU small / GPU on-demand (g7e.2xl+4xl, taint, gpu≤4, WhenEmpty, 1-node budget) / GPU spot burst (burst taint, g6e/g7e 1-GPU); device-plugin helm values (gfd+nfd auto, nodeSelector nvidia.com/gpu.present, MOFED note); s3-weights.sh (bucket + hf download sync + S3-read role + Pod Identity for vllm SA); vLLM Deployment = exact flag set (FP8-KV, MTP n=2, 8192 batched tokens, 64 seqs, 0.92 util, prefix caching, runai_streamer s3://, sleep-mode env present-but-commented, /health probes w/ 10-min startup, do-not-disrupt + PDB maxUnavailable 0); KEDA ScaledObject (1→4 @ sum(num_requests_running)/40) + HPA alternative; bench-and-gate.sh (probe → curl → concurrency sweep 8/16/32/64 ISL2048/OSL512 → tier-gate criteria + metrics to record). Phase-2 (llm-d/P-D) explicitly deferred per §8 gate. |
