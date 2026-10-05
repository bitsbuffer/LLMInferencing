# E2 — PagedAttention: the KV cache as virtual memory

> Tracker: E2 · Status: covered (D2) · Date: 2026-10-03
> Scope: the block-table mechanism from the SOSP'23 paper through today's V1 `KVCacheManager`,
> copy-on-write, and the exceptions (hybrid groups, block-size 1). Feeds article 06/07.

## 1. The mechanism (verified, SOSP'23 paper)

- **Analogy:** blocks = pages, tokens = bytes, requests = processes. Each request's KV cache is a
  list of **logical blocks**, filled left-to-right; a **block table** maps logical → physical
  blocks, each entry recording the physical block id and **#filled positions**.
- Physical memory = one contiguous chunk divided into fixed-size **physical blocks**
  (uniform size ⇒ no external fragmentation; last-block slack ⇒ internal fragmentation bounded
  under one block). No pre-reservation for `max_model_len` — memory grows as tokens arrive.
- Paper's deliberate design: **separate blocks + tables per layer/head** (vs one monolithic
  block) — "no performance difference" and simpler kernels.
- **Headline results:** 2–4× throughput vs FasterTransformer/Orca at equal latency; near-zero KV
  waste; gains grow with longer sequences, bigger models, more complex decoding.
- Paper's worked example (worth reproducing as the article's figure): 7-token prompt → logical
  blocks 0,1 → physical blocks 7,1 (4+3 tokens, one slot reserved); first decode fills block 1's
  slot and updates #filled; second decode allocates physical block 3 for logical block 2.

## 2. Copy-on-write (verified)

- Parallel sampling / beam search: sequences **share blocks** (reference counts); on divergence,
  only the last (partially-filled) block is copied — the fork's new token goes to a fresh block.
  Paper frames it as OS CoW; vLLM's **block-copy kernel** (PR #32) fused the per-layer copies
  into one kernel invocation (from `2 × layers × blocks` down to 1).
- Same machinery underpins prefix sharing and (with hashing) prefix caching — blocks are the
  *unit* of sharing everywhere.

## 3. V1's `KVCacheManager` today (verified from source) — and why this topic is the hub

`CacheConfig.DEFAULT_BLOCK_SIZE = 16` (configurable; hybrid/GDN models use different group
block sizes — DeepSeek-style sparse attention needs **block_size 1** per the backend docs).
`gpu_memory_utilization` default is now **0.92** (per-instance, not per-GPU). The
`allocate_slots()` signature is effectively the table of contents of this series:

| Parameter | Series topic it exists for |
| --- | --- |
| `num_new_tokens` / `num_new_computed_tokens` | chunked prefill + prefix caching (E3/E4) |
| `num_lookahead_tokens` | speculative decoding (EAGLE needs KV slots for draft tokens) → I-series |
| `num_external_computed_tokens` | KV transferred from outside (P/D connectors) → H3 |
| `delay_cache_blocks` | P/D: don't commit blocks until the remote KV transfer completes → H3 |
| `full_sequence_must_fit` | admission gate (don't over-admit on chunked prefill) |
| `reserved_blocks` | async KV-connector loads can't steal blocks from in-flight prefills |
| `watermark_blocks` (watermark × num_blocks) | headroom so waiting/preempted requests don't preemption-storm (E5) |

Also in the manager: free-in-reverse-order (tail blocks evicted first), `remove_skipped_blocks`
(sliding-window gaps), commit capped at finalized tokens (non-committable draft tokens excluded).

## 4. Hybrid groups & `prefix_match_unit` (verified)

- Models mixing attention types (full + sliding-window + mamba/GDN) get **KV cache groups**, each
  with its own block size and `KVCacheTensor`; coordinators: `UnitaryKVCacheCoordinator`,
  `HybridKVCacheCoordinator` (exactly 2 groups: one full + one other), or
  `KVCacheCoordinatorNoPrefixCache`. Sliding-window prefix caching only needs the last
  `sw−1` tokens cached.
- **`prefix_match_unit`** (a.k.a. `hash_block_size`): prefix-cache keys computed every N tokens —
  can be *finer than the physical block* (e.g., 32 vs a 1024-token hybrid block) as long as every
  group's block size is divisible by it → **cache hits inside physical blocks**.

## 5. Doubt questions (doubt map A6) → status

| Question | Status |
| --- | --- |
| How do block tables work / what's in an entry? | **Answered** (§1): physical block + #filled; per-layer/head tables. |
| Default block size & exceptions? | **16** default; hybrid groups per attention type; sparse/DSA models → block size 1 (§3/§4). |
| When does CoW trigger? | Shared blocks with ref>1 fork on the last partial block (§2). |
| Where does fragmentation go? | Internal ≤ 1 block; external eliminated by uniformity (§1). |

## 6. Verified facts (sources, accessed 2026-10-03)

- Paper: [arXiv 2309.06180](https://arxiv.org/abs/2309.06180) (mechanism, example, results).
- Current manager: [kv_cache_manager.py](https://github.com/vllm-project/vllm/blob/main/vllm/v1/core/kv_cache_manager.py),
  [KVCacheManager API](https://docs.vllm.ai/en/stable/api/vllm/v1/core/kv_cache_manager/).
- CacheConfig (block size, watermark, prefix_match_unit, 0.92): [config docs](https://docs.vllm.ai/en/stable/api/vllm/config/).
- Hybrid groups: [hybrid KV cache manager design](https://docs.vllm.ai/en/stable/design/hybrid_kv_cache_manager/).
- CoW kernel: [vllm PR #32](https://github.com/vllm-project/vllm/pull/32).

## 7. Hands-on validation (scheduled)

LAB 06 (article 06): run Qwen3.5-0.8B and read the startup log's `# GPU blocks: N` for
block-size 8/16/32 and `--gpu-memory-utilization` sweeps (predict N before each run, reconcile
with F1's math); force an OOM-ish preemption by shrinking memory and watch preemption/recompute;
parallel-sampling demo (`n>1`) showing shared-prefix behavior. D3 evidence when run.

## 8. Blog angle

"Virtual memory for attention": the OS analogy table (page/block, process/request), the worked
example figure, the allocate_slots signature as the surprise ("look, spec decode, P/D, sliding
window — all one function"), and the hybrid/prefix_match_unit footnote.
