#!/usr/bin/env python3
"""Blocking schema gate for config/data contracts."""

from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
for _path_entry in (str(REPO_ROOT), str(BENCH_ROOT)):
    if _path_entry not in sys.path:
        sys.path.insert(0, _path_entry)


import argparse
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import jsonschema

from bench.lib.bench_utils import detect_repo_root, load_json
from bench.lib.python_import_boundaries import validate_python_import_boundaries


@dataclass(frozen=True)
class ValidationTarget:
    schema_rel: str
    data_rel: str


OPTIONAL_GENERATED_DATA_PREFIXES = ("bench/out/",)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--root",
        default="",
        help="Repository root. Auto-detected when omitted.",
    )
    return parser.parse_args()


def is_optional_generated_data(data_rel: str) -> bool:
    normalized = data_rel.replace("\\", "/")
    return any(normalized.startswith(prefix) for prefix in OPTIONAL_GENERATED_DATA_PREFIXES)


def format_error_path(error: jsonschema.ValidationError) -> str:
    if not error.absolute_path:
        return "<root>"
    return ".".join(str(part) for part in error.absolute_path)


def validate_target(root: Path, target: ValidationTarget) -> list[str]:
    schema_path = root / target.schema_rel
    data_path = root / target.data_rel
    failures: list[str] = []

    if not schema_path.exists():
        failures.append(f"missing schema: {target.schema_rel}")
        return failures
    if not data_path.exists():
        if is_optional_generated_data(target.data_rel):
            return failures
        failures.append(f"missing data: {target.data_rel}")
        return failures

    try:
        schema_payload = load_json(schema_path)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        failures.append(f"{target.schema_rel}: schema parse failed: {exc}")
        return failures
    try:
        data_payload = load_json(data_path)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        failures.append(f"{target.data_rel}: data parse failed: {exc}")
        return failures

    try:
        validator = jsonschema.Draft202012Validator(schema_payload)
    except jsonschema.SchemaError as exc:
        failures.append(f"{target.schema_rel}: invalid schema: {exc.message}")
        return failures

    payloads: list[tuple[int | None, Any]]
    if isinstance(data_payload, list):
        payloads = list(enumerate(data_payload))
    else:
        payloads = [(None, data_payload)]

    for entry_idx, payload in payloads:
        errors = sorted(
            validator.iter_errors(payload),
            key=lambda item: tuple(str(part) for part in item.absolute_path),
        )
        for err in errors:
            location = format_error_path(err)
            if entry_idx is not None:
                if location == "<root>":
                    location = f"[{entry_idx}]"
                else:
                    location = f"[{entry_idx}].{location}"
            failures.append(f"{target.data_rel}: {location}: {err.message}")
    return failures


def load_schema_target_registry(root: Path) -> list[ValidationTarget]:
    registry_path = root / "config" / "schema-targets.json"
    if not registry_path.exists():
        raise ValueError(f"missing schema target registry: {registry_path}")
    registry_payload = load_json(registry_path)

    schema_path = root / "config" / "schema-targets.schema.json"
    if not schema_path.exists():
        raise ValueError(f"missing schema target registry schema: {schema_path}")
    schema_payload = load_json(schema_path)
    registry_validator = jsonschema.Draft202012Validator(schema_payload)

    registry_errors = sorted(
        registry_validator.iter_errors(registry_payload),
        key=lambda item: tuple(str(part) for part in item.absolute_path),
    )
    if registry_errors:
        messages = [f"{format_error_path(error)}: {error.message}" for error in registry_errors]
        raise ValueError("schema-targets.json is invalid: " + "; ".join(messages))

    targets: list[ValidationTarget] = []
    for target in registry_payload.get("targets", []):
        schema_rel = target.get("schema")
        data_rel = target.get("data")
        if not isinstance(schema_rel, str) or not isinstance(data_rel, str):
            raise ValueError(f"invalid registry target entry: {target}")
        targets.append(
            ValidationTarget(
                schema_rel=schema_rel,
                data_rel=data_rel,
            )
        )

    for glob_target in registry_payload.get("globTargets", []):
        schema_rel = glob_target.get("schema")
        glob_pattern = glob_target.get("glob")
        allow_empty = glob_target.get("allowEmpty") is True
        if not isinstance(schema_rel, str) or not isinstance(glob_pattern, str):
            raise ValueError(f"invalid registry glob target entry: {glob_target}")
        var_found = False
        for data_path in sorted(root.glob(glob_pattern)):
            if not data_path.is_file():
                continue
            var_found = True
            targets.append(
                ValidationTarget(
                    schema_rel=schema_rel,
                    data_rel=str(data_path.relative_to(root)),
                )
            )
        if not var_found and not allow_empty:
            raise ValueError(f"schema target glob has no matches: {glob_pattern}")

    return targets


def collect_targets(root: Path) -> list[ValidationTarget]:
    return load_schema_target_registry(root)


