# doe-gpu

<p align="center">
<img src="https://raw.githubusercontent.com/doerun/doe/main/assets/doe-logo.svg" alt="Doe logo" width="96" />
</p>

`doe-gpu` is the native, receipt-backed WebGPU runtime for Node.js and Bun.
Deno support is exposed through the package entrypoints.

It gives JavaScript a small layer over the native Doe runtime, with focused
subpaths for compute, browser compatibility, capture, plans, and native
provider access.

For Node.js benchmark and advanced provider-control work, the package also
exports `createNativeDirect()`. It exposes Doe's native WebGPU surface with the
same receipt-backed package identity while avoiding the default wrapper path.

## Install

```bash
npm install doe-gpu
```

## Why use it

- Small JS layer over the native Doe runtime
- Explicit failure instead of silent fallback
- One package surface across Node.js, Bun, and Deno
- Receipt-backed performance work against Dawn-backed package lanes
- Browser shim available when you want API compatibility rather than runtime
  replacement

## Current evidence

The npm package is the JavaScript runtime surface. It does not bundle the full
Vulkan, Metal, Dawn-vs-Doe, browser, or hardware evidence artifact trees.

The package participates in receipt-backed compare lanes, but package README
numbers are not the source of truth. Current public package and runtime claims
are indexed in
[`reports/claim-index.json`](https://github.com/doerun/doe/blob/main/reports/claim-index.json)
and summarized in the repo README backend evidence chart.

Read every evidence row by its explicit claim state:

- `claim-indexed`: public README claim row with a report path and required
  claim sidecar.
- `diagnostic`: useful engineering evidence, not public speed wording.
- `status-only`: support or capability status without a promoted performance
  claim.

Do not promote historical package percentages from old charts or local run
artifacts unless the current claim index and gates still mark the lane as
claimable.

## Additional benchmark outputs

Native, release, ORT, and browser lanes are summarized in the repo README. Read
[`README.md`](https://github.com/doerun/doe/blob/main/README.md) for the
current scope, metric direction, claim state, and artifacts.

## Usage

Install and run a first real kernel:

```bash
npm install doe-gpu
node node_modules/doe-gpu/examples/node-first-kernel.mjs
bun node_modules/doe-gpu/examples/bun-first-kernel.mjs
```

Each example prints runtime identity and emits an example-level JSON receipt.
These smoke examples are not performance claims.

```js
import { gpu } from "doe-gpu";

const device = await gpu.requestDevice();
const result = await device.compute({
  code: `@group(0) @binding(0) var<storage, read_write> data: array<f32>;
         @compute @workgroup_size(64) fn main(@builtin(global_invocation_id) id: vec3u) {
           data[id.x] = data[id.x] * 2.0;
         }`,
  inputs: [new Float32Array([1, 2, 3, 4])],
  output: { type: Float32Array, size: 16 },
  workgroups: 1,
});
```

Explicit native-direct Node surface:

```js
import { createNativeDirect } from "doe-gpu";

const gpu = createNativeDirect();
const adapter = await gpu.requestAdapter();
const device = await adapter.requestDevice();
```

## Subpaths

- `doe-gpu`: default native-runtime surface
- `doe-gpu/api`: provider-neutral JS API helpers and types
- `doe-gpu/native`: explicit Zig-backed native WebGPU provider
- `doe-gpu/node-webgpu`: explicit Node WebGPU provider bootstrap for
  repo-adjacent evidence tooling
- `doe-gpu/plan`: JSON command-stream, capture-graph, and execution-plan contracts
- `doe-gpu/capture`: alias for the record-only WebGPU capture provider
- `doe-gpu/compute`: narrower compute-focused surface
- `doe-gpu/browser`: browser wrapper over the browser's built-in WebGPU runtime
- `doe-gpu/hybrid`: legacy integration helper for local/cloud fallback

## Runtime requirements

- Node.js 18+ for the default package surface
- a matching optional platform package or a built/preinstalled Doe native library
- Bun and Deno are supported through the package entrypoints in `exports`

The `doe-gpu` package is the JS front door. Native artifacts are expected to
arrive through one of these paths:

- npm-installed optional platform packages such as `doe-gpu-darwin-arm64`
  and `doe-gpu-linux-x64`
- a local workspace build under `runtime/zig/zig-out/`
- explicit `DOE_WEBGPU_LIB` / `DOE_LIB` overrides
- local debug prebuilds under `packages/doe-gpu/prebuilds/<platform-arch>/`

If the native addon or shared library is missing, the package fails explicitly
instead of silently falling back to another runtime.

## Publish packaging

Cross-platform npm install support is package-based, not host-magic:

- `doe-gpu` publishes the JS wrapper and declares optional platform packages
- `doe-gpu-<platform>-<arch>` publishes the native `bin/` payload for that host

The platform package bin payload includes:

- `doe_napi.node`
- `libwebgpu_doe.<dylib|so>` or `webgpu_doe.dll`
- `doe-build-metadata.json`
- `metadata.json`

Before publishing a platform package, stage its `bin/` directory from a built
workspace:

```bash
cd packages/doe-gpu-darwin-arm64
npm run stage
```

Release order matters:

1. Build the native artifacts on the target host for each platform package.
2. Bump `doe-gpu-<platform>-<arch>` to the release version it will publish.
3. Run `npm run stage` in that platform package.
4. Verify `packages/doe-gpu` with `npm run test:smoke`,
   `npm run test:integration`, and `npm pack --dry-run`.
5. Publish the platform package versions first. On Apple, publish
   `doe-gpu-darwin-arm64` only after Linux is already published.
6. Publish `doe-gpu` only after every platform package version referenced in
   its `optionalDependencies` is already live on npm.

## Important distinctions

The default package and `/compute` remain batteries-included Doe native-runtime
surfaces. `/native` is the explicit subpath for consumers that want to bind to
the Zig-backed WebGPU provider directly.

`doe-gpu/browser` is different. It wraps the browser's incumbent WebGPU
implementation so code written against `doe-gpu` can run in a browser, but it
does not mean Doe has replaced the browser runtime.

`doe-gpu/api`, `doe-gpu/plan`, and `doe-gpu/capture` do not load native addons
or platform packages. They expose provider-neutral helpers, JSON shape checks,
WebGPU enum globals, and record-only capture into a Doe execution graph.

The portable capture boundary is WebGPU behavior, not arbitrary JavaScript
source translation. Host code may use normal JavaScript, but the observable GPU
work must flow through the supported provider subset:
`requestAdapter`, `requestDevice`, buffer creation/writes, WGSL shader module
creation, bind group and compute pipeline creation, command encoding,
compute dispatch, buffer copies, queue submission, and selected readback
checkpoints. Unsupported CSL features such as render passes, textures,
samplers, atomics, and generic subgroup behavior fail explicitly in capture
mode.

`doe-gpu/hybrid` is kept for compatibility, but product model loading,
tokenizers, generation, and local/cloud routing should live above Doe. New
Doppler integrations should prefer an explicit Doppler provider over treating
`/hybrid` as a core Doe runtime layer.

There is intentionally no public `doe-gpu/csl` subpath yet. CSL and SdkLayout
lowering stay private until the HostPlan and receipt boundary is stable enough
to publish without overpromising. The public boundary today is the captured
WebGPU graph plus plan/receipt contracts. Public demos should bind the Doppler
runner, capture graph hash, WGSL hashes, lowering stage status, and parity
verdict through `doe_webgpu_capture_evidence` receipts.

## Repo-adjacent surfaces

`createDoeRuntime()` and `runDawnVsDoeCompare()` remain available for
repo-adjacent environments that already have Doe runtime or compare assets.

Deeper runtime internals, benchmark workflows, and status live in the repo:

- repo overview:
  [`README.md`](https://github.com/doerun/doe/blob/main/README.md)
- runtime internals:
  [`runtime/zig/README.md`](https://github.com/doerun/doe/blob/main/runtime/zig/README.md)
- benchmarks and evidence:
  [`bench/README.md`](https://github.com/doerun/doe/blob/main/bench/README.md)
- current status:
  [`docs/status.md`](https://github.com/doerun/doe/blob/main/docs/status.md)
- browser integration:
  [`browser/chromium/README.md`](https://github.com/doerun/doe/blob/main/browser/chromium/README.md)

## Legacy package names

These legacy package names are deprecated in favor of `doe-gpu`:

- `@simulatte/webgpu`
- `@simulatte/webgpu-doe`

## License

Apache-2.0. See
[`docs/licensing.md`](https://github.com/doerun/doe/blob/main/docs/licensing.md).
