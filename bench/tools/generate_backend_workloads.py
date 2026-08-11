#!/usr/bin/env python3
"""Generate backend workload contract files from a canonical catalog."""

from __future__ import annotations

import argparse
import json
import sys
from collections import OrderedDict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import jsonschema

try:
    from bench.tools._repo_import import ensure_repo_root
except ModuleNotFoundError:
    from _repo_import import ensure_repo_root

REPO_ROOT = ensure_repo_root(__file__)
from bench.lib import benchmark_ir as benchmark_ir_mod
from native_compare_modules.runner import file_sha256


CATALOG_PATH = REPO_ROOT / "bench" / "workloads" / "metadata" / "backend-workload-catalog.json"
CATALOG_SCHEMA_PATH = REPO_ROOT / "config" / "backend-workload-catalog.schema.json"
COHORTS_PATH = REPO_ROOT / "config" / "backend-workload-cohorts.json"
COHORTS_SCHEMA_PATH = REPO_ROOT / "config" / "backend-workload-cohorts.schema.json"
WORKLOAD_ORIGINS = (
    "dawn_benchmark",
    "dawn_autodiscovered",
    "doe_contract_with_dawn_mapping",
    "doe_specific",
)
WORKLOAD_ORIGIN_VALUES = set(WORKLOAD_ORIGINS)
WORKLOAD_EFFECTIVE_ORIGINS = (*WORKLOAD_ORIGINS, "hybrid")
WORKLOAD_EFFECTIVE_ORIGIN_VALUES = set(WORKLOAD_EFFECTIVE_ORIGINS)
WORKLOAD_ORIGIN_KEY = "workloadOrigin"

DEFAULT_LANE_OUTPUTS = OrderedDict(
    [
        ("generic", {"outputPath": "bench/workloads/specialized/workloads.generic.json"}),
        (
            "amd_vulkan",
            {
                "outputPath": "bench/workloads/workloads.amd.vulkan.json",
                "sourceLane": "amd_vulkan_superset_native_supported",
                "profile": "amd_vulkan",
            },
        ),
        (
            "amd_vulkan_smoke",
            {
                "outputPath": "bench/workloads/workloads.amd.vulkan.smoke.json",
                "sourceLane": "amd_vulkan_smoke",
                "profile": "amd_vulkan",
            },
        ),
        (
            "apple_metal",
            {
                "outputPath": "bench/workloads/workloads.apple.metal.json",
                "sourceLane": "apple_metal_extended",
                "profile": "apple_metal",
            },
        ),
        (
            "apple_metal_smoke",
            {
                "outputPath": "bench/workloads/workloads.apple.metal.smoke.json",
                "sourceLane": "apple_metal_smoke",
                "profile": "apple_metal",
            },
        ),
        (
            "local_d3d12",
            {
                "outputPath": "bench/workloads/workloads.local.d3d12.json",
                "sourceLane": "local_d3d12_extended",
                "profile": "local_d3d12",
            },
        ),
        (
            "local_d3d12_smoke",
            {
                "outputPath": "bench/workloads/workloads.local.d3d12.smoke.json",
                "sourceLane": "local_d3d12_smoke",
                "profile": "local_d3d12",
            },
        ),
    ]
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--catalog",
        default=str(CATALOG_PATH),
        help="Canonical backend workload catalog path.",
    )
    parser.add_argument(
        "--emit-workload-origins",
        help="Optional output path for generated workload-origin provenance.",
    )
    parser.add_argument(
        "--bootstrap-from-existing",
        action="store_true",
        help="Create/update the catalog from the existing generated workload files.",
    )
    parser.add_argument(
        "--verify",
        action="store_true",
        help="Verify generated workload files match the catalog instead of writing.",
    )
    return parser.parse_args()


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def json_text(payload: Any) -> str:
    return json.dumps(payload, indent=2) + "\n"


def write_json(path: Path, payload: Any) -> bool:
    path.parent.mkdir(parents=True, exist_ok=True)
    rendered = json_text(payload)
    if path.exists():
        current = path.read_text(encoding="utf-8")
        if current == rendered:
            return False
    path.write_text(rendered, encoding="utf-8")
    return True


def validate_catalog(catalog: dict[str, Any]) -> None:
    schema = load_json(CATALOG_SCHEMA_PATH)
    validator = jsonschema.Draft202012Validator(schema)
    errors = sorted(
        validator.iter_errors(catalog),
        key=lambda item: tuple(str(part) for part in item.absolute_path),
    )
    if errors:
        first = errors[0]
        location = ".".join(str(part) for part in first.absolute_path) if first.absolute_path else "<root>"
        raise ValueError(f"{CATALOG_SCHEMA_PATH}: {location}: {first.message}")
    validate_catalog_semantics(catalog)


