#!/usr/bin/env python3
"""Validate timing source/class policy for compare reports.

Parametric over Metal and Vulkan backends. Each backend preserves its
original behavior: Metal additionally fails when a workload side has no
successful command samples; Vulkan additionally consults
allowedTimingSourcesByBackendId for per-sample backend-specific source sets.
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

from bench.lib.bench_utils import canonical, load_json_object as load_json
from bench.lib.config_validation import load_validated_config


BACKENDS = ("metal", "vulkan")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--backend", required=True, choices=BACKENDS)
    parser.add_argument("--report", default="bench/out/dawn-vs-doe.json")
    parser.add_argument("--timing-policy", default="config/backend-timing-policy.json")
    return parser.parse_args()


def domain_policy(policy: dict[str, Any], domain: str) -> dict[str, Any]:
    domains = policy.get("domains") if isinstance(policy.get("domains"), dict) else {}
    entry = domains.get(domain)
    return entry if isinstance(entry, dict) else {}


def sample_backend_id(sample: dict[str, Any]) -> str:
    trace_meta = sample.get("traceMeta")
    if isinstance(trace_meta, dict):
        backend_id = trace_meta.get("backendId")
        if isinstance(backend_id, str) and backend_id:
            return backend_id

    backend_id = sample.get("backendId")
    if isinstance(backend_id, str) and backend_id:
        return backend_id

    backend_selection = sample.get("backendSelection")
    if isinstance(backend_selection, dict):
        selected = backend_selection.get("selectedBackend")
        if isinstance(selected, dict):
            selected_id = selected.get("backendId")
            if isinstance(selected_id, str) and selected_id:
                return selected_id
    return ""


def backend_allowed_sources(policy_entry: dict[str, Any], backend_id: str) -> set[str]:
    if not backend_id:
        return set()
    by_backend = policy_entry.get("allowedTimingSourcesByBackendId")
    if not isinstance(by_backend, dict):
        return set()
    backend_sources = by_backend.get(backend_id)
    if not isinstance(backend_sources, list):
        return set()
    return {canonical(str(item)) for item in backend_sources if isinstance(item, str)}


def validate_side_samples(
    samples: list[Any],
    *,
    backend: str,
    workload_id: str,
    side_name: str,
    allowed_sources: set[str],
    require_upload_source: Any,
    policy_entry_payload: dict[str, Any],
) -> list[str]:
    failures: list[str] = []
    successful_samples = 0
    for sample in samples:
        if not isinstance(sample, dict):
            continue
        if sample.get("returnCode") != 0:
            continue
        successful_samples += 1
        source = canonical(str(sample.get("timingSource", "")))
        if backend == "vulkan":
            sample_allowed_sources = set(allowed_sources)
            sample_allowed_sources.update(
                backend_allowed_sources(policy_entry_payload, sample_backend_id(sample))
            )
        else:
            sample_allowed_sources = allowed_sources
        if sample_allowed_sources and source not in sample_allowed_sources:
            failures.append(
                f"{workload_id}: {side_name} timingSource {source!r} not in allowed set {sorted(sample_allowed_sources)}"
            )
        timing = sample.get("timing")
        if (
            isinstance(require_upload_source, str)
            and require_upload_source
            and isinstance(timing, dict)
            and timing.get("uploadIgnoreFirstApplied") is True
        ):
            adjusted = canonical(str(timing.get("uploadIgnoreFirstAdjustedTimingSource", "")))
            if adjusted != canonical(require_upload_source):
                failures.append(
                    f"{workload_id}: {side_name} upload ignore-first adjusted source {adjusted!r} expected {require_upload_source!r}"
                )
    if backend == "metal" and successful_samples == 0:
        failures.append(
            f"{workload_id}: {side_name} has no successful command samples for timing-policy validation"
        )
    return failures


def main() -> int:
    args = parse_args()
    try:
        report = load_json(Path(args.report))
        policy = load_validated_config(Path(args.timing_policy))
    except (OSError, UnicodeError, ValueError) as exc:
        print(f"FAIL: {args.backend} timing policy gate input error: {exc}")
        return 1

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
        policy_entry = domain_policy(policy, domain)
        required_class = str(policy_entry.get("requiredTimingClass", "any"))
        allowed_sources = {
            canonical(str(item))
            for item in policy_entry.get("allowedTimingSources", [])
            if isinstance(item, str)
        }
        require_upload_source = policy_entry.get("requireUploadIgnoreFirstSource")

        comparability = workload.get("comparability")
        if isinstance(comparability, dict):
            left_class = str(comparability.get("baselineTimingClass", ""))
            right_class = str(comparability.get("comparisonTimingClass", ""))
            if required_class != "any" and left_class != required_class:
                failures.append(
                    f"{workload_id}: baselineTimingClass mismatch expected={required_class} got={left_class}"
                )
            if required_class != "any" and right_class != required_class:
                failures.append(
                    f"{workload_id}: comparisonTimingClass mismatch expected={required_class} got={right_class}"
                )

        for side_name in ("baseline", "comparison"):
            side = workload.get(side_name)
            if not isinstance(side, dict):
                continue
            samples = side.get("commandSamples")
            if not isinstance(samples, list):
                continue
            failures.extend(
                validate_side_samples(
                    samples,
                    backend=args.backend,
                    workload_id=workload_id,
                    side_name=side_name,
                    allowed_sources=allowed_sources,
                    require_upload_source=require_upload_source,
                    policy_entry_payload=policy_entry,
                )
            )

    label = f"{args.backend} timing policy gate"
    if failures:
        print(f"FAIL: {label}")
        for item in failures:
            print(f"  {item}")
        return 1

    print(f"PASS: {label}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
