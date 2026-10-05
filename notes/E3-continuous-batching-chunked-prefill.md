# E3 — Continuous batching & chunked prefill: the unified token-budget scheduler

> Tracker: E3 · Status: covered (D2) · Date: 2026-10-03
> Scope: iteration-level scheduling (Orca) → stall-free chunked prefill (Sarathi-Serve) → V1's
> unified `{request_id: num_tokens}` scheduler, with real `SchedulerOutput` anatomy and the
> preemption path. Feeds articles 06/10.

## 1. Orca: iteration-level scheduling (verified, OSDI'22)

- Schedule at the **granularity of iteration**, not request: every iteration the scheduler picks
  the request set, runs exactly one model iteration, and streams outputs — finished requests
  return immediately; new arrivals start after the current iteration.
- **Selective batching** makes that possible on a Transformer: token-wise batching for
  request-agnostic ops (linear/norm/add/GeLU) with split→attention→merge around the one op that
  needs request identity (attention; KV kept per-request in the manager).
- Result: **36.9×** throughput at equal latency vs FasterTransformer (GPT-3 175B).

## 2. The stall problem and Sarathi-Serve (verified, OSDI'24)

- vLLM/Orca-era **prefill-prioritizing** scheduling creates **generation stalls**: a long prefill
  scheduled between decodes freezes ongoing decodes for seconds (vLLM "schedules as many prefills
  as possible" before resuming decodes). Naive hybrid batching can inflate TBT **up to 28.3×**.
- **Chunked prefill**: split prefills into near-equal compute chunks — a ~512-token chunk already
  saturates GPU compute, so chunks keep decodes' arithmetic-intensity slack busy without breaking
  the TBT SLO. **Stall-free batching**: pack running decodes first → partially-completed prefills
  → then admit new requests into leftover budget (budget derived from the SLO).
- Combined (chunked + hybrid) beats each alone: **2.6×** capacity (Mistral-7B, A100), **3.7×**
  (Yi-34B, 2×A100), **5.6×** (Falcon-180B with pipeline parallelism — uniform batches shrink
  pipeline bubbles).

## 3. V1's unified scheduler (verified from source)

The V1-alpha blog line holds in the code: the scheduler emits `{request_id: num_tokens}` under a
**token budget**, erasing the prefill/decode distinction — chunked prefill and spec decode are
just budget arithmetic.

**`SchedulerOutput` anatomy** (the real contract, diff-based):
- `scheduled_new_reqs` (first-time requests; **their data is cached in worker processes**) vs
  `scheduled_cached_reqs` — "**we only send the diff**" (the incremental-diff design from E1).
- `num_scheduled_tokens` / `total_num_scheduled_tokens`; `scheduled_spec_decode_tokens`;
  `scheduled_encoder_inputs` (multimodal/VLM encoder compute).
- `num_common_prefix_blocks` (per KV group — feeds **cascade attention**).
- `finished_req_ids`, `free_encoder_mm_hashes`, `preempted_req_ids` (v2 model runner).
- Async-scheduling extras: `has_structured_output_requests` / `pending_structured_output_tokens`
  (grammar bitmasks computed off-step), `num_invalid_spec_tokens` (acceptance-rate accounting).
- `kv_connector_metadata` / `ec_connector_metadata` and **`new_block_ids_to_zero`** (fresh blocks
  zeroed by the worker to avoid stale-memory corruption — an H3/connector tie-in).

**The preemption path (in `schedule()`):** running requests consume `token_budget` (each step's
`num_new_tokens = num_tokens_with_spec + placeholders − computed`, capped by
`long_prefill_token_threshold`, `max_model_len`, and mamba block-aligned splits); when
`allocate_slots` returns None, vLLM preempts — **FCFS pops the newest running request**, priority
policy preempts by `(priority, arrival_time)` — and explicitly `continue`s (not `break`) so
lower-priority requests may still schedule in the same step.

## 4. Config surface (verified)

- `DEFAULT_MAX_NUM_BATCHED_TOKENS = 2048` (**256 for batched-DP**), `DEFAULT_MAX_NUM_SEQS = 128` —
  but these are *test* defaults; **real defaults are set in `EngineArgs.create_engine_config`**
  (a trap worth calling out).
- `max_num_scheduled_tokens` ≤ `max_num_batched_tokens` (smaller when spec decode may append).
- Validation rules: without chunked prefill, `max_num_batched_tokens ≥ max_model_len` (or long
  prompts are rejected); `max_num_batched_tokens ≥ max_num_seqs`; warning if it exceeds
  `max_num_seqs × max_model_len`.
- V1 multimodal budgets: `max_num_encoder_input_tokens`, `encoder_cache_size` (not yet
  configurable); `schedule_interval` (step every N engine steps, aligned across DP ranks).

## 5. Doubt questions (doubt map A6) → status

| Question | Status |
| --- | --- |
| What is continuous batching, exactly? | **Answered** (§1): iteration-level scheduling + selective batching. |
| How does chunked prefill work and when? | **Answered** (§2/§4): V1 default-on; stall math + Sarathi numbers. |
| How does priority/preemption work? | **Answered** (§3): policy classes, preempt-lowest, continue-not-break. |
| What does one scheduling step actually emit? | **Answered**: the `SchedulerOutput` anatomy (§3). |

## 6. Verified facts (sources, accessed 2026-10-03)

- Orca: [OSDI'22 paper](https://www.usenix.org/system/files/osdi22-yu.pdf).
- Sarathi-Serve: [OSDI'24 paper](https://www.usenix.org/system/files/osdi24-agrawal.pdf) / [arXiv](https://arxiv.org/html/2403.02310v2).
- V1 scheduler: [scheduler.py](https://github.com/vllm-project/vllm/blob/17d87168/vllm/v1/core/sched/scheduler.py),
  [output.py](https://github.com/vllm-project/vllm/blob/17d87168/vllm/v1/core/sched/output.py).
- Config: [scheduler config docs](https://docs.vllm.ai/en/stable/api/vllm/config/scheduler/).

## 7. Hands-on validation (scheduled)

LAB 06 (article 06) + article 10's hero: long-prompt storm at fixed load with
`max_num_batched_tokens` 1024 vs 4096 vs 8192 — record ITL p99 (the stall story) and TTFT;
then a tiny-budget preemption-storm run to catch `preempted_req_ids` in logs. Predict the ITL
shape before measuring.

## 8. Blog angle

"The scheduler that killed the prefill/decode distinction": Orca → stall → Sarathi → V1 in four
figures, the SchedulerOutput anatomy as the "here's the actual contract" moment, and the
test-defaults trap as the practical footnote.
