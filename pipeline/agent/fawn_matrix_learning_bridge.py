#!/usr/bin/env python3
"""Route Fawn matrix evidence into bounded DoeLab learning records.

Failure manifests preserve the observed evidence, cluster repeat occurrences, and
emit replay/minimization proposals.  Those proposals are deliberately unverified:
this bridge has no authority to change runtime policy, promote a candidate, or
make a release claim.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

from bench.fawn_matrix.harness.live_evidence import (
    canonical_hash,
    verify_promotion_receipt,
)
from pipeline.agent.mine_upstream_quirks import build_hash_chain


LANE_BOUNDARIES = {
    "lane_a_chromium_playwright_dawn": "baseline_environment",
    "lane_b_fawn_playwright_dawn": "fawn_browser_shell",
    "lane_c_fawn_playwright_doe": "fawn_doe_runtime_boundary",
    "lane_d_fawn_direct_doe": "fawn_direct_doe_stack",
}

PROHIBITED_ACTIONS = (
    "release_claim",
    "runtime_policy_mutation",
    "candidate_promotion",
)

REQUIRED_EVIDENCE = (
    "exact_failure_replay",
    "minimized_reproducer",
    "independent_oracle_result",
    "physical_baseline_candidate_comparison",
)


def load_json(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def _workload_id(raw: dict[str, Any]) -> str:
    workload_id = raw.get("workloadId") or raw.get("workload", {}).get("workloadId")
    if not isinstance(workload_id, str) or not workload_id:
        raise ValueError("raw evidence has no workload identity")
    return workload_id


def _sample_failure_class(sample: dict[str, Any]) -> str:
    execution_failed = sample.get("success") is not True
    oracle_failed = sample.get("oraclePass") is not True
    if execution_failed and oracle_failed:
        return "execution_and_oracle_failure"
    if execution_failed:
        return "execution_failure"
    return "oracle_failure"


def _cluster_signature(record: dict[str, Any]) -> dict[str, Any]:
    return {
        "workloadId": record["workloadId"],
        "lane": record.get("lane", "unassigned"),
        "phase": record.get("phase", "executor"),
        "failureClass": record["failureClass"],
        "runtimeIdentitySha256": canonical_hash(record.get("runtimeIdentity")),
        "adapterInfoSha256": canonical_hash(record.get("adapterInfo")),
    }


def _build_clusters(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[str, tuple[dict[str, Any], list[dict[str, Any]]]] = {}
    for record in records:
        signature = _cluster_signature(record)
        key = canonical_hash(signature)
        grouped.setdefault(key, (signature, []))[1].append(record)

    clusters = []
    for cluster_id, (signature, occurrences) in sorted(grouped.items()):
        occurrences.sort(key=lambda item: item["failureId"])
        selectors = [
            {
                "failureId": item["failureId"],
                "lane": item.get("lane", "unassigned"),
                "phase": item.get("phase", "executor"),
                **(
                    {"iteration": item["iteration"]}
                    if isinstance(item.get("iteration"), int)
                    else {}
                ),
            }
            for item in occurrences
        ]
        observed_boundary = LANE_BOUNDARIES.get(
            signature["lane"],
            "unassigned",
        )
        proposal_id = canonical_hash({
            "clusterId": cluster_id,
            "contract": "doe-lab-investigation-candidate-v1",
        })
        clusters.append({
            "clusterId": cluster_id,
            "signature": signature,
            "occurrenceCount": len(occurrences),
            "failureIds": [item["failureId"] for item in occurrences],
            "replaySelectors": selectors,
            "minimizationPlan": {
                "status": "required",
                "preserveFailureSignature": True,
                "steps": [
                    "replay_exact_failure",
                    "isolate_observed_lane_boundary",
                    "delta_debug_workload_input_and_actions",
                    "replay_with_independent_oracle",
                ],
            },
            "candidateProposal": {
                "proposalId": proposal_id,
                "recordKind": "doe-lab-investigation-candidate-v1",
                "status": "unverified",
                "hypothesisStatus": "unestablished",
                "observedBoundary": observed_boundary,
                "allowedNextStage": "verify",
                "requiredEvidence": list(REQUIRED_EVIDENCE),
                "prohibitedActions": list(PROHIBITED_ACTIONS),
            },
        })
    return clusters


def validate_learning_manifest(manifest: dict[str, Any]) -> None:
    """Fail closed on the authority and cross-reference invariants of schema v2."""
    if manifest.get("schemaVersion") != 2:
        raise ValueError("learning manifest schemaVersion must be 2")
    if manifest.get("manifestKind") != "doe-lab-fawn-matrix-learning-v2":
        raise ValueError("unexpected learning manifest kind")
    if manifest.get("schemaPath") != "config/doe-lab-fawn-matrix-learning.schema.json":
        raise ValueError("unexpected learning manifest schema path")
    records = manifest.get("records")
    clusters = manifest.get("clusters")
    if not isinstance(records, list) or manifest.get("recordCount") != len(records):
        raise ValueError("learning record count mismatch")
    if not isinstance(clusters, list) or manifest.get("clusterCount") != len(clusters):
        raise ValueError("learning cluster count mismatch")
    record_ids = [record.get("failureId") for record in records]
    if len(record_ids) != len(set(record_ids)):
        raise ValueError("failure identities must be unique")
    expected_chain = build_hash_chain([
        {"quirkId": record["failureId"], **record}
        for record in records
    ])
    if manifest.get("hashChain") != expected_chain:
        raise ValueError("learning hash chain does not match the failure records")
    clustered_ids: list[str] = []
    proposal_ids: list[str] = []
    for cluster in clusters:
        clustered_ids.extend(cluster.get("failureIds", []))
        proposal = cluster.get("candidateProposal", {})
        proposal_ids.append(proposal.get("proposalId"))
        if proposal.get("status") != "unverified":
            raise ValueError("DoeLab candidate must remain unverified")
        if proposal.get("hypothesisStatus") != "unestablished":
            raise ValueError("DoeLab candidate cannot assert an unverified cause")
        if proposal.get("allowedNextStage") != "verify":
            raise ValueError("DoeLab candidate may only advance to verification")
        if proposal.get("prohibitedActions") != list(PROHIBITED_ACTIONS):
            raise ValueError("DoeLab candidate authority was widened")
    if sorted(clustered_ids) != sorted(record_ids):
        raise ValueError("failure clusters must cover each record exactly once")
    if len(proposal_ids) != len(set(proposal_ids)):
        raise ValueError("candidate proposal identities must be unique")


def failure_records(raw: dict[str, Any], source_path: Path) -> dict[str, Any]:
    workload_id = _workload_id(raw)
    records: list[dict[str, Any]] = []
    for lane_id, lane in sorted(raw.get("lanes", {}).items()):
        samples = sorted(
            lane.get("samples", []),
            key=lambda item: canonical_hash(item),
        )
        for sample in samples:
            if sample.get("success") and sample.get("oraclePass"):
                continue
            identity = {
                "workloadId": workload_id,
                "lane": lane_id,
                "phase": sample.get("phase"),
                "iteration": sample.get("iteration"),
                "failureClass": _sample_failure_class(sample),
                "sampleSha256": canonical_hash(sample),
            }
            records.append({
                "recordKind": "doe-lab-matrix-failure-v2",
                "failureId": canonical_hash(identity),
                **identity,
                "runtimeIdentity": lane.get("runtimeIdentity"),
                "adapterInfo": lane.get("adapterInfo"),
                "sample": sample,
            })
    normalized_errors = [
        error if isinstance(error, dict) else {"error": str(error)}
        for error in raw.get("errors", [])
    ]
    normalized_errors.sort(key=canonical_hash)
    duplicate_count: dict[str, int] = {}
    for error in normalized_errors:
        error_hash = canonical_hash(error)
        occurrence = duplicate_count.get(error_hash, 0)
        duplicate_count[error_hash] = occurrence + 1
        identity = {
            "workloadId": workload_id,
            "failureClass": "executor_error",
            "errorSha256": error_hash,
            "occurrence": occurrence,
            **error,
        }
        records.append({
            "recordKind": "doe-lab-matrix-failure-v2",
            "failureId": canonical_hash(identity),
            **identity,
        })
    records.sort(key=lambda item: item["failureId"])
    clusters = _build_clusters(records)
    manifest = {
        "schemaVersion": 2,
        "manifestKind": "doe-lab-fawn-matrix-learning-v2",
        "schemaPath": "config/doe-lab-fawn-matrix-learning.schema.json",
        "sourceArtifact": str(source_path),
        "sourceSha256": hashlib.sha256(source_path.read_bytes()).hexdigest(),
        "workloadId": workload_id,
        "recordCount": len(records),
        "hashChain": build_hash_chain([
            {"quirkId": record["failureId"], **record}
            for record in records
        ]),
        "records": records,
        "clusterCount": len(clusters),
        "clusters": clusters,
    }
    validate_learning_manifest(manifest)
    return manifest


def promotion_record(suite: dict[str, Any], source_path: Path) -> dict[str, Any]:
    subject = {
        key: value
        for key, value in suite.items()
        if key not in {"promotionReceipt", "reportHash"}
    }
    verify_promotion_receipt(subject, suite["promotionReceipt"])
    return {
        "schemaVersion": 1,
        "recordKind": "doe-lab-matrix-promotion-v1",
        "sourceArtifact": str(source_path),
        "sourceSha256": hashlib.sha256(source_path.read_bytes()).hexdigest(),
        "platform": suite["platform"],
        "earnedComponents": suite["earnedComponents"],
        "promotionReceipt": suite["promotionReceipt"],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw", type=Path)
    parser.add_argument("--suite", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if bool(args.raw) == bool(args.suite):
        parser.error("exactly one of --raw or --suite is required")
    source = args.raw or args.suite
    payload = load_json(source)
    result = failure_records(payload, source) if args.raw else promotion_record(payload, source)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
