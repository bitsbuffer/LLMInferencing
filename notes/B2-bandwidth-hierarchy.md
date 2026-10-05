# B2 — The bandwidth hierarchy table (measured, not copied)

> Tracker: B2 · Status: covered (D2) · Date: 2026-10-03 · **Measured columns fill in LAB 03.**
> Scope: the single most-reused artifact of the whole series — every bandwidth number that
> explains a serving decision, with the *protocol* to measure each row yourself.
> Feeds article 03.

## 1. Crisp understanding

LLM inference is a bandwidth-budgeting problem. Decode runs at arithmetic intensity ≈ 1 (each
weight byte read ~once per token) → **HBM bandwidth is the decode ceiling**. TP's per-layer
all-reduce rides the **NVLink/NVSwitch domain**; anything cross-node pays **EFA**; control-plane
and non-collective traffic ride **ENA**; weights and KV spill through **NVMe/EBS/S3**. The
hierarchy table is how you *predict* which of these dominates a given config — and every article
after 03 cites it.

## 2. The hierarchy (spec column verified; measured column = LAB 03)

| Rank | Layer | Spec (verified) | Measured (LAB 03) | Measured how |
| --- | --- | --- | --- | --- |
| 1 | HBM per GPU | H100 3.35 TB/s · H200 4.8 TB/s · B200 8 TB/s (HGX B300: up to 8, 288 GB) | ___ (DCGM `fb` BW / stream triad) | DCGM profiler, cuda memory ops |
| 2 | NVLink per GPU (bidir) | 900 GB/s (H200) · 1.8 TB/s (B200) · 3.6 TB/s (Rubin) | ___ | `nvidia-smi nvlink -s` + nccl-tests |
| 3 | NCCL allreduce, intra-node (NVLS) | ~480 GB/s busbw (H100, NVIDIA-measured) | ___ | nccl-tests `all_reduce_perf` |
| 4 | PCIe Gen5 x16 per GPU | **64 GB/s/dir (128 GB/s bidir** — NVIDIA spec lists bidir) | ___ | p2pBandwidthLatencyTest |
| 5 | Cross-node EFA (p5) | 3.2 Tbps shared with IP (IP ≤ 800 Gbps) | ___ | nccl-tests across 2 nodes |
| 6 | ENA (p5) | 100 Gbps (1 ENA) → up to 800 Gbps (8-ENA pattern) | ___ | iperf3 TCP |
| 7 | Instance NVMe (p5) | 8×3.84 TB (per-disk rate measure) | ___ | fio rand/seq |
| 8 | EBS (p5) | 80 Gbps | ___ | fio |
| 9 | Host↔GPU DMA | — (GDRCopy) | ___ | gdrcopy bw_test |
| 10 | S3 (via runai/Mountpoint) | instance-bandwidth-bound | ___ | load-time (A10 step 11) |

Ratios to publish (spec-side): HBM : NVLink : PCIe ≈ 4 : 1 : 0.07 on H100-class; decode tokens/s/GPU
≈ HBM_BW ÷ model_bytes_per_token — the *roofline* sanity check that every later benchmark gets
reconciled against.

## 3. Measurement protocol (the "not copied" part)

- **nccl-tests formulas** (verified): `algbw = S/t`; **busbw correction factors**: AllReduce
  `2(n−1)/n`; ReduceScatter/AllGather/AlltoAll `(n−1)/n`; Broadcast/Reduce `1`.
- **Caveats worth printing:** (1) busbw is a *flat-fabric equivalent* — with tree algorithms NCCL's
  internal conversion differs, and **NVLS/SHARP is hierarchical**, so busbw ≠ link speed there
  (compare *between algorithms*, not against peak); (2) always report size sweeps (1 MB→1 GB) and
  warmups; (3) for storage rows, drop caches (`echo 3 > /proc/sys/vm/drop_caches`) before cold
  reads (A10's 100 s→1 s trap); (4) capture `nvidia-smi topo -m` and NCCL_DEBUG alongside every
  run so the numbers are attributable to a topology.

## 4. Doubt questions (self-defined) → status

| Question | Status |
| --- | --- |
| p5 ENA baseline? | **Answered**: 100 Gbps (single ENA config) up to 800 Gbps with the 8-ENA pattern — verified in EC2 EFA instance-type doc. |
| Are the published busbw numbers reproducible? | Directionally yes (~480 GB/s H100 NVLS); **measured column fills in LAB 03** — that's the article's hero. |
| Does busbw equal link bandwidth? | **No** — correction-factor story + tree/NVLS caveats (section 3); this subtlety is a blog section of its own. |

## 5. Verified facts (sources, accessed 2026-10-03)

- H200 (141 GB HBM3e @ 4.8 TB/s, NVLink 900 GB/s, PCIe Gen5 128 GB/s): [H200 page](https://www.nvidia.com/en-us/data-center/h200/).
- B200/B300 (180–288 GB HBM3e @ up to 8 TB/s; node aggregates 38.4/64 TB/s; NVL72 130 TB/s NVLink):
  [HGX AI Factory components](https://docs.nvidia.com/enterprise-reference-architectures/hgx-ai-factory/latest/components.html),
  [Blackwell datasheet](https://dam-cdn.nvd.orangelogic.com/AssetLink/01dyp27s6aj4e0483cs5goo15354m438.pdf).
- busbw formulas + tree/NVLS caveats: [nccl-tests PERFORMANCE.md](https://github.com/NVIDIA/nccl-tests/blob/master/doc/PERFORMANCE.md),
  [nccl-tests#274](https://github.com/NVIDIA/nccl-tests/issues/274).
- p5 EFA/ENA split: [EFA accelerated instance types](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa-acc-inst-types.html).

## 6. Hands-on validation

**LAB 03 created** (`labs/03-gpu-anatomy/LAB.md`) — the article-03 hero lab: the full measurement
matrix (section 2's "measured how" column), deliverable = the filled table as CSV + annotated
topo matrices. B2 reaches D3/D4 when that runs.

## 7. Blog angle

"Ten numbers that explain every serving decision you'll make" — the hierarchy as the article's
spine, each row linked to the decision it constrains (decode roofline, TP fabric, cross-node EFA,
storage). The busbw-correction sidebar is the "now you know how benchmarks lie" moment.
