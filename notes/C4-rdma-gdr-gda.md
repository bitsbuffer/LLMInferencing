# C4 — RDMA on AWS: RDMA read/write, GPUDirect RDMA (GDR), GPUDirect Async (GDA)

> Tracker: C4 · Status: covered (D2) · Date: 2026-10-03
> Scope: the GPU↔NIC fast paths behind "bypassing the CPU" — what each is, the memory-registration
> story, the instance-support matrix, and the EKS enablement path. Feeds article 04; powers
> article 13 (NIXL KV transfer). Your doubt T5's core.

## 1. The three fast paths (don't conflate them)

| Path | What it is | Consumer examples |
| --- | --- | --- |
| **GPUDirect RDMA (GDR)** | NIC DMA reads/writes **GPU memory** directly (kernel-registered) | NCCL (via peermem/dmabuf), NIXL/UCX KV transfers, IBGDA data plane |
| **GPUDirect Async (GDA)** | The **control path**: GPU SMs build WQs/doorbells themselves — CPU out of the critical path | aws-ofi-nccl v1.21 "kernel backend (EFA GDA)", NVSHMEM IBGDA |
| **GDRCopy** | Host↔GPU copies over BAR1 (not networking) | completion-flag delivery in proxy paths; storage staging |

EFA verbs semantics: **RDMA read** on all Nitro v4+; **RDMA write** on most Nitro v4+ (not all!);
**GDR and GDA only on select Nitro v4+ instances** — and the support table is brutal in detail:
general-purpose EFA instances (m8a/m8i/m8g…) support RDMA read/write but **GDR = No**; it's the
P/G HPC families that carry GDR/GDA. Never assume "it has EFA" ⇒ "it has GPUDirect".

## 2. Memory registration — the peermem lineage (verified)

- **Legacy**: `nv_peer_mem` (deprecated since CUDA 11.5) → replaced by the open-source
  **`nvidia_peermem`** kernel module shipped *with the NVIDIA driver* (drop-in; registers GPU
  memory with the kernel so NICs can map it).
- **Modern, recommended**: **DMA-BUF** — CUDA exports an fd; NICs register it via
  `ibv_reg_dmabuf_mr`. NVIDIA explicitly recommends DMA-BUF over peermem (no perf delta per
  driver-team answers; it's the open Linux framework replacing the proprietary VA/PA module).
- **EFA's own implementation**: amzn-drivers implement GDR against NVIDIA's **nv-p2p API**
  (`efa_nvmem_impl_v1/v2`, `nv-p2p.h`) — and the EFA installer ships an **`efa_nv_peermem`**
  module (the one UCX checks at `/sys/module/efa_nv_peermem/version`). P2P is a build-time
  feature (`-DENABLE_P2P=0` disables).

## 3. What GDA actually does (verified via NVSHMEM IBGDA — same architecture)

- **Proxy path (the old way)**: GPU kernel → descriptor into *host-memory* proxy buffer → CPU
  proxy thread posts WR + rings the doorbell → NIC GDR-reads GPU data → transfer → CQ → CPU
  notifies GPU (GDRCopy flag). The CPU is a serialization bottleneck (NVSHMEM: scaling stopped
  at ~4 CTAs).
- **Kernel-initiated (GDA/IBGDA/GDAKI)**: GPU SM writes the WQ **in GPU memory**, updates the DBR,
  writes the NIC doorbell register directly; NIC reads WQ+data via GDR and posts completion to a
  GPU-memory CQ. **CPU fully out of the critical path.**
- Numbers (IBGDA on ConnectX-6): **up to 9.5× throughput** for <1 KiB puts; put rate ≈ 180 MOPS
  (NIC peak 215 MOPS); bandwidth saturates at ~2 KiB messages with 64 CTAs. That's why small-
  message GPU collectives on IB and now EFA-GDA change character completely.
- On AWS: aws-ofi-nccl **v1.21+ kernel backend = EFA GDA** — NCCL rings the EFA doorbell from the
  GPU where supported; requires NCCL ≥2.31.2-1, GDRCopy ≥2.5, libfabric ≥2.6.0.

## 4. Enabling it on EKS (verified)

| Stack | GDR registration | Notes |
| --- | --- | --- |
| EKS-optimized AMI (no GPU Operator) | EFA installer's **`efa_nv_peermem`** (auto) | verify: `/sys/module/efa_nv_peermem/version`, `lsmod` |
| NVIDIA GPU Operator | default = DMA-BUF (recommended); legacy peermem via `--set driver.rdma.enabled=true` (adds `nvidia-peermem-ctr` container; `driver.kernelModuleType=open` pre-R570) | init container waits for NIC drivers |
| UCX/NIXL consumers | auto-detect: dmabuf → peermem modules; **silent software-emulation fallback if neither** (ucx#10966) | `UCX_CUDA_COPY_DMABUF` lever |
| NIXL MNNVL (GB200) | KV cache as VMM + `UCX_CUDA_IPC_ENABLE_MNNVL`, `--enable-cumem-allocator`/`--enable-sleep-mode` (vLLM) | else RDMA/TCP only |

## 5. Doubt questions (from doubt map A15) → status

| Question | Status |
| --- | --- |
| Enable peermem on EKS + verify? | **Answered** (§4); verification = module presence + a NIXL/NCCL bench — LAB 13 runs it [D3 pending]. |
| KV transfer bandwidth: RDMA vs TCP? | Directionally known (TCP fallback = dev-only per llm-d); measured delta **[LAB 13]**. |
| UCX-EFA env for NIXL? | Partially (§4); full env set captured at LAB 13. |
| MNNVL/cumem path? | **Answered** (§4, GB200-class only). |

## 6. Verified facts (sources, accessed 2026-10-03)

- Support matrix (read/write/GDR/GDA per instance, per EFA gen): [EFA docs](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html).
- EFA GDR implementation & nv-p2p: [amzn-drivers README](https://github.com/amzn/amzn-drivers/blob/master/kernel/linux/efa/README).
- peermem lineage & dmabuf recommendation: [GPUDirect RDMA installation](https://networking-docs.nvidia.com/gpudirectrdma/installation),
  [ibv_reg_dmabuf_mr discussion](https://forums.developer.nvidia.com/t/gpudirect-rdma-difference-between-ibv-reg-mr-and-ibv-reg-dmabuf-mr/262313/6).
- GDA/IBGDA internals + numbers: [NVSHMEM IBGDA blog](https://developer.nvidia.com/blog/improving-network-performance-of-hpc-systems-using-nvidia-magnum-io-nvshmem-and-gpudirect-async/),
  [DOCA GPUNetIO (GDAKI naming)](https://docs.nvidia.com/doca/sdk/DOCA-GPUNetIO/index.html).
- GPU Operator flags: [GPU Operator RDMA/GDS](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-operator-rdma.html).
- UCX detection gotcha: [ucx#10966](https://github.com/openucx/ucx/issues/10966).

## 7. Hands-on validation

LAB 03 **step 4 extension** (add peermem/dmabuf checks around the cross-node NCCL run: which
registration path engaged?) and **LAB 13** (NixlConnector P/D pair: RDMA vs TCP KV-transfer
bandwidth, GDR detection logs). Predictions to write: which module should be present on an
EKS-AMI p5 node; what UCX logs on a misconfigured node.

## 8. Blog angle

"Three fast paths and one silent fallback": the paths table, the IBGDA diagram (proxy vs SM-to-NIC),
the peermem→dmabuf timeline, and the instance-support matrix reality check ("EFA ≠ GPUDirect").
