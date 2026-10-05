# C3 — libfabric & its three consumers: MPI, NCCL (aws-ofi-nccl), NIXL

> Tracker: C3 · Status: covered (D2) · Date: 2026-10-03
> Scope: who rides the EFA/libfabric seam and how — the version matrices, the plugin-loading
> mechanics, the new GPU-doorbell path, and the NIXL-on-AWS recipe. Feeds article 04; underpins
> 09 (NCCL collectives) and 13 (NIXL KV transfer).

## 1. Crisp understanding

libfabric (ofi) is the seam: EFA exposes a user-space, OS-bypass interface; **three families of
consumers** sit on it:
1. **MPI** (OpenMPI/Intel MPI/MVAPICH) — "just works" via the libfabric provider; irrelevant for
   vLLM but the original design target.
2. **NCCL** — via **aws-ofi-nccl**, an NCCL *external network plugin* implementing the NCCL NET
   API on libfabric.
3. **NIXL** — NVIDIA's inference-transfer library (KV cache, P/D); on AWS via its **UCX** or
   **LIBFABRIC** backends.

## 2. NCCL × EFA: aws-ofi-nccl (verified)

- **Current release: v1.21.1** — tested with NCCL **v2.31.2-1**, backward-compatible to **v2.17.1+**;
  v1.20 added the NCCL **net v12 plugin interface** (NCCL 2.30+).
- **Plugin loading** (verified from Makefile + NCCL ext-net README): the build produces
  `libnccl-net-ofi.so` plus a default `libnccl-net.so`. Load via `NCCL_NET_PLUGIN=ofi`
  (or the full .so name) — note `NCCL_NET_PLUGIN` selects the *library* (suffix of
  `libnccl-net-${name}.so`), while `NCCL_NET=<name>` selects a *network implementation by name*
  inside a plugin. If unset, NCCL dlopens `libnccl-net.so` and falls back to internal transports
  if init fails — which is why "NCCL silently used TCP" happens when the plugin isn't found.
- **Two execution modes in v1.21+** (the big news):
  - *host-proxy*: a CPU proxy thread issues network ops on the GPU's behalf (the historical mode);
  - **kernel backend (EFA GDA)**: NCCL issues work-queue entries and **rings the NIC doorbell
    directly from the GPU — no CPU involvement**. Auto-selected where supported. Requires
    NCCL ≥ 2.31.2-1, **GDRCopy ≥ 2.5**, **libfabric ≥ 2.6.0+**, and a supported EFA instance.
    This is GPUDirect-Async (GDA) landing in the standard NCCL path on AWS — article 04/09 gold.
- **Version matrix sanity** (HyperPod example): EFA installer 1.31.0 ↔ libfabric 1.18.2 ↔
  NCCL 2.20.3 ↔ OFI 1.8.1-aws; p5 minimums from A5 (cuda ≥12, nccl ≥2.18.5, ofi ≥1.7.3,
  efa-installer ≥1.29.0). EFA devices enumerate as `rdmap0s29-rdm`-style names.
