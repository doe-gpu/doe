# Runtime surface boundary

Doe surfaces do not inherit one another's claims.

| Surface | Owner | Claim boundary |
| --- | --- | --- |
| Public JavaScript package | `packages/doe-gpu/` | Package and declared native-provider behavior only |
| Native runtime and ABI | `runtime/zig/` | Backend- and host-specific runtime evidence |
| Benchmark tooling | `bench/` | Repo-only tooling that may produce public artifacts |
| Browser integration | `browser/chromium/` | Chromium-specific execution and release evidence |
| Compiler and spatial lowering | `runtime/zig/src/compiler/` | Internal until exposed by a promoted runtime contract |

`doe-gpu/browser` wraps the browser's incumbent WebGPU implementation. It is
not Doe replacing the Chromium runtime.

The package export list is owned by `packages/doe-gpu/package.json`. Public and
internal tool classification is owned by `config/tool-surfaces.json`.
Unsupported behavior must be typed; hidden fallback cannot support a promoted
claim.
