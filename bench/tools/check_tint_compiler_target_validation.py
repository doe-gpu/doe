#!/usr/bin/env python3
"""Check target-backend shader artifacts in Tint compiler evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Any

try:
    from bench.tools._repo_import import ensure_repo_root
except ModuleNotFoundError:
    from _repo_import import ensure_repo_root

ensure_repo_root(__file__)

from bench.lib.bench_utils import unsafe_repo_path_reason  # noqa: E402


VALID_TARGETS = {"msl", "spirv", "dxil", "hlsl"}
VALID_HEX = set("0123456789abcdef")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--evidence",
        action="append",
        default=[],
        required=True,
        help="Tint compiler evidence report. Repeat when validation spans corpora.",
    )
    parser.add_argument(
        "--required-target",
        action="append",
        dest="required_targets",
        required=True,
        choices=sorted(VALID_TARGETS),
        help="Backend target that must have validated Doe and Tint artifacts.",
    )
    parser.add_argument(
        "--verify-files-root",
        default="",
        help="Resolve repo-relative artifact paths under this root and verify file hashes.",
    )
    parser.add_argument(
        "--allow-diagnostic-rows",
        action="store_true",
        help=(
            "Record rows with failed or unvalidated compiler sides as claim blockers "
            "instead of hard receipt failures."
        ),
    )
    parser.add_argument("--out", default="", help="Optional output validation receipt path.")
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def load_json(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"expected JSON object: {path}")
    return payload


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_sha256(value: Any) -> bool:
    return isinstance(value, str) and len(value) == 64 and all(char in VALID_HEX for char in value)


def failure(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def resolve_path(path_text: str, verify_files_root: Path | None) -> Path:
    path = Path(path_text)
    if path.is_absolute() or verify_files_root is None:
        return path
    return verify_files_root / path


def normalize_required_targets(required_targets: list[str]) -> tuple[list[str], list[dict[str, str]]]:
    normalized: list[str] = []
    failures: list[dict[str, str]] = []
    for index, target in enumerate(required_targets):
        if target not in VALID_TARGETS:
            failures.append(
                failure(
                    "invalid_required_target",
                    f"requiredTargets[{index}]",
                    f"unsupported backend target: {target}",
                )
            )
            continue
        if target not in normalized:
            normalized.append(target)
    if not normalized:
        failures.append(
            failure(
                "missing_required_targets",
                "requiredTargets",
                "at least one backend target is required",
            )
        )
    return normalized, failures


def check_path_field(
    *,
    failures: list[dict[str, str]],
    path_value: Any,
    path_name: str,
    path_label: str,
) -> str:
    if not isinstance(path_value, str) or not path_value:
        failures.append(
            failure(
                f"{path_label}_missing",
                path_name,
                f"{path_label} must be a non-empty repo-relative path",
            )
        )
        return ""
    reason = unsafe_repo_path_reason(path_value, allow_empty=False)
    if reason:
        failures.append(
            failure(
                f"{path_label}_unsafe",
                path_name,
                f"{path_label} must be a safe repo-relative path: {reason}",
            )
        )
        return ""
    return str(path_value)


def check_output_artifacts(
    *,
    side: str,
    result: dict[str, Any],
    side_path: str,
    expected_target: str,
    verify_files_root: Path | None,
    failures: list[dict[str, str]],
) -> None:
    artifacts = result.get("outputArtifacts", [])
    if artifacts in (None, []):
        return
    side_label = "Doe" if side == "doe" else "Tint"
    if not isinstance(artifacts, list):
        failures.append(
            failure(
                f"{side}_output_artifacts_invalid",
                f"{side_path}.outputArtifacts",
                f"{side_label} outputArtifacts must be an array",
            )
        )
        return
    for index, artifact in enumerate(artifacts):
        artifact_path = f"{side_path}.outputArtifacts[{index}]"
        if not isinstance(artifact, dict):
            failures.append(
                failure(
                    f"{side}_output_artifact_invalid",
                    artifact_path,
                    f"{side_label} output artifact must be an object",
                )
            )
            continue
        if artifact.get("target") != expected_target:
            failures.append(
                failure(
                    f"{side}_output_artifact_target_mismatch",
                    f"{artifact_path}.target",
                    f"{side_label} output artifact target must be {expected_target}",
                )
            )
        if artifact.get("validationStatus") != "passed":
            failures.append(
                failure(
                    f"{side}_output_artifact_validation_not_passed",
                    f"{artifact_path}.validationStatus",
                    f"{side_label} output artifact validationStatus must be passed",
                )
            )
        if not isinstance(artifact.get("validationTool"), str) or not artifact.get("validationTool"):
            failures.append(
                failure(
                    f"{side}_output_artifact_validation_tool_missing",
                    f"{artifact_path}.validationTool",
                    f"{side_label} output artifact validationTool is required",
                )
            )
        output_sha = artifact.get("outputSha256")
        if not is_sha256(output_sha):
            failures.append(
                failure(
                    f"{side}_output_artifact_hash_missing",
                    f"{artifact_path}.outputSha256",
                    f"{side_label} output artifact outputSha256 must be sha256 hex",
                )
            )
        output_path = check_path_field(
            failures=failures,
            path_value=artifact.get("outputPath"),
            path_name=f"{artifact_path}.outputPath",
            path_label=f"{side}_output_artifact_path",
        )
        if verify_files_root is not None and output_path:
            resolved_output = resolve_path(output_path, verify_files_root)
            if not resolved_output.is_file():
                failures.append(
                    failure(
                        f"{side}_output_artifact_missing",
                        f"{artifact_path}.outputPath",
                        f"{side_label} output artifact not found: {output_path}",
                    )
                )
            elif is_sha256(output_sha):
                actual_sha = file_sha256(resolved_output)
                if actual_sha != output_sha:
                    failures.append(
                        failure(
                            f"{side}_output_artifact_hash_mismatch",
                            f"{artifact_path}.outputSha256",
                            f"expected {output_sha}, got {actual_sha}",
                        )
                    )


def check_side_result(
    *,
    side: str,
    result: Any,
    row_path: str,
    target: str,
    verify_files_root: Path | None,
    failures: list[dict[str, str]],
) -> bool:
    before = len(failures)
    side_label = "Doe" if side == "doe" else "Tint"
    side_path = f"{row_path}.{side}"
    if not isinstance(result, dict):
        failures.append(
            failure(
                f"{side}_result_missing",
                side_path,
                f"{side_label} compiler result must be an object",
            )
        )
        result = {}

    if result.get("status") != "ok":
        failures.append(
            failure(
                f"{side}_result_not_ok",
                f"{side_path}.status",
                f"{side_label} compiler result must be ok",
            )
        )
    if result.get("validationStatus") != "passed":
        failures.append(
            failure(
                f"{side}_validation_not_passed",
                f"{side_path}.validationStatus",
                f"{side_label} validationStatus must be passed",
            )
        )
    if not isinstance(result.get("validationTool"), str) or not result.get("validationTool"):
        failures.append(
            failure(
                f"{side}_validation_tool_missing",
                f"{side_path}.validationTool",
                f"{side_label} validationTool is required",
            )
        )

    output_sha = result.get("outputSha256")
    if not is_sha256(output_sha):
        failures.append(
            failure(
                f"{side}_output_hash_missing",
                f"{side_path}.outputSha256",
                f"{side_label} outputSha256 must be sha256 hex",
            )
        )

    output_path = check_path_field(
        failures=failures,
        path_value=result.get("outputPath"),
        path_name=f"{side_path}.outputPath",
        path_label=f"{side}_output_path",
    )
    receipt_path = check_path_field(
        failures=failures,
        path_value=result.get("receiptPath"),
        path_name=f"{side_path}.receiptPath",
        path_label=f"{side}_receipt_path",
    )

    if verify_files_root is not None:
        if output_path:
            resolved_output = resolve_path(output_path, verify_files_root)
            if not resolved_output.is_file():
                failures.append(
                    failure(
                        f"{side}_output_missing",
                        f"{side_path}.outputPath",
                        f"{side_label} backend output not found: {output_path}",
                    )
                )
            elif is_sha256(output_sha):
                actual_sha = file_sha256(resolved_output)
                if actual_sha != output_sha:
                    failures.append(
                        failure(
                            f"{side}_output_hash_mismatch",
                            f"{side_path}.outputSha256",
                            f"expected {output_sha}, got {actual_sha}",
                        )
                    )
        if receipt_path:
            resolved_receipt = resolve_path(receipt_path, verify_files_root)
            if not resolved_receipt.is_file():
                failures.append(
                    failure(
                        f"{side}_receipt_missing",
                        f"{side_path}.receiptPath",
                        f"{side_label} receipt not found: {receipt_path}",
                    )
                )

    if isinstance(result, dict):
        check_output_artifacts(
            side=side,
            result=result,
            side_path=side_path,
            expected_target=target,
            verify_files_root=verify_files_root,
            failures=failures,
        )

    return len(failures) == before


def check_target_row(
    *,
    row: dict[str, Any],
    row_path: str,
    target: str,
    verify_files_root: Path | None,
    failures: list[dict[str, str]],
) -> bool:
    before = len(failures)
    expected_targets = row.get("expectedBackendTargets")
    if not isinstance(expected_targets, list) or target not in expected_targets:
        failures.append(
            failure(
                "target_not_expected",
                f"{row_path}.expectedBackendTargets",
                "row target must be present in expectedBackendTargets",
            )
        )
    if row.get("expectedValidity") != "valid":
        failures.append(
            failure(
                "expected_shader_not_valid",
                f"{row_path}.expectedValidity",
                "target validation rows must be expected-valid shaders",
            )
        )

    check_side_result(
        side="doe",
        result=row.get("doe"),
        row_path=row_path,
        target=target,
        verify_files_root=verify_files_root,
        failures=failures,
    )
    check_side_result(
        side="tint",
        result=row.get("tint"),
        row_path=row_path,
        target=target,
        verify_files_root=verify_files_root,
        failures=failures,
    )
    return len(failures) == before


def compiler_side_ready(result: Any) -> bool:
    return (
        isinstance(result, dict)
        and result.get("status") == "ok"
        and result.get("validationStatus") == "passed"
    )


def result_detail(result: dict[str, Any], code_field: str, message_field: str, fallback: str) -> str:
    code = result.get(code_field)
    message = result.get(message_field)
    code_text = code if isinstance(code, str) and code else fallback
    if isinstance(message, str) and message:
        return f"{code_text}: {message}"
    return code_text


def diagnostic_row_blockers(
    *,
    row: dict[str, Any],
    row_path: str,
) -> list[dict[str, str]]:
    blockers: list[dict[str, str]] = []
    for side, label in (("doe", "Doe"), ("tint", "Tint")):
        result = row.get(side)
        side_path = f"{row_path}.{side}"
        if not isinstance(result, dict):
            blockers.append(
                failure(
                    f"{side}_result_missing",
                    side_path,
                    f"{label} compiler result must be an object",
                )
            )
            continue
        status = result.get("status")
        if status != "ok":
            diagnostic = result_detail(result, "diagnosticCode", "diagnosticMessage", status or "unknown")
            blockers.append(
                failure(
                    f"{side}_result_not_ok",
                    f"{side_path}.status",
                    f"{label} compiler result is not ok: {diagnostic}",
                )
            )
            continue
        validation_status = result.get("validationStatus")
        if validation_status != "passed":
            diagnostic = result_detail(
                result,
                "validationStatus",
                "validationMessage",
                validation_status or "unknown",
            )
            blockers.append(
                failure(
                    f"{side}_validation_not_passed",
                    f"{side_path}.validationStatus",
                    f"{label} validationStatus is not passed: {diagnostic}",
                )
            )
    return blockers


def summarize_claim_blockers(blockers: list[dict[str, str]]) -> list[dict[str, Any]]:
    summary: list[dict[str, Any]] = []
    for blocker in blockers:
        code = blocker.get("code", "")
        message = blocker.get("message", "")
        for item in summary:
            if item["code"] == code and item["message"] == message:
                item["count"] += 1
                break
        else:
            summary.append({"code": code, "message": message, "count": 1})
    return summary


def blocker_evidence_path(blocker: dict[str, str]) -> str:
    path = blocker.get("path", "")
    prefix = "evidence["
    if not path.startswith(prefix):
        return ""
    end = path.find("]", len(prefix))
    if end <= len(prefix):
        return ""
    return path[len(prefix):end]


def summarize_claim_blockers_by_evidence_path(
    *,
    blockers: list[dict[str, str]],
    evidence_paths: list[str],
) -> list[dict[str, Any]]:
    grouped: dict[str, list[dict[str, str]]] = {path: [] for path in evidence_paths}
    for blocker in blockers:
        path = blocker_evidence_path(blocker)
        if not path:
            continue
        if path not in grouped:
            grouped[path] = []
        grouped[path].append(blocker)
    return [
        {
            "evidencePath": path,
            "claimBlockerSummary": summarize_claim_blockers(path_blockers),
        }
        for path, path_blockers in grouped.items()
    ]


def check_target_row_for_report(
    *,
    row: dict[str, Any],
    row_path: str,
    target: str,
    verify_files_root: Path | None,
    failures: list[dict[str, str]],
    claim_blockers: list[dict[str, str]],
    allow_diagnostic_rows: bool,
) -> tuple[bool, bool]:
    if allow_diagnostic_rows and (
        not compiler_side_ready(row.get("doe"))
        or not compiler_side_ready(row.get("tint"))
    ):
        row_blockers = diagnostic_row_blockers(row=row, row_path=row_path)
        claim_blockers.extend(row_blockers)
        return False, bool(row_blockers)

    return (
        check_target_row(
            row=row,
            row_path=row_path,
            target=target,
            verify_files_root=verify_files_root,
            failures=failures,
        ),
        False,
    )


def normalize_evidence_reports(
    *,
    evidence: dict[str, Any] | None,
    evidence_path: str | None,
    evidence_reports: list[tuple[str, dict[str, Any]]] | None,
) -> list[tuple[str, dict[str, Any]]]:
    if evidence_reports is not None:
        return evidence_reports
    if evidence is None:
        return []
    return [(evidence_path or "", evidence)]


def build_report(
    *,
    evidence: dict[str, Any] | None = None,
    evidence_path: str | None = None,
    evidence_reports: list[tuple[str, dict[str, Any]]] | None = None,
    required_targets: list[str],
    verify_files_root: Path | None = None,
    allow_diagnostic_rows: bool = False,
) -> dict[str, Any]:
    targets, failures = normalize_required_targets(required_targets)
    reports = normalize_evidence_reports(
        evidence=evidence,
        evidence_path=evidence_path,
        evidence_reports=evidence_reports,
    )
    claim_blockers: list[dict[str, str]] = []
    evidence_paths = [path for path, _payload in reports if path]

    evidence_rows: list[tuple[str, int, dict[str, Any]]] = []
    for report_index, (path, payload) in enumerate(reports):
        report_path = f"evidenceReports[{report_index}]"
        if payload.get("artifactKind") != "tint-compiler-evidence":
            failures.append(
                failure(
                    "invalid_artifact_kind",
                    f"{report_path}.artifactKind",
                    "artifactKind must be tint-compiler-evidence",
                )
            )

        rows = payload.get("rows", [])
        if not isinstance(rows, list):
            failures.append(failure("invalid_rows", f"{report_path}.rows", "rows must be an array"))
            rows = []
        for row_index, row in enumerate(rows):
            if isinstance(row, dict):
                evidence_rows.append((path, row_index, row))

    target_coverage = []
    validated_row_total = 0
    diagnostic_row_total = 0
    for target in targets:
        matching_rows = [
            (path, index, row)
            for path, index, row in evidence_rows
            if isinstance(row, dict) and row.get("target") == target
        ]
        if not matching_rows:
            failures.append(
                failure(
                    "missing_required_target",
                    f"requiredTargets.{target}",
                    f"no compiler evidence rows found for target {target}",
                )
            )

        validated_rows = 0
        diagnostic_rows = 0
        shader_ids = []
        coverage_evidence_paths: list[str] = []
        for path, index, row in matching_rows:
            row_path = f"evidence[{path}].rows[{index}]" if path else f"rows[{index}]"
            if path and path not in coverage_evidence_paths:
                coverage_evidence_paths.append(path)
            shader_id = row.get("shaderId")
            if isinstance(shader_id, str) and shader_id:
                shader_ids.append(shader_id)
            validated, diagnostic = check_target_row_for_report(
                row=row,
                row_path=row_path,
                target=target,
                verify_files_root=verify_files_root,
                failures=failures,
                claim_blockers=claim_blockers,
                allow_diagnostic_rows=allow_diagnostic_rows,
            )
            if validated:
                validated_rows += 1
            if diagnostic:
                diagnostic_rows += 1
        validated_row_total += validated_rows
        diagnostic_row_total += diagnostic_rows
        target_coverage.append(
            {
                "target": target,
                "evidencePaths": coverage_evidence_paths,
                "rowCount": len(matching_rows),
                "validatedRows": validated_rows,
                "diagnosticRows": diagnostic_rows,
                "shaderIds": shader_ids,
            }
        )

    covered_targets = sum(1 for item in target_coverage if item["rowCount"] > 0)
    report = {
        "schemaVersion": 1,
        "artifactKind": "tint_compiler_target_validation",
        "evidencePath": evidence_paths[0] if evidence_paths else "",
        "evidencePaths": evidence_paths,
        "requiredTargets": targets,
        "status": "fail" if failures else "pass",
        "targetCoverage": target_coverage,
        "claimBlockers": claim_blockers,
        "claimBlockerSummary": summarize_claim_blockers(claim_blockers),
        "claimBlockerSummaryByEvidencePath": summarize_claim_blockers_by_evidence_path(
            blockers=claim_blockers,
            evidence_paths=evidence_paths,
        ),
        "failures": failures,
        "summary": {
            "targetCount": len(targets),
            "coveredTargetCount": covered_targets,
            "rowCount": sum(item["rowCount"] for item in target_coverage),
            "validatedRows": validated_row_total,
            "diagnosticRows": diagnostic_row_total,
            "claimBlockerCount": len(claim_blockers),
            "failureCount": len(failures),
        },
    }
    return report


def main() -> int:
    args = parse_args()
    verify_files_root = Path(args.verify_files_root).resolve() if args.verify_files_root else None
    evidence_reports = []
    for evidence_path in args.evidence:
        evidence_reports.append((evidence_path, load_json(Path(evidence_path))))
    report = build_report(
        evidence_reports=evidence_reports,
        required_targets=list(args.required_targets),
        verify_files_root=verify_files_root,
        allow_diagnostic_rows=args.allow_diagnostic_rows,
    )
    if args.out:
        out_path = Path(args.out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if args.emit_json:
        print(json.dumps(report, indent=2))
    elif report["failures"]:
        print("FAIL: Tint compiler target validation")
        for item in report["failures"]:
            print(f"- {item['code']}: {item['path']}: {item['message']}")
    else:
        print("PASS: Tint compiler target validation")
    return 1 if report["failures"] else 0


if __name__ == "__main__":
    sys.exit(main())
