# B1 — NVLink 4/5, NVSwitch, and the NVLink-vs-PCIe cliff

> Tracker: B1 · Status: covered (D2) · Date: 2026-10-03
> Scope: the intra-instance GPU interconnect — why TP loves it, what NVSwitch changes, where the
> domain ends. Feeds article 03 (and article 09's TP decision). Doubt map's NVLink section = this
> topic (tracker B1–B4).

## 1. Crisp understanding

**NVLink** = direct GPU-to-GPU serial interconnect (bidirectional, packetized, memory-coherent).
**NVSwitch** = switch chip(s) that turn per-GPU NVLink into an **NVLink domain** where *every* GPU
talks to *every other* GPU at full link speed, single-hop, non-blocking — no topology tax.
**PCIe** = the fallback: every peer pair traverses the host bridge hierarchy (with per-flow caps).

Why tensor parallelism cares: every transformer layer ends in an all-reduce whose traffic is
~`2 × hidden × bytes × (N−1)/N` per rank. At 900 GB/s (H100 NVLink 4) the all-reduce is a rounding
error; at PCIe ~64 GB/s per direction it dominates layer time. This is the whole reason article 09
shows TP=2 collapapsing on g6e (L40S, no NVLink) while flying on p5.

## 2. Verified numbers (the cliff, per generation)

| Generation | Architecture | Per-GPU NVLink | Links/GPU | NVSwitch domain | Aggregate |
| --- | --- | --- | --- | --- | --- |
| NVLink 3 | Ampere (A100) | 600 GB/s | 12 | 8 GPUs | (p4d: 600 GB/s interconnect) |
| NVLink 4 | Hopper (H100/H200) | **900 GB/s** | 18 | 8 GPUs (4× gen-3 NVSwitch, 25.6 Tbps each) | 7.2 TB/s per 8-GPU HGX |
| NVLink 5 | Blackwell (B200) | **1.8 TB/s** | 18 | 8 **or 72** GPUs | GB200 NVL72: **130 TB/s** |
| NVLink 6 | Rubin (Vera Rubin) | **3.6 TB/s** | 36 | 72 GPUs | Vera Rubin NVL72: **260 TB/s** |

- Hopper 8-GPU: all-to-all non-blocking at 900 GB/s *regardless of how many GPUs converse
  simultaneously*; NVIDIA's example: 20 GB transfer in ~22 ms vs ~150 ms over P2P PCIe.
- **PCIe Gen5 x16 ≈ 64 GB/s per direction** — a ~14× cliff vs NVLink 5, ~28× vs NVLink 6.
- Domain boundary: NVLink stops at the instance (or, for GB200-class rack systems, the NVL72
  rack via NVLink Switch trays). **On vanilla EKS nodes (p5/p6-b200), cross-node is always
  EFA/RDMA territory** (cluster C) — NVLink never crosses a node boundary there.

## 3. NVLink SHARP / NVLS (verified)

- NCCL ≥2.17's `NCCL_ALGO=NVLS` uses **NVLink SHARP** (NVLink-4 NVSwitch feature): arithmetic is
  **offloaded into the NVSwitch** and combined with **hardware multicast** (CUDA 12.1 multicast
  objects; `multimem.ld_reduce` PTX). NCCL runs dedicated NVLS kernels with load/store to
  multicast buffers (ucBuff → mcBuff reduce, mcBuff → ucBuff broadcast).
- Requires NCCL built against CUDA 12.1+ and H100/NVLink-4-class hardware. Measured effect:
  H100 allreduce busbw **~370 → ~480 GB/s**.
- Multi-node combinations (NVLS + IB SHARP) were still evolving when this was written — check
  NCCL release notes at publish time [V].
- Practical check in the lab: `NCCL_DEBUG=INFO` logs show `NVLS multicast support is available`
  and the chosen algo per collective.

## 4. MIG × NVLink (verified constraint)

With driver R570+: **P2P is supported only between MIG instances on the *same* physical GPU**;
MIG-instance↔MIG-instance across different GPUs, and MIG↔non-MIG devices, are not supported.
Consequence for serving: you cannot shard a TP group across MIG slices of different physical
GPUs — TP wants whole GPUs (MIG is for isolated small replicas, article B5). (vGPU footnote:
time-sliced vGPUs only for NVLink P2P; A100 had a UVM quirk reporting `PIX` instead of `NV12` —
not applicable to Hopper+.)

## 5. Reading `nvidia-smi topo -m` (the legend, verified)

| Code | Meaning |
| --- | --- |
| `NV##` | NVLink with ## links (e.g. NV18 = 18-link NVLink pair) |
| `PIX` | single PCIe switch hop |
| `PXB` | multiple PCIe switches, no host bridge |
| `PHB` | through a PCIe host bridge (CPU) |
| `NODE` | across PCIe host bridges **within** a NUMA node |
| `SYS` | across NUMA nodes (SMP/UPI interconnect) — the slowest path |

The NIC columns matter as much as GPU columns: on HGX boards, NICs sit `PIX`-adjacent to specific
GPU pairs (e.g. GPU0–3 ↔ NIC0–1) — that affinity is what DRA/DRANET topology-aware EFA pairing
(A5) encodes. The topology matrix is the ground truth for "who talks to whom at what speed" —
capture it in every article's screenshots.

## 6. Doubt questions (self-defined) → status

| Question | Status |
| --- | --- |
| Is NVLS active on p5 (H100 NVSwitch)? | Should be (H100+NVLink4); **[V]** in lab via NCCL_DEBUG logs + busbw delta. |
| Does NVLink span nodes on EKS? | **No** for p5/p6-b200 (cross-node = EFA); NVL72-class rack systems are the exception and not ordinary EC2 nodes [V — p6e-gb200 story]. |
| TP across MIG slices? | **No** — same-GPU P2P only (section 4). |
| NVLink domain size on our instances? | 8 GPUs (p5: 4× NVSwitch gen-3) — verified table above. |

## 7. Verified facts (sources, accessed 2026-10-03)

- Generations & domain sizes: [NVIDIA NVLink page](https://www.nvidia.com/en-us/data-center/nvlink/)
  (incl. NVLink 6 / Rubin NVL72 260 TB/s, hot-swap switch trays, partial-rack operation).
- Hopper NVSwitch details (4× gen-3, 25.6 Tbps each, non-blocking, 20 GB/22 ms example, P2P table):
  [NVIDIA blog](https://developer.nvidia.com/blog/nvidia-nvlink-and-nvidia-nvswitch-supercharge-large-language-model-inference/).
- NVLS internals + busbw: [nccl#807](https://github.com/NVIDIA/nccl/issues/807),
  [NCCL NVLink-SHARP deep dive](https://main-horse.github.io/translations/nccl/nvlink_sharp/).
- MIG P2P constraint: [MIG user guide](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/latest/deployment-considerations.html).
- topo legend: [NVIDIA forums legend](https://forums.developer.nvidia.com/t/strange-output-by-nvidia-smi-topo/68452/1),
  [B200 topology explorer](https://the-dsvolk.github.io/ai-perf/ai-infra/B200-explorer.html).
- PCIe Gen5 per-direction rate: standard spec; used in the plan's hierarchy table [V exact
  (63–64 GB/s) at lab via busbw measurement].

## 8. Hands-on validation (scheduled)

LAB 01 **step 12** (quick capture): `nvidia-smi topo -m`, `nvidia-smi nvlink -s`, and a
`NCCL_DEBUG=INFO` all-reduce to confirm NVLS. Full bandwidth matrix (intra vs cross-node) is
article 03's lab (`labs/03-gpu-anatomy/`, created at drafting time) — that's where B1–B4 get D3/D4.

## 9. Blog angle

"The 14× cliff": one generational table, one topology matrix read aloud, one NVLS busbw
measurement — then the punchline: everything beyond the NVLink domain belongs to article 04.