def load_cohorts_config() -> dict[str, Any]:
    payload = load_json(COHORTS_PATH)
    schema = load_json(COHORTS_SCHEMA_PATH)
    validator = jsonschema.Draft202012Validator(schema)
    errors = sorted(
        validator.iter_errors(payload),
        key=lambda item: tuple(str(part) for part in item.absolute_path),
    )
    if errors:
        first = errors[0]
        location = ".".join(str(part) for part in first.absolute_path) if first.absolute_path else "<root>"
        raise ValueError(f"{COHORTS_SCHEMA_PATH}: {location}: {first.message}")
    return payload


def effective_field(item: dict[str, Any], lane_id: str, key: str, default: Any) -> Any:
    lane_override = item["lanes"].get(lane_id, {})
    if key in lane_override:
        return lane_override[key]
    if key in item.get("shared", {}):
        return item["shared"][key]
    return default


def infer_workload_origin(item: dict[str, Any], lane_id: str) -> str:
    dawn_filter = effective_field(item, lane_id, "dawnFilter", None)
    if dawn_filter is None:
        return "doe_specific"
    if isinstance(dawn_filter, str) and dawn_filter.strip() == "@autodiscover":
        return "dawn_autodiscovered"
    return "dawn_benchmark"


def resolve_workload_origin(item: dict[str, Any], lane_id: str) -> str:
    explicit_origin = effective_field(item, lane_id, WORKLOAD_ORIGIN_KEY, None)
    if explicit_origin is not None:
        if explicit_origin not in WORKLOAD_ORIGIN_VALUES:
            raise ValueError(
                f"{item['id']} lane={lane_id}: invalid workloadOrigin={explicit_origin!r}"
            )
        return explicit_origin
    return infer_workload_origin(item, lane_id)


def build_workload_origin_matrix(item: dict[str, Any]) -> dict[str, str]:
    lane_origins: dict[str, str] = {}
    for lane_id in item["lanes"]:
        lane_origins[lane_id] = resolve_workload_origin(item, lane_id)
    return lane_origins


def workload_effective_origin(item: dict[str, Any]) -> str:
    origins = set(build_workload_origin_matrix(item).values())
    if not origins:
        return "doe_specific"
    if len(origins) == 1:
        return next(iter(origins))
    return "hybrid"


def build_workload_origin_report(catalog: dict[str, Any]) -> dict[str, Any]:
    rows: list[dict[str, Any]] = []
    counts = {origin: 0 for origin in WORKLOAD_EFFECTIVE_ORIGINS}
    for item in catalog["workloads"]:
        lane_origins = build_workload_origin_matrix(item)
        effective_origin = workload_effective_origin(item)
        if effective_origin not in WORKLOAD_EFFECTIVE_ORIGIN_VALUES:
            raise ValueError(f"{item['id']}: invalid effective workload origin={effective_origin!r}")
        counts[effective_origin] = counts.get(effective_origin, 0) + 1
        rows.append(
            {
                "id": item["id"],
                "effectiveOrigin": effective_origin,
                "laneOrigins": lane_origins,
            }
        )
    return {
        "schemaVersion": 1,
        "source": "bench/workloads/metadata/backend-workload-catalog.json",
        "counts": counts,
        "workloads": rows,
    }


