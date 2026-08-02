# doe-gpu

<p align="center">
<img src="https://raw.githubusercontent.com/doerun/doe/main/assets/doe-logo.svg" alt="Doe logo" width="96" />
</p>

`doe-gpu` is the JavaScript entry point for Doe's native WebGPU runtime. It
loads a native Doe library when one is available and fails explicitly when it is
not.

## Install

```bash
npm install doe-gpu
```

## Package map

```text
+-------------------+
| app code          |
| Node | Bun | Deno |
+---------+---------+
         |
         v
+--------------------------------+
| doe-gpu npm package            |
| JS API + native runtime loader |
+------+------------+------------+
       |            |
       v            v
+-------------+  +--------------------------------+
| entrypoints |  | native library resolution      |
| compute     |  | optional pkg | workspace build |
| native      |  | DOE_WEBGPU_LIB / DOE_LIB       |
| node-webgpu |  +---------------+----------------+
| plan        |                  |
| capture     |                  v
| browser     |          +----------------+
+------+------+          | libwebgpu_doe  |
      |                +-------+--------+
      |                        |
      |                        v
      |          +-------------------------------+
      |          | native backend path           |
      |          | Metal | Vulkan | D3D12/DXIL  |
      |          +---------------+---------------+
      |                          |
      +--------------------------+
                                 v
                      +---------------------+
                      | receipts or explicit|
                      | missing-runtime fail|
                      +---------------------+

+------------------+     +--------------------------+
| doe-gpu/browser  | --> | incumbent browser WebGPU |
+------------------+     +--------------------------+

+-------------------------------+
| Fawn/Chromium                 |
| separate browser release lane |
+-------------------------------+
```

## Usage

Run the package examples:

```bash
node node_modules/doe-gpu/examples/node-first-kernel.mjs
bun node_modules/doe-gpu/examples/bun-first-kernel.mjs
```

Or call the default compute surface:

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

Use `createNativeDirect()` when you want the native WebGPU provider directly:

```js
import { createNativeDirect } from "doe-gpu";

const gpu = createNativeDirect();
const adapter = await gpu.requestAdapter();
const device = await adapter.requestDevice();
```

For one-step device acquisition, prefer the explicit names:

```js
import { requestRawDevice, requestBoundDevice } from "doe-gpu";

const rawDevice = await requestRawDevice();
const boundDoe = await requestBoundDevice();
// boundDoe.device is the underlying raw GPUDevice.
```

The older root `requestDevice()` remains a raw-device compatibility alias.
`gpu.requestDevice()` returns the bound helper; the explicit names avoid that
historical root-versus-namespace ambiguity.

## Entry Points

- `doe-gpu`: default runtime surface
- `doe-gpu/compute`: compute-focused helper surface
- `doe-gpu/native`: explicit Zig-backed native WebGPU provider
- `doe-gpu/node-webgpu`: strict provider-v1 acquisition and lifecycle
- `doe-gpu/program-bundle`: closed Doppler Program Bundle validation/execution
- `doe-gpu/api`: provider-neutral helpers and types
- `doe-gpu/plan`: JSON command-stream and execution-plan contracts
- `doe-gpu/capture`: record-only WebGPU capture provider
- `doe-gpu/browser`: browser API wrapper
- `doe-gpu/hybrid`: compatibility helper for older integrations

## Runtime requirements

- Node.js 18+ for the default package entry point
- Bun and Deno are supported through the package entrypoints in `exports`
- a matching optional platform package, local workspace build, or explicit
  native library path

Native loading checks these paths:

- npm-installed optional platform packages such as `doe-gpu-darwin-arm64`
  and `doe-gpu-linux-x64`
- a local workspace build under `runtime/zig/zig-out/`
- explicit `DOE_WEBGPU_LIB` / `DOE_LIB` overrides
- local debug prebuilds under `packages/doe-gpu/prebuilds/<platform-arch>/`

If the native addon or shared library is missing, the package fails explicitly
instead of silently falling back to another runtime.

Provider-v1 callers declare an ordered provider list, exact factory/export
bindings, adapter options, and global-installation mode. `openNodeWebGPU(...)`
returns a receipt-bearing session whose `close()` restores changed globals.
Doe's Program Bundle runner additionally requires a canonical closed bundle and
explicit provider options; host execution occurs only when a host bridge is
provided.

Publishing is fail-closed. `prepublishOnly` requires an authenticated npm
account, exact-version platform packages already present in the selected
registry with matching CPU/OS metadata and integrity, and the complete package
test suite. Platform packages therefore publish before the main wrapper; an
unauthenticated host cannot publish accidentally.

## Evidence

The npm package is the JavaScript wrapper. It does not bundle the full Vulkan,
Metal, Dawn-vs-Doe, browser, or hardware evidence trees.

![Doe Metal and Vulkan evidence summary](https://raw.githubusercontent.com/doerun/doe/main/assets/readme/backend-evidence-summary.svg)

Current public package and runtime evidence is indexed in
[`reports/claim-index.json`](https://github.com/doerun/doe/blob/main/reports/claim-index.json).
The shared chart separates claim-indexed Apple Metal package/native rows, AMD
Vulkan package/native/drop-in rows, and diagnostic ORT/browser rows.
Read each row by its claim state:

- `claim-indexed`: public claim row with a report path and claim sidecar.
- `diagnostic`: measured engineering evidence, not public speed wording.
- `status-only`: support or capability status without a performance claim.

Do not promote old package charts or local run artifacts unless the current
claim index and gates still mark the lane as claimable.

## Release boundary

A `doe-gpu` npm release is a package/native-runtime release. It is not, by
itself, a Fawn/Chromium browser release and it does not prove that Doe replaces
Dawn in every browser path.

Platform packages and prebuilds are platform-specific. macOS arm64, Linux x64,
and future Windows artifacts need matching native libraries, package metadata,
and evidence rows. Keep macOS evidence and downloads separate from Linux Vulkan
browser diagnostics.

Browser runtime releases need their own public archive, SHA-256, proof surface,
launch receipt, and Dawn-vs-Doe comparison receipts outside the npm package.

## Browser boundary

`doe-gpu/browser` wraps the browser's incumbent WebGPU implementation. It is
for API compatibility in browser code; it is not Doe replacing the browser
runtime.

A future Fawn/Doe browser artifact for macOS arm64 should be documented as a
separate browser release lane, not as `doe-gpu/browser`.

## More detail

- repo overview:
  [`README.md`](https://github.com/doerun/doe/blob/main/README.md)
- runtime internals:
  [`runtime/zig/README.md`](https://github.com/doerun/doe/blob/main/runtime/zig/README.md)
- benchmarks and evidence:
  [`bench/README.md`](https://github.com/doerun/doe/blob/main/bench/README.md)
- current status:
  [`docs/status.md`](https://github.com/doerun/doe/blob/main/docs/status.md)

## Legacy package names

These legacy package names are deprecated in favor of `doe-gpu`:

- `@simulatte/webgpu`
- `@simulatte/webgpu-doe`

## License

Apache-2.0. See
[`docs/licensing.md`](https://github.com/doerun/doe/blob/main/docs/licensing.md).
