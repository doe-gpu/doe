#!/usr/bin/env python3
"""Build and publish an Apple Metal runtime evidence bundle."""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import shutil
import socket
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
for _path_entry in (str(REPO_ROOT), str(BENCH_ROOT)):
    if _path_entry not in sys.path:
        sys.path.insert(0, _path_entry)

from bench.lib import output_paths
from bench.lib import compare_claim_artifacts as artifacts_mod


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--artifact",
        default="runtime/zig/zig-out/lib/libwebgpu_doe.dylib",
        help="Path to the Apple drop-in dylib to publish.",
    )
    parser.add_argument(
        "--bundle-dir",
        default="bench/out/apple-runtime-release",
        help="Parent directory for the timestamped Apple runtime bundle.",
    )
    parser.add_argument(
        "--timestamp",
        default="",
        help="UTC timestamp suffix (YYYYMMDDTHHMMSSZ).",
    )
    parser.add_argument(
        "--cts-config",
        default="bench/fixtures/cts_subset.fawn-node.json",
        help="CTS subset config used for Apple publication.",
    )
    parser.add_argument(
        "--cts-backend",
        default="doe_metal",
        help="CTS backend identifier recorded in artifacts and ledger.",
    )
    parser.add_argument(
        "--cts-surface",
        default="package",
        choices=["compute", "full", "browser", "package", "native"],
        help="Surface label written into config/webgpu-cts-evidence.json.",
    )
    parser.add_argument(
        "--compare-config",
        default="bench/native-compare/compare.config.apple.metal.compare-dev.json",
        help="Runtime compare config used for Metal sync/timing gate receipts.",
    )
    parser.add_argument(
        "--update-cts-ledger",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Update config/webgpu-cts-evidence.json to the new Apple baseline.",
    )
    return parser.parse_args()


def run_step(
    label: str,
    command: list[str],
    *,
    cwd: Path = REPO_ROOT,
    env: dict[str, str] | None = None,
) -> dict[str, Any]:
    started = time.perf_counter()
    proc = subprocess.run(
        command,
        cwd=str(cwd),
        env=env,
        text=True,
        capture_output=True,
        errors="replace",
        check=False,
    )
    elapsed = round(time.perf_counter() - started, 6)
    return {
        "label": label,
        "command": command,
        "cwd": str(cwd),
        "returnCode": proc.returncode,
        "runtimeSeconds": elapsed,
        "stdoutTail": (proc.stdout or "").splitlines()[-40:],
        "stderrTail": (proc.stderr or "").splitlines()[-40:],
        "pass": proc.returncode == 0,
    }


def ensure_step_ok(step: dict[str, Any]) -> None:
    if not bool(step.get("pass")):
        raise RuntimeError(f"{step.get('label', 'step')} failed")


def ensure_compare_step_acceptable(step: dict[str, Any], report_path: Path) -> None:
    if bool(step.get("pass")):
        if report_path.exists():
            artifacts_mod.ensure_release_strict_comparability(
                load_json(report_path),
                report_path,
                surface="publish_apple_runtime_release",
            )
        return
    if int(step.get("returnCode", 1)) != 3 or not report_path.exists():
        raise RuntimeError(f"{step.get('label', 'step')} failed")
    report = load_json(report_path)
    artifacts_mod.ensure_release_strict_comparability(
        report,
        report_path,
        surface="publish_apple_runtime_release",
    )
    claim_report, _claim_path = artifacts_mod.load_optional_claim_report(report_path)
    if report.get("comparisonStatus") != "comparable":
        raise RuntimeError(f"{step.get('label', 'step')} failed")
    step["pass"] = True
    step["acceptedDiagnosticClaimStatus"] = bool(
        artifacts_mod.claim_status(report, claim_report) == "diagnostic"
    )


