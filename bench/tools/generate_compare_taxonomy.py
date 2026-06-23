#!/usr/bin/env python3
"""Generate and verify the compare-taxonomy expansion artifact."""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path

try:
    from bench.tools._repo_import import ensure_repo_root
except ModuleNotFoundError:
    from _repo_import import ensure_repo_root

REPO_ROOT = ensure_repo_root(__file__)
from bench.lib import compare_axes as compare_axes_mod

DEFAULT_TAXONOMY_PATH = REPO_ROOT / "config" / "compare-taxonomy.json"
DEFAULT_PROMOTED_CATALOG_PATH = REPO_ROOT / "config" / "promoted-compare-catalog.json"
DEFAULT_OUTPUT_PATH = REPO_ROOT / "config" / "generated" / "compare-taxonomy-expanded.jsonl"


@dataclass(frozen=True)
class StructuralFamily:
    id: str
    surface: str
    product: str
    comparison_boundary: str
    runtime_host: str
    comparison_view: str
    provider_set: str
    providers: tuple[str, ...]
    temperature: str
    target_kind: str
    executor_input_boundary: str
    structural_platform_lanes: tuple[str, ...]
    theoretical_concrete_target_ids: tuple[str, ...]


@dataclass(frozen=True)
class PromotedCoverage:
    family_id: str
    platform_lane: str
    target_ids: tuple[str, ...]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
      "--taxonomy",
      default=str(DEFAULT_TAXONOMY_PATH),
      help="Path to compare-taxonomy.json.",
    )
    parser.add_argument(
      "--promoted-catalog",
      default=str(DEFAULT_PROMOTED_CATALOG_PATH),
      help="Path to promoted-compare-catalog.json.",
    )
    parser.add_argument(
      "--output",
      default=str(DEFAULT_OUTPUT_PATH),
      help="Path to the generated JSONL output.",
    )
    parser.add_argument(
      "--write",
      action="store_true",
      help="Write the generated JSONL artifact.",
    )
    parser.add_argument(
      "--verify",
      action="store_true",
      help="Verify that the generated JSONL matches the checked-in artifact.",
    )
    return parser.parse_args()


def load_json(path: Path) -> object:
    return json.loads(path.read_text(encoding="utf-8"))


def parse_structural_families(payload: dict) -> list[StructuralFamily]:
    families: list[StructuralFamily] = []
    seen_ids: set[str] = set()
    raw_families = payload.get("structuralFamilies") or payload.get("productFamilies") or []
    for raw in raw_families:
        family_id = raw["id"]
        if family_id in seen_ids:
            raise ValueError(f"duplicate structural family id: {family_id}")
        seen_ids.add(family_id)
        surface = raw.get("surface", "")
        boundary = raw.get("comparisonBoundary", "")
        if not boundary and surface:
            boundary = compare_axes_mod.boundary_for_surface(surface)
        product = raw.get("product", "")
        comparison_view = raw.get("comparisonView") or raw.get("providerPair", "")
        if not comparison_view and product:
            if surface == "backend" and product in {"doe", "dawn"}:
                comparison_view = "doe_vs_dawn_delegate"
            elif surface == "plan" and product in {"doe", "dawn"}:
                comparison_view = "doe_vs_dawn_direct"
            elif surface == "package" and raw["runtimeHost"] == "node" and product in {"doe", "node_webgpu_package"}:
                comparison_view = "doe_vs_dawn_node_webgpu_package"
            elif surface == "package" and raw["runtimeHost"] == "bun" and product in {"doe", "bun_webgpu_package"}:
                comparison_view = "doe_vs_dawn_bun_webgpu_package"
            elif surface == "package" and raw["runtimeHost"] == "deno" and product in {"doe", "deno_webgpu_package"}:
                comparison_view = "doe_vs_deno_webgpu_package"
            else:
                comparison_view = f"{product}_product_family"
        provider_set = raw.get("providerSet", "")
        if not provider_set and boundary:
            try:
                provider_set = compare_axes_mod.derive_provider_set(
                    boundary=boundary,
                    runtime_host=raw["runtimeHost"],
                    comparison_view=comparison_view if comparison_view and not product else "",
                )
            except ValueError:
                provider_set = f"{product}_providers" if product else ""
        providers_raw = raw.get("providers")
        if providers_raw:
            providers = tuple(providers_raw)
        elif comparison_view:
            comparison_view_providers = compare_axes_mod.providers_for_comparison_view(comparison_view)
            providers = comparison_view_providers or ((product,) if product else ())
        elif product:
            providers = (product,)
        else:
            providers = ()
        families.append(
            StructuralFamily(
                id=family_id,
                surface=surface,
                product=product,
                comparison_boundary=boundary,
                runtime_host=raw["runtimeHost"],
                comparison_view=comparison_view,
                provider_set=provider_set,
                providers=providers,
                temperature=raw["temperature"],
                target_kind=raw["targetKind"],
                executor_input_boundary=raw["executorInputBoundary"],
                structural_platform_lanes=tuple(raw["structuralPlatformLanes"]),
                theoretical_concrete_target_ids=tuple(raw["theoreticalConcreteTargetIds"]),
            )
        )
    return families


