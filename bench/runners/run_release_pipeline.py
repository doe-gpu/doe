#!/usr/bin/env python3
"""Canonical release/smoke pipeline runner for benchmark + gates (drop-in optional)."""

from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
for _path_entry in (str(REPO_ROOT), str(BENCH_ROOT)):
    if _path_entry not in sys.path:
        sys.path.insert(0, _path_entry)


import argparse
import subprocess
import sys
from pathlib import Path
from typing import Any
from bench.lib import output_paths
from bench.lib.bench_utils import load_json_object as load_json
from bench.runners.release_pipeline_receipts import run_receipt_first_compare


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--config",
        default="bench/native-compare/compare.config.amd.vulkan.release.json",
        help="Compare-lane config path for this pipeline run.",
    )
    parser.add_argument(
        "--report",
        default="",
        help="Override report path. Defaults to run.out from --config.",
    )
    parser.add_argument(
        "--workspace",
        default="",
        help="Override workspace path. Defaults to run.workspace from --config.",
    )
    parser.add_argument(
        "--strict-amd-vulkan",
        action="store_true",
        help="Run strict AMD Vulkan host preflight before benchmark execution.",
    )
    parser.add_argument(
        "--with-local-metal-gates",
        action=argparse.BooleanOptionalAction,
        default=True,
        help=(
            "Run local-metal-specific blocking gates (backend selection/shader artifacts/"
            "sync/timing contracts) when a local-metal config is detected."
        ),
    )
    parser.add_argument(
        "--with-local-metal-preflight",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Run preflight_metal_host.py when a local-metal config is detected.",
    )
    parser.add_argument(
        "--local-metal-backend-policy",
        default="config/backend-runtime-policy.json",
        help="Backend runtime policy path for local-metal gate execution.",
    )
    parser.add_argument(
        "--local-metal-timing-policy",
        default="config/backend-timing-policy.json",
        help="Backend timing policy path for local-metal gate execution.",
    )
    parser.add_argument(
        "--local-metal-shader-artifact-schema",
        default="config/shader-artifact.schema.json",
        help="Shader artifact schema path for local-metal gate execution.",
    )
    parser.add_argument(
        "--local-metal-symbol-ownership",
        default="config/dropin-symbol-ownership.json",
        help="Drop-in symbol ownership contract passed to local-metal proc-resolution checks.",
    )
    parser.add_argument(
        "--local-metal-lane",
        default="",
        help="Optional local-metal lane override for local-metal gate execution.",
    )
    parser.add_argument(
        "--with-local-vulkan-gates",
        action=argparse.BooleanOptionalAction,
        default=True,
        help=(
            "Run local-vulkan-specific blocking gates (backend selection/shader artifacts/"
            "sync/timing contracts) when a local-vulkan config is detected."
        ),
    )
    parser.add_argument(
        "--with-local-vulkan-preflight",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Run preflight_vulkan_host.py when a local-vulkan config is detected.",
    )
    parser.add_argument(
        "--local-vulkan-backend-policy",
        default="config/backend-runtime-policy.json",
        help="Backend runtime policy path for local-vulkan gate execution.",
    )
    parser.add_argument(
        "--local-vulkan-timing-policy",
        default="config/backend-timing-policy.json",
        help="Backend timing policy path for local-vulkan gate execution.",
    )
    parser.add_argument(
        "--local-vulkan-shader-artifact-schema",
        default="config/shader-artifact.schema.json",
        help="Shader artifact schema path for local-vulkan gate execution.",
    )
    parser.add_argument(
        "--local-vulkan-symbol-ownership",
        default="config/dropin-symbol-ownership.json",
        help="Drop-in symbol ownership contract passed to local-vulkan proc-resolution checks.",
    )
    parser.add_argument(
        "--local-vulkan-lane",
        default="",
        help="Optional local-vulkan lane override for local-vulkan gate execution.",
    )
    parser.add_argument(
        "--verify-smoke-report",
        default="",
        help="Optional smoke report path to validate with verify_smoke_gpu_usage.py.",
    )
    parser.add_argument(
        "--verify-smoke-require-comparable",
        action="store_true",
        help="Pass --require-comparable to verify_smoke_gpu_usage.py.",
    )
    parser.add_argument(
        "--with-claim-gate",
        action="store_true",
        help="Run claim gate in addition to schema/correctness/trace gates.",
    )
    parser.add_argument(
        "--with-comparability-parity-gate",
        action="store_true",
        help=(
            "Run comparability_obligation_parity_gate.py in run_blocking_gates.py "
            "before correctness/trace."
        ),
    )
    parser.add_argument(
        "--trace-semantic-parity-mode",
        choices=["off", "auto", "required"],
        default="required",
        help="Semantic parity mode forwarded to trace gate execution.",
    )
    parser.add_argument(
        "--with-dropin-gate",
        action="store_true",
        help="Run drop-in compatibility gate in addition to schema/correctness/trace gates.",
    )
    parser.add_argument(
        "--dropin-artifact",
        default="runtime/zig/zig-out/lib/libwebgpu_doe.so",
        help="Shared library artifact path for drop-in gate when --with-dropin-gate is set.",
    )
    parser.add_argument(
        "--dropin-symbols",
        default="config/dropin_abi.symbols.txt",
        help="Required symbol list for drop-in gate.",
    )
    parser.add_argument(
        "--dropin-report",
        default="bench/out/dropin_report.json",
        help="Drop-in consolidated report path.",
    )
    parser.add_argument(
        "--dropin-symbol-report",
        default="bench/out/dropin_symbol_report.json",
        help="Drop-in symbol report path.",
    )
    parser.add_argument(
        "--dropin-behavior-report",
        default="bench/out/dropin_behavior_report.json",
        help="Drop-in behavior report path.",
    )
    parser.add_argument(
        "--dropin-benchmark-report",
        default="bench/out/dropin_benchmark_report.json",
        help="Drop-in benchmark report path.",
    )
    parser.add_argument(
        "--dropin-benchmark-html",
        default="bench/out/dropin_benchmark_report.html",
        help="Drop-in benchmark HTML path.",
    )
    parser.add_argument(
        "--dropin-micro-iterations",
        type=int,
        default=30,
        help="Micro benchmark iterations for drop-in gate.",
    )
    parser.add_argument(
        "--dropin-e2e-iterations",
        type=int,
        default=10,
        help="End-to-end benchmark iterations for drop-in gate.",
    )
    parser.add_argument(
        "--dropin-skip-benchmarks",
        action="store_true",
        help="Skip drop-in benchmark execution while still running symbol + behavior checks.",
    )
    parser.add_argument(
        "--compare-html-output",
        action=argparse.BooleanOptionalAction,
        default=False,
        help=(
            "Generate Dawn-vs-Doe visualization HTML from the compare report. "
            "Disabled by default; prefer the static bench JSON viewer."
        ),
    )
    parser.add_argument(
        "--compare-html-out",
        default="",
        help="Optional HTML output path override (default: report path with .html suffix).",
    )
    parser.add_argument(
        "--compare-analysis-out",
        default="",
        help=(
            "Optional distribution-analysis JSON path for visualize_dawn_vs_doe.py "
            "(default: disabled)."
        ),
    )
    parser.add_argument(
        "--claim-require-comparison-status",
        default="comparable",
        help="Required comparisonStatus for claim gate.",
    )
    parser.add_argument(
        "--claim-require-claim-status",
        default="claimable",
        help="Required claimStatus for claim gate.",
    )
    parser.add_argument(
        "--claim-require-claimability-mode",
        default="release",
        help="Required claimability mode for claim gate.",
    )
    parser.add_argument(
        "--claim-require-min-timed-samples",
        type=int,
        default=15,
        help="Minimum timed sample floor for claim gate.",
    )
    parser.add_argument(
        "--with-claim-rehearsal-artifacts",
        action=argparse.BooleanOptionalAction,
        default=True,
        help=(
            "Generate claim rehearsal artifacts (claim gate result, tail health, "
            "timing invariant audit, contract hash manifest) after gates. "
            "Enabled by default."
        ),
    )
    parser.add_argument(
        "--claim-rehearsal-prefix",
        default="",
        help=(
            "Optional output prefix for claim rehearsal artifacts. "
            "Defaults to <report-without-suffix>.claim-rehearsal."
        ),
    )
    parser.add_argument(
        "--with-cycle-gate",
        action=argparse.BooleanOptionalAction,
        default=True,
        help=(
            "Run cycle_gate.py for claim-lane cycle-lock/rollback enforcement after "
            "blocking gates (default: enabled)."
        ),
    )
    parser.add_argument(
        "--with-external-project-release-suite",
        action=argparse.BooleanOptionalAction,
        default=True,
        help=(
            "Run every promoted external-project harness after blocking gates. "
            "Enabled by default; zero promoted harnesses is valid until promotion occurs."
        ),
    )
    parser.add_argument(
        "--external-project-release-suite-out",
        default="bench/out/external-projects/release-suite.json",
        help="Output receipt for the promoted external-project release suite.",
    )
    parser.add_argument(
        "--cycle-contract",
        default="config/claim-cycle.active.json",
        help="Cycle contract path passed to cycle_gate.py.",
    )
    parser.add_argument(
        "--cycle-gate-out",
        default="bench/out/cycle_gate_report.json",
        help="Cycle-gate report output path.",
    )
    parser.add_argument(
        "--cycle-artifact-class",
        choices=["claim", "diagnostic"],
        default="claim",
        help="Artifact class passed to cycle_gate.py namespace policy checks.",
    )
    parser.add_argument(
        "--cycle-comparability-obligations",
        default="config/comparability-obligations.json",
        help="Comparability-obligation contract path passed to cycle_gate.py.",
    )
    parser.add_argument(
        "--cycle-substantiation-report",
        default="",
        help="Optional substantiation gate report path passed to cycle_gate.py.",
    )
    parser.add_argument(
        "--cycle-enforce-rollbacks",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Enforce enabled rollback criteria in cycle_gate.py (default: enabled).",
    )
    parser.add_argument(
        "--skip-preflight",
        action="store_true",
        help="Skip host preflight step.",
    )
    parser.add_argument(
        "--skip-compare",
        action="store_true",
        help="Skip compare-lane execution.",
    )
    parser.add_argument(
        "--skip-gates",
        action="store_true",
        help="Skip run_blocking_gates.py execution.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print commands without executing them.",
    )
    parser.add_argument(
        "--timestamp",
        default="",
        help=(
            "UTC suffix for artifact paths (YYYYMMDDTHHMMSSZ). "
            "Defaults to current UTC time when --timestamp-output is enabled."
        ),
    )
    parser.add_argument(
        "--timestamp-output",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Stamp compare/drop-in artifact paths with a UTC timestamp suffix.",
    )
    return parser.parse_args()


