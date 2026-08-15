# doe-gpu

`doe-gpu` is the public JavaScript package for Doe's native WebGPU runtime.
Support is limited to the runtime, operating-system, architecture, backend,
and workload tuples declared in the Doe support matrix.

## Install and verify

```bash
npm install doe-gpu
node node_modules/doe-gpu/examples/node-first-kernel.mjs
node node_modules/doe-gpu/examples/node-governed-first-kernel.mjs
```

On a supported tuple, the first-kernel example loads the packaged native
runtime, executes WGSL, validates output, and emits runtime identity and a
receipt. Unsupported tuples must fail with an actionable cause; they must not
select another GPU or CPU provider silently.

## Basic use

```js
import { gpu } from "doe-gpu";

const device = await gpu.requestDevice();
const output = await device.compute({
  code: `@group(0) @binding(0) var<storage, read_write> data: array<f32>;
         @compute @workgroup_size(64)
         fn main(@builtin(global_invocation_id) id: vec3u) {
           data[id.x] = data[id.x] * 2.0;
         }`,
  inputs: [new Float32Array([1, 2, 3, 4])],
  output: { type: Float32Array, size: 16 },
  workgroups: 1,
});
```

Use the strict provider-v1 API when the application owns provider selection and
global installation:

```js
import { openNodeWebGPU } from "doe-gpu/node-webgpu";

const session = await openNodeWebGPU({ providers, globals: { mode: "replace" } });
try {
  const device = await session.adapter.requestDevice();
  // Run the application workload.
} finally {
  await session.close();
}
```

Every provider attempt is represented in the session receipt. `close()`
restores changed globals.

For a provider-neutral DoeProof execution, bind the workload implementation,
input, and expected exact output before running either an incumbent or Doe:

```js
import {
  runGovernedNodeWebGPU,
  validateGovernedNodeWebGPUReceipt,
} from "doe-gpu/node-webgpu";

const result = await runGovernedNodeWebGPU({
  provider: { providers, adapterOptions: null, globals: { mode: "replace" } },
  workload: {
    id: "my-kernel",
    version: "1",
    implementationSha256,
    input,
    expectedOutputSha256,
  },
  execute: async ({ adapter, input }) => runApplication(adapter, input),
  checkpoint: persistReceipt,
});

const validation = validateGovernedNodeWebGPUReceipt(result.receipt);
```

The exact-output oracle fails closed. The checkpoint receives an
`inference-complete-release-pending` receipt before teardown and a final
`release-complete` receipt afterward. Stable workload and execution hashes let
the same contract compare a governed incumbent (`W0`) with Doe (`D0`) without
assigning runtime credit to evidence supplied by the wrapper.
Validation recomputes both replay identities and rejects incoherent oracle,
provider, adapter-observation, error, or lifecycle state.

An unchanged Node application that imports the exact `webgpu` specifier can use
the public fail-closed loader:

```bash
DOE_NODE_WEBGPU_PROVIDER_ID=pinned-incumbent \
DOE_NODE_WEBGPU_PROVIDER_MODULE=/absolute/path/to/provider/index.js \
node --experimental-loader doe-gpu/node-webgpu-loader application.mjs
```

The loader redirects only `webgpu`, exposes `__doeProofProviderIdentity`, and
fails when either declaration is missing or the selected module does not export
`create()` and `globals`. It does not select a fallback provider.

Use the governed process entrypoint when the unchanged application must also
produce durable parent-side execution evidence:

```js
import {
  runGovernedNodeWebGPUProcess,
  validateGovernedNodeWebGPUProcessReceipt,
} from "doe-gpu/node-webgpu-process";

const run = await runGovernedNodeWebGPUProcess({
  provider: { id: "pinned-incumbent", module: providerModule },
  workload: { id, version, implementationSha256, input, expectedOutputSha256 },
  process: {
    entrypoint: applicationPath,
    environment: { mode: "sealed", values: applicationEnvironment },
    filesystem: {
      mode: "node-permission-read-only",
      readPaths: declaredRuntimePaths,
    },
    timeoutMs,
    maxOutputBytes,
  },
  evaluate: parseApplicationOutput,
  signal: abortController.signal,
});

const validation = validateGovernedNodeWebGPUProcessReceipt(run.receipt);
```

