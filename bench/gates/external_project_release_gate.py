#!/usr/bin/env python3
"""Validate the promoted external-project release surface."""

from __future__ import annotations

import argparse
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
    "release",
)


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


def _floor_failures(
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
