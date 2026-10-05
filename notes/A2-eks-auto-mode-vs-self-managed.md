# A2 — EKS Auto Mode vs self-managed GPU management

> Tracker: A2 · Status: covered (D2) · Date: 2026-10-03
> Scope: what Auto Mode actually manages for GPU nodes, what it refuses to do, what it costs,
> and when a GPU-inference cluster must not use it. Feeds articles 01–02.

## 1. Crisp understanding

EKS Auto Mode ("compute on autopilot") manages node *lifecycle* plus the platform machinery that
normally toils you: capacity selection (Karpenter engine under the hood), AMIs, **NVIDIA/Neuron
drivers**, the **NVIDIA device plugin**, block storage, load balancing, IAM. You express intent as
a `karpenter.sh/v1 NodePool` with `eks.amazonaws.com` NodeClass; AWS picks concrete instances.

**What Auto Mode manages for GPU nodes (verified):**
- NVIDIA drivers + NVIDIA device plugin — runs automatically, **not visible as a DaemonSet**.
- Neuron drivers for Trainium/Inferentia.
- **EFA network interfaces** — configured declaratively via `NodeClass
  (`eks.amazonaws.com/v1`)` → `advancedNetworking.networkInterfaces[]` with `networkCardIndex`,
  `deviceIndex`, `interfaceType: interface | efa-only`; supports placement groups. With a static
  `networkInterfaces` config, Auto Mode attaches **no** extra IPs/prefixes/ENIs post-launch.
- EBS storage: provisioner is `ebs.csi.eks.amazonaws.com`; existing `ebs.csi.aws.com` volumes must
  migrate via snapshots. You don't run the EBS CSI controller yourself.
- Supported accelerated families (verified list): p6-b200, p6-b300, p5, p5e, p5en, p4d, p4de, p3,
  p3dn, **g7e, g6, gr6, g6e, g5, g5g**, trn2, trn1, trn1n, inf2, inf1, g4ad, g4dn — with
  scheduling labels like `eks.amazonaws.com/instance-gpu-name: l40s` and the standard
  `nvidia.com/gpu` taint + toleration pattern.

**What Auto Mode does NOT do (verified — these are the disqualifiers):**
1. **No DRA.** "DRA is not currently supported with EKS Auto Mode." The NVIDIA DRA driver and the
   EFA DRA driver require Karpenter (static capacity), managed node groups, or self-managed nodes.
2. No custom AMI choice (no explicit Bottlerocket `aws-k8s-nvidia` / AL2023-NVIDIA selection —
   that's article 02 territory) [V — confirm current NodeClass fields at lab time].
3. No NVIDIA GPU Operator extras (MIG manager, driver rollout DaemonSets, DCGM exporter) — you
   either accept what's bundled or manage it yourself.
4. EFA **DRA** driver (topology-aware GPU↔EFA pairing, device sharing) is out; only the plugin
   path exists, and automatic topology-aligned GPU↔EFA allocation happens only on EKS-optimized
   **AL2023 accelerated AMIs**, not Bottlerocket/custom.

## 2. The MOFED trap (verified, article-01 gold)

Starting with NVIDIA `k8s-device-plugin` **v0.19.0**, `--mofed-enabled` defaults to **true**: the
plugin mounts **all `/dev/infiniband/uverbs*`** devices into containers that merely request GPUs.
That collides with the **EFA device plugin**, which is the component that should be allocating EFA
devices under `/dev/infiniband`. On managed node groups / self-managed nodes with the NVIDIA
device plugin you must **explicitly disable MOFED**; Auto Mode does not enable MOFED and is
unaffected. Also: the **EFA DRA driver and EFA device plugin cannot coexist on a node** (silent
oversubscription).

## 3. Cost model (verified)

- Auto Mode adds a **management fee per instance type**, on top of EC2 price; per-second billing,
  1-minute minimum. Example (us-west-2, from AWS pricing page): c6a.2xlarge → $0.306 EC2 +
  $0.03672 Auto Mode (~12% premium); m5a.xlarge → $0.172 + $0.02064.
- EC2 purchase options (On-Demand, RIs, Savings Plans, **Spot**) all work; the fee is independent
  of purchase option.
- You can **mix** Auto Mode nodes with managed node groups / self-managed nodes in one cluster —
  the sensible production pattern (Auto Mode for stateless/system, explicit GPU nodepools for
  inference).

## 4. Decision table for this series

| Need | Auto Mode | Karpenter + device plugin | Karpenter/MNG + DRA drivers |
| --- | --- | --- | --- |
| Article 01 quickstart (GPU pod green in minutes) | ✅ best | ⚠️ more setup | ❌ overkill |
| Article 02: compare AL2023-NVIDIA vs Bottlerocket AMIs | ❌ no AMI choice | ✅ | ✅ |
| Topology-aware GPU↔EFA pairing via DRA (article 04/13) | ❌ | ⚠️ plugin-level affinity (AL2023 only) | ✅ |
| MIG manager / GPU Operator extras (B5) | ⚠️ limited | ✅ | ✅ |
| Long-lived prod cluster w/ mixed compute | ✅ (mixed mode) | ✅ | ✅ |

**Series plan:** article 01 uses Auto Mode for the fastest green GPU pod; article 02 needs
Karpenter + explicit AMIs; topics A3/A5 (DRA, EFA topology) need MNG/static-Karpenter nodes.

## 5. Doubt questions → status

- "Auto Mode vs self-managed for GPUs" — **answered** (sections 1–4).
- DCGM exporter under Auto Mode — **deferred → D5** (Auto Mode doesn't ship it; placement is an
  observability decision).
- Exact current Auto Mode NodeClass fields (post-v1 AMI choice knobs) — **[V] at lab time**.

## 6. Verified facts (sources, accessed 2026-10-03)

- Auto Mode accelerator management & NodePool examples:
  [auto-accelerated](https://docs.aws.amazon.com/eks/latest/userguide/auto-accelerated.html).
- Supported instance families:
  [automode-learn-instances](https://docs.aws.amazon.com/eks/latest/userguide/automode-learn-instances.html).
- EFA NI config on Auto Mode, DRA-not-supported, MOFED gotcha, topology-aligned allocation rules:
  [device-management-efa](https://docs.aws.amazon.com/eks/latest/userguide/device-management-efa.html).
- Pricing (fee tiers, per-second, examples):
  [EKS pricing](https://aws.amazon.com/eks/pricing/).
- Mixed Auto Mode + self-managed, cost framing:
  [Auto Mode best practices](https://docs.aws.amazon.com/eks/latest/best-practices/automode.html).

## 7. Hands-on validation (scheduled lab)

Covered by `labs/01-cluster-addons/LAB.md` (Auto Mode path): NodePool for g6e with
`instance-gpu-name` label, run `nvidia-smi` pod, confirm no visible NVIDIA DaemonSets, then record
fee from pricing example vs actual bill.

## 8. Blog angle

"The autopilot and its edges": a decision table is the reader takeaway; the MOFED/EFA conflict and
the "no DRA under Auto Mode" cliff are the non-obvious stories that make the article worth
publishing.
