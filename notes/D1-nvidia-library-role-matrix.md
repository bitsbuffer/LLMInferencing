# D1 — The NVIDIA library role matrix (who actually executes your inference)

> Tracker: D1 · Status: covered (D2) · Date: 2026-10-03
> Scope: your doubt #3 answered with evidence — the cast list of libraries under vLLM on EKS,
> what each one actually executes, and the two that everyone over-credits (cuDNN, cuBLAS).
> Feeds article 05.

## 1. The matrix (verified, Oct 2026)

| Library | Role in LLM inference (vLLM on EKS) | Evidence |
| --- | --- | --- |
| **cuBLAS / cuBLASLt** | Generic GEMM underneath PyTorch; the *fallback* candidate in vLLM's linear-kernel chain — present, not the star | FP8 GEMM candidate order ends at "PyTorch" (cuBLAS) |
| **CUTLASS** | Template GEMM kernels vLLM instantiates: FP8 W8A8 candidates, **Machete** (Hopper mixed-precision W4A16 "spiritual successor to Marlin", CUTLASS-based, prepacked weights), FlashInfer's CUTLASS MLA backend (SM100), NVFP4 w4a4 (SM120 PR) | Machete README; vLLM PR #49936; #21309 |
| **Marlin** | Weight-only mixed-precision GEMM (W8A16/W4A16…) — where GPUs without native FP8 land | PR #49936: "no native FP8 → weight-only Marlin" |
| **DeepGEMM** | DeepSeek's FP8/MoE GEMM; enabled by default in vLLM's DeepSeek path; **FlashInfer/DeepGEMM hybrid candidate on Hopper** | PR #49936 chain: FlashInfer/DeepGEMM hybrid (Hopper) → DeepGEMM → CUTLASS → Marlin → Triton → PyTorch |
| **Triton** | Kernel DSL: `TRITON_ATTN`/`TRITON_MLA` backends, fused-MoE, sampling kernels | attention-backend priority lists |
| **FlashAttention 2/3/4** | The `FLASH_ATTN` backend; version auto-picked by arch: **FA2 (Ampere), FA3 (Hopper, default), FA4 (Blackwell SM100+, default)**; FA4 needs SM ≥10.0 | attention-backends doc |
| **FlashInfer** | **Priority-1 backend on Blackwell** (Native + **XQA** decode via TRT-LLM API + **trtllm-gen** on SM100), plus MLA CUTLASS backend, NVFP4 (per-token activation scales), TRT-LLM FP4 MoE kernels | attention-backends doc; NVFP4 online-quant docs |
| **TRT-LLM kernels (via FlashInfer)** | XQA decode path, TRT-LLM Ragged MLA (Blackwell MLA fallback order: Ragged → FlashInfer → TokenSpeed), DeepSeek-V4 sparse MLA (`FLASHINFER_MLA_SPARSE_DSV4`, 256-token blocks/head 512) | attention-backends doc |
| **NCCL** | Collectives (all-reduce/AG/RS/A2A); NVLS on NVSwitch; **DeepEP-V2's new transport ("NCCL Gin backend")** | C3/C6; DeepEP README |
| **NVSHMEM** | PGAS/multi-GPU+node communication; **DeepEP-V1 legacy backend**; IBGDA (GPU-initiated RDMA, C4) | DeepEP legacy docs |
| **DeepEP** | MoE dispatch/combine all-to-all: **V2 = NCCL-Gin based, several-times-fewer SMs, JIT-compiled**, NVLink 643–740 GB/s (SM100), RDMA 61–90 GB/s; V1 = NVSHMEM + pure-RDMA low-latency kernels | DeepEP README/legacy |
| **cuDNN (9.x)** | **Capable but not vLLM's default**: cuDNN Frontend SDPA implements FA2-algorithm attention **with paged-attention tables, FP8 on Hopper/Blackwell, ragged layouts, UNIFIED fused path (9.13.1+)** — but no CUDNN backend in vLLM's current priority lists [V recheck] | cuDNN Frontend Attention page (9.18.1 matrix) |
| **GDN/linear-attention kernels** | Qwen3.5 hybrid (Gated DeltaNet) execution path (v0.17) | vLLM v0.17 release (A-series notes) |
| **FlexAttention / TURBOQUANT / HPC_ATTN** | Newer/fallback backends in the priority lists (Flex = torch.compile-based; TURBOQUANT quantized-attention fallback) | attention-backends doc |

