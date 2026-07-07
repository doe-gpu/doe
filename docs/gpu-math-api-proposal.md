# GPU math API proposal

## Status

This is a design proposal for an experimental `doe-gpu/math` layer. It is not
a shipped package contract, not a replacement for the current low-level compute
surface, and not public performance claim language.

Current API/spec artifacts:

- Draft receipt schema: `config/doe-gpu-math-receipt.schema.json`
- Schema sample: `examples/doe-gpu-math-receipt.sample.json`
- Proposed import: `import { gpu, wgsl } from "doe-gpu/math"`
- Package status: `doe-gpu/math` is proposed only and is not exported from
  `packages/doe-gpu/package.json`

The purpose is to explore a more usable front door for mathematical GPU
calculations while preserving Doe's core requirements:

- generated WGSL remains inspectable
- dtype and shape inference is receipt-backed
- CPU/GPU synchronization is explicit
- materialization boundaries are explicit
- fusion behavior is reported, not hidden
- raw kernel escape hatches remain available

## Problem

The current low-level compute shape is correct but too boilerplate-heavy for
simple math:

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

That API exposes the primitive. A math layer should expose intent:

```js
import { gpu, wgsl } from "doe-gpu/math";

const y = await gpu.map([1, 2, 3, 4], wgsl`x * 2.0`);
```

The hard part is not syntax. The hard part is keeping this pleasant path honest
when shape, dtype, layout, reductions, fusion, and readback boundaries matter.

## Design position

Use progressive disclosure:

1. Convenience front door for one-shot common cases.
2. Lazy graph surface for composition.
3. Explicit data/kernel surface for hard cases.

The front door should not own the semantics. The graph and receipt contract
should own the semantics; the pleasant syntax should be a thin adapter over it.

Prototype examples use `doe-gpu/math` intentionally. The root `doe-gpu` export
should not expose this layer until the receipt, resource ownership, and fusion
contracts are stable.

## Doe/Doppler boundary

Doe owns the GPU math graph contract: host data wrappers, WGSL fragment
validation, dtype and shape inference, graph planning, compilation, dispatch,
resource ownership, synchronization, fusion reporting, and math receipts.

Doppler owns model and program semantics: model manifests, tokenizer and
weights identity, program bundle export, model-specific execution graphs, and
release evidence.

The shared seam should be schema and hash linked, not source-tree linked. A Doe
math receipt may optionally bind to a Doppler Program Bundle by recording the
bundle schema, bundle hash, execution graph hash, WGSL module-set hash, and
reference transcript hash. No `doe-gpu/math` API should import Doppler
internals, and no Doppler API should re-export Doe math as its public surface.

For this pass, Doppler interop fields stay nullable. They describe the eventual
unification point without requiring a Doppler runtime dependency or a local
neighbor checkout.

## Ergonomic decisions

- `gpu.map(data, expr)` returns the host value directly.
- `gpu.map(data, expr, { receipt: true })` returns `{ value, receipt }`.
- `.read()` returns a typed array derived from the output dtype by default.
- `.read({ receipt: true })` returns `{ value, receipt }`.
- `.read({ as: "array" })` may convert to a plain JavaScript array for small
  ergonomic cases, but typed arrays are the default.
- `gpu.array(data)` creates a lazy data node. It uploads only when execution
  requires it.
- `.materialize()` is the explicit GPU upload/execution boundary and returns an
  owned GPU-backed math value.
- `.plan()` is synchronous and produces generated WGSL plus a planning receipt.
- `.compile()` is asynchronous because backend/device validation and pipeline
  creation are runtime-sensitive.
- Generated kernels are cached by final WGSL hash plus semantic graph hash,
  dtype/shape/layout, symbol scopes, backend/runtime identity, relevant device
  limits/features, workgroup policy, and fusion plan.
- Reductions default to fast non-deterministic floating order. Deterministic
  reductions are opt-in with `{ deterministic: true }`, and the effective policy
  must be in the receipt.

## Chosen ergonomic contract

The best API shape is two front doors over the same graph contract.

For one-shot math, use a direct operation:

```js
const y = await gpu.map([1, 2, 3, 4], wgsl`x * 2.0`);
```

For composed work, use a lazy value:

