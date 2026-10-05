# LAB 01 — EKS 1.36 GPU cluster bring-up + addon stack (feeds article 01)

> Covers tracker topics A1, A2 (A3–A10 get their own labs later in article 01/02 series).
> Scheduled: 2026-10-03. Status: **not run**. Est. AWS cost: control plane (~$0.10/h) + one
> g6e.2xlarge spot (~$0.5/h) + Karpenter; destroy immediately after.
> Baselines: EKS 1.36, Karpenter v1.14.x, Qwen3.5-0.8B as the first served model (article 06 lab).

## Predictions to write down BEFORE running (the self-test ritual)

- P1: Number of `kube-system` pods on an Auto Mode cluster vs a Karpenter+addons cluster: ___
- P2: Time from `eksctl create cluster` → first Ready node (Auto Mode): ___ min
- P3: Time from NodePool creation → g6e node Ready + `nvidia-smi` pod Succeeded: ___ min
- P4: `kubectl top pod` memory of `coredns`/`vpc-cni` pods: ___ MiB

## Prerequisites

- AWS CLI v2 + `eksctl` (current), Helm 3, kubectl; region with g6e capacity.
- Quota check for the instance family you plan to demo (P quotas especially) — record the quota
  CLI call used.

## Path A — Auto Mode (fastest green GPU pod)

1. Create cluster with Auto Mode enabled (eksctl `computeConfig` / `--enable-auto-mode` per
   current eksctl syntax [V]).
2. Apply the NodePool from the EKS docs pattern:

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata: { name: gpu }
spec:
  template:
    spec:
      nodeClassRef: { group: eks.amazonaws.com, kind: NodeClass, name: default }
      requirements:
        - key: eks.amazonaws.com/instance-family
          operator: In
          values: [g6e]
      taints: [{ key: nvidia.com/gpu, effect: NoSchedule }]
```

3. Run the probe pod (`nvidia-smi` on AL2023-minimal with `nvidia.com/gpu: 1` request +
   `compute-type: auto` selector + toleration, per EKS docs).
4. Verify: `kubectl get pods -A` — confirm **no visible NVIDIA device-plugin DaemonSet**;
   `kubectl describe node` → labels (`eks.amazonaws.com/instance-gpu-name`), allocatable
   `nvidia.com/gpu: 1`; check driver version in the probe output.
5. Record: which add-ons are invisible vs present (`aws eks list-addons`), and whether
   `describe-addon-versions ... --kubernetes-version 1.36` shows `computeTypes: [auto]` for
   `vpc-cni`, `kube-proxy`, `coredns`, `aws-ebs-csi-driver`, `eks-pod-identity-agent`.

## Path B — Karpenter + explicit addons (article 02 on-ramp)

1. Cluster 1.36 with OIDC; install add-ons with Pod Identity associations
   (`addonsConfig.autoApplyPodIdentityAssociations: true` in eksctl): `vpc-cni`, `kube-proxy`,
   `coredns`, `aws-ebs-csi-driver`, `eks-pod-identity-agent`, `aws-mountpoint-s3-csi-driver`.
2. Install Karpenter v1.14.x (Helm, IRSA or Pod Identity), create an `EC2NodeClass` with
   `amiFamily: AL2023` + alias `al2023@latest` for x86_64 and a GPU NodePool (g6e).
3. Same probe pod (without the Auto Mode selector).
4. **Version snapshot (deliverable):** save
   `aws eks describe-addon-versions --kubernetes-version 1.36 --query 'addons[].{name:addonName,ver:addonVersions[0].addonVersion}'`
   to `bench/addon-versions-1.36.json` — resolves the VPC CNI v1.22-vs-v1.23 doc-table
   discrepancy and pins everything else.
5. Verify Pod Identity: describe the `vpc-cni` add-on's association; confirm IAM role attached
   without OIDC trust churn.
6. NFD + GFD + NRT (feeds A4): `helm install -n node-feature-discovery nfd
   oci://registry.k8s.io/nfd/charts/node-feature-discovery --version 0.19.0 --create-namespace
   --set topologyUpdater.enable=true` (GFD ships with the device plugin from step 1/2). Predict:
   `nvidia.com/gpu.product` / `gpu.memory` / `cuda.driver.major` values for the chosen GPU: ___;
   NRT zone count on the node: ___. Then verify: `kubectl get node -L nvidia.com/gpu.product -L
   nvidia.com/gpu.memory -L nvidia.com/cuda.driver.major` and
   `kubectl get noderesourcetopologies.topology.node.k8s.io -o wide`.
7. EFA device plugin (feeds A5; Path B): `helm repo add eks https://aws.github.io/eks-charts &&
   helm install efa eks/aws-efa-k8s-device-plugin -n kube-system`; add
   `spec.networkInterfaces` to the EC2NodeClass (card 0: ENA at device 0 + efa-only at device 1).
   Predict: `vpc.amazonaws.com/efa` allocatable on the node: ___; does a probe pod requesting
   1 EFA + `hugepages-2Mi` see the efa libfabric provider with zero env vars (`fi_info -p efa`)? ___
   Then verify both. (Path A note: Auto Mode EFA goes via `NodeClass.advancedNetworking.networkInterfaces`.)
8. Bottlerocket NVIDIA AMI (feeds A6): add a second EC2NodeClass with
   `amiSelectorTerms: [{ssmParameter: /aws/service/bottlerocket/aws-k8s-1.36-nvidia/x86_64/latest/image_id}]`
   (or `alias: bottlerocket@latest` — check whether the -nvidia variant auto-resolves for GPU
   pools). Predict: `nvidia.com/gpu` allocatable without installing any plugin: ___; does the
   device plugin show up as a pod? ___ Then verify. Then via
   `kubectl debug node/<n> -it --image=ubuntu --profile=sysadmin` +
   `chroot /host apiclient set settings.kubelet-device-plugins.nvidia.enabled=false`, confirm
   allocatable → 0, re-enable.
9. Gang scheduling w/ Kueue (feeds A8; Path B): install Kueue v0.19.2 (helm, kubernetes-sigs);
   create ClusterQueue + LocalQueue with an `nvidia.com/gpu` ResourceFlavor; submit an LWS
   (leader + 2 workers × 1 GPU) annotated
   `kueue.x-k8s.io/podset-required-topology: cloud.provider.com/topology-rack` +
   `kueue.x-k8s.io/podset-group-name`. Predict: pods sit Pending behind a **schedulingGate** until
   the Workload is admitted (yes/no?); group admits and starts atomically (yes/no?); then submit a
   second LWS whose topology can't fit and confirm it stays gated. Verify via
   `kubectl get workloads.kueue.x-k8s.io` + pod conditions.
10. Placement groups + reserved capacity (feeds A9): create a **cluster** placement group; add
   `placementGroupSelector: {name: <pg>}` to the GPU EC2NodeClass; launch 2 nodes and confirm
   single-AZ placement; create an ODCR/Capacity-Block and a NodePool with
   `karpenter.sh/capacity-type: reserved` + `capacityReservationSelectorTerms`; verify labels
   (`karpenter.k8s.aws/capacity-reservation-id|type`) and Karpenter's reserved-priority behavior.
   Add `karpenter.sh/do-not-disrupt: "true"` to a probe pod and trigger node expiry — confirm the
   eviction is blocked. Predict first: what happens if the NodeClass spans 2 AZs with a cluster PG?
11. Weight loading (feeds A10; needs the vLLM image — article 06 on-ramp): serve
   Qwen/Qwen3.5-0.8B three ways and record the **"Loading weights took"** log line from each:
   (a) HF download → emptyDir; (b) `--load-format runai_streamer` with `s3://<bucket>/qwen3.5-0.8b`;
   (c) pre-baked NVMe (or hostPath scratch). Then
   `VLLM_SERVER_DEV_MODE=1 ... --enable-sleep-mode`: time `POST /sleep?level=1` → `/wake_up` and
   `POST /sleep?level=2` → `wake_up?tags=weights` → `collective_rpc reload_weights` →
   `wake_up?tags=kv_cache` round-trips. Predict the three load times and both wake times first.
