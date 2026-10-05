# E1 — The vLLM V1 process model (who serves your tokens)

> Tracker: E1 · Status: covered (D2) · Date: 2026-10-03
> Scope: the process/thread topology of `vllm serve` on V1 — API server(s), EngineCore, worker
> processes, the IPC wiring, and async scheduling. Feeds article 06 (its structural half).

## 1. The process model (verified, arch overview + current sources)

```
Client ──HTTP──▶ [API server process(es)]  ──ZMQ many-to-many──▶ [EngineCore proc per DP rank] ──▶ [Worker proc per GPU]
   ▲                ├ InputProcessor (tokenize, mm load)              ├ busy loop: poll input →                ├ rpc_broadcast_mq (ZMQ MessageQueue)
   └── stream ◀─────├ OutputProcessor (detokenize, logprobs)           │  publish counts → step → outputs       ├ SchedulerOutput via SHARED MEMORY handle
                    └ output_handler (asyncio → AsyncStream)           ├ DP coordinator (XSUB stats)             └ WorkerProc busy loop → GPUModelRunner
```

- **API server process(es)**: HTTP/OpenAI handling, tokenization, multimodal loading
  (`VLLM_MEDIA_LOADING_THREAD_COUNT`, default 8), streaming. Default 1; auto-scales to DP size;
  manual via `--api-server-count` (`-asc`); many-to-many ZMQ so any API server reaches any engine
  core. **`AsyncLLM`** lives here: `InputProcessor` (EngineInput → EngineCoreRequest via the
  renderer/tokenizer), `OutputProcessor` (EngineCoreOutputs → RequestOutput; detokenization,
  `stream_interval`, logprobs), `StatLoggerManager`, and the background `output_handler` task
  pulling outputs into per-request `AsyncStream`s (drain-first, no-await fast path;
  `VLLM_V1_OUTPUT_PROC_CHUNK_SIZE`).
- **EngineCore process** (one per DP rank): the busy loop — `_process_input_queue` (drain aborts,
  handle client requests) → `_maybe_publish_request_counts` → `_process_engine_step` → outputs
  onto the ZMQ queue. IO runs on **background threads** (ZMQ DEALER inputs + XSUB coordinator
  outputs) so socket IO overlaps GPU work (GIL released). Extras visible in current code:
  **DP coordinator** (request-count publishing for internal DP load balancing), **fault-tolerance
  sentinel** (`enable_fault_tolerance`), **tensor-IPC queue** for multimodal tensor sharing, and
  **elastic EP** (`scale_elastic_ep`) — plus a `pcp_size` (prefill-context-parallel) in the
  world-size math (TP×PP×PCP).
- **Worker processes** (one per GPU, via `MultiprocExecutor`): created per `local_rank` with
  **NUMA binding**; scheduler outputs handed over via a **shared-memory handle** (not ZMQ) while
  RPCs flow through the `rpc_broadcast_mq`; each rank has a response MessageQueue; a
  `driver_worker` distinction; background worker-health monitor. Worker busy loop =
  dequeue-RPC → execute (cloudpickle for ad-hoc calls) → publish output.
- Sizing takeaway for EKS: plan CPU for **1 API server + 1 engine core + 1 worker per GPU** (plus
  threads for media/loading); `set_torch_threads_for_runtime()` ensures the scheduler process
  doesn't fight workers for torch intra-op threads.

## 2. Async scheduling (verified)

**Default-on since PR #27614** (`disable_async_scheduling` to opt out; auto-disabled for
**pipeline parallelism** and **speculative decoding**; pooling models unaffected). The engine
step was refactored into **`execute_model` + `sample_tokens`** so CPU-side scheduling overlaps the
GPU forward (mainly a decode win; maintainer notes: CPU→GPU copy of new input tokens is *not*
yet overlapped). Custom scheduler classes must implement the Scheduler interface and are warned
about degraded perf without async scheduling.

## 3. Doubt questions (doubt map A6) → status

| Question | Status |
| --- | --- |
| V1 process split & IPC? | **Answered** (§1): ZMQ between API server(s)/EngineCore; shm + MessageQueues between EngineCore and workers. |
| What overlaps what? | **Answered**: frontend vs engine core (V1-alpha design), ZMQ IO vs GPU (threads), scheduling vs forward (async scheduling), with explicit non-overlaps (input-token copy). |
| Where do tokenization/detokenization live? | In the **API server/frontend process** (Input/OutputProcessor) — the reason API-server count scales frontends (PR #23717: processor caching per API-server rank). |
| How does KV cache mgmt fit? | EngineCore process — details → E2/E5 (next topics). |

## 4. Verified facts (sources, accessed 2026-10-03)

- Process architecture & API-server scaling: [arch overview (v0.26)](https://docs.vllm.ai/en/v0.26.0/design/arch_overview/),
  [vllm serve CLI (--api-server-count, frontend multiprocessing)](https://vllm.website.cncfstack.com/cli/serve.html),
  [PR #23717](https://github.com/vllm-project/vllm/pull/23717).
- AsyncLLM internals: [async_llm.py](https://github.com/vllm-project/vllm/blob/main/vllm/v1/engine/async_llm.py)
  (Input/OutputProcessor, output_handler, streaming input, stat loggers).
- EngineCore busy loop/threads/DP/fault-tolerance: [v1/engine/core.py](https://github.com/vllm-project/vllm/blob/main/vllm/v1/engine/core.py).
- MultiprocExecutor + worker wiring: [multiproc_executor.py](https://github.com/vllm-project/vllm/blob/main/vllm/v1/executor/multiproc_executor.py).
- Async scheduling: [scheduler config](https://docs.vllm.ai/en/stable/api/vllm/config/scheduler/),
  [PR #27614](https://github.com/vllm-project/vllm/pull/27614).
- V1 design rationale (EngineCore isolation, symmetric workers, diffs): V1 alpha blog (A-series notes).

## 5. Hands-on validation (scheduled)

LAB 06 (article 06, created at drafting): run Qwen3.5-0.8B; inspect the process tree
(`API server` / `EngineCore` / `VllmWorker-N`), ZMQ socket fds; A/B `--disable-async-scheduling`
under load (predict: TPOT gap at small ISL); `--api-server-count 2` + confirm many-to-many
routing in logs. D3 evidence when run.

## 6. Blog angle

"The four processes that serve your tokens": the ASCII diagram upgraded to a real figure, the
IPC table (ZMQ vs shm vs RPC), and the async-scheduling default flip as the "what changed
recently" beat.