**Selection behavior worth publishing:** attention backend = first *compatible* backend in a
priority list, else an error listing every incompatibility (silent fallback is dead); linear/FP8
kernel = chosen at load time and **logged as `Selected for …`**; `--linear-backend` covers
quantized linear layers but **MoE experts have a separate `--moe-backend`**; explicit unsupported
backends raise rather than silently downgrade.

## 2. The doubt-#3 verdict (blog-ready)

- **NCCL = the network librarian** (collectives only; see C3/C6 for the EFA wiring).
- **cuDNN = the guest star, not the cast**: its paged-attention SDPA is real and modern, but dense
  LLM serving in vLLM runs on FlashAttention/FlashInfer/TRT-LLM kernels — if your article 05
  nsys trace shows cuDNN kernels, you're probably in a VLM/other path [V verify in LAB 05].
- **cuBLAS = the floor, not the ceiling**: present under PyTorch; every optimized path *replaces*
  it.
- The actual stars: **FlashAttention/FlashInfer/TRT-LLM kernels** (attention), **DeepGEMM/CUTLASS/
  Marlin/Machete/Triton** (GEMM/MoE), **NCCL(+NVLS)/DeepEP/NVSHMEM** (collectives/dispatch).

## 3. Doubt questions (from doubt map A3) → status

| Question | Status |
| --- | --- |
| Which vLLM ops hit cuDNN? | **Answered**: none in the default attention path (§1); VLM/aux paths possible — LAB 05 nsys will settle it. |
| NCCL↔driver↔CUDA matrix? | Covered in C3 (OFI/NCCL versions); NCCL 2.31.2 tested w/ ofi 1.21.1. |
| CUDA-graphs & PIECEWISE? | Topic D3 (next cluster rounds). |
| torch.compile subgraphs? | Topic D3. |

## 4. Verified facts (sources, accessed 2026-10-03)

- Attention backend priorities & FA-version defaults: [vLLM attention backends](https://docs.vllm.ai/en/latest/design/attention_backends/).
- FP8 GEMM selection chain + `--linear-backend`/`--moe-backend` split: [vllm PR #49936](https://github.com/vllm-project/vllm/pull/49936).
- Machete: [csrc/quantization/machete README (v0.19.0)](https://github.com/vllm-project/vllm/blob/v0.19.0/csrc/quantization/machete/Readme.md).
- DeepEP V2 (NCCL Gin) + perf table + NVSHMEM legacy: [DeepEP README](https://github.com/deepseek-ai/DeepEP),
  [legacy docs](https://github.com/deepseek-ai/DeepEP/blob/main/docs/legacy.md).
- cuDNN Frontend SDPA (paged attn, fp8, UNIFIED): [cuDNN Attention docs](https://docs.nvidia.com/deeplearning/cudnn/frontend/latest/operations/Attention.html).

## 5. Hands-on validation (scheduled)

**LAB 05** (article 05, created at drafting time): nsys flamegraph of one Llama layer on the
cluster; label kernels by library; verify the `Selected for` log line and that no cuDNN kernels
appear in the dense-LLM path. That's D1's D3 evidence (and D2/D3 follow).

## 6. Blog angle

"The cast list": one matrix, the selection-behavior sidebar (no silent fallbacks anymore), and
the two corrections (cuDNN/cuBLAS) as the opener — exactly the doubt your readers will share.
