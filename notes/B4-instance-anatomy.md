# B4 — Instance anatomy: p5 / p5e / p5en / p6-b200 / p6-b300 / p6e-gb200(x) 

> Tracker: B4 · Status: covered (D2) · Date: 2026-10-03
> Scope: the "what you actually get" reference table for EC2 GPU instances in this series, incl.
> the EFA generation/interface-count matrix. Feeds article 03; refines cluster C (EFA gens).

## 1. The anatomy table (verified, Oct 2026)

| | p5.48xl | p5e.48xl | p5en.48xl | p6-b200.48xl | p6-b300.48xl | p6e-gb200.36xl | u-p6e-gb200x72 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| GPUs | 8×H100 | 8×H200 | 8×H200 | 8×B200 | 8×B300 | 4×Blackwell | **72×Blackwell** |
| GPU memory | 640 GB | 1128 GB | 1128 GB | 1440 GB | 2144 GB | 740 GB | 13,320 GB |
| HBM BW/GPU | 3.35 TB/s | 4.8 TB/s | 4.8 TB/s | 8 TB/s | 8 TB/s | 8 TB/s | 8 TB/s |
| vCPU / RAM | 192 / 2 TiB | 192 / 2 TiB | 192 / 2 TiB | 192 / 2 TiB | 192 / 4 TiB | 144 / 960 GiB | 2,592 / 17.3 TiB |
| NVMe | 8×3.84 TB | 8×3.84 | 8×3.84 | 8×3.84 | 8×3.84 | 3×7.5 | 405 TB |
| EFA gen | v2 | v2 | **v3** (Nitro v5) | **v4** | v4 | v4 | v4 |
| EFA interfaces | **32** | 32 | **16** | **8** (400 Gbps ea.) | 8-class | 400 Gbps ea. | 400 Gbps ea. |
| EFA aggregate | 3.2 Tbps | 3.2 Tbps | 3.2 Tbps | 3.2 Tbps | 6.4 Tbps | 3.2 Tbps | **28.8 Tbps** |
| IP (ENA) cap | 800 Gbps | 800 | 800 | 100 base/800 pattern | — | — | 1,080 Gbps EBS |
| EBS BW | 80 Gbps | 80 | 100 | 100 | 100 | 60 | 1,080 |
| GPU P2P | 900 GB/s (NVSwitch, 3.6 TB/s bisection) | 900 | 900 | **1,800 (NVLink 5)** | NVLink5-class | NVL domain | **130 TB/s NVL domain** |

