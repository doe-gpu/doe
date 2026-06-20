#!/usr/bin/env python3
"""Promote sampled decode fragility rows into checked decode-boundary signatures."""

from __future__ import annotations

import argparse
import collections
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
for _path_entry in (str(REPO_ROOT), str(BENCH_ROOT)):
    if _path_entry not in sys.path:
        sys.path.insert(0, _path_entry)

from bench.lib.sampled_decode_fragility import (
    load_json,
    meaningful_token_class,
    repo_rel,
    semantic_scenario_bucket,
    write_json,
)


DEFAULT_VALIDATION_PLAN_PATH = REPO_ROOT / "config" / "numeric-stability-decode-validation-plan.json"
DEFAULT_SIGNATURE_ROOT = REPO_ROOT / "config" / "fragility-signatures" / "decode-promoted"
DEFAULT_CATALOG_PATH = REPO_ROOT / "config" / "numeric-stability-decode-promoted-catalog.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", required=True, help="Ranked decode fragility report path.")
    parser.add_argument("--manifest", required=True, help="Harvest manifest path.")
    parser.add_argument(
        "--validation-plan",
        default=str(DEFAULT_VALIDATION_PLAN_PATH),
        help="Decode validation plan JSON.",
    )
    parser.add_argument(
        "--signature-root",
        default=str(DEFAULT_SIGNATURE_ROOT),
        help="Output directory for promoted decode signatures.",
    )
    parser.add_argument(
        "--catalog-path",
        default=str(DEFAULT_CATALOG_PATH),
        help="Output decode promoted catalog JSON.",
    )
    parser.add_argument(
        "--no-clean",
        action="store_true",
        help="Do not remove existing promoted decode signature JSON files before writing the new set.",
    )
    return parser.parse_args()


def sanitize_signature_id(case_id: str) -> str:
    sanitized = []
    for character in case_id:
        if character.isalnum():
            sanitized.append(character.lower())
        else:
            sanitized.append("-")
    collapsed = "".join(sanitized)
    while "--" in collapsed:
        collapsed = collapsed.replace("--", "-")
    return collapsed.strip("-")


def find_case(manifest: dict[str, Any], base_case_id: str) -> dict[str, Any]:
    for case in manifest["cases"]:
        if case["caseId"] == base_case_id:
            return case
    raise KeyError(f"case {base_case_id!r} not found in harvest manifest")


def base_case_id(case_id: str) -> str:
    return case_id.split("::step-", 1)[0]


def candidate_selected_token_text(receipt: dict[str, Any]) -> dict[str, str]:
    selected = receipt["selectedToken"]
    label_by_token = {
        int(candidate["tokenId"]): str(candidate.get("label", f"token:{candidate['tokenId']}"))
        for candidate in receipt.get("candidates") or []
    }
    return {
        lane: label_by_token.get(int(selected[lane]), f"token:{selected[lane]}")
        for lane in ("fast", "stable", "reference")
    }


def build_signature(
    *,
    ranked_case: dict[str, Any],
    receipt: dict[str, Any],
    case: dict[str, Any],
    validation_plan: dict[str, Any],
    report_path: Path,
    manifest_path: Path,
) -> dict[str, Any]:
    selected_token_text = {
        "fast": ranked_case["selectedTokens"].get("fastText"),
        "stable": ranked_case["selectedTokens"].get("stableText"),
        "reference": ranked_case["selectedTokens"].get("referenceText"),
    }
    if not all(selected_token_text.values()):
        selected_token_text = candidate_selected_token_text(receipt)
    semantic_priority_class = str(ranked_case["semanticPriorityClass"])
    signature_id = f"decode-sampled-{sanitize_signature_id(ranked_case['caseId'])}"
    return {
        "schemaVersion": 1,
        "signatureId": signature_id,
        "promotionPolicyId": validation_plan["basePromotionPolicyId"],
        "contractStage": "metal-promoted",
        "caseId": ranked_case["caseId"],
        "promptText": ranked_case["promptText"],
        "semanticPriorityClass": semantic_priority_class,
        "semanticScenarioBucket": semantic_scenario_bucket(
            selected_token_text,
            semantic_priority_class,
        ),
        "meaningfulTokenClass": meaningful_token_class(
            selected_token_text,
            semantic_priority_class,
        ),
        "decodeStepIndex": int(ranked_case["decodeStepIndex"]),
        "routeDecision": receipt["route"]["decision"],
        "selectedTokens": {
            "fast": int(ranked_case["selectedTokens"]["fast"]),
            "stable": int(ranked_case["selectedTokens"]["stable"]),
            "reference": int(ranked_case["selectedTokens"]["reference"]),
            "fastText": str(selected_token_text["fast"]),
            "stableText": str(selected_token_text["stable"]),
            "referenceText": str(selected_token_text["reference"]),
        },
        "metrics": {
            "postTemperatureTop1Margin": ranked_case["metrics"].get("postTemperatureTop1Margin"),
            "topKBoundaryGap": ranked_case["metrics"].get("topKBoundaryGap"),
            "topPBoundaryGap": ranked_case["metrics"].get("topPBoundaryGap"),
            "cdfDistanceToDraw": ranked_case["metrics"].get("cdfDistanceToDraw"),
            "adjacentDecodePersistence": ranked_case["metrics"].get("adjacentDecodePersistence"),
            "actualSelectedTokenChanged": bool(ranked_case["metrics"].get("actualSelectedTokenChanged")),
            "meaningfulToken": bool(ranked_case["metrics"].get("meaningfulToken")),
            "withinPolicyStable": bool(ranked_case["metrics"].get("withinPolicyStable")),
            "suffixReplayDivergent": bool(ranked_case["metrics"].get("suffixReplayDivergent")),
            "suffixReplayAvailable": bool(ranked_case["metrics"].get("suffixReplayAvailable")),
        },
        "sourceReportPath": repo_rel(report_path),
        "sourceManifestPath": repo_rel(manifest_path),
        "sourceReceiptPath": ranked_case["receiptPath"],
        "commandsPath": case["commandsPath"],
        "patchedCommandsPath": case["patchedCommandsPath"],
        "kernelRoot": case["kernelRoot"],
        "maxSampleStepsToCapture": case.get("maxSampleStepsToCapture"),
        "sampleConfig": {
            "temperature": case["sampleConfig"]["temperature"],
            "topK": case["sampleConfig"]["topK"],
            "topP": case["sampleConfig"]["topP"],
            "rngSeed": case["sampleConfig"]["rngSeed"],
            "rngDraw": case["sampleConfig"]["rngDraw"],
        },
        "backend": case["backend"],
        "executionIdentity": receipt.get("executionIdentity"),
        "vulkanReplay": None,
    }


