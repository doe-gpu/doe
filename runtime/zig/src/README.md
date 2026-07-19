# Doe Zig source map

Production source is organized by ownership boundary. `mod.zig` is the single
module root; every other Zig file belongs to one owner below.

| Directory | Owns |
| --- | --- |
| `backend/` | Backend selection, common seams, and Metal/Vulkan/D3D12 implementations |
| `cli/` | CLI orchestration and executable entrypoints |
| `command/` | Command-stream parsing and normalization |
| `compat/` | Explicit compatibility barrels retained by compatibility tests |
| `compiler/wgsl/` | WGSL frontend, IR, proofs, runtime compilation, and target emitters |
| `compiler/tsir/` | Tiled spatial IR, planner, reference interpreter, and emitters |
| `compiler/targets/` | Compiler target capability descriptions |
| `contracts/` | Neutral contracts shared by core and full runtime layers |
| `core/` | Compute/resource/queue behavior and the WebGPU ABI core |
| `dropin/` | Drop-in symbol ownership, routing, and behavior policy |
| `experimental/` | Runtime experiments outside promoted behavior |
| `full/` | Rendering, surfaces, and full-runtime commands |
| `integrations/` | Native integration anchors such as ONNX Runtime EP |
| `native/` | Doe-native WebGPU objects, resources, commands, and exports |
| `plan/` | Direct execution-plan contracts and executors |
| `quirk/` | Quirk parsing, matching, and application |
| `runtime/` | Shared execution, caches, devices, queues, diagnostics, and traces |
| `spatial/` | HostPlan and CSL orchestration for spatial targets |
| `tooling/` | I/O contexts shared by command-line tools |
| `verification/` | Runtime consumers of proof artifacts |

WGSL follows a compiler-stage layout:

```text
compiler/wgsl/
  frontend/          tokenization, parsing, semantic analysis
  ir/                typed IR, validation, transforms
  proof/             proof-pattern matching and bounds contracts
  runtime/           runtime compilation and reports
  emit/
    msl/             Apple Metal
    spirv/           Vulkan
    dxil/            native D3D12 bytecode
    hlsl/            HLSL fallback and contracts
    csl/             Cerebras classifier/template path
```

Repository-only Zig benchmarks live in `../bench/`, outside production
`src/`. `source-layout.json` and `tools/check_source_layout.py` enforce this
map, including the exact compatibility-facade set.
