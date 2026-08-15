# CATSCAN: WGSL compiler

Parent: [Compiler](../CATSCAN.md)

## Target

Parse, validate, normalize, and lower the declared WGSL surface into target artifacts with source-linked diagnostics.

## Authority

- Owns WGSL syntax, semantic analysis, typed IR construction, robustness transforms, overrides, and target-emitter dispatch.
- Does not own TSIR planning, runtime command submission, or unsupported-language emulation.

## Scope

- Includes files beneath this directory except child-chartered components, which narrow this authority.

## Contracts

Inputs:
- Supported language boundary: [`WGSL_SUPPORT.md`](WGSL_SUPPORT.md).
- Compiler architecture: [`../../../../../docs/shader-compiler-architecture.md`](../../../../../docs/shader-compiler-architecture.md).

Outputs:
- Validated IR, MSL, SPIR-V, DXIL/HLSL, CSL-path inputs, and typed diagnostics.

## Invariants

- Diagnostic locations and causes remain attributable to original WGSL.
- Robustness and proof-elided transformations preserve declared semantics.
- Missing language or target support fails explicitly.

## Acceptance

- WGSL parser, semantic, emitter, and diagnostic fixtures pass the compiler suite.
- Evidence: [`../../../tests/wgsl`](../../../tests/wgsl).

## Non-goals

- Universal WGSL conformance without published coverage or silent delegation to an incumbent compiler.

## Freedom

Any mechanism is permitted if it preserves these boundaries and passes the acceptance evidence.