def resolve_report_path(config_path: Path, explicit_report: str) -> Path:
    if explicit_report:
        return Path(explicit_report)

    config_payload = load_json(config_path)
    run_payload = config_payload.get("run")
    if not isinstance(run_payload, dict):
        raise ValueError(f"invalid config {config_path}: missing object field run")
    out_value = run_payload.get("out")
    if not isinstance(out_value, str) or not out_value.strip():
        raise ValueError(f"invalid config {config_path}: missing non-empty run.out")
    return Path(out_value)


def resolve_workspace_path(config_path: Path, explicit_workspace: str) -> Path:
    if explicit_workspace:
        return Path(explicit_workspace)

    config_payload = load_json(config_path)
    run_payload = config_payload.get("run")
    if not isinstance(run_payload, dict):
        raise ValueError(f"invalid config {config_path}: missing object field run")
    workspace_value = run_payload.get("workspace")
    if not isinstance(workspace_value, str) or not workspace_value.strip():
        raise ValueError(f"invalid config {config_path}: missing non-empty run.workspace")
    return Path(workspace_value)


def resolve_workloads_contract_path(config_path: Path) -> Path:
    config_payload = load_json(config_path)
    workloads_value = config_payload.get("workloads")
    if not isinstance(workloads_value, str) or not workloads_value.strip():
        raise ValueError(f"invalid config {config_path}: missing non-empty workloads path")
    candidate = Path(workloads_value)
    if candidate.is_absolute():
        return candidate
    repo_root = REPO_ROOT
    repo_relative = (repo_root / candidate).resolve()
    if repo_relative.exists():
        return repo_relative
    config_relative = (config_path.parent / candidate).resolve()
    if config_relative.exists():
        return config_relative
    return repo_relative