```js
const { value, receipt } = await gpu
  .array([1, 2, 3, 4])
  .map(wgsl`x * 2.0`)
  .map(wgsl`sqrt(x + 1.0)`)
  .read({ receipt: true });
```

`gpu.array(...)` is not a GPU upload. It is the explicit point where host data
enters the math graph. Shape and dtype stay optional only for cases that are
safe to infer; every inferred choice must appear in the receipt.

Uniforms should use typed wrappers directly in the options object. Avoid a
separate `{ uniforms, values }` declaration because it repeats names and makes
simple math feel ceremonial:

```js
const y = await gpu.map(values, wgsl`x * scale + bias`, {
  scale: gpu.f32(0.5),
  bias: gpu.f32(2.0),
});
```

More than two inputs should be named at the graph edge instead of inventing
implicit `z`, `w`, or positional symbols:

```js
const y = await gpu
  .zip({ activation, weight, bias })
  .map(wgsl`activation * weight + bias`)
  .read();
```

The escape hatch is explicit. If the operation cannot be expressed as map, zip,
sum, reduce, or materialize, use `gpu.kernel(...)` and keep the full contract in
the receipt.

This keeps the pleasant path small without hiding execution detail: convenience
calls still lower into graph nodes, generated WGSL, dispatches, resource
ownership, sync boundaries, and cache identity.

## Proposed layers

### Layer 1: convenience calls

Use this when the operation is simple and immediate host readback is acceptable.

```js
const y = await gpu.map([1, 2, 3, 4], wgsl`x * 2.0`);
```

Equivalent expanded intent:

```js
const y = await gpu
  .array([1, 2, 3, 4])
  .map(wgsl`x * 2.0`)
  .read();
```

Convenience calls may infer dtype and shape, execute, and read back. They must
still be able to produce a receipt:

```js
const { value, receipt } = await gpu.map([1, 2, 3, 4], wgsl`x * 2.0`, {
  receipt: true,
});
```

### Layer 2: lazy graph

Use this when composing operations or when readback should be delayed.

```js
const y = await gpu
  .array([1, 2, 3, 4])
  .map(wgsl`x * 2.0`)
  .map(wgsl`sqrt(x + 1.0)`)
  .read();
```

This builds a graph. It should not imply one GPU dispatch per method call.
Legal operations may fuse, but the fusion result must be inspectable.

### Layer 3: explicit data and raw kernels

Use this when shape, dtype, layout, output ownership, or dispatch geometry must
be explicit.

```js
const out = await gpu.kernel({
  inputs: {
    data: gpu.array(values, { dtype: "f32", shape: [values.length] }),
  },
  outputs: {
    result: { dtype: "f32", shape: [values.length] },
  },
  workgroupSize: 64,
  fn: wgsl`
    fn compute(x: f32, i: u32) -> f32 {
      return x * x + f32(i);
    }
  `,
}).read("result");
```

## WGSL fragments

The tagged template should produce a typed fragment object rather than a plain
string:

```js
function wgsl(strings, ...values) {
  if (values.length !== 0) {
    throw new TypeError(
      "wgsl template interpolation is not supported; pass runtime values as typed uniforms or buffers."
    );
  }
  return {
    kind: "wgsl",
    source: String.raw({ raw: strings.raw }),
  };
}
```

String interpolation is rejected in the first version. Runtime values must be
passed as typed uniforms or buffers:

```js
const y = await gpu.map([1, 2, 3, 4], wgsl`x * scale + bias`, {
  scale: gpu.f32(0.5),
  bias: gpu.f32(2.0),
});
```

The fragment is not standalone WGSL. Its valid symbols depend on the operation
that receives it.

## Symbol scopes

| Operation | Symbols | Notes |
|---|---|---|
| map fragment | `x`, `i`, `n`, `coord` for shaped arrays | `x` is the element, `i` is `u32`, `n` is `u32`. |
| zip map fragment | `x`, `y`, `i`, `n`, `coord` | Names beyond two inputs need explicit aliases. |
| `reduce(...)` | `x` in map phase, `a`/`b` in combine phase | Floating reductions need determinism policy. |
| `stencil(...)` | `x`, `coord`, `sample(dx, dy, ...)` | Boundary policy must be explicit. |
| `kernel(...)` | Whatever the full function declares | Raw escape hatch controls its own function shape. |

