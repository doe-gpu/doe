"""Fail-closed validation for physical Fawn matrix receipts."""

from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Any

from bench.fawn_matrix.harness.lanes import compute_percentile
from bench.fawn_matrix.harness.types import Lane


class EvidenceError(ValueError):
    """Raised when a matrix receipt does not prove the declared execution."""


EXPECTED_LANES = {
    Lane.LANE_A.value: ("playwright_full_ax_v1", "dawn"),
    Lane.LANE_B.value: ("playwright_full_ax_v1", "dawn"),
    Lane.LANE_C.value: ("playwright_full_ax_v1", "doe"),
    Lane.LANE_D.value: ("fawn_direct_cdp_incremental_v1", "doe"),
}


def sha256_file(path: Path) -> str:
    """Hash a file without loading a browser binary into memory."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _contains_forbidden_key(value: Any) -> bool:
    if isinstance(value, dict):
        if "simulated_mode" in value or "simulatedMode" in value:
            return True
        return any(_contains_forbidden_key(item) for item in value.values())
    if isinstance(value, list):
        return any(_contains_forbidden_key(item) for item in value)
    return False


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise EvidenceError(message)


def _validate_artifact(
    path_text: str,
    expected_hash: str,
    hash_cache: dict[Path, str],
) -> None:
    path = Path(path_text)
    _require(path.is_file(), "runtime artifact is missing: " + path_text)
    resolved = path.resolve()
    actual_hash = hash_cache.setdefault(resolved, sha256_file(resolved))
    _require(
        actual_hash == expected_hash,
        "runtime artifact hash mismatch: " + path_text,
    )


def validate_raw_evidence(
    payload: dict[str, Any],
    workload: dict[str, Any],
    repo_root: Path,
) -> dict[str, Any]:
    """Validate identities, samples, oracle output, and lane equivalence."""
    _require(
        not _contains_forbidden_key(payload),
        "synthetic evidence is forbidden",
    )
    _require(payload.get("schemaVersion") == 1, "raw schemaVersion must be 1")
    _require(
        payload.get("reportKind")
        == "fawn-doe-context-snapshot-diff-raw",
        "unexpected raw reportKind",
    )
    _require(payload.get("runStatus") == "passed", "raw run did not pass")
    _require(
        payload.get("workload", {}).get("workloadId")
        == workload["workloadId"],
        "workload identity mismatch",
    )
    input_path = repo_root / workload["inputPath"]
    _require(input_path.is_file(), "workload input is missing")
    _require(
        payload["workload"]["inputSha256"] == sha256_file(input_path),
        "workload input hash mismatch",
    )
    _require(
        payload["run"]["laneOrderPolicy"] == "rotating_interleaved_v1",
        "lane execution was not interleaved",
    )
    _require(
        payload["run"]["warmupIterations"]
        == workload["warmupIterations"],
        "warmup count does not match config",
    )
    _require(
        payload["run"]["timedIterations"] == workload["timedIterations"],
        "timed count does not match config",
    )
    _require(
        set(payload.get("lanes", {})) == set(EXPECTED_LANES),
        "raw receipt must contain exactly four lanes",
    )
    hardware = payload.get("platform", {}).get("hardwareIdentity", {})
    _require(
        hardware.get("verified") is True,
        "physical hardware is unverified",
    )
    _require(
        bool(hardware.get("identityHash")),
        "hardware identity hash is missing",
    )

    oracle_hashes: set[str] = set()
    browser_hashes: dict[str, str] = {}
    hash_cache: dict[Path, str] = {}
    for lane_id, expected in EXPECTED_LANES.items():
        expected_transport, expected_runtime = expected
        lane = payload["lanes"][lane_id]
        _require(
            lane.get("transport") == expected_transport,
            lane_id + " transport mismatch",
        )
        runtime = lane.get("runtimeIdentity", {})
        _require(
            runtime.get("selectedRuntime") == expected_runtime,
            lane_id + " runtime mismatch",
        )
        _require(
            runtime.get("forcedMode") == expected_runtime,
            lane_id + " was not forced",
        )
        _require(
            runtime.get("fallbackApplied") is False,
            lane_id + " used fallback",
        )
        _require(
            runtime.get("hiddenFallbackAllowed") is False,
            lane_id + " permits hidden fallback",
        )
        _require(
            runtime.get("activeRuntimeProof", {}).get("matched") is True,
            lane_id + " active runtime proof failed",
        )
        browser = lane.get("browserIdentity", {})
        _validate_artifact(
            browser["executablePath"],
            browser["executableSha256"],
            hash_cache,
        )
        _validate_artifact(
            runtime["artifactPath"],
            runtime["artifactSha256"],
            hash_cache,
        )
        browser_hashes[lane_id] = browser["executableSha256"]

        samples = lane.get("samples", [])
        warmups = [
            sample for sample in samples if sample.get("phase") == "warmup"
        ]
        timed = [
            sample for sample in samples if sample.get("phase") == "timed"
        ]
        _require(
            len(warmups) == workload["warmupIterations"],
            lane_id + " warmup sample count mismatch",
        )
        _require(
            len(timed) == workload["timedIterations"],
            lane_id + " timed sample count mismatch",
        )
        latencies: list[float] = []
        for sample in timed:
            _require(
                sample.get("success") is True,
                lane_id + " has a failed sample",
            )
            _require(
                sample.get("oraclePass") is True,
                lane_id + " oracle failed",
            )
            serialized = sample.get("serializedPayload")
            _require(
                isinstance(serialized, str),
                lane_id + " payload is missing",
            )
            actual_payload_hash = hashlib.sha256(
                serialized.encode("utf-8")
            ).hexdigest()
            _require(
                actual_payload_hash == sample.get("payloadSha256"),
                lane_id + " payload hash mismatch",
            )
            _require(
                len(serialized.encode("utf-8"))
                == sample.get("serializedBytes"),
                lane_id + " serialized byte count mismatch",
            )
            oracle_hashes.add(sample["oracleSha256"])
            latencies.append(float(sample["timing"]["totalWallMs"]))
        _require(
            len(set(latencies)) > 1,
            lane_id + " timings are constant",
        )
        p50 = compute_percentile(latencies, 0.50)
        p95 = compute_percentile(latencies, 0.95)
        _require(p50 > 0, lane_id + " p50 must be positive")
        _require(
            p95 / p50
            <= workload["targetTolerances"]["maxP95P50Ratio"],
            lane_id + " exceeds configured tail variance",
        )

    _require(
        len(oracle_hashes) == 1,
        "lane oracle outputs are not equivalent",
    )
    _require(
        browser_hashes[Lane.LANE_A.value]
        != browser_hashes[Lane.LANE_B.value],
        "lane A must use stock Chromium rather than the Fawn binary",
    )
    fawn_hashes = {
        browser_hashes[Lane.LANE_B.value],
        browser_hashes[Lane.LANE_C.value],
        browser_hashes[Lane.LANE_D.value],
    }
    _require(
        len(fawn_hashes) == 1,
        "lanes B, C, and D must use one Fawn binary",
    )
    return {
        "status": "pass",
        "independentOracle": True,
        "interleaved": True,
        "oracleSha256": next(iter(oracle_hashes)),
        "physicalHardware": True,
        "structuralEquivalence": "pass",
    }
