# A4 — NFD / GPU Feature Discovery labels + topology-aware GPU scheduling

> Tracker: A4 · Status: covered (D2) · Date: 2026-10-03
> Scope: how a GPU cluster describes itself to the scheduler — Node Feature Discovery, NVIDIA's
> GPU Feature Discovery labels, NodeResourceTopology + the topology-aware scheduler plugin, and
> how DRA (1.36) absorbs much of this. Feeds article 01; connects to A3 (DRA) and L2 (placement).
> Note: the doubt map has no dedicated NFD section (its "A4" = NVLink → tracker B1–B4); research
> questions for this topic are defined here.

## 1. Crisp understanding

Two information layers tell the scheduler *what a node is*:

1. **NFD (Node Feature Discovery, kubernetes-sigs)** — the generic feature-labeller. Components:
   `nfd-master` (Deployment), `nfd-worker` (DaemonSet, runs on every node), `nfd-gc` (garbage
   collector), and optional **`nfd-topology-updater`** which publishes **NodeResourceTopology (NRT)**
   CRs describing per-NUMA-zone resource availability. Current release **v0.19.0** (2026-07-10);
   Helm chart now served from **`registry.k8s.io/nfd/charts/node-feature-discovery`** (moved there
   ~v0.18; older docs point at gcr.io staging [V at install]). Enable the updater with
   `--set topologyUpdater.enable=true`.
2. **GFD (GPU Feature Discovery, ships with the NVIDIA device plugin)** — turns NVML facts into
   `nvidia.com/*` node labels. Verified label set (from k8s-device-plugin docs):
   - `nvidia.com/gpu.product` — NVML product name minus the `NVIDIA` prefix (e.g. `A100-SXM4-40GB`,
     `L40S`); **overridden under MIG** to e.g. `A100-SXM4-40GB-MIG-1g.5gb`
   - `nvidia.com/gpu.count` (MIG override = number of MIG devices), `nvidia.com/gpu.memory` (MiB,
     per-slice under MIG), `nvidia.com/gpu.family` (ampere…), `nvidia.com/gpu.machine`,
     `nvidia.com/gpu.multiprocessors` (MIG slices), `nvidia.com/mig.strategy` (single|mixed)
   - `nvidia.com/cuda.driver.major/minor/rev`, `nvidia.com/cuda.runtime.major/minor`,
     `nvidia.com/gpu.compute.major/minor`, `nvidia.com/gfd.timestamp`
   These are consumed by plain `nodeSelector`/`nodeAffinity` — the *device-plugin-era* way to pick
   "an L40S" or "≥80 GB memory" without DRA.

## 2. Topology-aware scheduling (device-plugin era)

**NRT + scheduler-plugins' `NodeResourceTopologyMatch`** (kubernetes-sigs/scheduler-plugins):
- nfd-topology-updater (or RTE) publishes NRT CRs (`topology.node.k8s.io/v1alpha2`; cluster-scoped
  since NRT CRD v0.0.12; scheduler-plugins master needs NRT v0.1.0).
- Deploy a custom scheduler (`schedulerName: topo-aware-scheduler`) enabling
  `NodeResourceTopologyMatch` as Filter+Score; optional **Reserve-plugin overreserving cache**
  (`cacheResyncPeriodSeconds`, ≥5s) to survive pod churn — NRT data staleness is the classic
  failure mode at scale.
- **Scoring strategies:** `MostAllocated` / `BalancedAllocation` / `LeastAllocated` (require kubelet
  Topology Manager policy `single-numa-node`) and `LeastNUMANodes` (works with all policies).
- **Division of labor (key subtlety):** the scheduler picks the **node**; the **kubelet's Topology
  Manager** picks the NUMA node(s) *within* the node. The scheduler also requires NRT `Attributes`
  mirroring kubelet config (`topologyManagerPolicy`, `topologyManagerScope`), and homogeneous NUMA
  topology + kubelet settings across the node group it serves — it cannot validate that itself.
