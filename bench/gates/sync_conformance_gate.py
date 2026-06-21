#!/usr/bin/env python3
"""Validate per-workload queue sync model from trace metadata.

Parametric over Metal and Vulkan backends. Each backend preserves its
original strictness: Metal additionally fails when a workload has no
successful baseline command samples; Vulkan additionally consults
requiredTimingClass and requireUploadIgnoreFirstSource policy entries.
"""

from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
for _path_entry in (str(REPO_ROOT), str(BENCH_ROOT)):
    if _path_entry not in sys.path:
        sys.path.insert(0, _path_entry)


import argparse
from typing import Any

from bench.lib.bench_utils import load_json_object as load_json
from native_compare_modules import contracts


BACKENDS = ("metal", "vulkan")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--backend", required=True, choices=BACKENDS)
    parser.add_argument("--report", default="bench/out/dawn-vs-doe.json")
    parser.add_argument("--timing-policy", default="config/backend-timing-policy.json")
    return parser.parse_args()


def policy_entry(policy: dict[str, Any], domain: str) -> dict[str, Any]:
    domains = policy.get("domains") if isinstance(policy.get("domains"), dict) else {}
    entry = domains.get(domain)
    return entry if isinstance(entry, dict) else {}


def expected_sync_mode(entry: dict[str, Any]) -> str:
    raw = entry.get("requiredSyncModel")
    return raw if isinstance(raw, str) else "either"


def validate_metal_workload(
    workload: dict[str, Any],
    workload_id: str,
    expected: str,
) -> list[str]:
    failures: list[str] = []
    baseline = workload.get("baseline")
    if not isinstance(baseline, dict):
        return failures
    samples = baseline.get("commandSamples")
    if not isinstance(samples, list):
        return failures
    validated_samples = 0
    for sample in samples:
        if not isinstance(sample, dict):
            continue
        if sample.get("returnCode") != 0:
            continue
        trace_meta = sample.get("traceMeta")
        if not isinstance(trace_meta, dict):
            continue
        validated_samples += 1
        for err in contracts.evaluate_metal_sync_meta(trace_meta, expected):
            failures.append(f"{workload_id}: {err}")
    if validated_samples == 0:
        failures.append(
            f"{workload_id}: no successful baseline command samples with traceMeta for sync validation"
        )
    return failures


def validate_vulkan_workload(
    workload: dict[str, Any],
    workload_id: str,
    expected: str,
    entry: dict[str, Any],
) -> list[str]:
    failures: list[str] = []
    required_timing_class = str(entry.get("requiredTimingClass", "any"))
    required_upload_source = str(entry.get("requireUploadIgnoreFirstSource", ""))
    baseline = workload.get("baseline")
    if not isinstance(baseline, dict):
        return failures
    samples = baseline.get("commandSamples")
    if not isinstance(samples, list):
        return failures
    for sample in samples:
        if not isinstance(sample, dict):
            continue
        if sample.get("returnCode") != 0:
            continue
        for err in contracts.evaluate_vulkan_sync_meta(
            sample,
            expected,
            required_timing_class=required_timing_class,
            require_upload_ignore_first_source=required_upload_source,
        ):
            failures.append(f"{workload_id}: {err}")
    return failures


def main() -> int:
    args = parse_args()
    report = load_json(Path(args.report))
    policy = load_json(Path(args.timing_policy))

    failures: list[str] = []
    workloads = report.get("workloads")
    if not isinstance(workloads, list):
        print("FAIL: invalid report workloads")
        return 1

    for workload in workloads:
        if not isinstance(workload, dict):
            continue
        workload_id = str(workload.get("id", "unknown"))
        domain = str(workload.get("domain", ""))
        entry = policy_entry(policy, domain)
        expected = expected_sync_mode(entry)

        if args.backend == "metal":
            failures.extend(validate_metal_workload(workload, workload_id, expected))
        else:
            failures.extend(validate_vulkan_workload(workload, workload_id, expected, entry))

    label = f"{args.backend} sync conformance"
    if failures:
        print(f"FAIL: {label}")
        for item in failures:
            print(f"  {item}")
        return 1

    print(f"PASS: {label}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
