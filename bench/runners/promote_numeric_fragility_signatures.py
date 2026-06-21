#!/usr/bin/env python3
"""Promote numeric-fragility corpus rows into checked-in signature config."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
for _path_entry in (str(REPO_ROOT), str(BENCH_ROOT)):
    if _path_entry not in sys.path:
        sys.path.insert(0, _path_entry)

from bench.lib.bench_utils import load_json_object as load_json
from bench.lib.config_validation import load_validated_config


DEFAULT_CORPUS_ROOT = REPO_ROOT / "bench" / "out" / "apple-metal-numeric-fragility-corpus"
DEFAULT_POLICY_PATH = REPO_ROOT / "config" / "fragility-promotion-policy.json"
DEFAULT_REGISTRY_PATH = REPO_ROOT / "config" / "numeric-stability-policy.json"
DEFAULT_SIGNATURE_ROOT = REPO_ROOT / "config" / "fragility-signatures" / "promoted"
DEFAULT_CATALOG_PATH = REPO_ROOT / "config" / "promoted-fragility-catalog.json"
FRAGILITY_SIGNATURE_SCHEMA_PATH = REPO_ROOT / "config" / "fragility-signature.schema.json"
PROMOTED_CATALOG_SCHEMA_PATH = REPO_ROOT / "config" / "promoted-fragility-catalog.schema.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source-jsonl",
        default=None,
        help="Explicit corpus JSONL path. Defaults to the latest export under bench/out/apple-metal-numeric-fragility-corpus/.",
    )
    parser.add_argument(
        "--source-manifest",
        default=None,
        help="Explicit corpus manifest path. Defaults to the sibling manifest of --source-jsonl or the latest export manifest.",
    )
    parser.add_argument(
        "--promotion-policy",
        default=str(DEFAULT_POLICY_PATH),
        help="Fragility promotion policy JSON.",
    )
    parser.add_argument(
        "--numeric-stability-registry",
        default=str(DEFAULT_REGISTRY_PATH),
        help="Numeric stability policy registry JSON.",
    )
    parser.add_argument(
        "--signature-root",
        default=str(DEFAULT_SIGNATURE_ROOT),
        help="Directory for promoted fragility signature JSON files.",
    )
    parser.add_argument(
        "--catalog-path",
        default=str(DEFAULT_CATALOG_PATH),
        help="Output promoted fragility catalog JSON path.",
    )
    parser.add_argument(
        "--no-clean",
        action="store_true",
        help="Do not remove existing promoted signature JSON files before writing the new set.",
    )
    return parser.parse_args()


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            stripped = line.strip()
            if not stripped:
                continue
            rows.append(json.loads(stripped))
    return rows


def repo_rel(path_value: str | Path | None) -> str | None:
    if path_value is None:
        return None
    path = Path(path_value)
    absolute = path if path.is_absolute() else (REPO_ROOT / path)
    absolute = absolute.resolve()
    try:
        return str(absolute.relative_to(REPO_ROOT.resolve()))
    except ValueError:
        return str(absolute)


def latest_corpus_paths(root: Path) -> tuple[Path, Path]:
    candidates: list[tuple[str, Path, Path]] = []
    for run_dir in sorted(root.glob("*")):
        if not run_dir.is_dir():
            continue
        manifest = run_dir / "apple_metal_numeric_fragility_corpus.manifest.json"
        jsonl = run_dir / "apple_metal_numeric_fragility_corpus.jsonl"
        if manifest.exists() and jsonl.exists():
            candidates.append((run_dir.name, jsonl, manifest))
    if not candidates:
        raise FileNotFoundError(f"no numeric fragility corpus exports found under {root}")
    _, jsonl_path, manifest_path = candidates[-1]
    return jsonl_path, manifest_path


def artifact_kind_from_path(path_value: str | Path | None) -> str | None:
    rel = repo_rel(path_value)
    if rel is None:
        return None
    if "selective-stable-rerun" in rel:
        return "selective-stable-rerun"
    if "reduction-order-logit-flip" in rel:
        return "reduction-order-logit-flip"
    if "reduction-order-counterexample" in rel:
        return "reduction-order-counterexample"
    if "real-lm-head-slice-hunt" in rel:
        return "real-lm-head-slice-hunt"
    if rel.endswith(".package-determinism.json"):
        return "package-determinism"
    if rel.endswith(".determinism.json"):
        return "sample-only-determinism"
    return None


def row_matches_rule(row: dict[str, Any], rule: dict[str, Any]) -> bool:
    if row.get("entryType") != rule["entryType"]:
        return False
    if rule.get("requireSourceBacked") and not row.get("sourceBacked"):
        return False
    if rule.get("requirePromotionEvidence") and not row.get("details", {}).get("promotionEvidence"):
        return False
    required_status = rule.get("requireRouteExpectationStatus")
    if required_status is not None:
        expectation = row.get("routeExpectation")
        if not isinstance(expectation, dict) or expectation.get("status") != required_status:
            return False
    required_kinds = set(rule.get("requireRelatedArtifactKinds", []))
    if required_kinds:
        available_kinds = set()
        source_kind = row.get("sourceArtifactKind")
        if source_kind:
            available_kinds.add(source_kind)
        for related_path in row.get("relatedArtifactPaths") or []:
            related_kind = artifact_kind_from_path(related_path)
            if related_kind:
                available_kinds.add(related_kind)
        if not required_kinds.issubset(available_kinds):
            return False
    return True


def selection_rule_for_row(row: dict[str, Any], policy: dict[str, Any]) -> dict[str, Any] | None:
    for rule in policy["selectionRules"]:
        if row_matches_rule(row, rule):
            return rule
    return None


def corpus_class_for_row(row: dict[str, Any], policy: dict[str, Any]) -> str:
    bucket = row.get("presentationBucket")
    if bucket not in policy["presentationBucketToCorpusClass"]:
        raise ValueError(f"unmapped presentation bucket: {bucket!r}")
    return policy["presentationBucketToCorpusClass"][bucket]


def sanitize_signature_file_name(signature_id: str) -> str:
    sanitized = []
    for char in signature_id:
        if char.isalnum():
            sanitized.append(char.lower())
        else:
            sanitized.append("-")
    compact = "".join(sanitized)
    while "--" in compact:
        compact = compact.replace("--", "-")
    return compact.strip("-") + ".json"


def canonical_promotion_evidence(row: dict[str, Any]) -> dict[str, Any] | None:
    evidence_items = row.get("details", {}).get("promotionEvidence") or []
    if not evidence_items:
        return None
    preferred_source = repo_rel(row.get("sourceArtifactPath"))
    preferred = [
        item for item in evidence_items if repo_rel(item.get("reportPath")) == preferred_source
    ]
    if preferred:
        evidence_items = preferred
    return sorted(
        evidence_items,
        key=lambda item: (
            repo_rel(item.get("selectiveReportPath")) or "",
            repo_rel(item.get("reductionReportPath")) or "",
            repo_rel(item.get("reportPath")) or "",
        ),
    )[0]


def canonical_selective_report_path(row: dict[str, Any]) -> str | None:
    evidence = canonical_promotion_evidence(row)
    if evidence and evidence.get("selectiveReportPath"):
        return repo_rel(evidence["selectiveReportPath"])
    if row.get("sourceArtifactKind") == "selective-stable-rerun":
        return repo_rel(row.get("sourceArtifactPath"))
    related_selective = [
        repo_rel(path)
        for path in row.get("relatedArtifactPaths") or []
        if artifact_kind_from_path(path) == "selective-stable-rerun"
    ]
    return sorted(path for path in related_selective if path is not None)[0] if related_selective else None


def load_selective_lane(row: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]] | tuple[None, None]:
    selective_report_rel = canonical_selective_report_path(row)
    if selective_report_rel is None:
        return None, None
    report = load_json(REPO_ROOT / selective_report_rel)
    lane_results = report.get("laneResults", {})
    if "doe" in lane_results:
        return report, lane_results["doe"]
    if not lane_results:
        return report, None
    lane_id = sorted(lane_results.keys())[0]
    return report, lane_results[lane_id]


def candidate_rows_from_row(row: dict[str, Any]) -> list[dict[str, Any]]:
    candidate_rows = row.get("details", {}).get("candidateRows")
    if isinstance(candidate_rows, list):
        return sorted(candidate_rows, key=lambda item: int(item.get("rowIndex", 0)))
    bounded_rows = row.get("boundedAnswerMetrics", {}).get("candidateRows") if isinstance(row.get("boundedAnswerMetrics"), dict) else None
    if isinstance(bounded_rows, list):
        return sorted(
            [
                {
                    "rowIndex": int(item["rowIndex"]),
                    "tokenId": int(item["tokenId"]),
                    "tokenText": item["tokenText"],
                    "prefillLogit": float(item["logit"]),
                }
                for item in bounded_rows
            ],
            key=lambda item: item["rowIndex"],
        )
    return []


def token_text_lookup(row: dict[str, Any]) -> dict[int, str]:
    lookup: dict[int, str] = {}
    for candidate in candidate_rows_from_row(row):
        lookup[int(candidate["tokenId"])] = str(candidate["tokenText"])
    global_metrics = row.get("globalDecisionMetrics") or {}
    for candidate in global_metrics.get("topCandidates") or []:
        lookup[int(candidate["tokenId"])] = str(candidate["tokenText"])
    if row.get("exactReferenceTokenId") is not None and row.get("exactReferenceTokenText") is not None:
        lookup[int(row["exactReferenceTokenId"])] = str(row["exactReferenceTokenText"])
    if row.get("fastTokenId") is not None and row.get("fastTokenText") is not None:
        lookup[int(row["fastTokenId"])] = str(row["fastTokenText"])
    return lookup


def token_text_for_id(row: dict[str, Any], token_id: int | None) -> str | None:
    if token_id is None:
        return None
    lookup = token_text_lookup(row)
    if token_id in lookup:
        return lookup[token_id]
    return f"token:{token_id}"


def resolve_selected_token_id(row: dict[str, Any], token_id: int | None) -> int | None:
    if token_id is None:
        return None
    lookup = token_text_lookup(row)
    if int(token_id) in lookup:
        return int(token_id)
    candidate_rows = candidate_rows_from_row(row)
    if 0 <= int(token_id) < len(candidate_rows):
        return int(candidate_rows[int(token_id)]["tokenId"])
    return int(token_id)


def compact_bounded_metrics(row: dict[str, Any]) -> dict[str, Any] | None:
    metrics = row.get("boundedAnswerMetrics")
    if not isinstance(metrics, dict) or not metrics.get("available"):
        return None
    return {
        "pairGapLogit": metrics["pairGapLogit"],
        "pairMarginProbability": metrics["pairMarginProbability"],
        "pairEntropyNats": metrics.get("pairEntropyNats"),
        "referenceProbability": metrics["referenceProbability"],
        "referenceSurprisalNats": metrics["referenceSurprisalNats"],
        "fastProbability": metrics["fastProbability"],
        "fastSurprisalNats": metrics["fastSurprisalNats"],
    }


def compact_global_metrics(row: dict[str, Any]) -> dict[str, Any] | None:
    metrics = row.get("globalDecisionMetrics")
    if not isinstance(metrics, dict) or not metrics.get("available"):
        return None
    payload: dict[str, Any] = {
        "globalGreedyToken": {
          "tokenId": int(metrics["globalGreedyTokenId"]),
          "tokenText": str(metrics.get("globalGreedyTokenText", "")),
          "logit": float(metrics["globalGreedyLogit"]),
        },
        "globalTop2GapLogit": float(metrics["globalTop2GapLogit"]),
        "referenceTokenGlobalSurprisalStatus": metrics["referenceTokenGlobalSurprisalStatus"],
    }
    for field in (
        "outsiderLeadVsPairMaxLogit",
        "outsiderDominatesPair",
        "referenceTokenGlobalProbability",
        "referenceTokenGlobalSurprisalNats",
    ):
        value = metrics.get(field)
        if value is not None:
            payload[field] = value
    return payload


def answer_set_payload(row: dict[str, Any]) -> dict[str, Any] | None:
    answer_set_id = row.get("answerSetId")
    candidate_rows = candidate_rows_from_row(row)
    if answer_set_id is None or not candidate_rows:
        return None
    return {
        "answerSetId": str(answer_set_id),
        "candidateSetSource": str(row.get("candidateSource") or row.get("sourceArtifactKind") or "unknown"),
        "candidates": [
            {
                "tokenId": int(candidate["tokenId"]),
                "tokenText": str(candidate["tokenText"]),
                "priority": int(candidate["rowIndex"]),
            }
            for candidate in candidate_rows
        ],
    }


def selection_payload(
    *,
    token_id: int | None,
    token_text: str | None,
    variant_id: str | None,
    policy_id: str | None,
    exact_reference_token_id: int | None,
) -> dict[str, Any] | None:
    if token_id is None or token_text is None:
        return None
    payload: dict[str, Any] = {
        "tokenId": int(token_id),
        "tokenText": str(token_text),
        "matchesExactReference": (
            exact_reference_token_id is not None and int(token_id) == int(exact_reference_token_id)
        ),
    }
    if variant_id:
        payload["variantId"] = str(variant_id)
    if policy_id:
        payload["policyId"] = str(policy_id)
    return payload


def unique_paths(*path_groups: list[str | None]) -> list[str]:
    seen: set[str] = set()
    ordered: list[str] = []
    for group in path_groups:
        for item in group:
            if item is None:
                continue
            if item in seen:
                continue
            seen.add(item)
            ordered.append(item)
    return ordered


def collect_proof_links(
    selective_report: dict[str, Any] | None,
    lane_result: dict[str, Any] | None,
    *,
    route_metadata_by_decision: dict[str, dict[str, Any]],
) -> list[dict[str, Any]]:
    if selective_report is None or lane_result is None:
        return []
    links: list[dict[str, Any]] = []
    for container in (
        lane_result.get("trigger", {}),
        lane_result.get("route", {}),
    ):
        for link in container.get("proofLinks") or []:
            normalized = dict(link)
            normalized["artifactPath"] = repo_rel(link.get("artifactPath")) or str(link.get("artifactPath"))
            if normalized not in links:
                links.append(normalized)
    for link in lane_result.get("route", {}).get("selectionProofLinks") or []:
        normalized = dict(link)
        normalized["artifactPath"] = repo_rel(link.get("artifactPath")) or str(link.get("artifactPath"))
        if normalized not in links:
            links.append(normalized)
    route_decision = lane_result.get("route", {}).get("decision")
    route_metadata = route_metadata_by_decision.get(route_decision)
    if route_metadata is not None:
        for link in route_metadata.get("proofLinks") or []:
            normalized = dict(link)
            normalized["artifactPath"] = repo_rel(link.get("artifactPath")) or str(link.get("artifactPath"))
            if normalized not in links:
                links.append(normalized)
    return links


def build_signature(
    row: dict[str, Any],
    *,
    contract_stage: str,
    corpus_class: str,
    route_taxonomy_version: str,
    policy_id: str,
    route_metadata_by_decision: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    selective_report, lane_result = load_selective_lane(row)
    candidate_rows = candidate_rows_from_row(row)
    token_lookup = token_text_lookup(row)
    exact_reference_token_id = row.get("exactReferenceTokenId")
    exact_reference_text = token_text_for_id(row, exact_reference_token_id)

    signature: dict[str, Any] = {
        "schemaVersion": 1,
        "signatureId": str(row["entryId"]),
        "contractStage": contract_stage,
        "artifactKind": str(row["entryType"]),
        "corpusClass": corpus_class,
        "routeTaxonomyVersion": route_taxonomy_version,
        "sourceArtifactPath": repo_rel(row.get("sourceArtifactPath")),
        "scenarioStem": str(row["scenarioStem"]),
        "notes": (
            f"Promoted by {policy_id} from the numeric fragility corpus. "
            "Runtime novelty remains blocked until a runtime-exercised receipt exists."
        ),
    }

    source_search = repo_rel(row.get("sourceSearchArtifactPath"))
    if source_search:
        signature["sourceSearchArtifactPath"] = source_search

    related_paths = unique_paths(
        [repo_rel(path) for path in row.get("relatedArtifactPaths") or []],
        [repo_rel(canonical_promotion_evidence(row).get("reductionReportPath"))] if canonical_promotion_evidence(row) else [],
        [repo_rel(canonical_promotion_evidence(row).get("selectiveReportPath"))] if canonical_promotion_evidence(row) else [],
        [repo_rel(canonical_promotion_evidence(row).get("reductionFixturePath"))] if canonical_promotion_evidence(row) else [],
        [repo_rel(canonical_promotion_evidence(row).get("selectiveFixturePath"))] if canonical_promotion_evidence(row) else [],
    )
    if related_paths:
        signature["relatedArtifactPaths"] = related_paths

    if row.get("promptId"):
        signature["promptId"] = str(row["promptId"])
    if row.get("promptText"):
        signature["promptText"] = str(row["promptText"])

    answer_set = answer_set_payload(row)
    if answer_set is not None:
        signature["answerSet"] = answer_set

    global_metrics = compact_global_metrics(row)
    if global_metrics is not None:
        signature["globalDecisionMetrics"] = global_metrics
        signature["firstGeneratedToken"] = global_metrics["globalGreedyToken"]

    bounded_metrics = compact_bounded_metrics(row)
    if bounded_metrics is not None:
        signature["boundedAnswerMetrics"] = bounded_metrics

    if exact_reference_token_id is not None and exact_reference_text is not None:
        signature["referenceSelection"] = selection_payload(
            token_id=int(exact_reference_token_id),
            token_text=exact_reference_text,
            variant_id="exact-reference",
            policy_id=None,
            exact_reference_token_id=int(exact_reference_token_id),
        )

    fast_variant_id = row.get("fastVariantId")
    fast_policy_id = lane_result.get("fastPolicyId") if lane_result else None
    fast_token_id = row.get("fastTokenId")
    if fast_token_id is None and lane_result is not None:
        fast_token_id = lane_result.get("selectedToken", {}).get("fast")
    fast_token_id = resolve_selected_token_id(row, fast_token_id)
    fast_token_text = token_text_for_id(row, fast_token_id)
    fast_selection = selection_payload(
        token_id=int(fast_token_id) if fast_token_id is not None else None,
        token_text=fast_token_text,
        variant_id=str(fast_variant_id) if fast_variant_id else (str(lane_result.get("fastVariantId")) if lane_result else None),
        policy_id=str(fast_policy_id) if fast_policy_id else None,
        exact_reference_token_id=int(exact_reference_token_id) if exact_reference_token_id is not None else None,
    )
    if fast_selection is not None:
        signature["fastSelection"] = fast_selection

    stable_token_id = None
    stable_variant_id = None
    stable_policy_id = None
    if lane_result is not None:
        stable_token_id = lane_result.get("selectedToken", {}).get("stable")
        stable_variant_id = lane_result.get("stableVariantId")
        stable_policy_id = lane_result.get("stablePolicyId")
    elif exact_reference_token_id is not None:
        stable_token_id = exact_reference_token_id
    stable_token_id = resolve_selected_token_id(row, stable_token_id)
    stable_token_text = token_text_for_id(row, stable_token_id)
    stable_selection = selection_payload(
        token_id=int(stable_token_id) if stable_token_id is not None else None,
        token_text=stable_token_text,
        variant_id=str(stable_variant_id) if stable_variant_id else "stable-reference-family",
        policy_id=str(stable_policy_id) if stable_policy_id else None,
        exact_reference_token_id=int(exact_reference_token_id) if exact_reference_token_id is not None else None,
    )
    if stable_selection is not None:
        signature["stableSelection"] = stable_selection

    if lane_result is not None and lane_result.get("firstDivergence") is not None:
        divergence = lane_result["firstDivergence"]
        signature["firstDivergence"] = {
            "semanticOpId": str(divergence["semanticOpId"]),
            "operatorFamily": str(lane_result.get("operatorFamily") or row["scenarioStem"]),
            "semanticStage": str(divergence.get("semanticStage") or ""),
            "semanticPhase": str(divergence.get("semanticPhase") or ""),
            "fastDigest": str(divergence["fastDigest"]),
            "stableDigest": str(divergence["stableDigest"]),
        }

    route_decision = None
    if isinstance(row.get("routeExpectation"), dict):
        route_decision = row["routeExpectation"].get("decision")
    if route_decision is None and lane_result is not None:
        route_decision = lane_result.get("route", {}).get("decision")
    if route_decision is not None:
        signature["routeExpectation"] = {
            "decision": str(route_decision),
            "status": "realized-in-promotion",
            "sourceArtifactPath": repo_rel(canonical_selective_report_path(row) or row.get("sourceArtifactPath")),
            "hasPromotionEvidence": True,
        }

    proof_links = collect_proof_links(
        selective_report,
        lane_result,
        route_metadata_by_decision=route_metadata_by_decision,
    )
    if proof_links:
        signature["proofLinks"] = proof_links

    return signature


def build_catalog(
    *,
    signatures: list[tuple[Path, dict[str, Any]]],
    catalog_version: str,
    promotion_policy_id: str,
    route_taxonomy_version: str,
    source_corpus_path: str,
    source_manifest_path: str | None,
) -> dict[str, Any]:
    entries = []
    counts_by_stage: dict[str, int] = {}
    counts_by_kind: dict[str, int] = {}
    counts_by_class: dict[str, int] = {}
    counts_by_route_outcome: dict[str, int] = {}
    for signature_path, signature in signatures:
        contract_stage = signature["contractStage"]
        artifact_kind = signature["artifactKind"]
        corpus_class = signature["corpusClass"]
        counts_by_stage[contract_stage] = counts_by_stage.get(contract_stage, 0) + 1
        counts_by_kind[artifact_kind] = counts_by_kind.get(artifact_kind, 0) + 1
        counts_by_class[corpus_class] = counts_by_class.get(corpus_class, 0) + 1
        entry = {
            "signatureId": signature["signatureId"],
            "signaturePath": repo_rel(signature_path),
            "contractStage": contract_stage,
            "artifactKind": artifact_kind,
            "corpusClass": corpus_class,
            "scenarioStem": signature["scenarioStem"],
            "routeExpectationDecision": signature["routeExpectation"]["decision"],
        }
        route_outcome = signature.get("routeOutcome", {}).get("decision")
        if route_outcome is not None:
            entry["routeOutcomeDecision"] = route_outcome
            counts_by_route_outcome[route_outcome] = counts_by_route_outcome.get(route_outcome, 0) + 1
        if "promptId" in signature:
            entry["promptId"] = signature["promptId"]
        entries.append(entry)

    entries.sort(
        key=lambda item: (
            item["contractStage"],
            item["artifactKind"],
            item["corpusClass"],
            item["scenarioStem"],
            item["signatureId"],
        )
    )
    catalog: dict[str, Any] = {
        "schemaVersion": 1,
        "catalogVersion": catalog_version,
        "promotionPolicyId": promotion_policy_id,
        "routeTaxonomyVersion": route_taxonomy_version,
        "sourceCorpusPath": source_corpus_path,
        "entries": entries,
        "summary": {
            "entryCount": len(entries),
            "countsByContractStage": counts_by_stage,
            "countsByArtifactKind": counts_by_kind,
            "countsByCorpusClass": counts_by_class,
            "countsByRouteOutcome": counts_by_route_outcome,
        },
    }
    if source_manifest_path is not None:
        catalog["sourceManifestPath"] = source_manifest_path
    return catalog


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    policy_path = Path(args.promotion_policy)
    registry_path = Path(args.numeric_stability_registry)
    promotion_policy = load_validated_config(policy_path)
    registry = load_validated_config(registry_path)
    if promotion_policy["routeTaxonomyVersion"] != registry["routeTaxonomyVersion"]:
        raise ValueError(
            "promotion policy routeTaxonomyVersion does not match numeric stability registry"
        )
    route_metadata_by_decision = {
        entry["decision"]: entry for entry in registry["routeDecisionMetadata"]
    }

    if args.source_jsonl is None:
        source_jsonl_path, source_manifest_path = latest_corpus_paths(DEFAULT_CORPUS_ROOT)
    else:
        source_jsonl_path = Path(args.source_jsonl)
        if args.source_manifest is not None:
            source_manifest_path = Path(args.source_manifest)
        else:
            candidate = source_jsonl_path.with_name("apple_metal_numeric_fragility_corpus.manifest.json")
            source_manifest_path = candidate if candidate.exists() else None
    rows = load_jsonl(source_jsonl_path)
    signature_root = Path(args.signature_root)
    catalog_path = Path(args.catalog_path)

    if not args.no_clean:
        if signature_root.exists():
            for existing in signature_root.glob("*.json"):
                existing.unlink()

    signatures: list[tuple[Path, dict[str, Any]]] = []
    for row in rows:
        rule = selection_rule_for_row(row, promotion_policy)
        if rule is None:
            continue
        signature = build_signature(
            row,
            contract_stage=rule["contractStage"],
            corpus_class=corpus_class_for_row(row, promotion_policy),
            route_taxonomy_version=registry["routeTaxonomyVersion"],
            policy_id=promotion_policy["policyId"],
            route_metadata_by_decision=route_metadata_by_decision,
        )
        signature_path = signature_root / sanitize_signature_file_name(signature["signatureId"])
        write_json(signature_path, signature)
        load_validated_config(signature_path, FRAGILITY_SIGNATURE_SCHEMA_PATH)
        signatures.append((signature_path, signature))

    if not signatures:
        raise ValueError("promotion policy selected zero numeric fragility signatures")

    catalog = build_catalog(
        signatures=signatures,
        catalog_version=promotion_policy["policyId"],
        promotion_policy_id=promotion_policy["policyId"],
        route_taxonomy_version=registry["routeTaxonomyVersion"],
        source_corpus_path=repo_rel(source_jsonl_path),
        source_manifest_path=repo_rel(source_manifest_path) if source_manifest_path is not None else None,
    )
    write_json(catalog_path, catalog)
    load_validated_config(catalog_path, PROMOTED_CATALOG_SCHEMA_PATH)
    print(catalog_path)


if __name__ == "__main__":
    main()
