# Runtime surface boundary

Doe surfaces are intentionally separate. Do not merge their claims.

## Public package surface

`packages/doe-gpu/` is the npm package surface.

Current package subpath classes:

| Subpath | Class | Boundary |
| --- | --- | --- |
| `doe-gpu` | native runtime package | JS front door over the native Doe runtime |
| `doe-gpu/compute` | native runtime package | narrower compute-oriented public surface |
| `doe-gpu/native` | explicit native provider | direct binding to the Zig-backed provider |
| `doe-gpu/node-webgpu` | repo-adjacent provider bootstrap | explicit Node provider bootstrap for evidence tooling |
| `doe-gpu/api` | provider-neutral helpers | helpers/types, not a runtime replacement claim |
| `doe-gpu/plan` | command/plan contract | JSON execution-plan and shape helpers |
| `doe-gpu/capture` | record-only capture | captures WebGPU behavior into Doe plan contracts |
| `doe-gpu/browser` | browser compatibility shim | wraps incumbent browser `navigator.gpu`; does not run Doe Zig runtime |
| `doe-gpu/hybrid` | compatibility helper | legacy integration helper, not core runtime layer |

There is no public `doe-gpu/csl` subpath.

## Native runtime surface

`doe-zig-runtime` and `libwebgpu_doe` are native runtime/build artifacts used by
package, drop-in, embedded, and benchmark lanes. They are not the npm package
contract by themselves.

## Browser integration surface

`browser/chromium/` is the governed Chromium-family runtime integration lane.
It is separate from `doe-gpu/browser`.

Browser diagnostic artifacts are useful, but browser replacement language must
come from browser-lane compatibility, trace, correctness, and comparability
gates. Package/browser-shim evidence must not be cited as Chromium replacement
evidence.

## Benchmark surface

`bench/` is repo-only operator tooling. It can produce public evidence, but the
tooling itself is not a public product surface unless a manifest marks it
public.

## Compiler/lowering surface

WGSL, TSIR, HostPlan, backend emission, and proof artifacts are compiler/runtime
internals unless exposed through package, native, or evidence contracts.
Unsupported lowering behavior should be typed unsupported behavior, not a hidden
fallback.
