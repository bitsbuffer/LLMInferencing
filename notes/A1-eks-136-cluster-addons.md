# A1 — EKS 1.36 control plane + addon stack

> Tracker: A1 · Status: covered (D2) · Date: 2026-10-03
> Scope: what the EKS control plane is, and which add-ons turn it into a GPU-inference platform.
> Feeds article 01 ("Building the GPU cluster: EKS + the right plugins").

## 1. Crisp understanding

The EKS control plane is AWS-run (API server, etcd, scheduler, controller manager; multi-AZ; you
never see the machines). It is *not* what makes a cluster usable. A cluster becomes a platform via
the **add-on stack** — AWS-managed or self-managed deployments of the pieces the control plane does
not ship. For an LLM-inference cluster the minimal stack is:

| Add-on (EKS name) | Job | Notes verified 2026-10 |
| --- | --- | --- |
| `vpc-cni` (Amazon VPC CNI) | Pod IPs from the VPC; trunk ENIs; security-groups-for-pods; network policy agent | Latest listed for 1.36: **v1.22.4-eksbuild.3** (pod-networking page) vs **v1.23.1-eksbuild.1** (managing-vpc-cni page) — the two doc tables disagree [V]; resolve via `describe-addon-versions`. Upgrade rule: **one minor at a time**. |
| `kube-proxy` | Service VIPs / iptables-eBPF plumbing | Version per K8s minor via `describe-addon-versions`. |
| `coredns` | Cluster DNS | Same. |
| `eks-pod-identity-agent` | Pod Identity: EKS-API-managed IAM bindings for service accounts | Recommended over IRSA; DaemonSet on nodes. |
| `aws-ebs-csi-driver` | EBS volumes (model scratch, logs, offload disks) | On **Auto Mode** you skip the controller; provisioner becomes `ebs.csi.eks.amazonaws.com` (vs `ebs.csi.aws.com` self-managed). |
| `aws-efs-csi-driver` | Shared RWX storage (LoRA adapters, shared caches) | Classic CSI addon. |
| `aws-mountpoint-s3-csi-driver` | Mount S3 buckets as files — model weights at scale | Cost/caching tradeoffs → topic A10. |
| (self-managed) Karpenter v1.14.x | Just-in-time GPU node provisioning | Now `kubernetes-sigs/karpenter`; v1.14.0 published 2026-07-11, v1.14.1 current. |

**What the add-on stack does NOT include** (each is its own topic): NVIDIA device plugin / DRA
drivers (A3), EFA device plugin (A5), GPU Operator components (D4–D5), observability (K2).

## 2. Why 1.36 as the baseline (verified release facts)

K8s 1.36 "Haru" released upstream 2026-04-22; on EKS 2026-06-02. Standard support 14 months
(until 2027-08-02). GPU-relevant wave:

- **DRA continues to mature** (DRA core went GA in 1.34): in 1.36, **AdminAccess** and
  **Prioritized Alternatives in device requests** graduate to Stable; **partitionable devices**,
  **consumable capacity**, **device taints & tolerations**, **ResourceClaim device status
  (health)**, **binding conditions**, and **extended-resource support** (bridge from legacy
  `nvidia.com/gpu` requests to DRA — clusters can migrate gradually) are beta, enabled by default.
- DRA **alpha** in 1.36: ResourceClaims for workloads/PodGroups, **node allocatable resources**
  (CPU/memory under DRA), **ResourcePoolStatusRequest** (pool availability snapshots), **device
  metadata in containers** (versioned JSON + CDI bind-mounts at well-known paths).
- Platform features: **mutating admission policies** (CEL, no webhooks), user namespaces GA,
  node log query, fine-grained kubelet API authorization, in-place pod-level resource resize,
  VolumeGroupSnapshot.

Blog-ready takeaway: *pick the newest EKS minor you can, because the DRA feature wave only lands on
new minors — and every GPU-ops feature you'll blog about (device health in Pod status, device
taints for faulty GPUs, prioritized fallback lists like "H100 → A100") is DRA.*

## 3. IAM wiring for add-ons (verified)

- **Pod Identity is the recommended mechanism**: EKS-API-managed associations (no per-cluster OIDC
  trust churn; roles reusable across clusters). The add-on API can create/own the association in
  the same call as the add-on (`preserve` option prevents cascade delete).
