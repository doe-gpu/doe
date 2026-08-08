# doe-gpu

`doe-gpu` is the public JavaScript package for Doe's native WebGPU runtime.
Support is limited to the runtime, operating-system, architecture, backend,
and workload tuples declared in the Doe support matrix.

## Install and verify

```bash
npm install doe-gpu
node node_modules/doe-gpu/examples/node-first-kernel.mjs
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

## Entry points

`packages/doe-gpu/package.json` is the authoritative export list.

| Entry point | Purpose |
| --- | --- |
| `doe-gpu` | Host-aware public runtime surface |
| `doe-gpu/api` | Provider-neutral helpers and types |
| `doe-gpu/native` | Explicit native provider |
| `doe-gpu/node-webgpu` | Strict provider acquisition and lifecycle |
| `doe-gpu/program-bundle` | Closed Program Bundle validation and execution |
| `doe-gpu/plan` | Execution-plan contracts |
| `doe-gpu/capture` | Record-only WebGPU capture |
| `doe-gpu/compute` | Compute-oriented helper surface |
| `doe-gpu/browser` | Browser compatibility wrapper |
| `doe-gpu/hybrid` | Legacy local/cloud integration helper |

The hybrid helper has an explicit fallback-oriented contract and is not the
strict native-runtime path. New runtime integrations should use an explicit
provider list and consume its receipt.

## Runtime resolution

The package may resolve a matching optional platform package, a workspace
build, or an explicitly configured native library path. The selected binary
and provider must appear in diagnostics. A supported installation must not
require a local Zig build.

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
