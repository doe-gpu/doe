#!/usr/bin/env python3
"""Validate AMD Vulkan smoke report has explicit GPU probe evidence for both sides."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--report",
        default="bench/out/dawn-vs-doe.amd.vulkan.smoke.gpu.16mb.json",
        help="Path to a compare-lane report JSON.",
    )
    parser.add_argument(
        "--require-comparable",
        action="store_true",
        help="Require top-level comparisonStatus=comparable.",
    )
    return parser.parse_args()


def _stats_has_count(stats: dict[str, Any], key: str) -> bool:
    value = stats.get(key)
    return isinstance(value, dict) and int(value.get("count", 0)) > 0


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _load_run_receipt(
    reference: dict[str, Any],
    root: Path,
) -> tuple[dict[str, Any] | None, str]:
    raw_path = reference.get("path")
    if not isinstance(raw_path, str) or not raw_path:
        return None, "run receipt path missing"
    relative_path = Path(raw_path)
    if relative_path.is_absolute():
        return None, "run receipt path must be repository-relative"
    resolved_root = root.resolve()
    receipt_path = (resolved_root / relative_path).resolve()
    try:
        receipt_path.relative_to(resolved_root)
    except ValueError:
        return None, "run receipt path escapes repository root"
    try:
        actual_sha256 = _sha256_file(receipt_path)
        payload = json.loads(receipt_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        return None, f"unable to load run receipt: {exc}"
    if actual_sha256 != reference.get("sha256"):
        return None, "run receipt SHA-256 does not match"
    if not isinstance(payload, dict):
        return None, "run receipt is not an object"
    return payload, "ok"


def _receipt_resource_ok(
    workload: dict[str, Any],
    side: str,
    root: Path,
) -> tuple[bool, str]:
    reference_key = "left" if side == "baseline" else "right"
    receipts = workload.get("receipts")
    reference = receipts.get(reference_key) if isinstance(receipts, dict) else None
    if not isinstance(reference, dict):
        return False, f"{side}: run receipt reference missing"
    receipt, message = _load_run_receipt(reference, root)
    if receipt is None:
        return False, f"{side}: {message}"
    receipt_workload = receipt.get("workload")
    if not isinstance(receipt_workload, dict):
        return False, f"{side}: run receipt workload missing"
    if receipt_workload.get("id") != workload.get("id"):
        return False, f"{side}: run receipt workload identity mismatch"
    if receipt.get("product") != reference.get("product"):
        return False, f"{side}: run receipt product identity mismatch"
    samples = receipt.get("samples")
    if not isinstance(samples, list) or not samples:
        return False, f"{side}: run receipt has no samples"
    stats_key = "baselineStatsMs" if side == "baseline" else "comparisonStatsMs"
    stats = workload.get(stats_key)
    expected_count = int(stats.get("count", 0)) if isinstance(stats, dict) else 0
    if len(samples) != expected_count:
        return False, f"{side}: run receipt sample count does not match report"
    for index, sample in enumerate(samples):
        if not isinstance(sample, dict) or sample.get("success") is not True:
            return False, f"{side}: sample {index} is not successful"
        resource = sample.get("resource")
        if not isinstance(resource, dict):
            return False, f"{side}: sample {index} resource evidence missing"
        if resource.get("gpuMemoryProbeAvailable") is not True:
            return False, f"{side}: sample {index} gpuMemoryProbeAvailable=false"
        if int(resource.get("resourceSampleCount", 0)) <= 0:
            return False, f"{side}: sample {index} resourceSampleCount=0"
        if int(resource.get("gpuVramUsedPeakBytes", 0)) <= 0:
            return False, f"{side}: sample {index} gpuVramUsedPeakBytes<=0"
    return True, "ok"


def _resource_ok(
    workload: dict[str, Any],
    side: str,
    root: Path = REPO_ROOT,
) -> tuple[bool, str]:
    side_data = workload.get(side, {})
    command_samples = side_data.get("commandSamples") or []
    if not command_samples:
        return _receipt_resource_ok(workload, side, root)
    resource = command_samples[0].get("resource") or {}
    if not bool(resource.get("gpuMemoryProbeAvailable", False)):
        return False, f"{side}: gpuMemoryProbeAvailable=false"
    if int(resource.get("resourceSampleCount", 0)) <= 0:
        return False, f"{side}: resourceSampleCount=0"
    if int(resource.get("gpuVramUsedPeakBytes", 0)) <= 0:
        return False, f"{side}: gpuVramUsedPeakBytes<=0"
    stats = side_data.get("resourceStats") or {}
    if int(stats.get("gpuProbeAvailableCount", 0)) <= 0:
        return False, f"{side}: resourceStats.gpuProbeAvailableCount=0"
    if not _stats_has_count(stats, "gpuVramUsedPeakBytes"):
        return False, f"{side}: resourceStats.gpuVramUsedPeakBytes missing"
    return True, "ok"


def main() -> int:
    args = parse_args()
    report_path = Path(args.report)
    if not report_path.exists():
        raise SystemExit(f"missing report: {report_path}")
    report = json.loads(report_path.read_text(encoding="utf-8"))

    if args.require_comparable and report.get("comparisonStatus") != "comparable":
        raise SystemExit(
            f"comparisonStatus={report.get('comparisonStatus')} (expected comparable)"
        )

    workloads = report.get("workloads") or []
    if not workloads:
        raise SystemExit("report has no workloads")

    errors: list[str] = []
    for workload in workloads:
        workload_id = workload.get("id", "<unknown>")
        for side in ("baseline", "comparison"):
            ok, reason = _resource_ok(workload, side, REPO_ROOT)
            if not ok:
                errors.append(f"{workload_id}: {reason}")

    if errors:
        joined = "\n".join(errors)
        raise SystemExit(f"gpu smoke verification failed:\n{joined}")

    print(
        "gpu smoke verification passed "
        f"(report={report_path}, workloads={len(workloads)})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