- Verify in logs: `NCCL INFO NET/OFI Configuring AWS-specific options` (also confirms the AWS-
  optimized build that auto-resolves `NCCL_TOPO_FILE` — aws-ofi-nccl#298 lesson).

## 3. UCX × EFA (verified)

- UCX gained EFA support (UCT EFA memory domain): **UD-over-verbs** (EFA is not IBTA-compliant:
  no completion-order guarantee, subset of registration flags, no CQ interrupts) and an **SRD
  transport** (Active Messages am_short/bcopy/zcopy; RMA `get` via RDMA READ ≤1 GB). 2021 paper:
  UCX+SRD saturated ~12 GB/s (single-port era), **10× UCX+TCP**; GPUDirect RDMA for device
  buffers.
- Historical note worth a sidebar: early EFA/SRD had **no RDMA WRITE** (send + READ only);
  Nitro v4+ added write on most instances (current EFA docs) — do not quote 2021 tables at
  2026 hardware.
- **Live gotcha (ucx#10966)**: UCX's GPUDirect detection checks `efa_nv_peermem`/`nvidia_peermem`
  modules or dmabuf support; on p5/p5en *without* the peermem module it fell back to software
  emulation even though dmabuf-capable; fix levers: load `efa_nv_peermem` (GPU Operator deploys
  it) or `UCX_CUDA_COPY_DMABUF` tuning. This bit a real `nixl-benchmark` pod — expect it in the
  article-13 lab.

## 4. NIXL (verified)

- **Plugin architecture**: backends as SB-API plugins — **UCX** (network; all capabilities),
  **GDS** (storage↔GPU), plus newer ones incl. **LIBFABRIC**; agent model with serialized
  connection + memory metadata (`getPublicData` remote identifiers); transfers are non-blocking
  buffer-list requests; backend chosen by memory types or preference list.
- **AWS recipe (EFA+NIXL guide)**: run vLLM P/D with
  `--kv-transfer-config '{"kv_connector":"NixlConnector","kv_role":"kv_both","kv_buffer_device":
  "cuda","kv_connector_extra_config":{"backends":["LIBFABRIC"]}}'` — LIBFABRIC backend = native
  EFA path without UCX. (Caveat: AWS's example uses `kv_both`, which vLLM docs now deprecate for
  Nixl — prefer `kv_producer`/`kv_consumer` in the series' labs [V].)
-.llm-d context: llm-d standardizes on NIXL for P/D KV transfer, with TCP fallback dev-only (A11/J4).

## 5. Doubt questions (self-defined) → status

| Question | Status |
| --- | --- |
| Which library for vLLM KV transfer on AWS? | **NixlConnector + LIBFABRIC backend** (AWS recipe); UCX alternative carries the peermem/dmabuf caveat. |
| Does NCCL ring the NIC from the GPU now? | **Yes, optionally** — v1.21 GDA kernel backend (requirements §2). |
| How is the plugin actually loaded? | `NCCL_NET_PLUGIN=ofi` → `libnccl-net-ofi.so` (§2); unset → default dlopen with silent TCP fallback. |
| Does vLLM need MPI on EKS? | **No** — MPI is the HPC consumer; vLLM uses torch/mp + NCCL + NIXL. |

## 6. Verified facts (sources, accessed 2026-10-03)

- aws-ofi-nccl releases & GDA backend: [releases](https://github.com/aws/aws-ofi-nccl/releases)
  (v1.21.1 notes: host-proxy vs kernel, NCCL ≥2.31.2-1, GDRCopy ≥2.5, libfabric ≥2.6.0).
- Plugin mechanics: [aws-ofi-nccl src/Makefile.am](https://github.com/aws/aws-ofi-nccl/blob/master/src/Makefile.am),
  [NCCL ext-net README](https://github.com/NVIDIA/nccl/blob/master/ext-net/README.md).
- UCX-on-EFA design + numbers: [UCF21 paper](https://raw.githubusercontent.com/wiki/openucx/ucx/UCF2021_slides/UCF2021_paper_18.pdf);
  GDR detection issue: [ucx#10966](https://github.com/openucx/ucx/issues/10966).
- NIXL architecture: [BackendGuide](https://github.com/ai-dynamo/nixl/blob/main/docs/BackendGuide.md);
  AWS EFA+NIXL recipe: [efa-start-nixl](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa-start-nixl.html).
- Version-matrix example: [HyperPod EFA validation](https://awslabs.github.io/ai-on-sagemaker-hyperpod/docs/eks-orchestration/validation-and-testing/environment-validation/efa-validation).

## 7. Hands-on validation

LAB 03 step 4 already exercises NCCL-over-OFI (verify the `NET/OFI` + AWS-options log lines and,
on a modern stack, whether the GDA kernel backend engages). LAB 13 (article 13) will run the
NixlConnector LIBFABRIC-backend P/D pair on EKS — including the peermem/dmabuf check from §3.

## 8. Blog angle

"Three ways to ride one NIC": the consumer table, the plugin-loading diagram (NCCL_NET_PLUGIN vs
NCCL_NET), the GPU-doorbell timeline (host-proxy → GDA), and the NIXL-on-EFA recipe box.
