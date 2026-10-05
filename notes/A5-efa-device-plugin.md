# A5 — EFA device plugin (`vpc.amazonaws.com/efa`) + efa-only vs EFA-with-ENA on EKS

> Tracker: A5 · Status: covered (D2) · Date: 2026-10-03
> Scope: the *mechanics* of giving pods EFA devices on EKS — plugin install, resource accounting,
> interface provisioning layers, the interface-type taxonomy. Protocol/SRD/RDMA depth lives in
> cluster C (article 04); NCCL-over-EFA tuning in cluster G. Feeds article 01 (+04).

## 1. Crisp understanding

EFA devices reach pods through **three cooperating layers**, and A5 is the middle one:

1. **Node provisioning layer — attaches the EFA interfaces at instance launch** (they cannot be
   added later; EFA ENIs attach only at launch or to stopped instances). Options, all verified:
   - **Karpenter `EC2NodeClass.spec.networkInterfaces[]`** — `{networkCardIndex, deviceIndex,
     interfaceType: interface | efa-only}` with CEL validation: primary must be `interface`, no
     duplicate (card, device) pairs, **exactly one EFA device per network card**. If a pod
     requests `vpc.amazonaws.com/efa` but no explicit config exists, Karpenter dynamically
     *maximizes* EFA interfaces for the instance type.
   - **Auto Mode `NodeClass`** (`eks.amazonaws.com/v1`) — same shape via
     `advancedNetworking.networkInterfaces`; with static config, no extra IPs/ENIs are attached
     post-launch.
   - **Managed node groups / self-managed** — launch templates (or eksctl `efaEnabled`, which
     uses the default "all interfaces EFA" config; custom layouts need launch templates).
2. **Kubelet accounting layer — the EFA device plugin**: DaemonSet (`eks/aws-efa-k8s-device-plugin`
   Helm chart from aws.github.io/eks-charts; image in AWS ECR, chart page shows tag v0.5.20 [V —
   check current at install]). It advertises EFA devices as extended resources; pods request:
   ```yaml
   resources:
     limits:   { vpc.amazonaws.com/efa: 4, hugepages-2Mi: 8Gi }   # example from AWS docs
     requests: { vpc.amazonaws.com/efa: 4, hugepages-2Mi: 8Gi }
   ```
   (The AWS pod example pairs EFA with `hugepages-2Mi` — libfabric's EFA provider uses huge pages;
   treat hugepages as part of the standard EFA pod spec [V].)
3. **Host layer — already in the AMI**: EKS-optimized AL2023 and all Bottlerocket AMIs include the
   aws-efa-installer components (kernel module, rdma-core, libfabric). **They do NOT include the
   plugin or the DRA driver** — those are cluster installs (this topic / A3).

Note for K8s 1.34+: the DRA alternative is the **EFA DRA driver ("DRANET")** (kube-system install,
topology-aware GPU↔EFA pairing, device sharing across pods). Plugin and DRA driver **cannot
coexist on a node**; DRA pairing is automatic only on EKS-optimized AL2023 accelerated AMIs (not
Bottlerocket/custom). Also the MOFED trap: NVIDIA device plugin ≥ v0.19 mounts all
`/dev/infiniband/uverbs*` into GPU containers by default and must have `--mofed-enabled=false` on
EFA nodes (Auto Mode unaffected).

## 2. Interface taxonomy & the p5 layout (verified)

Three interface types (EC2):
| Type | IP? | Device exposed | Use |
| --- | --- | --- | --- |
| ENA (`interface`) | yes | ENA only | VPC networking, primary ENI |
| EFA (with ENA) | yes | ENA + EFA | legacy pattern; consumes IP + ENI quota |
| **EFA-only** | **no** | EFA only | the recommended EKS pattern; no conntrack settings |

**Recommended EKS pattern** (Karpenter supports *only* `interface` + `efa-only`): ENA on one device
index, **efa-only on the rest**. Karpenter design doc: no use case found for EFA-with-ENA over
this pattern.

**p5.48xlarge / p5e.48xlarge (verified numbers):** 32 network cards, **3,200 Gbps shared total**,
**IP traffic capped at 800 Gbps** (EFA gets the remainder — e.g. 400 Gbps IP ⇒ 2,800 Gbps EFA).
Canonical layout: primary ENA at card 0/device 0; **efa-only at card 0/device 1 and cards 1–31,
device 0**. p5en.48xlarge: **16 interfaces** (per the AWS HPC recipe table). Cluster placement
group required-in-practice for full cross-node bandwidth.

