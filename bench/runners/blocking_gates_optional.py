#!/usr/bin/env python3
"""Optional artifact and receipt gates for run_blocking_gates.py."""

from __future__ import annotations

from collections.abc import Callable
from pathlib import Path
import sys


def run_optional_artifact_gates(
    args,
    *,
    repo_root: Path,
    bench_root: Path,
    run_gate: Callable[[str, list[str]], None],
) -> int:
    gates_dir = bench_root / "gates"
    tools_dir = bench_root / "tools"
    browser_dir = bench_root / "browser"
    browser_scripts_dir = repo_root / "browser" / "chromium" / "scripts"

    browser_gate = browser_dir / "browser_gate.py"
    browser_claim_gate = browser_dir / "browser_claim_gate.py"
    browser_claim_policy_check = tools_dir / "check_browser_claim_policy.py"
    browser_ownership_check = tools_dir / "check_browser_ownership.py"
    module_gate = gates_dir / "module_gate.py"
    model_runtime_receipt_gate = gates_dir / "model_runtime_receipt_gate.py"
    kernel_chain_parity_gate = gates_dir / "kernel_chain_parity_gate.py"
    browser_claim_promotion_receipt_check = (
        tools_dir / "check_browser_claim_promotion_receipt.py"
    )
    browser_release_candidate_provenance_check = (
        tools_dir / "check_browser_release_candidate_provenance.py"
    )
    browser_published_proof_surface_check = (
        tools_dir / "check_browser_published_proof_surface.py"
    )
    browser_release_candidate_finalizer_check = (
        tools_dir / "check_browser_release_candidate_finalizer.py"
    )
    browser_release_package_inputs_check = (
        tools_dir / "check_browser_release_package_inputs.py"
    )
    browser_release_artifact_bundle_check = (
        tools_dir / "check_browser_release_artifact_bundle.py"
    )
    browser_runtime_frontier_bundle_check = (
        tools_dir / "check_browser_runtime_frontier_bundle.py"
    )
    wgsl_lowering_link_receipt_check = tools_dir / "check_wgsl_lowering_link_receipt.py"
    wgsl_minimization_receipt_check = tools_dir / "check_wgsl_minimization_receipt.py"
    wgsl_cts_shader_subset_check = tools_dir / "check_wgsl_cts_shader_subset.py"
    wgsl_corpus_materialization_check = (
        tools_dir / "check_wgsl_corpus_materialization.py"
    )
    native_command_graph_replay = tools_dir / "replay_native_command_graph_receipt.py"
    native_no_fallback_report_check = tools_dir / "check_native_no_fallback_report.py"
    native_backend_coverage_matrix_check = (
        tools_dir / "check_native_backend_coverage_matrix.py"
    )
    browser_capture_policy_check = tools_dir / "check_browser_capture_policy.py"
    browser_artifact_identity_coverage_check = (
        tools_dir / "check_browser_artifact_identity_coverage.py"
    )
    browser_unsupported_reason_taxonomy_check = (
        tools_dir / "check_browser_unsupported_reason_taxonomy.py"
    )
    evidence_blocker_taxonomy_gate = gates_dir / "evidence_blocker_taxonomy_gate.py"
    browser_responsibility_map_check = tools_dir / "check_browser_responsibility_map.py"
    chromium_fork_maintenance_policy_check = (
        tools_dir / "check_chromium_fork_maintenance_policy.py"
    )
    chromium_patch_manifest_check = tools_dir / "check_chromium_patch_manifest.py"
    chromium_source_checkout_check = tools_dir / "check_chromium_source_checkout.py"
    doe_chromium_proc_surface_check = tools_dir / "check_doe_chromium_proc_surface.py"
    webgpu_integration_chromium_check = (
        tools_dir / "check_webgpu_integration_chromium.py"
    )
    browser_runtime_selector_policy_check = (
        browser_scripts_dir / "check-browser-runtime-selector-policy.py"
    )
    browser_runtime_identity_check = browser_scripts_dir / "check-browser-runtime-identity.py"
    browser_promotion_approvals_check = (
        browser_scripts_dir / "check-browser-promotion-approvals.py"
    )
    browser_workflow_manifest_check = (
        browser_scripts_dir / "check-browser-workflow-manifest.py"
    )
    browser_milestones_check = browser_scripts_dir / "check-browser-milestones.py"
    browser_smoke_report_check = browser_scripts_dir / "check-browser-smoke-report.py"
    browser_benchmark_superset_check = (
        browser_scripts_dir / "check-browser-benchmark-superset.py"
    )
    browser_canvas_webgpu_fusion_check = (
        browser_scripts_dir / "check-browser-canvas-webgpu-fusion.py"
    )
    browser_cts_subset_check = browser_scripts_dir / "check-browser-cts-subset.py"
    browser_fallback_explanations_check = (
        browser_scripts_dir / "check-browser-fallback-explanations.py"
    )
    browser_gpu_scheduler_check = browser_scripts_dir / "check-browser-gpu-scheduler.py"
    browser_gpu_flight_recorder_replay = (
        browser_scripts_dir / "replay-browser-gpu-flight-recorder.py"
    )
    browser_local_ai_workloads_check = (
        browser_scripts_dir / "check-browser-local-ai-workloads.py"
    )
    browser_media_path_probe_check = browser_scripts_dir / "check-browser-media-path-probe.py"
    browser_pipeline_cache_receipts_check = (
        browser_scripts_dir / "check-browser-pipeline-cache-receipts.py"
    )
    browser_recovery_parity_check = browser_scripts_dir / "check-browser-recovery-parity.py"
    browser_shader_links_check = browser_scripts_dir / "check-browser-shader-links.py"
    browser_webgpu_effect_experiment_check = (
        browser_scripts_dir / "check-browser-webgpu-effect-experiment.py"
    )
    native_pipeline_cache_receipts_check = (
        tools_dir / "check_native_pipeline_cache_receipts.py"
    )
    native_resource_reuse_receipts_check = (
        tools_dir / "check_native_resource_reuse_receipts.py"
    )
    native_upload_path_receipts_check = tools_dir / "check_native_upload_path_receipts.py"
    wgsl_diagnostic_fixtures_check = tools_dir / "check_wgsl_diagnostic_fixtures.py"
    wgsl_robustness_fixtures_check = tools_dir / "check_wgsl_robustness_fixtures.py"

    def require_existing_path(path_text: str, option_name: str) -> Path | None:
        path = Path(path_text)
        if not path.exists():
            print(f"FAIL: missing {option_name}: {path}")
            return None
        return path

    if args.with_browser_claim_promotion_receipt_gate:
        receipt_path = Path(args.browser_claim_promotion_receipt)
        if not receipt_path.exists():
            print(
                "FAIL: missing --browser-claim-promotion-receipt: "
                f"{receipt_path}"
            )
            return 1
        gate_cmd = [
            sys.executable,
            str(browser_claim_promotion_receipt_check),
            "--receipt",
            str(receipt_path),
        ]
        if args.browser_claim_promotion_receipt_verify_files_root.strip():
            gate_cmd.extend(
                [
                    "--verify-files-root",
                    args.browser_claim_promotion_receipt_verify_files_root.strip(),
                ]
            )
        run_gate("browser-claim-promotion-receipt", gate_cmd)

    if args.with_browser_release_candidate_provenance_gate:
        package_inputs = (
            args.browser_release_candidate_provenance_package_inputs.strip()
        )
        if not package_inputs:
            print(
                "FAIL: missing "
                "--browser-release-candidate-provenance-package-inputs: "
                "browser release-candidate provenance gate requires the "
                "package-input preflight receipt"
            )
            return 1
        candidate_inputs = (
            (
                package_inputs,
                "--browser-release-candidate-provenance-package-inputs",
            ),
            (
                args.browser_release_candidate_provenance_release_archive,
                "--browser-release-candidate-provenance-release-archive",
            ),
            (
                args.browser_release_candidate_provenance_release_archive_manifest,
                "--browser-release-candidate-provenance-release-archive-manifest",
            ),
            (
                args.browser_release_candidate_provenance_public_download_receipt,
                "--browser-release-candidate-provenance-public-download-receipt",
            ),
            (
                args.browser_release_candidate_provenance_proof_surface,
                "--browser-release-candidate-provenance-proof-surface",
            ),
            (
                args.browser_release_candidate_provenance_proof_surface_check,
                "--browser-release-candidate-provenance-proof-surface-check",
            ),
            (
                args.browser_release_candidate_provenance_browser_launch_receipt,
                "--browser-release-candidate-provenance-browser-launch-receipt",
            ),
        )
        for input_path, option_name in candidate_inputs:
            if require_existing_path(input_path, option_name) is None:
                return 1
        gate_cmd = [
            sys.executable,
            str(browser_release_candidate_provenance_check),
            "--release-archive",
            args.browser_release_candidate_provenance_release_archive,
            "--release-archive-url",
            args.browser_release_candidate_provenance_release_archive_url,
            "--release-archive-manifest",
            args.browser_release_candidate_provenance_release_archive_manifest,
            "--public-download-receipt",
            args.browser_release_candidate_provenance_public_download_receipt,
            "--proof-surface",
            args.browser_release_candidate_provenance_proof_surface,
            "--proof-surface-check",
            args.browser_release_candidate_provenance_proof_surface_check,
            "--browser-launch-receipt",
            args.browser_release_candidate_provenance_browser_launch_receipt,
            "--package-inputs",
            package_inputs,
        ]
        if args.browser_release_candidate_provenance_verify_files_root.strip():
            gate_cmd.extend(
                [
                    "--verify-files-root",
                    args.browser_release_candidate_provenance_verify_files_root.strip(),
                ]
            )
        if args.browser_release_candidate_provenance_out.strip():
            gate_cmd.extend(["--out", args.browser_release_candidate_provenance_out.strip()])
        run_gate("browser-release-candidate-provenance", gate_cmd)

    if args.with_browser_published_proof_surface_gate:
        surface_path = Path(args.browser_published_proof_surface)
        if not surface_path.exists():
            print(f"FAIL: missing --browser-published-proof-surface: {surface_path}")
            return 1
        gate_cmd = [
            sys.executable,
            str(browser_published_proof_surface_check),
            "--surface",
            str(surface_path),
        ]
        if args.browser_published_proof_surface_verify_files_root.strip():
            gate_cmd.extend(
                [
                    "--verify-files-root",
                    args.browser_published_proof_surface_verify_files_root.strip(),
                ]
            )
        if args.browser_published_proof_surface_require_public_urls:
            gate_cmd.append("--require-public-urls")
        if args.browser_published_proof_surface_check_out.strip():
            gate_cmd.extend(["--out", args.browser_published_proof_surface_check_out.strip()])
        run_gate("browser-published-proof-surface", gate_cmd)

    if args.with_browser_release_candidate_finalizer_gate:
        report_path = Path(args.browser_release_candidate_finalizer_report)
        if not report_path.exists():
            print(
                "FAIL: missing --browser-release-candidate-finalizer-report: "
                f"{report_path}"
            )
            return 1
        gate_cmd = [
            sys.executable,
            str(browser_release_candidate_finalizer_check),
            "--report",
            str(report_path),
        ]
        if args.browser_release_candidate_finalizer_verify_files_root.strip():
            gate_cmd.extend(
                [
                    "--verify-files-root",
                    args.browser_release_candidate_finalizer_verify_files_root.strip(),
                ]
            )
        if args.browser_release_candidate_finalizer_require_pass:
            gate_cmd.append("--require-pass")
        if args.browser_release_candidate_finalizer_check_out.strip():
            gate_cmd.extend(["--out", args.browser_release_candidate_finalizer_check_out.strip()])
        run_gate("browser-release-candidate-finalizer", gate_cmd)

    if args.with_browser_release_artifact_bundle_gate:
        bundle_path = Path(args.browser_release_artifact_bundle)
        if not bundle_path.exists():
            print(f"FAIL: missing --browser-release-artifact-bundle: {bundle_path}")
            return 1
        gate_cmd = [
            sys.executable,
            str(browser_release_artifact_bundle_check),
            "--bundle",
            str(bundle_path),
        ]
        if args.browser_release_artifact_bundle_verify_files_root.strip():
            gate_cmd.extend(
                [
                    "--verify-files-root",
                    args.browser_release_artifact_bundle_verify_files_root.strip(),
                ]
            )
        if args.browser_release_artifact_bundle_require_release_candidate:
            gate_cmd.append("--require-release-candidate")
        run_gate("browser-release-artifact-bundle", gate_cmd)

    if args.with_browser_release_package_inputs_gate:
        gate_cmd = [
            sys.executable,
            str(browser_release_package_inputs_check),
            "--package-dir",
            args.browser_release_package_inputs_package_dir,
            "--package-root-name",
            args.browser_release_package_inputs_package_root_name,
            "--doe-runtime",
            args.browser_release_package_inputs_doe_runtime,
            "--dawn-fallback-runtime",
            args.browser_release_package_inputs_dawn_fallback_runtime,
            "--shader-compiler",
            args.browser_release_package_inputs_shader_compiler,
            "--product-version",
            args.browser_release_package_inputs_product_version,
            "--product-channel",
            args.browser_release_package_inputs_product_channel,
            "--platform-os",
            args.browser_release_package_inputs_platform_os,
            "--platform-arch",
            args.browser_release_package_inputs_platform_arch,
            "--root",
            args.browser_release_package_inputs_root,
        ]
        if args.browser_release_package_inputs_require_release_candidate_eligible:
            gate_cmd.append("--require-release-candidate-eligible")
        if args.browser_release_package_inputs_out.strip():
            gate_cmd.extend(["--out", args.browser_release_package_inputs_out.strip()])
        run_gate("browser-release-package-inputs", gate_cmd)

    if args.with_browser_runtime_frontier_bundle_gate:
        identity_path = Path(args.browser_runtime_frontier_bundle_runtime_identity)
        if not identity_path.exists():
            print(
                "FAIL: missing --browser-runtime-frontier-bundle-runtime-identity: "
                f"{identity_path}"
            )
            return 1
        receipt_path = Path(args.browser_runtime_frontier_bundle_claim_promotion_receipt)
        if not receipt_path.exists():
            print(
                "FAIL: missing --browser-runtime-frontier-bundle-claim-promotion-receipt: "
                f"{receipt_path}"
            )
            return 1
        bundle_path = Path(args.browser_runtime_frontier_bundle_release_artifact_bundle)
        if not bundle_path.exists():
            print(
                "FAIL: missing --browser-runtime-frontier-bundle-release-artifact-bundle: "
                f"{bundle_path}"
            )
            return 1
        gate_cmd = [
            sys.executable,
            str(browser_runtime_frontier_bundle_check),
            "--runtime-identity",
            str(identity_path),
            "--claim-promotion-receipt",
            str(receipt_path),
            "--release-artifact-bundle",
            str(bundle_path),
        ]
        if args.browser_runtime_frontier_bundle_verify_files_root.strip():
            gate_cmd.extend(
                [
                    "--verify-files-root",
                    args.browser_runtime_frontier_bundle_verify_files_root.strip(),
                ]
            )
        if args.browser_runtime_frontier_bundle_require_claimable:
            gate_cmd.append("--require-claimable")
        if args.browser_runtime_frontier_bundle_out.strip():
            gate_cmd.extend(["--out", args.browser_runtime_frontier_bundle_out.strip()])
        run_gate("browser-runtime-frontier-bundle", gate_cmd)

    if args.with_wgsl_lowering_link_receipt_gate:
        receipt_path = Path(args.wgsl_lowering_link_receipt)
        if not receipt_path.exists():
            print(f"FAIL: missing --wgsl-lowering-link-receipt: {receipt_path}")
            return 1
        gate_cmd = [
            sys.executable,
            str(wgsl_lowering_link_receipt_check),
            "--receipt",
            str(receipt_path),
        ]
        if args.wgsl_lowering_link_verify_files_root.strip():
            gate_cmd.extend(
                [
                    "--verify-files-root",
                    args.wgsl_lowering_link_verify_files_root.strip(),
                ]
            )
        run_gate("wgsl-lowering-link-receipt", gate_cmd)

    if args.with_wgsl_minimization_receipt_gate:
        receipt_path = Path(args.wgsl_minimization_receipt)
        if not receipt_path.exists():
            print(f"FAIL: missing --wgsl-minimization-receipt: {receipt_path}")
            return 1
        gate_cmd = [
            sys.executable,
            str(wgsl_minimization_receipt_check),
            "--receipt",
            str(receipt_path),
        ]
        if args.wgsl_minimization_verify_files_root.strip():
            gate_cmd.extend(
                [
                    "--verify-files-root",
                    args.wgsl_minimization_verify_files_root.strip(),
                ]
            )
        run_gate("wgsl-minimization-receipt", gate_cmd)

    if args.with_wgsl_cts_shader_subset_gate:
        subset_path = Path(args.wgsl_cts_shader_subset)
        if not subset_path.exists():
            print(f"FAIL: missing --wgsl-cts-shader-subset: {subset_path}")
            return 1
        run_gate(
            "wgsl-cts-shader-subset",
            [
                sys.executable,
                str(wgsl_cts_shader_subset_check),
                "--subset",
                str(subset_path),
            ],
        )

    if args.with_wgsl_corpus_materialization_gate:
        receipt_path = Path(args.wgsl_corpus_materialization_receipt)
        if not receipt_path.exists():
            print(
                "FAIL: missing --wgsl-corpus-materialization-receipt: "
                f"{receipt_path}"
            )
            return 1
        gate_cmd = [
            sys.executable,
            str(wgsl_corpus_materialization_check),
            "--receipt",
            str(receipt_path),
        ]
        if args.wgsl_corpus_materialization_verify_files_root.strip():
            gate_cmd.extend(
                [
                    "--verify-files-root",
                    args.wgsl_corpus_materialization_verify_files_root.strip(),
                ]
            )
        run_gate("wgsl-corpus-materialization", gate_cmd)

    if args.with_native_command_graph_replay_gate:
        receipt_path = Path(args.native_command_graph_receipt)
        if not receipt_path.exists():
            print(f"FAIL: missing --native-command-graph-receipt: {receipt_path}")
            return 1
        gate_cmd = [
            sys.executable,
            str(native_command_graph_replay),
            "--receipt",
            str(receipt_path),
        ]
        if args.native_command_graph_verify_files_root.strip():
            gate_cmd.extend(
                [
                    "--verify-files-root",
                    args.native_command_graph_verify_files_root.strip(),
                ]
            )
        run_gate("native-command-graph-replay", gate_cmd)

    if args.with_native_no_fallback_gate:
        report = Path(args.native_no_fallback_report)
        if not report.exists():
            print(f"FAIL: missing --native-no-fallback-report: {report}")
            return 1
        gate_cmd = [
            sys.executable,
            str(native_no_fallback_report_check),
            "--report",
            str(report),
        ]
        if args.native_no_fallback_verify_files_root.strip():
            gate_cmd.extend(
                [
                    "--verify-files-root",
                    args.native_no_fallback_verify_files_root.strip(),
                ]
            )
        run_gate("native-no-fallback", gate_cmd)

    if args.with_native_backend_coverage_matrix_gate:
        matrix_path = Path(args.native_backend_coverage_matrix)
        if not matrix_path.exists():
            print(f"FAIL: missing --native-backend-coverage-matrix: {matrix_path}")
            return 1
        gate_cmd = [
            sys.executable,
            str(native_backend_coverage_matrix_check),
            "--matrix",
            str(matrix_path),
        ]
        if args.native_backend_coverage_evidence_root.strip():
            gate_cmd.extend(
                [
                    "--verify-evidence-root",
                    args.native_backend_coverage_evidence_root.strip(),
                ]
            )
        run_gate("native-backend-coverage-matrix", gate_cmd)

    if args.with_browser_capture_policy_gate:
        policy_path = require_existing_path(
            args.browser_capture_policy,
            "--browser-capture-policy",
        )
        if policy_path is None:
            return 1
        run_gate(
            "browser-capture-policy",
            [
                sys.executable,
                str(browser_capture_policy_check),
                "--policy",
                str(policy_path),
            ],
        )

    if args.with_browser_artifact_identity_coverage_gate:
        coverage_path = require_existing_path(
            args.browser_artifact_identity_coverage,
            "--browser-artifact-identity-coverage",
        )
        if coverage_path is None:
            return 1
        run_gate(
            "browser-artifact-identity-coverage",
            [
                sys.executable,
                str(browser_artifact_identity_coverage_check),
                "--coverage",
                str(coverage_path),
                "--root",
                args.browser_artifact_identity_coverage_root,
            ],
        )

    if args.with_browser_unsupported_reason_taxonomy_gate:
        taxonomy_path = require_existing_path(
            args.browser_unsupported_reason_taxonomy,
            "--browser-unsupported-reason-taxonomy",
        )
        if taxonomy_path is None:
            return 1
        run_gate(
            "browser-unsupported-reason-taxonomy",
            [
                sys.executable,
                str(browser_unsupported_reason_taxonomy_check),
                "--taxonomy",
                str(taxonomy_path),
            ],
        )

    if args.with_evidence_blocker_taxonomy_gate:
        taxonomy_path = require_existing_path(
            args.evidence_blocker_taxonomy,
            "--evidence-blocker-taxonomy",
        )
        schema_path = require_existing_path(
            args.evidence_blocker_taxonomy_schema,
            "--evidence-blocker-taxonomy-schema",
        )
        model_runtime_schema_path = require_existing_path(
            args.evidence_blocker_model_runtime_schema,
            "--evidence-blocker-model-runtime-schema",
        )
        if (
            taxonomy_path is None
            or schema_path is None
            or model_runtime_schema_path is None
        ):
            return 1
        run_gate(
            "evidence-blocker-taxonomy",
            [
                sys.executable,
                str(evidence_blocker_taxonomy_gate),
                "--taxonomy",
                str(taxonomy_path),
                "--schema",
                str(schema_path),
                "--model-runtime-schema",
                str(model_runtime_schema_path),
            ],
        )

    if args.with_browser_responsibility_map_gate:
        map_path = require_existing_path(
            args.browser_responsibility_map,
            "--browser-responsibility-map",
        )
        if map_path is None:
            return 1
        run_gate(
            "browser-responsibility-map",
            [
                sys.executable,
                str(browser_responsibility_map_check),
                "--map",
                str(map_path),
                "--root",
                args.browser_responsibility_map_root,
            ],
        )

    if args.with_chromium_fork_maintenance_policy_gate:
        policy_path = require_existing_path(
            args.chromium_fork_maintenance_policy,
            "--chromium-fork-maintenance-policy",
        )
        if policy_path is None:
            return 1
        run_gate(
            "chromium-fork-maintenance-policy",
            [
                sys.executable,
                str(chromium_fork_maintenance_policy_check),
                "--policy",
                str(policy_path),
            ],
        )

    if args.with_chromium_patch_manifest_gate:
        manifest_path = require_existing_path(
            args.chromium_patch_manifest,
            "--chromium-patch-manifest",
        )
        policy_path = require_existing_path(
            args.chromium_fork_maintenance_policy,
            "--chromium-fork-maintenance-policy",
        )
        if manifest_path is None or policy_path is None:
            return 1
        run_gate(
            "chromium-patch-manifest",
            [
                sys.executable,
                str(chromium_patch_manifest_check),
                "--manifest",
                str(manifest_path),
                "--policy",
                str(policy_path),
                "--root",
                args.chromium_patch_manifest_root,
            ],
        )

    if args.with_chromium_source_checkout_gate:
        command = [
            sys.executable,
            str(chromium_source_checkout_check),
            "--source-root",
            args.chromium_source_root,
            "--root",
            args.chromium_source_checkout_root,
            "--require-ready",
        ]
        if args.chromium_source_require_runtime_selector:
            command.append("--require-runtime-selector")
        run_gate(
            "chromium-source-checkout",
            command,
        )

    if args.with_doe_chromium_proc_surface_gate:
        config_path = require_existing_path(
            args.doe_chromium_proc_surface,
            "--doe-chromium-proc-surface",
        )
        if config_path is None:
            return 1
        command = [
            sys.executable,
            str(doe_chromium_proc_surface_check),
            "--config",
            str(config_path),
            "--require-ready",
        ]
        if args.doe_chromium_proc_surface_library.strip():
            command.extend(
                [
                    "--library",
                    args.doe_chromium_proc_surface_library.strip(),
                ]
            )
        run_gate(
            "doe-chromium-proc-surface",
            command,
        )

    if args.with_webgpu_integration_chromium_gate:
        overlay_path = require_existing_path(
            args.webgpu_integration_chromium,
            "--webgpu-integration-chromium",
        )
        if overlay_path is None:
            return 1
        gate_cmd = [
            sys.executable,
            str(webgpu_integration_chromium_check),
            "--overlay",
            str(overlay_path),
        ]
        if args.webgpu_integration_chromium_verify_artifact_root.strip():
            gate_cmd.extend(
                [
                    "--verify-artifact-root",
                    args.webgpu_integration_chromium_verify_artifact_root.strip(),
                ]
            )
        run_gate("webgpu-integration-chromium", gate_cmd)

    if args.with_browser_runtime_selector_policy_gate:
        policy_path = require_existing_path(
            args.browser_runtime_selector_policy,
            "--browser-runtime-selector-policy",
        )
        if policy_path is None:
            return 1
        run_gate(
            "browser-runtime-selector-policy",
            [
                sys.executable,
                str(browser_runtime_selector_policy_check),
                "--policy",
                str(policy_path),
            ],
        )

    if args.with_browser_runtime_identity_gate:
        identity_path = require_existing_path(
            args.browser_runtime_identity,
            "--browser-runtime-identity",
        )
        if identity_path is None:
            return 1
        run_gate(
            "browser-runtime-identity",
            [
                sys.executable,
                str(browser_runtime_identity_check),
                "--identity",
                str(identity_path),
            ],
        )

    if args.with_browser_promotion_approvals_gate:
        approvals_path = require_existing_path(
            args.browser_promotion_approvals,
            "--browser-promotion-approvals",
        )
        workflow_path = require_existing_path(
            args.browser_promotion_approvals_workflows,
            "--browser-promotion-approvals-workflows",
        )
        if approvals_path is None or workflow_path is None:
            return 1
        run_gate(
            "browser-promotion-approvals",
            [
                sys.executable,
                str(browser_promotion_approvals_check),
                "--approvals",
                str(approvals_path),
                "--workflows",
                str(workflow_path),
            ],
        )

    if args.with_browser_workflow_manifest_gate:
        workflow_path = require_existing_path(
            args.browser_workflow_manifest,
            "--browser-workflow-manifest",
        )
        if workflow_path is None:
            return 1
        run_gate(
            "browser-workflow-manifest",
            [
                sys.executable,
                str(browser_workflow_manifest_check),
                "--manifest",
                str(workflow_path),
            ],
        )

    if args.with_browser_milestones_gate:
        manifest_path = require_existing_path(
            args.browser_milestones,
            "--browser-milestones",
        )
        if manifest_path is None:
            return 1
        run_gate(
            "browser-milestones",
            [
                sys.executable,
                str(browser_milestones_check),
                "--manifest",
                str(manifest_path),
            ],
        )

    if args.with_browser_benchmark_superset_gate:
        gate_cmd = [
            sys.executable,
            str(browser_benchmark_superset_check),
        ]
        if args.browser_benchmark_superset_report.strip():
            report = require_existing_path(
                args.browser_benchmark_superset_report.strip(),
                "--browser-benchmark-superset-report",
            )
            if report is None:
                return 1
            gate_cmd.extend(["--report", str(report)])
        if args.browser_benchmark_superset_require_modes.strip():
            gate_cmd.extend(
                [
                    "--require-modes",
                    args.browser_benchmark_superset_require_modes.strip(),
                ]
            )
        if args.browser_benchmark_superset_require_promotion_approvals:
            gate_cmd.append("--require-promotion-approvals")
        run_gate("browser-benchmark-superset", gate_cmd)

    if args.with_browser_gpu_flight_recorder_replay_gate:
        flight_recorder_path = require_existing_path(
            args.browser_gpu_flight_recorder,
            "--browser-gpu-flight-recorder",
        )
        capture_policy_path = require_existing_path(
            args.browser_gpu_flight_recorder_capture_policy,
            "--browser-gpu-flight-recorder-capture-policy",
        )
        if flight_recorder_path is None or capture_policy_path is None:
            return 1
        gate_cmd = [
            sys.executable,
            str(browser_gpu_flight_recorder_replay),
            "--flight-recorder",
            str(flight_recorder_path),
            "--capture-policy",
            str(capture_policy_path),
            "--responsibility-map-root",
            args.browser_gpu_flight_recorder_responsibility_map_root,
        ]
        if args.browser_gpu_flight_replay_out.strip():
            gate_cmd.extend(["--out", args.browser_gpu_flight_replay_out.strip()])
        run_gate("browser-gpu-flight-recorder-replay", gate_cmd)

    simple_artifact_gates: tuple[tuple[bool, str, Path, str, str], ...] = (
        (
            args.with_browser_smoke_report_gate,
            "browser-smoke-report",
            browser_smoke_report_check,
            "--smoke-report",
            args.browser_smoke_report,
        ),
        (
            args.with_browser_canvas_webgpu_fusion_gate,
            "browser-canvas-webgpu-fusion",
            browser_canvas_webgpu_fusion_check,
            "--probe",
            args.browser_canvas_webgpu_fusion_probe,
        ),
        (
            args.with_browser_cts_subset_gate,
            "browser-cts-subset",
            browser_cts_subset_check,
            "--subset",
            args.browser_cts_subset,
        ),
        (
            args.with_browser_fallback_explanations_gate,
            "browser-fallback-explanations",
            browser_fallback_explanations_check,
            "--explanations",
            args.browser_fallback_explanations,
        ),
        (
            args.with_browser_gpu_scheduler_gate,
            "browser-gpu-scheduler",
            browser_gpu_scheduler_check,
            "--probe",
            args.browser_gpu_scheduler_probe,
        ),
        (
            args.with_browser_local_ai_workloads_gate,
            "browser-local-ai-workloads",
            browser_local_ai_workloads_check,
            "--workloads",
            args.browser_local_ai_workloads,
        ),
        (
            args.with_browser_media_path_probe_gate,
            "browser-media-path-probe",
            browser_media_path_probe_check,
            "--probe",
            args.browser_media_path_probe,
        ),
        (
            args.with_browser_pipeline_cache_receipts_gate,
            "browser-pipeline-cache-receipts",
            browser_pipeline_cache_receipts_check,
            "--receipts",
            args.browser_pipeline_cache_receipts,
        ),
        (
            args.with_browser_recovery_parity_gate,
            "browser-recovery-parity",
            browser_recovery_parity_check,
            "--parity",
            args.browser_recovery_parity,
        ),
        (
            args.with_browser_shader_links_gate,
            "browser-shader-links",
            browser_shader_links_check,
            "--links",
            args.browser_shader_links,
        ),
        (
            args.with_browser_webgpu_effect_experiment_gate,
            "browser-webgpu-effect-experiment",
            browser_webgpu_effect_experiment_check,
            "--experiment",
            args.browser_webgpu_effect_experiment,
        ),
        (
            args.with_native_pipeline_cache_receipts_gate,
            "native-pipeline-cache-receipts",
            native_pipeline_cache_receipts_check,
            "--receipts",
            args.native_pipeline_cache_receipts,
        ),
        (
            args.with_native_resource_reuse_receipts_gate,
            "native-resource-reuse-receipts",
            native_resource_reuse_receipts_check,
            "--receipts",
            args.native_resource_reuse_receipts,
        ),
        (
            args.with_native_upload_path_receipts_gate,
            "native-upload-path-receipts",
            native_upload_path_receipts_check,
            "--receipts",
            args.native_upload_path_receipts,
        ),
    )
    for enabled, label, checker, input_flag, input_path in simple_artifact_gates:
        if not enabled:
            continue
        artifact_path = require_existing_path(input_path, input_flag)
        if artifact_path is None:
            return 1
        gate_cmd = [
            sys.executable,
            str(checker),
            input_flag,
            str(artifact_path),
        ]
        if label == "browser-smoke-report":
            gate_cmd.extend(
                [
                    "--require-modes",
                    args.browser_smoke_report_require_modes,
                ]
            )
        if label in {
            "browser-canvas-webgpu-fusion",
            "browser-fallback-explanations",
            "browser-gpu-scheduler",
            "browser-local-ai-workloads",
            "browser-media-path-probe",
            "browser-pipeline-cache-receipts",
            "browser-webgpu-effect-experiment",
        } and args.browser_derived_runtime_identity_root.strip():
            gate_cmd.extend(
                [
                    "--runtime-identity-root",
                    args.browser_derived_runtime_identity_root.strip(),
                ]
            )
        if label == "browser-media-path-probe":
            gate_cmd.extend(
                [
                    "--capture-policy-root",
                    args.browser_media_path_probe_capture_policy_root,
                ]
            )
        if label == "browser-fallback-explanations":
            gate_cmd.extend(
                [
                    "--taxonomy-root",
                    args.browser_fallback_explanations_taxonomy_root,
                ]
            )
        if label == "browser-pipeline-cache-receipts":
            gate_cmd.extend(
                [
                    "--verify-workloads-root",
                    args.browser_pipeline_cache_receipts_verify_workloads_root,
                ]
            )
        if label == "browser-shader-links":
            if args.browser_shader_links_verify_flight_recorder_root.strip():
                gate_cmd.extend(
                    [
                        "--verify-flight-recorder-root",
                        args.browser_shader_links_verify_flight_recorder_root.strip(),
                    ]
                )
        if label == "browser-shader-links" and args.browser_shader_links_verify_lowering_root.strip():
            gate_cmd.extend(
                [
                    "--verify-lowering-root",
                    args.browser_shader_links_verify_lowering_root.strip(),
                ]
            )
        run_gate(
            label,
            gate_cmd,
        )

    if args.with_wgsl_diagnostic_fixtures_gate:
        fixtures_path = require_existing_path(
            args.wgsl_diagnostic_fixtures,
            "--wgsl-diagnostic-fixtures",
        )
        manifest_path = require_existing_path(
            args.wgsl_diagnostic_fixtures_manifest,
            "--wgsl-diagnostic-fixtures-manifest",
        )
        taxonomy_path = require_existing_path(
            args.wgsl_diagnostic_fixtures_taxonomy,
            "--wgsl-diagnostic-fixtures-taxonomy",
        )
        if fixtures_path is None or manifest_path is None or taxonomy_path is None:
            return 1
        run_gate(
            "wgsl-diagnostic-fixtures",
            [
                sys.executable,
                str(wgsl_diagnostic_fixtures_check),
                "--fixtures",
                str(fixtures_path),
                "--manifest",
                str(manifest_path),
                "--taxonomy",
                str(taxonomy_path),
            ],
        )

    if args.with_wgsl_robustness_fixtures_gate:
        fixtures_path = require_existing_path(
            args.wgsl_robustness_fixtures,
            "--wgsl-robustness-fixtures",
        )
        if fixtures_path is None:
            return 1
        run_gate(
            "wgsl-robustness-fixtures",
            [
                sys.executable,
                str(wgsl_robustness_fixtures_check),
                "--fixtures",
                str(fixtures_path),
            ],
        )

    for receipt_path in args.with_model_runtime_receipt:
        gate_cmd = [
            sys.executable,
            str(model_runtime_receipt_gate),
            "--receipt", receipt_path,
            "--require-fits",
            "--require-structural-full-coverage",
            "--min-kernel-coverage-pct", "100",
            "--min-chain-parity-patterns",
            str(args.model_runtime_receipt_min_chain_parity),
        ]
        stem = Path(receipt_path).stem
        run_gate(f"model-runtime-receipt:{stem}", gate_cmd)

    for receipt_path in args.with_kernel_chain_parity:
        gate_cmd = [sys.executable, str(kernel_chain_parity_gate), "--receipt", receipt_path]
        if args.kernel_chain_parity_bit_exact:
            gate_cmd.append("--require-bit-exact")
        else:
            gate_cmd.append("--require-bit-close")
        stem = Path(receipt_path).stem
        run_gate(f"kernel-chain-parity:{stem}", gate_cmd)

    if args.with_modules:
        run_gate(
            "modules",
            [
                sys.executable,
                str(module_gate),
            ],
        )

    if args.with_browser_claim_gate:
        run_gate(
            "browser-claim",
            [
                sys.executable,
                str(browser_claim_gate),
            ],
        )
    elif args.with_browser_gate:
        run_gate(
            "browser",
            [
                sys.executable,
                str(browser_gate),
            ],
        )

    if args.with_browser_claim_policy_gate:
        policy_path = require_existing_path(
            args.browser_claim_policy,
            "--browser-claim-policy",
        )
        if policy_path is None:
            return 1
        run_gate(
            "browser-claim-policy",
            [
                sys.executable,
                str(browser_claim_policy_check),
                "--policy",
                str(policy_path),
            ],
        )

    if args.with_browser_ownership_gate:
        ownership_path = require_existing_path(
            args.browser_ownership,
            "--browser-ownership",
        )
        if ownership_path is None:
            return 1
        run_gate(
            "browser-ownership",
            [
                sys.executable,
                str(browser_ownership_check),
                "--ownership",
                str(ownership_path),
            ],
        )


    return 0
