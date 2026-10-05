# C6 — InfiniBand industry context + NCCL topology tuning for p5/p6

> Tracker: C6 · Status: covered (D2) · Date: 2026-10-03 · **Cluster C complete (6/6).**
> Scope: the IB-world context (brief — C1 owns the deep compare) and the *practical* NCCL
> tuning story on AWS fabric, incl. the topology-file machinery. Feeds article 04 (and 09/15).

## 1. Industry context (recap — details live in C1/B1/B4)

The non-AWS HPC world still runs **InfiniBand** (ConnectX-7/8 class NICs, SHARP in-network
collectives) or RoCE — with ~0.9 µs 8-byte latency vs EFA's tens-of-µs, but on dedicated,
maintenance-windowed fabrics. The vLLM large-scale result (2.2k tok/s/H200 DeepSeek wide-EP) was
measured on **CoreWeave H200 + ConnectX-7 InfiniBand**; NVIDIA's NVL72 (GB200) keeps that traffic
*intra-rack* on the 130 TB/s NVLink domain. AWS's answer is SRD-on-Ethernet (C1/C2) — different
trade, same destination: saturated bulk collectives with tame tails.

## 2. NCCL topology files on AWS (verified)

- **What it is:** a platform XML (GPU↔NIC↔CPU affinity + bandwidths) NCCL's graph search consumes
  to pick optimal collectives/routes per rail.
