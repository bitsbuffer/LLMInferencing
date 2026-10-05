# A9 — Node pools & taints; placement groups for p5/p6

> Tracker: A9 · Status: covered (D2) · Date: 2026-10-03
> Scope: steering GPU pods to GPU nodes (taints/labels), and the physical-topology guarantees
> (placement groups, capacity reservations) behind multi-node EFA. Feeds article 01/15;
> connects to A5 (EFA), A8 (Kueue), L2 (production placement).

## 1. Crisp understanding

Two orthogonal problems:
**(a) Logical steering** — make sure only GPU workloads land on nodes that cost $2–$100+/hour.
The pattern: NodePool **taints** `nvidia.com/gpu: NoSchedule` + pods **tolerate** it
(`operator: Exists`); select concrete silicon via labels (`eks.amazonaws.com/instance-gpu-name:
l40s|h200|b200`, `eks.amazonaws.com/compute-type: auto` under Auto Mode, or GFD's
`nvidia.com/gpu.product` on self-managed). Kueue can carry the same taints in a `ResourceFlavor`
so the queue itself enforces the boundary.
**(b) Physical topology** — placement groups + capacity reservations decide whether 2+ nodes can
actually saturate EFA at all.

## 2. Placement groups on EKS (verified)

- **Karpenter `EC2NodeClass.spec.placementGroupSelector`** (`name` or `id`): **one EC2NodeClass =
  exactly one placement group** — every instance from that NodeClass lands in it. Needs
  `ec2:DescribePlacementGroups` (+ launch permissions). A `PlacementGroupReady` condition gates
  launches; Karpenter filters instance types by strategy compatibility and simulates PG membership
  during consolidation. Strategies:
  - **cluster** — single AZ, same network segment; the EFA pattern
  - **partition** — up to 7 partitions/AZ; `karpenter.k8s.aws/placement-group-partition` node
    label drives `topologySpreadConstraints`
  - **spread** — ≤7 instances/AZ per group