def parse_promoted_coverage(payload: dict, family_by_id: dict[str, StructuralFamily]) -> list[PromotedCoverage]:
    coverage_entries: list[PromotedCoverage] = []
    seen_pairs: set[tuple[str, str]] = set()
    promoted_key = "promotedCompareCoverage" if "promotedCompareCoverage" in payload else "promotedRunCoverage"
    for raw in payload.get(promoted_key, []):
        family_id = raw["familyId"]
        if family_id not in family_by_id:
            raise ValueError(f"promoted coverage references unknown family: {family_id}")
        key = (family_id, raw["platformLane"])
        if key in seen_pairs:
            raise ValueError(
                "duplicate promoted coverage entry for "
                f"family={family_id}, platformLane={raw['platformLane']}"
            )
        seen_pairs.add(key)
        family = family_by_id[family_id]
        target_ids = tuple(raw["targetIds"])
        missing_targets = sorted(set(target_ids) - set(family.theoretical_concrete_target_ids))
        if missing_targets:
            raise ValueError(
                f"promoted coverage for family={family_id} contains unknown target ids {missing_targets}"
            )
        coverage_entries.append(
            PromotedCoverage(
                family_id=family_id,
                platform_lane=raw["platformLane"],
                target_ids=target_ids,
            )
        )
    return coverage_entries


def boundary_by_surface(payload: dict) -> dict[str, str]:
    mapping: dict[str, str] = {}
    for surface in payload.get("axes", {}).get("surfaces", []):
        mapping[surface] = compare_axes_mod.boundary_for_surface(surface)
    return mapping


def repo_surface_by_boundary_and_runtime(payload: dict) -> dict[tuple[str, str], str]:
    mapping: dict[tuple[str, str], str] = {}
    aliases = payload.get("aliases", {})
    raw_list = aliases.get("repoSurfaceByBoundaryAndRuntimeHost") or aliases.get("repoSurfaceByProductAndRuntimeHost") or []
    for raw in raw_list:
        boundary = raw.get("comparisonBoundary", "")
        if not boundary:
            boundary = compare_axes_mod.boundary_for_surface(raw.get("surface", ""))
        key = (boundary, raw["runtimeHost"])
        if key in mapping:
            if mapping[key] != raw["repoSurface"]:
                raise ValueError(f"duplicate repo-surface alias for {key}")
            continue
        mapping[key] = raw["repoSurface"]
    return mapping


