# Node/Bun developer wedge

This page is the implementation and promotion contract for the initial wedge.
The objective, priority order, downstream flywheel, commercial journey, and
expansion boundaries live only in [`thesis.md`](thesis.md).

## Candidate boundary

This wedge applies only where the application controls provider selection:

- Node services and tools;
- Bun services and tools;
- Electron main-process or Node-side GPU execution;
- local inference, embedding, search, image, and compute applications;
- CI and release systems with controlled GPU hosts.

It does not imply arbitrary npm `webgpu` compatibility, browser runtime
replacement, or support outside the declared matrix.

Inclusion above identifies an admissible candidate surface, not a promoted
tuple. Current support is owned by [`doe-support-matrix.md`](doe-support-matrix.md)
and `reports/claim-index.json`; Electron requires its own promoted evidence.

## First-kernel contract

```bash
npm install doe-gpu
node node_modules/doe-gpu/examples/node-first-kernel.mjs
bun node_modules/doe-gpu/examples/bun-first-kernel.mjs
```

On a supported tuple, each example must load the packaged native runtime, run a
real WGSL kernel, validate the output, print runtime identity, and emit a
receipt. On an unsupported tuple, it must fail with an actionable typed cause.

## Downstream compatibility suite

Promotion requires a small, versioned set of recognizable projects. Each row
must record:

- upstream project and version;
- provider substitution or patch set;
- exercised operations;
- output oracle;
- unsupported APIs;
- runtime, adapter, driver, and native binary identity;
- installation and execution receipt.

## Runtime ownership gate

Every promotion candidate must execute the comparison contract in
[`runtime-ownership-decision.md`](runtime-ownership-decision.md): ambient
incumbent, pinned incumbent, pinned incumbent plus DoeProof, and DoeRuntime plus
the same DoeProof machinery. Add the bounded-patch control when independent
correction is the claimed advantage.

The application contract must identify the property claimed to require
DoeRuntime and freeze its adjudicating outcome before execution. If the
governed incumbent closes the gap, promote DoeProof for that application rather
than assigning the result to DoeRuntime.

## Release portfolio

Application count does not determine release consequence. Classify each
application as one of:

- core blocker for the primary tuples;
- platform blocker for changes affecting its declared tuple;
- diagnostic application with no release authority;
- experimental probe with no support commitment.

Only applications with complete installation, oracle, replay, lifecycle,
resource, support-target, and runtime-ownership attribution may become blockers.

## Reliability gate

Every promoted workload must cover:

- correct output and corruption rejection;
- crash, hang, timeout, cancellation, and device-loss behavior;
- queue ordering and concurrent runtime instances;
- repeated initialization and teardown;
- memory growth and resource lifetime;
- explicit cache, fallback, and retry decisions.

Known silent no-ops, sentinel failures, unbounded leaks, or missing output
oracles block promotion.

## Performance gate

Measure operations users care about:

- inference prefill and decode;
- embeddings and vector operations;
- upload, dispatch, completion, and readback;
- shader and pipeline creation;
- warm pipeline reuse;
- total memory use.

Claims must be end-to-end, output-valid, structurally equivalent, and positive
at the declared percentiles by more than the measured noise floor. Diagnostic
microbenchmarks may explain a result but cannot replace it.

## Installation gate

The package release must test clean installation and first-kernel execution for
every promoted Node/Bun, operating-system, architecture, and backend tuple. No
local Zig build or undocumented environment configuration belongs in the
supported path.

## Claim boundary

Allowed:

- a named workload, host, backend, comparator, metric, and artifact;
- a named compatibility result for a locked downstream version;
- a receipt-backed reliability or installation result.

Disallowed:

- universal “fastest WebGPU runtime” language;
- “faster everywhere”;
- arbitrary Node/Bun GPU compatibility;
- browser replacement inferred from package evidence.

Current evidence lives in `reports/claim-index.json` and
[`status/runtime-backends-and-bench.md`](status/runtime-backends-and-bench.md).
Do not copy receipt inventories into this strategy document.