def validate_catalog_semantics(catalog: dict[str, Any]) -> None:
    symmetry_fields = (
        ("baselineCommandRepeat", "comparisonCommandRepeat", 1),
        ("baselineIgnoreFirstOps", "comparisonIgnoreFirstOps", 0),
        ("baselineUploadSubmitEvery", "comparisonUploadSubmitEvery", 1),
        ("baselineTimingDivisor", "comparisonTimingDivisor", 1.0),
        ("baselineUploadBufferUsage", "comparisonUploadBufferUsage", None),
    )
    problems: list[str] = []
    for item in catalog["workloads"]:
        for lane_id in item["lanes"]:
            lane_origin = resolve_workload_origin(item, lane_id)
            comparable = effective_field(item, lane_id, "comparable", False)
            benchmark_class = effective_field(item, lane_id, "benchmarkClass", None)
            ir_path = effective_field(item, lane_id, "irPath", None)
            ir_scenario = effective_field(item, lane_id, "irScenario", None)
            commands_path = effective_field(item, lane_id, "commandsPath", None)
            if benchmark_class is None:
                benchmark_class = "comparable" if comparable else "directional"
            elif isinstance(benchmark_class, str):
                benchmark_class = benchmark_class.strip().lower()
            else:
                problems.append(
                    f"{item['id']} lane={lane_id}: benchmarkClass must be a string when present"
                )
                continue
            if benchmark_class not in {"comparable", "directional"}:
                problems.append(
                    f"{item['id']} lane={lane_id}: invalid benchmarkClass={benchmark_class!r}"
                )
                continue
            if benchmark_class == "comparable" and not comparable:
                problems.append(
                    f"{item['id']} lane={lane_id}: benchmarkClass=comparable requires comparable=true"
                )
                continue
            if benchmark_class == "directional" and comparable:
                problems.append(
                    f"{item['id']} lane={lane_id}: benchmarkClass=directional requires comparable=false"
                )
                continue
            if ir_path is not None and not isinstance(ir_path, str):
                problems.append(f"{item['id']} lane={lane_id}: irPath must be a string when present")
                continue
            if ir_scenario is not None and not isinstance(ir_scenario, str):
                problems.append(f"{item['id']} lane={lane_id}: irScenario must be a string when present")
                continue
            if ir_path is not None:
                if ir_scenario is None:
                    problems.append(
                        f"{item['id']} lane={lane_id}: irScenario is required when irPath is present"
                    )
                if commands_path is not None:
                    problems.append(
                        f"{item['id']} lane={lane_id}: ir-backed workloads must not author commandsPath in the catalog"
                    )
            if comparable and lane_origin == "doe_specific":
                problems.append(
                    f"{item['id']} lane={lane_id}: comparable lanes must not be provenance='doe_specific'"
                )
            if not comparable:
                continue
            for left_key, right_key, default in symmetry_fields:
                left_value = effective_field(item, lane_id, left_key, default)
                right_value = effective_field(item, lane_id, right_key, default)
                if left_value != right_value:
                    problems.append(
                        f"{item['id']} lane={lane_id}: {left_key}={left_value!r} != {right_key}={right_value!r}"
                    )
    for item in catalog["workloads"]:
        shared = item.get("shared", {})
        shared_bc = shared.get("benchmarkClass")
        shared_comparable = shared.get("comparable")
        claim_eligible = shared.get("claimEligible")
        if claim_eligible is not None and shared_bc is not None:
            eff_bc = str(shared_bc).strip().lower()
            if eff_bc == "comparable" and not claim_eligible:
                problems.append(
                    f"{item['id']}: shared benchmarkClass=comparable requires claimEligible=true"
                )
            if eff_bc == "directional" and claim_eligible:
                problems.append(
                    f"{item['id']}: shared benchmarkClass=directional requires claimEligible=false"
                )
        elif claim_eligible is not None and shared_comparable is not None and shared_bc is None:
            if shared_comparable and not claim_eligible:
                problems.append(
                    f"{item['id']}: shared comparable=true requires claimEligible=true"
                )
            if not shared_comparable and claim_eligible:
                problems.append(
                    f"{item['id']}: shared comparable=false requires claimEligible=false"
                )
    if problems:
        raise ValueError(
            "comparable workload contract asymmetry detected:\n" + "\n".join(problems)
        )


def validate_ir_catalog(catalog: dict[str, Any]) -> None:
    ir_rows = []
    for item in catalog["workloads"]:
        for lane_id in item["lanes"]:
            ir_path = effective_field(item, lane_id, "irPath", None)
            ir_scenario = effective_field(item, lane_id, "irScenario", None)
            if ir_path is None:
                continue
            ir_rows.append((item["id"], lane_id, ir_path, ir_scenario))
    if not ir_rows:
        return
    for workload_id, lane_id, ir_path, ir_scenario in ir_rows:
        benchmark_ir_mod.load_ir_document(REPO_ROOT / str(ir_path))
        if not isinstance(ir_scenario, str):
            raise ValueError(f"{workload_id} lane={lane_id}: invalid IR scenario")
        benchmark_ir_mod.load_ir_scenario(REPO_ROOT / str(ir_path), ir_scenario)


