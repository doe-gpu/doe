#!/usr/bin/env python3
"""Run the exact browser render oracle through Chromium/Dawn and Fawn/Doe."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
RUNNER_PATH = REPO_ROOT / "browser/chromium/scripts/webgpu-playwright-layered-bench.mjs"
WORKFLOWS_PATH = REPO_ROOT / "browser/chromium/bench/workflows/browser-workflow-manifest.json"
WORKLOAD_ID = "render_draw_state_bindings"
RUNTIMES = ("dawn", "doe")


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(value, separators=(",", ":"), sort_keys=True).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def first_existing(candidates: list[Path]) -> Path:
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    return candidates[0]


def default_manifest() -> Path:
    suffix = ".apple.metal" if sys.platform == "darwin" else ""
    return REPO_ROOT / f"browser/chromium/bench/generated/browser_projection_manifest{suffix}.json"


def default_dawn_chrome() -> Path:
    configured = os.environ.get("FAWN_DAWN_CHROME_BIN")
    candidates = [
        Path(configured) if configured else Path("/__missing_fawn_dawn_chrome__"),
        Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
        Path("/usr/bin/google-chrome-stable"),
        Path("/usr/bin/google-chrome"),
        Path("/usr/bin/chromium"),
    ]
    return first_existing(candidates)


def default_doe_chrome() -> Path:
    configured = os.environ.get("FAWN_DOE_CHROME_BIN") or os.environ.get("FAWN_CHROME_BIN")
    home = Path.home()
    candidates = [
        Path(configured) if configured else Path("/__missing_fawn_doe_chrome__"),
        REPO_ROOT / "browser/chromium/out/fawn_release_local/Fawn.app/Contents/MacOS/Chromium-real",
        REPO_ROOT / "browser/chromium/out/fawn_release_local/Fawn.app/Contents/MacOS/Chromium",
        REPO_ROOT / "browser/chromium/out/fawn_release_local/chrome",
        home / "Applications/Fawn.app/Contents/MacOS/Chromium-real",
        home / "Applications/Fawn.app/Contents/MacOS/Chromium",
    ]
    return first_existing(candidates)


def default_doe_lib() -> Path:
    configured = os.environ.get("FAWN_DOE_LIB")
    extension = "dylib" if sys.platform == "darwin" else "dll" if os.name == "nt" else "so"
    candidates = [
        Path(configured) if configured else Path("/__missing_fawn_doe_lib__"),
        REPO_ROOT / f"runtime/zig/zig-out/lib/libwebgpu_doe_full.{extension}",
        REPO_ROOT / f"runtime/zig/zig-out/lib/libwebgpu_doe.{extension}",
    ]
    return first_existing(candidates)


def corrupted_sha256(expected: str) -> str:
    replacement = "0" if expected[0] != "0" else "1"
    return f"{replacement}{expected[1:]}"


def focused_manifest(source: dict[str, Any], mode: str) -> tuple[dict[str, Any], str, str]:
    rows = source.get("rows")
    if not isinstance(rows, list):
        raise ValueError("source projection manifest rows missing")
    matches = [row for row in rows if row.get("sourceWorkloadId") == WORKLOAD_ID]
    if len(matches) != 1:
        raise ValueError(f"expected one {WORKLOAD_ID} projection row, found {len(matches)}")
    row = json.loads(json.dumps(matches[0]))
    oracle = row.get("browserWorkload", {}).get("renderOutputOracle")
    if not isinstance(oracle, dict):
        raise ValueError(f"{WORKLOAD_ID} renderOutputOracle missing")
    expected = str(oracle.get("expectedSha256", ""))
    if len(expected) != 64:
        raise ValueError(f"{WORKLOAD_ID} expected raster SHA-256 missing")
    effective = expected
    if mode == "corrupt":
        effective = corrupted_sha256(expected)
        oracle["expectedSha256"] = effective
    focused = {
        key: source[key]
        for key in (
            "schemaVersion",
            "generatedAt",
            "sourceWorkloadsPath",
            "sourceWorkloadsSha256",
            "rulesPath",
            "rulesSha256",
        )
    }
    focused["sourceWorkloadCount"] = 1
    focused["rows"] = [row]
    focused["projectionContractHash"] = sha256_bytes(
        canonical_bytes(
            {
                "sourceWorkloadsSha256": focused["sourceWorkloadsSha256"],
                "rulesSha256": focused["rulesSha256"],
                "rows": focused["rows"],
            }
        )
    )
    return focused, expected, effective


def runtime_rows(report: dict[str, Any]) -> dict[str, dict[str, Any]]:
    rows = report.get("l1", {}).get("rows")
    if not isinstance(rows, list) or len(rows) != 1:
        return {}
    runtimes = rows[0].get("runtimes")
    return runtimes if isinstance(runtimes, dict) else {}


def runtime_identity(report: dict[str, Any], mode: str) -> dict[str, Any]:
    details = report.get("modeRunDetails")
    if not isinstance(details, list):
        return {}
    for detail in details:
        if isinstance(detail, dict) and detail.get("mode") == mode:
            return detail
    return {}


def summarize_runtime(report: dict[str, Any], mode: str) -> dict[str, Any]:
    result = runtime_rows(report).get(mode, {})
    metrics = result.get("metrics") if isinstance(result.get("metrics"), dict) else {}
    identity = runtime_identity(report, mode)
    runtime_probe = identity.get("runtimeProbe") if isinstance(identity.get("runtimeProbe"), dict) else {}
    runtime_evidence = (
        identity.get("runtimeEvidence")
        if isinstance(identity.get("runtimeEvidence"), dict)
        else {}
    )
    active_proof = (
        runtime_evidence.get("activeRuntimeProof")
        if isinstance(runtime_evidence.get("activeRuntimeProof"), dict)
        else {}
    )
    return {
        "mode": mode,
        "browserPath": str(identity.get("chromePath", "")),
        "browserVersion": str(runtime_evidence.get("browserVersion", "")),
        "adapterIdentity": runtime_probe.get("adapterIdentity") or {},
        "activeRuntimeMatched": active_proof.get("matched") is True,
        "status": str(result.get("status", "missing")),
        "statusCode": str(result.get("statusCode", "missing")),
        "error": str(result.get("error") or ""),
        "expectedRasterSha256": str(metrics.get("expectedRasterSha256", "")),
        "computedExpectedRasterSha256": str(metrics.get("computedExpectedRasterSha256", "")),
        "actualRasterSha256": str(metrics.get("actualRasterSha256", "")),
        "rasterByteLength": int(metrics.get("rasterByteLength", 0)),
        "rasterMismatchCount": int(metrics.get("rasterMismatchCount", -1)),
        "firstRasterMismatchOffset": int(metrics.get("firstRasterMismatchOffset", -2)),
        "oraclePassed": metrics.get("pass") is True,
        "renderMs": float(metrics.get("renderMs", 0.0)),
    }


def expected_runtime_result(
    row: dict[str, Any], mode: str, expected: str, effective: str, byte_length: int
) -> bool:
    common = bool(
        row["mode"] == mode
        and row["activeRuntimeMatched"]
        and row["computedExpectedRasterSha256"] == expected
        and row["actualRasterSha256"] == expected
        and row["rasterByteLength"] == byte_length
        and row["rasterMismatchCount"] == 0
        and row["firstRasterMismatchOffset"] == -1
    )
    if not common:
        return False
    if effective == expected:
        return bool(
            row["status"] == "ok"
            and row["statusCode"] == "ok"
            and row["expectedRasterSha256"] == expected
            and row["oraclePassed"]
        )
    return bool(
        row["status"] == "fail"
        and row["statusCode"] == "scenario_runtime_error"
        and row["expectedRasterSha256"] == effective
        and not row["oraclePassed"]
        and "full-raster render oracle failed" in row["error"]
    )


def build_report(
    mode: str,
    source_manifest_path: Path,
    focused_manifest_path: Path,
    layered_report_path: Path,
    completed: subprocess.CompletedProcess[str],
) -> tuple[dict[str, Any], int]:
    source = json.loads(source_manifest_path.read_text(encoding="utf-8"))
    focused = json.loads(focused_manifest_path.read_text(encoding="utf-8"))
    _, expected, effective = focused_manifest(source, mode)
    layered = (
        json.loads(layered_report_path.read_text(encoding="utf-8"))
        if layered_report_path.is_file()
        else {}
    )
    oracle = focused["rows"][0]["browserWorkload"]["renderOutputOracle"]
    byte_length = int(oracle["bytesPerRow"]) * int(oracle["height"])
    runtimes = [summarize_runtime(layered, runtime) for runtime in RUNTIMES]
    checks = [
        expected_runtime_result(row, runtime, expected, effective, byte_length)
        for row, runtime in zip(runtimes, RUNTIMES, strict=True)
    ]
    runner_exit_expected = completed.returncode == (0 if mode == "exact" else 1)
    expected_status = "pass" if mode == "exact" else "oracle_rejected_corruption"
    status = expected_status if runner_exit_expected and all(checks) else "fail"
    report = {
        "schemaVersion": 1,
        "kind": "doe_browser_render_oracle",
        "status": status,
        "mode": mode,
        "workloadId": WORKLOAD_ID,
        "sourceManifestSha256": sha256_file(source_manifest_path),
        "focusedManifestSha256": sha256_file(focused_manifest_path),
        "layeredReportSha256": sha256_file(layered_report_path) if layered_report_path.is_file() else "",
        "expectedRasterSha256": expected,
        "effectiveExpectedRasterSha256": effective,
        "rasterByteLength": byte_length,
        "runnerExitCode": completed.returncode,
        "runnerStdout": completed.stdout.strip(),
        "runnerStderr": completed.stderr.strip(),
        "runtimes": runtimes,
    }
    return report, 0 if status == expected_status else 1


def run(args: argparse.Namespace) -> tuple[dict[str, Any], int]:
    source_manifest_path = args.manifest.resolve()
    source = json.loads(source_manifest_path.read_text(encoding="utf-8"))
    focused, _, _ = focused_manifest(source, args.mode)
    with tempfile.TemporaryDirectory(prefix="doe-browser-render-oracle-") as temporary:
        root = Path(temporary)
        manifest_path = root / "focused-projection-manifest.json"
        layered_report_path = root / "browser-layered-report.json"
        manifest_path.write_bytes(canonical_bytes(focused))
        command = [
            "node",
            str(RUNNER_PATH.relative_to(REPO_ROOT)),
            "--mode",
            "both",
            "--mode-order",
            "dawn,doe",
            "--mode-schedule",
            "paired",
            "--dawn-chrome",
            str(args.dawn_chrome),
            "--doe-chrome",
            str(args.doe_chrome),
            "--doe-lib",
            str(args.doe_lib),
            "--manifest",
            str(manifest_path),
            "--workflows",
            str(WORKFLOWS_PATH),
            "--focus-category",
            "render",
            "--iters-render",
            "1",
            "--headless",
            "true",
            "--strict",
            "--out",
            str(layered_report_path),
        ]
        completed = subprocess.run(
            command,
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        return build_report(
            args.mode,
            source_manifest_path,
            manifest_path,
            layered_report_path,
            completed,
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("exact", "corrupt"), required=True)
    parser.add_argument("--manifest", type=Path, default=default_manifest())
    parser.add_argument("--dawn-chrome", type=Path, default=default_dawn_chrome())
    parser.add_argument("--doe-chrome", type=Path, default=default_doe_chrome())
    parser.add_argument("--doe-lib", type=Path, default=default_doe_lib())
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    report, exit_code = run(args)
    print(json.dumps(report, separators=(",", ":"), sort_keys=True))
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
