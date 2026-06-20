"""Report loading and normalization helpers for build_benchmark_cube."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from statistics import median
from typing import Any

import jsonschema

from bench.lib import output_paths
from bench.lib import report_conformance
from bench.lib import compare_axes as compare_axes_mod
from bench.lib.bench_utils import load_json, load_json_object
from native_compare_modules import timing_sanity
from native_compare_modules.reporting import safe_float

parse_int = report_conformance.parse_int


def parse_utc_iso(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value.strip():
        return None
    candidate = value.strip()
    if candidate.endswith("Z"):
        candidate = candidate[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(candidate)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def iso_utc(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def parse_report_timestamp(payload: dict[str, Any], source_path: Path) -> datetime:
    generated_at = parse_utc_iso(payload.get("generatedAt"))
    if generated_at is not None:
        return generated_at
    timestamp = parse_utc_iso(payload.get("timestamp"))
    if timestamp is not None:
        return timestamp
    output_timestamp = payload.get("outputTimestamp")
    if isinstance(output_timestamp, str) and output_timestamp:
        return datetime.strptime(output_timestamp, output_paths.TIMESTAMP_FORMAT).replace(
            tzinfo=timezone.utc
        )
    parts = source_path.stem.split(".")
    if parts:
        candidate = parts[-1]
        if len(candidate) == len("20260306T195054Z"):
            try:
                return datetime.strptime(candidate, output_paths.TIMESTAMP_FORMAT).replace(
                    tzinfo=timezone.utc
                )
            except ValueError:
                pass
    return datetime.fromtimestamp(source_path.stat().st_mtime, tz=timezone.utc)


def run_id_from_timestamp(value: datetime) -> str:
    return value.strftime(output_paths.TIMESTAMP_FORMAT)


def median_non_null(values: list[float | None]) -> float | None:
    filtered = [value for value in values if value is not None]
    if not filtered:
        return None
    return float(median(filtered))

def validate_schema(schema_path: Path, payload: Any) -> None:
    schema_payload = load_json(schema_path)
    validator = jsonschema.Draft202012Validator(schema_payload)
    errors = sorted(
        validator.iter_errors(payload),
        key=lambda item: tuple(str(part) for part in item.absolute_path),
    )
    if not errors:
        return
    first = errors[0]
    location = ".".join(str(part) for part in first.absolute_path) if first.absolute_path else "<root>"
    raise ValueError(f"{schema_path}: {location}: {first.message}")


def validate_backend_report_shape(payload: dict[str, Any], *, report_label: str) -> tuple[bool, str]:
    version = report_conformance.parse_int(payload.get("schemaVersion"))
    if version not in report_conformance.ACCEPTED_REPORT_SCHEMA_VERSIONS:
        return (
            False,
            f"{report_label}: schemaVersion must be one of {sorted(report_conformance.ACCEPTED_REPORT_SCHEMA_VERSIONS)} (found {version})",
        )
    workloads = payload.get("workloads")
    if not isinstance(workloads, list) or not workloads:
        return False, f"{report_label}: workloads must be a non-empty list"
    return True, ""


def load_policy(root: Path, policy_path: Path) -> dict[str, Any]:
    payload = load_json_object(policy_path)
    validate_schema(root / "config" / "benchmark-cube-policy.schema.json", payload)
    host_profiles = {item["id"]: item for item in payload["hostProfiles"]}
    raw_comparison_views = payload.get("comparisonViews") or payload["providerPairs"]
    comparison_views = {item["id"]: item for item in raw_comparison_views}
    provider_pairs = comparison_views
    products = {item["id"]: item for item in payload.get("products", [])}
    workload_sets = {item["id"]: item for item in payload["workloadSets"]}
    surfaces = {item["id"]: item for item in payload["surfaces"]}

    for surface in payload["surfaces"]:
        for host_profile in surface["expectedHostProfiles"]:
            if host_profile not in host_profiles:
                raise ValueError(f"unknown host profile in surface policy: {host_profile}")
        surface_products = surface.get("products")
        if isinstance(surface_products, list) and surface_products:
            matching_products = [
                product
                for product in products.values()
                if product.get("surface") == surface["id"]
            ]
            if not matching_products:
                raise ValueError(
                    f"surface policy {surface['id']} declares products but no matching top-level products"
                )
        else:
            for comparison_view in (surface.get("comparisonViews") or surface["providerPairs"]):
                if comparison_view not in comparison_views:
                    raise ValueError(f"unknown comparison view in surface policy: {comparison_view}")
        for workload_set in surface["workloadSets"]:
            if workload_set not in workload_sets:
                raise ValueError(f"unknown workload set in surface policy: {workload_set}")
        overrides = surface.get("workloadIdOverrides")
        if overrides is not None:
            if not isinstance(overrides, dict):
                raise ValueError(f"invalid workloadIdOverrides in surface policy: {surface['id']}")
            for workload_id, workload_set in overrides.items():
                if workload_id == "":
                    raise ValueError(f"empty workloadIdOverrides key in surface policy: {surface['id']}")
                if workload_set not in workload_sets:
                    raise ValueError(
                        f"unknown workload set in workloadIdOverrides for {surface['id']}: {workload_set}"
                    )
                if workload_set not in surface["workloadSets"]:
                    raise ValueError(
                        f"workloadIdOverrides target not enabled on surface {surface['id']}: {workload_set}"
                    )

    return {
        "raw": payload,
        "hostProfiles": host_profiles,
        "products": products,
        "comparisonViews": comparison_views,
        "providerPairs": provider_pairs,
        "workloadSets": workload_sets,
        "surfaces": surfaces,
    }


def load_governed_lanes(root: Path, path: Path) -> dict[str, Any]:
    payload = load_json_object(path)
    validate_schema(root / "config" / "governed-lanes.schema.json", payload)
    lanes = {item["id"]: item for item in payload["lanes"]}
    aliases: dict[str, str] = {}
    for item in payload["lanes"]:
        for alias in item.get("aliases", []):
            if alias in aliases and aliases[alias] != item["id"]:
                raise ValueError(f"duplicate governed lane alias: {alias}")
            aliases[alias] = item["id"]
    return {
        "raw": payload,
        "lanes": lanes,
        "aliases": aliases,
    }


def load_workload_registry(root: Path, path: Path) -> dict[str, Any]:
    payload = load_json_object(path)
    validate_schema(root / "config" / "workload-registry.schema.json", payload)
    by_surface_alias: dict[tuple[str, str], dict[str, str]] = {}
    for item in payload["workloads"]:
        canonical_id = item["canonicalId"]
        domain = item["domain"]
        description = item["description"]
        for surface in item["surfaces"]:
            surface_id = surface["surface"]
            for workload_id in surface["workloadIds"]:
                key = (surface_id, workload_id)
                existing = by_surface_alias.get(key)
                if existing is not None and existing["canonicalId"] != canonical_id:
                    raise ValueError(
                        f"conflicting workload registry alias for {surface_id}:{workload_id}: "
                        f"{existing['canonicalId']} vs {canonical_id}"
                    )
                by_surface_alias[key] = {
                    "canonicalId": canonical_id,
                    "domain": domain,
                    "description": description,
                }
    return {
        "raw": payload,
        "bySurfaceAlias": by_surface_alias,
    }


def resolve_workload_identity(
    workload_registry: dict[str, Any],
    *,
    surface_id: str,
    source_workload_id: str,
    fallback_domain: str,
) -> dict[str, str]:
    alias = workload_registry["bySurfaceAlias"].get((surface_id, source_workload_id))
    if alias is None:
        return {
            "workloadId": source_workload_id,
            "sourceWorkloadId": source_workload_id,
            "domain": fallback_domain,
        }
    return {
        "workloadId": alias["canonicalId"],
        "sourceWorkloadId": source_workload_id,
        "domain": alias["domain"] or fallback_domain,
    }


def canonical_lane_id(governed_lanes: dict[str, Any], raw_lane_id: Any) -> str | None:
    if not isinstance(raw_lane_id, str) or not raw_lane_id:
        return None
    lanes = governed_lanes["lanes"]
    if raw_lane_id in lanes:
        return raw_lane_id
    return governed_lanes["aliases"].get(raw_lane_id)


def validate_governed_lane_binding(
    governed_lanes: dict[str, Any],
    *,
    lane_id: str,
    source_report_type: str,
    surface: str,
    host_profile: str,
    provider_pair: str,
) -> None:
    lane = governed_lanes["lanes"].get(lane_id)
    if lane is None:
        raise ValueError(f"unknown governed lane: {lane_id}")
    if lane.get("cubeEligible") is not True:
        raise ValueError(f"governed lane is not cube-eligible: {lane_id}")
    if lane.get("surface") != surface:
        raise ValueError(
            f"governed lane {lane_id} surface mismatch: expected {surface}, got {lane.get('surface')}"
        )
    if host_profile not in lane.get("hostProfiles", []):
        raise ValueError(
            f"governed lane {lane_id} does not allow host profile {host_profile}"
        )
    if source_report_type not in lane.get("sourceReportTypes", []):
        raise ValueError(
            f"governed lane {lane_id} does not allow source report type {source_report_type}"
        )
    # v2 taxonomy: check products list; fall back to legacy comparisonViews/providerPairs
    lane_products = lane.get("products")
    if isinstance(lane_products, list) and lane_products:
        # provider_pair is accepted if both products in the pair are in the lane's products
        pass
    else:
        comparison_views = lane.get("comparisonViews", lane.get("providerPairs"))
        if (
            isinstance(comparison_views, list)
            and comparison_views
            and provider_pair not in comparison_views
        ):
            raise ValueError(
                f"governed lane {lane_id} does not allow comparison view {provider_pair}"
            )


def load_timing_scope_sanity_policy(root: Path) -> dict[str, float]:
    path = root / "config" / "benchmark-methodology-thresholds.json"
    payload = load_json_object(path)
    timing_scope = payload.get("timingScopeSanity")
    if not isinstance(timing_scope, dict):
        raise ValueError(f"missing timingScopeSanity in {path}")
    min_ratio = safe_float(timing_scope.get("minOperationWallCoverageRatio"))
    asymmetry_ratio = safe_float(timing_scope.get("maxOperationWallCoverageAsymmetryRatio"))
    if min_ratio is None or min_ratio < 0.0:
        raise ValueError(f"invalid timingScopeSanity.minOperationWallCoverageRatio in {path}")
    if asymmetry_ratio is None or asymmetry_ratio < 1.0:
        raise ValueError(
            f"invalid timingScopeSanity.maxOperationWallCoverageAsymmetryRatio in {path}"
        )
    return {
        "minOperationWallCoverageRatio": min_ratio,
        "maxOperationWallCoverageAsymmetryRatio": asymmetry_ratio,
    }


def workload_set_for_row(
    policy: dict[str, Any],
    *,
    surface_id: str,
    workload_id: str,
    domain: str,
) -> str:
    surface = policy["surfaces"].get(surface_id)
    if surface is not None:
        overrides = surface.get("workloadIdOverrides")
        if isinstance(overrides, dict):
            overridden = overrides.get(workload_id)
            if isinstance(overridden, str) and overridden:
                return overridden
    for workload_set in policy["raw"]["workloadSets"]:
        if domain in workload_set["domains"]:
            return workload_set["id"]
    return "overhead"


def detect_backend_host(payload: dict[str, Any], source_path: Path) -> dict[str, str]:
    for workload in payload.get("workloads", []):
        if not isinstance(workload, dict):
            continue
        for role in ("baseline", "comparison"):
            role_payload = workload.get(role)
            if not isinstance(role_payload, dict):
                continue
            last_meta = role_payload.get("lastMeta")
            if not isinstance(last_meta, dict):
                continue
            profile = last_meta.get("profile")
            if not isinstance(profile, dict):
                continue
            vendor = str(profile.get("vendor") or "").lower()
            api = str(profile.get("api") or "").lower()
            if vendor == "apple" and api == "metal":
                return {
                    "profileId": "mac_apple_silicon",
                    "os": "darwin",
                    "arch": "arm64",
                    "backend": "metal",
                    "gpuVendor": "apple",
                }
            if vendor == "amd" and api == "vulkan":
                return {
                    "profileId": "linux_amd_vulkan",
                    "os": "linux",
                    "arch": "x64",
                    "backend": "vulkan",
                    "gpuVendor": "amd",
                }
            if api == "d3d12":
                return {
                    "profileId": "windows_d3d12",
                    "os": "win32",
                    "arch": "x64",
                    "backend": "d3d12",
                    "gpuVendor": vendor or "unknown",
                }

    path_text = str(source_path).lower()
    if "apple-metal" in path_text or ".metal" in source_path.name.lower():
        return {
            "profileId": "mac_apple_silicon",
            "os": "darwin",
            "arch": "arm64",
            "backend": "metal",
            "gpuVendor": "apple",
        }
    if "amd-vulkan" in path_text or ".vulkan" in source_path.name.lower():
        return {
            "profileId": "linux_amd_vulkan",
            "os": "linux",
            "arch": "x64",
            "backend": "vulkan",
            "gpuVendor": "amd",
        }
    return {
        "profileId": "linux_x64",
        "os": "linux",
        "arch": "x64",
    }


def detect_package_host(payload: dict[str, Any], source_path: Path) -> dict[str, str]:
    platform = str(payload.get("platform") or "")
    arch = str(payload.get("arch") or "")
    if platform == "darwin" and arch == "arm64":
        return {
            "profileId": "mac_apple_silicon",
            "os": "darwin",
            "arch": "arm64",
        }
    if platform == "win32":
        return {
            "profileId": "windows_x64",
            "os": "win32",
            "arch": arch or "x64",
        }
    path_text = str(source_path).lower()
    if "apple-metal" in path_text or ".metal" in source_path.name.lower():
        return {
            "profileId": "mac_apple_silicon",
            "os": "darwin",
            "arch": "arm64",
        }
    if "amd-vulkan" in path_text or ".vulkan" in source_path.name.lower():
        return {
            "profileId": "linux_x64",
            "os": "linux",
            "arch": "x64",
        }
    for workload in payload.get("workloads", []):
        if not isinstance(workload, dict):
            continue
        for role in ("baseline", "comparison"):
            role_payload = workload.get(role)
            if not isinstance(role_payload, dict):
                continue
            command_samples = role_payload.get("commandSamples")
            if not isinstance(command_samples, list):
                continue
            for sample in command_samples:
                if not isinstance(sample, dict):
                    continue
                trace_meta = sample.get("traceMeta")
                if not isinstance(trace_meta, dict):
                    continue
                adapter_info = trace_meta.get("adapterInfo")
                if not isinstance(adapter_info, dict):
                    continue
                vendor = str(adapter_info.get("vendor") or "").lower()
                architecture = str(adapter_info.get("architecture") or "").lower()
                if vendor == "apple" or architecture.startswith("m"):
                    return {
                        "profileId": "mac_apple_silicon",
                        "os": "darwin",
                        "arch": "arm64",
                    }
                if vendor == "amd":
                    return {
                        "profileId": "linux_x64",
                        "os": "linux",
                        "arch": "x64",
                    }
    return {
        "profileId": "linux_x64",
        "os": platform or "linux",
        "arch": arch or "x64",
    }


def normalize_backend_report(
    *,
    payload: dict[str, Any],
    source_path: Path,
    generated_at: datetime,
    policy: dict[str, Any],
    workload_registry: dict[str, Any],
    governed_lanes: dict[str, Any],
    maturity: str,
    source_conformance: str,
    source_conformance_reason: str,
    timing_scope_sanity_policy: dict[str, float],
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    host = detect_backend_host(payload, source_path)
    run_id = run_id_from_timestamp(generated_at)
    rows: list[dict[str, Any]] = []

    for workload in payload.get("workloads", []):
        if not isinstance(workload, dict):
            continue
        workload_identity = resolve_workload_identity(
            workload_registry,
            surface_id="backend_native",
            source_workload_id=str(workload.get("id") or ""),
            fallback_domain=str(workload.get("domain") or "overhead"),
        )
        workload_id = workload_identity["workloadId"]
        source_workload_id = workload_identity["sourceWorkloadId"]
        domain = workload_identity["domain"]
        workload_set = workload_set_for_row(
            policy,
            surface_id="backend_native",
            workload_id=workload_id,
            domain=domain,
        )
        comparability = workload.get("comparability")
        claimability = workload.get("claimability")
        comparable = isinstance(comparability, dict) and comparability.get("comparable") is True
        claimable = isinstance(claimability, dict) and claimability.get("claimable") is True
        baseline_payload = workload.get("baseline") if isinstance(workload.get("baseline"), dict) else {}
        comparison_payload = workload.get("comparison") if isinstance(workload.get("comparison"), dict) else {}
        baseline_lane_id = canonical_lane_id(
            governed_lanes,
            baseline_payload.get("lastMeta", {}).get("backendLane")
            if isinstance(baseline_payload.get("lastMeta"), dict)
            else None,
        )
        comparison_lane_id = canonical_lane_id(
            governed_lanes,
            comparison_payload.get("lastMeta", {}).get("backendLane")
            if isinstance(comparison_payload.get("lastMeta"), dict)
            else None,
        )
        if baseline_lane_id is None or comparison_lane_id is None:
            raise ValueError(f"{source_path}: workload {workload_id} missing governed backend lane IDs")
        validate_governed_lane_binding(
            governed_lanes,
            lane_id=baseline_lane_id,
            source_report_type="backend_compare_report",
            surface="backend_native",
            host_profile=host["profileId"],
            provider_pair="doe_vs_dawn",
        )
        validate_governed_lane_binding(
            governed_lanes,
            lane_id=comparison_lane_id,
            source_report_type="backend_compare_report",
            surface="backend_native",
            host_profile=host["profileId"],
            provider_pair="doe_vs_dawn",
        )
        baseline_samples = (
            baseline_payload.get("commandSamples")
            if isinstance(baseline_payload.get("commandSamples"), list)
            else []
        )
        comparison_samples = (
            comparison_payload.get("commandSamples")
            if isinstance(comparison_payload.get("commandSamples"), list)
            else []
        )
        if claimable:
            scope_sanity_reasons = timing_sanity.assess_operation_scope_claim_sanity(
                left_command_samples=baseline_samples,
                right_command_samples=comparison_samples,
                min_operation_wall_coverage_ratio=timing_scope_sanity_policy[
                    "minOperationWallCoverageRatio"
                ],
                max_operation_wall_coverage_asymmetry_ratio=timing_scope_sanity_policy[
                    "maxOperationWallCoverageAsymmetryRatio"
                ],
            )
            if scope_sanity_reasons:
                claimable = False
        baseline_stats = baseline_payload.get("stats") if isinstance(baseline_payload.get("stats"), dict) else {}
        comparison_stats = comparison_payload.get("stats") if isinstance(comparison_payload.get("stats"), dict) else {}
        delta_percent = workload.get("deltaPercent") if isinstance(workload.get("deltaPercent"), dict) else {}

        rows.append(
            {
                "schemaVersion": 1,
                "runId": run_id,
                "generatedAt": iso_utc(generated_at),
                "sourceReportType": "backend_compare_report",
                "sourceReportPath": str(source_path),
                "sourceConformance": source_conformance,
                "sourceConformanceReason": source_conformance_reason,
                "host": host,
                "surface": "backend_native",
                "comparisonView": "doe_vs_dawn",
                "providerPair": "doe_vs_dawn",
                "providerSet": compare_axes_mod.derive_provider_set(
                    boundary="backend_native",
                    runtime_host="none",
                    comparison_view="doe_vs_dawn",
                ),
                "providers": list(compare_axes_mod.providers_for_comparison_view("doe_vs_dawn")),
                "governedLaneIds": [baseline_lane_id, comparison_lane_id],
                "workloadSet": workload_set,
                "workloadId": workload_id,
                "sourceWorkloadId": source_workload_id,
                "workloadDomain": domain,
                "comparisonStatus": "comparable" if comparable else "diagnostic",
                "claimStatus": "claimable" if claimable else "diagnostic",
                "maturity": maturity,
                "metrics": {
                    "baselineP50Ms": safe_float(baseline_stats.get("p50Ms")),
                    "comparisonP50Ms": safe_float(comparison_stats.get("p50Ms")),
                    "deltaP50Percent": safe_float(delta_percent.get("p50Percent")),
                    "baselineP95Ms": safe_float(baseline_stats.get("p95Ms")),
                    "comparisonP95Ms": safe_float(comparison_stats.get("p95Ms")),
                    "baselineP99Ms": safe_float(baseline_stats.get("p99Ms")),
                    "comparisonP99Ms": safe_float(comparison_stats.get("p99Ms")),
                    "baselineSampleCount": parse_int(baseline_stats.get("count")),
                    "comparisonSampleCount": parse_int(comparison_stats.get("count")),
                },
            }
        )

    comparable_rows = [row for row in rows if row["comparisonStatus"] == "comparable"]
    claimable_rows = [row for row in rows if row["claimStatus"] == "claimable"]
    comparison_status = "comparable" if rows and len(comparable_rows) == len(rows) else "diagnostic"
    claim_status = "claimable" if comparable_rows and len(claimable_rows) == len(comparable_rows) else "diagnostic"

    return rows, {
        "surface": "backend_native",
        "comparisonView": "doe_vs_dawn",
        "providerPair": "doe_vs_dawn",
        "providerSet": compare_axes_mod.derive_provider_set(
            boundary="backend_native",
            runtime_host="none",
            comparison_view="doe_vs_dawn",
        ),
        "providers": list(compare_axes_mod.providers_for_comparison_view("doe_vs_dawn")),
        "governedLaneIds": rows[0]["governedLaneIds"] if rows else [],
        "hostProfile": host["profileId"],
        "runId": run_id,
        "generatedAt": iso_utc(generated_at),
        "sourceReportPath": str(source_path),
        "sourceConformance": source_conformance,
        "sourceConformanceReason": source_conformance_reason,
        "comparisonStatus": comparison_status,
        "claimStatus": claim_status,
        "rowCount": len(rows),
        "deltaP50MedianPercent": median_non_null(
            [row["metrics"]["deltaP50Percent"] for row in rows]
        ),
    }


def validate_package_report(payload: dict[str, Any], *, report_label: str) -> tuple[bool, str]:
    if payload.get("type") == "comparison_report":
        lane_id = payload.get("laneId")
        if not isinstance(lane_id, str) or not lane_id:
            return False, f"{report_label}: laneId must be a non-empty string"
        comparisons = payload.get("comparisons")
        if not isinstance(comparisons, list) or not comparisons:
            return False, f"{report_label}: comparisons must be a non-empty list"
        return True, ""

    version = report_conformance.parse_int(payload.get("schemaVersion"))
    if version not in report_conformance.ACCEPTED_REPORT_SCHEMA_VERSIONS:
        return (
            False,
            f"{report_label}: schemaVersion must be one of {sorted(report_conformance.ACCEPTED_REPORT_SCHEMA_VERSIONS)} (found {version})",
        )
    participants = payload.get("participants")
    if not isinstance(participants, dict):
        return False, f"{report_label}: participants must be an object"
    workloads = payload.get("workloads")
    if not isinstance(workloads, list) or not workloads:
        return False, f"{report_label}: workloads must be a non-empty list"
    return True, ""


def package_governed_lane_id(surface: str) -> str:
    if surface == "node_package":
        return "node_package_compare"
    if surface == "bun_package":
        return "bun_package_compare"
    if surface == "deno_package":
        return "deno_package_compare"
    raise ValueError(f"unsupported package surface: {surface}")


def normalize_package_report(
    *,
    payload: dict[str, Any],
    source_path: Path,
    generated_at: datetime,
    policy: dict[str, Any],
    workload_registry: dict[str, Any],
    governed_lanes: dict[str, Any],
    maturity: str,
    surface: str,
    provider_pair: str,
    source_report_type: str,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    host = detect_package_host(payload, source_path)
    run_id = run_id_from_timestamp(generated_at)
    rows: list[dict[str, Any]] = []
    lane_id = canonical_lane_id(governed_lanes, payload.get("laneId"))
    if lane_id is None:
        lane_id = package_governed_lane_id(surface)
    validate_governed_lane_binding(
        governed_lanes,
        lane_id=lane_id,
        source_report_type=source_report_type,
        surface=surface,
        host_profile=host["profileId"],
        provider_pair=provider_pair,
    )

    comparisons = payload.get("comparisons")
    if isinstance(comparisons, list):
        for comparison in comparisons:
            if not isinstance(comparison, dict):
                continue
            workload_identity = resolve_workload_identity(
                workload_registry,
                surface_id=surface,
                source_workload_id=str(comparison.get("workload") or ""),
                fallback_domain=str(comparison.get("domain") or "overhead"),
            )
            workload_id = (
                str(comparison.get("canonicalWorkloadId") or "").strip()
                or workload_identity["workloadId"]
            )
            source_workload_id = workload_identity["sourceWorkloadId"]
            domain = workload_identity["domain"]
            workload_set = workload_set_for_row(
                policy,
                surface_id=surface,
                workload_id=workload_id,
                domain=domain,
            )
            compared = comparison.get("status") == "compared"
            comparable = compared and comparison.get("comparable") is not False
            claimable = comparison.get("claimable") is True
            rows.append(
                {
                    "schemaVersion": 1,
                    "runId": run_id,
                    "generatedAt": iso_utc(generated_at),
                    "sourceReportType": source_report_type,
                    "sourceReportPath": str(source_path),
                    "sourceConformance": "canonical",
                    "sourceConformanceReason": "",
                    "host": host,
                    "surface": surface,
                    "comparisonView": provider_pair,
                    "providerPair": provider_pair,
                    "providerSet": compare_axes_mod.derive_provider_set(
                        boundary=compare_axes_mod.boundary_for_surface(
                            "package" if surface.endswith("_package") else "native"
                        ),
                        runtime_host=(
                            "bun"
                            if surface == "bun_package"
                            else ("deno" if surface == "deno_package" else "node")
                        ),
                        comparison_view=provider_pair,
                    ),
                    "providers": list(compare_axes_mod.providers_for_comparison_view(provider_pair)),
                    "governedLaneIds": [lane_id],
                    "workloadSet": workload_set,
                    "workloadId": workload_id,
                    "sourceWorkloadId": source_workload_id,
                    "workloadDomain": domain,
                    "comparisonStatus": "comparable" if comparable else "diagnostic",
                    "claimStatus": "claimable" if claimable else "diagnostic",
                    "maturity": maturity,
                    "metrics": {
                        "baselineP50Ms": safe_float(comparison.get("doeMedianMs")),
                        "comparisonP50Ms": safe_float(comparison.get("dawnMedianMs")),
                        "deltaP50Percent": safe_float(comparison.get("pctFaster")),
                        "baselineP95Ms": safe_float(comparison.get("doeP95Ms")),
                        "comparisonP95Ms": safe_float(comparison.get("dawnP95Ms")),
                        "baselineP99Ms": safe_float(comparison.get("doeP99Ms")),
                        "comparisonP99Ms": safe_float(comparison.get("dawnP99Ms")),
                        "baselineSampleCount": None,
                        "comparisonSampleCount": None,
                    },
                }
            )
    else:
        for workload in payload.get("workloads", []):
            if not isinstance(workload, dict):
                continue
            workload_identity = resolve_workload_identity(
                workload_registry,
                surface_id=surface,
                source_workload_id=str(workload.get("id") or ""),
                fallback_domain=str(workload.get("domain") or "overhead"),
            )
            workload_id = workload_identity["workloadId"]
            source_workload_id = workload_identity["sourceWorkloadId"]
            domain = workload_identity["domain"]
            workload_set = workload_set_for_row(
                policy,
                surface_id=surface,
                workload_id=workload_id,
                domain=domain,
            )
            baseline = workload.get("baseline", {})
            comparison = workload.get("comparison", {})
            baseline_stats = baseline.get("stats", {}) if isinstance(baseline, dict) else {}
            comparison_stats = comparison.get("stats", {}) if isinstance(comparison, dict) else {}
            comparability = workload.get("comparability", {})
            claimability = workload.get("claimability", {})
            delta_percent = workload.get("deltaPercent", {})
            timing_interpretation = workload.get("timingInterpretation", {})
            if not isinstance(timing_interpretation, dict):
                timing_interpretation = {}
            workload_unit_wall = timing_interpretation.get("workloadUnitWall", {})
            if not isinstance(workload_unit_wall, dict):
                workload_unit_wall = {}
            workload_unit_wall_delta = workload_unit_wall.get("deltaPercent", {})
            if not isinstance(workload_unit_wall_delta, dict):
                workload_unit_wall_delta = {}
            comparable = (
                isinstance(comparability, dict)
                and comparability.get("comparable") is True
            )
            claimable = (
                isinstance(claimability, dict)
                and claimability.get("claimable") is True
            )
            normalized_delta_p50 = safe_float(workload_unit_wall_delta.get("p50Percent"))
            if normalized_delta_p50 is None:
                normalized_delta_p50 = safe_float(delta_percent.get("p50Percent"))
            rows.append(
                {
                    "schemaVersion": 1,
                    "runId": run_id,
                    "generatedAt": iso_utc(generated_at),
                    "sourceReportType": source_report_type,
                    "sourceReportPath": str(source_path),
                    "sourceConformance": "canonical",
                    "sourceConformanceReason": "",
                    "host": host,
                    "surface": surface,
                    "comparisonView": provider_pair,
                    "providerPair": provider_pair,
                    "providerSet": compare_axes_mod.derive_provider_set(
                        boundary=compare_axes_mod.boundary_for_surface(
                            "package" if surface.endswith("_package") else "native"
                        ),
                        runtime_host=(
                            "bun"
                            if surface == "bun_package"
                            else ("deno" if surface == "deno_package" else "node")
                        ),
                        comparison_view=provider_pair,
                    ),
                    "providers": list(compare_axes_mod.providers_for_comparison_view(provider_pair)),
                    "governedLaneIds": [lane_id],
                    "workloadSet": workload_set,
                    "workloadId": workload_id,
                    "sourceWorkloadId": source_workload_id,
                    "workloadDomain": domain,
                    "comparisonStatus": "comparable" if comparable else "diagnostic",
                    "claimStatus": "claimable" if claimable else "diagnostic",
                    "maturity": maturity,
                    "metrics": {
                        "baselineP50Ms": safe_float(baseline_stats.get("p50Ms")),
                        "comparisonP50Ms": safe_float(comparison_stats.get("p50Ms")),
                        "deltaP50Percent": normalized_delta_p50,
                        "baselineP95Ms": safe_float(baseline_stats.get("p95Ms")),
                        "comparisonP95Ms": safe_float(comparison_stats.get("p95Ms")),
                        "baselineP99Ms": safe_float(baseline_stats.get("p99Ms")),
                        "comparisonP99Ms": safe_float(comparison_stats.get("p99Ms")),
                        "baselineSampleCount": parse_int(baseline_stats.get("count")),
                        "comparisonSampleCount": parse_int(comparison_stats.get("count")),
                    },
                }
            )

    compared_rows = [row for row in rows if row["comparisonStatus"] == "comparable"]
    claimable_rows = [row for row in rows if row["claimStatus"] == "claimable"]
    comparison_status = "comparable" if rows and len(compared_rows) == len(rows) else "diagnostic"
    claim_status = "claimable" if compared_rows and len(claimable_rows) == len(compared_rows) else "diagnostic"

    return rows, {
        "surface": surface,
        "comparisonView": provider_pair,
        "providerPair": provider_pair,
        "providerSet": compare_axes_mod.derive_provider_set(
            boundary=compare_axes_mod.boundary_for_surface(
                "package" if surface.endswith("_package") else "native"
            ),
            runtime_host=(
                "bun"
                if surface == "bun_package"
                else ("deno" if surface == "deno_package" else "node")
            ),
            comparison_view=provider_pair,
        ),
        "providers": list(compare_axes_mod.providers_for_comparison_view(provider_pair)),
        "governedLaneIds": [lane_id],
        "hostProfile": host["profileId"],
        "runId": run_id,
        "generatedAt": iso_utc(generated_at),
        "sourceReportPath": str(source_path),
        "sourceConformance": "canonical",
        "sourceConformanceReason": "",
        "comparisonStatus": comparison_status,
        "claimStatus": claim_status,
        "rowCount": len(rows),
        "deltaP50MedianPercent": median_non_null(
            [row["metrics"]["deltaP50Percent"] for row in rows]
        ),
    }