(GB300 NVL72 GA'd 2025-12-01: 1.5× memory & FP4 vs GB200, ~20 TB GPU memory per UltraServer.)

## 2. The three structural surprises (blog gold)

1. **P6e-GB200 instances only exist inside UltraServers.** `u-p6e-gb200x72` connects many EC2
   instances into **one 72-GPU NVLink domain** (36→72 GPU sizes; 14.4→28.8 Tbps EFAv4). This is
   the verified exception to "NVLink stops at the node" (B1): the NVLink domain spans instances.
   GB200 superchip = 2 Blackwell + 1 Grace over NVLink-C2C (10 PFLOPS FP8, 372 GB HBM3e each).
   Initially Capacity-Blocks-only in the Dallas Local Zone (`us-east-1-dfw-2a`).
2. **EFA interface count shrinks as bandwidth per interface grows**: 32×(~100 Gbps) on p5/p5e →
   16×(200-ish, EFAv3) on p5en → **8×400 Gbps (EFAv4) on p6**. The A5 CEL rule ("one EFA device
   per card") still holds, but the pod-side device-count math changes per family — a real
   gotcha when porting NCCL jobs across generations.
3. **EFA generations matter for latency, not just bandwidth**: EFAv3 (Nitro v5, p5en) ≈ 35%
   lower latency vs EFAv2; EFAv4 (P6) does SRD multi-path routing across 400 Gbps/GPU. If you
   write about NCCL-over-EFA tuning (article 04), the generation is part of the tuning matrix.

## 3. Interface-attachment patterns differ per family (verified)

- p5.48xlarge canonical: primary ENA (card 0/dev 0) + efa-only at card 0/dev 1 + cards 1–31/dev 0.
- p5en AWS example uses a different shape: EFA/EFA-with-ENA at dev 1 of cards 0/4/8/12, efa-only
  elsewhere (16 cards total).
- p6: 8 cards → 8 EFA interfaces (400 Gbps each); max ENIs 32, max cards 8 [third-party listing —
  re-verify against EC2 docs at publish [V]].
- Translation for the series: the "N EFA devices" in any multi-node NCCL test is instance-family-
  specific; capture it in `bench/topo-<type>.txt` (LAB 03).

## 4. Cost/availability shape (for the lab-planning notes)

- p5 ~$98/h on-demand era pricing [V current]; P6/P6e availability is zonal/local-zone-limited;
  GB200/GB300 UltraServers and even P6 families are Capacity-Block-first (A9 tie-in). g6e.48xl
  (~8×L40S, no NVLink) remains the budget contrast instance for article 03/09.

## 5. Doubt questions → status

| Question | Status |
| --- | --- |
| Exact p6 EFA interface count? | **Answered**: 8×400 Gbps (EFAv4) for 3.2 Tbps on p6-b200. |
| Does NVLink cross nodes on EKS? | **Answered**: only via UltraServers (p6e-gb200x36/x72) — dedicated EC2 instances connected by an NVLink domain; p6-b200 stays single-node. |
| p5en interface count? | **Answered**: 16 (EFAv3), max cards 16 / ENIs 64 [V vs EC2 docs]. |
| GB300 availability? | **Answered**: GA 2025-12-01; 1.5× vs GB200. |

## 6. Verified facts (sources, accessed 2026-10-03)

- P6 family table + EFAv4 + superchip description: [P6 instance page](https://aws.amazon.com/ec2/instance-types/p6/).
- P6e-GB200 GA + UltraServer spec table: [AWS blog](https://aws.amazon.com/blogs/aws/new-amazon-ec2-p6e-gb200-ultraservers-powered-by-nvidia-grace-blackwell-gpus-for-the-highest-ai-performance/),
  [whats-new](https://aws.amazon.com/about-aws/whats-new/2025/07/amazon-p6e-gb200-ultraservers-gpu-performance-ec2/).
- P6-B200 spec (8×400 Gbps, 1800 GB/s P2P, Emerald Rapids): [AWS blog](https://aws.amazon.com/blogs/aws/new-amazon-ec2-p6-b200-instances-powered-by-nvidia-blackwell-gpus-to-accelerate-ai-innovations/).
- P5en EFAv3 + 35% latency + CLI pattern: [AWS blog](https://aws.amazon.com/blogs/aws/new-amazon-ec2-p5en-instances-with-nvidia-h200-tensor-core-gpus-and-efav3-networking/).
- GB300 NVL72 GA: [whats-new](https://aws.amazon.com/about-aws/whats-new/2025/12/amazon-ec2-p6e-gb300-ultraservers-nvidia-gb300-nvl72-generally-available/).
- p5/p5e numbers: [P5 page](https://aws.amazon.com/ec2/instance-types/p5/) (A1/A5 notes).
- Interface-count listings: [p5en listing](https://cloudprice.net/aws/ec2/instances/p5en.48xlarge),
  [p6-b200 listing](https://cloudprice.net/aws/ec2/instances/p6-b200.48xlarge) [V vs EC2 docs].

## 7. Hands-on validation

LAB 03 runs the measurement matrix on p5 (+g6e contrast). If a p5en/p6 node becomes available
(e.g., via Capacity Block), re-run steps 1–4 on it — the interface-count difference (32 vs 16 vs 8)
is the interesting delta for the hierarchy table.

## 8. Blog angle

"One table to rule them all": the anatomy table + the three surprises (UltraServer NVLink domains,
shrinking EFA interface counts, EFA generation latency deltas). This is the article-03 opener.
