# B5 — MIG, time-slicing, MPS for inference

> Tracker: B5 · Status: covered (D2) · Date: 2026-10-03
> Scope: the three GPU-sharing mechanisms, what isolation each buys, the inference-specific
> guidance (spoiler: the best sharing is a bigger batch), and the vLLM×MIG bug you'll hit.
> Feeds article 03 (+ sidebars in 06/07). Builds on A3 (DRA sharing) and B1 (MIG×NVLink P2P).

## 1. The three mechanisms (verified mechanics)

| | **MIG** | **Time-slicing** | **MPS** |
| --- | --- | --- | --- |
| What it is | Hardware partition: fixed memory/SM/L2/decoder slices | OS-level compute interleave via CUDA time-slice | Contexts merged server-side; Volta+ clients submit directly, server arbitrates scheduling |
| Memory isolation | ✅ per-slice (1g.10gb = 1/8 mem, 1/7 SMs on H100) | ❌ every replica sees all GPU memory — OOM & fault domain shared ("if one crashes, they all do") | Partial: per-client address spaces; memory cap per client = equal fraction via control daemon |
| Fault isolation | ✅ | ❌ same fault domain | `-multiuser-server` drops cross-user isolation; a fatal fault can take down clients sharing that GPU |
| K8s shape | device plugin `migStrategy: single|mixed` (GA); DRA static (GA) / dynamic (alpha, owns node MIG config) | `sharing.timeSlicing.resources[].replicas` (e.g. 8 GPUs × 10 = 80 advertised); `renameByDefault` → `nvidia.com/gpu.shared` or product label `…-SHARED`; `failRequestsGreaterThanOne` (recommended true) fails requests >1 with `UnexpectedAdmissionError` | `sharing.mps.resources[]`; Bottlerocket: `device-sharing-strategy: mps` |
| Sharp edges | TP impossible across slices (B1); DCGM exporter can't map metrics to containers under time-slicing | replicas ≠ proportional compute (equal time share to all clients); time-slice × MPS mutually exclusive; one config per node; GPU Operator ignores live config-map edits (restart plugin pods) | **1 MPS server per user** (control daemon serializes activations across UIDs); ~60 client contexts/server (CUDA_DEVICE_MAX_CONNECTIONS interplay); recommended compute mode: EXCLUSIVE_PROCESS |

H100 MIG profile table (verified): 7×`1g.10gb` (or 4×`1g.20gb`, 3×`2g.20gb`, 2×`3g.40gb`, 1×`4g.40gb`,
1×`7g.80gb`, 1×`1g.10gb+me`); H200: up to 7 MIGs @ 18 GB each.

## 2. The vLLM × MIG bug (verified, recent)

- `CUDA_VISIBLE_DEVICES=MIG-<uuid>` — NVIDIA's own recommended isolation method — **crashed vLLM
  at startup** (`int()` ValueError in `device_id_to_physical_device_id`) — issue #41848. Worse:
  the numeric-ID workaround made NVML report the **parent GPU's memory** (80 GiB instead of the
  slice's 20 GiB), breaking KV-cache sizing at load time.
- Fix path: PR #41850 → consolidated in **#46132** (UUID strings preserved; NVML looked up by
  UUID so capacity/name/NUMA report the *slice*; validated e2e on A100 MIG `2g.10gb`). Landmark:
  vLLM on MIG slices works on recent builds [V your pinned version].
- Consequence for DRA dynamic-MIG stories: this code path is exactly what device-plugin
  `migStrategy: mixed` UUID assignments exercise.

## 3. Inference guidance (the blog's verdict)

- **LLM serving rarely wants any of the three.** Decode is memory-bound and wants the full KV
  cache; the *actual* sharing mechanism of LLM serving is **continuous batching** (E3), not
  context multiplexing. Sharing a GPU three ways by MIG gives 3 replicas with ⅛ memory each —
  which usually just makes three slow servers.
- **MIG wins** for: multi-tenant small-model serving (7×1g.10gb = 7 isolated 10 GB servers on an
  H100), strict isolation/quotas, dev fleets. **Time-slicing** for: notebooks/dev/bursty sparse
  tenants (with `failRequestsGreaterThanOne=true`). **MPS** for: many small processes on one GPU
  *without* MIG (e.g., embedding micro-services); rarely for vLLM (already batches internally).
- DRA's **consumable capacity** (A3) is the modern cross-namespace sharing story; keep the
  device-plugin paths for the GA world.

## 4. Doubt questions → status

| Question | Status |
| --- | --- |
| Does vLLM run on MIG slices? | **Yes on recent versions** (post-#46132); use UUIDs; watch parent-GPU-memory trap on old builds. |
| Can TP span MIG slices? | **No** (B1 — same-GPU P2P only). |
| Time-slice replicas = fair compute split? | **No** — equal time share among all clients; replicas are access grants (§1). |
| DCGM under sharing? | Container-metric association broken under time-slicing — affects K2 dashboards [V]. |
| Per-GPU sharing configs? | **Not supported** — one method per node (§1). |

## 5. Verified facts (sources, accessed 2026-10-03)

- Time-slicing config semantics + DCGM caveat: [GPU Operator gpu-sharing](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-sharing.html),
  [k8s-device-plugin](https://github.com/nvidia/k8s-device-plugin) (sharing section).
- MPS architecture/limits: [when-to-use MPS](https://docs.nvidia.com/deploy/mps/when-to-use-mps.html),
  [MPS architecture](https://docs.nvidia.com/deploy/mps/610/architecture.html).
- H100 profile table: [MIG user guide](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/latest/supported-mig-profiles.html).
- vLLM×MIG: [vllm#41848](https://github.com/vllm-project/vllm/issues/41848),
  [PR #41850](https://github.com/vllm-project/vllm/pull/41850), [PR #46132](https://github.com/vllm-project/vllm/pull/46132).

## 6. Hands-on validation (scheduled)

LAB 03 **step 9** (new): enable static MIG `1g.10gb`×7 on one H100; serve Qwen3.5-0.8B on one
slice (predict: works post-#46132; NVML reports ~10 GB, not 80); attempt TP=2 across two slices
(predict: fails/NCCL error — same-GPU P2P only); run DCGM under time-slicing to show the
container-metric gap. This gives B5 its D3 evidence.

## 7. Blog angle

"The best GPU sharing is a bigger batch": lead with the continuous-batching-as-sharing thesis,
then the mechanism table, then the vLLM×MIG bug as the "cost of partitioning" case study.
