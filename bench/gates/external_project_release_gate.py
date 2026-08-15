#!/usr/bin/env python3
"""Validate the promoted external-project release surface."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bench.lib.ecosystem_registry import load_json_object


PROMOTION_GATES = (
    "installation",
    "supportHardware",
    "concurrency",
    "teardown",
    "stress",
    "memory",
    "receipts",
    "replay",
    "performance",
    "ownership",
    "release",
)

PROMOTABLE_OWNERSHIP_DECISIONS = {
    "promote-doe-runtime",
    "promote-doe-proof",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=str(REPO_ROOT))
    parser.add_argument("--registry", default="config/ecosystem-registry.json")
    parser.add_argument(
        "--policy", default="config/external-project-promotion-policy.json"
    )
    parser.add_argument("--require-promoted", action="store_true")
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def _failure(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _payload_sha256(payload: dict[str, Any]) -> str:
    normalized = dict(payload)
    normalized.pop("receiptSha256", None)
    content = json.dumps(
        normalized,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(content).hexdigest()


def _preparation_receipt_failures(
    root: Path,
    actor: dict[str, Any],
    manifest: dict[str, Any],
    report: dict[str, Any],
    path: str,
) -> list[dict[str, str]]:
    references = [
        reference
        for reference in report.get("receipts", [])
        if isinstance(reference, dict)
        and isinstance(reference.get("path"), str)
        and reference["path"].endswith("/preparation.json")
    ]
    if not references:
        return [
            _failure(
                "promotion_report_missing_preparation_receipt",
                path,
                f"report {report.get('reportId')} must reference preparation.json",
            )
        ]

    invalid_references: list[dict[str, str]] = []
    resolved_root = root.resolve()
    for index, reference in enumerate(references):
        reference_path = f"{path}.receipts[{index}]"
        receipt_path = (resolved_root / reference["path"]).resolve()
        try:
            receipt_path.relative_to(resolved_root)
        except ValueError:
            invalid_references.append(
                _failure(
                    "preparation_receipt_path_escape",
                    reference_path,
                    "preparation receipt path escapes the repository root",
                )
            )
            continue
        try:
            file_sha256 = _sha256_file(receipt_path)
            receipt = load_json_object(receipt_path)
        except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
            invalid_references.append(
                _failure(
                    "invalid_preparation_receipt",
                    reference_path,
                    str(exc),
                )
            )
            continue
        errors: list[str] = []
        if file_sha256 != reference.get("sha256"):
            errors.append("referenced file hash does not match")
        if receipt.get("receiptSha256") != _payload_sha256(receipt):
            errors.append("embedded receipt hash does not match")
        if receipt.get("artifactKind") != "external-project-preparation-receipt":
            errors.append("artifact kind is not a preparation receipt")
        if receipt.get("status") != "passed":
            errors.append("preparation status is not passed")
        if receipt.get("actorId") != actor.get("id"):
            errors.append("actor identity does not match")
        if receipt.get("harnessId") != manifest.get("harnessId"):
            errors.append("harness identity does not match")
        if receipt.get("source", {}).get("actualCommit") != report.get(
            "upstream", {}
        ).get("commit"):
            errors.append("upstream commit does not match the report")
        if receipt.get("supportTarget", {}).get("claimEligible") is not True:
            errors.append("support target is not claim eligible")
        if not errors:
            return []
        invalid_references.append(
            _failure(
                "invalid_preparation_receipt",
                reference_path,
                "; ".join(errors),
            )
        )
    return invalid_references


def _runtime_ownership_plan_failures(
    manifest: dict[str, Any],
    floor: dict[str, Any],
    path: str,
) -> list[dict[str, str]]:
    if not floor.get("requireRuntimeOwnershipAttribution"):
        return []

    failures: list[dict[str, str]] = []
    plan = manifest.get("runtimeOwnershipPlan")
    if not isinstance(plan, dict):
        failures.append(
            _failure(
                "runtime_ownership_plan_missing",
                f"{path}.runtimeOwnershipPlan",
                "promotion requires a predeclared runtime-ownership plan",
            )
        )
        plan = {}

    plan_lanes = plan.get("lanes") if isinstance(plan.get("lanes"), dict) else {}
    required_lanes = floor.get("requiredRuntimeOwnershipLanes", [])
    for lane_id in required_lanes:
        lane = plan_lanes.get(lane_id)
        if not isinstance(lane, dict) or lane.get("requirement") != "required":
            failures.append(
                _failure(
                    "runtime_ownership_lane_not_predeclared",
                    f"{path}.runtimeOwnershipPlan.lanes.{lane_id}",
                    f"lane {lane_id} must be predeclared as required",
                )
            )

    claimed_property = plan.get("claimedProperty")
    patch_control_properties = floor.get("requireBoundedPatchControlFor", [])
    patch_control_required = claimed_property in patch_control_properties
    if patch_control_required:
        patch_lane = plan_lanes.get("P0")
        if (
            not isinstance(patch_lane, dict)
            or patch_lane.get("requirement") != "required"
        ):
            failures.append(
                _failure(
                    "bounded_patch_control_not_predeclared",
                    f"{path}.runtimeOwnershipPlan.lanes.P0",
                    f"{claimed_property} requires the bounded incumbent patch control",
                )
            )

    return failures


def _ownership_evidence_failures(
    root: Path,
    references: Any,
    path: str,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    if not isinstance(references, list) or not references:
        return failures
    resolved_root = root.resolve()
    for index, reference in enumerate(references):
        reference_path = f"{path}[{index}]"
        if not isinstance(reference, dict):
            failures.append(
                _failure(
                    "runtime_ownership_evidence_invalid",
                    reference_path,
                    "ownership evidence must be a path and SHA-256 object",
                )
            )
            continue
        relative_path = reference.get("path")
        expected_sha256 = reference.get("sha256")
        if not isinstance(relative_path, str) or not isinstance(expected_sha256, str):
            failures.append(
                _failure(
                    "runtime_ownership_evidence_invalid",
                    reference_path,
                    "ownership evidence must contain path and sha256 strings",
                )
            )
            continue
        evidence_path = (resolved_root / relative_path).resolve()
        try:
            evidence_path.relative_to(resolved_root)
        except ValueError:
            failures.append(
                _failure(
                    "runtime_ownership_evidence_path_escape",
                    reference_path,
                    "ownership evidence path escapes the repository root",
                )
            )
            continue
        try:
            actual_sha256 = _sha256_file(evidence_path)
        except OSError as exc:
            failures.append(
                _failure(
                    "runtime_ownership_evidence_unreadable",
                    reference_path,
                    str(exc),
                )
            )
            continue
        if actual_sha256 != expected_sha256:
            failures.append(
                _failure(
                    "runtime_ownership_evidence_hash_mismatch",
                    reference_path,
                    f"expected {expected_sha256}, got {actual_sha256}",
                )
            )
    return failures


def _runtime_ownership_failures(
    root: Path,
    manifest: dict[str, Any],
    report: dict[str, Any],
    floor: dict[str, Any],
    path: str,
    *,
    include_plan: bool = True,
) -> list[dict[str, str]]:
    if not floor.get("requireRuntimeOwnershipAttribution"):
        return []

    failures = (
        _runtime_ownership_plan_failures(manifest, floor, path)
        if include_plan
        else []
    )
    plan = manifest.get("runtimeOwnershipPlan")
    plan = plan if isinstance(plan, dict) else {}
    plan_lanes = plan.get("lanes") if isinstance(plan.get("lanes"), dict) else {}
    required_lanes = floor.get("requiredRuntimeOwnershipLanes", [])
    claimed_property = plan.get("claimedProperty")
    patch_control_properties = floor.get("requireBoundedPatchControlFor", [])
    patch_control_required = claimed_property in patch_control_properties

    ownership = report.get("runtimeOwnershipAssessment")
    if not isinstance(ownership, dict) or ownership.get("status") != "pass":
        failures.append(
            _failure(
                "runtime_ownership_assessment_incomplete",
                f"{path}.runtimeOwnershipAssessment",
                "promotion requires a passing reviewed ownership assessment",
            )
        )
        return failures

    if ownership.get("claimedProperty") != claimed_property:
        failures.append(
            _failure(
                "runtime_ownership_property_mismatch",
                f"{path}.runtimeOwnershipAssessment.claimedProperty",
                "reviewed ownership property does not match the predeclared plan",
            )
        )
    if ownership.get("decision") not in PROMOTABLE_OWNERSHIP_DECISIONS:
        failures.append(
            _failure(
                "runtime_ownership_decision_not_promotable",
                f"{path}.runtimeOwnershipAssessment.decision",
                "promotion requires a DoeRuntime or DoeProof terminal decision",
            )
        )

    assessed_lanes = (
        ownership.get("lanes") if isinstance(ownership.get("lanes"), dict) else {}
    )
    lanes_to_prove = list(required_lanes)
    if patch_control_required:
        lanes_to_prove.append("P0")
    for lane_id in lanes_to_prove:
        result = assessed_lanes.get(lane_id)
        if not isinstance(result, dict) or result.get("status") != "pass":
            failures.append(
                _failure(
                    "runtime_ownership_lane_not_passed",
                    f"{path}.runtimeOwnershipAssessment.lanes.{lane_id}",
                    f"lane {lane_id} must pass the frozen comparison contract",
                )
            )
        elif not result.get("evidence"):
            failures.append(
                _failure(
                    "runtime_ownership_lane_evidence_missing",
                    f"{path}.runtimeOwnershipAssessment.lanes.{lane_id}.evidence",
                    f"lane {lane_id} must reference reviewed evidence",
                )
            )
        else:
            failures.extend(
                _ownership_evidence_failures(
                    root,
                    result["evidence"],
                    f"{path}.runtimeOwnershipAssessment.lanes.{lane_id}.evidence",
                )
            )

    for field_name in ("materialOutcome", "costAcceptance"):
        result = ownership.get(field_name)
        if not isinstance(result, dict) or result.get("status") != "pass":
            failures.append(
                _failure(
                    "runtime_ownership_adjudication_not_passed",
                    f"{path}.runtimeOwnershipAssessment.{field_name}",
                    f"{field_name} must pass before promotion",
                )
            )
        elif not result.get("evidence"):
            failures.append(
                _failure(
                    "runtime_ownership_adjudication_evidence_missing",
                    f"{path}.runtimeOwnershipAssessment.{field_name}.evidence",
                    f"{field_name} must reference reviewed evidence",
                )
            )
        else:
            failures.extend(
                _ownership_evidence_failures(
                    root,
                    result["evidence"],
                    f"{path}.runtimeOwnershipAssessment.{field_name}.evidence",
                )
            )
    return failures


def _floor_failures(
    root: Path,
    actor: dict[str, Any],
    manifest: dict[str, Any],
    reports_by_id: dict[str, dict[str, Any]],
    floor: dict[str, Any],
    path: str,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    installation = manifest.get("installation", {})
    if installation.get("productionStatus") != "validated":
        failures.append(_failure("production_substitution_unvalidated", path, "production provider substitution is not validated"))
    if not installation.get("applicationSourceUnchanged"):
        failures.append(_failure("application_source_changed", path, "application source must remain unchanged"))
    if not installation.get("shaderSourceUnchanged"):
        failures.append(_failure("shader_source_changed", path, "shader source must remain unchanged"))

    promoted_targets = [
        target
        for target in manifest.get("supportTargets", [])
        if isinstance(target, dict) and target.get("status") == "promoted"
    ]
    if floor.get("requirePhysicalGpu") and not promoted_targets:
        failures.append(_failure("missing_promoted_support_target", path, "at least one physical GPU support target must be promoted"))

    reliability = manifest.get("reliabilityPolicy", {})
    numeric_floors = (
        ("cleanProcessRunsPerProvider", "minimumCleanProcessRunsPerProvider"),
        ("concurrencyLevel", "minimumConcurrencyLevel"),
        ("concurrencyRunsPerProvider", "minimumConcurrencyRunsPerProvider"),
        ("teardownCyclesPerProvider", "minimumTeardownCyclesPerProvider"),
        ("stressIterationsPerProvider", "minimumStressIterationsPerProvider"),
    )
    for manifest_field, policy_field in numeric_floors:
        actual = reliability.get(manifest_field, -1)
        required = floor.get(policy_field, 0)
        if not isinstance(actual, int) or actual < required:
            failures.append(_failure("reliability_floor_not_met", f"{path}.reliabilityPolicy.{manifest_field}", f"expected >= {required}, got {actual}"))
    if reliability.get("memoryGrowthBoundaryBytes") != floor.get("maximumUnboundedMemoryGrowthBytes"):
        failures.append(_failure("memory_growth_boundary_not_met", f"{path}.reliabilityPolicy.memoryGrowthBoundaryBytes", "promotion requires zero unbounded memory growth"))

    performance = manifest.get("performancePolicy", {})
    for manifest_field, policy_field in (
        ("coldSamplesPerProvider", "minimumColdSamplesPerProvider"),
        ("warmSamplesPerProvider", "minimumWarmSamplesPerProvider"),
    ):
        actual = performance.get(manifest_field, -1)
        required = floor.get(policy_field, 0)
        if not isinstance(actual, int) or actual < required:
            failures.append(_failure("performance_sample_floor_not_met", f"{path}.performancePolicy.{manifest_field}", f"expected >= {required}, got {actual}"))

    receipt_policy = manifest.get("receiptPolicy", {})
    if floor.get("requireReplay") and not receipt_policy.get("replayRequired"):
        failures.append(_failure("replay_not_required", path, "promoted workloads must require receipt replay"))
    if not receipt_policy.get("runtimeBuildIdentityRequired"):
        failures.append(_failure("runtime_identity_not_required", path, "promoted workloads must bind the runtime build identity"))
    if not receipt_policy.get("preparationReceiptRequired"):
        failures.append(
            _failure(
                "preparation_receipt_not_required",
                path,
                "promoted workloads must require a matching preparation receipt",
            )
        )

    failures.extend(
        _runtime_ownership_plan_failures(manifest, floor, path)
    )

    release_policy = manifest.get("releasePolicy", {})
    if not release_policy.get("blocking") or not release_policy.get("command"):
        failures.append(_failure("release_command_not_blocking", path, "promoted workloads require a blocking release command"))
    report_ids = release_policy.get("promotionReportIds", [])
    if not report_ids:
        failures.append(_failure("missing_promotion_report", path, "promoted workloads require reviewed promotion reports"))
    for report_id in report_ids:
        report = reports_by_id.get(report_id)
        if report is None:
            failures.append(_failure("unknown_promotion_report", path, f"unknown promotion report: {report_id}"))
            continue
        assessment = report.get("promotionAssessment", {})
        failed_gates = [
            name
            for name in PROMOTION_GATES
            if assessment.get(name, {}).get("status") != "pass"
        ]
        if report.get("evidenceMaturity") != floor.get("minimumEvidenceMaturity"):
            failures.append(_failure("promotion_report_not_claimable", path, f"report {report_id} does not meet evidence maturity floor"))
        if assessment.get("eligibility") != "eligible" or failed_gates:
            failures.append(_failure("promotion_report_ineligible", path, f"report {report_id} has non-passing gates: {', '.join(failed_gates)}"))
        failures.extend(
            _runtime_ownership_failures(
                root,
                manifest,
                report,
                floor,
                f"{path}.releasePolicy.promotionReportIds[{report_id}]",
                include_plan=False,
            )
        )
        failures.extend(
            _preparation_receipt_failures(
                root,
                actor,
                manifest,
                report,
                f"{path}.releasePolicy.promotionReportIds[{report_id}]",
            )
        )
    return failures


def evaluate(root: Path, registry: dict[str, Any], policy: dict[str, Any]) -> dict[str, Any]:
    failures: list[dict[str, str]] = []
    floor = policy.get("promotionFloor", {})
    promoted_count = 0
    promoted_harness_count = 0
    for actor_index, actor in enumerate(registry.get("actors", [])):
        if not isinstance(actor, dict):
            continue
        actor_path = f"actors[{actor_index}]"
        reports_by_id: dict[str, dict[str, Any]] = {}
        for report_ref in actor.get("reviewedReports", []):
            if not isinstance(report_ref, dict) or not isinstance(report_ref.get("path"), str):
                continue
            try:
                report = load_json_object(root / report_ref["path"])
            except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
                continue
            report_id = report.get("reportId")
            if isinstance(report_id, str):
                reports_by_id[report_id] = report

        if actor.get("promotionStatus") == "promoted":
            promoted_count += 1
        for harness_index, harness_ref in enumerate(actor.get("harnesses", [])):
            if not isinstance(harness_ref, dict) or not isinstance(harness_ref.get("manifestPath"), str):
                continue
            manifest_path = root / harness_ref["manifestPath"]
            try:
                manifest = load_json_object(manifest_path)
            except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
                failures.append(_failure("invalid_release_manifest", f"{actor_path}.harnesses[{harness_index}]", str(exc)))
                continue
            if manifest.get("releasePolicy", {}).get("promotionState") != "promoted":
                continue
            promoted_harness_count += 1
            failures.extend(
                _floor_failures(
                    root,
                    actor,
                    manifest,
                    reports_by_id,
                    floor,
                    f"{actor_path}.harnesses[{harness_index}]",
                )
            )
    return {
        "schemaVersion": 1,
        "artifactKind": "external-project-release-check",
        "ok": not failures,
        "failures": failures,
        "summary": {
            "promotedActorCount": promoted_count,
            "promotedHarnessCount": promoted_harness_count,
            "failureCount": len(failures),
        },
    }


def main() -> int:
    args = parse_args()
    root = Path(args.root).resolve()
    try:
        registry = load_json_object(root / args.registry)
        policy = load_json_object(root / args.policy)
        result = evaluate(root, registry, policy)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        print(f"FAIL: external project release input error: {exc}")
        return 1
    if args.require_promoted and result["summary"]["promotedHarnessCount"] == 0:
        result["ok"] = False
        result["failures"].append(_failure("no_promoted_harness", "actors", "at least one promoted external-project harness is required"))
        result["summary"]["failureCount"] = len(result["failures"])
    if args.emit_json:
        print(json.dumps(result, indent=2, sort_keys=True))
    elif result["ok"]:
        print(f"PASS: external project release surface ({result['summary']['promotedHarnessCount']} promoted harnesses)")
    else:
        for item in result["failures"]:
            print(f"FAIL [{item['code']}] {item['path']}: {item['message']}")
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