## 3. NCCL-over-EFA env matrix (verified from aws-ofi-nccl docs; full treatment → article 04)

| Software stack | Env needed |
| --- | --- |
| libfabric ≥1.18 + aws-ofi-nccl ≥1.7.0 (current) | none — no `FI_PROVIDER`, no `FI_EFA_USE_DEVICE_RDMA` |
| aws-ofi-nccl ≤1.5.0 + EFA GPU instances | `FI_PROVIDER=efa`, `NCCL_PROTO=simple` |
| aws-ofi-nccl 1.6.x + p4/p5 | `FI_EFA_USE_DEVICE_RDMA=1` |
| fork/OOM errors (multi-process dataloaders) | `FI_EFA_USE_HUGE_PAGE=0` |
| Never | `RDMAV_FORK_SAFE` (breaks newer kernels), `NCCL_SOCKET_NTHREADS`/`NCCL_NSOCKS_PERTHREAD` (N/A for EFA); leave `NCCL_MIN_CHANNELS`/`NCCL_BUFFSIZE` at defaults |

p5 minimums: cuda ≥12.0, nccl ≥2.18.5, aws-ofi-nccl ≥1.7.3, efa-installer ≥1.29.0 (else NCCL ≥2.19
raises libfabric errors). Topology files: build aws-ofi-nccl with `--enable-platform-aws` so it
auto-sets `NCCL_TOPO_FILE`; else set it manually (e.g. `p4de-24xl-topo.xml`) — a real regression
class seen in the wild (aws-ofi-nccl#298).

## 4. Doubt questions (self-defined) → status

| Question | Status |
| --- | --- |
| What creates the EFA interfaces — the plugin? | **No** — the provisioning layer at launch (section 1). The plugin only *counts* them. |
| Plugin resource name & pod spec? | **Answered**: `vpc.amazonaws.com/efa` (integers), paired with hugepages-2Mi. |
| efa-only vs EFA-with-ENA on EKS? | **Answered**: Karpenter/Auto Mode accept `interface` + `efa-only`; ENA+EFA dual pattern is legacy; efa-only gets no IP, no conntrack tuning. |
| Current plugin chart version? | [V] at lab time (chart page showed v0.5.20). |
| Does the same node count both plugin + DRA? | **Answered**: no — mutually exclusive (A3). |

## 5. Verified facts (sources, accessed 2026-10-03)

- Plugin install + pod spec + AMI/DRANET context:
  [device-management-efa](https://docs.aws.amazon.com/eks/latest/userguide/device-management-efa.html).
- Chart & default image tag: [eks-charts aws-efa-k8s-device-plugin](https://github.com/aws/eks-charts/tree/master/stable/aws-efa-k8s-device-plugin).
- Karpenter `networkInterfaces` + CEL rules + dynamic EFA maximization:
  [NodeClasses](https://karpenter.sh/docs/concepts/nodeclasses/),
  [design RFC](https://github.com/aws/karpenter-provider-aws/blob/main/designs/efa-for-static-capacity.md).
- p5 interface counts, 3.2 Tbps shared / 800 Gbps IP cap, canonical layout:
  [EFA accelerated instance types](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa-acc-inst-types.html),
  [P5 EFA recipe](https://github.com/aws-samples/aws-hpc-recipes/blob/main/recipes/pcs/enable_efa/README.md).
- aws-ofi-nccl env matrix: [efa-env-var.md](https://github.com/aws/aws-ofi-nccl/blob/master/doc/efa-env-var.md),
  topology regression: [aws-ofi-nccl#298](https://github.com/aws/aws-ofi-nccl/issues/298).

## 6. Hands-on validation (scheduled)

LAB 01 **step 7**: install `eks/aws-efa-k8s-device-plugin` on Path B, add a Karpenter
`EC2NodeClass.networkInterfaces` block (1×ENA + N×efa-only), probe pod requesting 1 EFA + hugepages,
run `fi_info -p efa` inside it. Predict: allocatable EFA count on the node; whether the probe sees
an efa provider without any env vars.

## 7. Blog angle

"Three layers stand between your pod and a 400-Gbps NIC" — provisioning (launch-time), accounting
(device plugin), host drivers (AMI). The p5 32-card/shared-3.2-Tbps/800-Gbps-IP numbers and the
"one EFA device per card" CEL rule are the concrete, screenshot-worthy bits.