def sha256_path(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def dependency_list(path: Path) -> list[str]:
    proc = subprocess.run(
        ["otool", "-L", str(path)],
        text=True,
        capture_output=True,
        errors="replace",
        check=False,
    )
    if proc.returncode != 0:
        return []
    deps: list[str] = []
    for line in proc.stdout.splitlines()[1:]:
        text = line.strip()
        if not text:
            continue
        deps.append(text.split(" (", 1)[0].strip())
    return deps


def strip_copy(src: Path, dst: Path) -> tuple[list[str], int]:
    shutil.copy2(src, dst)
    strip_bin = shutil.which("strip")
    if not strip_bin:
        raise RuntimeError("missing strip tool")
    commands = [
        [strip_bin, "-x", str(dst)],
        [strip_bin, "-S", str(dst)],
    ]
    last_return = 1
    for command in commands:
        proc = subprocess.run(command, capture_output=True, check=False)
        last_return = proc.returncode
        if proc.returncode == 0:
            return command, proc.returncode
    raise RuntimeError(f"strip failed for {dst} (last exit={last_return})")


def load_json(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"invalid JSON object: {path}")
    return payload


def relpath(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(REPO_ROOT.resolve()))
    except ValueError:
        return str(path)


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def update_cts_ledger(
    *,
    ledger_path: Path,
    baseline_path: Path,
    trend_path: Path,
    manifest_path: Path,
    surface: str,
    host: str,
    os_id: str,
    backend: str,
) -> None:
    ledger = load_json(ledger_path)
    baseline = load_json(baseline_path)
    evidence = ledger.get("evidence")
    if not isinstance(evidence, list):
        raise ValueError(f"invalid CTS evidence ledger: {ledger_path}")

    replacement_rows: list[dict[str, Any]] = []
    note = (
        "Apple Metal release publication; "
        f"trend={relpath(trend_path)}; "
        f"bundle={relpath(manifest_path)}"
    )
    for result in baseline.get("results", []):
        if not isinstance(result, dict):
            continue
        query = result.get("query")
        bucket = result.get("bucket")
        status = result.get("status")
        if not isinstance(query, str) or not query:
            continue
        if not isinstance(bucket, str) or not bucket:
            continue
        if not isinstance(status, str) or status not in {"pass", "fail", "skip"}:
            continue
        replacement_rows.append(
            {
                "query": query,
                "bucket": bucket,
                "status": status,
                "surface": surface,
                "host": host,
                "os": os_id,
                "backend": backend,
                "artifactPath": relpath(baseline_path),
                "notes": note,
            }
        )

    filtered_rows = [
        row
        for row in evidence
        if not (
            isinstance(row, dict)
            and row.get("host") == host
            and row.get("os") == os_id
            and row.get("backend") == backend
            and row.get("query") in {item["query"] for item in replacement_rows}
        )
    ]
    filtered_rows.extend(replacement_rows)
    filtered_rows.sort(
        key=lambda row: (
            str(row.get("backend", "")),
            str(row.get("surface", "")),
            str(row.get("host", "")),
            str(row.get("bucket", "")),
            str(row.get("query", "")),
        )
    )
    ledger["lastUpdated"] = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    ledger["ctsSource"] = baseline.get("ctsSource", ledger.get("ctsSource", ""))
    ledger["ctsRevision"] = baseline.get("ctsRevision", ledger.get("ctsRevision", ""))
    ledger["evidence"] = filtered_rows
    write_json(ledger_path, ledger)


def main() -> int:
    args = parse_args()
    output_timestamp = output_paths.resolve_timestamp(args.timestamp)
    bundle_dir = Path(args.bundle_dir) / output_timestamp
    bundle_dir.mkdir(parents=True, exist_ok=True)

    artifact_path = Path(args.artifact)
    if not artifact_path.exists():
        print(f"FAIL: missing artifact: {artifact_path}")
        return 1

    host = socket.gethostname()
    os_id = f"{platform.system().lower()}-{platform.release()}"
    manifest_path = bundle_dir / "apple_runtime_release_manifest.json"

    steps: list[dict[str, Any]] = []
    outputs: list[Path] = []

    try:
        build_step = run_step(
            "build-dropin",
            ["zig", "build", "dropin"],
            cwd=REPO_ROOT / "runtime" / "zig",
        )
        steps.append(build_step)
        ensure_step_ok(build_step)

        source_artifact = artifact_path.resolve()
        raw_artifact = bundle_dir / source_artifact.name
        shutil.copy2(source_artifact, raw_artifact)
        outputs.append(raw_artifact)

        stripped_artifact = bundle_dir / "libwebgpu_doe.stripped.dylib"
        strip_command, strip_exit = strip_copy(source_artifact, stripped_artifact)
        if strip_exit != 0:
            raise RuntimeError("strip failed")
        outputs.append(stripped_artifact)

        footprint_json = bundle_dir / "runtime_footprint_report.json"
        footprint_md = bundle_dir / "runtime_footprint_report.md"
        footprint_step = run_step(
            "runtime-footprint",
            [
                sys.executable,
                "bench/tools/measure_runtime_footprint.py",
                "--doe-lib",
                str(source_artifact),
                "--out-json",
                str(footprint_json),
                "--out-md",
                str(footprint_md),
            ],
        )
        steps.append(footprint_step)
        ensure_step_ok(footprint_step)
        outputs.extend([footprint_json, footprint_md])

        dropin_report = bundle_dir / "dropin_report.json"
        dropin_symbol_report = bundle_dir / "dropin_symbol_report.json"
        dropin_behavior_report = bundle_dir / "dropin_behavior_report.json"
        dropin_benchmark_report = bundle_dir / "dropin_benchmark_report.json"
        dropin_benchmark_html = bundle_dir / "dropin_benchmark_report.html"
        dropin_step = run_step(
            "dropin-gate",
            [
                sys.executable,
                "bench/drop-in/dropin_gate.py",
                "--artifact",
                str(source_artifact),
                "--symbol-report",
                str(dropin_symbol_report),
                "--behavior-report",
                str(dropin_behavior_report),
                "--benchmark-report",
                str(dropin_benchmark_report),
                "--benchmark-html",
                str(dropin_benchmark_html),
                "--report",
                str(dropin_report),
                "--no-timestamp-output",
            ],
        )
        steps.append(dropin_step)
        ensure_step_ok(dropin_step)
        outputs.extend(
            [
                dropin_report,
                dropin_symbol_report,
                dropin_behavior_report,
                dropin_benchmark_report,
                dropin_benchmark_html,
            ]
        )

        consumer_report = bundle_dir / "apple_runtime_consumer_report.json"
        consumer_step = run_step(
            "apple-runtime-consumer",
            [
                sys.executable,
                "bench/drop-in/apple_runtime_consumer.py",
                "--artifact",
                str(source_artifact),
                "--report",
                str(consumer_report),
                "--no-timestamp-output",
            ],
        )
        steps.append(consumer_step)
        ensure_step_ok(consumer_step)
        outputs.append(consumer_report)

        cts_baseline = bundle_dir / "cts_baseline.json"
        cts_step = run_step(
            "cts-baseline",
            [
                sys.executable,
                "bench/tools/cts_baseline_generate.py",
                "--config",
                args.cts_config,
                "--backend",
                args.cts_backend,
                "--host",
                host,
                "--os",
                os_id,
                "--out",
                str(cts_baseline),
            ],
        )
        steps.append(cts_step)
        ensure_step_ok(cts_step)
        outputs.append(cts_baseline)

        cts_trend = bundle_dir / "cts_trend.json"
        cts_trend_step = run_step(
            "cts-trend",
            [
                sys.executable,
                "bench/tools/cts_baseline_trend.py",
                "--dir",
                "bench/out/cts-baseline",
                "--out",
                str(cts_trend),
            ],
        )
        steps.append(cts_trend_step)
        ensure_step_ok(cts_trend_step)
        outputs.append(cts_trend)

        compare_report = bundle_dir / "apple_metal_compare_dev.json"
        compare_workspace = bundle_dir / "apple_metal_compare_dev.workspace"
        compare_step = run_step(
            "apple-metal-compare-dev",
            [
                sys.executable,
                "bench/cli.py",
                "compare",
                "--config",
                args.compare_config,
                "--out",
                str(compare_report),
                "--workspace",
                str(compare_workspace),
                "--no-timestamp-output",
            ],
        )
        steps.append(compare_step)
        ensure_compare_step_acceptable(compare_step, compare_report)
        outputs.append(compare_report)

        sync_gate_report = bundle_dir / "metal_sync_conformance_gate.json"
        sync_gate_step = run_step(
            "metal-sync-conformance",
            [
                sys.executable,
                "bench/gates/sync_conformance_gate.py",
                "--backend",
                "metal",
                "--report",
                str(compare_report),
            ],
        )
        steps.append(sync_gate_step)
        ensure_step_ok(sync_gate_step)
        write_json(sync_gate_report, sync_gate_step)
        outputs.append(sync_gate_report)

        timing_gate_report = bundle_dir / "metal_timing_policy_gate.json"
        timing_gate_step = run_step(
            "metal-timing-policy",
            [
                sys.executable,
                "bench/gates/timing_policy_gate.py",
                "--backend",
                "metal",
                "--report",
                str(compare_report),
            ],
        )
        steps.append(timing_gate_step)
        ensure_step_ok(timing_gate_step)
        write_json(timing_gate_report, timing_gate_step)
        outputs.append(timing_gate_report)

        if args.update_cts_ledger:
            update_cts_ledger(
                ledger_path=REPO_ROOT / "config" / "webgpu-cts-evidence.json",
                baseline_path=cts_baseline,
                trend_path=cts_trend,
                manifest_path=manifest_path,
                surface=args.cts_surface,
                host=host,
                os_id=os_id,
                backend=args.cts_backend,
            )

        manifest = {
            "schemaVersion": 1,
            "generatedAtUtc": utc_now(),
            "outputTimestamp": output_timestamp,
            "bundleDir": relpath(bundle_dir),
            "host": host,
            "os": os_id,
            "artifact": {
                "sourcePath": relpath(source_artifact),
                "rawPath": relpath(raw_artifact),
                "rawSha256": sha256_path(raw_artifact),
                "rawSizeBytes": raw_artifact.stat().st_size,
                "strippedPath": relpath(stripped_artifact),
                "strippedSha256": sha256_path(stripped_artifact),
                "strippedSizeBytes": stripped_artifact.stat().st_size,
                "stripCommand": strip_command,
                "dependencies": dependency_list(raw_artifact),
            },
            "invocation": {
                "buildCommand": ["zig", "build", "dropin"],
                "runnerCommand": [sys.executable, "bench/runners/publish_apple_runtime_release.py", *sys.argv[1:]],
            },
            "artifacts": {
                "dropinReport": relpath(dropin_report),
                "dropinSymbolReport": relpath(dropin_symbol_report),
                "dropinBehaviorReport": relpath(dropin_behavior_report),
                "dropinBenchmarkReport": relpath(dropin_benchmark_report),
                "dropinBenchmarkHtml": relpath(dropin_benchmark_html),
                "consumerReport": relpath(consumer_report),
                "ctsBaseline": relpath(cts_baseline),
                "ctsTrend": relpath(cts_trend),
                "runtimeFootprintJson": relpath(footprint_json),
                "runtimeFootprintMd": relpath(footprint_md),
                "compareDevReport": relpath(compare_report),
                "compareDevWorkspace": relpath(compare_workspace),
                "metalSyncGateReport": relpath(sync_gate_report),
                "metalTimingPolicyGateReport": relpath(timing_gate_report),
            },
            "steps": steps,
            "ctsLedgerUpdated": bool(args.update_cts_ledger),
        }
        write_json(manifest_path, manifest)
        outputs.append(manifest_path)
        output_paths.write_run_manifest_for_outputs(
            outputs,
            {
                "runType": "apple_runtime_release_bundle",
                "config": {
                    "artifact": str(artifact_path),
                    "ctsConfig": args.cts_config,
                    "compareConfig": args.compare_config,
                },
                "fullRun": True,
                "claimGateRan": False,
                "dropinGateRan": True,
                "reportPath": str(manifest_path),
                "status": "passed",
            },
        )
        print(f"PASS: apple runtime release bundle")
        print(f"manifest: {manifest_path}")
        return 0
    except Exception as exc:  # noqa: BLE001
        failure_manifest = {
            "schemaVersion": 1,
            "generatedAtUtc": utc_now(),
            "outputTimestamp": output_timestamp,
            "bundleDir": relpath(bundle_dir),
            "host": host,
            "os": os_id,
            "error": str(exc),
            "steps": steps,
        }
        write_json(manifest_path, failure_manifest)
        outputs.append(manifest_path)
        output_paths.write_run_manifest_for_outputs(
            outputs,
            {
                "runType": "apple_runtime_release_bundle",
                "config": {
                    "artifact": str(artifact_path),
                    "ctsConfig": args.cts_config,
                    "compareConfig": args.compare_config,
                },
                "fullRun": True,
                "claimGateRan": False,
                "dropinGateRan": True,
                "reportPath": str(manifest_path),
                "status": "failed",
            },
        )
        print(f"FAIL: apple runtime release bundle: {exc}")
        print(f"manifest: {manifest_path}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
