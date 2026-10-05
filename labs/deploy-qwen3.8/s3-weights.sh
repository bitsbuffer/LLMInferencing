#!/usr/bin/env bash
# Weights → S3 + the vLLM pod's S3-read identity (runai_streamer reads s3:// directly, A10).
set -euo pipefail
CLUSTER=${CLUSTER:-infer-lab}
REGION=${REGION:-us-east-1}
BUCKET=${BUCKET:-infer-lab-weights}
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

# 1) bucket
aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION" 2>/dev/null || true

# 2) download the official FP8 checkpoint and sync to S3
pip install "huggingface_hub[cli]"
hf download Qwen/Qwen3.8-27B-FP8 --local-dir ./ckpt-qwen3.8-27b-fp8
aws s3 sync ./ckpt-qwen3.8-27b-fp8 "s3://$BUCKET/qwen3.8-27b-fp8/" --no-progress

# 3) S3-read role for the vllm service account (Pod Identity)
aws iam create-role --role-name vllm-s3-read \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"pods.eks.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession","sts:SetSourceIdentity"]}]}'
aws iam put-role-policy --role-name vllm-s3-read --policy-name s3-read \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:ListBucket\"],\"Resource\":[\"arn:aws:s3:::$BUCKET\",\"arn:aws:s3:::$BUCKET/*\"]}]}"
aws eks create-pod-identity-association --cluster-name "$CLUSTER" \
  --namespace vllm --service-account vllm \
  --role-arn "arn:aws:iam::$ACCOUNT:role/vllm-s3-read"
echo "OK — vllm SA can read s3://$BUCKET/qwen3.8-27b-fp8/"