- Why an inference cluster cares: NUMA-local CPU↔GPU placement keeps tokenization/detokenization
  and NCCL pin threads on the socket closest to the GPU's PCIe/NVLink root (matters most on
  multi-socket p5.48xlarge with 8 GPUs spanning both sockets).

## 3. Where DRA (1.36) absorbs this

- Device-plugin labels and NRT were the workarounds for "the scheduler can't see devices". DRA
  makes device *attributes* first-class (A3): CEL selectors over model/memory/NUMA, per-device
  health, taints. The NVIDIA DRA driver v0.5.0 publishes **standard NUMA attributes** and gates
  list-valued attributes (`resource.kubernetes.io/numaNode`) via `DRAListTypeAttributes` (alpha) —
  i.e., NUMA-aware placement is becoming a DRA-native property rather than an NRT+custom-scheduler
  bolt-on.
- Practical 2026 guidance for the blog: run **NFD+GFD for labels** (cheap, universal), keep
  nodeSelector-based GPU picking as the baseline recipe, and treat NRT+topo-aware-scheduler as
  the interim tool — the durable path for topology-critical placement is DRA on 1.36+.

## 4. Doubt questions (self-defined) → status

| Question | Status |
| --- | --- |
| Does EKS ship NFD? | **No** — install via Helm (registry.k8s.io OCI chart) or manifests; not an EKS add-on. |
| What labels does GFD actually set on p5/g6e? | Label set verified (section 1); exact values on your instances → LAB 01 step 6. |
| Is NRT + topo-aware-scheduler worth it for vLLM pods? | Mechanically answered (section 2); the *measured* benefit (TTFT/TPOT delta with NUMA-pinned workers) is a LAB 15/L2 experiment — deferred with reason. |
| NFD vs DRA overlap? | **Answered** (section 3): labels = discovery/selection; DRA = allocation/topology/health. Both can coexist. |

## 5. Verified facts (sources, accessed 2026-10-03)

- NFD v0.19.0 + registry.k8s.io chart move:
  [releases](https://github.com/kubernetes-sigs/node-feature-discovery/releases),
  [v0.19.0](https://github.com/kubernetes-sigs/node-feature-discovery/releases/tag/v0.19.0),
  [Helm docs](https://kubernetes-sigs.github.io/node-feature-discovery/master/deployment/helm.html),
  [quick start](https://github.com/kubernetes-sigs/node-feature-discovery/blob/master/docs/get-started/quick-start.md).
- GFD labels incl. MIG overrides & product-name derivation:
  [GFD README](https://github.com/NVIDIA/k8s-device-plugin/blob/main/docs/gpu-feature-discovery/README.md),
  [label values discussion](https://github.com/NVIDIA/k8s-device-plugin/issues/739).
- NRT + scheduler plugin: [NodeResourceTopologyMatch docs](https://scheduler-plugins.sigs.k8s.io/docs/plugins/noderesourcetopology/),
  [README](https://github.com/kubernetes-sigs/scheduler-plugins/blob/master/pkg/noderesourcetopology/README.md).
- DRA NUMA attributes: NVIDIA DRA driver v0.5.0 release notes (see A3 notes).

## 6. Hands-on validation (scheduled)

LAB 01 Path B **step 6** (added): install NFD v0.19.0 with topology-updater alongside the device
plugin, then inspect labels (`kubectl get node -L nvidia.com/gpu.product -L nvidia.com/gpu.memory
-L nvidia.com/cuda.driver.major`) and `kubectl get noderesourcetopologies.topology.node.k8s.io`.
Predict first: label values for the chosen GPU, and NRT zone count (p5 = 2 NUMA nodes).

## 7. Blog angle

"Your cluster already knows it has 8 H100s — it just never told the scheduler." Walk the label
chain (NVML → GFD → node labels → nodeSelector), then the NRT/topo-aware-scheduler layer, then the
punchline: DRA makes describing devices native, which is *why* the 1.36 baseline matters.
