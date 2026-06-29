#!/usr/bin/env python3
"""Canonical entrypoint for schema/correctness/pipeline/trace/drop-in/claim gates with optional parity verification."""

from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
for _path_entry in (str(REPO_ROOT), str(BENCH_ROOT)):
    if _path_entry not in sys.path:
        sys.path.insert(0, _path_entry)


import shutil
import subprocess
from bench.lib import compare_claim_artifacts as artifacts_mod
from bench.lib import output_paths
from bench.runners.blocking_gates_args import parse_args
from bench.runners.blocking_gates_optional import run_optional_artifact_gates


def run_gate(label: str, command: list[str]) -> None:
    print(f"[gate] {label}: {' '.join(command)}", flush=True)
    subprocess.run(command, check=True)


def main() -> int:
    args = parse_args()
    report_path = Path(args.report)
    if not report_path.exists():
        print(f"FAIL: missing report: {report_path}")
        return 1

    try:
        report_payload = artifacts_mod.load_compare_report(report_path)
        artifacts_mod.ensure_release_strict_comparability(
            report_payload,
            report_path,
            surface="run_blocking_gates",
        )
    except RuntimeError as exc:
        print(f"FAIL: {exc}")
        return 1

    if args.claim_require_min_timed_samples < 0:
        print(
            "FAIL: invalid --claim-require-min-timed-samples="
            f"{args.claim_require_min_timed_samples} expected >= 0"
        )
        return 1
    if args.require_claim_gate and not args.with_claim_gate:
        print("FAIL: --require-claim-gate requires --with-claim-gate")
        return 1
    if args.dropin_micro_iterations < 0:
        print(
            "FAIL: invalid --dropin-micro-iterations="
            f"{args.dropin_micro_iterations} expected >= 0"
        )
        return 1
    if args.dropin_e2e_iterations < 0:
        print(
            "FAIL: invalid --dropin-e2e-iterations="
            f"{args.dropin_e2e_iterations} expected >= 0"
        )
        return 1
    if args.with_claim_gate:
        claim_benchmark_policy_path = Path(args.claim_benchmark_policy)
        if not claim_benchmark_policy_path.exists():
            print(f"FAIL: missing --claim-benchmark-policy: {claim_benchmark_policy_path}")
            return 1
    if args.with_comparability_coherence_gate:
        comparability_coherence_policy_path = Path(
            args.comparability_coherence_benchmark_policy
        )
        if not comparability_coherence_policy_path.exists():
            print(
                "FAIL: missing --comparability-coherence-benchmark-policy: "
                f"{comparability_coherence_policy_path}"
            )
            return 1

    output_timestamp = (
        output_paths.resolve_timestamp(args.timestamp)
        if args.timestamp_output
        else ""
    )

    gates_dir = BENCH_ROOT / "gates"
    tools_dir = BENCH_ROOT / "tools"
    dropin_dir = BENCH_ROOT / "drop-in"
    schema_gate = gates_dir / "schema_gate.py"
    claim_index_gate = gates_dir / "claim_index_gate.py"
    dawn_replacement_frontier_gate = gates_dir / "dawn_replacement_frontier_gate.py"
    tool_surface_gate = gates_dir / "tool_surface_gate.py"
    file_size_gate = gates_dir / "file_size_gate.py"
    split_coverage_gate = gates_dir / "split_coverage_gate.py"
    backend_workload_catalog_gate = tools_dir / "generate_backend_workloads.py"
    workload_overlap_map = tools_dir / "generate_workload_overlap_map.py"
    comparability_parity_gate = gates_dir / "comparability_obligation_parity_gate.py"
    correctness_gate = gates_dir / "check_correctness.py"
    trace_gate = gates_dir / "trace_gate.py"
    backend_selection_gate = gates_dir / "backend_selection_gate.py"
    shader_artifact_gate = gates_dir / "shader_artifact_gate.py"
    tint_compiler_evidence_gate = gates_dir / "tint_compiler_evidence_gate.py"
    spirv_val_gate = gates_dir / "spirv_val_gate.py"
    dxil_validate_gate = gates_dir / "dxil_validate_gate.py"
    sync_conformance_gate = gates_dir / "sync_conformance_gate.py"
    timing_policy_gate = gates_dir / "timing_policy_gate.py"
    comparable_runtime_invariants_gate = (
        gates_dir / "comparable_runtime_invariants_gate.py"
    )
    comparability_coherence_gate = gates_dir / "comparability_coherence_gate.py"
    compare_output_partition_gate = gates_dir / "compare_output_partition_gate.py"
    structural_equivalence_gate = gates_dir / "structural_equivalence_gate.py"
    dropin_gate = dropin_dir / "dropin_gate.py"
    dropin_proc_resolution_tests = dropin_dir / "dropin_proc_resolution_tests.py"
    cts_baseline_compare = tools_dir / "cts_baseline_compare.py"
    csl_governed_lane_gate = gates_dir / "csl_governed_lane_gate.py"
    csl_simulator_gate = gates_dir / "csl_simulator_gate.py"
    sdklayout_streaming_hardening_gate = (
        gates_dir / "sdklayout_streaming_hardening_gate.py"
    )
    cerebras_artifact_gate = gates_dir / "cerebras_artifact_gate.py"
    doe_private_strategy_leak_gate = gates_dir / "doe_private_strategy_leak_gate.py"
    wgsl_backend_matrix_gate = gates_dir / "wgsl_backend_matrix_gate.py"
    csl_fixture_mirror_gate = gates_dir / "csl_fixture_mirror_gate.py"
    csl_operation_graph_gate = gates_dir / "csl_operation_graph_gate.py"
    cross_model_parity_gate = tools_dir / "aggregate_cross_model_parity.py"
    tracked_ignore_gate = tools_dir / "check_no_new_tracked_under_gitignore.py"
    pilot_evidence_gate = gates_dir / "pilot_evidence_gate.py"
    claim_gate = gates_dir / "claim_gate.py"
    bench_cli = BENCH_ROOT / "cli.py"

    if not args.with_claim_gate:
        print(
            "INFO: claim gate not requested; this run validates blocking gates only "
            "(schema/correctness/trace[/drop-in]) and is not release-claim readiness evidence."
        )
    if not args.with_comparability_parity_gate:
        print(
            "INFO: comparability parity gate not requested; verification-lane Lean/Python "
            "fixture parity is not checked in this run."
        )
    if not args.with_comparability_coherence_gate:
        print(
            "INFO: comparability coherence gate disabled via "
            "--no-with-comparability-coherence-gate; this run does NOT validate "
            "that workload matching, obligations, structural checks, timing "
            "phase checks, and sample-floor policy agree at report scope."
        )
    if not args.with_compare_output_partition_gate:
        print(
            "INFO: compare output partition gate disabled via "
            "--no-with-compare-output-partition-gate; this run does NOT validate "
            "that diagnostic rows stay out of claimable compare output."
        )
    if not args.with_structural_equivalence_gate:
        print(
            "INFO: structural equivalence gate disabled via "
            "--no-with-structural-equivalence-gate; this run does NOT validate "
            "dispatch-count parity, timing-phase symmetry, or zero-phase "
            "anomalies. Use only for diagnostic-only runs that legitimately "
            "fail structural parity (e.g. directional coverage lanes)."
        )
    if args.with_claim_gate and not args.with_comparability_coherence_gate:
        print(
            "FAIL: --with-claim-gate requires comparability coherence gate "
            "(remove --no-with-comparability-coherence-gate)."
        )
        return 1
    if args.with_claim_gate and not args.with_compare_output_partition_gate:
        print(
            "FAIL: --with-claim-gate requires compare output partition gate "
            "(remove --no-with-compare-output-partition-gate)."
        )
        return 1
    if args.with_claim_gate and not args.with_structural_equivalence_gate:
        # --with-claim-gate cannot coexist with structural opt-out; CLAUDE.md
        # non-negotiable #10 requires structural parity for any claim-eligible
        # workload.
        print(
            "FAIL: --with-claim-gate requires structural equivalence gate "
            "(remove --no-with-structural-equivalence-gate)."
        )
        return 1

    try:
        if args.with_tracked_ignore_gate:
            run_gate(
                "tracked-ignore",
                [sys.executable, str(tracked_ignore_gate)],
            )
        run_gate("schema", [sys.executable, str(schema_gate)])
        if args.with_claim_index_gate:
            run_gate("claim-index", [sys.executable, str(claim_index_gate)])
        if args.with_dawn_replacement_frontier_gate:
            run_gate(
                "dawn-replacement-frontier",
                [sys.executable, str(dawn_replacement_frontier_gate)],
            )
        if args.with_tool_surface_gate:
            run_gate("tool-surface", [sys.executable, str(tool_surface_gate)])
        run_gate("cerebras-artifact", [sys.executable, str(cerebras_artifact_gate)])
        run_gate("doe-private-strategy-leak", [sys.executable, str(doe_private_strategy_leak_gate)])
        run_gate("csl-fixture-mirrors", [sys.executable, str(csl_fixture_mirror_gate)])
        run_gate("csl-operation-graph", [sys.executable, str(csl_operation_graph_gate)])
        if args.with_cross_model_parity_gate:
            run_gate(
                "cross-model-parity",
                [
                    sys.executable,
                    str(cross_model_parity_gate),
                    "--out",
                    args.cross_model_parity_out,
                ],
            )
        if args.with_pilot_evidence_gate:
            run_gate("pilot-evidence", [sys.executable, str(pilot_evidence_gate)])
        if args.with_file_size_gate:
            run_gate("file-size", [sys.executable, str(file_size_gate)])
        if args.with_split_coverage_gate:
            run_gate(
                "split-coverage",
                [
                    sys.executable,
                    str(split_coverage_gate),
                    "--surface",
                    args.split_coverage_surface,
                ],
            )
        run_gate(
            "backend-workload-catalog",
            [sys.executable, str(backend_workload_catalog_gate), "--verify"],
        )
        run_gate(
            "backend-workload-catalog-tests",
            [
                sys.executable,
                "-m",
                "unittest",
                "bench.tests.test_backend_workload_catalog",
            ],
        )
        run_gate(
            "backend-workload-overlap-map",
            [
                sys.executable,
                str(workload_overlap_map),
                "--verify",
            ],
        )
        if args.with_comparability_parity_gate:
            run_gate("comparability-parity", [sys.executable, str(comparability_parity_gate)])
        run_gate(
            "correctness",
            [
                sys.executable,
                str(correctness_gate),
                "--gates",
                args.gates,
                "--quirk",
                args.quirk,
                "--report",
                str(report_path),
            ],
        )
        run_gate(
            "trace",
            [
                sys.executable,
                str(trace_gate),
                "--report",
                str(report_path),
                "--semantic-parity-mode",
                args.trace_semantic_parity_mode,
            ],
        )
        if args.with_comparable_runtime_invariants_gate:
            run_gate(
                "comparable-runtime-invariants",
                [
                    sys.executable,
                    str(comparable_runtime_invariants_gate),
                    "--report",
                    str(report_path),
                ],
            )
        if args.with_compare_output_partition_gate:
            run_gate(
                "compare-output-partition",
                [
                    sys.executable,
                    str(compare_output_partition_gate),
                    "--report",
                    str(report_path),
                ],
            )
        if args.with_csl_governed_lane_gate:
            gate_cmd = [
                sys.executable,
                str(csl_governed_lane_gate),
                "--report",
                args.csl_governed_report,
                "--schema",
                args.csl_governed_schema,
            ]
            if args.csl_governed_require_compile_success:
                gate_cmd.append("--require-compile-success")
            if args.csl_governed_require_run_success:
                gate_cmd.append("--require-run-success")
            run_gate("csl-governed-lane", gate_cmd)

        if args.with_csl_simulator_gate:
            gate_cmd = [
                sys.executable,
                str(csl_simulator_gate),
                "--report",
                args.csl_simulator_report,
                "--report-schema",
                args.csl_simulator_report_schema,
            ]
            if args.csl_simulator_require_ready:
                gate_cmd.append("--require-ready")
            run_gate("csl-simulator", gate_cmd)

        if args.with_sdklayout_streaming_hardening_gate:
            gate_cmd = [
                sys.executable,
                str(sdklayout_streaming_hardening_gate),
            ]
            for trace_path in args.sdklayout_streaming_hardening_trace:
                gate_cmd.extend(["--trace", trace_path])
            if args.sdklayout_streaming_hardening_fail_on_overalloc:
                gate_cmd.append("--fail-on-overalloc")
            run_gate("sdklayout-streaming-hardening", gate_cmd)

        if args.with_wgsl_backend_matrix_gate:
            gate_cmd = [
                sys.executable,
                str(wgsl_backend_matrix_gate),
                "--report",
                args.wgsl_backend_matrix_report,
                "--schema",
                args.wgsl_backend_matrix_schema,
                "--require-vulkan-ready",
                "--require-metal-ready",
                "--require-d3d12-ready",
                "--sdk-optional",
                "--min-csl-runtime-ready",
                str(args.wgsl_backend_matrix_min_csl_runtime_ready),
            ]
            run_gate("wgsl-backend-matrix", gate_cmd)

        optional_status = run_optional_artifact_gates(
            args, repo_root=REPO_ROOT, bench_root=BENCH_ROOT, run_gate=run_gate
        )
        if optional_status != 0:
            return optional_status

        if args.with_comparability_coherence_gate:
            run_gate(
                "comparability-coherence",
                [
                    sys.executable,
                    str(comparability_coherence_gate),
                    "--report",
                    str(report_path),
                    "--benchmark-policy",
                    args.comparability_coherence_benchmark_policy,
                    "--require-pass",
                ],
            )

        if args.with_structural_equivalence_gate:
            run_gate(
                "structural-equivalence",
                [
                    sys.executable,
                    str(structural_equivalence_gate),
                    "--report",
                    str(report_path),
                    "--require-all-pass",
                ],
            )

        if args.with_backend_selection_gate:
            backend_policy_path = Path(args.backend_runtime_policy)
            if not backend_policy_path.exists():
                print(f"FAIL: missing --backend-runtime-policy: {backend_policy_path}")
                return 1
            backend_selection_command = [
                sys.executable,
                str(backend_selection_gate),
                "--report",
                str(report_path),
                "--policy",
                str(backend_policy_path),
            ]
            if args.backend_selection_lane.strip():
                backend_selection_command.extend(
                    ["--lane", args.backend_selection_lane.strip()]
                )
            run_gate("backend-selection", backend_selection_command)

        if args.with_shader_artifact_gate:
            shader_schema_path = Path(args.shader_artifact_schema)
            if not shader_schema_path.exists():
                print(f"FAIL: missing --shader-artifact-schema: {shader_schema_path}")
                return 1
            spirv_val = args.shader_artifact_spirv_val.strip()
            if not spirv_val:
                spirv_val = shutil.which("spirv-val") or ""
            if args.shader_artifact_require_spirv_validation and not spirv_val:
                print(
                    "FAIL: --shader-artifact-require-spirv-validation "
                    "requires --shader-artifact-spirv-val or spirv-val on PATH"
                )
                return 1
            if spirv_val and shutil.which(spirv_val) is None:
                print(f"FAIL: missing --shader-artifact-spirv-val executable: {spirv_val}")
                return 1
            shader_artifact_command = [
                sys.executable,
                str(shader_artifact_gate),
                "--report",
                str(report_path),
                "--schema",
                str(shader_schema_path),
            ]
            if args.shader_artifact_require_manifest:
                shader_artifact_command.append("--require-manifest")
            if spirv_val:
                shader_artifact_command.extend(["--spirv-val", spirv_val])
            if args.shader_artifact_require_spirv_validation and not spirv_val:
                shader_artifact_command.append("--require-spirv-validation")
            run_gate("shader-artifact", shader_artifact_command)

        if args.with_tint_compiler_evidence_gate:
            tint_report_path = Path(args.tint_compiler_evidence_report)
            if not tint_report_path.exists():
                print(
                    "FAIL: missing --tint-compiler-evidence-report: "
                    f"{tint_report_path}"
                )
                return 1
            tint_schema_path = Path(args.tint_compiler_evidence_schema)
            if not tint_schema_path.exists():
                print(
                    "FAIL: missing --tint-compiler-evidence-schema: "
                    f"{tint_schema_path}"
                )
                return 1
            tint_gate_command = [
                sys.executable,
                str(tint_compiler_evidence_gate),
                "--report",
                str(tint_report_path),
                "--schema",
                str(tint_schema_path),
            ]
            if args.tint_compiler_evidence_require_claimable:
                tint_gate_command.append("--require-claimable")
            run_gate("tint-compiler-evidence", tint_gate_command)

        if args.with_spirv_val_gate:
            spirv_val_command = [
                sys.executable,
                str(spirv_val_gate),
            ]
            if args.spirv_val_require:
                spirv_val_command.append("--require")
            if args.spirv_val_compile:
                spirv_val_command.append("--compile")
            run_gate("spirv-val", spirv_val_command)

        if args.with_dxil_validate_gate:
            dxil_validate_command = [
                sys.executable,
                str(dxil_validate_gate),
                "--zig",
                args.dxil_validate_zig,
            ]
            if args.dxil_validate_skip_zig_tests:
                dxil_validate_command.append("--skip-zig-tests")
            run_gate("dxil-validate", dxil_validate_command)

        sync_gate_runs = (
            ("metal-sync", "metal", args.with_metal_sync_conformance_gate),
            ("vulkan-sync", "vulkan", args.with_vulkan_sync_conformance_gate),
        )
        for label, backend, enabled in sync_gate_runs:
            if not enabled:
                continue
            timing_policy_path = Path(args.backend_timing_policy)
            if not timing_policy_path.exists():
                print(f"FAIL: missing --backend-timing-policy: {timing_policy_path}")
                return 1
            run_gate(
                label,
                [
                    sys.executable,
                    str(sync_conformance_gate),
                    "--backend",
                    backend,
                    "--report",
                    str(report_path),
                    "--timing-policy",
                    str(timing_policy_path),
                ],
            )

        timing_gate_runs = (
            ("metal-timing-policy", "metal", args.with_metal_timing_policy_gate),
            ("vulkan-timing-policy", "vulkan", args.with_vulkan_timing_policy_gate),
        )
        for label, backend, enabled in timing_gate_runs:
            if not enabled:
                continue
            timing_policy_path = Path(args.backend_timing_policy)
            if not timing_policy_path.exists():
                print(f"FAIL: missing --backend-timing-policy: {timing_policy_path}")
                return 1
            run_gate(
                label,
                [
                    sys.executable,
                    str(timing_policy_gate),
                    "--backend",
                    backend,
                    "--report",
                    str(report_path),
                    "--timing-policy",
                    str(timing_policy_path),
                ],
            )

        if args.with_dropin_gate:
            if not args.dropin_artifact.strip():
                print("FAIL: --with-dropin-gate requires --dropin-artifact")
                return 1
            artifact_path = Path(args.dropin_artifact)
            if not artifact_path.exists():
                print(f"FAIL: missing --dropin-artifact: {artifact_path}")
                return 1
            dropin_report = output_paths.with_timestamp(
                args.dropin_report,
                output_timestamp,
                enabled=args.timestamp_output,
            )
            dropin_symbol_report = output_paths.with_timestamp(
                args.dropin_symbol_report,
                output_timestamp,
                enabled=args.timestamp_output,
            )
            dropin_behavior_report = output_paths.with_timestamp(
                args.dropin_behavior_report,
                output_timestamp,
                enabled=args.timestamp_output,
            )
            dropin_benchmark_report = output_paths.with_timestamp(
                args.dropin_benchmark_report,
                output_timestamp,
                enabled=args.timestamp_output,
            )
            dropin_benchmark_html = output_paths.with_timestamp(
                args.dropin_benchmark_html,
                output_timestamp,
                enabled=args.timestamp_output,
            )
            dropin_command = [
                sys.executable,
                str(dropin_gate),
                "--artifact",
                args.dropin_artifact,
                "--symbols",
                args.dropin_symbols,
                "--report",
                str(dropin_report),
                "--symbol-report",
                str(dropin_symbol_report),
                "--behavior-report",
                str(dropin_behavior_report),
                "--benchmark-report",
                str(dropin_benchmark_report),
                "--benchmark-html",
                str(dropin_benchmark_html),
                "--micro-iterations",
                str(args.dropin_micro_iterations),
                "--e2e-iterations",
                str(args.dropin_e2e_iterations),
            ]
            if args.timestamp_output:
                dropin_command.extend(["--timestamp", output_timestamp])
            else:
                dropin_command.append("--no-timestamp-output")
            if args.dropin_skip_benchmarks:
                dropin_command.append("--skip-benchmarks")
            if args.with_dropin_proc_resolution_gate:
                ownership_path = Path(args.dropin_symbol_ownership)
                if not ownership_path.exists():
                    print(f"FAIL: missing --dropin-symbol-ownership: {ownership_path}")
                    return 1
                dropin_command.extend(
                    [
                        "--with-proc-resolution-gate",
                        "--symbol-ownership",
                        str(ownership_path),
                    ]
                )
            run_gate("dropin", dropin_command)

        elif args.with_dropin_proc_resolution_gate:
            if not args.dropin_artifact.strip():
                print("FAIL: --with-dropin-proc-resolution-gate requires --dropin-artifact")
                return 1
            artifact_path = Path(args.dropin_artifact)
            if not artifact_path.exists():
                print(f"FAIL: missing --dropin-artifact: {artifact_path}")
                return 1
            ownership_path = Path(args.dropin_symbol_ownership)
            if not ownership_path.exists():
                print(f"FAIL: missing --dropin-symbol-ownership: {ownership_path}")
                return 1
            run_gate(
                "dropin-proc-resolution",
                [
                    sys.executable,
                    str(dropin_proc_resolution_tests),
                    "--artifact",
                    str(artifact_path),
                    "--ownership",
                    str(ownership_path),
                ],
            )

        if args.with_cts_baseline_gate:
            if not args.cts_baseline_snapshot.strip():
                print("FAIL: --with-cts-baseline-gate requires --cts-baseline-snapshot")
                return 1
            baseline_snapshot_path = Path(args.cts_baseline_snapshot)
            if not baseline_snapshot_path.exists():
                print(f"FAIL: missing --cts-baseline-snapshot: {baseline_snapshot_path}")
                return 1
            cts_compare_command = [
                sys.executable,
                str(cts_baseline_compare),
                "--baseline",
                str(baseline_snapshot_path),
                "--policy",
                args.cts_baseline_policy,
                "--gate",
            ]
            if args.cts_baseline_current.strip():
                cts_compare_command.extend(["--current", args.cts_baseline_current])
            else:
                cts_compare_command.extend(["--current-dir", "bench/out/cts-baseline"])
            run_gate("cts-baseline", cts_compare_command)

        if args.with_claim_gate:
            claim_report_path = artifacts_mod.claim_report_candidate_path(report_path)
            claim_build_command = [
                sys.executable,
                str(bench_cli),
                "claim",
                str(report_path),
                "--mode",
                args.claim_require_claimability_mode,
                "--min-timed-samples",
                str(args.claim_require_min_timed_samples),
                "--benchmark-policy",
                args.claim_benchmark_policy,
                "--out",
                str(claim_report_path),
            ]
            if args.claim_config.strip():
                claim_build_command.extend(["--config", args.claim_config.strip()])
            print(f"[gate] claim-report: {' '.join(claim_build_command)}", flush=True)
            claim_build_proc = subprocess.run(claim_build_command, check=False)
            if claim_build_proc.returncode not in (0, 2) or not claim_report_path.exists():
                raise subprocess.CalledProcessError(
                    claim_build_proc.returncode,
                    claim_build_command,
                )

            claim_command = [
                sys.executable,
                str(claim_gate),
                "--report",
                str(report_path),
                "--claim-report",
                str(claim_report_path),
                "--require-comparison-status",
                args.claim_require_comparison_status,
                "--require-claim-status",
                args.claim_require_claim_status,
                "--require-claimability-mode",
                args.claim_require_claimability_mode,
                "--require-min-timed-samples",
                str(args.claim_require_min_timed_samples),
            ]
            if args.claim_config.strip():
                claim_command.extend(["--config", args.claim_config.strip()])
            if args.claim_expected_workload_contract.strip():
                claim_command.extend(
                    [
                        "--expected-workload-contract",
                        args.claim_expected_workload_contract,
                    ]
                )
            if args.claim_require_workload_contract_hash:
                claim_command.append("--require-workload-contract-hash")
            if args.claim_require_workload_id_set_match:
                claim_command.append("--require-workload-id-set-match")
            if args.claim_require_backend_telemetry:
                claim_command.append("--require-backend-telemetry")
            if args.claim_expected_backend_id.strip():
                claim_command.extend(
                    ["--expected-backend-id", args.claim_expected_backend_id.strip()]
                )
            run_gate("claim", claim_command)
    except subprocess.CalledProcessError as exc:
        print(f"FAIL: gate command failed with return code {exc.returncode}")
        return exc.returncode

    print("PASS: blocking gate sequence completed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
