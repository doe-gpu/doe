#!/usr/bin/env python3
"""Run the exact package upload/readback oracle through Doe and Dawn."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import tempfile
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
PLAN_PATH = REPO_ROOT / "bench/plans/package-developer/package_buffer_upload_readback_exact_1mb.plan.json"
RUNNER_PATH = REPO_ROOT / "bench/executors/run-node-webgpu-plan.js"
PROVIDERS = ("doe", "node-webgpu")
WORKLOAD_ID = "package_buffer_upload_readback_exact_1mb"


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(value, separators=(",", ":"), sort_keys=True).encode("utf-8")


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_plan() -> dict[str, Any]:
    return json.loads(PLAN_PATH.read_text(encoding="utf-8"))


def expected_sha256(plan: dict[str, Any]) -> str:
    return str(plan["commands"][0]["captureValidate"]["sha256"])


def corrupted_sha256(expected: str) -> str:
    replacement = "0" if expected[0] != "0" else "1"
    return f"{replacement}{expected[1:]}"


def run_provider(provider: str, plan_path: Path, output_dir: Path) -> dict[str, Any]:
    provider_dir = output_dir / provider
    provider_dir.mkdir(parents=True, exist_ok=True)
    trace_meta_path = provider_dir / "trace.meta.json"
    trace_jsonl_path = provider_dir / "trace.ndjson"
    command = [
        "node",
        str(RUNNER_PATH.relative_to(REPO_ROOT)),
        "--provider",
        provider,
        "--plan",
        str(plan_path),
        "--trace-meta",
        str(trace_meta_path),
        "--trace-jsonl",
        str(trace_jsonl_path),
        "--workload",
        WORKLOAD_ID,
    ]
    environment = dict(os.environ)
    environment["DOE_NODE_WEBGPU_CHILD"] = "1"
    completed = subprocess.run(
        command,
        cwd=REPO_ROOT,
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )
    trace_meta = (
        json.loads(trace_meta_path.read_text(encoding="utf-8"))
        if trace_meta_path.is_file()
        else {}
    )
    captures = trace_meta.get("readbackCaptures")
    return {
        "provider": provider,
        "executionBackend": trace_meta.get("executionBackend", ""),
        "exitCode": completed.returncode,
        "executionSuccessCount": int(trace_meta.get("executionSuccessCount", 0)),
        "executionErrorCount": int(trace_meta.get("executionErrorCount", 0)),
        "executionUnsupportedCount": int(trace_meta.get("executionUnsupportedCount", 0)),
        "executionSkippedCount": int(trace_meta.get("executionSkippedCount", 0)),
        "executionSetupTotalNs": int(trace_meta.get("executionSetupTotalNs", 0)),
        "executionEncodeTotalNs": int(trace_meta.get("executionEncodeTotalNs", 0)),
        "executionSubmitWaitTotalNs": int(trace_meta.get("executionSubmitWaitTotalNs", 0)),
        "executionTotalNs": int(trace_meta.get("executionTotalNs", 0)),
        "readbackCaptures": captures if isinstance(captures, list) else [],
        "traceMetaSha256": sha256_file(trace_meta_path) if trace_meta_path.is_file() else "",
        "stderr": completed.stderr.strip(),
    }


def exact_provider_passed(row: dict[str, Any], expected: str) -> bool:
    captures = row["readbackCaptures"]
    return bool(
        row["exitCode"] == 0
        and row["executionSuccessCount"] == 3
        and row["executionErrorCount"] == 0
        and row["executionUnsupportedCount"] == 0
        and row["executionSkippedCount"] == 0
        and len(captures) == 1
        and captures[0].get("byteLength") == 1048576
        and captures[0].get("sha256") == expected
    )


def corruption_provider_passed(row: dict[str, Any], expected: str) -> bool:
    return bool(
        row["exitCode"] != 0
        and row["executionSuccessCount"] == 0
        and row["executionErrorCount"] == 1
        and row["executionUnsupportedCount"] == 0
        and row["executionSkippedCount"] == 0
        and not row["readbackCaptures"]
        and "validation failed" in row["stderr"]
        and expected in row["stderr"]
    )


def build_report(mode: str) -> tuple[dict[str, Any], int]:
    plan = load_plan()
    expected = expected_sha256(plan)
    effective_plan = plan
    expected_status = "pass"
    with tempfile.TemporaryDirectory(prefix="doe-package-upload-oracle-") as temporary:
        output_dir = Path(temporary)
        plan_path = PLAN_PATH
        if mode == "corrupt":
            effective_plan = json.loads(json.dumps(plan))
            effective_plan["commands"][0]["captureValidate"]["sha256"] = corrupted_sha256(expected)
            plan_path = output_dir / "corrupt.plan.json"
            plan_path.write_bytes(canonical_bytes(effective_plan))
            expected_status = "oracle_rejected_corruption"
        providers = [run_provider(provider, plan_path, output_dir) for provider in PROVIDERS]

    checks = [
        exact_provider_passed(row, expected)
        if mode == "exact"
        else corruption_provider_passed(row, expected)
        for row in providers
    ]
    status = expected_status if all(checks) else "fail"
    report = {
        "schemaVersion": 1,
        "kind": "doe_package_upload_readback_oracle",
        "status": status,
        "mode": mode,
        "workloadId": WORKLOAD_ID,
        "planSha256": hashlib.sha256(canonical_bytes(effective_plan)).hexdigest(),
        "expectedPayloadSha256": expected,
        "captureByteLength": 1048576,
        "providers": providers,
    }
    return report, 0 if status == expected_status else 1


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("exact", "corrupt"), required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    report, exit_code = build_report(args.mode)
    print(json.dumps(report, separators=(",", ":"), sort_keys=True))
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
