"""Evidence validation, evaluation, and promotion receipts for live workloads."""

from __future__ import annotations

import base64
import datetime
import hashlib
import json
import os
import subprocess
import tempfile
from pathlib import Path
from typing import Any

from bench.fawn_matrix.harness.lanes import compute_percentile
from bench.fawn_matrix.harness.types import Lane


class LiveEvidenceError(ValueError):
    """Raised when live workload evidence is not admissible."""


LANES = [lane.value for lane in Lane]
RUNTIMES = {
    Lane.LANE_A.value: "dawn",
    Lane.LANE_B.value: "dawn",
    Lane.LANE_C.value: "doe",
    Lane.LANE_D.value: "doe",
}
DEFAULT_TRUST_POLICY_PATH = (
    Path(__file__).resolve().parents[3]
    / "config"
    / "doe-proof-trusted-signers.json"
)
PROMOTION_RECEIPT_KIND = "doe-promotion-receipt-v1"


def canonical_hash(value: Any) -> str:
    encoded = json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    return hashlib.sha256(encoded).hexdigest()


def file_hash(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise LiveEvidenceError(message)


def _canonical_public_key(public_key: str) -> str:
    fields = public_key.split()
    _require(len(fields) >= 2 and fields[0] == "ssh-ed25519", "signing key must be Ed25519")
    return " ".join(fields[:2])


def _parse_utc(value: str, field: str) -> datetime.datetime:
    _require(value.endswith("Z"), f"{field} must be UTC")
    try:
        return datetime.datetime.fromisoformat(value.removesuffix("Z") + "+00:00")
    except ValueError as error:
        raise LiveEvidenceError(f"{field} is not an ISO-8601 timestamp") from error


def _load_trust_policy(path: Path | None) -> dict[str, Any]:
    policy_path = path or DEFAULT_TRUST_POLICY_PATH
    _require(policy_path.is_file(), f"trusted signer policy is missing: {policy_path}")
    policy = json.loads(policy_path.read_text(encoding="utf-8"))
    _require(policy.get("schemaVersion") == 1, "unsupported trusted signer policy")
    _require(policy.get("policyId") == "doe-proof-release-signers-v1", "wrong trusted signer policy")
    _require(policy.get("policyState") == "active", "trusted signer policy has no production trust anchor")
    signers = policy.get("signers", [])
    _require(bool(signers), "trusted signer policy authorizes no signers")
    _require(len({entry.get("signerId") for entry in signers}) == len(signers), "trusted signer IDs are not unique")
    _require(len({entry.get("publicKeySha256") for entry in signers}) == len(signers), "trusted signer fingerprints are not unique")
    return policy


def _authorize_signer(
    public_key_sha256: str,
    receipt_kind: str,
    subject_kind: str,
    signed_at: str,
    signer_id: str | None,
    trust_policy_path: Path | None,
) -> dict[str, Any]:
    policy = _load_trust_policy(trust_policy_path)
    matches = [entry for entry in policy["signers"] if entry.get("publicKeySha256") == public_key_sha256]
    _require(len(matches) == 1, "receipt signer fingerprint is not authorized")
    signer = matches[0]
    _require(signer.get("status") == "active", "receipt signer is revoked")
    if signer_id is not None:
        _require(signer.get("signerId") == signer_id, "receipt signer identity mismatch")
    _require(receipt_kind in signer.get("allowedReceiptKinds", []), "signer is not authorized for this receipt kind")
    _require(subject_kind in signer.get("allowedSubjectKinds", []), "signer is not authorized for this subject kind")
    instant = _parse_utc(signed_at, "signedAt")
    _require(
        _parse_utc(signer["notBefore"], "notBefore") <= instant <= _parse_utc(signer["notAfter"], "notAfter"),
        "receipt was signed outside the signer's validity interval",
    )
    return signer


def validate_live_raw(
    payload: dict[str, Any],
    workload: dict[str, Any],
) -> dict[str, Any]:
    _require(not payload.get("simulated_mode"), "simulated evidence rejected")
    _require(payload.get("reportKind") == "fawn-doe-live-workload-raw", "wrong report kind")
    _require(payload.get("workloadId") == workload["workloadId"], "workload mismatch")
    _require(payload.get("runStatus") == "passed", "executor did not pass")
    _require(not payload.get("errors"), "executor recorded errors")
    _require(set(payload.get("lanes", {})) == set(LANES), "all four lanes are required")
    run = payload["run"]
    _require(run.get("laneOrderPolicy") == "rotating_interleaved_v1", "samples are not interleaved")
    _require(run.get("timedIterations") == workload["timedIterations"], "timed count mismatch")
    oracle_by_iteration: dict[tuple[str, int], set[str]] = {}
    output_by_iteration: dict[tuple[str, int], set[str]] = {}
    order_by_iteration: dict[tuple[str, int], set[int]] = {}
    for lane_id in LANES:
        lane = payload["lanes"][lane_id]
        runtime = lane["runtimeIdentity"]
        _require(runtime.get("selectedRuntime") == RUNTIMES[lane_id], f"{lane_id} runtime mismatch")
        _require(not runtime.get("fallbackApplied"), f"{lane_id} applied fallback")
        _require(not runtime.get("hiddenFallbackAllowed"), f"{lane_id} permits hidden fallback")
        _require(runtime.get("activeRuntimeProof", {}).get("matched"), f"{lane_id} runtime proof failed")
        for identity_key in ("browserIdentity", "runtimeIdentity"):
            identity = lane[identity_key]
            artifact_path = Path(identity.get("executablePath") or identity.get("artifactPath"))
            expected_hash = identity.get("executableSha256") or identity.get("artifactSha256")
            _require(artifact_path.is_file(), f"missing artifact {artifact_path}")
            _require(file_hash(artifact_path) == expected_hash, f"artifact hash mismatch {artifact_path}")
        expected_transport = "fawn_direct_raw_cdp_v1" if lane_id == Lane.LANE_D.value else "playwright_v1"
        _require(lane.get("transport") == expected_transport, f"{lane_id} transport mismatch")
        samples = lane.get("samples", [])
        timed = [sample for sample in samples if sample.get("phase") == "timed"]
        _require(len(timed) == workload["timedIterations"], f"{lane_id} timed sample count mismatch")
        _require(len({sample["timing"]["totalWallMs"] for sample in timed}) > 1, f"{lane_id} constant timings")
        for sample in samples:
            _require(sample.get("success") and sample.get("oraclePass"), f"{lane_id} sample failed")
            _require(sample["timing"]["totalWallMs"] > 0, f"{lane_id} invalid timing")
            key = (sample["phase"], sample["iteration"])
            order_by_iteration.setdefault(key, set()).add(sample["orderIndex"])
            if payload["workloadId"] == "webgpu_model_preprocessing":
                _require(
                    sample.get("inputElements") == workload["inputElements"],
                    f"{lane_id} input size is not config-driven",
                )
                _require(
                    sample.get("dispatchRepeats") == workload["dispatchRepeats"],
                    f"{lane_id} dispatch repetition mismatch",
                )
                output_by_iteration.setdefault(key, set()).add(sample["outputSha256"])
            else:
                oracle_by_iteration.setdefault(key, set()).add(sample["oracleSha256"])
    _require(all(value == {0, 1, 2, 3} for value in order_by_iteration.values()), "lane order is incomplete")
    _require(all(len(value) == 1 for value in output_by_iteration.values()), "GPU outputs differ across lanes")
    _require(all(len(value) == 1 for value in oracle_by_iteration.values()), "task oracle differs across lanes")
    return {
        "status": "pass",
        "physicalHardware": payload.get("platform", {}).get("hardwareIdentity", {}).get("verified") is True,
        "interleaved": True,
        "structuralEquivalence": "pass",
        "independentOracle": True,
    }


def _metrics(samples: list[dict[str, Any]], workload_id: str) -> dict[str, Any]:
    timed = [sample for sample in samples if sample["phase"] == "timed"]
    latencies = [sample["timing"]["totalWallMs"] for sample in timed]
    metrics: dict[str, Any] = {
        "sampleCount": len(timed),
        "successRate": sum(bool(sample["success"]) for sample in timed) / len(timed),
        "latencyMsP50": compute_percentile(latencies, 0.50),
        "latencyMsP95": compute_percentile(latencies, 0.95),
        "latencyMsP99": compute_percentile(latencies, 0.99),
        "memoryPeakMb": max(sample.get("memoryMb", 0) for sample in timed),
    }
    if workload_id == "webgpu_model_preprocessing":
        for key in (
            "compilationMs",
            "pipelineCreationMs",
            "uploadMs",
            "dispatchMs",
            "dispatchPerRepeatMs",
            "synchronizationMs",
            "readbackMs",
        ):
            metrics[key + "P50"] = compute_percentile(
                [sample["timing"][key] for sample in timed],
                0.50,
            )
        metrics["maxAbsError"] = max(sample["maxAbsError"] for sample in timed)
    else:
        metrics["contextBytesP50"] = compute_percentile([sample["contextBytes"] for sample in timed], 0.50)
        metrics["contextTokensP50"] = compute_percentile([sample["contextTokens"] for sample in timed], 0.50)
        metrics["coldLatencyMsP50"] = compute_percentile(
            [sample["timing"]["totalWallMs"] for sample in timed if sample["sessionMode"] == "cold"], 0.50)
        metrics["warmLatencyMsP50"] = compute_percentile(
            [sample["timing"]["totalWallMs"] for sample in timed if sample["sessionMode"] == "warm"], 0.50)
    return metrics


def evaluate_live_workload(
    payload: dict[str, Any],
    workload: dict[str, Any],
    comparability: dict[str, Any],
    raw_path: Path,
) -> dict[str, Any]:
    lane_metrics = {
        lane_id: _metrics(payload["lanes"][lane_id]["samples"], payload["workloadId"])
        for lane_id in LANES
    }
    a = lane_metrics[Lane.LANE_A.value]
    b = lane_metrics[Lane.LANE_B.value]
    c = lane_metrics[Lane.LANE_C.value]
    d = lane_metrics[Lane.LANE_D.value]
    report: dict[str, Any] = {
        "schemaVersion": 1,
        "reportKind": "fawn-doe-live-workload-platform-report",
        "workloadId": payload["workloadId"],
        "evidenceStatus": "physical_diagnostic",
        "platform": payload["platform"],
        "comparability": comparability,
        "laneMetrics": lane_metrics,
        "rawArtifact": {"path": str(raw_path), "sha256": file_hash(raw_path)},
    }
    if payload["workloadId"] == "webgpu_model_preprocessing":
        speedup = b["latencyMsP50"] / c["latencyMsP50"]
        evidenced = speedup >= workload["materialSpeedupRatio"]
        report.update({
            "primaryComparison": "lane_c_over_lane_b",
            "speedupCOverB": speedup,
            "overallThesisStatus": "DOE_RUNTIME_PREPROCESSING_EVIDENCED" if evidenced else "DOE_RUNTIME_PREPROCESSING_NOT_EVIDENCED",
            "productDecision": "Use DoeRuntime beneath Fawn for this workload after the second physical platform agrees." if evidenced else "Retain Dawn beneath Fawn for this workload while DoeRuntime improves.",
        })
    else:
        speedup = a["latencyMsP50"] / d["latencyMsP50"]
        cold_speedup = a["coldLatencyMsP50"] / d["coldLatencyMsP50"]
        warm_speedup = a["warmLatencyMsP50"] / d["warmLatencyMsP50"]
        token_reduction = a["contextTokensP50"] / d["contextTokensP50"]
        byte_reduction = a["contextBytesP50"] / d["contextBytesP50"]
        evidenced = (
            cold_speedup >= workload["materialSpeedupRatio"]
            and warm_speedup >= workload["materialSpeedupRatio"]
            and token_reduction
            >= workload["materialContextReductionRatio"]
        )
        report.update({
            "primaryComparison": "lane_d_over_lane_a",
            "speedupDOverA": speedup,
            "coldSpeedupDOverA": cold_speedup,
            "warmSpeedupDOverA": warm_speedup,
            "tokenReductionDOverA": token_reduction,
            "byteReductionDOverA": byte_reduction,
            "overallThesisStatus": "VERTICAL_AGENT_STACK_EVIDENCED" if evidenced else "VERTICAL_AGENT_STACK_NOT_EVIDENCED",
            "productDecision": "Promote the complete stack only after the second physical platform agrees." if evidenced else "Do not promote the complete vertical stack from this workload.",
        })
    report["reportHash"] = canonical_hash(report)
    return report


def promotion_receipt(
    subject: dict[str, Any],
    signing_environment: str,
    trust_policy_path: Path | None = None,
) -> dict[str, Any]:
    subject_hash = canonical_hash(subject)
    subject_kind = subject.get("reportKind", "")
    _require(bool(subject_kind), "signed subject reportKind is missing")
    key_value = os.environ.get(signing_environment)
    if not key_value:
        return {
            "receiptKind": PROMOTION_RECEIPT_KIND,
            "subjectSha256": subject_hash,
            "subjectKind": subject_kind,
            "signatureAlgorithm": None,
            "signature": None,
            "publicKey": None,
            "signatureStatus": "unsigned_review_required",
        }
    key_path = Path(key_value)
    _require(key_path.is_file(), f"signing key does not exist: {key_path}")
    public_path = Path(str(key_path) + ".pub")
    if public_path.is_file():
        public_key = public_path.read_text(encoding="utf-8").strip()
    else:
        public_key = subprocess.run(
            ["ssh-keygen", "-y", "-f", str(key_path)],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
    public_key = _canonical_public_key(public_key)
    public_key_sha256 = hashlib.sha256(public_key.encode()).hexdigest()
    signed_at = datetime.datetime.now(datetime.UTC).isoformat().replace("+00:00", "Z")
    signer = _authorize_signer(
        public_key_sha256,
        PROMOTION_RECEIPT_KIND,
        subject_kind,
        signed_at,
        None,
        trust_policy_path,
    )
    with tempfile.TemporaryDirectory(prefix="doe-proof-sign-") as directory:
        subject_path = Path(directory) / "subject.txt"
        subject_path.write_text(subject_hash, encoding="utf-8")
        subprocess.run(
            ["ssh-keygen", "-Y", "sign", "-f", str(key_path), "-n", "doe-proof", str(subject_path)],
            check=True,
            capture_output=True,
        )
        signature = base64.b64encode(
            Path(str(subject_path) + ".sig").read_bytes()
        ).decode("ascii")
    return {
        "receiptKind": PROMOTION_RECEIPT_KIND,
        "subjectSha256": subject_hash,
        "subjectKind": subject_kind,
        "signatureAlgorithm": "sshsig-ed25519",
        "signature": signature,
        "publicKey": public_key,
        "publicKeySha256": public_key_sha256,
        "signerId": signer["signerId"],
        "signedAt": signed_at,
        "signatureStatus": "signed",
    }


def verify_promotion_receipt(
    subject: dict[str, Any],
    receipt: dict[str, Any],
    trust_policy_path: Path | None = None,
) -> None:
    _require(receipt.get("signatureStatus") == "signed", "receipt is unsigned")
    _require(receipt.get("signatureAlgorithm") == "sshsig-ed25519", "unsupported signature algorithm")
    _require(receipt.get("receiptKind") == PROMOTION_RECEIPT_KIND, "unsupported receipt kind")
    subject_hash = canonical_hash(subject)
    _require(receipt.get("subjectSha256") == subject_hash, "receipt subject hash mismatch")
    subject_kind = subject.get("reportKind", "")
    _require(receipt.get("subjectKind") == subject_kind, "receipt subject kind mismatch")
    public_key = _canonical_public_key(receipt.get("publicKey", ""))
    public_key_sha256 = hashlib.sha256(public_key.encode()).hexdigest()
    _require(
        receipt.get("publicKeySha256")
        == public_key_sha256,
        "receipt public key hash mismatch",
    )
    _authorize_signer(
        public_key_sha256,
        PROMOTION_RECEIPT_KIND,
        subject_kind,
        receipt.get("signedAt", ""),
        receipt.get("signerId"),
        trust_policy_path,
    )
    with tempfile.TemporaryDirectory(prefix="doe-proof-verify-") as directory:
        root = Path(directory)
        allowed = root / "allowed_signers"
        signature_path = root / "subject.sig"
        allowed.write_text(f"doe-proof {public_key}\n", encoding="utf-8")
        signature_path.write_bytes(base64.b64decode(receipt["signature"], validate=True))
        result = subprocess.run(
            [
                "ssh-keygen", "-Y", "verify", "-f", str(allowed),
                "-I", "doe-proof", "-n", "doe-proof", "-s", str(signature_path),
            ],
            input=subject_hash.encode(),
            capture_output=True,
        )
        _require(result.returncode == 0, "receipt signature verification failed")


def build_platform_suite(
    reports: list[dict[str, Any]],
    signing_environment: str,
    trust_policy_path: Path | None = None,
    execution_provenance: dict[str, Any] | None = None,
) -> dict[str, Any]:
    by_workload = {
        report.get("workloadId") or report.get("workload_id"): report
        for report in reports
    }
    required = {"context_snapshot_diff", "webgpu_model_preprocessing", "multi_step_agent_interaction"}
    _require(set(by_workload) == required, "suite requires all three workloads")
    platform_ids = {report["platform"]["platformId"] for report in reports}
    _require(len(platform_ids) == 1, "suite reports must share one platform")
    _require(all(report.get("evidenceStatus") in {"physical_diagnostic", "physical"} or report.get("evidence_status") == "physical_diagnostic" for report in reports), "suite contains non-physical evidence")
    _require(
        all(report.get("comparability", {}).get("status") == "pass" for report in reports),
        "suite contains incomparable evidence",
    )
    suite = {
        "schemaVersion": 1,
        "reportKind": "fawn-doe-platform-suite",
        "platform": reports[0]["platform"],
        "workloads": by_workload,
        "decisions": {
            "fawnShell": by_workload["context_snapshot_diff"].get("speedup_b_over_a", 0) >= 1.05,
            "doeRuntime": by_workload["webgpu_model_preprocessing"]["overallThesisStatus"] == "DOE_RUNTIME_PREPROCESSING_EVIDENCED",
            "directProtocol": by_workload["context_snapshot_diff"].get("overall_thesis_status") == "FAWN_DIRECT_CONTEXT_PATH_EVIDENCED",
            "verticalStack": by_workload["multi_step_agent_interaction"]["overallThesisStatus"] == "VERTICAL_AGENT_STACK_EVIDENCED",
        },
    }
    if execution_provenance is not None:
        _require(execution_provenance.get("schemaVersion") == 1, "execution provenance schemaVersion must be 1")
        _require(bool(execution_provenance.get("experimentRevision")), "execution provenance must bind the experiment revision")
        _require(bool(execution_provenance.get("runnerName")), "execution provenance must bind the physical runner")
        suite["executionProvenance"] = execution_provenance
    suite["earnedComponents"] = sorted(
        component
        for component, earned in suite["decisions"].items()
        if earned
    )
    suite["promotionReceipt"] = promotion_receipt(suite, signing_environment, trust_policy_path)
    suite["reportHash"] = canonical_hash(suite)
    return suite


def aggregate_platform_suites(
    suites: list[dict[str, Any]],
    core_platforms: list[str],
    desktop_platforms: list[str],
) -> dict[str, Any]:
    by_platform = {suite["platform"]["platformId"]: suite for suite in suites}
    missing_core = sorted(set(core_platforms) - set(by_platform))
    _require(not missing_core, "missing core physical platforms: " + ", ".join(missing_core))
    identities = [suite["platform"]["hardwareIdentity"]["identityHash"] for suite in suites]
    _require(len(identities) == len(set(identities)), "physical hardware identities are not distinct")
    aggregate = {
        "schemaVersion": 1,
        "reportKind": "fawn-doe-cross-platform-suite",
        "platforms": by_platform,
        "corePlatformStatus": "pass",
        "desktopPlatformStatus": "pass" if set(desktop_platforms) <= set(by_platform) else "pending",
        "missingDesktopPlatforms": sorted(set(desktop_platforms) - set(by_platform)),
        "publicationStatus": "review_required",
    }
    aggregate["reportHash"] = canonical_hash(aggregate)
    return aggregate


def validate_passport_candidate(
    aggregate: dict[str, Any],
    trust_policy_path: Path | None = None,
) -> None:
    _require(aggregate.get("reportKind") == "fawn-doe-cross-platform-suite", "wrong aggregate kind")
    _require(aggregate.get("corePlatformStatus") == "pass", "core platform gate failed")
    for platform_id, suite in aggregate.get("platforms", {}).items():
        receipt_subject = {
            key: value
            for key, value in suite.items()
            if key not in {"promotionReceipt", "reportHash"}
        }
        try:
            verify_promotion_receipt(
                receipt_subject,
                suite.get("promotionReceipt", {}),
                trust_policy_path,
            )
        except LiveEvidenceError as error:
            raise LiveEvidenceError(f"{platform_id} {error}") from error
        _require(bool(suite.get("earnedComponents")), f"{platform_id} earned no product component")
        _require(suite.get("decisions", {}).get("verticalStack") is True, f"{platform_id} vertical task gate failed")
