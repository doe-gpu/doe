# Doe Node WebGPU and Program Bundle contracts

Doe owns device acquisition, compute helpers, and lifecycle. Doppler owns the
portable Program Bundle. The boundary between them consists of two versioned,
fail-closed contracts.

## Provider v1

Import the provider contract from `doe-gpu/node-webgpu`:

```js
import { openNodeWebGPU } from 'doe-gpu/node-webgpu';

const session = await openNodeWebGPU({
  providers: [{
    id: 'selected-provider',
    kind: 'module',
    module: 'webgpu',
    gpu: {
      kind: 'factory',
      path: 'create',
      args: [['enable-dawn-features=allow_unsafe_apis']],
    },
    globals: {
      GPUBufferUsage: 'globals.GPUBufferUsage',
      GPUShaderStage: 'globals.GPUShaderStage',
      GPUMapMode: 'globals.GPUMapMode',
      GPUTextureUsage: 'globals.GPUTextureUsage',
    },
  }],
  adapterOptions: null,
  globals: { mode: 'replace' },
});

try {
  const device = await session.adapter.requestDevice();
  // Use the device.
} finally {
  await session.close();
}
```

The caller supplies an ordered `providers` array. A module provider names one
exact export or factory path, its exact argument array, an optional result path,
and the exact enum bindings. Provider v1 does not guess factory signatures or
discard initialization failures. Each attempt appears in the receipt with its
stage, typed error code, and selected provider identity.

`session.close()` restores every global descriptor changed by the session.
`globals.mode` is explicit:

- `none` leaves globals untouched;
- `install-missing` fills absent globals only;
- `replace` installs the selected provider and later restores prior values.

Compatibility helpers remain available, but new integrations should use
`openNodeWebGPU(...)` and own the returned session.

## Closed Program Bundle execution

Import Doe's consumer from `doe-gpu/program-bundle`:

```js
import { runProgramBundle } from 'doe-gpu/program-bundle';

const receipt = await runProgramBundle({
  programBundlePath: '/absolute/path/to/program-bundle.json',
  providerOptions,
  execution: {
    hostBridge,
    input,
  },
});
```

Doe packages an exact byte mirror of Doppler's generated JSON Schema. The
consumer verifies that schema, checks every bundle-relative WGSL and constrained
host-JS file against its declared SHA-256 and byte size, compiles only the
declared WGSL entrypoint, and optionally invokes the packaged host entrypoint
through a caller-supplied bridge.

The result separates four facts:

- `schemaValid`
- `providerAvailable`
- `executed`
- `transcriptMatched`

Compile-only execution cannot report transcript parity. Schema validation does
not imply provider availability. Provider availability does not imply that the
host program executed.

There is no adjacent Doppler checkout lookup, ambient model discovery, prompt
default, token-count default, provider fallback outside the declared order, or
implicit host execution. The package contains source bytes required by the
Program Bundle itself; model and weight artifacts remain separately hash-bound
artifacts under the Doppler contract.

## Schema synchronization

Doppler generates `src/config/schema/program-bundle.schema.json`. Doe mirrors
those exact bytes into:

- `config/doe-doppler-program-bundle.schema.json`
- `packages/doe-gpu/assets/program-bundle.schema.json`

Synchronization is explicit and never searches for a sibling checkout:

```bash
node packages/doe-gpu/scripts/sync-program-bundle-schema.js \
  --source /path/to/doppler/src/config/schema/program-bundle.schema.json
```

Use `--check` to verify both mirrors without writing them.

## CLI evidence surface

`bench/tools/run_doe_webgpu_program_bundle_inference.mjs` requires an explicit
mode. `validate` checks closed package bytes. `compile` additionally requires a
provider-v1 JSON config. `execute` additionally requires an explicit host bridge
module. The tool never imports Doppler or infers a sibling repository.
