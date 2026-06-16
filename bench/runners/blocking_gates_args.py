#!/usr/bin/env python3
"""Argument parser for run_blocking_gates.py."""

from __future__ import annotations

import argparse


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--report",
        default="bench/out/dawn-vs-doe.json",
        help="Comparison report produced by the compare lane.",
    )
    parser.add_argument(
        "--timestamp",
        default="",
        help=(
            "UTC suffix for drop-in gate outputs (YYYYMMDDTHHMMSSZ). "
            "Defaults to current UTC time when --timestamp-output is enabled."
        ),
    )
    parser.add_argument(
        "--timestamp-output",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Stamp drop-in gate report paths with a UTC timestamp suffix.",
    )
    parser.add_argument(
        "--gates",
        default="config/gates.json",
        help="Gate policy config path passed to check_correctness.py",
    )
    parser.add_argument(
        "--quirk",
        default="examples/quirks/intel_gen12_temp_buffer.json",
        help="Reference quirk path passed to check_correctness.py",
    )
    parser.add_argument(
        "--with-comparability-parity-gate",
        action="store_true",
        help=(
            "Run comparability_obligation_parity_gate.py as a verification-lane gate "
            "before correctness/trace."
        ),
    )
    parser.add_argument(
        "--with-tracked-ignore-gate",
        action=argparse.BooleanOptionalAction,
        default=True,
        help=(
            "Run check_no_new_tracked_under_gitignore.py before the normal "
            "gate sequence. Default: enabled. The guard scans staged "
            "additions only, so legacy tracked files under ignored paths do "
            "not block unrelated gate runs."
        ),
    )
    parser.add_argument(
        "--with-claim-gate",
        action="store_true",
        help="Run claim_gate.py after schema/correctness/trace gates.",
    )
    parser.add_argument(
        "--with-backend-selection-gate",
        action="store_true",
        help="Run backend_selection_gate.py after trace gate.",
    )
    parser.add_argument(
        "--backend-runtime-policy",
        default="config/backend-runtime-policy.json",
        help="Backend runtime policy path passed to backend_selection_gate.py.",
    )
    parser.add_argument(
        "--backend-selection-lane",
        default="",
        help="Optional lane override passed to backend_selection_gate.py.",
    )
    parser.add_argument(
        "--with-shader-artifact-gate",
        action="store_true",
        help="Run shader_artifact_gate.py after trace gate.",
    )
    parser.add_argument(
        "--with-tint-compiler-evidence-gate",
        action="store_true",
        help="Run tint_compiler_evidence_gate.py for Doe-vs-Tint compiler receipts.",
    )
    parser.add_argument(
        "--shader-artifact-schema",
        default="config/shader-artifact.schema.json",
        help="Shader artifact schema path passed to shader_artifact_gate.py.",
    )
    parser.add_argument(
        "--tint-compiler-evidence-report",
        default="bench/out/tint-compiler-evidence.json",
        help="Doe-vs-Tint compiler evidence report path.",
    )
    parser.add_argument(
        "--tint-compiler-evidence-schema",
        default="config/tint-compiler-evidence.schema.json",
        help="Schema path passed to tint_compiler_evidence_gate.py.",
    )
    parser.add_argument(
        "--tint-compiler-evidence-require-claimable",
        action="store_true",
        help="Require claimable Doe-vs-Tint compiler evidence.",
    )
    parser.add_argument(
        "--shader-artifact-require-manifest",
        action="store_true",
        help="Pass --require-manifest to shader_artifact_gate.py.",
    )
    parser.add_argument(
        "--shader-artifact-spirv-val",
        default="",
        help="Optional spirv-val executable passed to shader_artifact_gate.py.",
    )
    parser.add_argument(
        "--shader-artifact-require-spirv-validation",
        action="store_true",
        help="Fail shader artifact gate when SPIR-V artifacts are present but not validated.",
    )
    parser.add_argument(
        "--with-metal-sync-conformance-gate",
        action="store_true",
        help="Run metal_sync_conformance.py after trace gate.",
    )
    parser.add_argument(
        "--backend-timing-policy",
        default="config/backend-timing-policy.json",
        help="Backend timing policy path passed to sync/timing gates.",
    )
    parser.add_argument(
        "--with-metal-timing-policy-gate",
        action="store_true",
        help="Run metal_timing_policy_gate.py after trace gate.",
    )
    parser.add_argument(
        "--with-vulkan-sync-conformance-gate",
        action="store_true",
        help="Run vulkan_sync_conformance.py after trace gate.",
    )
    parser.add_argument(
        "--with-vulkan-timing-policy-gate",
        action="store_true",
        help="Run vulkan_timing_policy_gate.py after trace gate.",
    )
    parser.add_argument(
        "--with-comparable-runtime-invariants-gate",
        action="store_true",
        help="Run comparable_runtime_invariants_gate.py after trace gate.",
    )
    parser.add_argument(
        "--with-modules",
        action="store_true",
        help="Run promoted module blocking gates after trace gate.",
    )
    parser.add_argument(
        "--with-browser-gate",
        action="store_true",
        help="Run promoted browser gate after trace gate.",
    )
    parser.add_argument(
        "--with-browser-claim-gate",
        action="store_true",
        help="Run the repeated-window browser claim gate after trace gate.",
    )
    parser.add_argument(
        "--with-browser-claim-policy-gate",
        action="store_true",
        help="Run check_browser_claim_policy.py on a browser claim policy.",
    )
    parser.add_argument(
        "--browser-claim-policy",
        default="config/browser-claim-policy.json",
        help="Browser claim policy passed to the standalone policy checker.",
    )
    parser.add_argument(
        "--with-browser-ownership-gate",
        action="store_true",
        help="Run check_browser_ownership.py on the browser ownership manifest.",
    )
    parser.add_argument(
        "--browser-ownership",
        default="config/browser-ownership.json",
        help="Browser ownership manifest passed to the standalone checker.",
    )
    parser.add_argument(
        "--with-comparability-coherence-gate",
        action=argparse.BooleanOptionalAction,
        default=True,
        help=(
            "Run comparability_coherence_gate.py after trace gate. Default: enabled. "
            "Pass --no-with-comparability-coherence-gate only for diagnostic report "
            "audits that are not claim evidence."
        ),
    )
    parser.add_argument(
        "--comparability-coherence-benchmark-policy",
        default="config/benchmark-methodology-thresholds.json",
        help="Benchmark policy path passed to comparability_coherence_gate.py.",
    )
    parser.add_argument(
        "--with-compare-output-partition-gate",
        action=argparse.BooleanOptionalAction,
        default=True,
        help=(
            "Run compare_output_partition_gate.py after trace gate. Default: enabled. "
            "Pass --no-with-compare-output-partition-gate only for non-claim "
            "diagnostic audits that intentionally violate claim/diagnostic partitioning."
        ),
    )
    parser.add_argument(
        "--with-structural-equivalence-gate",
        action=argparse.BooleanOptionalAction,
        default=True,
        help=(
            "Run structural_equivalence_gate.py after trace gate. Default: enabled. "
            "Pass --no-with-structural-equivalence-gate to opt out for diagnostic-only "
            "runs that legitimately fail structural parity (e.g. workloads exercising "
            "Doe-only coverage where Dawn reports unsupported)."
        ),
    )
    parser.add_argument(
        "--with-file-size-gate",
        action="store_true",
        help="Run file_size_gate.py to enforce line-count limits on source files.",
    )
    parser.add_argument(
        "--with-split-coverage-gate",
        action="store_true",
        help="Run split_coverage_gate.py to validate core/full coverage ledgers.",
    )
    parser.add_argument(
        "--split-coverage-surface",
        choices=["core", "full", "both"],
        default="both",
        help="Which surface(s) to validate in the split coverage gate.",
    )
    parser.add_argument(
        "--with-dxil-validate-gate",
        action="store_true",
        help="Run dxil_validate_gate.py to validate DXIL structural correctness.",
    )
    parser.add_argument(
        "--dxil-validate-zig",
        default="zig",
        help="Path to the Zig compiler for DXIL validation gate.",
    )
    parser.add_argument(
        "--dxil-validate-skip-zig-tests",
        action="store_true",
        help="Pass --skip-zig-tests to dxil_validate_gate.py.",
    )
    parser.add_argument(
        "--with-spirv-val-gate",
        action="store_true",
        help="Run spirv_val_gate.py to validate SPIR-V artifacts with spirv-val.",
    )
    parser.add_argument(
        "--with-pilot-evidence-gate",
        action="store_true",
        help="Run pilot_evidence_gate.py to audit registered pilot-evidence receipts + their artifact bundles.",
    )
    parser.add_argument(
        "--with-cross-model-parity-gate",
        action=argparse.BooleanOptionalAction,
        default=True,
        help=(
            "Run aggregate_cross_model_parity.py as a blocking two-model Cerebras "
            "parity gate. Default: enabled."
        ),
    )
    parser.add_argument(
        "--cross-model-parity-out",
        default="bench/out/r3-cross-model-parity/receipt.json",
        help="Receipt path written by aggregate_cross_model_parity.py.",
    )
    parser.add_argument(
        "--spirv-val-require",
        action="store_true",
        help="Fail if spirv-val is not available (default: skip with warning).",
    )
    parser.add_argument(
        "--spirv-val-compile",
        action="store_true",
        help="Compile WGSL kernels to SPIR-V before validation.",
    )
    parser.add_argument(
        "--with-dropin-proc-resolution-gate",
        action="store_true",
        help="Run dropin_proc_resolution_tests.py in the drop-in phase.",
    )
    parser.add_argument(
        "--dropin-symbol-ownership",
        default="config/dropin-symbol-ownership.json",
        help="Drop-in symbol ownership contract for proc-resolution checks.",
    )
    parser.add_argument(
        "--require-claim-gate",
        action="store_true",
        help=(
            "Fail unless --with-claim-gate is set. "
            "Use this when the run is intended as release-claim readiness evidence."
        ),
    )
    parser.add_argument(
        "--with-cts-baseline-gate",
        action="store_true",
        help="Run cts_baseline_compare.py to detect CTS conformance regressions.",
    )
    parser.add_argument(
        "--with-csl-governed-lane-gate",
        action="store_true",
        help="Run csl_governed_lane_gate.py to validate governed CSL compile/run/parity reports.",
    )
    parser.add_argument(
        "--with-csl-simulator-gate",
        action="store_true",
        help="Run csl_simulator_gate.py to validate governed CSL simulator/run receipts.",
    )
    parser.add_argument(
        "--with-sdklayout-streaming-hardening-gate",
        action="store_true",
        help=(
            "Run sdklayout_streaming_hardening_gate.py on explicit SdkLayout "
            "streaming traces."
        ),
    )
    parser.add_argument(
        "--with-wgsl-backend-matrix-gate",
        action="store_true",
        help=(
            "Run wgsl_backend_matrix_gate.py to lock cross-backend parity. "
            "Vulkan/Metal/D3D12 readiness is required unconditionally; the CSL "
            "runtime-ready threshold is enforced only when the Cerebras SDK is "
            "detected (DOE_CSL_SDK_ROOT / DOE_CSLC_EXECUTABLE / cslc on PATH). "
            "Prevents Doe regressions on the shared WGSL emitter path across "
            "SDK-absent dev hosts and SDK-present lane runners."
        ),
    )
    parser.add_argument(
        "--with-browser-release-artifact-bundle-gate",
        action="store_true",
        help="Run check_browser_release_artifact_bundle.py on the browser release bundle.",
    )
    parser.add_argument(
        "--with-browser-claim-promotion-receipt-gate",
        action="store_true",
        help="Run check_browser_claim_promotion_receipt.py on a browser claim promotion receipt.",
    )
    parser.add_argument(
        "--browser-claim-promotion-receipt",
        default="examples/browser-claim-promotion-receipt.sample.json",
        help="Browser claim promotion receipt passed to the receipt checker.",
    )
    parser.add_argument(
        "--browser-claim-promotion-receipt-verify-files-root",
        default="",
        help="Optional file root forwarded to the browser claim promotion receipt checker.",
    )
    parser.add_argument(
        "--browser-release-artifact-bundle",
        default="examples/browser-release-artifact-bundle.sample.json",
        help="Browser release artifact bundle passed to the bundle checker.",
    )
    parser.add_argument(
        "--browser-release-artifact-bundle-verify-files-root",
        default="",
        help="Optional file root forwarded to the browser release bundle checker.",
    )
    parser.add_argument(
        "--with-wgsl-lowering-link-receipt-gate",
        action="store_true",
        help="Run check_wgsl_lowering_link_receipt.py on a lowering link receipt.",
    )
    parser.add_argument(
        "--wgsl-lowering-link-receipt",
        default="examples/wgsl-lowering-link-receipt.sample.json",
        help="WGSL lowering link receipt passed to the receipt checker.",
    )
    parser.add_argument(
        "--wgsl-lowering-link-verify-files-root",
        default="",
        help="Optional file root forwarded to the WGSL lowering link checker.",
    )
    parser.add_argument(
        "--with-wgsl-minimization-receipt-gate",
        action="store_true",
        help="Run check_wgsl_minimization_receipt.py on a minimization receipt.",
    )
    parser.add_argument(
        "--wgsl-minimization-receipt",
        default="examples/wgsl-minimization-receipt.sample.json",
        help="WGSL minimization receipt passed to the receipt checker.",
    )
    parser.add_argument(
        "--wgsl-minimization-verify-files-root",
        default="",
        help="Optional file root forwarded to the WGSL minimization receipt checker.",
    )
    parser.add_argument(
        "--with-wgsl-cts-shader-subset-gate",
        action="store_true",
        help="Run check_wgsl_cts_shader_subset.py on a CTS shader subset artifact.",
    )
    parser.add_argument(
        "--wgsl-cts-shader-subset",
        default="examples/wgsl-cts-shader-subset.sample.json",
        help="WGSL CTS shader subset passed to the subset checker.",
    )
    parser.add_argument(
        "--with-wgsl-corpus-materialization-gate",
        action="store_true",
        help="Run check_wgsl_corpus_materialization.py on a materialization receipt.",
    )
    parser.add_argument(
        "--wgsl-corpus-materialization-receipt",
        default="examples/wgsl-corpus-materialization.sample.json",
        help="WGSL corpus materialization receipt passed to the materialization checker.",
    )
    parser.add_argument(
        "--wgsl-corpus-materialization-verify-files-root",
        default="",
        help="Optional file root forwarded to the WGSL materialization checker.",
    )
    parser.add_argument(
        "--with-native-command-graph-replay-gate",
        action="store_true",
        help="Run replay_native_command_graph_receipt.py on a native command graph receipt.",
    )
    parser.add_argument(
        "--native-command-graph-receipt",
        default="examples/native-command-graph-receipt.sample.json",
        help="Native command graph receipt passed to the replay checker.",
    )
    parser.add_argument(
        "--native-command-graph-verify-files-root",
        default="",
        help="Optional file root forwarded to the native command graph replay checker.",
    )
    parser.add_argument(
        "--with-native-no-fallback-gate",
        action="store_true",
        help="Run check_native_no_fallback_report.py on a strict native no-fallback report.",
    )
    parser.add_argument(
        "--native-no-fallback-report",
        default="examples/native-no-fallback-report.sample.json",
        help="Native no-fallback report passed to the report checker.",
    )
    parser.add_argument(
        "--native-no-fallback-verify-files-root",
        default="",
        help="Optional file root forwarded to the native no-fallback checker.",
    )
    parser.add_argument(
        "--with-native-backend-coverage-matrix-gate",
        action="store_true",
        help="Run check_native_backend_coverage_matrix.py on the native backend coverage matrix.",
    )
    parser.add_argument(
        "--native-backend-coverage-matrix",
        default="config/native-backend-coverage-matrix.json",
        help="Native backend coverage matrix passed to the matrix checker.",
    )
    parser.add_argument(
        "--native-backend-coverage-evidence-root",
        default="",
        help="Optional evidence root forwarded to the native backend coverage matrix checker.",
    )
    parser.add_argument(
        "--with-browser-capture-policy-gate",
        action="store_true",
        help="Run check_browser_capture_policy.py on the browser capture policy.",
    )
    parser.add_argument(
        "--browser-capture-policy",
        default="config/browser-capture-policy.json",
        help="Browser capture policy passed to the capture-policy checker.",
    )
    parser.add_argument(
        "--with-browser-artifact-identity-coverage-gate",
        action="store_true",
        help="Run check_browser_artifact_identity_coverage.py on browser identity anchors.",
    )
    parser.add_argument(
        "--browser-artifact-identity-coverage",
        default="config/browser-artifact-identity-coverage.json",
        help="Browser artifact identity coverage manifest passed to the checker.",
    )
    parser.add_argument(
        "--browser-artifact-identity-coverage-root",
        default=".",
        help="Repository root forwarded to the browser artifact identity coverage checker.",
    )
    parser.add_argument(
        "--with-browser-unsupported-reason-taxonomy-gate",
        action="store_true",
        help="Run check_browser_unsupported_reason_taxonomy.py on browser reason codes.",
    )
    parser.add_argument(
        "--browser-unsupported-reason-taxonomy",
        default="config/browser-unsupported-reason-taxonomy.json",
        help="Browser unsupported reason taxonomy passed to the checker.",
    )
    parser.add_argument(
        "--with-evidence-blocker-taxonomy-gate",
        action="store_true",
        help="Run evidence_blocker_taxonomy_gate.py on shared evidence blocker codes.",
    )
    parser.add_argument(
        "--evidence-blocker-taxonomy",
        default="config/evidence-blocker-taxonomy.json",
        help="Evidence blocker taxonomy passed to the checker.",
    )
    parser.add_argument(
        "--evidence-blocker-taxonomy-schema",
        default="config/evidence-blocker-taxonomy.schema.json",
        help="Evidence blocker taxonomy schema passed to the checker.",
    )
    parser.add_argument(
        "--evidence-blocker-model-runtime-schema",
        default="config/doe-model-runtime-receipt.schema.json",
        help="Model runtime receipt schema checked against the evidence blocker taxonomy.",
    )
    parser.add_argument(
        "--with-browser-responsibility-map-gate",
        action="store_true",
        help="Run check_browser_responsibility_map.py on the browser responsibility map.",
    )
    parser.add_argument(
        "--browser-responsibility-map",
        default="config/browser-responsibility-map.json",
        help="Browser responsibility map passed to the responsibility-map checker.",
    )
    parser.add_argument(
        "--browser-responsibility-map-root",
        default=".",
        help="Repository root forwarded to the browser responsibility-map checker.",
    )
    parser.add_argument(
        "--with-chromium-fork-maintenance-policy-gate",
        action="store_true",
        help="Run check_chromium_fork_maintenance_policy.py on the Chromium fork policy.",
    )
    parser.add_argument(
        "--chromium-fork-maintenance-policy",
        default="config/chromium-fork-maintenance-policy.json",
        help="Chromium fork maintenance policy passed to the fork-policy checker.",
    )
    parser.add_argument(
        "--with-chromium-patch-manifest-gate",
        action="store_true",
        help="Run check_chromium_patch_manifest.py on the Chromium patch manifest.",
    )
    parser.add_argument(
        "--chromium-patch-manifest",
        default="config/chromium-patch-manifest.json",
        help="Chromium patch manifest passed to the patch-manifest checker.",
    )
    parser.add_argument(
        "--chromium-patch-manifest-root",
        default=".",
        help="Repository root forwarded to the Chromium patch-manifest checker.",
    )
    parser.add_argument(
        "--with-chromium-source-checkout-gate",
        action="store_true",
        help="Run check_chromium_source_checkout.py with source readiness required.",
    )
    parser.add_argument(
        "--chromium-source-root",
        default="browser/chromium/src",
        help="Chromium source checkout root passed to the source-checkout checker.",
    )
    parser.add_argument(
        "--chromium-source-checkout-root",
        default=".",
        help="Repository root forwarded to the Chromium source-checkout checker.",
    )
    parser.add_argument(
        "--chromium-source-require-runtime-selector",
        action="store_true",
        help="Require source markers for Chromium's fail-closed Doe runtime selector seam.",
    )
    parser.add_argument(
        "--with-doe-chromium-proc-surface-gate",
        action="store_true",
        help="Run check_doe_chromium_proc_surface.py on the Doe WebGPU dylib.",
    )
    parser.add_argument(
        "--doe-chromium-proc-surface",
        default="config/doe-chromium-proc-surface.json",
        help="Doe Chromium proc-surface config passed to the checker.",
    )
    parser.add_argument(
        "--doe-chromium-proc-surface-library",
        default="",
        help="Optional Doe WebGPU library override passed to the proc-surface checker.",
    )
    parser.add_argument(
        "--with-webgpu-integration-chromium-gate",
        action="store_true",
        help="Run check_webgpu_integration_chromium.py on the Chromium integration overlay.",
    )
    parser.add_argument(
        "--webgpu-integration-chromium",
        default="config/webgpu-integration-chromium.json",
        help="Chromium WebGPU integration overlay passed to the checker.",
    )
    parser.add_argument(
        "--webgpu-integration-chromium-verify-artifact-root",
        default=".",
        help="Optional root forwarded to the Chromium integration overlay checker.",
    )
    parser.add_argument(
        "--with-browser-runtime-selector-policy-gate",
        action="store_true",
        help="Run check-browser-runtime-selector-policy.py on the browser runtime selector policy.",
    )
    parser.add_argument(
        "--browser-runtime-selector-policy",
        default="config/browser-runtime-selector-policy.json",
        help="Browser runtime selector policy passed to the selector-policy checker.",
    )
    parser.add_argument(
        "--with-browser-runtime-identity-gate",
        action="store_true",
        help="Run check-browser-runtime-identity.py on a browser runtime identity artifact.",
    )
    parser.add_argument(
        "--browser-runtime-identity",
        default="examples/browser-runtime-identity.sample.json",
        help="Browser runtime identity artifact passed to the identity checker.",
    )
    parser.add_argument(
        "--with-browser-promotion-approvals-gate",
        action="store_true",
        help="Run check-browser-promotion-approvals.py on browser promotion approvals.",
    )
    parser.add_argument(
        "--browser-promotion-approvals",
        default="browser/chromium/bench/workflows/browser-promotion-approvals.json",
        help="Browser promotion approvals passed to the standalone checker.",
    )
    parser.add_argument(
        "--browser-promotion-approvals-workflows",
        default="browser/chromium/bench/workflows/browser-workflow-manifest.json",
        help="Browser workflow manifest used for promotion approval coverage checks.",
    )
    parser.add_argument(
        "--with-browser-workflow-manifest-gate",
        action="store_true",
        help="Run check-browser-workflow-manifest.py on the browser workflow manifest.",
    )
    parser.add_argument(
        "--browser-workflow-manifest",
        default="browser/chromium/bench/workflows/browser-workflow-manifest.json",
        help="Browser workflow manifest passed to the standalone checker.",
    )
    parser.add_argument(
        "--with-browser-milestones-gate",
        action="store_true",
        help="Run check-browser-milestones.py on the browser milestone manifest.",
    )
    parser.add_argument(
        "--browser-milestones",
        default="browser/chromium/bench/workflows/browser-milestones.json",
        help="Browser milestone manifest passed to the milestone checker.",
    )
    parser.add_argument(
        "--with-browser-smoke-report-gate",
        action="store_true",
        help="Run check-browser-smoke-report.py on a Chromium WebGPU smoke report.",
    )
    parser.add_argument(
        "--browser-smoke-report",
        default="examples/browser-smoke-report.sample.json",
        help="Chromium WebGPU smoke report passed to the checker.",
    )
    parser.add_argument(
        "--browser-smoke-report-require-modes",
        default="dawn,doe",
        help="Comma-separated smoke modes required by the browser smoke report checker.",
    )
    parser.add_argument(
        "--with-browser-benchmark-superset-gate",
        action="store_true",
        help="Run check-browser-benchmark-superset.py on the browser projection/workflow contract.",
    )
    parser.add_argument(
        "--browser-benchmark-superset-report",
        default="",
        help="Optional layered report forwarded to the browser benchmark superset checker.",
    )
    parser.add_argument(
        "--browser-benchmark-superset-require-modes",
        default="",
        help="Optional comma-separated runtime modes required by the browser benchmark superset checker.",
    )
    parser.add_argument(
        "--browser-benchmark-superset-require-promotion-approvals",
        action="store_true",
        help="Forward --require-promotion-approvals to the browser benchmark superset checker.",
    )
    parser.add_argument(
        "--with-browser-canvas-webgpu-fusion-gate",
        action="store_true",
        help="Run check-browser-canvas-webgpu-fusion.py on a fusion probe artifact.",
    )
    parser.add_argument(
        "--browser-canvas-webgpu-fusion-probe",
        default="examples/browser-canvas-webgpu-fusion.sample.json",
        help="Browser canvas/WebGPU fusion probe passed to the checker.",
    )
    parser.add_argument(
        "--browser-derived-runtime-identity-root",
        default=".",
        help="Repository root forwarded to derived browser artifact runtime identity reference checks.",
    )
    parser.add_argument(
        "--with-browser-cts-subset-gate",
        action="store_true",
        help="Run check-browser-cts-subset.py on a browser CTS subset artifact.",
    )
    parser.add_argument(
        "--browser-cts-subset",
        default="examples/browser-cts-subset.sample.json",
        help="Browser CTS subset artifact passed to the checker.",
    )
    parser.add_argument(
        "--with-browser-fallback-explanations-gate",
        action="store_true",
        help="Run check-browser-fallback-explanations.py on fallback explanations.",
    )
    parser.add_argument(
        "--browser-fallback-explanations",
        default="examples/browser-fallback-explanations.sample.json",
        help="Browser fallback explanations artifact passed to the checker.",
    )
    parser.add_argument(
        "--browser-fallback-explanations-taxonomy-root",
        default=".",
        help="Repository root forwarded to the browser fallback explanations checker.",
    )
    parser.add_argument(
        "--with-browser-gpu-scheduler-gate",
        action="store_true",
        help="Run check-browser-gpu-scheduler.py on a scheduler probe artifact.",
    )
    parser.add_argument(
        "--browser-gpu-scheduler-probe",
        default="examples/browser-gpu-scheduler.sample.json",
        help="Browser GPU scheduler probe passed to the checker.",
    )
    parser.add_argument(
        "--with-browser-gpu-flight-recorder-replay-gate",
        action="store_true",
        help="Run replay-browser-gpu-flight-recorder.py on a browser GPU flight recorder artifact.",
    )
    parser.add_argument(
        "--browser-gpu-flight-recorder",
        default="examples/browser-gpu-flight-recorder.sample.json",
        help="Browser GPU flight recorder artifact passed to the replay checker.",
    )
    parser.add_argument(
        "--browser-gpu-flight-recorder-capture-policy",
        default="config/browser-capture-policy.json",
        help="Browser capture policy passed to the flight-recorder replay checker.",
    )
    parser.add_argument(
        "--browser-gpu-flight-recorder-responsibility-map-root",
        default=".",
        help="Repository root forwarded to the flight-recorder responsibility map reference check.",
    )
    parser.add_argument(
        "--browser-gpu-flight-replay-out",
        default="",
        help="Optional browser GPU flight replay report path.",
    )
    parser.add_argument(
        "--with-browser-local-ai-workloads-gate",
        action="store_true",
        help="Run check-browser-local-ai-workloads.py on local AI workload receipts.",
    )
    parser.add_argument(
        "--browser-local-ai-workloads",
        default="examples/browser-local-ai-workloads.sample.json",
        help="Browser local AI workload artifact passed to the checker.",
    )
    parser.add_argument(
        "--with-browser-media-path-probe-gate",
        action="store_true",
        help="Run check-browser-media-path-probe.py on a media path probe artifact.",
    )
    parser.add_argument(
        "--browser-media-path-probe",
        default="examples/browser-media-path-probe.sample.json",
        help="Browser media path probe passed to the checker.",
    )
    parser.add_argument(
        "--browser-media-path-probe-capture-policy-root",
        default=".",
        help="Repository root forwarded to the browser media-path probe checker.",
    )
    parser.add_argument(
        "--with-browser-pipeline-cache-receipts-gate",
        action="store_true",
        help="Run check-browser-pipeline-cache-receipts.py on browser cache receipts.",
    )
    parser.add_argument(
        "--browser-pipeline-cache-receipts",
        default="examples/browser-pipeline-cache-receipts.sample.json",
        help="Browser pipeline cache receipts passed to the checker.",
    )
    parser.add_argument(
        "--browser-pipeline-cache-receipts-verify-workloads-root",
        default=".",
        help="Repository root forwarded to the browser pipeline-cache receipt checker.",
    )
    parser.add_argument(
        "--with-browser-recovery-parity-gate",
        action="store_true",
        help="Run check-browser-recovery-parity.py on browser recovery parity evidence.",
    )
    parser.add_argument(
        "--browser-recovery-parity",
        default="examples/browser-recovery-parity.sample.json",
        help="Browser recovery parity artifact passed to the checker.",
    )
    parser.add_argument(
        "--with-browser-shader-links-gate",
        action="store_true",
        help="Run check-browser-shader-links.py on browser shader links.",
    )
    parser.add_argument(
        "--browser-shader-links",
        default="examples/browser-shader-links.sample.json",
        help="Browser shader links artifact passed to the checker.",
    )
    parser.add_argument(
        "--browser-shader-links-verify-lowering-root",
        default="",
        help="Optional root forwarded to browser shader-links lowering receipt verification.",
    )
    parser.add_argument(
        "--browser-shader-links-verify-flight-recorder-root",
        default=".",
        help="Repository root forwarded to browser shader-links flight-recorder verification.",
    )
    parser.add_argument(
        "--with-browser-webgpu-effect-experiment-gate",
        action="store_true",
        help="Run check-browser-webgpu-effect-experiment.py on effect experiment evidence.",
    )
    parser.add_argument(
        "--browser-webgpu-effect-experiment",
        default="examples/browser-webgpu-effect-experiment.sample.json",
        help="Browser WebGPU effect experiment artifact passed to the checker.",
    )
    parser.add_argument(
        "--with-native-pipeline-cache-receipts-gate",
        action="store_true",
        help="Run check_native_pipeline_cache_receipts.py on native cache receipts.",
    )
    parser.add_argument(
        "--native-pipeline-cache-receipts",
        default="examples/native-pipeline-cache-receipts.sample.json",
        help="Native pipeline cache receipts passed to the checker.",
    )
    parser.add_argument(
        "--with-native-resource-reuse-receipts-gate",
        action="store_true",
        help="Run check_native_resource_reuse_receipts.py on native reuse receipts.",
    )
    parser.add_argument(
        "--native-resource-reuse-receipts",
        default="examples/native-resource-reuse-receipts.sample.json",
        help="Native resource reuse receipts passed to the checker.",
    )
    parser.add_argument(
        "--with-native-upload-path-receipts-gate",
        action="store_true",
        help="Run check_native_upload_path_receipts.py on native upload receipts.",
    )
    parser.add_argument(
        "--native-upload-path-receipts",
        default="examples/native-upload-path-receipts.sample.json",
        help="Native upload path receipts passed to the checker.",
    )
    parser.add_argument(
        "--with-wgsl-diagnostic-fixtures-gate",
        action="store_true",
        help="Run check_wgsl_diagnostic_fixtures.py on invalid-shader fixtures.",
    )
    parser.add_argument(
        "--wgsl-diagnostic-fixtures",
        default="config/wgsl-diagnostic-fixtures.json",
        help="WGSL diagnostic fixtures passed to the checker.",
    )
    parser.add_argument(
        "--wgsl-diagnostic-fixtures-manifest",
        default="config/wgsl-browser-corpus.json",
        help="WGSL corpus manifest passed to the diagnostic fixture checker.",
    )
    parser.add_argument(
        "--wgsl-diagnostic-fixtures-taxonomy",
        default="config/shader-error-taxonomy.json",
        help="Shader error taxonomy passed to the diagnostic fixture checker.",
    )
    parser.add_argument(
        "--with-wgsl-robustness-fixtures-gate",
        action="store_true",
        help="Run check_wgsl_robustness_fixtures.py on robustness fixtures.",
    )
    parser.add_argument(
        "--wgsl-robustness-fixtures",
        default="config/wgsl-robustness-fixtures.json",
        help="WGSL robustness fixtures passed to the checker.",
    )
    parser.add_argument(
        "--with-model-runtime-receipt",
        action="append",
        default=[],
        help=(
            "Run model_runtime_receipt_gate.py on the given doe_model_runtime_receipt "
            "JSON. Repeatable — one invocation per model. Each receipt is gated with "
            "--require-fits --require-structural-full-coverage "
            "--min-kernel-coverage-pct 100 --min-chain-parity-patterns "
            "(--model-runtime-receipt-min-chain-parity, default 0)."
        ),
    )
    parser.add_argument(
        "--model-runtime-receipt-min-chain-parity",
        type=int,
        default=0,
        help="Chain-parity coverage floor applied to every --with-model-runtime-receipt receipt.",
    )
    parser.add_argument(
        "--with-kernel-chain-parity",
        action="append",
        default=[],
        help=(
            "Run kernel_chain_parity_gate.py on the given doe_kernel_chain_parity "
            "JSON. Repeatable — one invocation per chain receipt. Each receipt "
            "gated with --require-bit-close; tighten to --require-bit-exact via "
            "--kernel-chain-parity-bit-exact."
        ),
    )
    parser.add_argument(
        "--kernel-chain-parity-bit-exact",
        action="store_true",
        help="Upgrade --with-kernel-chain-parity from --require-bit-close to --require-bit-exact.",
    )
    parser.add_argument(
        "--wgsl-backend-matrix-report",
        default="bench/out/cross-backend-matrix/wgsl-backend-matrix.json",
    )
    parser.add_argument(
        "--wgsl-backend-matrix-schema",
        default="config/wgsl-backend-matrix-report.schema.json",
    )
    parser.add_argument(
        "--wgsl-backend-matrix-min-csl-runtime-ready",
        type=int,
        default=0,
        help="Enforced only when the Cerebras SDK is detected locally.",
    )
    parser.add_argument(
        "--csl-governed-report",
        default="bench/out/csl-governed-lane.report.json",
        help="Governed CSL lane report path passed to csl_governed_lane_gate.py.",
    )
    parser.add_argument(
        "--csl-governed-schema",
        default="config/csl-governed-lane-report.schema.json",
        help="Governed CSL lane schema path passed to csl_governed_lane_gate.py.",
    )
    parser.add_argument(
        "--csl-governed-require-compile-success",
        action="store_true",
        help="Require compile.status=succeeded in the CSL governed lane gate.",
    )
    parser.add_argument(
        "--csl-governed-require-run-success",
        action="store_true",
        help="Require run.status=succeeded in the CSL governed lane gate.",
    )
    parser.add_argument(
        "--csl-simulator-report",
        default="bench/out/csl-governed-lane.report.json",
        help="Governed CSL lane report path passed to csl_simulator_gate.py.",
    )
    parser.add_argument(
        "--csl-simulator-report-schema",
        default="config/csl-governed-lane-report.schema.json",
        help="Governed CSL lane schema path passed to csl_simulator_gate.py.",
    )
    parser.add_argument(
        "--csl-simulator-require-ready",
        action="store_true",
        help="Require laneStatus=ready in csl_simulator_gate.py.",
    )
    parser.add_argument(
        "--sdklayout-streaming-hardening-trace",
        action="append",
        default=[],
        help=(
            "SdkLayout streaming trace passed to "
            "sdklayout_streaming_hardening_gate.py. Repeatable and required "
            "when --with-sdklayout-streaming-hardening-gate is set."
        ),
    )
    parser.add_argument(
        "--sdklayout-streaming-hardening-fail-on-overalloc",
        action="store_true",
        help=(
            "Forward --fail-on-overalloc to "
            "sdklayout_streaming_hardening_gate.py."
        ),
    )
    parser.add_argument(
        "--cts-baseline-snapshot",
        default="",
        help="Path to the baseline CTS snapshot JSON for regression comparison.",
    )
    parser.add_argument(
        "--cts-baseline-current",
        default="",
        help="Path to the current CTS snapshot JSON. When omitted, latest in bench/out/cts-baseline/ is used.",
    )
    parser.add_argument(
        "--cts-baseline-policy",
        default="config/cts-baseline-policy.json",
        help="CTS baseline policy config path.",
    )
    parser.add_argument(
        "--trace-semantic-parity-mode",
        choices=["off", "auto", "required"],
        default="auto",
        help="Semantic parity mode passed to trace_gate.py.",
    )
    parser.add_argument(
        "--with-dropin-gate",
        action="store_true",
        help="Run dropin_gate.py after schema/correctness/trace gates.",
    )
    parser.add_argument(
        "--dropin-artifact",
        default="runtime/zig/zig-out/lib/libwebgpu_doe.so",
        help="Shared library artifact path passed to dropin_gate.py when --with-dropin-gate is set.",
    )
    parser.add_argument(
        "--dropin-symbols",
        default="config/dropin_abi.symbols.txt",
        help="Required symbol list passed to dropin_gate.py.",
    )
    parser.add_argument(
        "--dropin-report",
        default="bench/out/dropin_report.json",
        help="Top-level drop-in report path passed to dropin_gate.py.",
    )
    parser.add_argument(
        "--dropin-symbol-report",
        default="bench/out/dropin_symbol_report.json",
        help="Drop-in symbol report path passed to dropin_gate.py.",
    )
    parser.add_argument(
        "--dropin-behavior-report",
        default="bench/out/dropin_behavior_report.json",
        help="Drop-in behavior report path passed to dropin_gate.py.",
    )
    parser.add_argument(
        "--dropin-benchmark-report",
        default="bench/out/dropin_benchmark_report.json",
        help="Drop-in benchmark report path passed to dropin_gate.py.",
    )
    parser.add_argument(
        "--dropin-benchmark-html",
        default="bench/out/dropin_benchmark_report.html",
        help="Drop-in benchmark HTML path passed to dropin_gate.py.",
    )
    parser.add_argument(
        "--dropin-micro-iterations",
        type=int,
        default=30,
        help="Micro benchmark iteration count passed to dropin_gate.py.",
    )
    parser.add_argument(
        "--dropin-e2e-iterations",
        type=int,
        default=10,
        help="End-to-end benchmark iteration count passed to dropin_gate.py.",
    )
    parser.add_argument(
        "--dropin-skip-benchmarks",
        action="store_true",
        help="Pass --skip-benchmarks to dropin_gate.py.",
    )
    parser.add_argument(
        "--claim-require-comparison-status",
        default="comparable",
        help="Required top-level comparisonStatus when --with-claim-gate is set.",
    )
    parser.add_argument(
        "--claim-require-claim-status",
        default="claimable",
        help="Required top-level claimStatus when --with-claim-gate is set.",
    )
    parser.add_argument(
        "--claim-require-claimability-mode",
        default="release",
        help="Required claimPolicy.mode when --with-claim-gate is set.",
    )
    parser.add_argument(
        "--claim-require-min-timed-samples",
        type=int,
        default=15,
        help="Required claimPolicy.minTimedSamples lower bound when --with-claim-gate is set.",
    )
    parser.add_argument(
        "--claim-config",
        default="",
        help="Optional compare config forwarded to `bench/cli.py claim` before claim gate evaluation.",
    )
    parser.add_argument(
        "--claim-benchmark-policy",
        default="config/benchmark-methodology-thresholds.json",
        help="Benchmark policy path forwarded to `bench/cli.py claim`.",
    )
    parser.add_argument(
        "--claim-expected-workload-contract",
        default="",
        help=(
            "Optional workload contract path forwarded to claim_gate.py "
            "for workload hash/ID-set checks."
        ),
    )
    parser.add_argument(
        "--claim-require-workload-contract-hash",
        action="store_true",
        help="Forward --require-workload-contract-hash to claim_gate.py.",
    )
    parser.add_argument(
        "--claim-require-workload-id-set-match",
        action="store_true",
        help="Forward --require-workload-id-set-match to claim_gate.py.",
    )
    parser.add_argument(
        "--claim-require-backend-telemetry",
        action="store_true",
        help="Forward --require-backend-telemetry to claim_gate.py.",
    )
    parser.add_argument(
        "--claim-expected-backend-id",
        default="",
        help="Forward --expected-backend-id to claim_gate.py.",
    )
    return parser.parse_args()