- **Where:** historically shipped static, e.g. `/opt/aws-ofi-nccl/install/share/aws-ofi-nccl/xml/
  p4de-24xl-topo.xml`; the plugin auto-selects it when built with `--enable-platform-aws`
  (log line: `NCCL INFO NET/OFI Configuring AWS-specific options` — the same flag that fixed the
  aws-ofi-nccl#298 regression).
- **What changed (v1.19.0, Apr 2026):** **P5 topology files are now auto-generated from detected
  topology instead of static files**, and a GB200-in-Docker bug (NUMA nodes disconnected from
  Package nodes → wrong topology) got fixed. Practical rule: on modern stacks, let the plugin
  generate; set `NCCL_TOPO_FILE` manually only for custom/broken cases, and verify the XML from
  inside the container (B3's topo capture is the ground truth).

## 3. The NCCL env cheat-sheet for EKS p5/p6 (verified)

**Core (usually all you need on a modern stack):** none required — plugin + NVLS pick
themselves. Debug first: `NCCL_DEBUG=INFO` (+ `NCCL_DEBUG_SUBSYS=INIT,GRAPH,TUNING` when needed).

**Semantics worth knowing (not tuning blind):**
- `NCCL_NVLS_ENABLE`: `2` (default) = silently disabled when multiple ranks share a GPU; `1` =
  force (init *fails* on ranks-per-GPU>1); `0` = off. NVLS/NVLSTree = NVLink-SHARP offload (B1).
- `NCCL_ALGO` now takes function-scoped lists, e.g. `allreduce:^tree`.
- `NCCL_SOCKET_IFNAME` (bootstrap/socket traffic): prefixes, `=exact`, leading `^` to invert
  **(must be first)**. **Kernel chooses the source interface via routing** — NCCL only picks
  destination IPs; the design assumes one subnet per interface (nccl#1580: same-subnet multi-NIC
  breaks silently). OOB/bootstrap has its own `NCCL_OOB_NET_*` knobs.

**aws-ofi-nccl runtime knobs (`OFI_NCCL_*`, when you're actually tuning):**
- `OFI_NCCL_PROTOCOL`: `SENDRECV` (tagged sends; best where the provider has eager/tagged GPU
  paths) vs `RDMA` (sender-managed receive via RDMA write; **multi-rail channels per GPU** —
  prefer on multi-NIC instances like p6's 8×400 or when no eager optimization exists).
- `OFI_NCCL_FORCE_NUM_RAILS` (+ `MIN_STRIPE_SIZE` 128 KiB default) — rail/striping control for
  the RDMA protocol.
- Safety valves: `OFI_NCCL_DISABLE_GDR_REQUIRED_CHECK` (run without GDR on P4d+),
  `OFI_NCCL_DISABLE_NATIVE_RDMA_CHECK`, `OFI_NCCL_GDR_FLUSH_DISABLE`, `OFI_NCCL_DISABLE_DMABUF`,
  `OFI_NCCL_CUDA_FLUSH_ENABLE`; perf hygiene: `OFI_NCCL_MR_CACHE_DISABLE` (off = keep cache),
  `OFI_NCCL_EAGER_MAX_SIZE` (v1.20: auto-detected), `OFI_NCCL_CQ_SIZE` (12,288 default).

**Legacy-only set (aws-ofi-nccl ≤1.5):** `FI_PROVIDER=efa`, `NCCL_PROTO=simple`, 
`FI_EFA_USE_DEVICE_RDMA=1` — do not apply to modern stacks (A5's matrix).

## 4. Bonus: VPC CNI multi-NIC for ENA spreading (verified)

`ENABLE_MULTI_NIC=true` on `aws-node` + `k8s.amazonaws.com/nicConfig: multi-nic-attachment`
gives a pod an ENI/IP from *every* NIC with an ENA adapter (cards with only efa-only are skipped;
can't pick specific NICs; **not supported on Auto Mode**). Relevance: p5's 32 cards can spread
*IP* traffic (dataloader pulls, checkpoint writes) across ENAs while EFA rails do collectives.

## 5. Doubt questions (self-defined) → status

| Question | Status |
| --- | --- |
| Which NCCL envs are *required* on p5/p6 today? | **None** — debug vars only; everything else is situational (§3). |
| When to set `OFI_NCCL_PROTOCOL=RDMA`? | Multi-NIC instances / no-eager providers (p6 8-rail story); verify at lab [V]. |
| NVLS with ranks-per-GPU > 1? | Auto-disabled at default `2`; forced `1` fails init (§3). |
| Topology file needed on P5? | v1.19+ generates it; only set manually for anomalies (§2). |

## 6. Verified facts (sources, accessed 2026-10-03)

- Topology auto-generation + GB200 fix: [aws-ofi-nccl v1.19.0](https://github.com/aws/aws-ofi-nccl/commit/4afc89b740324f0ed1bd8df1c75b6e5c03e8b3a0).
- Env semantics: [NCCL env docs (2.32.3)](https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/env.html) (IFNAME
  prefixes, NVLS_ENABLE values, NCCL_ALGO syntax); [nccl#1580](https://github.com/NVIDIA/nccl/issues/1580)
  (kernel-routes-source subtlety, OOB separation).
- `OFI_NCCL_*` table: [aws-ofi-nccl env wiki](https://github.com/aws/aws-ofi-nccl/wiki/Environment-Variables);
  legacy matrix: [efa-env-var.md](https://github.com/aws/aws-ofi-nccl/blob/master/doc/efa-env-var.md).
- Topology path/regression: [aws-ofi-nccl#298](https://github.com/aws/aws-ofi-nccl/issues/298).
- VPC CNI multi-NIC: [EKS pod multi-NIC](https://docs.aws.amazon.com/eks/latest/userguide/pod-multiple-network-interfaces.html).
- IB context: C1 notes (SC16 poster, DaMoN'22) + vLLM wide-EP blog (B1 notes).

## 7. Hands-on validation

LAB 03 step 4 already logs NCCL's algo/rail choices with `NCCL_DEBUG=INFO`. D3 extensions: on a
p6 pair, A/B `OFI_NCCL_PROTOCOL=SENDRECV` vs `RDMA` with `OFI_NCCL_FORCE_NUM_RAILS=8`; on p5,
verify the auto-generated topology file appears in the container and matches B3's `topo -m`.

## 8. Blog angle

"The ten env vars that actually matter" — a cheat-sheet table with a *semantic* column (what each
knob really does), the topology-file evolution (static XML → generated), and the multi-NIC ENA
spreader as the practical coda.
