#!/usr/bin/env python3
"""Run the non-hardware CSL smoke lane for compile/run/parity contract prep."""

from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
for _path_entry in (str(REPO_ROOT), str(BENCH_ROOT)):
    if _path_entry not in sys.path:
        sys.path.insert(0, _path_entry)


import argparse
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from bench.lib import output_paths
from bench.lib.bench_utils import load_json_object as load_json
from bench.lib.bench_utils import write_json_object as write_json
from native_compare_modules import contracts as contract

REPO_ROOT = Path(__file__).resolve().parents[2]
RUNTIME_ZIG_DIR = REPO_ROOT / "runtime" / "zig"
BUNDLE_EMITTER = RUNTIME_ZIG_DIR / "zig-out" / "bin" / "doe-csl-bundle-emitter"
SIM_RUNNER = RUNTIME_ZIG_DIR / "zig-out" / "bin" / "doe-csl-sim-runner"
SIM_PLAN_SCHEMA = REPO_ROOT / "config" / "doe-wgsl-simulator-plan.schema.json"
SIM_TRACE_SCHEMA = REPO_ROOT / "config" / "doe-wgsl-simulator-trace.schema.json"
SIM_DRIVER_RESULT_SCHEMA = REPO_ROOT / "config" / "doe-wgsl-simulator-driver-result.schema.json"
LANE_REPORT_SCHEMA = REPO_ROOT / "config" / "csl-governed-lane-report.schema.json"
CSL_GATE = REPO_ROOT / "bench" / "csl_simulator_gate.py"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="bench/csl_smoke_lane.gelu.json")
    parser.add_argument("--report", default="")
    parser.add_argument("--timestamp", default="")
    parser.add_argument("--timestamp-output", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--with-gate", action="store_true")
    parser.add_argument("--require-ready", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def run_step(name: str, command: list[str], *, cwd: Path, dry_run: bool) -> int:
    print(f"[{name}] {' '.join(command)}", flush=True)
    if dry_run:
        return 0
    proc = subprocess.run(command, cwd=cwd, check=False)
    return proc.returncode


def phase(status: str, reason: str) -> dict[str, str]:
    return {"status": status, "reason": reason}


def resolve_zig_executable() -> str:
    for candidate in (
        shutil.which("zig"),
        "/opt/homebrew/bin/zig",
        "/opt/homebrew/Cellar/zig/0.15.2/bin/zig",
    ):
        if candidate and Path(candidate).exists():
            return candidate
    return "zig"


def main() -> int:
    args = parse_args()
    config_path = (REPO_ROOT / args.config).resolve()
    config = load_json(config_path)
    zig_executable = resolve_zig_executable()

    report_target = Path(args.report) if args.report.strip() else Path(str(config["reportPath"]))
    report_path = output_paths.with_timestamp(
        REPO_ROOT / report_target,
        output_paths.resolve_timestamp(args.timestamp) if args.timestamp_output else "",
        enabled=args.timestamp_output,
        group="csl-simulator",
    )
    run_dir = report_path.parent
    compile_root = run_dir / "compile"
    kernel_name = str(config.get("kernelName", "kernel"))
    bundle_dir = compile_root / kernel_name
    stdout_path = run_dir / "stdout.log"
    stderr_path = run_dir / "stderr.log"
    trace_path = run_dir / "simulator-trace.json"
    result_path = run_dir / "simulator-result.json"
    driver_result_path = run_dir / f"{trace_path.name}.driver-result.json"
    simulator_plan_path = run_dir / "simulator-plan.json"
    host_plan_copy = run_dir / "host-plan.json"
    runtime_config_copy = run_dir / "runtime-config.json"

    wgsl_path = (REPO_ROOT / str(config["wgslPath"])).resolve()
    host_plan_path = (REPO_ROOT / str(config["hostPlanArtifactPath"])).resolve()
    runtime_config_path = (REPO_ROOT / str(config["runtimeConfigPath"])).resolve()
    driver_path = (REPO_ROOT / str(config["driverExecutable"])).resolve()

    phases = {
        "translate": phase("not-run", "translation not started"),
        "compile": phase("not-run", "compile not started"),
        "runtime": phase("not-run", "runtime not started"),
        "parity": phase("not-run", "parity not started"),
    }

    if not BUNDLE_EMITTER.exists():
        if run_step("build-bundle-emitter", [zig_executable, "build", "csl-bundle-emitter"], cwd=RUNTIME_ZIG_DIR, dry_run=args.dry_run) != 0:
            phases["translate"] = phase("failed", "zig build csl-bundle-emitter failed")
    if phases["translate"]["status"] == "not-run" and not SIM_RUNNER.exists():
        if run_step("build-sim-runner", [zig_executable, "build", "csl-sim-runner"], cwd=RUNTIME_ZIG_DIR, dry_run=args.dry_run) != 0:
            phases["translate"] = phase("failed", "zig build csl-sim-runner failed")
    if phases["translate"]["status"] == "not-run" and run_step(
        "emit-bundle",
        [str(BUNDLE_EMITTER), "--wgsl", str(wgsl_path), "--out-dir", str(bundle_dir)],
        cwd=RUNTIME_ZIG_DIR,
        dry_run=args.dry_run,
    ) != 0:
        phases["translate"] = phase("failed", "doe-csl-bundle-emitter failed")
    elif phases["translate"]["status"] == "not-run":
        phases["translate"] = phase("passed", "WGSL smoke kernel emitted into a CSL bundle")

    driver_result_payload: dict[str, Any]
    simulation_result_payload: dict[str, Any] = {}

    if phases["translate"]["status"] == "passed" and not args.dry_run:
        run_dir.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(host_plan_path, host_plan_copy)
        shutil.copyfile(runtime_config_path, runtime_config_copy)
        simulator_plan = {
            "schemaVersion": 1,
            "artifactKind": "csl_simulator_plan",
            "target": str(config.get("target", "wse3")),
            "contract": "explicit_simulator_launch",
            "driver": {
                "protocol": "doe.csl.simulator/v1",
                "executableEnvVar": "DOE_CSL_SIM_EXECUTABLE",
                "failClosedIfMissing": True,
            },
            "inputs": {
                "hostPlanArtifactPath": host_plan_copy.name,
                "runtimeConfigPath": runtime_config_copy.name,
                "compileRootPath": compile_root.name,
                "compileTargets": [
                    {
                        "name": kernel_name,
                        "layout": f"{kernel_name}/layout.csl",
                        "peProgram": f"{kernel_name}/pe_program.csl",
                    }
                ],
            },
            "runtime": {
                "peGrid": config["peGrid"],
                "prefillLaunchCount": 0,
                "decodeLaunchCount": 0,
                "weightMappingCount": 0,
                "stateBufferCount": 0,
                "maxDecodeTokens": 0,
                "timeoutMs": int(config.get("timeoutMs", 30000)),
                "batchSize": 1,
                "eosTokenId": None,
            },
            "outputs": {
                "stdoutPath": stdout_path.name,
                "stderrPath": stderr_path.name,
                "tracePath": trace_path.name,
            },
        }
        write_json(simulator_plan_path, simulator_plan)

        plan_errors = contract.validate_artifact(simulator_plan_path, contract.load_schema(SIM_PLAN_SCHEMA))
        if plan_errors:
            phases["compile"] = phase("failed", "; ".join(plan_errors))
            phases["runtime"] = phase("not-run", "compile unavailable")
            phases["parity"] = phase("not-run", "trace unavailable")
            driver_result_payload = {
                "schemaVersion": 1,
                "artifactKind": "csl_simulator_driver_result",
                "target": str(config.get("target", "wse3")),
                "contract": "explicit_driver_outcome",
                "simulatorPlanPath": str(simulator_plan_path),
                "compilerExecutable": None,
                "runtimeConfigPath": str(runtime_config_copy),
                "compile": {"attempted": False, "status": "failed", "reason": "; ".join(plan_errors), "targets": []},
                "run": {
                    "attempted": False,
                    "status": "blocked",
                    "reason": "compile_not_ready",
                    "tracePath": str(trace_path),
                    "traceProduced": False,
                    "stdoutPath": str(stdout_path),
                    "stderrPath": str(stderr_path),
                },
            }
            write_json(driver_result_path, driver_result_payload)
        else:
            runner_proc = subprocess.run(
                [
                    str(SIM_RUNNER),
                    "--plan",
                    str(simulator_plan_path),
                    "--driver-executable",
                    str(driver_path),
                    "--result-json",
                    str(result_path),
                ],
                cwd=REPO_ROOT,
                check=False,
            )
            driver_result_payload = load_json(driver_result_path) if driver_result_path.exists() else {
                "schemaVersion": 1,
                "artifactKind": "csl_simulator_driver_result",
                "target": str(config.get("target", "wse3")),
                "contract": "explicit_driver_outcome",
                "simulatorPlanPath": str(simulator_plan_path),
                "compilerExecutable": None,
                "runtimeConfigPath": str(runtime_config_copy),
                "compile": {"attempted": False, "status": "blocked", "reason": f"missing driver result after runner exit {runner_proc.returncode}", "targets": []},
                "run": {
                    "attempted": False,
                    "status": "blocked",
                    "reason": "driver_result_missing",
                    "tracePath": str(trace_path),
                    "traceProduced": False,
                    "stdoutPath": str(stdout_path),
                    "stderrPath": str(stderr_path),
                },
            }
            if result_path.exists():
                simulation_result_payload = load_json(result_path)

            compile_state = str(driver_result_payload.get("compile", {}).get("status", "failed"))
            compile_reason = str(driver_result_payload.get("compile", {}).get("reason", "compile failed"))
            run_state = str(driver_result_payload.get("run", {}).get("status", "blocked"))
            run_reason = str(driver_result_payload.get("run", {}).get("reason", "run blocked"))
            trace_produced = bool(driver_result_payload.get("run", {}).get("traceProduced"))

            phases["compile"] = phase(
                "passed" if compile_state == "succeeded" else ("unavailable" if compile_state == "blocked" else "failed"),
                compile_reason,
            )
            phases["runtime"] = phase(
                "passed" if run_state == "succeeded" else ("not-run" if run_state == "blocked" else "failed"),
                run_reason,
            )

            if trace_produced and trace_path.exists():
                trace_errors = contract.validate_artifact(trace_path, contract.load_schema(SIM_TRACE_SCHEMA))
                if trace_errors:
                    phases["parity"] = phase("failed", "; ".join(trace_errors))
                else:
                    trace_payload = load_json(trace_path)
                    parity_errors = contract.evaluate_csl_trace_parity(trace_payload, dict(config["expectedTrace"]))
                    if parity_errors:
                        phases["parity"] = phase("failed", "; ".join(parity_errors))
                    else:
                        phases["parity"] = phase("passed", "trace summary matched expected smoke-lane counts")
            else:
                phases["parity"] = phase("not-run", "trace unavailable")
    else:
        driver_result_payload = {
            "schemaVersion": 1,
            "artifactKind": "csl_simulator_driver_result",
            "target": str(config.get("target", "wse3")),
            "contract": "explicit_driver_outcome",
            "simulatorPlanPath": str(simulator_plan_path),
            "compilerExecutable": None,
            "runtimeConfigPath": str(runtime_config_path),
            "compile": {"attempted": False, "status": "blocked", "reason": phases["translate"]["reason"], "targets": []},
            "run": {
                "attempted": False,
                "status": "blocked",
                "reason": "translation_failed",
                "tracePath": str(trace_path),
                "traceProduced": False,
                "stdoutPath": str(stdout_path),
                "stderrPath": str(stderr_path),
            },
        }

    driver_result_errors = contract.validate_artifact(driver_result_path, contract.load_schema(SIM_DRIVER_RESULT_SCHEMA)) if driver_result_path.exists() else []
    if driver_result_errors:
        phases["compile"] = phase("failed", "; ".join(driver_result_errors))

    actual_host_plan_path = host_plan_copy if host_plan_copy.exists() else host_plan_path
    expected_host_plan_hash = contract.artifact_sha256(host_plan_path)
    actual_host_plan_hash = contract.artifact_sha256(actual_host_plan_path)

    compile_status_map = {"passed": "succeeded", "failed": "failed", "unavailable": "blocked", "not-run": "blocked"}
    run_status_map = compile_status_map
    lane_status = "failed" if any(item["status"] == "failed" for item in phases.values()) else ("ready" if all(item["status"] == "passed" for item in phases.values()) else "blocked")
    parity_status = "matched" if phases["parity"]["status"] == "passed" else ("mismatched" if phases["parity"]["status"] == "failed" else "not-run")

    report_payload = {
        "schemaVersion": 1,
        "generatedAt": utc_now(),
        "outputTimestamp": run_dir.name if output_paths.run_folder_for_path(report_path) else "",
        "fixture": {
            "id": str(config["laneId"]),
            "inputJsonPath": str(wgsl_path),
        },
        "laneStatus": lane_status,
        "compile": {
            "status": compile_status_map[phases["compile"]["status"]],
            "reason": phases["compile"]["reason"],
            "runnerExitCode": simulation_result_payload.get("exitCode", 2),
        },
        "run": {
            "status": run_status_map[phases["runtime"]["status"]],
            "reason": phases["runtime"]["reason"],
            "traceProduced": trace_path.exists(),
        },
        "parity": {
            "status": parity_status,
            "reason": phases["parity"]["reason"],
            "expectedHostPlanSha256": expected_host_plan_hash,
            "actualHostPlanSha256": actual_host_plan_hash,
            "traceExpected": config["expectedTrace"],
        },
        "artifacts": {
            "actualHostPlanPath": str(actual_host_plan_path),
            "expectedHostPlanPath": str(host_plan_path),
            "simulatorPlanPath": str(simulator_plan_path),
            "simulatorResultPath": str(result_path),
            "driverResultPath": str(driver_result_path),
            "tracePath": str(trace_path),
        },
        "steps": phases,
        "simulationResult": simulation_result_payload,
        "driverResult": driver_result_payload,
        "comparisonStatus": "diagnostic",
        "claimStatus": "not-evaluated",
    }
    write_json(report_path, report_payload)
    output_paths.write_run_manifest_for_outputs(
        [report_path, simulator_plan_path, result_path, trace_path, driver_result_path],
        {
            "artifactKind": "csl_smoke_lane_run",
            "laneId": config["laneId"],
            "target": config.get("target", "wse3"),
            "reportPath": str(report_path),
        },
    )

    report_errors = contract.validate_artifact(report_path, contract.load_schema(LANE_REPORT_SCHEMA))
    if report_errors:
        print("FAIL: invalid CSL smoke lane report")
        for item in report_errors:
            print(f"  {item}")
        return 1

    if args.with_gate:
        gate_cmd = ["python3", str(CSL_GATE), "--report", str(report_path)]
        if args.require_ready:
            gate_cmd.append("--require-ready")
        proc = subprocess.run(gate_cmd, cwd=REPO_ROOT, check=False)
        if proc.returncode != 0:
            return proc.returncode

    print(f"PASS: CSL smoke lane report written to {report_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