def bootstrap_catalog() -> dict[str, Any]:
    lane_outputs = OrderedDict(DEFAULT_LANE_OUTPUTS)
    lane_rows: dict[str, dict[str, dict[str, Any]]] = {}
    all_ids: set[str] = set()
    for lane_id, entry in lane_outputs.items():
        payload = load_json(REPO_ROOT / entry["outputPath"])
        rows = payload.get("workloads")
        if not isinstance(rows, list):
            raise ValueError(f"invalid workloads payload: {entry['outputPath']}")
        row_map: dict[str, dict[str, Any]] = {}
        for row in rows:
            workload_id = row["id"]
            row_map[workload_id] = row
            all_ids.add(workload_id)
        lane_rows[lane_id] = row_map

    ordered_ids: list[str] = []
    seen_ids: set[str] = set()
    for lane_id in lane_outputs:
        for workload_id in lane_rows[lane_id]:
            if workload_id in seen_ids:
                continue
            seen_ids.add(workload_id)
            ordered_ids.append(workload_id)

    workloads = []
    for workload_id in ordered_ids:
        present_rows = [lane_rows[lane][workload_id] for lane in lane_outputs if workload_id in lane_rows[lane]]
        has_ir_source = any("irPath" in row for row in present_rows)
        generated_ir_keys = {
            "commandsPath",
            "planPath",
            "planSchemaVersion",
            "planHash",
            "planCommandCount",
            "planDispatchCount",
            "planBufferWriteCount",
            "compatibilityCommandHash",
            "sourceIrSha256",
            "compatibilityCommandsSha256",
        }
        field_order = [
            key
            for key in present_rows[0].keys()
            if key != "id" and (not has_ir_source or key not in generated_ir_keys)
        ]
        common_keys = set(present_rows[0].keys())
        for row in present_rows[1:]:
            common_keys &= set(row.keys())
        shared: dict[str, Any] = {}
        for key in field_order:
            if key not in common_keys:
                continue
            first_value = present_rows[0][key]
            if all(row[key] == first_value for row in present_rows[1:]):
                shared[key] = first_value
        if "id" in shared:
            shared.pop("id")

        lane_overrides: dict[str, dict[str, Any]] = OrderedDict()
        for lane_id in lane_outputs:
            row = lane_rows[lane_id].get(workload_id)
            if row is None:
                continue
            override = OrderedDict()
            for key in field_order:
                if key not in row:
                    continue
                value = row[key]
                if key == "id":
                    continue
                if shared.get(key) == value:
                    continue
                if has_ir_source and key in generated_ir_keys:
                    continue
                override[key] = value
            lane_overrides[lane_id] = override

        workloads.append(
            OrderedDict(
                [
                    ("id", workload_id),
                    ("fieldOrder", field_order),
                    ("shared", OrderedDict(shared.items())),
                    ("lanes", lane_overrides),
                ]
            )
        )

    catalog = OrderedDict(
        [
            ("schemaVersion", 1),
            ("laneOutputs", lane_outputs),
            ("workloads", workloads),
        ]
    )
    validate_catalog(catalog)
    return catalog


