# A3 — NVIDIA device plugin vs DRA (K8s 1.34→1.36)

> Tracker: A3 · Status: covered (D2) · Date: 2026-10-03
> Scope: how GPUs reach pods — the legacy extended-resource device plugin vs Dynamic Resource
> Allocation; maturity of the NVIDIA DRA driver; the verdict for vLLM serving on EKS 1.36.
> Feeds article 01; underpins B5 (MIG/MPS) and A5 (topology-aware EFA).

## 1. Crisp understanding

**Device plugin (legacy, still default):** kubelet's extended-resource model. The NVIDIA device
plugin advertises integer counts of `nvidia.com/gpu` per node; pods request integers. Simple, GA,
works everywhere (incl. Auto Mode) — but it's just a counter: no attributes, no topology, no
health, no sharing semantics beyond static MIG/MPS/time-slice configs, no device-level taints.

**DRA (Dynamic Resource Allocation):** the scheduler allocates *devices* through driver-published
inventory. Objects: **ResourceSlice** (driver → kubelet inventory: GPU model, memory, driver
version, topology/PCIe locality), **DeviceClass** (`gpu.nvidia.com`, `mig.nvidia.com`,
`vfio.gpu.nvidia.com`), **ResourceClaim / ResourceClaimTemplate** (what a pod requests, with CEL
selectors over attributes/capacity), and (driver-side) config for sharing. Pods reference claims in
`spec.resourceClaims[]` and consume them via `resources.claims` per container. Scheduling is
topology-aware because allocation happens in the scheduler, not at kubelet admission time.

Maturity timeline (verified):
- **v1.30** first DRA alpha (old design) → reworked; **v1.34**: core APIs **GA**, `resource.k8s.io/v1`,
  enabled by default → **v1.35/1.36**: task docs mark DRA *stable & locked* (no opt-out).
- **1.36 beta-by-default**: partitionable devices (KEP-4815), consumable capacity, device taints &
  tolerations, ResourceClaim device status (health in Pod status), binding conditions,
  **extended-resource support** (pod keeps asking `nvidia.com/gpu` while the cluster runs DRA —
  the migration bridge). Stable: AdminAccess, prioritized alternative lists ("H100 else A100").
- Alpha in 1.36: ResourceClaims for workloads/PodGroups, node allocatable (CPU/mem via DRA),
  ResourcePoolStatusRequest, device metadata (versioned JSON + CDI bind-mounts).

## 2. The NVIDIA DRA driver — verified state (Oct 2026)

- **GPU allocation plugin: GA** since `NVIDIA/k8s-dra-driver-gpu` v25.12.0 (2026-02-12); project
  now lives at **kubernetes-sigs/dra-driver-nvidia-gpu**, current release **v0.5.0** (2026-08-19),
  Helm chart `oci://registry.k8s.io/dra-driver-nvidia/charts/dra-driver-nvidia-gpu`, supports GPU
  Operator **v26.7.0**. EKS doc walkthrough exists (its example pins chart v0.4.1 [V]).
