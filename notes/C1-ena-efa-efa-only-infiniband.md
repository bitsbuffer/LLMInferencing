# C1 — ENA vs EFA vs EFA-only vs InfiniBand (SRD)

> Tracker: C1 · Status: covered (D2) · Date: 2026-10-03
> Scope: the conceptual heart of article 04 — what each interface is, why AWS built SRD instead of
> using InfiniBand, and the measured gaps that matter for LLM collectives. Your original doubt #5
> ("InfiniBand… Elastic Network Adapter") resolves here. Feeds article 04; A5 owns the mechanics.

## 1. The interface taxonomy (verified recap + citations)

| | ENA (`interface`) | EFA with ENA | **EFA-only** |
| --- | --- | --- | --- |
| IP networking | ✅ VPC IP | ✅ both devices | ❌ no IP, can't be primary, no IPv4/6 |
| Exposed device | ENA | ENA + EFA | EFA |
| Use | everything ordinary | legacy ML/HPC pattern | **the recommended EKS pattern** (Karpenter/Auto Mode support only `interface` + `efa-only`) |
| Counts toward ENI limit | yes | yes | yes |

And the correction: **InfiniBand is not offered on AWS at all** — EFA *is* the InfiniBand-alternative;
ENA (Elastic Network Adapter) is just the VPC NIC. Three products share SRD: **EFA** (libfabric,
RDMA verbs semantics, NCCL/NIXL/MPI consumers), **ENA Express** (SRD for ordinary TCP/UDP), and
(EFAv2/v3/v4 = generations, not products — B4).

## 2. Why AWS built SRD instead of using InfiniBand (verified design story)

- **Cloud constraints:** the network is *always on* and multitenant; "truckloads of new servers"
  arrive daily; no maintenance windows to rebuild fabrics; no dedicated IB islands (they'd be
  "surrounded by oceans of everything else"). AWS's massive Ethernet investment stays.
- **The key design move: relax in-order delivery.** InfiniBand/TCP are conga lines — a single lost
  packet stalls everything behind it (head-of-line blocking). SRD sprays the packets of one flow
  **over 64 paths at a time chosen from hundreds/thousands available**, avoids overloaded paths,
  reasserts order higher in the stack. Result: **p99 tail latency dropped ~10×**, recovery from
  loss keeps throughput high.
- **Implemented in the Nitro networking card** (not the host) for fast congestion response; QP
  model is UD-like with reliability (Reliable-Datagram family; at-most-once delivery; per-WR
  Address Handles → full connectivity needs O(p) QPs, not O(p²) like RC).
- Design goal: "MPI should just work" — hence libfabric as the seam; NCCL rides it via
  aws-ofi-nccl, NIXL via UCX/EFA.

## 3. The measured gaps vs InfiniBand (verified — and why they mostly don't bite LLM workloads)

From a systematic EFA-vs-RDMA/IB evaluation (ACM DaMoN'22) plus AWS's own framing:

| Dimension | IB/RDMA | EFA/SRD | Meaning for LLM serving |
| --- | --- | --- | --- |
| Small-message latency (<512 B) | single-digit µs | ~20× higher (10× at 8 kB); ~2× better than TCP | NCCL control traffic stays on TCP anyway; collectives move MB–GB buffers |
| Saturation | low depth OK | needs **transmission depth ≈256** and ≥8 kB messages | NCCL/NIXL pipelines are deep — fine; tune if you hand-roll verbs |
| Message rate (small) | ~17 M/s (single core, posted lists) | ~2 M/s per NIC PU; ~8 M/s with multiple threads/connections | keep small ops off EFA; use parallelism |
| p99 under congestion | order-preserving → HOL blocking | **SRD wins here** — that's the point | multi-tenant cloud reality: tail latency is what collectives feel |
| Switch-hop latency (context) | ~100 ns (IB) vs ~300 ns (Ethernet) vs ~12.7 µs (plain TCP) | — | historical SC16 poster numbers for the IB-vs-RoCE-vs-Ethernet sidebar |

Poster-child conclusion for the blog: EFA is *not* a slower InfiniBand — it's a different
reliability/latency trade built for a shared network, and for bulk collectives it lands in the
same place (see B2: cross-node rows measured, not copied).

## 4. ENA Express — SRD for the ordinary NIC (verified)

- Same-AZ **or cross-AZ within a Region**; single-flow bandwidth **5 → 25 Gbps** (up to instance
  aggregate); dynamic path distribution + receive-side reordering; TCP uses it automatically when
  *both* ends enable it (UDP needs explicit `EnaSrdUdpSpecification` enablement); falls back to
  standard ENA otherwise; requires lower MTU (SRD headers) + TCP buffer/congestion checks.
- Blog aside: this is why "SRD" appears twice in AWS networking — EFA for HPC/ML fabrics, ENA
  Express for boring TCP — and they are not the same product.

## 5. Doubt questions → status

| Question | Status |
| --- | --- |
| "InfiniBand for node-to-node… AWS's Elastic Network Adapter?" | **Corrected** (§1): EFA = the fabric; ENA = the NIC; no IB on AWS. |
| Why no InfiniBand on AWS? | **Answered** (§2): always-on multitenancy + Ethernet + scale economics; SRD re-claims the tail latency IB order-preserving delivery wins on dedicated fabrics. |
| Is EFA just slower IB? | **No** — measured gaps are small-message latency and message rate; bulk collectives saturate fine with depth (§3). |
| Does SRD cross AZs? | EFA: **no** (same-AZ only); ENA Express: **yes** (cross-AZ in-region). |

## 6. Verified facts (sources, accessed 2026-10-03)

- SRD design & the no-HOL-blocking story: [AWS HPC blog](https://aws.amazon.com/blogs/hpc/in-the-search-for-performance-theres-more-than-one-way-to-build-a-network/),
  [Amazon Science paper](https://www.amazon.science/publications/a-cloud-optimized-transport-protocol-for-elastic-and-scalable-hpc),
  [amzn-drivers SRD.txt](https://github.com/amzn/amzn-drivers/blob/master/kernel/linux/efa/SRD.txt).
- Why not InfiniBand: [day1hpc: how EFA works](https://day1hpc.com/post/how-efa-works-and-why-we-dont-use-infiniband-in-the-cloud/).
- Measured EFA-vs-IB gaps: [ACM DaMoN'22 EFA evaluation](https://dl.acm.org/doi/fullHtml/10.1145/3533737.3538506).
- ENA Express: [EC2 docs](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ena-express.html),
  [EnaSrdUdpSpecification](https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_EnaSrdUdpSpecification.html).
- Interface taxonomy + EFA constraints: EFA docs + HPC FAQ (A5 notes, verified earlier).
- IB/RoCE/Ethernet latency context: [SC16 poster](https://sc16.supercomputing.org/sc-archive/tech_poster/poster_files/post149s2-file3.pdf).

## 7. Hands-on validation

LAB 03 steps 4–5 (EFA-vs-TCP allreduce + iperf/ENA) + **step 5 extension added**: `fi_pingpong`
(libfabric) EFA vs TCP for the latency row — the D3 evidence for this topic.

## 8. Blog angle

"The conga line and the crowd": open with the head-of-line-blocking story, the 64-paths diagram,
the p99×10 punchline — then the honest latency table so readers don't walk away thinking EFA
*beats* IB at everything. Your doubt #5 becomes the article's first sidebar.
