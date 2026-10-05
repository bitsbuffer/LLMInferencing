# D3 — CUDA Graphs (FULL/PIECEWISE) & torch.compile/Dynamo-Inductor in vLLM

> Tracker: D3 · Status: covered (D2) · Date: 2026-10-03
> Scope: why decode loves graphs and prefill doesn't; vLLM's five cudagraph modes and the
> dispatcher; the Inductor integration (compile-once/per-shape, graph partitioning, fusion
> passes). Feeds article 05/06. Doubt-map A3's CUDA-graphs & torch.compile questions answered.

## 1. CUDA Graphs fundamentals (verified, CUDA programming guide)

- In stream execution the host driver pays **per-kernel launch overhead** — significant for short
  kernels. A CUDA graph pays that **once at instantiation**; replay is a single launch of the
  whole graph.
- Constraints that shape everything downstream: fixed kernels/args/**memory addresses**; no
  host-to-device syncs (`.item()` breaks capture); limited control flow; capture needs warmup
  runs; separate memory pool with fixed addresses (values may change, addresses may not).
- Consequence for LLMs: **decode** = many small kernels at fixed shapes → graphs win big.
  **Prefill** = few huge kernels at wildly variable shapes → piecewise (or none). PyTorch's own
  CUDAGraph-Trees notes quantify graph memory: **~64 KB device memory per kernel launch per
  graph** (CUDA ≤12.4/550+) — many captured sizes × many kernels = real memory; vLLM manages its
  own pools/dispatcher rather than torch's trees for exactly this reason.

## 2. vLLM's five cudagraph modes (verified, CompilationConfig + design doc)

| Mode | Semantics | When |
| --- | --- | --- |
| `NONE` | eager everywhere | `--enforce-eager`; when piecewise compilation unavailable |
| `PIECEWISE` | graphs around cudagraph-safe segments; **attention & other cudagraph-unsafe ops stay eager**; requires piecewise compilation | past default; most flexible; pooling models |
| `FULL` | whole forward captured for all batches | small models/small prompts; few backend support |
| `FULL_DECODE_ONLY` | full graph for **uniform decode** only; prefill/mixed run eager | **decode instances in P/D setups** (saves the memory of piecewise graphs) |
| `FULL_AND_PIECEWISE` | full graph for uniform decode + piecewise for prefill/mixed | **V1 default; most performant; most memory; longest capture** |

Design (verified from the dispatcher source): `CudagraphDispatcher` is the single source of truth;
dispatch priority `FULL > PIECEWISE > NONE`; keys are batch descriptors (num_tokens padded to
capture sizes, uniform-decode flag, LoRA counts); nested wrappers (one FULL wrapper outside the
model, one PIECEWISE wrapper per inductor partition); automatic **downgrade** to the closest mode
per attention-backend capability (hybrid models = min capability); capture happens on first
`_dummy_run` per descriptor.

**Capture-size economics:** default sizes `[1,2,4] + range(8,256,8) + range(256, max+1, 16)`;
`max_cudagraph_capture_size` default `min(max_num_seqs*2, 512)`; every run pads to the next
captured size; `cudagraph_num_of_warmups` before recording; **LoRA-specialized graphs**
(cudagraph_specialize_lora: separate graphs with/without active adapters, powers-of-2 LoRA
counts); encoder (VLM) graphs use token *budgets* with greedy image packing.

## 3. torch.compile / Dynamo-Inductor integration (verified)

- **Compile once with Dynamo, many times with Inductor:** vLLM compiles the bytecode once, then
  compiles inductor *outside* the Dynamo context per shape (compile ranges/sizes) using the
  `AlwaysHitShapeEnv` trick so the code cache always hits. Local caches: `~/.cache/vllm` →
  `TORCHINDUCTOR_CACHE_DIR`/`TRITON_CACHE_DIR` (fx_graph_cache on, remote off).
- **Graph partitioning:** `use_inductor_graph_partition` splits at ops tagged `cudagraph_unsafe`
  (attention) → N+1 partitions, each wrapped by a PIECEWISE CUDAGraph wrapper — full and
  piecewise modes **without compiling twice**.
- **Fusion passes** (PassConfig, levels O0–O3; verified table with measured e2e gains):
  AllReduce+RMSNorm (+residual/quant) — **O2, Hopper/Blackwell + TP>1, 5–20%**; **AsyncTP
  GEMM+collective** (reduce-scatter/all-gather fused into GEMMs via symm-mem — 7–10%, high
  num_tokens, needs Sequence-Parallelism first); RMSNorm+Quant & SiLU+Mul+Quant (O1, 1–4%);
  QK-Norm+RoPE (2–3%); RoPE+KV-write (ROCm O2); Attention+Quant (off by default, fullgraph
  required); MLA dual-RMSNorm (ROCm).
- **Fullgraph conflicts:** passes like AttnQuantFusion and Sequence-Parallelism must see the whole
  graph → piecewise compilation auto-disables (`splitting_ops=[]`) → mode falls back to
  FULL/FULL_DECODE_ONLY. That tradeoff (fusion vs piecewise-cudagraph) is a real production
  decision, not an academic footnote.

## 4. Config surface (verified)

`--enforce-eager` (kill all graphs); `--compilation-config '{"cudagraph_mode":
"FULL_AND_PIECEWISE"}'` (uppercase enum); compile knobs inside the same JSON (`compile_sizes`,
`compile_ranges_endpoints`, `inductor_passes`, PassConfig fields). `-O3`-style optimization
levels appear in the fallback-policy text (compilation level 3).

## 5. Doubt questions (doubt map A3) → status

| Question | Status |
| --- | --- |
| What exactly changes with CUDA graphs (launch overhead)? | **Answered** (§1): per-kernel launch cost → once-per-graph; fixed addresses/args; sync-free. |
| Which subgraphs does torch.compile compile? | **Answered** (§3): whole model bytecode once (Dynamo); per-shape/range Inductor compiles; split at cudagraph-unsafe ops; fusion passes on top. |
| Which cudagraph mode when? | **Answered** (§2 table) incl. the P/D decode-instance choice. |

## 6. Verified facts (sources, accessed 2026-10-03)

- Modes/dispatcher/capture sizes: [CompilationConfig docs](https://docs.vllm.ai/en/latest/api/vllm/config/compilation/),
  [CUDA Graphs design (v0.28)](https://docs.vllm.ai/en/v0.28.0/design/cuda_graphs/),
  [cudagraph_dispatcher.py](https://github.com/vllm-project/vllm/blob/main/vllm/v1/cudagraph_dispatcher.py).
- Inductor integration & passes: [compiler_interface.py](https://github.com/vllm-project/vllm/blob/main/vllm/compilation/compiler_interface.py),
  [fusion passes](https://vllm.readthedocs.io/en/latest/design/fusions/).
- CUDA graph semantics & PyTorch trees (64 KB/launch figure): [CUDA docs](https://docs.nvidia.com/cuda/cuda-programming-guide/04-special-topics/cuda-graphs.html.md),
  [torch.compiler cudagraph_trees](https://docs.pytorch.org/docs/stable/user_guide/torch_compiler/torch.compiler_cudagraph_trees.md).

## 7. Hands-on validation (scheduled)

LAB 05 (article 05): A/B `--enforce-eager` vs default on Qwen3.5-0.8B and Llama-8B TP=2 —
measure TPOT delta and capture time; grep logs for selected cudagraph mode + sizes; nsys side-by-
side of eager vs replayed step. Predict TPOT delta (decode) and capture-time cost first.

## 8. Blog angle

"Decode loves graphs, prefill doesn't": the mode table as the centerpiece, the dispatch-priority
diagram, the capture-memory economics (64 KB/launch × sizes × kernels), and the fusion-pass table
with real percentages — then the P/D insight (`FULL_DECODE_ONLY` exists *for decode instances*).
