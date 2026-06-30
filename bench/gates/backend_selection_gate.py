#!/usr/bin/env python3
"""Validate backend selection telemetry against backend-runtime policy."""

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


# Every non-listed lane string passes through unchanged. Only one true alias
# lives in this map — `vulkan_dawn_directional` collapses to the release lane.
_LANE_ALIASES: dict[str, str] = {
    "vulkan_dawn_directional": "vulkan_dawn_release",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", default="bench/out/dawn-vs-doe.json")
    parser.add_argument("--policy", default="config/backend-runtime-policy.json")
    parser.add_argument("--lane", default="")
    return parser.parse_args()


def normalize_lane_alias(raw_lane: str) -> str:
    return _LANE_ALIASES.get(raw_lane, raw_lane)


def infer_lane(report: dict[str, Any], explicit_lane: str) -> str:
    if explicit_lane:
        return normalize_lane_alias(explicit_lane)
    config_path = str(report.get("configPath", ""))
    if "metal_doe_app" in config_path or "metal-doe-app" in config_path:
        return "metal_doe_app"
    if ".metal.dawn" in config_path:
        return "metal_dawn_release"
    if ".metal.smoke" in config_path:
        return "metal_doe_directional"
    if ".metal.release" in config_path:
        return "metal_doe_release"
    if (
        ".metal.compare-dev" in config_path
        or ".metal.compare" in config_path
        or ".metal.frontier" in config_path
    ):
        return "metal_doe_comparable"
    if ".metal.comparable" in config_path or ".metal.extended.comparable" in config_path:
        return "metal_doe_comparable"
    if ".metal.explore" in config_path:
        return "metal_doe_directional"
    if ".metal.directional" in config_path:
        return "metal_doe_directional"
    if ".local.d3d12.smoke" in config_path:
        return "d3d12_doe_comparable"
    if ".local.d3d12.release" in config_path:
        return "d3d12_doe_release"
    if (
        ".local.d3d12.compare-dev" in config_path
        or ".local.d3d12.compare" in config_path
        or ".local.d3d12.frontier" in config_path
    ):
        return "d3d12_doe_comparable"
    if ".local.d3d12.comparable" in config_path or ".local.d3d12.extended.comparable" in config_path:
        return "d3d12_doe_comparable"
    if ".local.d3d12.explore" in config_path:
        return "d3d12_doe_directional"
    if ".local.d3d12.directional" in config_path:
        return "d3d12_doe_directional"
    if ".d3d12.dawn" in config_path:
        return "d3d12_dawn_release"
    if ".d3d12.app" in config_path:
        return "d3d12_doe_app"
    if ".amd.vulkan.smoke" in config_path:
        return "vulkan_doe_app"
    if ".amd.vulkan.release" in config_path or ".amd.vulkan.extended.strict.release" in config_path or ".local.vulkan.release" in config_path:
        return "vulkan_doe_release"
    if (
        ".amd.vulkan.compare-dev" in config_path
        or ".amd.vulkan.compare" in config_path
        or ".amd.vulkan.frontier" in config_path
    ):
        return "vulkan_doe_comparable"
    if (
        ".amd.vulkan.comparable" in config_path
        or ".amd.vulkan.extended.comparable" in config_path
        or ".amd.vulkan.extended.strict.comparable" in config_path
        or ".amd.vulkan.superset.comparable" in config_path
        or ".local.vulkan.comparable" in config_path
        or ".local.vulkan.extended.comparable" in config_path
    ):
        return "vulkan_doe_comparable"
    if ".amd.vulkan.explore" in config_path:
        return "vulkan_doe_app"
    if (
        ".amd.vulkan.directional" in config_path
        or ".amd.vulkan.macro.directional" in config_path
        or ".amd.vulkan.extended.strict.directional" in config_path
        or ".local.vulkan.directional" in config_path
    ):
        return "vulkan_doe_app"
    return "vulkan_dawn_release"


def main() -> int:
    args = parse_args()
    try:
        report = load_json(Path(args.report))
        policy = load_json(Path(args.policy))
    except (OSError, UnicodeError, ValueError) as exc:
        print(f"FAIL: backend selection gate input error: {exc}")
        return 1

    lanes = policy.get("lanes") if isinstance(policy.get("lanes"), dict) else {}
    lane = infer_lane(report, args.lane)
    lane_policy = lanes.get(lane) if isinstance(lanes, dict) else None
    if not isinstance(lane_policy, dict):
        print(f"FAIL: missing lane policy for {lane}")
        return 1

    expected_backend = lane_policy.get("defaultBackend")
    strict_no_fallback = bool(lane_policy.get("strictNoFallback", False))

    failures: list[str] = []
    workloads = report.get("workloads")
    if not isinstance(workloads, list):
        print("FAIL: invalid report workloads")
        return 1

    for workload in workloads:
        if not isinstance(workload, dict):
            continue
        workload_id = str(workload.get("id", "unknown"))
        baseline = workload.get("baseline")
        if not isinstance(baseline, dict):
            continue
        samples = baseline.get("commandSamples")
        if not isinstance(samples, list):
            continue
        for sample in samples:
            if not isinstance(sample, dict):
                continue
            if sample.get("returnCode") != 0:
                continue
            trace_meta = sample.get("traceMeta")
            if not isinstance(trace_meta, dict):
                failures.append(f"{workload_id}: missing traceMeta")
                continue
            errors = contracts.backend_telemetry_errors(trace_meta)
            for err in errors:
                failures.append(f"{workload_id}: {err}")
            backend_id = trace_meta.get("backendId")
            if isinstance(expected_backend, str) and backend_id != expected_backend:
                failures.append(
                    f"{workload_id}: backendId mismatch expected={expected_backend} got={backend_id!r}"
                )
            if strict_no_fallback and trace_meta.get("fallbackUsed") is True:
                failures.append(f"{workload_id}: fallbackUsed=true not allowed in strict lane")

    if failures:
        print("FAIL: backend selection gate")
        for item in failures:
            print(f"  {item}")
        return 1

    print(f"PASS: backend selection gate (lane={lane})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
