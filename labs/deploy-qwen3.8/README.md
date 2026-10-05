# LAB — Phase-1 deploy: Qwen3.8-27B-FP8 on EKS, 1 GPU/replica, scaled by Karpenter

> Implements §5 of `deployment/qwen3.8-27b-hosting-design.md` (rev 2).
> Model: `Qwen/Qwen3.8-27B-FP8` (official FP8, block-128). Phase-2 (llm-d / P/D) is a **later
> review** gated on measured SLO/cost — do not build it now.
> Placeholders used throughout: `CLUSTER_NAME=infer-lab`, `REGION=us-east-1`,
> `BUCKET=infer-lab-weights`. Replace before running.
> Cost: pilot ≈ $2.24/hr (g6e.2xlarge) or $4.00/hr (g7e.4xlarge) + control plane. Destroy when idle.

## 0. Prerequisites (fresh account)

```bash
# quotas (request if needed): G-family vCPUs for g6e.2xlarge / g7e.4xlarge
aws service-quotas get-service-quota --service-code ec2 --quota-code L-12181C0F   # Running on-demand standard (A/G…) [V code per region]
# tooling: awscli v2, kubectl, eksctl (>= 0.2xx), helm 3; Karpenter pinned v1.14.x
```

IAM: an admin principal (SSO recommended), IMDSv2 default, billing alarm. Optional: an ODCR for
the always-on baseline node (A9) — skip for the pilot.

## 1. VPC + EKS 1.36 (addons via eksctl)

```bash
eksctl create cluster -f cluster.yaml          # see cluster.yaml (addons incl. EBS CSI + Pod Identity Agent)
```
Note: **no managed GPU node group** — GPU capacity comes from Karpenter (step 2). Keep the tiny
CPU MNG in `cluster.yaml` for add-on pods if you don't want Karpenter to own them.

## 2. Karpenter (v1.14) + IAM

Follow Karpenter's EKS getting-started for the controller policy + SQS interruption queue
(one cloudformation), then:

```bash
# Node role (Karpenter launches instances with it)
aws iam create-role --role-name KarpenterNodeRole-infer-lab \
  --assume-role-policy-document file://karpenter/node-trust.json
aws iam attach-role-policy --role-name KarpenterNodeRole-infer-lab \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
aws iam attach-role-policy --role-name KarpenterNodeRole-infer-lab \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
# (CNI policy optional with VPC CNI v1.12+)
eksctl create addon --cluster infer-lab --name ... # none needed for node role

# Controller auth: Pod Identity association (requires eks-pod-identity-agent addon — in cluster.yaml)
aws eks create-pod-identity-association --cluster-name infer-lab \
  --namespace karpenter --service-account karpenter \
  --role-arn arn:aws:iam::<ACCOUNT>:role/KarpenterControllerRole-infer-lab

helm install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --namespace karpenter --create-namespace --version 1.14.1 \
  --set "settings.clusterName=infer-lab" --set "settings.interruptionQueue=KarpenterInterruptionQueue" \
  --set serviceAccount.name=karpenter
kubectl apply -f karpenter/nodepool-cpu.yaml karpenter/ec2nodeclass.yaml \
  karpenter/nodepool-gpu.yaml karpenter/nodepool-gpu-spot.yaml
```
`EC2NodeClass` uses `amiSelectorTerms: [{alias: al2023@latest}]` — Karpenter resolves the
**AL2023-NVIDIA accelerated variant** for GPU instance types [V first launch; fallback =
explicit Bottlerocket SSM param from design §1/A6].

## 3. Device plumbing (device plugin + GFD/NFD)

