#!/usr/bin/env python3
"""Validate that structural claims in docs are backed by existing files.

Does NOT lint prose for numbers or grep for counts — that approach is fragile.
Instead, validates that things docs claim exist actually exist in the repo.
If someone deletes the DXIL emitter but a doc still claims it exists, CI fails.

Usage:
    python3 pipeline/tools/validate_doc_claims.py [--strict]

Exit code 0 = all claims valid. Non-zero = at least one structural claim is broken.
"""

import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Each entry: (file_that_must_exist, human_label_for_error_message)
# Add entries when a new structural capability is documented.
STRUCTURAL_CLAIMS = [
    # Lean proofs
    ("pipeline/lean/artifacts/proven-conditions.json", "Lean proof artifact"),

    # WGSL compiler backends
    ("runtime/zig/src/compiler/wgsl/emit/msl/emit_msl.zig", "MSL emitter"),
    ("runtime/zig/src/compiler/wgsl/emit/hlsl/emit_hlsl_stage.zig", "HLSL emitter"),
    ("runtime/zig/src/compiler/wgsl/emit/spirv/emit_spirv_stages.zig", "SPIR-V emitter"),
    ("runtime/zig/src/compiler/wgsl/emit/dxil/emit_dxil_native.zig", "native DXIL emitter"),

    # Runtime backends
    ("runtime/zig/src/backend/vulkan/native_runtime.zig", "Vulkan backend"),
    ("runtime/zig/src/backend/d3d12/d3d12_native_runtime.zig", "D3D12 backend"),

    # Chromium integration. The Chromium checkout is external and ignored; its
    # source markers are validated by the dedicated checkout gate.
    ("bench/tools/check_chromium_source_checkout.py", "Chromium source integration gate"),
    ("config/webgpu-integration-chromium.json", "Chromium integration overlay"),
    ("config/doe-chromium-proc-surface.json", "Chromium proc-surface contract"),
    ("config/chromium-patch-manifest.json", "Chromium patch manifest"),

    # Core runtime
    ("runtime/zig/src/native/mod.zig", "Doe WebGPU native runtime"),
    ("runtime/zig/src/verification/lean_proof.zig", "Lean proof comptime validator"),
    ("runtime/zig/src/compiler/wgsl/mod.zig", "WGSL compiler entry point"),

    # Benchmark contracts
    ("bench/workloads/metadata/backend-workload-catalog.json", "benchmark workload catalog"),
    ("config/backend-runtime-policy.json", "backend runtime policy"),

    # GPU timeline (deferred callback infrastructure)
    ("runtime/zig/src/runtime/queue/gpu_timeline.zig", "GPU timeline deferred callbacks"),
]


def validate(strict=False):
    failures = []
    for rel_path, label in STRUCTURAL_CLAIMS:
        full_path = os.path.join(REPO_ROOT, rel_path)
        if not os.path.exists(full_path):
            failures.append((rel_path, label))

    if failures:
        print(f"FAIL: {len(failures)} structural claim(s) broken:\n")
        for path, label in failures:
            print(f"  missing: {path}")
            print(f"  claim:   {label}\n")
        return 1

    print(f"OK: all {len(STRUCTURAL_CLAIMS)} structural claims validated.")
    return 0


if __name__ == "__main__":
    strict = "--strict" in sys.argv
    sys.exit(validate(strict))