def is_apple_metal_config(config_path: Path) -> bool:
    config_name = str(config_path).lower()
    return ".apple.metal" in config_name or ".local.metal" in config_name


def is_amd_vulkan_config(config_path: Path) -> bool:
    config_name = str(config_path).lower()
    return ".amd.vulkan" in config_name or ".local.vulkan" in config_name


def infer_apple_metal_lane(config_path: Path, explicit_lane: str) -> str:
    if explicit_lane.strip():
        return explicit_lane.strip()
    config_name = str(config_path).lower()
    if ".apple.metal.dawn" in config_name or ".local.metal.dawn" in config_name or ".metal.dawn" in config_name:
        return "metal_dawn_release"
    if ".apple.metal.release" in config_name or ".local.metal.release" in config_name:
        return "metal_doe_release"
    if ".apple.metal.directional" in config_name or ".local.metal.directional" in config_name:
        return "metal_doe_directional"
    if (
        ".apple.metal.extended" in config_name
        or ".apple.metal.comparable" in config_name
        or ".local.metal.extended" in config_name
        or ".local.metal.comparable" in config_name
    ):
        return "metal_doe_comparable"
    if "metal_doe_app" in config_name or "metal_doe_app" in config_name or "metal-doe-app" in config_name:
        return "metal_doe_app"
    return ""


def infer_amd_vulkan_lane(config_path: Path, explicit_lane: str) -> str:
    if explicit_lane.strip():
        return explicit_lane.strip()
    config_name = str(config_path).lower()
    if (
        ".amd.vulkan.release" in config_name
        or ".amd.vulkan.extended.strict.release" in config_name
        or ".local.vulkan.release" in config_name
    ):
        return "vulkan_doe_release"
    if (
        ".amd.vulkan.directional" in config_name
        or ".amd.vulkan.macro.directional" in config_name
        or ".amd.vulkan.extended.strict.directional" in config_name
        or ".local.vulkan.directional" in config_name
    ):
        return "vulkan_doe_app"
    if (
        ".amd.vulkan.comparable" in config_name
        or ".amd.vulkan.extended.comparable" in config_name
        or ".amd.vulkan.extended.strict.comparable" in config_name
        or ".amd.vulkan.superset.comparable" in config_name
        or ".local.vulkan.extended" in config_name
        or ".local.vulkan.comparable" in config_name
    ):
        return "vulkan_doe_comparable"
    return ""


