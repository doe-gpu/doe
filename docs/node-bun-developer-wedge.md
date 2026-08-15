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

The public Node implementation starts at
`doe-gpu/node-webgpu::runGovernedNodeWebGPU`. It accepts the same explicit
provider contract for incumbent and Doe lanes, binds a caller-declared
implementation digest plus input and expected-output identity, applies an exact
SHA-256 output oracle, and emits both pre-release and terminal lifecycle
checkpoints. The helper supplies execution evidence; the application contract
still owns whether the expected output is genuinely independent and whether a
run is release-eligible.

For an unchanged Node application, the public
`doe-gpu/node-webgpu-process::runGovernedNodeWebGPUProcess` wrapper composes the
fail-closed `webgpu` loader with bounded child execution. It requires the child
evidence to return the effective loader identity, applies the exact parent-side
oracle, binds the process declaration and hashed environment, and emits a
self-validating provider-neutral receipt. A process receipt remains diagnostic
until the application-specific reliability and adoption gates pass.

Abort, timeout, and captured-output limits share one termination contract.
POSIX runs own a process group and terminate that group; Windows runs terminate
the direct child and explicitly record that narrower scope. The CLI converts
`SIGINT` and `SIGTERM` into the same durable failed receipt instead of silently
abandoning the evidence path. A valid cancellation receipt proves integrity and
declared cleanup scope, not successful workload execution.

The CLI contract may bind additional runtime files by unique identifier, path,
and SHA-256. This closes drift for declared data and library artifacts, while
remaining explicitly weaker than a dependency-sealed execution: completeness
and absence of undeclared reads require an isolation or file-observation gate.

For compatible Node executables, `node-permission-read-only` adds a fail-closed
Node API boundary: the loader, application, provider, input, and declared
runtime files form the read allowlist; filesystem writes and child processes
remain denied. The custom loader requires Node's internal worker path, so worker
permission is enabled and explicitly recorded. Native-code syscalls, network
access, and operating-system isolation remain outside this contract. Native
addon loading is necessarily enabled for WebGPU providers and is separately
recorded as `allowed-for-provider`.

The frozen HoloScript diagnostic at
`reports/benchmarks/amd-vulkan/20260815T205128Z/holoscript-doeproof-cli-filesystem-diagnostic.json`
exercises this mode on both the incumbent and Doe providers. It deliberately
omits the harness's auxiliary renderer subprocess and therefore proves the
Node API allowlist and exact workload result, not hardware eligibility or
operating-system dependency sealing.

The packaged `doe-proof-node` command exposes this same contract to CI through
hash-bound `run`, `verify`, `inspect`, `replay`, and exact-output `compare`
operations. It does not expose the repository benchmark or release operators.
The package ships contract, receipt, and artifact JSON Schemas for portable
shape validation; the CLI validator additionally enforces semantic and hash
coherence that JSON Schema cannot establish.

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

For a staged host platform, `npm run test:integration:native-clean-install`
and `npm run test:integration:native-clean-install:bun` each pack the wrapper
and platform payload, install them into a fresh project with scripts disabled,
execute the runtime-specific shipped first kernel, and verify that the loaded
library path remains inside that installation. Missing staged artifacts are a
failure in either explicit release gate, while the ordinary source-tree suite
may report the Node physical package check as skipped.

The `native-reliability` variants reuse one clean installation across repeated
fresh processes and overlapping runtime instances, then execute 12 exact
create/compute/destroy cycles inside one additional process. They record the
post-warmup RSS span against a frozen 256 MiB diagnostic ceiling. This covers a
bounded same-process lifecycle and memory envelope, resolves `GPUDevice.lost`
with the `destroyed` reason, and requires post-destroy operations to fail closed.
It is not a long-soak leak test or unexpected hardware-loss recovery gate; those
remain separate promotion obligations.

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
