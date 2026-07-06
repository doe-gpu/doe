# GPU math API proposal

## Status

This is a design proposal for an experimental `doe-gpu` math layer. It is not a
shipped package contract, not a replacement for the current low-level compute
surface, and not public performance claim language.

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
import { gpu, wgsl } from "doe-gpu";

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
  return {
    kind: "wgsl",
    source: String.raw({ raw: strings }, ...values),
  };
}
```

String interpolation must not be used for runtime values. Runtime values should
be passed as typed uniforms or buffers:

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

`materialize()` forces a GPU buffer boundary without CPU readback.

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

Open question: whether `mat()` defaults to row-major contiguous layout or
requires an explicit layout argument from the start.

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
  .compile();

console.log(plan.wgsl);
console.log(plan.receipt);

const y = await plan.run().read();
```

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
  .sum()
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
  "status": "ok",
  "inputSummary": {
    "dtype": "f32",
    "shape": [4],
    "inferred": true
  },
  "graph": {
    "nodeCount": 2,
    "nodes": ["array", "map"]
  },
  "fusion": {
    "enabled": true,
    "groups": [["map#1"]],
    "boundaries": ["read"]
  },
  "generated": {
    "wgslSha256": "<sha256>",
    "dispatches": [
      {
        "workgroupSize": 64,
        "workgroups": [1, 1, 1]
      }
    ]
  }
}
```

The concrete schema should be defined before promotion from experimental API to
package contract.

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
| Named zip inputs | maybe | yes | Avoid `z`, `w` symbol sprawl. |
| `sum()` | yes | yes | Determinism policy required. |
| Custom `reduce()` | maybe | yes | Needs clearer receipt policy. |
| `materialize()` | yes | yes | Explicit GPU boundary. |
| `compile()`/inspection | yes | yes | Required for auditability. |
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
determinism policies. Start with array, map, zip, reduction, materialize, read,
compile, and receipt.

## Open questions

- Should `gpu.map(data, expr)` return a plain host value or an object containing
  `{ value, receipt }` when receipt mode is enabled?
- Should `.read()` default to the original typed array class or always return a
  typed array derived from dtype?
- Should `gpu.array([1, 2, 3])` copy immediately to a GPU buffer or remain a
  host literal node until execution?
- How should generated kernels be cached and invalidated?
- What is the minimum receipt schema needed before shipping any API under
  `doe-gpu`?
- Is deterministic reduction a per-call option, a graph-level policy, or a
  runtime configuration?
- Should matrix helpers live in the base `doe-gpu` export or a separate
  `doe-gpu/math` export until stable?

## Recommended prototype slice

Prototype behind an experimental export such as `doe-gpu/math`:

- `wgsl`
- `gpu.array(data, options?)`
- `gpu.map(data, expr, options?)`
- `gpu.f32(value)`, `gpu.i32(value)`, `gpu.u32(value)`
- `.map(expr, options?)`
- `.zip(other, options?)`
- `.sum(options?)`
- `.materialize()`
- `.compile()`
- `.read(options?)`
- `.receipt()`

Do not include matrix, stencil, broadcasting, strided views, or in-place writes
until the graph receipt and fusion report are solid.