def actual_promoted_profile_map(
    promoted_catalog: dict,
    *,
    boundary_for_surface: dict[str, str],
) -> dict[tuple[str, str, str, str, str, str, str], list[str]]:
    profile_map: dict[tuple[str, str, str, str, str, str, str], list[str]] = {}
    for raw in promoted_catalog["entries"]:
        surface = raw.get(
            "surface",
            compare_axes_mod.surface_for_boundary(raw["boundary"]),
        )
        boundary = raw.get("boundary", boundary_for_surface[surface])
        runtime_host = raw.get(
            "runtimeHost",
            raw.get("packageRuntime", "none") if boundary == "package_surface" else "none",
        )
        comparison_view = raw.get(
            "comparisonView",
            compare_axes_mod.derive_comparison_view(
                surface=surface,
                runtime_host=runtime_host,
                provider_pair=raw.get("providerPair", ""),
            ),
        )
        target_kind = "preset" if "preset" in raw else "workload"
        target_id = raw["preset"] if target_kind == "preset" else raw["workload"]
        key = (
            raw["backend"],
            boundary,
            runtime_host,
            comparison_view,
            raw.get("temperature", raw["mode"]),
            target_kind,
            target_id,
        )
        profile_map.setdefault(key, []).append(raw["id"])
    for ids in profile_map.values():
        ids.sort()
    return profile_map


def expected_promoted_keys(
    coverage_entries: list[PromotedCoverage],
    *,
    family_by_id: dict[str, StructuralFamily],
) -> set[tuple[str, str, str, str, str, str, str]]:
    keys: set[tuple[str, str, str, str, str, str, str]] = set()
    for coverage in coverage_entries:
        family = family_by_id[coverage.family_id]
        for target_id in coverage.target_ids:
            keys.add(
                (
                    coverage.platform_lane,
                    family.comparison_boundary,
                    family.runtime_host,
                    family.comparison_view,
                    family.temperature,
                    family.target_kind,
                    target_id,
                )
            )
    return keys


def validate_promoted_subset_alignment(
    payload: dict,
    promoted_catalog: dict,
    *,
    family_by_id: dict[str, StructuralFamily],
) -> dict[tuple[str, str, str, str, str, str, str], list[str]]:
    coverage_entries = parse_promoted_coverage(payload, family_by_id)
    boundaries_by_surface = boundary_by_surface(payload)
    actual = actual_promoted_profile_map(
        promoted_catalog,
        boundary_for_surface=boundaries_by_surface,
    )
    expected = expected_promoted_keys(coverage_entries, family_by_id=family_by_id)
    actual_keys = set(actual)
    if expected != actual_keys:
        missing = sorted(expected - actual_keys)
        extra = sorted(actual_keys - expected)
        details: list[str] = []
        if missing:
            details.append(f"missing promoted tuples: {missing}")
        if extra:
            details.append(f"unexpected promoted tuples: {extra}")
        raise ValueError("promoted compare coverage drift: " + "; ".join(details))
    return actual


