# Validation & benchmark (design §5 step 9 — the D3 evidence gate)
# 1) GPU/host green;  2) one completion round-trip;  3) concurrency sweep;  4) tier gate.
set -euo pipefail
NS=vllm
SVC=vllm

echo "== 1) node + GPU probe =="
kubectl get nodes -L nvidia.com/gpu.present -L karpenter.k8s.aws/instance-type
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: { name: nvidia-smi-probe, namespace: vllm }
spec:
  restartPolicy: Never
  nodeSelector: { karpenter.k8s.aws/instance-family: g7e }   # match your tier
  tolerations: [{ key: nvidia.com/gpu, operator: Exists, effect: NoSchedule }]
  containers:
    - name: nvidia-smi
      image: nvcr.io/nvidia/cuda:13.0.0-base-ubuntu24.04      # or amazonlinux AL2023 + toolkit env
      command: ["bash","-c","nvidia-smi && nvidia-smi topo -m && sleep 1"]
      resources:
        limits: { nvidia.com/gpu: "1" }
EOF
kubectl -n $NS wait --for=condition=Ready pod/nvidia-smi-probe --timeout=120s
kubectl -n $NS logs nvidia-smi-probe

echo "== 2) one chat completion (thinking OFF for the latency path) =="
kubectl -n $NS port-forward svc/$SVC 8000:8000 >/dev/null 2>&1 &
PF=$!; sleep 3
curl -s localhost:8000/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model":"qwen3.8-27b",
  "messages":[{"role":"user","content":"Reply with exactly: READY"}],
  "chat_template_kwargs":{"enable_thinking":false}, "max_tokens":16}' | head -c 600; echo
kill $PF

echo "== 3) concurrency sweep (ISL 2048 / OSL 512) =="
for C in 8 16 32 64; do
  kubectl -n $NS port-forward svc/$SVC 8000:8000 >/dev/null 2>&1 &
  PF=$!; sleep 2
  vllm bench serve \
    --backend openai-chat \
    --model qwen3.8-27b \
    --host localhost --port 8000 \
    --num-prompts 128 --random-input-len 2048 --random-output-len 512 \
    --max-concurrency $C \
    --percentile-metrics ttft,tpot,itl \
    --save-result "bench-c${C}.json"           # [V exact flag names per your vLLM version]
  kill $PF
done

echo "== 4) tier gate =="
# Record from bench-c*.json: TTFT p50/p95, TPOT p50/p99, aggregate tok/s at each concurrency.
# Gate (design §3): TPOT p99 ≤ 50ms AND TTFT p95 ≤ 2s at target concurrency, else tier up:
#   g6e.2xlarge → g7e.4xlarge (FP8) → g7e.8xlarge + NVFP4 W4A4 (after SM120-JIT check).
# Also record: vllm:prefix_cache_{queries,hits} (PromQL rate), vllm:kv_cache_usage_perc,
#   "Loading weights took" from pod logs, and GDN-state footprint vs the 142 MiB/seq estimate.
