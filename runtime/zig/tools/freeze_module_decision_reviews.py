"""Freeze the completed recomposition module review into source-layout v3."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from source_architecture import analyze, load_manifest


ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = ROOT / "source-layout.json"
REPORT_PATH = ROOT / "reports" / "architecture" / "module-decisions.json"


REVIEWED_SIGNALS: dict[str, str] = {
    "src/backend/vulkan/native_runtime.zig": "Keep: owns Vulkan device/queue runtime lifetime and synchronization; adjacent resource, pipeline, upload, render, and surface capsules already own the separable domains.",
    "src/backend/vulkan/vk_pipeline.zig": "Keep: Vulkan compute-pipeline and descriptor-state lifetime capsule; kernel source resolution and SPIR-V compilation now have a separate owner.",
    "src/backend/vulkan/vk_render.zig": "Keep: cohesive Vulkan render encoding state and commands; native render control remains backend-local by policy.",
    "src/backend/vulkan/vk_resources.zig": "Keep: cohesive Vulkan resource allocation, lookup, and lifetime capsule used across backend command domains.",
    "src/backend/vulkan/vk_upload.zig": "Keep: cohesive Vulkan upload staging and submission policy with backend-native synchronization semantics.",
    "src/backend/vulkan/vulkan_surface.zig": "Keep: platform/FFI-facing Vulkan surface and presentation lifecycle capsule.",
    "src/compiler/tsir/digest.zig": "Keep: canonical TSIR semantic/realization serializer and digest owner; splitting its grammar would create multiple digest authorities.",
    "src/compiler/tsir/emit_kernel_body.zig": "Keep: primary TSIR kernel-body orchestration; independent operation families already live in named sibling modules.",
    "src/compiler/tsir/frontend.zig": "Keep: TSIR frontend orchestration and public entry surface; body, collective, context, and rejection responsibilities already live in named siblings.",
    "src/compiler/tsir/reference_extended_ops.zig": "Keep: independently meaningful CPU oracle algorithms for the extended TSIR operation family.",
    "src/compiler/wgsl/emit/csl/emit_csl_exec_v1.zig": "Keep: versioned CSL execution-contract serializer and validator with an independent schema identity.",
    "src/compiler/wgsl/emit/csl/emit_csl_host_compile_source.zig": "Keep: cohesive CSL host compile-source generation phase.",
    "src/compiler/wgsl/emit/csl/emit_csl_host_runtime.zig": "Keep: cohesive CSL host runtime generation phase.",
    "src/compiler/wgsl/emit/csl/emit_csl_ir_walk.zig": "Keep: cohesive CSL IR traversal/lowering phase shared by target emission.",
    "src/compiler/wgsl/emit/csl/emit_csl_layout.zig": "Keep: authoritative CSL layout calculation and serialization phase.",
    "src/compiler/wgsl/emit/msl/emit_msl_ir.zig": "Keep: MSL target lowering context and IR traversal; builtins, textures, and stage-specific behavior already have named owners.",
    "src/compiler/wgsl/emit/spirv/emit_spirv_builtins.zig": "Keep: authoritative SPIR-V builtin lowering family independent from function and texture lowering.",
    "src/compiler/wgsl/emit/spirv/emit_spirv_fn.zig": "Keep: SPIR-V function/control-flow lowering state machine; builtin, stage, texture, and serialization responsibilities are separate.",
    "src/compiler/wgsl/frontend/parser_expr.zig": "Keep: cohesive recursive-descent expression grammar with an independent parser responsibility.",
    "src/compiler/wgsl/ir/ir_transform_robustness.zig": "Keep: one named WGSL IR robustness transform pass with proof-backed precondition emission.",
    "src/compiler/wgsl/proof/dispatch_proof_match.zig": "Keep: independently meaningful dispatch-proof matching algorithm.",
    "src/compiler/wgsl/proof/dispatch_uniform_bounds.zig": "Keep: independently meaningful uniform-bounds proof algorithm.",
    "src/dropin/dropin_browser_shared_memory.zig": "Keep: browser shared-memory ABI and lifetime capsule; native ownership must remain isolated.",
    "src/native/compute/doe_compute_fast.zig": "Keep: promoted native fast-compute API and execution boundary; Vulkan bindings and backend implementation have separate owners.",
    "src/native/resource/doe_texture_sampler_native.zig": "Keep: cohesive native texture, texture-view, and sampler ABI ownership; the upstream chained swizzle descriptor belongs to texture-view normalization and does not justify a size-only split.",
    "src/native/shader/doe_shader_native.zig": "Keep: native shader-module creation, translation, cache, diagnostics, and object-lifetime boundary.",
    "src/native/vulkan/vulkan_compute_native.zig": "Keep: native WebGPU-to-Vulkan compute command orchestration and lifetime boundary.",
    "src/runtime/trace/trace.zig": "Keep: authoritative trace state, hash-chain, replay, and trace receipt model; format emitters are separate.",
    "src/spatial/csl/csl_host_plan_tool.zig": "Keep: cohesive CSL host-plan tool contract and process-facing validation behavior.",
    "src/dropin/dropin_abi_procs.zig": "Keep: WebGPU ABI proc-table population capsule with 108 declarations; merging would mix ABI table ownership with drop-in object behavior.",
    "src/dropin/wgpu_dropin_ext_a_exports.zig": "Keep: versioned drop-in extension export capsule and C ABI boundary.",
    "src/native/command/doe_immediates_external_native.zig": "Keep: native immediate-data extension ABI boundary with independent validation semantics.",
    "src/native/compute/doe_compute_ext_native.zig": "Keep: native compute extension ABI boundary consumed by the core export surface.",
    "src/native/lifecycle/doe_canvas_event_native.zig": "Keep: canvas-event native lifecycle and callback ABI capsule.",
    "src/native/render/doe_bundle_native.zig": "Keep: render-bundle object lifecycle and command ABI capsule.",
    "src/native/render/doe_render_pass_controls_native.zig": "Keep: render-pass control extension ABI capsule.",
    "src/native/render/doe_render_pipeline_native.zig": "Keep: render-pipeline creation, validation, and object-lifetime capsule.",
    "src/native/shader/doe_shader_compilation_info_native.zig": "Keep: asynchronous shader compilation-info callback ABI and lifetime capsule.",
    "src/native/support/doe_adapter_info_native.zig": "Keep: adapter-info native marshaling and ownership boundary.",
}

NAMED_BOUNDARY_REASONS: dict[str, str] = {
    "src/backend/vulkan/vk_shader_source.zig": "Keep: Vulkan kernel source resolution, WGSL-to-SPIR-V fallback, and owned SPIR-V source cache boundary.",
    "src/compiler/wgsl/runtime/runtime_compile.zig": "Keep: exercised public runtime-translation facade delegating to compute, graphics, and shared metadata owners.",
    "src/compiler/wgsl/runtime/runtime_compute_translation.zig": "Keep: runtime compute lowering policy and MSL/SPIR-V emission boundary shared by native backend consumers.",
    "src/compiler/wgsl/runtime/runtime_graphics_translation.zig": "Keep: graphics-stage SPIR-V emission and stage-interface reflection boundary.",
    "src/compiler/wgsl/runtime/runtime_translation_info.zig": "Keep: shared ownership and construction contract for runtime compute translation metadata.",
}


def _default_reason(module: dict[str, Any]) -> str:
    path = module["path"]
    if path in NAMED_BOUNDARY_REASONS:
        return NAMED_BOUNDARY_REASONS[path]
    if module.get("specialRole"):
        return f"Keep: declared {module['specialRole']} boundary at {path}."
    if module.get("definesMain"):
        return f"Keep: executable process root at {path}."
    if module.get("containsCImport"):
        return f"Keep: isolated C/OS FFI boundary at {path}."
    if module["layer"] == "contracts":
        return f"Keep: reachable neutral contract owner at {path}."
    if module.get("testBlockCount", 0) > 0:
        return f"Keep: reachable {module['owner']} implementation with private behavior tests and no merge, elevation, recomposition, or deletion signal."
    if module.get("fanIn", 0) > 1:
        return f"Keep: reachable {module['owner']} implementation shared by {module['fanIn']} production consumers with no conflicting ownership signal."
    return f"Keep: reachable {module['owner']} implementation with a distinct named responsibility and no merge, elevation, recomposition, or deletion signal."


def freeze(manifest_path: Path, report_path: Path, reviewer: str) -> int:
    config = load_manifest(manifest_path)
    analysis = analyze(ROOT, config)
    blocking_manifest_errors = [
        error
        for error in analysis.manifest_errors
        if not error.startswith("module decision review is stale for ")
        and not error.startswith("module decision review is missing for ")
    ]
    if blocking_manifest_errors or analysis.unresolved_imports:
        raise RuntimeError("source architecture must be valid before review capture")
    report = json.loads(report_path.read_text(encoding="utf-8"))
    report_entries = {entry["path"]: entry for entry in report["entries"]}
    modules = {module["path"]: module for module in analysis.modules}
    if set(report_entries) != set(modules):
        raise RuntimeError("module-decision report does not match the current source graph")
    signaled = {
        path for path, entry in report_entries.items()
        if entry["suggestedDecision"] != "Keep"
    }
    missing_reviews = sorted(signaled - set(REVIEWED_SIGNALS))
    stale_reviews = sorted(set(REVIEWED_SIGNALS) - signaled)
    if missing_reviews or stale_reviews:
        raise RuntimeError(
            f"reviewed signal map mismatch; missing={missing_reviews}, stale={stale_reviews}"
        )
    existing_reviews = config["architecture"].get("moduleDecisionReviews", {})
    reviews = {}
    for path, module in sorted(modules.items()):
        existing_review = existing_reviews.get(path)
        if (
            isinstance(existing_review, dict)
            and existing_review.get("decision") == "Keep"
            and existing_review.get("moduleSha256") == module["sha256"]
        ):
            reviews[path] = existing_review
            continue
        reviews[path] = {
            "decision": "Keep",
            "moduleSha256": module["sha256"],
            "reason": REVIEWED_SIGNALS.get(path, _default_reason(module)),
            "reviewer": reviewer,
        }
    config["architecture"]["moduleDecisionReviews"] = reviews
    manifest_path.write_text(
        json.dumps(config, indent=2, sort_keys=False) + "\n",
        encoding="utf-8",
    )
    return len(reviews)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=MANIFEST_PATH)
    parser.add_argument("--report", type=Path, default=REPORT_PATH)
    parser.add_argument(
        "--reviewer",
        default="codex-recomposition-review/2026-08-08",
    )
    parser.add_argument(
        "--acknowledge-reviewed-candidates",
        action="store_true",
        help="required explicit acknowledgement that REVIEWED_SIGNALS was reviewed",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.acknowledge_reviewed_candidates:
        print("--acknowledge-reviewed-candidates is required", file=sys.stderr)
        return 1
    try:
        count = freeze(args.manifest.resolve(), args.report.resolve(), args.reviewer)
    except (KeyError, OSError, RuntimeError, ValueError) as exc:
        print(f"module decision review capture failed: {exc}", file=sys.stderr)
        return 1
    print(f"captured {count} source-bound module decisions")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