def apple_metal_requires_shader_manifest(lane: str) -> bool:
    if not lane:
        return False
    strict_lanes = {"metal_doe_comparable", "metal_doe_release", "metal_doe_app"}
    return lane in strict_lanes


def amd_vulkan_requires_shader_manifest(lane: str) -> bool:
    if not lane:
        return False
    strict_lanes = {"vulkan_doe_comparable", "vulkan_doe_release"}
    return lane in strict_lanes


def run_step(label: str, command: list[str], *, dry_run: bool) -> None:
    print(f"[pipeline] {label}: {' '.join(command)}", flush=True)
    if dry_run:
        return
    subprocess.run(command, check=True)


def main() -> int:
    args = parse_args()

    if args.claim_require_min_timed_samples < 0:
        print(
            "FAIL: invalid --claim-require-min-timed-samples="
            f"{args.claim_require_min_timed_samples} expected >= 0"
        )
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

    config_path = Path(args.config)
    if not config_path.exists():
        print(f"FAIL: missing config: {config_path}")
        return 1
    if args.with_dropin_gate and not args.dropin_artifact.strip():
        print("FAIL: --with-dropin-gate requires --dropin-artifact")
        return 1
    if args.with_dropin_gate and not args.dry_run:
        artifact_path = Path(args.dropin_artifact)
        if not artifact_path.exists():
            print(f"FAIL: missing --dropin-artifact: {artifact_path}")
            return 1
    is_apple_metal = is_apple_metal_config(config_path)
    is_amd_vulkan = is_amd_vulkan_config(config_path)
    apple_metal_lane = infer_apple_metal_lane(config_path, args.local_metal_lane) if is_apple_metal else ""
    amd_vulkan_lane = (
        infer_amd_vulkan_lane(config_path, args.local_vulkan_lane)
        if is_amd_vulkan
        else ""
    )
    if is_apple_metal and args.with_local_metal_gates:
        local_runtime_policy_path = Path(args.local_metal_backend_policy)
        local_timing_policy_path = Path(args.local_metal_timing_policy)
        local_shader_schema_path = Path(args.local_metal_shader_artifact_schema)
        if not local_runtime_policy_path.exists():
            print(f"FAIL: missing --local-metal-backend-policy: {local_runtime_policy_path}")
            return 1
        if not local_timing_policy_path.exists():
            print(f"FAIL: missing --local-metal-timing-policy: {local_timing_policy_path}")
            return 1
        if not local_shader_schema_path.exists():
            print(
                f"FAIL: missing --local-metal-shader-artifact-schema: {local_shader_schema_path}"
            )
            return 1
        if args.with_local_metal_gates and not apple_metal_lane:
            print(
                "FAIL: unable to infer apple-metal lane from --config. "
                "Set --local-metal-lane explicitly."
            )
            return 1
    if is_amd_vulkan and args.with_local_vulkan_gates:
        local_runtime_policy_path = Path(args.local_vulkan_backend_policy)
        local_timing_policy_path = Path(args.local_vulkan_timing_policy)
        local_shader_schema_path = Path(args.local_vulkan_shader_artifact_schema)
        if not local_runtime_policy_path.exists():
            print(f"FAIL: missing --local-vulkan-backend-policy: {local_runtime_policy_path}")
            return 1
        if not local_timing_policy_path.exists():
            print(f"FAIL: missing --local-vulkan-timing-policy: {local_timing_policy_path}")
            return 1
        if not local_shader_schema_path.exists():
            print(
                f"FAIL: missing --local-vulkan-shader-artifact-schema: {local_shader_schema_path}"
            )
            return 1
        if args.with_local_vulkan_gates and not amd_vulkan_lane:
            print(
                "FAIL: unable to infer AMD Vulkan lane from --config. "
                "Set --local-vulkan-lane explicitly."
            )
            return 1
    if is_apple_metal and args.with_local_metal_gates and args.with_dropin_gate:
        local_symbol_ownership_path = Path(args.local_metal_symbol_ownership)
        if not local_symbol_ownership_path.exists():
            print(
                f"FAIL: missing --local-metal-symbol-ownership: {local_symbol_ownership_path}"
            )
            return 1
    if is_amd_vulkan and args.with_local_vulkan_gates and args.with_dropin_gate:
        local_symbol_ownership_path = Path(args.local_vulkan_symbol_ownership)
        if not local_symbol_ownership_path.exists():
            print(
                f"FAIL: missing --local-vulkan-symbol-ownership: {local_symbol_ownership_path}"
            )
            return 1
    cycle_contract_path = Path(args.cycle_contract)
    cycle_obligations_path = Path(args.cycle_comparability_obligations)
    if (
        args.with_cycle_gate
        and args.with_claim_gate
        and not args.skip_gates
        and not args.dry_run
        and not cycle_contract_path.exists()
    ):
        print(
            "FAIL: --with-cycle-gate requires --cycle-contract to exist in claim lanes: "
            f"{cycle_contract_path}"
        )
        return 1
    if (
        args.with_cycle_gate
        and args.with_claim_gate
        and not args.skip_gates
        and not args.dry_run
        and not cycle_obligations_path.exists()
    ):
        print(
            "FAIL: --with-cycle-gate requires --cycle-comparability-obligations to exist in claim lanes: "
            f"{cycle_obligations_path}"
        )
        return 1
    if (
        args.with_cycle_gate
        and args.with_claim_gate
        and not args.skip_gates
        and not args.dry_run
        and args.cycle_substantiation_report.strip()
        and not Path(args.cycle_substantiation_report.strip()).exists()
    ):
        print(
            "FAIL: --cycle-substantiation-report path does not exist: "
            f"{args.cycle_substantiation_report.strip()}"
        )
        return 1

    raw_report_path = resolve_report_path(config_path, args.report)
    raw_workspace_path = resolve_workspace_path(config_path, args.workspace)
    workloads_contract_path = resolve_workloads_contract_path(config_path)
    if args.with_claim_gate and not args.dry_run and not workloads_contract_path.exists():
        print(
            "FAIL: --with-claim-gate requires workload contract from config to exist: "
            f"{workloads_contract_path}"
        )
        return 1
    output_timestamp = (
        output_paths.resolve_timestamp(args.timestamp)
        if args.timestamp_output
        else ""
    )
    run_group = output_paths.derive_bench_out_group(raw_report_path)
    report_path = output_paths.with_timestamp(
        raw_report_path,
        output_timestamp,
        enabled=args.timestamp_output,
        group=run_group,
    )
    workspace_path = output_paths.with_timestamp(
        raw_workspace_path,
        output_timestamp,
        enabled=args.timestamp_output,
        group=run_group,
    )
    cycle_gate_report_path = output_paths.with_timestamp(
        Path(args.cycle_gate_out),
        output_timestamp,
        enabled=args.timestamp_output,
        group=run_group,
    )
    if args.compare_html_out.strip():
        compare_html_path = output_paths.with_timestamp(
            Path(args.compare_html_out.strip()),
            output_timestamp,
            enabled=args.timestamp_output,
            group=run_group,
        )
    else:
        compare_html_path = report_path.with_suffix(".html")
    compare_analysis_path: Path | None = None
    if args.compare_analysis_out.strip():
        compare_analysis_path = output_paths.with_timestamp(
            Path(args.compare_analysis_out.strip()),
            output_timestamp,
            enabled=args.timestamp_output,
            group=run_group,
        )

    runners_dir = BENCH_ROOT / "runners"
    gates_dir = BENCH_ROOT / "gates"
    tools_dir = BENCH_ROOT / "tools"
    compare_dir = BENCH_ROOT / "native-compare"
    python_exe = sys.executable
    preflight = runners_dir / "preflight_bench_host.py"
    preflight_metal = runners_dir / "preflight_metal_host.py"
    preflight_vulkan = runners_dir / "preflight_vulkan_host.py"
    compare = BENCH_ROOT / "cli.py"
    visualize = compare_dir / "visualize_dawn_vs_doe.py"
    smoke_verify = gates_dir / "verify_smoke_gpu_usage.py"
    gates = runners_dir / "run_blocking_gates.py"
    external_project_release_suite = (
        runners_dir / "run_external_project_release_suite.py"
    )
    claim_rehearsal = tools_dir / "build_claim_rehearsal_artifacts.py"
    cycle_gate = gates_dir / "cycle_gate.py"
    preflight_ran = False
    compare_ran = False
    compare_html_ran = False
    smoke_verify_ran = False
    gates_ran = False
    external_project_release_suite_ran = False
    claim_rehearsal_ran = False
    cycle_gate_ran = False
    claim_rehearsal_manifest_path: Path | None = None
    current_step = ""

    try:
        if args.strict_amd_vulkan and not args.skip_preflight:
            preflight_ran = True
            current_step = "preflight"
            run_step(
                "preflight",
                [python_exe, str(preflight), "--strict-amd-vulkan"],
                dry_run=args.dry_run,
            )
        if is_apple_metal and args.with_local_metal_preflight and not args.skip_preflight:
            preflight_ran = True
            current_step = "preflight-metal"
            run_step(
                "preflight-metal",
                [python_exe, str(preflight_metal)],
                dry_run=args.dry_run,
            )
        if is_amd_vulkan and args.with_local_vulkan_preflight and not args.skip_preflight:
            preflight_ran = True
            current_step = "preflight-vulkan"
            run_step(
                "preflight-vulkan",
                [python_exe, str(preflight_vulkan)],
                dry_run=args.dry_run,
            )

        if not args.skip_compare:
            compare_ran = True
            current_step = "compare"
            run_receipt_first_compare(
                python_exe=python_exe,
                compare=compare,
                config_path=config_path,
                report_path=report_path,
                workspace_path=workspace_path,
                output_timestamp=output_timestamp,
                timestamp_output=args.timestamp_output,
                dry_run=args.dry_run,
            )
        if args.compare_html_output:
            compare_html_ran = True
            current_step = "visualize"
            visualize_cmd = [
                python_exe,
                str(visualize),
                "--report",
                str(report_path),
                "--out",
                str(compare_html_path),
            ]
            if compare_analysis_path is not None:
                visualize_cmd.extend(["--analysis-out", str(compare_analysis_path)])
            run_step("visualize", visualize_cmd, dry_run=args.dry_run)

        if args.verify_smoke_report:
            smoke_verify_ran = True
            current_step = "verify-smoke"
            smoke_report_path = Path(args.verify_smoke_report)
            if args.timestamp_output and smoke_report_path == raw_report_path:
                smoke_report_path = report_path
            verify_cmd = [
                python_exe,
                str(smoke_verify),
                "--report",
                str(smoke_report_path),
            ]
            if args.verify_smoke_require_comparable:
                verify_cmd.append("--require-comparable")
            run_step("verify-smoke", verify_cmd, dry_run=args.dry_run)

        if not args.skip_gates:
            gates_ran = True
            current_step = "gates"
            gates_cmd = [python_exe, str(gates), "--report", str(report_path)]
            gates_cmd.extend(["--trace-semantic-parity-mode", args.trace_semantic_parity_mode])
            if args.with_comparability_parity_gate:
                gates_cmd.append("--with-comparability-parity-gate")
            if args.timestamp_output:
                gates_cmd.extend(["--timestamp", output_timestamp])
            else:
                gates_cmd.append("--no-timestamp-output")
            if is_apple_metal and args.with_local_metal_gates:
                gates_cmd.extend(
                    [
                        "--with-backend-selection-gate",
                        "--backend-runtime-policy",
                        args.local_metal_backend_policy,
                        "--backend-selection-lane",
                        apple_metal_lane,
                        "--with-shader-artifact-gate",
                        "--shader-artifact-schema",
                        args.local_metal_shader_artifact_schema,
                        "--with-metal-sync-conformance-gate",
                        "--with-metal-timing-policy-gate",
                        "--backend-timing-policy",
                        args.local_metal_timing_policy,
                    ]
                )
                if apple_metal_requires_shader_manifest(apple_metal_lane):
                    gates_cmd.append("--shader-artifact-require-manifest")
                if args.with_dropin_gate:
                    gates_cmd.extend(
                        [
                            "--with-dropin-proc-resolution-gate",
                            "--dropin-symbol-ownership",
                            args.local_metal_symbol_ownership,
                        ]
                    )
            if is_amd_vulkan and args.with_local_vulkan_gates:
                gates_cmd.extend(
                    [
                        "--with-backend-selection-gate",
                        "--backend-runtime-policy",
                        args.local_vulkan_backend_policy,
                        "--backend-selection-lane",
                        amd_vulkan_lane,
                        "--with-shader-artifact-gate",
                        "--shader-artifact-schema",
                        args.local_vulkan_shader_artifact_schema,
                        "--with-vulkan-sync-conformance-gate",
                        "--with-vulkan-timing-policy-gate",
                        "--backend-timing-policy",
                        args.local_vulkan_timing_policy,
                    ]
                )
                if amd_vulkan_requires_shader_manifest(amd_vulkan_lane):
                    gates_cmd.append("--shader-artifact-require-manifest")
                if args.with_dropin_gate:
                    gates_cmd.extend(
                        [
                            "--with-dropin-proc-resolution-gate",
                            "--dropin-symbol-ownership",
                            args.local_vulkan_symbol_ownership,
                        ]
                    )
            if args.with_dropin_gate:
                gates_cmd.extend(
                    [
                        "--with-dropin-gate",
                        "--dropin-artifact",
                        args.dropin_artifact,
                        "--dropin-symbols",
                        args.dropin_symbols,
                        "--dropin-report",
                        args.dropin_report,
                        "--dropin-symbol-report",
                        args.dropin_symbol_report,
                        "--dropin-behavior-report",
                        args.dropin_behavior_report,
                        "--dropin-benchmark-report",
                        args.dropin_benchmark_report,
                        "--dropin-benchmark-html",
                        args.dropin_benchmark_html,
                        "--dropin-micro-iterations",
                        str(args.dropin_micro_iterations),
                        "--dropin-e2e-iterations",
                        str(args.dropin_e2e_iterations),
                    ]
                )
                if args.dropin_skip_benchmarks:
                    gates_cmd.append("--dropin-skip-benchmarks")
            if args.with_claim_gate:
                gates_cmd.extend(
                    [
                        "--with-claim-gate",
                        "--claim-require-comparison-status",
                        args.claim_require_comparison_status,
                        "--claim-require-claim-status",
                        args.claim_require_claim_status,
                        "--claim-require-claimability-mode",
                        args.claim_require_claimability_mode,
                        "--claim-require-min-timed-samples",
                        str(args.claim_require_min_timed_samples),
                        "--claim-config",
                        str(config_path),
                        "--claim-expected-workload-contract",
                        str(workloads_contract_path),
                        "--claim-require-workload-contract-hash",
                        "--claim-require-workload-id-set-match",
                    ]
                )
                if (
                    is_apple_metal
                    and args.with_local_metal_gates
                    and apple_metal_requires_shader_manifest(apple_metal_lane)
                ):
                    gates_cmd.extend(
                        [
                            "--claim-require-backend-telemetry",
                            "--claim-expected-backend-id",
                            "doe_metal",
                        ]
                    )
                if (
                    is_amd_vulkan
                    and args.with_local_vulkan_gates
                    and amd_vulkan_requires_shader_manifest(amd_vulkan_lane)
                ):
                    gates_cmd.extend(
                        [
                            "--claim-require-backend-telemetry",
                            "--claim-expected-backend-id",
                            "doe_vulkan",
                        ]
                    )
            run_step("gates", gates_cmd, dry_run=args.dry_run)

        if (
            args.with_external_project_release_suite
            and gates_ran
        ):
            external_project_release_suite_ran = True
            current_step = "external-project-release-suite"
            run_step(
                "external-project-release-suite",
                [
                    python_exe,
                    str(external_project_release_suite),
                    "--out",
                    args.external_project_release_suite_out,
                ],
                dry_run=args.dry_run,
            )

        if args.with_claim_rehearsal_artifacts and args.with_claim_gate and gates_ran:
            claim_rehearsal_ran = True
            current_step = "claim-rehearsal-artifacts"
            rehearsal_cmd = [
                python_exe,
                str(claim_rehearsal),
                "--report",
                str(report_path),
                "--require-comparison-status",
                args.claim_require_comparison_status,
                "--require-claim-status",
                args.claim_require_claim_status,
                "--require-claimability-mode",
                args.claim_require_claimability_mode,
                "--require-min-timed-samples",
                str(args.claim_require_min_timed_samples),
                "--expected-workload-contract",
                str(workloads_contract_path),
            ]
            rehearsal_cmd.extend(["--config", str(config_path)])
            if args.claim_rehearsal_prefix.strip():
                claim_rehearsal_prefix = output_paths.with_timestamp(
                    Path(args.claim_rehearsal_prefix.strip()),
                    output_timestamp,
                    enabled=args.timestamp_output,
                    group=run_group,
                )
                rehearsal_cmd.extend(["--out-prefix", str(claim_rehearsal_prefix)])
                claim_rehearsal_manifest_path = Path(
                    f"{claim_rehearsal_prefix}.manifest.json"
                )
            else:
                claim_rehearsal_manifest_path = Path(
                    f"{report_path.with_suffix('')}.claim-rehearsal.manifest.json"
                )
            rehearsal_cmd.append(
                "--require-workload-contract-hash"
            )
            rehearsal_cmd.append(
                "--require-workload-id-set-match"
            )
            run_step(
                "claim-rehearsal-artifacts",
                rehearsal_cmd,
                dry_run=args.dry_run,
            )

        if args.with_cycle_gate and args.with_claim_gate and gates_ran:
            cycle_gate_ran = True
            current_step = "cycle-gate"
            cycle_cmd = [
                python_exe,
                str(cycle_gate),
                "--cycle",
                args.cycle_contract,
                "--report",
                str(report_path),
                "--artifact-class",
                args.cycle_artifact_class,
                "--comparability-obligations",
                args.cycle_comparability_obligations,
                "--out",
                args.cycle_gate_out,
            ]
            if args.cycle_substantiation_report.strip():
                cycle_cmd.extend(
                    [
                        "--substantiation-report",
                        args.cycle_substantiation_report.strip(),
                    ]
                )
            if args.timestamp_output:
                cycle_cmd.extend(["--timestamp", output_timestamp])
            else:
                cycle_cmd.append("--no-timestamp-output")
            if not args.cycle_enforce_rollbacks:
                cycle_cmd.append("--no-enforce-rollbacks")
            run_step("cycle-gate", cycle_cmd, dry_run=args.dry_run)
    except subprocess.CalledProcessError as exc:
        print(f"FAIL: pipeline step failed with return code {exc.returncode}")
        if not args.dry_run:
            manifest_payload: dict[str, Any] = {
                "runType": "release_pipeline",
                "config": str(config_path),
                "localMetal": is_apple_metal,
                "localMetalLane": apple_metal_lane if is_apple_metal else "",
                "localVulkan": is_amd_vulkan,
                "localVulkanLane": amd_vulkan_lane if is_amd_vulkan else "",
                "fullRun": (
                    (not args.skip_compare)
                    and (not args.skip_gates)
                    and (
                        (
                            not (
                                args.strict_amd_vulkan
                                or (is_apple_metal and args.with_local_metal_preflight)
                                or (is_amd_vulkan and args.with_local_vulkan_preflight)
                            )
                        )
                        or (not args.skip_preflight)
                    )
                ),
                "claimGateRan": bool(args.with_claim_gate and gates_ran),
                "dropinGateRan": bool(args.with_dropin_gate and gates_ran),
                "compareHtmlRan": bool(compare_html_ran),
                "preflightRan": preflight_ran,
                "compareRan": compare_ran,
                "gatesRan": gates_ran,
                "externalProjectReleaseSuiteRan": external_project_release_suite_ran,
                "smokeVerifyRan": smoke_verify_ran,
                "claimRehearsalRan": claim_rehearsal_ran,
                "cycleGateRan": cycle_gate_ran,
                "reportPath": str(report_path),
                "workspacePath": str(workspace_path),
                "compareHtmlPath": str(compare_html_path) if args.compare_html_output else "",
                "compareAnalysisPath": (
                    str(compare_analysis_path) if compare_analysis_path is not None else ""
                ),
                "cycleGateReportPath": (
                    str(cycle_gate_report_path) if cycle_gate_ran else ""
                ),
                "claimRehearsalManifestPath": (
                    str(claim_rehearsal_manifest_path)
                    if claim_rehearsal_manifest_path is not None
                    else ""
                ),
                "status": "failed",
                "failedStep": current_step or "unknown",
            }
            manifest_outputs: list[str | Path] = [
                report_path,
                workspace_path,
                compare_html_path,
            ]
            if claim_rehearsal_manifest_path is not None:
                manifest_outputs.append(claim_rehearsal_manifest_path)
            if cycle_gate_ran:
                manifest_outputs.append(cycle_gate_report_path)
        output_paths.write_run_manifest_for_outputs(
            manifest_outputs,
            manifest_payload,
        )
        sys.exit(exc.returncode)

    if not args.dry_run:
        manifest_payload = {
            "runType": "release_pipeline",
                "config": str(config_path),
                "localMetal": is_apple_metal,
                "localMetalLane": apple_metal_lane if is_apple_metal else "",
                "localVulkan": is_amd_vulkan,
                "localVulkanLane": amd_vulkan_lane if is_amd_vulkan else "",
                "fullRun": (
                    (not args.skip_compare)
                    and (not args.skip_gates)
                    and (
                        (
                            not (
                                args.strict_amd_vulkan
                                or (is_apple_metal and args.with_local_metal_preflight)
                                or (is_amd_vulkan and args.with_local_vulkan_preflight)
                            )
                        )
                        or (not args.skip_preflight)
                    )
                ),
            "claimGateRan": bool(args.with_claim_gate and gates_ran),
            "dropinGateRan": bool(args.with_dropin_gate and gates_ran),
            "compareHtmlRan": bool(compare_html_ran),
            "preflightRan": preflight_ran,
            "compareRan": compare_ran,
            "gatesRan": gates_ran,
            "externalProjectReleaseSuiteRan": external_project_release_suite_ran,
            "smokeVerifyRan": smoke_verify_ran,
            "claimRehearsalRan": claim_rehearsal_ran,
            "cycleGateRan": cycle_gate_ran,
            "reportPath": str(report_path),
            "workspacePath": str(workspace_path),
            "compareHtmlPath": str(compare_html_path) if args.compare_html_output else "",
            "compareAnalysisPath": (
                str(compare_analysis_path) if compare_analysis_path is not None else ""
            ),
            "cycleGateReportPath": str(cycle_gate_report_path) if cycle_gate_ran else "",
            "claimRehearsalManifestPath": (
                str(claim_rehearsal_manifest_path)
                if claim_rehearsal_manifest_path is not None
                else ""
            ),
            "status": "passed",
            "failedStep": "",
        }
        manifest_outputs: list[str | Path] = [report_path, workspace_path, compare_html_path]
        if claim_rehearsal_manifest_path is not None:
            manifest_outputs.append(claim_rehearsal_manifest_path)
        if cycle_gate_ran:
            manifest_outputs.append(cycle_gate_report_path)
        output_paths.write_run_manifest_for_outputs(
            manifest_outputs,
            manifest_payload,
        )

    print("PASS: release pipeline completed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
