# A10 — Model storage & weight-loading cost (S3→NVMe, sleep mode)

> Tracker: A10 · Status: covered (D2) · Date: 2026-10-03
> Scope: why "time to first token" includes *time to first weight* — storage options, loading
> paths, sleep mode, and the cost model. Feeds article 01/06; the deferred question from A1
> (Mountpoint-S3 vs pre-pulled weights) is answered here. Completes Cluster A.

## 1. Crisp understanding — cold start = download + load

A vLLM pod's startup is: pull image → obtain weights → read them into GPU. Weight-loading is
often the dominant, *unmanaged* cost. Fermi table (BF16 weights; verify in lab):

| Model | Size (BF16) | @ NVMe ~3.5 GB/s | @ S3 ~1.25 GB/s (10 Gbps) |
| --- | --- | --- | --- |
| Qwen3.5-0.8B | ~1.6 GiB | <1 s | ~1.3 s |
| Llama-3.1-8B | ~16 GiB | ~5 s | ~13 s |
| 70B-class | ~140 GiB | ~40 s | ~112 s |
| DeepSeek-R1-class (671B) | ~1.3 TiB (FP8 ≈ ½) | ~6 min | ~18 min |

Two verified pathological cases (the real story): default safetensors loading is **mmap/lazy** —
ideal on local SSD, catastrophic on network filesystems where per-shard small random reads
explode (GKE+A3M+Lustre: **94 min → 14 min** with `--safetensors-load-strategy eager`;
GCSFuse without cache: **4 hours for a 7B**; Lustre: 2 h for DeepSeek-R1). Eager reads whole
files sequentially — at the cost of CPU RAM (measured peak 130 → 542 GiB/node for DeepSeek-R1 on
16 ranks). Historical contrast: a warm OS page cache turns a 100 s cold 7B load into ~1 s.

## 2. The storage options (verified mechanics)

1. **Pod-start download** (HF hub / `hf_transfer` → `emptyDir`/PVC): simplest; cost = download
   time; cache dies with the pod unless PV-pinned.
2. **Mountpoint-for-S3 CSI mount**: bucket-as-filesystem. Verified knobs that matter:
   throughput ceiling defaults to **instance bandwidth** on EC2 (10 Gbps elsewhere), override
   with `--maximum-throughput-gbps`; `--max-threads` (16 default) for concurrent reads;
   8 MiB part size; prefetch window ≤2 GiB/file handle; CSI `cache: emptyDir|ephemeral` local
   caching; and the **`s3.csi.aws.com/agent-not-ready:NoExecute` node taint** to avoid pod-races
   at node startup. Pair with vLLM's *eager* safetensors strategy over FUSE [V which default in
   your image].
3. **`runai_streamer` direct-from-S3**: `vllm serve s3://bucket/model --load-format runai_streamer`
   (installs as vLLM optional dependency; S3-compatible stores via
   `RUNAI_STREAMER_S3_USE_VIRTUAL_ADDRESSING=0 AWS_ENDPOINT_URL=...`). No FUSE layer; parallel
   streaming into ranks.
4. **Pre-baked AMI / instance-store NVMe warm pool**: weights baked on the p5's 8×3.84 TB NVMe
   (or via SSM/launch-time copy) — fastest and most predictable; cost = AMI churn per model
   version. Good for big static models; bad for LoRA-heavy fleets.
5. **EFS**: fine for shared *small* artifacts (LoRA adapters, tokenizers), not for 100+ GiB
   weights.
6. **Autoscaler pre-warm**: Kueue ProvisioningRequest / Karpenter scale-up while pods are gated —
   pull images/weights *during* the gang wait (A8 tie-in).

## 3. Sleep mode (verified) — the multi-model / RL lever

`--enable-sleep-mode` (+ **`VLLM_SERVER_DEV_MODE=1`** to expose the HTTP endpoints):

- **Level 1**: weights **offloaded to CPU RAM** (needs enough host RAM), KV cache discarded —
  for waking the *same* model; wake restores weights.
- **Level 2**: weights *and* KV discarded (rope-scaling buffers stay in CPU) — for waking a
  *different* model or a weight update; restore via
  `wake_up?tags=weights` → `collective_rpc` `reload_weights` → `wake_up?tags=kv_cache`.
- Fine-grained `tags=` wake avoids OOM during RLHF weight sync (allocate weights, skip KV until
  the update lands). Works with TP/PP; frees "up to 90%+" of GPU memory.
- Endpoints: `POST /sleep?level=1|2`, `POST /wake_up?tags=`, `POST /collective_rpc`, `GET
  /is_sleeping` — **dev-mode gated**, so it's a platform-engineering primitive (an operator can
  expose it safely), not a public API.

## 4. Decision guidance (blog-ready)

| Workload | Storage recipe |
| --- | --- |
| One model, big GPU fleet | runai_streamer from S3 **or** pre-baked NVMe (largest models) |
| Many models, one fleet (switch often) | sleep-mode level 2 + reload, weights in S3/NVMe |
| RLHF / weight updates | sleep-mode level 2 + `tags=weights` wake |
| LoRA-heavy | base weights warm (NVMe/streamer) + adapters from EFS |
| Cold-start-sensitive autoscaling | pre-warm pools + Kueue-gated provisioning; measure "load took" from vLLM logs |

The measurable KPI: vLLM logs **"Loading weights took Xs"** (plus download time) — put it on
your Grafana panel next to TTFT, because *effective* cold-start TTFT includes it (L1/K2 tie-in).

## 5. Doubt questions → status

- A1's deferred Q (Mountpoint-S3 cold start vs pre-pulled NVMe): **answered** — Mountpoint with
  defaults is bounded by S3/network bandwidth and the mmap pitfall; pre-baked NVMe wins for big
  models; runai_streamer is the middle path. Exact numbers → LAB step 11.
- DCGM-under-Auto-Mode question stays deferred → D5.
- Open [?]: whether sleep mode composes with every parallelism/quant config on Qwen3.5 (hybrid
  GDN state handling) — **[V in lab]**.

## 6. Verified facts (sources, accessed 2026-10-03)

- Sleep mode: [vLLM docs](https://docs.vllm.ai/en/stable/features/sleep_mode/) (levels, tags,
  endpoints, dev-mode gate).
- runai_streamer: [vLLM docs](https://docs.vllm.ai/en/v0.28.0/models/extensions/runai_model_streamer/)
  (S3 + S3-compatible examples).
- Mountpoint perf + CSI attributes + readiness taint:
  [CONFIGURATION.md](https://github.com/awslabs/mountpoint-s3/blob/main/doc/CONFIGURATION.md),
  [CSI CONFIGURATION.md](https://github.com/awslabs/mountpoint-s3-csi-driver/blob/main/docs/CONFIGURATION.md).
- Safetensors pathology + eager flag: [vllm#24469](https://github.com/vllm-project/vllm/pull/24469);
  cold/warm cache numbers: [vllm#3185](https://github.com/vllm-project/vllm/pull/3185).

## 7. Hands-on validation (scheduled)

LAB 01 **step 11**: on the Path-B cluster with Qwen3.5-0.8B: (a) HF download to emptyDir vs
(b) `runai_streamer s3://` vs (c) pre-baked NVMe — record "Loading weights took" from each;
then sleep/wake round-trip timings (level 1 and level 2) via the dev-mode endpoints. Predict the
three load times before measuring.

## 8. Blog angle

"Your autoscaler promised 30-second scale-up. The weights take four minutes." Open with the
Fermi table, walk the mmap/Lustre horror story, then the six-option decision table and sleep
mode as the *in-memory* answer to model churn.
