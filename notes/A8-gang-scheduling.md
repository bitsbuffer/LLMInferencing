# A8 — Gang scheduling for GPU jobs: Kueue / Volcano / KAI

> Tracker: A8 · Status: covered (D2) · Date: 2026-10-03
> Scope: why multi-pod GPU launches need all-or-nothing admission, and which scheduler delivers it.
> Feeds article 01 (and article 09's multi-node labs). Doubt map has no gang section (tracker-only
> topic); questions defined here.

## 1. Crisp understanding

A multi-node vLLM launch (TP/PP/EP across pods) is a **gang**: every pod must get its GPU or none
should start. Naive scheduling admits pods one by one — partial gangs sit there burning allocated
GPUs while NCCL init times out, or worse, two partial gangs deadlock each other. Gang scheduling
makes the workload the unit of admission: pods are held behind **scheduling gates** until the
controller admits the whole group, then all pods schedule together.

The three contenders (all verified, all installable on EKS via Helm; none is an EKS add-on [V]):

| | **Kueue** (kubernetes-sigs) | **Volcano** | **KAI Scheduler** (NVIDIA/Run:ai) |
| --- | --- | --- | --- |
| Current (verified 2026-10) | **v0.19.2** (2026-08-20) | **v1.15.2** (v1.15.0 2026-06-01; 1.15.0/1 → security fix, upgrade) | open-sourced 2025-04 (Apache-2.0) |
| Model | `ClusterQueue`/`LocalQueue`/`ResourceFlavor` + **Workload** = admission unit; pods held by scheduling gates until admitted | queues (`capability/deserved/guarantee`) + **podgroups**; actions+plugins pipeline (gang, drf, binpack…) | **podgroups** (min members) + queues (quota, **over-quota weight**, limit, priority); fair-share algorithm each cycle |
| Gang features | admission-time gang + `waitForPodsReady`, preemption/borrowing in Cohorts, fair sharing (AFS) | **gang-aware preemption & reclamation (v1.15 alpha)**: victim selection at job/gang granularity; HyperNode-scoped eviction | gang scheduling + **elastic jobs** + consolidation (moves pods to free contiguous blocks) + reclaim/preempt |
| Topology | **TAS**: `kueue.x-k8s.io/podset-required-topology` (+ slice/group annotations); rack/DC-level co-location | **HyperNodes** (rack/DC domains); topology-scoped preemption | TAS + **hierarchical TAS** + **hierarchical podgroups** (multi-level gangs for disaggregated serving) |
| DRA | — (extended-resource era; watch this space) | **v1.15: DRA queue quota** — ResourceClaims counted in capability/deserved/guarantee; shared claims deduped; consumable-capacity quota | **DRA support for NVIDIA ComputeResources (GB200/GB300)** |
| Autoscaler interplay | ProvisioningRequest integration (scale-up on demand) | scheduling gates for queue admission (v1.15 alpha): quota-blocked pods don't trigger Karpenter/CA scale-up | nodegroups (extra-capacity pools) |
| LWS story | ✅ first-class: one Workload per LWS group; scale unit = group; new groups gated until admitted; `LWSImmutableGroupSize` beta (group size immutable while managed — fixes quota bypass) | via podgroup/pod annotations [V] | hierarchical podgroups; **[2025-11] Grove+Dynamo integration** for disaggregated serving |
| Multi-cluster | MultiKueue: LWS workloads dispatched **atomically to one worker cluster** (primary nominates, group follows) | — [V] | — [V] |

## 2. What vLLM on EKS actually needs (answer)

- **Single-node TP (mp executor, 1 pod): gang scheduling is a non-issue** — one pod, one node.
- Needed when: multi-node TP/PP/EP (one pod per node via Ray/LWS/JobSet), P/D disaggregated pools
  (prefill+decode pods that should land in topology domains), RayService multi-node clusters.
- Series pick: **Kueue** (CNCF-native, LWS + TAS + MultiKueue, and the KServe/llm-d ecosystem
  leans on it). **Volcano** = the battle-tested unified scheduler (its DRA queue quota is the most
  complete DRA story of the three). **KAI** = the NVIDIA-fleet option with fair-share across teams
  and hierarchical gangs purpose-built for Dynamo/Grove-style disaggregated serving.
- Layering with A4: Kueue-TAS decides the **topology domain at admission** (which rack); NRT's
  `NodeResourceTopologyMatch` decides **NUMA placement within a node** (and is the device-plugin-era
  path). DRA attributes (1.36) supersede much of the NRT half.

## 3. Maturity notes worth publishing (verified from release notes)

- Kueue's 0.19.x changelogs are **wall-to-wall TAS fixes** (unhealthy-node replacement, flavor
  scan progress, elastic-workload leader assignment) — TAS is maturing fast; pin versions and read
  release notes before upgrades. `LWSImmutableGroupSize` (beta, default) changes LWS semantics:
  resizing a Kueue-managed LWS's `size` requires recreation.
- Volcano 1.15.0/1.15.1 had a security vuln — 1.15.2 is the floor. Its gangPreempt/gangReclaim
  alpha must not be mixed with legacy preempt/reclaim actions.
- KAI: fair-share = deserved-quota + over-quota by weight + allocated/fair-share ratio; GPU
  sharing, elastic jobs, consolidation; runs alongside other schedulers; its install assumes GPU
  Operator on the cluster.

## 4. Doubt questions (self-defined) → status

| Question | Status |
| --- | --- |
| Which scheduler for this series' labs? | **Kueue** (section 2). |
| Does plain single-node vLLM need gang scheduling? | **No** (section 2). |
| Kueue-TAS vs NRT topo-scheduler vs DRA? | **Answered** (section 2 end). |
| Volcano EKS add-on availability? | [V] at lab time (marketplace vs helm). |
| Kueue × Karpenter flow? | ProvisioningRequest-based; exact wiring **[V at lab]** (LAB step 9). |

## 5. Verified facts (sources, accessed 2026-10-03)

- Kueue v0.19.2/v0.19.1 + LWS guide + MultiKueue LWS:
  [v0.19.2](https://github.com/kubernetes-sigs/kueue/releases/tag/v0.19.2),
  [v0.19.1](https://github.com/kubernetes-sigs/kueue/releases/tag/v0.19.1),
  [Run LWS](https://kueue.sigs.k8s.io/docs/tasks/run/leaderworkerset/),
  [MultiKueue LWS](https://kueue.sigs.k8s.io/docs/tasks/run/multikueue/leaderworkerset/).
- Volcano v1.15.0 (gang-aware preemption, DRA quota, scheduling gates):
  [release](https://github.com/volcano-sh/volcano/releases/tag/v1.15.0).
- KAI: [NVIDIA blog](https://developer.nvidia.com/blog/nvidia-open-sources-runai-scheduler-to-foster-community-collaboration/),
  [repo](https://github.com/kai-scheduler/KAI-scheduler).

## 6. Hands-on validation (scheduled)

LAB 01 **step 9** (Path B): install Kueue v0.19.2; create ClusterQueue+LocalQueue with
`nvidia.com/gpu` flavor; submit an LWS (leader + 2 workers, 1 GPU each) with
`podset-required-topology: cloud.provider.com/topology-rack`. Predict: pods stay **Pending with a
schedulingGate** until the Workload is admitted; then observe group admission; then force an
inadmissible topology and watch it stay gated.

## 7. Blog angle

"Deadlock by default": show the two partial gangs NCCL-timeout screenshot, then the Kueue gate →
admit → launch sequence. The comparison table + the "which layer decides what" (domain / node /
NUMA) pyramid is the reader takeaway.