- Resource types: full GPU / **MIG slice** / **VFIO passthrough** (`vfio.gpu.nvidia.com`, alpha).
- **Static MIG: default, no gate. Dynamic MIG: alpha** (`DynamicMIG` gate) — driver advertises all
  possible partitions + per-GPU shared counters, creates on demand, destroys on release, *owns*
  node MIG config (tears down unexpected partitions at startup; don't run `mig-parted` manually).
  Requires H100+ (A100 can't toggle MIG without reset), and K8s ≥1.36 for partitionable devices
  (1.34–1.35 need the `DRAPartitionableDevices` gate). `MPSSupport` is mutually exclusive with
  `DynamicMIG`.
- **Sharing:** consumable capacity (share one GPU/MIG across claims *and namespaces*, alpha
  `ConsumableShares`), time-slicing or multi-user MPS (within a claim). VFIO: no sharing.
- **ComputeDomains (MNNVL, GB200-style multi-node NVLink):** supported; v0.5.0 adds host-managed
  IMEX (alpha), Fabric-Manager partitioning (alpha); v25.12.0 cut domain-formation to ~10s at
  thousands-of-nodes scale and crash-fast on NVLink fabric errors (`CrashOnNVLinkFabricErrors`).
- **Health:** `NVMLDeviceHealthCheck` gate (alpha, off by default) + K8s-side ResourceClaim device
  status (beta in 1.36) → device health visible in **Pod status** with human-readable messages.
- Constraints to remember: same-GPU multi-MIG claims use `constraints: matchAttribute:
  gpu.nvidia.com/parentUUID`; claim sharing semantics differ (shared `ResourceClaim` vs per-pod
  template); static MIG changes after driver start need a kubelet-plugin restart.

## 3. EKS specifics (verified)

- Requirements: K8s ≥1.34; nodes from **static-capacity Karpenter, managed node groups, or
  self-managed** — **DRA is not supported with Auto Mode**.
- Cannot run alongside the NVIDIA device plugin (or EFA DRA driver alongside EFA plugin) on the
  same node — silent oversubscription risk.
- On Bottlerocket: disable the bundled device plugin via
  `settings.kubelet-device-plugins.nvidia.enabled=false` (Bottlerocket ≥ 1.63.0) before DRA.
- Install: `helm install dra-driver-nvidia-gpu oci://registry.k8s.io/dra-driver-nvidia/charts/
  dra-driver-nvidia-gpu --set gpuResourcesEnabledOverride=true` (optionally
  `resources.computeDomains.enabled=false` for single-node serving; `nvidiaDriverRoot=/run/nvidia/
  driver` when the GPU Operator manages drivers).

## 4. The verdict for vLLM on EKS 1.36 (blog-ready)

- **vLLM needs no core changes for DRA** — maintainers' own words on
  [issue #23900](https://github.com/vllm-project/vllm/issues/23900): DRA is effectively a no-op
  for the engine ("vLLM still just runs inside a resource provided by DRA"); what's missing is
  **docs/examples** (DRA manifests for the helm chart / k8s.md), and PRs are welcome.
- So the real question is platform choice, and the answer as of Oct 2026:
  - Default recipe (and what most of this series' labs use): **device plugin** (or Auto Mode).
    Works with dynamic Karpenter, GA everywhere, no feature gates.
  - Choose **DRA** when you need: attribute-based selection (CEL), topology-aware GPU↔EFA pairing,
    device taints for faulty GPUs, prioritized fallback models, per-device health in Pod status,
    or the migration bridge (extended resources over DRA).
  - Dynamic MIG / consumable-capacity sharing / multi-user MPS / ComputeDomains: **alpha** —
    fine for articles and controlled labs (great content!), not for prod fleets yet.
- Series implication: article 01 ships the device-plugin recipe; the DRA path is the "frontier"
  sidebar + its own lab (Path C).

## 5. Doubt questions → status

- "Is DRA production-ready for vLLM serving vs the device plugin?" — **answered** (section 4).
- "Dynamic MIG/MPS on EKS?" — answered as alpha-gated, mutually exclusive pairs; hands-on in
  LAB 01 Path C (opt).
- Remaining open [?]: chart v0.5.0 vs EKS-doc v0.4.1 drift; exact stable-version attribution
  (1.34 GA blog vs task-page "stable since 1.35") — both flagged [V] for lab verification.

## 6. Verified facts (sources, accessed 2026-10-03)

- EKS DRA vs device plugin: [device-management-nvidia-dra-device-plugin](https://docs.aws.amazon.com/eks/latest/userguide/device-management-nvidia-dra-device-plugin.html).
- Driver GA + dynamic MIG + ComputeDomain perf: [v25.12.0](https://github.com/NVIDIA/k8s-dra-driver-gpu/releases/tag/v25.12.0).
- Current SIG release, feature gates, consumable capacity, GFD clique label:
  [v0.5.0](https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/releases/tag/v0.5.0).
- Concepts & sharing matrix: [GPU allocation](https://dra-driver-nvidia-gpu.sigs.k8s.io/docs/concepts/gpu-allocation/),
  [MIG guide](https://dra-driver-nvidia-gpu.sigs.k8s.io/docs/guides/gpu-allocation/mig/).
- Install: [install docs](https://dra-driver-nvidia-gpu.sigs.k8s.io/docs/install/).
- K8s DRA workload syntax: [allocate-devices task](https://kubernetes.io/docs/tasks/configure-pod-container/assign-resources/allocate-devices-dra/).
- DRA GA in 1.34: [K8s blog](https://kubernetes.io/blog/2025/09/01/kubernetes-v1-34-dra-updates/);
  1.36 wave: [release blog](https://kubernetes.io/blog/2026/04/22/kubernetes-v1-36-release/),
  [DRA 1.36 updates](https://kubernetes.io/blog/2026/05/07/kubernetes-v1-36-dra-136-updates/).
- vLLM position: [vllm#23900](https://github.com/vllm-project/vllm/issues/23900).

## 7. Hands-on validation (scheduled)

LAB 01 **Path C** (DRA extension): install the v0.5.0 chart on the Path-B cluster, request a full
GPU via `ResourceClaimTemplate` with a CEL selector, run the same `nvidia-smi` probe via
`resources.claims`, inspect `ResourceSlice` attributes and claim/pod status. Estimates first:
expected ResourceSlice device count per node; time from claim → pod Running.

## 8. Blog angle

"A GPU is not an integer" — the one-line thesis of the DRA story. The plugin counts; DRA describes.
Include the verdict table and the vLLM no-op quote; keep the alpha-sharing section as the honest
frontier box.