- **Precedence rule:** if both an IRSA `serviceAccountRoleArn` and a Pod Identity association are
  set and the agent is installed, `serviceAccountRoleArn` is **ignored**. In eksctl, setting both
  is a validation error.
- eksctl helpers: `addon.podIdentityAssociations`, `addonsConfig.autoApplyPodIdentityAssociations`
  (apply AWS's *suggested* policy automatically), `addon.useDefaultPodIdentityAssociations`.
- Add-on version support policy: **latest + one prior**; security fixes backported as eksbuild
  versions. Compatibility per K8s version via:
  `aws eks describe-addon-versions --addon-name <name> --kubernetes-version 1.36`
  (response now carries `computeTypes`: `ec2` / `auto` / `hybrid` — i.e. does this add-on run under
  Auto Mode?). On Auto Mode the platform-level controllers (CNI/kube-proxy/CoreDNS/EBS/Pod-Identity)
  run on AWS-owned infra and may be invisible in your account; anti-affinity rules keep add-on pods
  on supported compute in mixed clusters.

## 4. Doubt questions → status

| Question (from research map A1) | Status |
| --- | --- |
| Does Auto Mode manage the EFA device plugin? | **Answered (moved to A2):** Auto Mode does **not** support DRA at all; it works with the EFA **device plugin** and takes EFA NIC config via `NodeClass.advancedNetworking.networkInterfaces` (`interfaceType: efa-only`). |
| Is DRA production-ready for vLLM serving on 1.36 vs the device plugin? | **Partially answered** (core GA 1.34; 1.36 beta wave + extended-resources bridge). Final verdict → topic A3 deep-dive. |
| DCGM exporter placement under Auto Mode? | **Deferred → D5** (not answerable without deciding observability stack). |
| Mountpoint-S3 cold-start cost vs pre-pulled weights on NVMe? | **Deferred → A10**. |

## 5. Verified facts (with sources, accessed 2026-10-03)

- EKS version lifecycle & 1.36 dates:
  [kubernetes-versions](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html),
  [1.36 what's-new](https://aws.amazon.com/about-aws/whats-new/2026/06/amazon-eks-distro-kubernetes-version-1-36/).
- K8s 1.36 release: [release blog](https://kubernetes.io/blog/2026/04/22/kubernetes-v1-36-release/);
  DRA detail: [DRA 1.36 updates](https://kubernetes.io/blog/2026/05/07/kubernetes-v1-36-dra-136-updates/).
- Add-on catalog & Auto Mode visibility:
  [add-ons](https://docs.aws.amazon.com/eks/latest/userguide/eks-add-ons.html),
  [available add-ons](https://docs.aws.amazon.com/eks/latest/userguide/workloads-add-ons-available-eks.html),
  [compat check](https://docs.aws.amazon.com/eks/latest/userguide/addon-compat.html).
- VPC CNI versions & one-minor-at-a-time rule:
  [pod-networking](https://docs.aws.amazon.com/eks/latest/userguide/pod-networking.html),
  [managing-vpc-cni](https://docs.aws.amazon.com/eks/latest/userguide/managing-vpc-cni.html).
- EBS CSI incl. Auto Mode provisioner:
  [ebs-csi](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html).
- Pod Identity & add-on IAM:
  [add-ons-iam](https://docs.aws.amazon.com/eks/latest/userguide/add-ons-iam.html),
  [eksctl PIA](https://docs.aws.amazon.com/eks/latest/eksctl/pod-identity-associations.html).
- Karpenter: [releases](https://github.com/kubernetes-sigs/karpenter/releases) (v1.14.x, Jul 2026).

## 6. Hands-on validation (scheduled lab)

`labs/01-cluster-addons/LAB.md` — bring up EKS 1.36 two ways (Auto Mode; Karpenter + addons),
snapshot `describe-addon-versions` JSON, verify pod-identity wiring, record time-to-ready.
Estimates to write down first: expected add-on pod count/memory, cluster-ready time.

## 7. Blog angle (article 01)

"The plugin stack you actually need" checklist + the traps nobody warns you about: the MOFED
default that hijacks `/dev/infiniband` from the EFA plugin (A5/A3 detail — verified below in A2
notes), one-minor-at-a-time CNI upgrades, and Pod Identity precedence.