The evaluator must return the exact output bytes, the loader-exported effective
provider identity, and optional application evidence. The runner invokes Node
without a shell, bounds execution and captured output, applies the frozen
SHA-256 oracle, and records hashes of the effective environment without
publishing its values. The application contract still owns the independence of
the oracle and the meaning of the evidence. Pre-aborted signals prevent spawn.
An active abort, timeout, or output-limit violation terminates the governed
process group on POSIX and the direct child on Windows; the receipt records the
actual termination scope. Callers must not infer Windows descendant cleanup
from a child-process receipt.

`node-permission-read-only` enables Node's permission model, removes
`NODE_OPTIONS`, denies Node filesystem writes and child-process creation, and
allows reads only for the loader, application entrypoint, provider entrypoint,
and declared `readPaths`. Node implements a custom ESM loader with an internal
worker, so the runner necessarily enables workers and records
`workerThreads: "allowed-for-loader"`. WebGPU providers require native addons,
so addon loading is also enabled and recorded as
`nativeAddons: "allowed-for-provider"`. This is a Node API filesystem boundary,
not an operating-system sandbox: addon syscalls, network access, and other host
interfaces require separate isolation. An executable without compatible Node
permission flags fails closed as a process error.

## DoeProof CLI and CI

The package installs `doe-proof-node` for declarative unchanged-process runs:

```bash
doe-proof-node run doe-proof.contract.json --out run.json
doe-proof-node verify run.json
doe-proof-node inspect run.json
doe-proof-node replay run.json --out replay.json
doe-proof-node compare run.json replay.json
```

The JSON contract schema is exported as
`doe-gpu/governed-node-webgpu-process-contract.schema.json`. A contract
binds the provider entrypoint, workload entrypoint, input, evaluator module,
expected output, environment policy, timeout, and output limit. Every referenced
file has an exact SHA-256. Optional `runtimeFiles` entries bind additional
runtime data, libraries, manifests, or generated artifacts by unique ID, path,
and digest. The evaluator exports `evaluate(processResult, context)` and returns
the same `{ output, providerIdentity, evidence }` object as the JavaScript
process API.

The provider and application entrypoint digests cover those files, not their
entire transitive dependency closures. `workload.implementationSha256` is the
caller-declared aggregate identity for that larger closure and must be produced
by the application’s own build or manifest contract; Doe does not invent it by
hashing one entry file. `runtimeFiles` makes a declared set verifiable, but it
does not prove the set is complete or that the process accessed no other files.
Those stronger claims require a separately enforced filesystem contract.
When the contract selects `node-permission-read-only`, the CLI automatically
adds the input and every `runtimeFiles` path to the read allowlist. Provider,
application, and loader entrypoints are added by the process runner.

The matching receipt and CLI-artifact schemas are exported as
`doe-gpu/governed-node-webgpu-process-receipt.schema.json` and
`doe-gpu/governed-node-webgpu-process-artifact.schema.json`. JSON Schema checks
prove portable shape and types; `verify` remains authoritative for contract
hashes, dependency rehashing, provider coherence, oracle equality, and replay
hashes.

`verify` hashes the contract and dependencies and validates the nested process
receipt without importing or executing the evaluator. `replay` executes the
bound contract again and requires both semantic workload and provider-specific
execution identities to match. `compare` requires two independently valid,
oracle-passing artifacts with the same workload and output. It explicitly emits
`performanceInterpretable: false` and `runtimeOwnershipCredit: false`; those
claims require the separate application gate. `inspect` and `verify` expose the
bound dependency identities and effective filesystem declaration so CI does not
need to parse implementation-private state.

On `SIGINT` or `SIGTERM`, the CLI requests cancellation and writes a terminal
failed-but-valid evidence artifact when `--out` is present. Verifying that
artifact succeeds because verification establishes receipt integrity, not a
passing workload outcome.

