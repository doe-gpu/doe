"""CLI for live GPU, agent, suite, aggregate, and passport evidence."""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import platform
import subprocess
import sys
from pathlib import Path
from typing import Any

from bench.fawn_matrix.cli import REPO_ROOT, resolve_host_paths
from bench.fawn_matrix.harness.live_evidence import (
    LiveEvidenceError,
    aggregate_platform_suites,
    build_platform_suite,
    canonical_hash,
    evaluate_live_workload,
    validate_live_raw,
    validate_passport_candidate,
)

CONFIG_PATH = Path(__file__).parent / "config" / "live-workloads.json"
EXECUTOR_PATH = Path(__file__).parent / "executors" / "live_workloads.mjs"
FIXTURE_PATH = Path(__file__).parent / "fixtures" / "multi_step_agent.html"
DEFAULT_OUTPUT_ROOT = REPO_ROOT / "bench" / "out" / "fawn-matrix"


def load_json(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def load_config() -> dict[str, Any]:
    config = load_json(CONFIG_PATH)
    if config.get("schemaVersion") != 1:
        raise LiveEvidenceError("unsupported live workload config")
    ids = {entry["workloadId"] for entry in config.get("workloads", [])}
    if ids != {"webgpu_model_preprocessing", "multi_step_agent_interaction"}:
        raise LiveEvidenceError("live workload config must declare both workloads")
    return config


def workload_config(config: dict[str, Any], workload_id: str) -> dict[str, Any]:
    return next(entry for entry in config["workloads"] if entry["workloadId"] == workload_id)


def playwright_root() -> Path:
    for candidate in (REPO_ROOT, REPO_ROOT / "browser" / "chromium"):
        if (candidate / "node_modules" / "playwright").is_dir() or (candidate / "node_modules" / "playwright-core").is_dir():
            return candidate
    raise FileNotFoundError("Playwright installation not found")


def hardware_identity(platform_id: str) -> dict[str, Any]:
    host = platform.system().lower()
    architecture = platform.machine()
    if platform_id == "apple-metal":
        if host != "darwin":
            raise LiveEvidenceError("apple-metal requires a Darwin host")
        command = ["system_profiler", "SPDisplaysDataType", "-json"]
        raw = subprocess.run(command, check=True, capture_output=True, text=True).stdout
        displays = json.loads(raw).get("SPDisplaysDataType", [])
        if not displays:
            raise LiveEvidenceError("Apple GPU identity unavailable")
        device = displays[0].get("sppci_model", "")
        vendor = displays[0].get("sppci_vendor", "Apple")
        backend = "metal"
        verified = "apple" in (device + vendor).lower()
        source = "system_profiler_SPDisplaysDataType"
    elif platform_id == "amd-vulkan":
        if host != "linux":
            raise LiveEvidenceError("amd-vulkan requires a Linux host")
        command = ["vulkaninfo", "--summary"]
        raw = subprocess.run(command, check=True, capture_output=True, text=True).stdout
        device = next((line.split("=", 1)[1].strip() for line in raw.splitlines() if "deviceName" in line), "")
        vendor = "AMD"
        backend = "vulkan"
        verified = "amd" in raw.lower() or "radeon" in raw.lower()
        source = "vulkaninfo_summary"
    else:
        if host != "windows":
            raise LiveEvidenceError("windows-d3d12 requires a Windows host")
        command = ["powershell", "-NoProfile", "-Command", "Get-CimInstance Win32_VideoController | ConvertTo-Json"]
        raw = subprocess.run(command, check=True, capture_output=True, text=True).stdout
        device = json.loads(raw).get("Name", "")
        vendor = "Windows GPU"
        backend = "d3d12"
        verified = bool(device)
        source = "Win32_VideoController"
    if not verified:
        raise LiveEvidenceError(f"physical identity not verified for {platform_id}")
    evidence_hash = hashlib.sha256(raw.encode()).hexdigest()
    identity = {
        "platformId": platform_id,
        "hostPlatform": host,
        "architecture": architecture,
        "backend": backend,
        "vendor": vendor,
        "device": device,
        "source": source,
        "evidenceSha256": evidence_hash,
        "verified": True,
    }
    identity["identityHash"] = canonical_hash(identity)
    return identity


def run_workload(args: argparse.Namespace) -> tuple[dict[str, Any], Path]:
    config = load_config()
    workload = workload_config(config, args.workload)
    stock, fawn, doe = resolve_host_paths(args.stock_chrome, args.fawn_chrome, args.doe_lib)
    timestamp = datetime.datetime.now(datetime.UTC).strftime("%Y%m%dT%H%M%SZ")
    output_dir = args.output_root / args.platform_id / timestamp
    raw_path = output_dir / f"{args.workload}.raw.json"
    raw_path.parent.mkdir(parents=True, exist_ok=True)
    command = [
        "node", str(EXECUTOR_PATH),
        "--workload", args.workload,
        "--stock-browser", str(stock),
        "--fawn-browser", str(fawn),
        "--doe-library", str(doe),
        "--playwright-root", str(playwright_root()),
        "--fixture", str(FIXTURE_PATH),
        "--output", str(raw_path),
        "--warmups", str(workload["warmupIterations"]),
        "--iterations", str(workload["timedIterations"]),
        "--agent-steps", str(workload.get("agentSteps", 3)),
        "--input-elements", str(workload.get("inputElements", 16384)),
        "--dispatch-repeats", str(workload.get("dispatchRepeats", 1)),
        "--headless", "false" if args.headful else "true",
    ]
    subprocess.run(command, cwd=REPO_ROOT, check=True)
    payload = load_json(raw_path)
    payload["platform"] = {
        "platformId": args.platform_id,
        "hardwareIdentity": hardware_identity(args.platform_id),
    }
    write_json(raw_path, payload)
    comparability = validate_live_raw(payload, workload)
    report = evaluate_live_workload(payload, workload, comparability, raw_path)
    report_path = output_dir / f"{args.workload}.platform-report.json"
    write_json(report_path, report)
    return report, report_path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    run = commands.add_parser("run")
    run.add_argument("--workload", choices=["webgpu_model_preprocessing", "multi_step_agent_interaction"], required=True)
    run.add_argument("--platform-id", choices=["apple-metal", "amd-vulkan", "windows-d3d12"], required=True)
    run.add_argument("--stock-chrome")
    run.add_argument("--fawn-chrome")
    run.add_argument("--doe-lib")
    run.add_argument("--headful", action="store_true")
    run.add_argument("--output-root", type=Path, default=DEFAULT_OUTPUT_ROOT)
    suite = commands.add_parser("suite")
    suite.add_argument("--report", action="append", type=Path, required=True)
    suite.add_argument("--out", type=Path, required=True)
    aggregate = commands.add_parser("aggregate")
    aggregate.add_argument("--suite-report", action="append", type=Path, required=True)
    aggregate.add_argument("--out", type=Path, required=True)
    passport = commands.add_parser("passport")
    passport.add_argument("--aggregate", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    config = load_config()
    if args.command == "run":
        report, path = run_workload(args)
        print(json.dumps({"overallThesisStatus": report["overallThesisStatus"], "reportPath": str(path)}, indent=2))
        return 0
    if args.command == "suite":
        suite = build_platform_suite(
            [load_json(path) for path in args.report],
            config["promotion"]["signingKeyEnvironment"],
        )
        write_json(args.out, suite)
        print(json.dumps({"reportPath": str(args.out), "decisions": suite["decisions"], "receipt": suite["promotionReceipt"]["signatureStatus"]}, indent=2))
        return 0
    if args.command == "aggregate":
        aggregate = aggregate_platform_suites(
            [load_json(path) for path in args.suite_report],
            config["promotion"]["corePlatforms"],
            config["promotion"]["desktopPlatforms"],
        )
        write_json(args.out, aggregate)
        print(json.dumps({"reportPath": str(args.out), "desktopPlatformStatus": aggregate["desktopPlatformStatus"]}, indent=2))
        return 0
    validate_passport_candidate(load_json(args.aggregate))
    print("PASS: release passport candidate is signed and all product components earned status")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (FileNotFoundError, LiveEvidenceError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1) from None