```bash
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin && helm repo update
helm upgrade -i nvidia-device-plugin nvdp/nvidia-device-plugin \
  --namespace nvidia-device-plugin --create-namespace \
  --version 0.19.x -f device-plugin-values.yaml
```
`device-plugin-values.yaml` sets `gfd.enabled=true` (auto-installs NFD), tolerates the
`nvidia.com/gpu` taint, and selects GPU nodes via the AMI's `nvidia.com/gpu.present=true` label
(nodeadm, A7). **MOFED note:** harmless on this 1-GPU phase (no EFA devices); revisit at phase 2
(A5's ≥v0.19 default-on trap).

## 4. Weights → S3 (+ vLLM's S3 access)

```bash
aws s3api create-bucket --bucket infer-lab-weights --region us-east-1
pip install "huggingface_hub[cli]" && hf download Qwen/Qwen3.8-27B-FP8 --local-dir ./ckpt
aws s3 sync ./ckpt s3://infer-lab-weights/qwen3.8-27b-fp8/
# vLLM (runai_streamer) reads S3 with the pod's IRSA/Pod-Identity creds:
aws iam create-role --role-name vllm-s3-read-infer-lab  # + inline s3:GetObject on the bucket
aws eks create-pod-identity-association --cluster-name infer-lab \
  --namespace vllm --service-account vllm --role-arn arn:aws:iam::<ACCOUNT>:role/vllm-s3-read-infer-lab
```
(EFS/Mountpoint not needed — runai_streamer reads `s3://` directly, A10.
**Lustre?** No — FSx-for-Lustre + GPUDirect Storage is a *big-model / multi-node-TP* play
(405B: 18 min → 6.4 s via fastsafetensors GDS; needs EFA plumbing + GDS driver + pre-sharded
checkpoints). For a ~30 GB FP8 model on one GPU, Run:ai Model Streamer from S3 gives engine
readiness in ~20–60 s. Revisit only at phase-2 (design §8) or 405B-class models. Beware the
naive-vLLM-on-Lustre mmap trap (#24469: 94 min → 14 min *with* eager load).)

## 5. Deploy vLLM (1 GPU)

```bash
kubectl create ns vllm
# create secret-hf.yaml ONLY if serving straight from HF hub (gated repo) instead of S3
kubectl apply -f vllm/deployment.yaml vllm/service.yaml
kubectl -n vllm rollout status deploy/vllm-qwen3-8-27b    # watch "Loading weights took"
```
Manifest notes (all design-§2 D7): FP8 KV, MTP n=2, `max_num_batched_tokens=8192` (explicit —
the 2048 default is a *test* value), `max_num_seqs=64`, `gpu_memory_utilization=0.92`, prefix
caching explicit, sleep-mode env flags present but **commented** (enable for scale-to-zero eval).
Image tag: **pin from the Qwen3.8 recipe** [V recipes.vllm.ai/Qwen/Qwen3.8-27B] — the arch needs
a recent vLLM (NVFP4 card cites ≥0.26.1-dev lineage).

## 6. Autoscaling (pick ONE)

- **KEDA (provided):** `vllm/keda-scaledobject.yaml` — scales 1→4 replicas on
  `sum(vllm:num_requests_running)` vs threshold 40 (≈ KV headroom per tier-2). Install KEDA first
  (`helm install keda kedacore/keda`). Spot burst: the `nodepool-gpu-spot.yaml` NodePool accepts
  the burst replicas if you add `karpenter.sh/capacity-type: spot` nodeSelector per replica group
  (keep baseline replicas on on-demand; A9 disruption notes).
- **HPA + prometheus-adapter (alternative):** `vllm/hpa-prometheus-adapter.yaml` — requires
  prometheus-adapter configured for `vllm:num_requests_running` (SeriesQuery). Use if you already
  run the adapter; otherwise prefer KEDA.

**Spot rule (A9):** baseline replica pods carry `karpenter.sh/do-not-disrupt: "true"`; only burst
replicas may ride Spot, and each has a PDB. Eviction cost = weight reload (+cold KV).

## 7. Validate + benchmark (the tier gate)

```bash
kubectl apply -f validate/probe-nvidia-smi.yaml        # GPU green, driver 580/CUDA13 visible
kubectl -n vllm port-forward svc/vllm 8000:8000
curl localhost:8000/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model":"qwen3.8-27b","messages":[{"role":"user","content":"Say hi in 5 words"}],
  "chat_template_kwargs":{"enable_thinking":false}}'    # thinking OFF for the latency path
bash validate/bench.sh                                  # concurrency sweep + metrics
```
`bench.sh` sweeps concurrency {8,16,32,64} (ISL 2048 / OSL 512) and records TTFT p50/p95,
TPOT p50/p99, aggregate tok/s → fill the design §3 table. Gate: TPOT p99 ≤ 50 ms and TTFT p95 ≤
2 s at your target concurrency, else tier up (g6e → g7e; FP8 → NVFP4 after the SM120-JIT check).
Also record: prefix-cache hit rate (shared system prompt) and GDN-state footprint at load
(design §0's 142 MiB/seq estimate).

## 8. Phase-2 gate (do NOT build now)

Record and revisit when ANY of: (a) ≥3 sustained replicas; (b) prefill-share >~70% w/ hard TPOT
SLO after `max_num_batched_tokens` tuning; (c) 64k+ RAG mix dominating TTFT p95 → then evaluate
**llm-d** (and its P/D mode) using the J4/H-series notes.

## 9. Teardown

```bash
kubectl delete ns vllm nvidia-device-plugin karpenter node-feature-discovery --ignore-not-found
eksctl delete cluster -f cluster.yaml   # + delete S3 bucket if desired
```

## Files
| File | Purpose |
| --- | --- |
| `cluster.yaml` | eksctl: EKS 1.36 + addons (VPC CNI, CoreDNS, kube-proxy, EBS CSI, Pod Identity Agent, Mountpoint-S3 CSI optional) |
| `karpenter/*` | EC2NodeClass (AL2023, accelerated variant) + CPU NodePool + GPU on-demand & spot NodePools |
| `device-plugin-values.yaml` | NVIDIA device plugin + GFD/NFD |
| `s3-weights.sh` | bucket + upload + S3-read role |
| `vllm/*` | Deployment (exact flag set), Service, KEDA ScaledObject (+HPA alternative) |
| `validate/*` | nvidia-smi probe + bench sweep script |
