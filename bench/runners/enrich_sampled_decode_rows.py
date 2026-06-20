#!/usr/bin/env python3
"""Attach stability and suffix evidence to sampled decode receipts and rank them."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
for _path_entry in (str(REPO_ROOT), str(BENCH_ROOT)):
    if _path_entry not in sys.path:
        sys.path.insert(0, _path_entry)

from bench.lib.config_validation import load_validated_config
from bench.lib.sampled_decode_fragility import (
    adjacent_decode_persistence,
    decode_rows_by_step,
    decode_step_key,
    load_json,
    receipt_repeat_signature,
    relative_or_absolute,
    suffix_replay_override,
    write_json,
)
from bench.runners.normalize_decode_fragility_rows import build_row, validate_rows, write_jsonl
from bench.runners.rank_decode_fragility_states import build_report


DEFAULT_VALIDATION_PLAN_PATH = REPO_ROOT / "config" / "numeric-stability-decode-validation-plan.json"
DEFAULT_FRAGILITY_PLAN_PATH = REPO_ROOT / "config" / "numeric-stability-decode-fragility-plan.json"
ENRICHMENT_FILE_NAME = "numeric_stability_decode.row-enrichment.json"
ROWS_FILE_NAME = "numeric_stability_decode.rows.jsonl"
RANKED_REPORT_FILE_NAME = "numeric_stability_decode_fragility.report.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--manifest",
        required=True,
        help="Harvest manifest produced by harvest_sampled_decode_fragility.py.",
    )
    parser.add_argument(
        "--validation-plan",
        default=str(DEFAULT_VALIDATION_PLAN_PATH),
        help="Decode validation plan JSON.",
    )
    parser.add_argument(
        "--fragility-plan",
        default=str(DEFAULT_FRAGILITY_PLAN_PATH),
        help="Decode fragility ranking plan JSON.",
    )
    return parser.parse_args()


def repeat_receipts(case: dict[str, Any]) -> list[list[dict[str, Any]]]:
    decoded: list[list[dict[str, Any]]] = []
    for repeat in case["repeats"]:
        if repeat.get("status") != "success":
            continue
        receipts = [load_json(REPO_ROOT / path) for path in repeat["decodeReceiptPaths"]]
        decoded.append(decode_rows_by_step(receipts))
    return decoded


def first_success_repeat(case: dict[str, Any]) -> dict[str, Any] | None:
    for repeat in case["repeats"]:
        if repeat.get("status") == "success":
            return repeat
    return None


def step_receipts_by_repeat(receipts_by_repeat: list[list[dict[str, Any]]]) -> dict[str, list[dict[str, Any]]]:
    grouped: dict[str, list[dict[str, Any]]] = {}
    for repeat_receipt_rows in receipts_by_repeat:
        for receipt in repeat_receipt_rows:
            grouped.setdefault(decode_step_key(receipt), []).append(receipt)
    return grouped


def build_enrichment_entry(
    *,
    case: dict[str, Any],
    canonical_receipts: list[dict[str, Any]],
    canonical_receipt_paths: list[str],
    grouped_by_step: dict[str, list[dict[str, Any]]],
    suffix_max_steps: int,
) -> list[dict[str, Any]]:
    entries: list[dict[str, Any]] = []
    for index, receipt in enumerate(canonical_receipts):
        step_key = decode_step_key(receipt)
        repeats = grouped_by_step.get(step_key, [])
        signatures = {receipt_repeat_signature(item) for item in repeats}
        within_policy_stable = len(repeats) == int(case["repeatCount"]) and len(signatures) == 1
        suffix = suffix_replay_override(canonical_receipts, index, suffix_max_steps)
        overrides = {
            "caseId": f"{case['caseId']}::step-{index}",
            "promptText": case["promptText"],
            "decodeStepIndex": index,
            "semanticPriorityClass": case["semanticPriorityClass"],
            "withinPolicyStable": within_policy_stable,
            "adjacentDecodePersistence": adjacent_decode_persistence(
                canonical_receipts,
                index,
                suffix_max_steps,
            ),
            "suffixReplay": suffix,
        }
        entries.append(
            {
                "match": {
                    "receiptPath": canonical_receipt_paths[index],
                    "semanticStage": receipt["semanticStage"],
                    "semanticOpId": receipt["semanticOpId"],
                },
                "overrides": overrides,
            }
        )
    return entries


def canonical_receipt_paths(case: dict[str, Any]) -> list[str]:
    repeat = first_success_repeat(case)
    if repeat is None:
        return []
    return list(repeat["decodeReceiptPaths"])


def build_rows(
    *,
    cases: list[dict[str, Any]],
    suffix_max_steps: int,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    enrichment_entries: list[dict[str, Any]] = []
    rows: list[dict[str, Any]] = []
    for case in cases:
        if case.get("status", "success") != "success":
            continue
        receipts_by_repeat = repeat_receipts(case)
        if not receipts_by_repeat:
            continue
        canonical_receipts = receipts_by_repeat[0]
        canonical_paths = canonical_receipt_paths(case)
        if len(canonical_paths) != len(canonical_receipts):
            raise ValueError(
                f"case {case['caseId']} has {len(canonical_paths)} canonical receipt paths for "
                f"{len(canonical_receipts)} canonical receipts"
            )
        grouped_by_step = step_receipts_by_repeat(receipts_by_repeat)
        entries = build_enrichment_entry(
            case=case,
            canonical_receipts=canonical_receipts,
            canonical_receipt_paths=canonical_paths,
            grouped_by_step=grouped_by_step,
            suffix_max_steps=suffix_max_steps,
        )
        enrichment_entries.extend(entries)
        entry_by_path = {entry["match"]["receiptPath"]: entry for entry in entries}
        for receipt_path in canonical_paths:
            receipt = load_json(REPO_ROOT / receipt_path)
            overrides = entry_by_path[receipt_path]["overrides"]
            rows.append(build_row(receipt, receipt_path=receipt_path, overrides=overrides))
    validate_rows(rows)
    enrichment_payload = {"schemaVersion": 1, "entries": enrichment_entries}
    return rows, enrichment_payload


def main() -> None:
    args = parse_args()
    manifest_path = Path(args.manifest)
    validation_plan = load_validated_config(Path(args.validation_plan))
    fragility_plan_path = Path(args.fragility_plan)
    fragility_plan = load_validated_config(fragility_plan_path)
    manifest = load_json(manifest_path)
    output_dir = manifest_path.parent

    rows, enrichment_payload = build_rows(
        cases=manifest["cases"],
        suffix_max_steps=int(validation_plan["suffixReplayValidation"]["maxReplaySteps"]),
    )
    enrichment_path = output_dir / ENRICHMENT_FILE_NAME
    rows_path = output_dir / ROWS_FILE_NAME
    report_path = output_dir / RANKED_REPORT_FILE_NAME
    write_json(enrichment_path, enrichment_payload)
    write_jsonl(rows_path, rows)
    report = build_report(
        cases=rows,
        plan=fragility_plan,
        plan_path=fragility_plan_path,
        source_path=rows_path,
        timestamp=str(manifest["timestamp"]),
    )
    write_json(report_path, report)

    manifest["enrichmentPath"] = relative_or_absolute(enrichment_path)
    manifest["normalizedRowsPath"] = relative_or_absolute(rows_path)
    manifest["rankedReportPath"] = relative_or_absolute(report_path)
    write_json(manifest_path, manifest)
    print(str(report_path))


if __name__ == "__main__":
    main()