def build_entries(
    payload: dict,
    *,
    promoted_profile_map: dict[tuple[str, str, str, str, str, str, str], list[str]],
) -> list[dict]:
    families = parse_structural_families(payload)
    family_by_id = {family.id: family for family in families}
    coverage_entries = parse_promoted_coverage(payload, family_by_id)
    promoted_coverage_map = {
        (entry.family_id, entry.platform_lane): list(entry.target_ids)
        for entry in coverage_entries
    }
    repo_surface_aliases = repo_surface_by_boundary_and_runtime(payload)
    entries_by_id: dict[str, dict] = {}
    for family in families:
        for platform_lane in family.structural_platform_lanes:
            comparison_boundary = family.comparison_boundary
            runtime_host = family.runtime_host
            comparison_view = family.comparison_view
            temperature = family.temperature
            target_kind = family.target_kind
            derived_provider_set = family.provider_set
            derived_providers = family.providers
            promoted_target_ids: list[str] = []
            promoted_profile_ids: list[str] = []
            promoted_target_ids = promoted_coverage_map.get((family.id, platform_lane), [])
            for target_id in promoted_target_ids:
                key = (
                    platform_lane,
                    comparison_boundary,
                    runtime_host,
                    comparison_view,
                    temperature,
                    target_kind,
                    target_id,
                )
                promoted_profile_ids.extend(promoted_profile_map[key])
            promoted_profile_ids.sort()
            entry = {
                "schemaVersion": 1,
                "entryId": "__".join(
                    [
                        platform_lane,
                        comparison_boundary,
                        runtime_host,
                        comparison_view,
                        temperature,
                        target_kind,
                    ]
                ),
                "platformLane": platform_lane,
                "comparisonBoundary": comparison_boundary,
                "runtimeHost": runtime_host,
                "comparisonView": comparison_view,
                "providerPair": comparison_view,
                "providerSet": derived_provider_set,
                "providers": list(derived_providers),
                "temperature": temperature,
                "targetKind": target_kind,
                "promotedCompareSurface": family.surface,
                "repoSurface": repo_surface_aliases.get((comparison_boundary, runtime_host)),
                "structuralFamilyId": family.id,
                "executorInputBoundary": family.executor_input_boundary,
                "isTypeCorrectStructural": True,
                "isTypeCorrectConcrete": bool(family.theoretical_concrete_target_ids),
                "isPromotedCompareReachable": bool(promoted_profile_ids),
                "theoreticalConcreteTargetIds": list(family.theoretical_concrete_target_ids),
                "theoreticalConcreteTargetSlotCount": len(family.theoretical_concrete_target_ids),
                "promotedTargetIds": promoted_target_ids,
                "promotedCompareProfileIds": promoted_profile_ids,
                "promotedCompareProfileCount": len(promoted_profile_ids),
            }
            existing = entries_by_id.get(entry["entryId"])
            if existing is None:
                entries_by_id[entry["entryId"]] = entry
                continue
            existing["providers"] = sorted(set(existing["providers"]) | set(entry["providers"]))
            existing["promotedTargetIds"] = sorted(
                set(existing["promotedTargetIds"]) | set(entry["promotedTargetIds"])
            )
            existing["promotedCompareProfileIds"] = sorted(
                set(existing["promotedCompareProfileIds"]) | set(entry["promotedCompareProfileIds"])
            )
            existing["promotedCompareProfileCount"] = len(existing["promotedCompareProfileIds"])
            existing["isPromotedCompareReachable"] = bool(existing["promotedCompareProfileIds"])
    entries = list(entries_by_id.values())
    entries.sort(key=lambda item: item["entryId"])
    return entries


def summarize_entries(entries: list[dict]) -> dict[str, int]:
    return {
        "expandedEntryCount": len(entries),
        "typeCorrectStructuralEntries": sum(1 for entry in entries if entry["isTypeCorrectStructural"]),
        "typeCorrectConcreteTargetSlots": sum(
            entry["theoreticalConcreteTargetSlotCount"] for entry in entries
        ),
        "promotedCompareProfiles": sum(entry["promotedCompareProfileCount"] for entry in entries),
    }


def validate_expected_counts(payload: dict, entries: list[dict]) -> None:
    expected = payload.get("expectedCounts")
    if expected is None:
        return
    actual = summarize_entries(entries)
    if actual != expected:
        raise ValueError(f"compare taxonomy counts drift: expected {expected}, got {actual}")


def render_jsonl(entries: list[dict]) -> str:
    return "".join(json.dumps(entry, sort_keys=True) + "\n" for entry in entries)


def main() -> int:
    args = parse_args()
    taxonomy_path = Path(args.taxonomy)
    promoted_catalog_path = Path(args.promoted_catalog)
    output_path = Path(args.output)

    payload = load_json(taxonomy_path)
    promoted_catalog = load_json(promoted_catalog_path)
    families = parse_structural_families(payload)
    family_by_id = {family.id: family for family in families}
    promoted_profile_map = validate_promoted_subset_alignment(
        payload,
        promoted_catalog,
        family_by_id=family_by_id,
    )
    entries = build_entries(payload, promoted_profile_map=promoted_profile_map)
    validate_expected_counts(payload, entries)
    rendered = render_jsonl(entries)

    if args.write:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(rendered, encoding="utf-8")

    if args.verify:
        if not output_path.exists():
            raise SystemExit(f"missing generated artifact: {output_path}")
        existing = output_path.read_text(encoding="utf-8")
        if existing != rendered:
            raise SystemExit(
                "compare taxonomy artifact drift: run "
                "`python3 bench/tools/generate_compare_taxonomy.py --write`"
            )

    if not args.write and not args.verify:
        print(rendered, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
