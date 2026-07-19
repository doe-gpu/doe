# WGSL compiler support

Quick-reference for doe_wgsl backend and feature status.

## Backend targets

| Backend | Status              | Notes                                              |
|---------|---------------------|----------------------------------------------------|
| MSL     | Native              | Self-contained; no external tools required         |
| SPIR-V  | Native              | Self-contained; no external tools required         |
| HLSL    | Native              | Self-contained; no external tools required         |
| DXIL    | Requires DXC        | Spawns external `dxc`; see `emit_dxil.zig` header  |

## Feature coverage

| Category              | Status              | Notes                                              |
|-----------------------|---------------------|----------------------------------------------------|
| Compute shaders       | Full                | Covers Doppler's full compute feature set          |
| Vertex shaders        | Functional          | Entry-point wiring, struct I/O decomposition, builtin inputs/outputs, inter-stage locations, interpolation decorations, `clip_distances` all work across MSL/HLSL/SPIR-V; render pipeline runtime integration still open |
| Fragment shaders      | Functional          | Entry-point wiring, struct I/O decomposition (MRT), builtin inputs (position, front_facing, sample_index), frag_depth output, `primitive_index`, `blend_src`, discard all work across MSL/HLSL/SPIR-V; render pipeline runtime integration still open |
| Robustness transform  | Functional          | Clamps sized arrays/vectors/matrices, runtime-sized array bases (broadened whitelist: global_ref, member, load, local_ref, param_ref, index, call), and texture coordinates for `textureLoad`/`textureStore` (2D/3D/cube/depth/multisampled/storage); Lean proof-driven clamp elision remains in place for covered storage-buffer patterns, and provably in-range function/private/workgroup sized-array accesses now skip redundant clamps; struct member `arrayLength(&buf.data)` works across MSL/HLSL/SPIR-V |
| Struct types          | Full (flat)         | Nested structs parsed but not exercised in tests   |
| var\<workgroup\>      | Full                | Workgroup-memory allocation emitted correctly      |
| Override constants    | Full                | Emitted as pipeline-overridable specialization     |
| Enable extensions     | Full (f16, subgrp)  | `enable f16` and `enable subgroups` pass through   |
| Helper functions      | Full                | 702+ helpers in Doppler corpus, all passing        |
| Builtins              | Full (compute set)  | subgroup ops, atomics, barriers, 45+ math (fract, mix, inverseSqrt, degrees, radians, atan2, ldexp, fma, smoothstep, etc.), pack/unpack (2x16float, 4x8snorm, 4x8unorm), bitcast, select, arrayLength |
| Texture types         | 2D/3D/cube/array    | texture_2d, texture_3d, texture_cube, texture_depth_cube, texture_2d_array; textureDimensions emitted across MSL/HLSL |
| Texture sampling      | Basic               | `textureSample`, `textureSampleLevel`, `textureDimensions` (including cube/array), plus guarded 2D `textureLoad/store` on the current MSL/HLSL path; broader texture/backend parity is still incomplete |
| Matrix types          | Full                | Parsed, IR-lowered, emitted across MSL (`floatMxN`), HLSL, and SPIR-V (`OpTypeMatrix`); robustness transform clamps column indices |
| Pointer parameters    | Supported (params)  | AST accepts ptr params; direct parameter lowering and call/codegen paths are verified across MSL/HLSL/SPIR-V |
| Suffixed literals     | Full                | `8u`, `2i`, `1.0f`, `3.5h` suffixes parsed and handled in attrs, constants, and expressions |
| Switch statements     | Full                | IR switch/case/default emitted across MSL, HLSL, and SPIR-V |
