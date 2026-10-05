# D4 — NVIDIA GPU Operator vs AMI-bundled: when each

> Tracker: D4 · Status: covered (D2) · Date: 2026-10-03
> Scope: the three management models for the GPU software stack on EKS, the operator's operand
> list, and the driver-upgrade lifecycle. Feeds article 05 (+15). Builds on A2/A3/A6/A7.

## 1. The three models (verified)

| | **AMI-bundled** (EKS accelerated AMIs) | **GPU Operator** (v26.7 era) | **EKS Auto Mode** |
| --- | --- | --- | --- |
| Driver | baked into AMI (580 for ≥1.34) | **driver container** (daemon-set pod, `NVIDIADriver` CR or ClusterPolicy) | AWS-managed, invisible |
| Device plugin / toolkit / MIG manager | separate installs (or Bottlerocket bundles them) | operator-deployed pods (`ClusterPolicy`) | AWS-managed |
| DRA driver | separate helm install (k8s-sigs chart, A3) | **new: `GPUCluster` CRD manages DRA driver + ComputeDomains + DCGM + validation** (mutually exclusive with `ClusterPolicy`; k8s ≥1.34.2, driver ≥580, CDI runtime) | ❌ no DRA |
| Extras | — | GFD, validator, GDRCopy, GDS (`gds.enabled`), **KubeVirt GPU plugins / vGPU device manager**, ccManager (confidential computing) | — |
| OS constraints | EKS AMIs | supported OSes; **no AL2 mix in one cluster**; Bottlerocket = bundles-its-own (operator not recommended, A7); eksctl can't provision non-AL2 MNGs → self-managed/console for operator nodes | n/a |
| Upgrade story | node replacement (new AMI → drift) | **in-place driver upgrade controller** (below) | AWS |

**EKS doc framing (verified):** on plain EKS-optimized AMIs you *don't* need the operator — its
limitations are the price for driver lifecycle in-cluster. Choose operator when you want recent
drivers without node churn or advanced operands (DRA/KubeVirt/vGPU); choose AMI-bundled for the
simple, pinned, node-replacement model; Auto Mode removes the choice entirely.

## 2. The operand list (verified)

Default install = driver, container-toolkit, device-plugin, **DCGM-exporter**, MIG-manager pods
per GPU node. Full component matrix adds: **GFD** (labels, A4), validator, **GDRCopy driver**
(C4), **GDS driver** (`gds.enabled`, needs open kernel module ≥v23.9), **KubeVirt GPU device
plugin + vGPU device manager** (virtualization), **ccManager** (confidential computing, default
off). Config = `ClusterPolicy` (or the new `GPUCluster` for the DRA path).

## 3. Driver upgrades — the state machine (verified)

Sequence per node: disable driver clients → unload kernel modules → start new driver pod →
load modules → re-enable clients. The **upgrade controller** (default-on) automates it with a
labelled state machine, `nvidia.com/gpu-driver-upgrade-state`:
`upgrade-required → cordon-required → wait-for-jobs-required → pod-deletion-required →
(drain-required, fallback) → pod-restart-required → validation-required → …`
with `autoUpgrade` pause per ClusterPolicy or per `NVIDIADriver` CR, `waitForCompletion` (jobs),
GPU-pod deletion, and **drain as last resort** (podSelector-scoped). Legacy `k8s-driver-manager`
initContainer still exists but is the deprecated path (no observability/pause). Bonus from v26.7:
workloads annotated `gpu.nvidia.com/gpu.deploy.client=true` get **auto-restarted during driver
upgrades / MIG changes**. Operator CRD updates: pre-upgrade hook (v24.9+); `GPUCluster`
installations must apply ComputeDomain CRDs manually.

Contrast with AMI-bundled: the same upgrade = a *node replacement* (drift/rolling MNG), which
evicts pods anyway — the difference is blast radius control (controller = per-node, observable,
pausable) vs fleet-level rollouts (Karpenter disruption budgets, A9).

## 4. Doubt questions → status

| Question | Status |
| --- | --- |
| Operator vs AMI-bundled on EKS? | **Answered** (§1 table; EKS doc's own framing). |
| What does the operator actually manage? | **Answered** (§2 operand list incl. the v26.7 `GPUCluster`/DRA integration). |
| How do driver upgrades differ? | **Answered** (§3 state machine vs node replacement). |
| DCGM exporter via operator or standalone? | Either (B6); operator installs it by default. |

## 5. Verified facts (sources, accessed 2026-10-03)

- Operator overview + operand/licenses: [About the GPU Operator (25.9.2)](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/25.9.2/index.html).
- v26.7 release notes (`GPUCluster`, KubeVirt+DRA, DRA v25.3.0, client restarts):
  [26.7 release notes](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/26.7/release-notes.html).
- Driver-upgrade controller: [GPU driver upgrades (26.7)](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/26.7/gpu-driver-upgrades.html).
- EKS integration + OS constraints: [GPU Operator with EKS (26.7)](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/26.7/amazon-eks.html).
- KubeVirt+DRA details (VFIO passthrough, feature gates): [26.7 KubeVirt DRA](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/26.7/gpu-operator-kubevirt-dra.html).
- Getting started (default operands, ClusterPolicy readiness): [getting-started](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/getting-started.html).

## 6. Hands-on validation (scheduled)

LAB 05 (article 05): install the operator on the Path-B cluster *alongside* the AMI path in a
separate node group; diff `kubectl get pods -A` (operator operands vs AMI-bundled), then exercise
a driver-upgrade rollout (pause → cordon → observe state labels) on one node. Predict: which
operands appear; how long a single-node driver upgrade takes.

## 7. Blog angle

"Three ways to own a driver": the model table, the operand inventory, and the upgrade state
machine as the centerpiece — with the v26.7 `GPUCluster` note ("the DRA story now lives inside
the operator") as the forward-look.