def validate_backend_lane_map_invariants(root: Path) -> list[str]:
    failures: list[str] = []
    backend_ids = ("dawn_delegate", "webkit_delegate", "doe_metal", "doe_vulkan", "doe_d3d12")
    allowed_upload_path_policies = {"allow_mapped_shortcuts", "staged_copy_only"}
    strict_staged_upload_lanes = {
        "metal_doe_comparable",
        "metal_doe_release",
        "vulkan_doe_comparable",
        "vulkan_doe_release",
        "d3d12_doe_comparable",
        "d3d12_doe_release",
    }

    runtime_policy_path = root / "config" / "backend-runtime-policy.json"
    lane_map_path = root / "config" / "backend-lane-map.json"
    cutover_policy_path = root / "config" / "backend-cutover-policy.json"

    if not runtime_policy_path.exists():
        failures.append("missing runtime policy for lane-map invariants: config/backend-runtime-policy.json")
        return failures
    if not lane_map_path.exists():
        failures.append("missing lane-map artifact: config/backend-lane-map.json")
        return failures
    if not cutover_policy_path.exists():
        failures.append("missing cutover policy for lane-map invariants: config/backend-cutover-policy.json")
        return failures

    try:
        runtime_policy = load_json(runtime_policy_path)
        lane_map = load_json(lane_map_path)
        cutover_policy = load_json(cutover_policy_path)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        failures.append(f"backend lane-map invariant parse failed: {exc}")
        return failures

    if not isinstance(runtime_policy, dict):
        failures.append("config/backend-runtime-policy.json must be a JSON object")
        return failures
    if not isinstance(lane_map, dict):
        failures.append("config/backend-lane-map.json must be a JSON object")
        return failures
    if not isinstance(cutover_policy, dict):
        failures.append("config/backend-cutover-policy.json must be a JSON object")
        return failures

    lanes_obj = runtime_policy.get("lanes")
    if not isinstance(lanes_obj, dict):
        failures.append("config/backend-runtime-policy.json: lanes must be an object")
        return failures

    expected_lane_to_backend: dict[str, str] = {}
    expected_backend_to_lanes = {backend_id: [] for backend_id in backend_ids}
    for lane_name, lane_payload in lanes_obj.items():
        if not isinstance(lane_name, str):
            failures.append("config/backend-runtime-policy.json: lane key must be a string")
            continue
        if not isinstance(lane_payload, dict):
            failures.append(f"config/backend-runtime-policy.json: lane {lane_name} must be an object")
            continue
        backend_name = lane_payload.get("defaultBackend")
        if not isinstance(backend_name, str):
            failures.append(
                f"config/backend-runtime-policy.json: lane {lane_name} defaultBackend must be a string"
            )
            continue
        upload_path_policy = lane_payload.get("uploadPathPolicy", "allow_mapped_shortcuts")
        if not isinstance(upload_path_policy, str):
            failures.append(
                f"config/backend-runtime-policy.json: lane {lane_name} uploadPathPolicy must be a string"
            )
        elif upload_path_policy not in allowed_upload_path_policies:
            failures.append(
                f"config/backend-runtime-policy.json: lane {lane_name} uploadPathPolicy has unknown value {upload_path_policy!r}"
            )
        elif lane_name in strict_staged_upload_lanes and upload_path_policy != "staged_copy_only":
            failures.append(
                f"config/backend-runtime-policy.json: strict staged-upload lane {lane_name} must set "
                "uploadPathPolicy='staged_copy_only'"
            )
        expected_lane_to_backend[lane_name] = backend_name
        if backend_name in expected_backend_to_lanes:
            expected_backend_to_lanes[backend_name].append(lane_name)
        else:
            failures.append(
                f"config/backend-runtime-policy.json: lane {lane_name} defaultBackend has unknown backend {backend_name!r}"
            )
    for backend_name in expected_backend_to_lanes:
        expected_backend_to_lanes[backend_name] = sorted(expected_backend_to_lanes[backend_name])

    lane_to_backend_obj = lane_map.get("laneToBackend")
    if not isinstance(lane_to_backend_obj, dict):
        failures.append("config/backend-lane-map.json: laneToBackend must be an object")
        return failures
    actual_lane_to_backend: dict[str, str] = {}
    for lane_name, backend_name in lane_to_backend_obj.items():
        if not isinstance(lane_name, str):
            failures.append("config/backend-lane-map.json: laneToBackend keys must be strings")
            continue
        if not isinstance(backend_name, str):
            failures.append(
                f"config/backend-lane-map.json: laneToBackend[{lane_name!r}] must be a string"
            )
            continue
        actual_lane_to_backend[lane_name] = backend_name

    expected_lanes = set(expected_lane_to_backend.keys())
    actual_lanes = set(actual_lane_to_backend.keys())
    missing_lanes = sorted(expected_lanes - actual_lanes)
    extra_lanes = sorted(actual_lanes - expected_lanes)
    if missing_lanes:
        failures.append(
            "config/backend-lane-map.json: laneToBackend missing lanes from runtime policy: "
            + ", ".join(missing_lanes)
        )
    if extra_lanes:
        failures.append(
            "config/backend-lane-map.json: laneToBackend has unknown lanes not in runtime policy: "
            + ", ".join(extra_lanes)
        )

    mismatched_lanes = sorted(
        lane_name
        for lane_name in sorted(expected_lanes & actual_lanes)
        if expected_lane_to_backend[lane_name] != actual_lane_to_backend[lane_name]
    )
    for lane_name in mismatched_lanes:
        failures.append(
            "config/backend-lane-map.json: laneToBackend mismatch for "
            f"{lane_name}: expected={expected_lane_to_backend[lane_name]!r} "
            f"got={actual_lane_to_backend[lane_name]!r}"
        )

    backend_to_lanes_obj = lane_map.get("backendToLanes")
    if not isinstance(backend_to_lanes_obj, dict):
        failures.append("config/backend-lane-map.json: backendToLanes must be an object")
        return failures
    backend_to_lanes_keys = set(backend_to_lanes_obj.keys())
    expected_backend_keys = set(backend_ids)
    missing_backends = sorted(expected_backend_keys - backend_to_lanes_keys)
    extra_backends = sorted(backend_to_lanes_keys - expected_backend_keys)
    if missing_backends:
        failures.append(
            "config/backend-lane-map.json: backendToLanes missing backend keys: "
            + ", ".join(missing_backends)
        )
    if extra_backends:
        failures.append(
            "config/backend-lane-map.json: backendToLanes has unknown backend keys: "
            + ", ".join(extra_backends)
        )

    for backend_name in backend_ids:
        lanes_value = backend_to_lanes_obj.get(backend_name)
        if not isinstance(lanes_value, list):
            failures.append(
                f"config/backend-lane-map.json: backendToLanes[{backend_name!r}] must be an array"
            )
            continue
        actual_lanes_for_backend: list[str] = []
        for entry in lanes_value:
            if not isinstance(entry, str):
                failures.append(
                    f"config/backend-lane-map.json: backendToLanes[{backend_name!r}] entries must be strings"
                )
                continue
            actual_lanes_for_backend.append(entry)
        if len(set(actual_lanes_for_backend)) != len(actual_lanes_for_backend):
            failures.append(
                f"config/backend-lane-map.json: backendToLanes[{backend_name!r}] has duplicate lane entries"
            )
        expected_for_backend = expected_backend_to_lanes.get(backend_name, [])
        if sorted(actual_lanes_for_backend) != expected_for_backend:
            failures.append(
                "config/backend-lane-map.json: backendToLanes mismatch for "
                f"{backend_name}: expected={expected_for_backend} "
                f"got={sorted(actual_lanes_for_backend)}"
            )

    source_policy_path = lane_map.get("sourcePolicyPath")
    if source_policy_path != "config/backend-runtime-policy.json":
        failures.append(
            "config/backend-lane-map.json: sourcePolicyPath must be "
            "'config/backend-runtime-policy.json'"
        )

    default_lane = runtime_policy.get("defaultLane")
    if isinstance(default_lane, str):
        if default_lane not in expected_lane_to_backend:
            failures.append(
                f"config/backend-runtime-policy.json: defaultLane {default_lane!r} is not present in lanes"
            )
    else:
        failures.append("config/backend-runtime-policy.json: defaultLane must be a string")

    cutover_obj = cutover_policy.get("cutover")
    if isinstance(cutover_obj, dict):
        target_lane = cutover_obj.get("targetLane")
        target_backend = cutover_obj.get("defaultBackend")
        if isinstance(target_lane, str):
            mapped_backend = expected_lane_to_backend.get(target_lane)
            if mapped_backend is None:
                failures.append(
                    f"config/backend-cutover-policy.json: targetLane {target_lane!r} is not present in runtime policy lanes"
                )
            elif isinstance(target_backend, str) and mapped_backend != target_backend:
                failures.append(
                    "config/backend-cutover-policy.json: cutover.defaultBackend mismatch for "
                    f"targetLane {target_lane}: expected={mapped_backend!r} got={target_backend!r}"
                )
        else:
            failures.append("config/backend-cutover-policy.json: cutover.targetLane must be a string")
    else:
        failures.append("config/backend-cutover-policy.json: cutover must be an object")

    return failures


def main() -> int:
    args = parse_args()
    try:
        root = detect_repo_root(args.root)
        targets = collect_targets(root)
    except (ValueError, OSError, UnicodeError, json.JSONDecodeError) as exc:
        print(f"FAIL: {exc}")
        return 1

    failures: list[str] = []
    for target in targets:
        failures.extend(validate_target(root, target))
    failures.extend(validate_backend_lane_map_invariants(root))
    failures.extend(validate_python_import_boundaries(root))

    if failures:
        print("FAIL: schema gate")
        for failure in failures:
            print(f"  {failure}")
        return 1

    print("PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