def materialize_lane(catalog: dict[str, Any], lane_id: str) -> dict[str, Any]:
    lane_outputs = catalog.get("laneOutputs", {})
    lane_entry = lane_outputs.get(lane_id, {}) if isinstance(lane_outputs, dict) else {}
    source_lane = (
        lane_entry.get("sourceLane", lane_id)
        if isinstance(lane_entry, dict)
        else lane_id
    )
    profile = lane_entry.get("profile") if isinstance(lane_entry, dict) else None
    cohorts_payload = load_cohorts_config()
    profile_cohorts = (
        cohorts_payload["profiles"].get(profile, {})
        if isinstance(profile, str)
        else {}
    )
    smoke_ids = set(profile_cohorts.get("smoke", []))
    governed_ids = set(profile_cohorts.get("governed", []))
    regression_ids = set(profile_cohorts.get("regression", []))
    workloads = []
    for item in catalog["workloads"]:
        lane_override = item["lanes"].get(source_lane)
        if lane_override is None:
            continue
        row = OrderedDict()
        row["id"] = item["id"]
        for key in item.get("fieldOrder", []):
            if key in lane_override:
                row[key] = lane_override[key]
            elif key in item["shared"]:
                row[key] = item["shared"][key]
        for key, value in item["shared"].items():
            if key not in row:
                row[key] = value
        for key, value in lane_override.items():
            if key not in row:
                row[key] = value
        if row.get("pathAsymmetry") is True:
            row["comparable"] = False
            row["claimEligible"] = False
            row["benchmarkClass"] = "directional"
            row["directionalReason"] = "path_asymmetry"
        if "benchmarkClass" not in row:
            row["benchmarkClass"] = "comparable" if bool(row.get("comparable", False)) else "directional"
        row[WORKLOAD_ORIGIN_KEY] = resolve_workload_origin(item, source_lane)
        ir_path = row.get("irPath")
        ir_scenario = row.get("irScenario")
        if ir_path is not None:
            if not isinstance(ir_path, str) or not isinstance(ir_scenario, str):
                raise ValueError(
                    f"{item['id']} lane={source_lane}: ir-backed workload requires string irPath/irScenario"
                )
            ir_artifacts = benchmark_ir_mod.materialize_plan_artifacts(
                REPO_ROOT / ir_path,
                ir_scenario,
            )
            row["planPath"] = ir_artifacts["planPath"]
            row["planSchemaVersion"] = ir_artifacts["plan"]["schemaVersion"]
            row["planHash"] = ir_artifacts["planSha256"]
            row["planCommandCount"] = ir_artifacts["commandCount"]
            row["planDispatchCount"] = ir_artifacts["dispatchCount"]
            row["planBufferWriteCount"] = ir_artifacts["bufferWriteCount"]
            row["planBufferLoadCount"] = ir_artifacts["bufferLoadCount"]
            row["compatibilityCommandHash"] = ir_artifacts["compatibilityCommandsSha256"]
            row["sourceIrSha256"] = ir_artifacts["sourceIrSha256"]
            row["commandsPath"] = ir_artifacts["commandsPath"]
        if profile is not None:
            cohort_tags: list[str] = []
            workload_id = item["id"]
            if workload_id in smoke_ids:
                cohort_tags.append("smoke")
            if workload_id in governed_ids:
                cohort_tags.append("governed")
            if workload_id in regression_ids:
                cohort_tags.append("regression")
            if workload_id not in governed_ids:
                cohort_tags.append("exploration")
            row.pop("suiteTags", None)
            row["cohorts"] = cohort_tags
        workloads.append(row)
    return OrderedDict(
        [
            ("schemaVersion", 1),
            ("ownership", "generated"),
            (
                "generatorId",
                "bench.tools.generate_backend_workloads:materialize_lane",
            ),
            ("generatorInputHash", file_sha256(CATALOG_PATH)),
            (
                "generatedAt",
                datetime.fromtimestamp(
                    CATALOG_PATH.stat().st_mtime,
                    timezone.utc,
                ).isoformat(),
            ),
            ("workloads", workloads),
        ]
    )


def verify_lane(path: Path, expected: dict[str, Any]) -> bool:
    if not path.exists():
        return False
    current = load_json(path)
    return current == expected


def generate_from_catalog(catalog: dict[str, Any], verify_only: bool) -> None:
    mismatches: list[str] = []
    for lane_id, lane_entry in catalog["laneOutputs"].items():
        payload = materialize_lane(catalog, lane_id)
        output_path = REPO_ROOT / lane_entry["outputPath"]
        if verify_only:
            if not verify_lane(output_path, payload):
                mismatches.append(str(output_path))
        else:
            write_json(output_path, payload)
        for row in payload["workloads"]:
            ir_path = row.get("irPath")
            ir_scenario = row.get("irScenario")
            if ir_path is None:
                continue
            artifacts = benchmark_ir_mod.materialize_plan_artifacts(REPO_ROOT / ir_path, ir_scenario)
            plan_path = REPO_ROOT / str(row["planPath"])
            commands_path = REPO_ROOT / str(row["commandsPath"])
            legacy_commands_path = REPO_ROOT / "examples" / f"{ir_scenario}_commands.json"
            if verify_only:
                if not verify_lane(plan_path, artifacts["plan"]):
                    mismatches.append(str(plan_path))
                if not verify_lane(commands_path, artifacts["commands"]):
                    mismatches.append(str(commands_path))
                if not verify_lane(legacy_commands_path, artifacts["commands"]):
                    mismatches.append(str(legacy_commands_path))
            else:
                write_json(plan_path, artifacts["plan"])
                write_json(commands_path, artifacts["commands"])
                write_json(legacy_commands_path, artifacts["commands"])
    if mismatches:
        raise SystemExit("generated workload files diverged:\n" + "\n".join(mismatches))


def main() -> None:
    args = parse_args()
    catalog_path = Path(args.catalog)
    if args.bootstrap_from_existing:
        catalog = bootstrap_catalog()
        write_json(catalog_path, catalog)
    else:
        catalog = load_json(catalog_path)
    validate_catalog(catalog)
    validate_ir_catalog(catalog)
    if args.emit_workload_origins is not None:
        write_json(Path(args.emit_workload_origins), build_workload_origin_report(catalog))
    generate_from_catalog(catalog, verify_only=args.verify)


if __name__ == "__main__":
    main()
