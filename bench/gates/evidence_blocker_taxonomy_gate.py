#!/usr/bin/env python3
"""Validate the shared evidence blocker taxonomy.

This gate keeps runner-visible blocker codes explicit and checks that the
model runtime receipt's executionBlocker enum is registered in the shared
taxonomy. It does not rewrite receipts; emitters remain responsible for
choosing the precise blocker code they observed.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

import jsonschema

REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
for _path_entry in (str(REPO_ROOT), str(BENCH_ROOT)):
    if _path_entry not in sys.path:
        sys.path.insert(0, _path_entry)

from bench.lib.bench_utils import detect_repo_root, load_json

REQUIRED_CODES = {
    "none",
    "native_webgpu_unavailable",
    "native_addon_unavailable",
    "runtime_library_unavailable",
    "provider_unavailable",
    "adapter_unavailable",
    "provider_import_failed",
    "unsupported_runtime_host",
    "hidden_fallback_applied",
    "shader_compile_failed",
    "pipeline_create_failed",
    "dispatch_failed",
    "readback_failed",
    "output_digest_missing",
    "transcript_digest_missing",
    "digest_mismatch",
    "checkpoint_stopped",
    "runtime_incomplete",
    "receipt_invalid",
    "runner_error",
    "model_runtime_blocked",
}
BLOCKER_CODE_RE = re.compile(r"^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$")
VALID_CATEGORIES = {
    "ready",
    "blocked",
    "unsupported",
    "fallback",
    "failure",
    "diagnostic",
}
VALID_STAGES = {
    "provider_gate",
    "runtime_selection",
    "adapter_request",
    "artifact",
    "cache",
    "doppler_manifest",
    "shader_compile",
    "pipeline_create",
    "dispatch",
    "readback",
    "digest",
    "checkpoint",
    "transcript",
    "model_runtime",
    "runner",
    "schema_gate",
}
VALID_RECEIPT_STATUSES = {
    "output_ready",
    "blocked",
    "checkpoint_stopped",
    "runtime_incomplete",
    "native_webgpu_unavailable",
    "provider_unavailable",
    "unsupported_capability",
    "adapter_unavailable",
    "shader_compile_failed",
    "pipeline_create_failed",
    "dispatch_failed",
    "readback_failed",
    "digest_mismatch",
    "receipt_invalid",
    "runner_error",
    "fallback_applied",
    "unsupported_runtime_host",
    "provider_import_failed",
    "native_addon_unavailable",
    "runtime_library_unavailable",
    "output_digest_missing",
    "transcript_digest_missing",
    "artifact_missing",
    "checkpoint_missing",
    "execution_not_attempted",
    "compile_failed",
    "simulator_failed",
    "hardware_failed",
    "memory_plan_does_not_fit",
    "partial_kernel_coverage",
    "real_weights_absent",
    "real_weight_parity_failed",
    "full_transformer_layer_block_incomplete",
    "full_grid_compile_unattempted",
    "cs_python_unavailable",
    "streaming_executor_unavailable",
    "hidden_fallback_applied",
}
VALID_CLAIM_IMPACTS = {
    "claimable",
    "diagnostic_only",
    "blocks_claim",
    "blocks_execution",
}
MODEL_RUNTIME_SCHEMA_DEFAULT = "config/doe-model-runtime-receipt.schema.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--root",
        default="",
        help="Repository root. Auto-detected when omitted.",
    )
    parser.add_argument(
        "--taxonomy",
        default="config/evidence-blocker-taxonomy.json",
        help="Evidence blocker taxonomy JSON.",
    )
    parser.add_argument(
        "--schema",
        default="config/evidence-blocker-taxonomy.schema.json",
        help="Evidence blocker taxonomy schema.",
    )
    parser.add_argument(
        "--model-runtime-schema",
        default=MODEL_RUNTIME_SCHEMA_DEFAULT,
        help="Model runtime receipt schema whose executionBlocker enum must be registered.",
    )
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def failure(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def _check_unique_list(
    failures: list[dict[str, str]],
    *,
    row_path: str,
    field_name: str,
    values: Any,
    valid_values: set[str],
    missing_code: str,
    invalid_code: str,
    duplicate_code: str,
) -> list[str]:
    if not isinstance(values, list) or not values:
        failures.append(
            failure(missing_code, f"{row_path}.{field_name}", f"{field_name} must be non-empty")
        )
        return []

    result: list[str] = []
    for index, value in enumerate(values):
        if value not in valid_values:
            failures.append(
                failure(
                    invalid_code,
                    f"{row_path}.{field_name}[{index}]",
                    f"{field_name} must use the evidence blocker taxonomy",
                )
            )
        elif isinstance(value, str):
            result.append(value)
    if len(result) != len(set(result)):
        failures.append(
            failure(
                duplicate_code,
                f"{row_path}.{field_name}",
                f"{field_name} must be unique",
            )
        )
    return result


def model_runtime_execution_blockers(schema_payload: dict[str, Any]) -> set[str]:
    execution_blocker = (
        schema_payload.get("properties", {})
        .get("executionBlocker", {})
        .get("enum", [])
    )
    if not isinstance(execution_blocker, list):
        return set()
    return {item for item in execution_blocker if isinstance(item, str)}


def check_taxonomy(
    payload: dict[str, Any],
    *,
    model_runtime_schema: dict[str, Any] | None = None,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    if payload.get("schemaVersion") != 1:
        failures.append(failure("invalid_schema_version", "schemaVersion", "schemaVersion must be 1"))
    if payload.get("artifactKind") != "evidence_blocker_taxonomy":
        failures.append(
            failure(
                "invalid_artifact_kind",
                "artifactKind",
                "artifactKind must be evidence_blocker_taxonomy",
            )
        )
    codes = payload.get("codes")
    if not isinstance(codes, list) or not codes:
        return failures + [failure("missing_codes", "codes", "codes must be a non-empty array")]

    seen: set[str] = set()
    code_to_row: dict[str, dict[str, Any]] = {}
    for index, row in enumerate(codes):
        row_path = f"codes[{index}]"
        if not isinstance(row, dict):
            failures.append(failure("invalid_code_row", row_path, "code row must be an object"))
            continue
        code = row.get("blockerCode")
        if not isinstance(code, str) or not code:
            failures.append(failure("missing_blocker_code", f"{row_path}.blockerCode", "blockerCode is required"))
        elif not BLOCKER_CODE_RE.fullmatch(code):
            failures.append(failure("invalid_blocker_code", f"{row_path}.blockerCode", "blockerCode must use snake_case taxonomy form"))
        elif code in seen:
            failures.append(failure("duplicate_blocker_code", f"{row_path}.blockerCode", f"duplicate blockerCode {code}"))
        else:
            seen.add(code)
            code_to_row[code] = row

        category = row.get("category")
        if category not in VALID_CATEGORIES:
            failures.append(failure("invalid_category", f"{row_path}.category", "category must use the evidence blocker taxonomy"))
        claim_impact = row.get("claimImpact")
        if claim_impact not in VALID_CLAIM_IMPACTS:
            failures.append(failure("invalid_claim_impact", f"{row_path}.claimImpact", "claimImpact must use the evidence blocker taxonomy"))
        developer_visible = row.get("developerVisible")
        if not isinstance(developer_visible, bool):
            failures.append(failure("invalid_developer_visible", f"{row_path}.developerVisible", "developerVisible must be boolean"))
        elif developer_visible is False and claim_impact != "diagnostic_only":
            failures.append(failure("nonvisible_blocker_not_diagnostic", f"{row_path}.developerVisible", "non-visible blocker codes must remain diagnostic-only"))
        if not isinstance(row.get("retryable"), bool):
            failures.append(failure("invalid_retryable", f"{row_path}.retryable", "retryable must be boolean"))
        if not isinstance(row.get("notes"), str) or not row.get("notes", "").strip():
            failures.append(failure("missing_notes", f"{row_path}.notes", "blocker codes require notes"))

        stages = _check_unique_list(
            failures,
            row_path=row_path,
            field_name="stages",
            values=row.get("stages"),
            valid_values=VALID_STAGES,
            missing_code="missing_stages",
            invalid_code="invalid_stage",
            duplicate_code="duplicate_stage",
        )
        statuses = _check_unique_list(
            failures,
            row_path=row_path,
            field_name="receiptStatuses",
            values=row.get("receiptStatuses"),
            valid_values=VALID_RECEIPT_STATUSES,
            missing_code="missing_receipt_statuses",
            invalid_code="invalid_receipt_status",
            duplicate_code="duplicate_receipt_status",
        )

        if category == "ready":
            if "output_ready" not in statuses:
                failures.append(
                    failure(
                        "ready_status_mismatch",
                        f"{row_path}.receiptStatuses",
                        "ready category requires output_ready status",
                    )
                )
            if claim_impact != "claimable":
                failures.append(
                    failure(
                        "ready_claim_impact_mismatch",
                        f"{row_path}.claimImpact",
                        "ready category requires claimable impact",
                    )
                )
        elif code != "none" and claim_impact == "claimable":
            failures.append(
                failure(
                    "nonready_claimable",
                    f"{row_path}.claimImpact",
                    "only the none blocker may be claimable",
                )
            )

        if code == "hidden_fallback_applied" and claim_impact not in {"blocks_claim", "blocks_execution"}:
            failures.append(
                failure(
                    "hidden_fallback_claim_impact",
                    f"{row_path}.claimImpact",
                    "hidden fallback must block claim or execution",
                )
            )
        if code == "digest_mismatch":
            if "digest" not in stages:
                failures.append(
                    failure(
                        "digest_mismatch_stage",
                        f"{row_path}.stages",
                        "digest_mismatch must include digest stage",
                    )
                )
            if "digest_mismatch" not in statuses:
                failures.append(
                    failure(
                        "digest_mismatch_status",
                        f"{row_path}.receiptStatuses",
                        "digest_mismatch must include digest_mismatch status",
                    )
                )
        if code == "checkpoint_stopped" and "checkpoint_stopped" not in statuses:
            failures.append(
                failure(
                    "checkpoint_stopped_status",
                    f"{row_path}.receiptStatuses",
                    "checkpoint_stopped must include checkpoint_stopped status",
                )
            )
        if code == "runtime_incomplete" and "runtime_incomplete" not in statuses:
            failures.append(
                failure(
                    "runtime_incomplete_status",
                    f"{row_path}.receiptStatuses",
                    "runtime_incomplete must include runtime_incomplete status",
                )
            )

    for code in sorted(REQUIRED_CODES - seen):
        failures.append(failure("missing_required_blocker_code", "codes", f"missing required blockerCode {code}"))

    if model_runtime_schema is not None:
        model_blockers = model_runtime_execution_blockers(model_runtime_schema)
        for code in sorted(model_blockers - seen):
            failures.append(
                failure(
                    "unregistered_model_runtime_blocker",
                    "codes",
                    f"model runtime executionBlocker {code} is not registered",
                )
            )
        for code in sorted(model_blockers & seen):
            if code == "none":
                continue
            row = code_to_row[code]
            stages = row.get("stages", [])
            if isinstance(stages, list) and "model_runtime" not in stages:
                failures.append(
                    failure(
                        "model_runtime_blocker_stage_missing",
                        f"codes[{codes.index(row)}].stages",
                        f"model runtime blocker {code} must include model_runtime stage",
                    )
                )

    return failures


def schema_validation_failures(
    payload: dict[str, Any],
    schema_payload: dict[str, Any],
) -> list[dict[str, str]]:
    validator = jsonschema.Draft202012Validator(schema_payload)
    errors = sorted(
        validator.iter_errors(payload),
        key=lambda item: tuple(str(part) for part in item.absolute_path),
    )
    failures: list[dict[str, str]] = []
    for error in errors:
        path = ".".join(str(part) for part in error.absolute_path) or "<root>"
        failures.append(failure("schema_validation_failed", path, error.message))
    return failures


def main() -> int:
    args = parse_args()
    try:
        root = detect_repo_root(args.root)
        taxonomy = load_json(root / args.taxonomy)
        schema = load_json(root / args.schema)
        model_runtime_schema = load_json(root / args.model_runtime_schema)
    except (ValueError, OSError, UnicodeError, json.JSONDecodeError) as exc:
        print(f"FAIL: evidence blocker taxonomy gate: {exc}")
        return 1

    if not isinstance(taxonomy, dict):
        print("FAIL: evidence blocker taxonomy gate: taxonomy must be a JSON object")
        return 1
    if not isinstance(schema, dict):
        print("FAIL: evidence blocker taxonomy gate: schema must be a JSON object")
        return 1
    if not isinstance(model_runtime_schema, dict):
        print("FAIL: evidence blocker taxonomy gate: model runtime schema must be a JSON object")
        return 1

    failures = schema_validation_failures(taxonomy, schema)
    failures.extend(
        check_taxonomy(taxonomy, model_runtime_schema=model_runtime_schema)
    )

    report = {
        "schemaVersion": 1,
        "artifactKind": "evidence_blocker_taxonomy_check",
        "taxonomyPath": args.taxonomy,
        "status": "fail" if failures else "pass",
        "failures": failures,
    }
    if args.emit_json:
        print(json.dumps(report, indent=2))
    elif failures:
        print("FAIL: evidence blocker taxonomy")
        for item in failures:
            print(f"  {item['code']}: {item['path']}: {item['message']}")
    else:
        print("PASS: evidence blocker taxonomy")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
