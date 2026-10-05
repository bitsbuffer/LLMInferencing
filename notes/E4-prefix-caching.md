# E4 — Prefix caching: APC, the block-hash tree, eviction, hit-rate math

> Tracker: E4 · Status: covered (D2) · Date: 2026-10-03
> Scope: how vLLM turns shared prefixes into free tokens — hash-based APC, the hash-algorithm
> landscape (incl. cache salts & security), the RadixAttention-equivalent eviction, and the
> metrics/hit-rate math. Feeds articles 06/07 (and llm-d's J4 routing story later).

## 1. The hash chain (verified from design doc + source)

- vLLM hashes each block by `(parent_block_hash, block_tokens tuple, extra_keys)` — so each
  hash uniquely fingerprints the **full prefix ending at its boundary**. Chained blocks form the
  "block-hash tree" (no radix tree needed; equivalent lookup semantics).
- `extra_keys`: LoRA IDs, multimodal-input hashes, prompt-embeds hashes, and **`cache_salt`** —
  the salt is injected into the **first block's hash only** (`start_token_idx == 0`), so cache
  sharing is scoped to requests that agree on the salt.
- **Granularity = `hash_block_size`** (verified rules): single KV group → scheduler block size
  (× DCP); multiple groups → `prefix_match_unit` override or the **GCD of group block sizes**
  (divisibility enforced with a `ValueError`; non-align mamba groups back off to scheduler size).
  Hashing also runs when KV *connectors* are active (P/D/offload) even without prefix caching —
  block hashes are the interchange format for KV transfer too.

## 2. Hash algorithms & security (verified)

- `--prefix-caching-hash-algo`: **`sha256` (default since v0.11)** — collision-safe, but pickle
  serialization ⇒ **hashes not reproducible across Python/vLLM versions**; `sha256_cbor` —
  canonical CBOR, reproducible/cross-language (recommended for deterministic caching);
  `xxhash`/`xxhash_cbor` — faster, with an explicit warning: non-cryptographic hashing raises
  collision risk → undefined behavior / **information leakage in multi-tenant settings**.
- **Deterministic seed**: the default seed is fixed (not secret) so independent vLLM processes
  compute identical block hashes — enabling **KV-cache reuse across nodes with zero config**
  (SHA-256's collision resistance doesn't rely on seed secrecy; `cache_salt` remains the
  isolation mechanism). This is exactly what makes cross-process/offload KV sharing viable.
- **Timing-attack defense**: without salts, an adversary can infer cached content from TTFT
  differences; salting scopes reuse to a trust group with no perf compromise.

## 3. Eviction (verified)

- Policy: when the pool is exhausted, evict blocks with **ref_count == 0** first; among those
  **LRU**; among equal access time, the block **deepest in the longest chain** (most hash tokens /
  tail of a chain) — the design doc notes this is **exactly RadixAttention's policy** for
  full-attention models.
- Implementation: intrusive doubly-linked `FreeBlockQueue` (no Python-object allocation; manipulates
  `prev/next_free_block` on the blocks), LRU at the front; **free-in-reverse-order** (E2) is what
  maintains the LRU ordering; `iter_blocks_after(cursor)` exposes eviction order.

## 4. Metrics & hit-rate math (verified)

- `vllm:prefix_cache_queries` and `vllm:prefix_cache_hits` are **counters** (per the metrics
  design; deliberately not a gauge — issue #1058): hit rate =
  `rate(prefix_cache_hits[5m]) / rate(prefix_cache_queries[5m])`. Log display shows hit rate over
  the **most recent 1k block queries**. Also: `vllm:kv_cache_usage_perc`.
- Fermi estimate for the article: a 2,048-token shared system prompt = 128 blocks (size 16); on
  H100 an 8B model prefills ~10–20k tok/s ⇒ ~100–200 ms TTFT saved **per cache hit** — at R
  requests sharing the prefix, R−1 prefills of P tokens evaporate. APC only accelerates
  **prefill** (long-doc queries, multi-round chat); long-generation or unique-prefix workloads
  see ~nothing.

## 5. Doubt questions (doubt map A6) → status

| Question | Status |
| --- | --- |
| How does APC identify shared prefixes? | **Answered** (§1): chained block hashes, granularity rules. |
| What evicts what? | **Answered** (§3): ref-0 → LRU → deepest-chain-tail; = RadixAttention policy. |
| How is a hit measured? | **Answered** (§4): counters + PromQL; 1k-recent log rate. |
| Multi-tenant safety? | **Answered** (§2): `cache_salt`; hash-algo collision warnings. |

## 6. Verified facts (sources, accessed 2026-10-03)

- Design: [prefix caching](https://docs.vllm.ai/en/stable/design/prefix_caching/),
  [APC feature page](https://docs.vllm.ai/en/stable/features/automatic_prefix_caching/),
  [v0.10 APC design (eviction policy/RadixAttention equivalence)](https://docs.vllm.ai/en/v0.10.0/design/automatic_prefix_caching.html).
- Source: [kv_cache_utils.py (hash_block_tokens, request_block_hasher, FreeBlockQueue, hash_block_size rules)](https://github.com/vllm-project/vllm/blob/7c2acd38/vllm/v1/core/kv_cache_utils.py).
- Metrics: [vLLM metrics design](https://docs.vllm.ai/en/stable/design/metrics/).

## 7. Hands-on validation (scheduled)

LAB 06 (article 06): A/B with/without APC on a 2k-token shared system prompt (predict TTFT delta
≈ prefill-time of the prefix); scrape `prefix_cache_{queries,hits}` and compute the PromQL rate;
demo `cache_salt` isolation (two salts → no cross-hits). D3 evidence when run.

## 8. Blog angle

"Your system prompt, precomputed": the hash-chain diagram, the salt/security sidebar (the
timing-attack angle is a differentiator), the RadixAttention-equivalence footnote, and the
hit-rate math you can do on a napkin.