For more than two inputs, avoid implicit `z`, `w`, etc. Prefer explicit names:

```js
const y = await gpu
  .zip({ input, weights, bias })
  .map(wgsl`input * weights + bias`)
  .read();
```

## Inference rules

Keep inference narrow.

| Input | Inferred dtype | Inferred shape |
|---|---|---|
| `[1, 2, 3]` | `f32` | `[3]` |
| `Float32Array` | `f32` | `[length]` |
| `Int32Array` | `i32` | `[length]` |
| `Uint32Array` | `u32` | `[length]` |
| Nested JS arrays | unsupported initially | explicit shape required |
| Mixed JS numbers | `f32` or fail if non-finite | `[length]` |

Explicit dtype and shape are required when inference would be surprising:

```js
const ids = gpu.array([1, 2, 3, 4], { dtype: "u32" });

const image = gpu.array(pixels, {
  dtype: "f32",
  shape: [height, width, 4],
});
```

No silent broadcasting in the first version.

```js
await gpu.array([1, 2, 3])
  .zip(gpu.array([1, 2, 3, 4]))
  .map(wgsl`x + y`)
  .read();
// Error: zip shape mismatch [3] vs [4]
```

If broadcasting is added later, require an explicit mode:

```js
const y = await a
  .zip(b, { broadcast: "numpy-subset" })
  .map(wgsl`x + y`)
  .read();
```

## Examples

### Elementwise map

```js
const y = await gpu
  .array([1, 2, 3, 4])
  .map(wgsl`x * 2.0`)
  .read();
```

### Typed array map

```js
const y = await gpu
  .array(new Uint32Array([1, 2, 3, 4]))
  .map(wgsl`x + 1u`)
  .read();
```

### Explicit integer path

```js
const y = await gpu
  .array([1, 2, 3, 4], { dtype: "i32" })
  .map(wgsl`x * 2`)
  .read();
```

### Uniforms

```js
const y = await gpu
  .array([1, 2, 3, 4])
  .map(wgsl`x * scale + bias`, {
    scale: gpu.f32(0.5),
    bias: gpu.f32(2.0),
  })
  .read();
```

### Index-aware map

```js
const y = await gpu
  .array([10, 20, 30, 40])
  .map(wgsl`x + f32(i)`)
  .read();
```

### Zip

```js
const a = gpu.array([1, 2, 3, 4]);
const b = gpu.array([10, 20, 30, 40]);

const c = await a
  .zip(b)
  .map(wgsl`x + y * 0.5`)
  .read();
```

### Named zip

```js
const y = await gpu
  .zip({
    activation: gpu.array(a),
    weight: gpu.array(w),
    bias: gpu.array(b),
  })
  .map(wgsl`activation * weight + bias`)
  .read();
```

### Materialization

```js
const tmp = await gpu
  .array([1, 2, 3, 4])
  .map(wgsl`x * x`)
  .materialize();

const y = await tmp
  .map(wgsl`x + 1.0`)
  .read();
```

`materialize()` forces a GPU buffer boundary without CPU readback. The returned
value owns GPU resources and must expose `dispose()`. Finalizers may warn about
leaks, but explicit disposal is the contract:

```js
const tmp = await gpu
  .array([1, 2, 3, 4])
  .map(wgsl`x * x`)
  .materialize();

try {
  const y = await tmp.map(wgsl`x + 1.0`).read();
} finally {
  tmp.dispose();
}
```

### Reduction

```js
const total = await gpu
  .array([1, 2, 3, 4])
  .sum({ deterministic: false })
  .read();
```

Deterministic reductions should be opt-in and may use a slower fixed reduction
tree:

```js
const total = await gpu
  .array([1, 2, 3, 4])
  .sum({ deterministic: true })
  .read();
```

### Custom reduction

```js
const maxAbs = await gpu
  .array([-1, 5, -9, 2])
  .reduce({
    init: wgsl`0.0`,
    map: wgsl`abs(x)`,
    combine: wgsl`max(a, b)`,
  })
  .read();
```

### Matrix path