- **EC2 cluster-PG rules that bite:** single-flow TCP/IP throughput 10 Gbps in-PG vs 5 Gbps
  outside; same-instance-type strongly recommended (mixing types lowers launch success);
  non-EFA internet/DX traffic capped at 5 Gbps in-PG; EFA doesn't *require* a cluster PG but AWS
  recommends it (single-AZ, low-latency segment — matches EFA's same-AZ constraint).
- **Capacity hazard:** a non-empty cluster PG pins subsequent launches to the PG's AZ;
  wrong-AZ subnets/instance types → `InsufficientInstanceCapacity`. AWS's remedy: **explicit
  ODCRs inside the placement group** (zonal Reserved Instances cannot reserve capacity in a PG).
- Multi-AZ GPU fleets therefore need **one NodeClass (and PG) per AZ** — a NodePool can select
  across NodeClasses, but a NodeClass can't span PGs.

## 3. Capacity reservations (verified)

- **Karpenter native ODCR support**: v1.3 ODCRs → v1.6 **Capacity Blocks for ML** → v1.10
  Interruptible ODCRs; gated by `ReservedCapacity`; configure
  `capacityReservationSelectorTerms` on the NodeClass; NodePool must allow
  `karpenter.sh/capacity-type: reserved` (alongside/instead of on-demand/spot). Karpenter
  **prioritizes reserved capacity** and models it as free (consolidates spot/OD onto it); once the
  gate is on, open matching is off — every ODCR must be explicitly selected. If a reservation
  expires/cancels, Karpenter relabels the node back to `on-demand`.
- **Capacity Blocks for ML**: pre-booked future GPU capacity; instances are **auto-placed close
  together inside EC2 UltraClusters** (petabit, non-blocking) — the cleanest way to get a p5/p6
  mini-supercomputer for a bounded window. EC2 terminates capacity-block instances ahead of the
  block end (10 min warning per instance type / 60 min for UltraServers); **Karpenter drains nodes
  10 minutes before EC2's termination** so workloads see the eviction coming.
- **Auto Mode**: launches into *open* ODCRs by default (labeled `on-demand`, not prioritized);
  adding `capacityReservationSelectorTerms` switches to explicit selection, labels nodes
  (`eks.amazonaws.com/capacity-reservation-id|type|interruptible`), and stops open-matching.
  Capacity Blocks always require explicit selection.

## 4. Disruption control for long-lived vLLM pods (verified)

- `karpenter.sh/do-not-disrupt: "true"` on a pod blocks **voluntary** disruption
  (consolidation/expiration/rotation): Karpenter won't remove or replace the node; draining blocks
  until `terminationGracePeriod` elapses. It does **not** protect against node failure, manual
  drain, or spot reclamation (on Spot, Karpenter only uses deletion consolidation).
- Why it matters for inference: an evicted vLLM pod loses its **warm weights** (reload cost) and
  its **KV/prefix cache** (TTFT regression fleet-wide). Pair with PDBs; accept the cost trade-off
  (protected nodes can't be consolidated until the pod ends).
- Complementary lever: `consolidateAfter: 1h` / `WhenEmpty` on the GPU NodePool (Auto Mode docs'
  own example) to stop consolidation churn on expensive nodes.

## 5. Doubt questions (self-defined) → status

| Question | Status |
| --- | --- |
| Can one NodeClass span multiple AZs with a cluster PG? | **No** — one PG per NodeClass; cluster PGs are single-AZ (section 2). |
| ODCRs usable without explicit config? | Yes via open matching (Karpenter fallback behavior no longer supported once native support is on; Auto Mode labels them `on-demand`) (section 3). |
| How to keep expensive GPU nodes from churn? | taints + `do-not-disrupt` + PDBs + `consolidateAfter` (sections 1, 4). |
| Kueue ResourceFlavor × taint interplay? | Directionally answered; exact manifest **[V at lab (step 9)]**. |

## 6. Verified facts (sources, accessed 2026-10-03)

- Karpenter placement groups: [NodeClasses](https://karpenter.sh/docs/concepts/nodeclasses/),
  [design RFC](https://github.com/aws/karpenter-provider-aws/blob/main/designs/placement-groups-support.md).
- EC2 PG rules (single-flow limits, same-type advice, ODCR-in-PG, parent precision-time PGs):
  [placement strategies](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/placement-strategies.html),
  [EFA start guide](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa-start.html).
- ODCR/Capacity Blocks: [Karpenter ODCRs](https://karpenter.sh/docs/tasks/odcrs/),
  [Auto Mode ODCR](https://docs.aws.amazon.com/eks/latest/userguide/auto-odcr.html).
- do-not-disrupt semantics: [Karpenter workshop](https://catalog.workshops.aws/workshops/334487c7-4583-4abe-b80c-b6d4569e2c63/en-US/disruption-control/disable-eviction),
  [karpenter-blueprints batch protection](https://deepwiki.com/aws-samples/karpenter-blueprints/4.3.2-batch-jobs-protection).
- Taint/toleration + instance-gpu-name patterns: EKS Auto Mode accelerated-workloads doc (A2 notes).

## 7. Hands-on validation (scheduled)

LAB 01 **step 10**: create a cluster PG; set `placementGroupSelector` on the GPU EC2NodeClass;
launch 2 nodes; confirm both land in the same AZ; create a Capacity-Block/ODCR-based NodePool
(`capacity-type: reserved`) and check reservation labels; add `do-not-disrupt` to a vLLM pod and
trigger an expiry to watch the block. Predict first: which AZ error you'd hit with a second subnet;
what happens to consolidation with a protected pod.

## 8. Blog angle

"$98/hour nodes deserve guardrails": taint patterns as the fiscal firewall; then the punchline
table of the three placement-group strategies vs EFA needs, the one-PG-per-NodeClass rule, and the
capacity-block drain countdown story.
