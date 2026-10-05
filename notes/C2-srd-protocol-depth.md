# C2 — The SRD protocol in depth (congestion, ordering, multitenancy)

> Tracker: C2 · Status: covered (D2) · Date: 2026-10-03
> Scope: protocol mechanics beyond C1's design story — congestion control, path selection,
> ordering stack, QP semantics, and what's actually tunable from EKS. Feeds article 04's
> protocol section. (C1 = the "why"; this = the "how".)

## 1. Congestion control — verified from the Amazon Science paper

- Objective: **fair share of bandwidth with minimum in-flight bytes** — prevent queue buildup
  (and drops) rather than reacting to them. Per-connection **dynamic rate limit + inflight limit**.
- Rate estimation from **ACK timing**, recent transmit rate and RTT changes; congestion is
  declared when **RTT rises on the majority of paths** (connection-wide, e.g. incast) or when the
  estimated rate drops below the transmit rate. Per-path congestion is handled **independently by
  rerouting**. The paper describes it as "somewhat similar to BBR, with datacenter multipath
  considerations."
- Spraying alone doesn't fix **incast** (many-to-one buffer exhaustion); it can even worsen it
  (micro-bursts converging on the receiver) — hence the min-in-flight discipline.

## 2. Path selection & recovery (verified)

- Sender **controls ECMP path choice by manipulating packet encapsulation** — SRD rides standard
  commodity-Ethernet ECMP rather than needing special switch features.
- Per-path RTT is collected continuously; overloaded paths are avoided (and SRD coexists with
  legacy non-spraying traffic deliberately).
- **Reroute-on-retransmit**: if the original path dies, the *retransmitted* packet takes another
  path immediately — no waiting for network-wide routing convergence (which is 2–3 orders of
  magnitude slower), no connection re-establishment.
- Paper's measured payoff (full-bisection, 8→8 racks, 16 MPI ranks/machine): TCP median FCT ~50%
  above ideal with tail **1–2 orders of magnitude** high; **SRD median FCT only 15% above ideal,
  and SRD's max FCT below TCP's average**.

## 3. Ordering: who restores it (verified)

- **SRD on the wire**: reliable, **out-of-order**, no segmentation (UD-like QPs: per-WR Address
  Handle, at-most-once delivery, retransmits, RNR errors with drop-ACKs; no EE contexts —
  O(p) connectivity).
- **libfabric `efa` RDM endpoint** restores *send-after-send* ordering via reassembly — that's
  the layer where "in-order" comes back. Opt-in granularity: `FI_OPT_EFA_SENDRECV_IN_ORDER_
  ALIGNED_128_BYTES` (in-order per 128-byte aligned block).
- **Reorder window is finite**: `FI_EFA_RECVWIN_SIZE` (messages). Anything arriving outside the
  window is an **error** — a real failure mode for wildly skewed paths (rare in practice).
- Two fabrics: **`efa`** (full-featured: emulated read/write/atomics, unlimited message size,
  FI_EP_DGRAM legacy) vs **`efa-direct`** (native path only: MTU ≈ 8 KiB message cap, requires
  `FI_CONTEXT2` + `FI_MR_LOCAL`, GDA query ops, CQ bypass) — a per-app tradeoff of compatibility
  vs overhead.

## 4. Multitenancy behavior (verified)

- SRD is designed to **share the fabric with non-spraying legacy traffic** (per-path RTT avoidance).
- Fair-share example from the paper: ~50 flows on 100 Gb/s → each converges to ~2 Gb/s with
  minimal in-flight bytes — i.e., your collective coexists with neighbors without collapsing.
- The Nitro-card placement of the reliability layer means fast retransmission/prompt slowdown
  **without host or hypervisor jitter** — and firmware improvements deploy fleet-wide without app
  changes.

## 5. Forward context: UEC/UET is standardizing SRD's ideas (verified)

The Ultra Ethernet Transport (v1.0 in progress) specifies: multi-path packet spraying, **flexible
ordering without a re-order buffer** (per-packet Direct Data Placement), receiver-based congestion
control with **credits for incast**, in-network collectives (switch offload), and ROD/RUD delivery
services, plus optional packet trimming for faster loss signaling. Translation for the blog:
**SRD was five years early** — and UEC's arrival means portable (non-AWS) fabrics gain the same
semantics; watch UEC v1.0 at publish time [V].

## 6. What's tunable from EKS (the operator's honest answer)

- **SRD itself: nothing** — it's in the Nitro card, no user knobs.
- **Consumer-side knobs**: libfabric envs (`FI_EFA_*`: TX queue depth, MR cache, bounce buffers,
  huge pages, MTU override) and consumer-level depths (NCCL channels/protocols per A5's matrix,
  NIXL backends). MTU is an instance/ENI property (ENA Express needs *lower* MTU for SRD headers).
- Monitoring: EFA metrics via CloudWatch add-on (B6), and the fabric counters in the AMI's
  rdma-core tooling.

## 7. Doubt questions (self-defined) → status

| Question | Status |
| --- | --- |
| How does SRD detect congestion? | **Answered** — majority-of-paths RTT rise or rate-estimate < transmit rate; per-path via rerouting (§1). |
| What if packets exceed the reorder window? | **Error** — `FI_EFA_RECVWIN_SIZE` (§3). |
| Do RDMA read/write ride SRD? | Yes — emulated in `efa` fabric; native in `efa-direct` within device limits (§3). |
| Can I tune SRD from the host? | **No** — only provider/consumer knobs (§6). |
| Does UEC change the story? | Convergence point, not a replacement on AWS — watch v1.0 [V]. |

## 8. Verified facts (sources, accessed 2026-10-03)

- Protocol details & measurements: [Amazon Science SRD paper](https://saeed.github.io/CS8803_DNS_Spring2024/assets/srd.pdf)
  (also [amazon.science page](https://www.amazon.science/publications/a-cloud-optimized-transport-protocol-for-elastic-and-scalable-hpc/)).
- QP semantics: [amzn-drivers SRD.txt](https://github.com/amzn/amzn-drivers/blob/master/kernel/linux/efa/SRD.txt).
- Provider knobs/fabrics: [fi_efa(7)](https://ofiwg.github.io/libfabric/main/man/fi_efa.7.html),
  [efa fabric comparison](https://github.com/ofiwg/libfabric/blob/main/prov/efa/docs/efa_fabric_comparison.md).
- UEC/UET: [UEC v1.0 progress](https://ultraethernet.org/uec-progresses-towards-v1-0-set-of-specifications/),
  [spec update](https://ultraethernet.org/ultra-ethernet-specification-update/).

## 9. Hands-on validation

LAB 03 step 5 (`fi_pingpong` EFA vs TCP) gives the latency row; a follow-on experiment for D3:
run two concurrent allreduce pairs on the same 2-node pair and watch per-run FCT variance — the
miniature version of the paper's fair-share experiment.

## 10. Blog angle

"A transport protocol that gives up on order and wins": congestion control diagram (rate limit +
inflight limit + majority-RTT), the FCT comparison chart, then the "SRD was early — UEC is
standardizing it" forward-look as the closer.
