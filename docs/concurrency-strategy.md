# Doe concurrency strategy

## Goal

Beat Dawn on concurrency where AI/browser workloads care:

1. async pipeline creation
2. parallel model warmup
3. upload/compute overlap
4. predictable callback completion under load

## Non-goals

1. generic graphics-engine maximal threading
2. cross-thread encoder mutation
3. hidden backend fallback behavior

## Threading contract

The runtime should converge on:

1. thread-safe devices, queues, immutable resources, shader modules, and pipelines
2. thread-confined encoders and pass encoders
3. explicit callback-thread semantics

The contract source is [threading_contract.zig](../runtime/zig/src/runtime/threading_contract.zig).

## Tooling I/O contexts

Tooling and orchestration paths now have a separate explicit I/O seam in
`runtime/zig/src/tooling_io_context.zig`:

1. `sync` for ordinary blocking CLI/tool runs
2. `cooperative_same_thread` for future same-thread cooperative orchestration
3. `threaded_parallel` for future fan-out work that should use OS threads

This I/O context is for replay loading, CLI input loading, and related
artifact/tooling flows. It is not a replacement for the runtime object
threading contract above, and GPU device/queue execution should remain on the
explicit runtime threading model unless a separate architecture row changes it.

## Phase 1 delivered here

1. bounded worker pool for CPU-side background jobs
2. real background compute-pipeline creation through async ABI entrypoints
3. real background render-pipeline creation through async ABI entrypoints
4. single-flight deduplication for duplicate in-flight async pipeline requests via a shared runtime coordinator
5. worker-delivered callback dispatch for queue/timeline completion paths via a shared runtime dispatcher
6. queue-role policy surface for inference-oriented scheduling
7. benchmark harness skeleton for concurrency evidence

## Phase 2

1. make model warmup and upload preparation parallel by default
2. add cache-backed background pipeline warmup for known model graphs
3. connect async pipeline single-flight to persistent pipeline-cache hit/miss telemetry
4. benchmark and tune worker-pool sizing per backend and workload class

## Evidence

Concurrency claims should be made only from benchmark artifacts that show:

1. cold-start latency
2. N-thread pipeline creation throughput
3. upload/compute overlap
4. callback delay under contention
5. apples-to-apples Dawn comparison on matched workloads