def build_catalog(
    *,
    signatures: list[tuple[Path, dict[str, Any]]],
    validation_plan: dict[str, Any],
    source_report_path: Path,
    source_manifest_path: Path,
) -> dict[str, Any]:
    entries = []
    stage_counts = collections.Counter()
    route_counts = collections.Counter()
    bucket_counts = collections.Counter()
    for path, signature in signatures:
        entries.append(
            {
                "signatureId": signature["signatureId"],
                "signaturePath": repo_rel(path),
                "contractStage": signature["contractStage"],
                "semanticScenarioBucket": signature["semanticScenarioBucket"],
                "routeDecision": signature["routeDecision"],
            }
        )
        stage_counts[signature["contractStage"]] += 1
        route_counts[signature["routeDecision"]] += 1
        bucket_counts[signature["semanticScenarioBucket"]] += 1
    return {
        "schemaVersion": 1,
        "catalogVersion": validation_plan["planVersion"],
        "promotionPolicyId": validation_plan["basePromotionPolicyId"],
        "validationPlanPath": repo_rel(REPO_ROOT / "config" / "numeric-stability-decode-validation-plan.json"),
        "sourceReportPath": repo_rel(source_report_path),
        "sourceManifestPath": repo_rel(source_manifest_path),
        "entries": entries,
        "summary": {
            "entryCount": len(entries),
            "countsByContractStage": dict(sorted(stage_counts.items())),
            "countsByRouteDecision": dict(sorted(route_counts.items())),
            "countsBySemanticScenarioBucket": dict(sorted(bucket_counts.items())),
        },
    }


def main() -> None:
    args = parse_args()
    report_path = Path(args.report)
    manifest_path = Path(args.manifest)
    validation_plan = load_json(Path(args.validation_plan))
    report = load_json(report_path)
    manifest = load_json(manifest_path)
    signature_root = Path(args.signature_root)
    catalog_path = Path(args.catalog_path)
    signature_root.mkdir(parents=True, exist_ok=True)

    if not args.no_clean:
        for existing in signature_root.glob("*.json"):
            existing.unlink()

    signatures: list[tuple[Path, dict[str, Any]]] = []
    for ranked_case in report["rankedCases"]:
        if ranked_case["rankingBucket"] != "promotable":
            continue
        case = find_case(manifest, base_case_id(ranked_case["caseId"]))
        receipt = load_json(REPO_ROOT / ranked_case["receiptPath"])
        signature = build_signature(
            ranked_case=ranked_case,
            receipt=receipt,
            case=case,
            validation_plan=validation_plan,
            report_path=report_path,
            manifest_path=manifest_path,
        )
        signature_path = signature_root / f"{signature['signatureId']}.json"
        write_json(signature_path, signature)
        signatures.append((signature_path, signature))

    catalog = build_catalog(
        signatures=signatures,
        validation_plan=validation_plan,
        source_report_path=report_path,
        source_manifest_path=manifest_path,
    )
    write_json(catalog_path, catalog)
    print(str(catalog_path))


if __name__ == "__main__":
    main()