## Entry points

`packages/doe-gpu/package.json` is the authoritative export list.

| Entry point | Purpose |
| --- | --- |
| `doe-gpu` | Host-aware public runtime surface |
| `doe-gpu/api` | Provider-neutral helpers and types |
| `doe-gpu/native` | Explicit native provider |
| `doe-gpu/node-webgpu` | Strict provider acquisition, governed exact-output execution, and lifecycle |
| `doe-gpu/node-webgpu-loader` | Fail-closed substitution for unchanged Node `webgpu` imports |
| `doe-gpu/node-webgpu-process` | Governed unchanged-process execution, exact oracle, and replay receipt |
| `doe-gpu/program-bundle` | Closed Program Bundle validation and execution |
| `doe-gpu/plan` | Execution-plan contracts |
| `doe-gpu/capture` | Record-only WebGPU capture |
| `doe-gpu/compute` | Compute-oriented helper surface |
| `doe-gpu/browser` | Browser compatibility wrapper |
| `doe-gpu/hybrid` | Legacy local/cloud integration helper |

The public `doe-proof-node` executable is the CLI/CI front door for the
governed process contract. It is not a benchmark or release-promotion command.

The hybrid helper has an explicit fallback-oriented contract and is not the
strict native-runtime path. New runtime integrations should use an explicit
provider list and consume its receipt.

## Runtime resolution

The package may resolve a matching optional platform package, a workspace
build, or an explicitly configured native library path. The selected binary
and provider must appear in diagnostics. A supported installation must not
require a local Zig build.

Release staging must run the native clean-install gate after the platform
payload is staged:

```bash
npm run test:integration:native-clean-install
npm run test:integration:native-clean-install:bun
npm run test:integration:native-reliability
npm run test:integration:native-reliability:bun
```

The gate packs the wrapper and matching platform package, installs both into a
fresh project with lifecycle scripts disabled, executes the runtime-specific
shipped first kernel, and rejects workspace-library resolution. Each receipt
binds the selected runtime executable and version. The ordinary integration
suite skips the Node physical package check when no staged platform payload
exists; either explicit release command fails instead.

The separate reliability commands reuse one clean installation across repeated
fresh processes and overlapping runtime instances, then execute 12 exact
create/compute/destroy cycles inside one additional process. They require exact
output, bounded child execution, stderr-free teardown, platform-package
resolution, and a reported post-warmup RSS span below the frozen diagnostic
ceiling. Every same-process cycle also registers `GPUDevice.lost` before
deliberate destruction, requires the `destroyed` reason, and verifies that
subsequent device use fails closed. This is not a long-soak leak certificate or
an unexpected hardware-loss recovery test. The commands do not establish
performance, application promotion, or release readiness.

Node 18 or newer is required for the default entrypoint. Bun and Deno use their
declared package export conditions. Actual platform support remains limited to
the tuples in [`docs/doe-support-matrix.md`](../../docs/doe-support-matrix.md).

## Evidence

Current package and runtime evidence lives in
[`reports/claim-index.json`](../../reports/claim-index.json):

- `claim-indexed` means a named row has current report and claim sidecars;
- `diagnostic` means the artifact is useful for engineering but cannot support
  promoted performance wording.

Do not infer broad compatibility or speed from one indexed row. Read the
workload, hardware, timing, oracle, and claim state in the referenced artifacts.

## Browser boundary

`doe-gpu/browser` wraps the browser's incumbent WebGPU implementation. It does
not install Doe beneath `navigator.gpu` and is not evidence of Chromium runtime
replacement. Browser integration is a separate governed lane under
`browser/chromium/`.

## Release boundary

Platform packages publish before the wrapper version that references them.
Publication requires package-readiness checks and the complete package test
suite. An npm package release does not promote native, browser, or hardware
claims that lack their own evidence.

Legacy `@simulatte/webgpu` and `@simulatte/webgpu-doe` names are migration
history. The package is licensed under Apache-2.0.