12. Topology capture (feeds B1; on a GPU node): run `nvidia-smi topo -m`, `nvidia-smi nvlink -s`,
   and an all-reduce with `NCCL_DEBUG=INFO` — predict whether NVLS shows up in the logs (NVLink-4
   switch systems), then verify. Save outputs to `bench/topo-<instance>.txt` for the article-03
   bandwidth-hierarchy table.

## Path C — DRA driver extension (optional; feeds A3, article 01 sidebar)

1. On the Path-B cluster (DRA needs static capacity; **not** Auto Mode), install the driver:
   `helm install dra-driver-nvidia-gpu oci://registry.k8s.io/dra-driver-nvidia/charts/dra-driver-nvidia-gpu
   --version 0.5.0 -n dra-driver-nvidia-gpu --create-namespace --set gpuResourcesEnabledOverride=true`
   (current per kubernetes-sigs v0.5.0, 2026-08-19; EKS doc example pins 0.4.1 [V — record which
   you used]). Disable the NVIDIA device plugin on these nodes first (DRA + plugin can't coexist).
2. Create a `ResourceClaimTemplate` on `gpu.nvidia.com` with a CEL selector
   (e.g. `device.capacity['gpu.nvidia.com'].memory.isGreaterThan(quantity('40Gi'))`), then run the
   same `nvidia-smi` probe referencing it via `pod.spec.resourceClaims` + `resources.claims`.
3. Verify: `kubectl get resourceslices` (attributes: model, memory, driver version, NUMA/PCIe),
   `kubectl describe pod` (allocatedResourcesStatus / health), and a second pod sharing the claim.
4. Predictions: ResourceSlice device count per node: ___; claim→Running latency: ___ s.



## Verification & teardown

- `kubectl top pod -n kube-system` → fill P1/P4.
- Timestamps from eksctl logs → fill P2/P3.
- `eksctl delete cluster` (and confirm Karpenter nodeclaims GC'd; record actual bill in `notes.md`).

## Definition of done for this lab

- [ ] `addon-versions-1.36.json` saved
- [ ] Both paths' `nvidia-smi` probe green (screenshot)
- [ ] Predictions P1–P4 filled + reconciled in `bench/notes.md`
- [ ] Tracker A1/A2 re-scored to D3 (hands-on evidence) when done