Matrix and tensor helpers should be later-stage APIs, not the first prototype.

```js
const y = await gpu
  .mat(weights, [m, k])
  .matmul(gpu.mat(input, [k, n]))
  .map(wgsl`max(x, 0.0)`)
  .read();
```

If matrix helpers are added later, `mat(data, [rows, cols])` should mean
row-major contiguous layout. Any other layout must be explicit, and the receipt
must record the effective layout.

### Stencil path

Stencil/grid helpers should be later-stage APIs because they need explicit
boundary, coordinate, and sampling semantics.

```js
const blurred = await gpu
  .grid(image, { dtype: "f32", shape: [height, width, 4] })
  .stencil({
    radius: 1,
    boundary: "clamp",
    fn: wgsl`
      sample(-1, 0) * 0.25 +
      sample( 0, 0) * 0.50 +
      sample( 1, 0) * 0.25
    `,
  })
  .read();
```

### Compile and inspect

Users must be able to inspect generated WGSL before execution:

```js
const plan = gpu
  .array([1, 2, 3, 4])
  .map(wgsl`x * 2.0`)
  .plan();

console.log(plan.wgsl);
console.log(plan.receipt);

const executable = await plan.compile();
const y = await executable.run().read();
```

`plan()` is synchronous code generation and graph analysis. `compile()` is
asynchronous because it may create device-specific shader modules or pipelines.

## Fusion contract

Fusion is allowed only when it preserves declared semantics.

Obvious fusion candidate:

```js
const y = await gpu
  .array([1, 2, 3, 4])
  .map(wgsl`x * 2.0`)
  .map(wgsl`sqrt(x + 1.0)`)
  .map(wgsl`clamp(x, 0.0, 3.0)`)
  .read();
```

Likely fused into one generated kernel.

Fusion boundary:

```js
const tmp = await gpu
  .array([1, 2, 3, 4])
  .map(wgsl`x * x`)
  .materialize();
```

`materialize()` must stop elementwise fusion across that boundary.

Reduction boundary:

```js
const y = await gpu
  .array([1, 2, 3, 4])
  .map(wgsl`x * x`)
  .sum({ deterministic: false })
  .read();
```

`map().sum()` may fuse into a map-reduce kernel, but the receipt must say so and
the reduction determinism policy must be visible.

Fusion receipts should include:

- graph node list
- fused groups
- rejected fusion opportunities and reasons
- generated WGSL per dispatch
- dispatch geometry
- buffer allocation plan
- materialization and readback boundaries
- dtype and shape after every operation

## Receipt requirements

The normative draft schema for this proposal is
`config/doe-gpu-math-receipt.schema.json`. The sample artifact is
`examples/doe-gpu-math-receipt.sample.json`. Prose examples below are
illustrative; the schema decides field names and required structure.

Every executed graph should be able to answer:

- What dtype was inferred?
- What shape was inferred?
- What symbols existed inside each WGSL fragment?
- What full WGSL was generated?
- Was the graph fused?
- What dispatches ran?
- What buffers were allocated?
- What data moved CPU -> GPU or GPU -> CPU?
- Where did synchronization happen?
- What cache key, if any, was used for generated kernels?
- What runtime/backend executed the graph?

Suggested receipt shape:

```json
{
  "schemaVersion": 1,
  "artifactKind": "doe-gpu-math-receipt",
  "apiStability": "experimental",
  "status": "ok",
  "runtime": {
    "package": "doe-gpu/math",
    "backend": "doe-native-webgpu",
    "adapter": "amd-vulkan",
    "deviceLimitsHash": "<sha256>",
    "featureSetHash": "<sha256>"
  },
  "graph": {
    "nodeCount": 2,
    "nodes": [
      {
        "id": "array#0",
        "op": "array",
        "dtype": "f32",
        "shape": [4],
        "dtypeInferred": true,
        "shapeInferred": true,
        "hostInput": "plain-array"
      },
      {
        "id": "map#1",
        "op": "map",
        "input": "array#0",
        "outputDtype": "f32",
        "outputShape": [4],
        "fragment": {
          "source": "x * 2.0",
          "sourceSha256": "<sha256>",
          "symbols": {
            "x": "f32",
            "i": "u32",
            "n": "u32"
          }
        }
      }
    ]
  },
  "fusion": {
    "enabled": true,
    "groups": [["map#1"]],
    "rejected": [],
    "boundaries": ["read"]
  },
  "generated": {
    "dispatches": [
      {
        "id": "dispatch#0",
        "nodes": ["map#1"],
        "wgsl": "<full generated WGSL source>",
        "wgslSha256": "<sha256>",
        "workgroupSize": 64,
        "workgroups": [1, 1, 1],
        "bindings": [
          { "binding": 0, "name": "input", "addressSpace": "storage", "access": "read" },
          { "binding": 1, "name": "output", "addressSpace": "storage", "access": "read_write" }
        ]
      }
    ]
  },
  "buffers": {
    "allocations": [
      { "id": "buffer#input", "bytes": 16, "owner": "graph", "lifetime": "read" },
      { "id": "buffer#output", "bytes": 16, "owner": "graph", "lifetime": "read" }
    ],
    "transfers": [
      { "direction": "cpu-to-gpu", "bytes": 16, "source": "array#0" },
      { "direction": "gpu-to-cpu", "bytes": 16, "target": "read" }
    ]
  },
  "sync": {
    "boundaries": [
      { "kind": "readback", "operation": "read" }
    ]
  },
  "cache": {
    "key": "<sha256>",
    "hit": false
  }
}
```

This is the minimum useful shape for the proposed API. Promotion from proposal
to experimental package contract requires schema validation, a stable sample,
and generated receipts that match this contract.

## Non-goals for this pass

- No runtime implementation.
- No package export change.
- No root `doe-gpu` API change.
- No Doppler code change.
- No matrix, stencil, broadcasting, strided view, or in-place write contract.
- No benchmark, release, or performance claim.
- No source-tree neighbor dependency between Doe and Doppler.

## Promotion gates

- The receipt schema is registered in `config/schema-targets.json`.
- The sample receipt validates against the schema.
- Every hidden choice has a receipt field: dtype, shape, symbols, generated
  WGSL, dispatch, bindings, buffers, transfers, sync, fusion, cache, runtime,
  and optional interop.
- `doe-gpu/math` remains under its own export path until the contract is stable.
- Doppler interop is artifact-bound and hash-linked; it does not depend on a
  checked-out sibling repository.
- Fusion and readback behavior remain inspectable before any performance claim
  can be made.

## Error examples

Shape mismatch:

```text
DoeGpuShapeError: zip shape mismatch.
left:  dtype=f32 shape=[3]
right: dtype=f32 shape=[4]
operation: zip().map(wgsl`x + y`)
hint: pass { broadcast: "numpy-subset" } only after broadcast support exists.
```

Symbol mismatch:

```text
DoeGpuWgslScopeError: unknown symbol "scale" in map fragment.
available symbols: x, i, n
hint: pass scale as gpu.f32(value) in the options object.
```

Unsupported dtype:

```text
DoeGpuDtypeError: Float64Array is not supported by the experimental math layer.
hint: convert to Float32Array or pass { dtype: "f32" } with explicit conversion.
```

Non-deterministic reduction:

```text
DoeGpuDeterminismError: sum({ deterministic: true }) is unsupported for this
backend/configuration.
hint: use deterministic=false or choose a backend/profile with fixed reduction
tree support.
```

## Coverage plan

| Area | Prototype | Later | Notes |
|---|---:|---:|---|
| `gpu.map(data, expr)` | yes | yes | Convenience front door. |
| `gpu.array(data).map(expr)` | yes | yes | Lazy graph base. |
| Typed array dtype inference | yes | yes | f32/i32/u32 first. |
| Plain JS array inference | yes | yes | f32 and 1D only. |
| Explicit shape | yes | yes | Required beyond 1D. |
| Uniform scalar wrappers | yes | yes | `gpu.f32`, `gpu.i32`, `gpu.u32`. |
| `zip().map()` | yes | yes | Exact shape match only at first. |
| Named zip inputs | yes | yes | Avoid `z`, `w` symbol sprawl. |
| `sum()` | yes | yes | Effective determinism policy appears in receipt. |
| Custom `reduce()` | yes | yes | Explicit `init`, `map`, and `combine` fragments. |
| `materialize()` | yes | yes | Explicit GPU boundary. |
| `plan()`/inspection | yes | yes | Synchronous generated WGSL and planning receipt. |
| `compile()` | yes | yes | Asynchronous backend/device preparation. |
| Matrix helpers | no | yes | Needs layout policy. |
| Stencil/grid helpers | no | yes | Needs boundary policy. |
| Broadcasting | no | maybe | Must never be silent. |
| Strided/views | no | maybe | High complexity. |
| In-place aliasing | no | maybe | Must prove no unsafe overwrite. |
| Kernel escape hatch | yes | yes | Use existing lower-level contracts. |

## Tradeoffs

### Pleasant front door vs semantic weight

The `gpu.map(...)` front door is attractive because it removes WebGPU
plumbing. It also hides dtype, shape, allocation, dispatch, and readback unless
the receipt exposes them. The API should stay pleasant, but the implementation
must never hide those decisions.

### WGSL fragments vs JavaScript lambdas

WGSL fragments keep shader math visible and avoid a JavaScript-to-WGSL compiler.
The tradeoff is that fragments need explicit symbol scopes and better errors.
This is preferable to pretending arbitrary JavaScript lambdas can become GPU
code safely.

### Lazy fusion vs predictable execution

Lazy graphs enable fusion and fewer dispatches. They also make performance and
numeric behavior less obvious. Fusion should be opt-out through
`materialize()`, visible through receipts, and conservative until semantics are
stable.

### Defaults vs compatibility traps

Defaulting plain arrays to `f32` makes examples concise. It may become a
compatibility trap. The first implementation should mark these defaults in
receipts and keep the supported inference set small.

### Tensor ambition vs first useful slice

Matrix, tensor, and stencil operations are important, but they should not
define the first API. They require layout, broadcasting, boundary, and
determinism policies. Start with array, map, zip, reduction, materialize, plan,
compile, read, and receipt.

## Closed decisions

- `gpu.map(data, expr)` returns the host value directly for the default case.
- `gpu.map(data, expr, { receipt: true })` returns `{ value, receipt }`.
- `.read()` returns a typed array derived from output dtype by default.
- `.read({ as: "array" })` may return a plain JavaScript array for small
  convenience cases.
- `gpu.array([1, 2, 3])` remains a host literal graph node until execution.
- Immediate GPU residency is requested with `.materialize()`, not hidden inside
  `array(...)`.
- Uniforms are passed as typed wrappers in the operation options object; avoid
  duplicated `{ uniforms, values }` declarations.
- Named `zip({ ... })` is part of the prototype because it is clearer than
  positional symbols beyond `x` and `y`.
- Materialized values own GPU resources and require explicit `dispose()`.
- Kernel cache invalidation is hash-based over final WGSL, graph semantics,
  dtype/shape/layout, symbol scope, backend/runtime identity, device
  feature/limit identity, workgroup policy, and fusion plan.
- The minimum receipt schema is the expanded shape above: runtime identity,
  graph nodes, fragment sources and scopes, generated WGSL, dispatches, binding
  layout, buffer allocations, CPU/GPU transfers, sync boundaries, fusion report,
  and cache key.
- Reduction determinism is a per-call option with a graph-level default. The
  default is fast non-deterministic floating order; deterministic reduction is
  opt-in and may fail closed on unsupported backends.
- Matrix helpers stay out of the prototype and should remain under
  `doe-gpu/math` until stable.

## Recommended prototype slice

Prototype behind the experimental `doe-gpu/math` export:

- `wgsl`
- `gpu.array(data, options?)`
- `gpu.map(data, expr, options?)`
- `gpu.f32(value)`, `gpu.i32(value)`, `gpu.u32(value)`
- `.map(expr, options?)`
- `.zip(other, options?)`
- `.zip(namedInputs, options?)`
- `.sum(options?)`
- `.reduce({ init, map, combine }, options?)`
- `.materialize()`
- `.plan()`
- `.compile()`
- `.read(options?)`
- `.receipt()`
- `gpu.kernel(spec)`

Do not include matrix, stencil, broadcasting, strided views, or in-place writes
until the graph receipt and fusion report are solid.
