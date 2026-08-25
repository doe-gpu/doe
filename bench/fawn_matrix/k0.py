"""Fail-closed execution for the external K0 browser comparator."""

from __future__ import annotations

import datetime
import hashlib
import json
import time
from pathlib import Path
from typing import Any, Callable


Transport = Callable[[str, dict[str, Any]], dict[str, Any]]


def _canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def _sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _write_bytes_atomic(path: Path, value: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_bytes(value)
    temporary.replace(path)


def _write_json_atomic(path: Path, value: dict[str, Any]) -> None:
    _write_bytes_atomic(
        path,
        json.dumps(value, indent=2, sort_keys=True).encode("utf-8") + b"\n",
    )


def _validated_bindings(
    policy: dict[str, Any],
    bindings: dict[str, Any],
) -> dict[str, dict[str, Any]]:
    if bindings.get("comparatorId") != "K0":
        raise ValueError("K0 bindings must declare comparatorId K0")
    tasks = bindings.get("tasks")
    if not isinstance(tasks, list):
        raise ValueError("K0 bindings tasks must be an array")
    by_id: dict[str, dict[str, Any]] = {}
    for task in tasks:
        task_id = task.get("taskId")
        if not isinstance(task_id, str) or task_id in by_id:
            raise ValueError("K0 bindings require unique taskId values")
        by_id[task_id] = task
    eligible = {
        task["taskId"]
        for task in policy["taskAdmission"]
        if task["eligibility"] == "eligible"
    }
    if set(by_id) != eligible:
        raise ValueError(
            "K0 bindings must contain exactly the admitted tasks: "
            + ", ".join(sorted(eligible))
        )
    return by_id


def _ineligible_result(task: dict[str, Any]) -> dict[str, Any]:
    return {
        "taskId": task["taskId"],
        "suiteId": task["suiteId"],
        "eligibility": "ineligible",
        "eligibilityReason": task["reasonCode"],
        "executionStatus": "ineligible",
        "action": None,
        "request": None,
        "response": None,
        "oracle": None,
        "observations": None,
        "failure": None,
        "fawnCreditAllowed": False,
    }


def _browser_ms(headers: dict[str, str]) -> float | None:
    value = headers.get("x-browser-ms-used")
    if value is None:
        return None
    try:
        return float(value)
    except ValueError:
        return None


def _eligible_result(
    task: dict[str, Any],
    binding: dict[str, Any],
    output_directory: Path,
    transport: Transport,
) -> dict[str, Any]:
    action = task["action"]
    url = binding["url"]
    request_value = {"action": action, "browser": "kitesurf", "url": url}
    request_digest = _sha256(_canonical_bytes(request_value))
    started = time.monotonic()
    try:
        observed = transport(action, binding)
        body = observed["body"]
        if not isinstance(body, bytes):
            raise TypeError("K0 transport body must be bytes")
        headers = {
            str(key).lower(): str(value)
            for key, value in observed.get("headers", {}).items()
        }
        status = int(observed["httpStatus"])
        if status < 200 or status >= 300:
            raise ValueError(f"K0 endpoint returned HTTP {status}")
        actual_sha256 = _sha256(body)
        artifact_path = Path("responses") / f"{task['taskId']}.response.bin"
        _write_bytes_atomic(output_directory / artifact_path, body)
        expected_sha256 = binding["oracle"]["expectedSha256"]
        oracle_pass = actual_sha256 == expected_sha256
        failure = None if oracle_pass else "exact-response-sha256-mismatch"
        return {
            "taskId": task["taskId"],
            "suiteId": task["suiteId"],
            "eligibility": "eligible",
            "eligibilityReason": task["reasonCode"],
            "executionStatus": "passed" if oracle_pass else "failed",
            "action": action,
            "request": {
                "url": url,
                "requestDigest": request_digest,
            },
            "response": {
                "artifactPath": artifact_path.as_posix(),
                "sha256": actual_sha256,
                "byteLength": len(body),
                "httpStatus": status,
                "contentType": headers.get("content-type"),
            },
            "oracle": {
                "kind": "exact-response-sha256",
                "expectedSha256": expected_sha256,
                "actualSha256": actual_sha256,
                "pass": oracle_pass,
            },
            "observations": {
                "wallTimeMs": (time.monotonic() - started) * 1000,
                "browserMsUsed": _browser_ms(headers),
                "retries": 0,
                "costUsd": None,
                "memoryBytes": None,
                "tokens": None,
                "compatibilityFailures": [],
                "unsupportedFeatures": [],
            },
            "failure": failure,
            "fawnCreditAllowed": False,
        }
    except Exception as error:
        return {
            "taskId": task["taskId"],
            "suiteId": task["suiteId"],
            "eligibility": "eligible",
            "eligibilityReason": task["reasonCode"],
            "executionStatus": "failed",
            "action": action,
            "request": {"url": url, "requestDigest": request_digest},
            "response": None,
            "oracle": {
                "kind": "exact-response-sha256",
                "expectedSha256": binding["oracle"]["expectedSha256"],
                "actualSha256": None,
                "pass": False,
            },
            "observations": {
                "wallTimeMs": (time.monotonic() - started) * 1000,
                "browserMsUsed": None,
                "retries": 0,
                "costUsd": None,
                "memoryBytes": None,
                "tokens": None,
                "compatibilityFailures": [type(error).__name__],
                "unsupportedFeatures": [],
            },
            "failure": str(error),
            "fawnCreditAllowed": False,
        }


def execute_k0_suite(
    policy: dict[str, Any],
    bindings: dict[str, Any],
    output_path: Path,
    transport: Transport,
    now: Callable[[], str] | None = None,
) -> dict[str, Any]:
    """Execute admitted K0 tasks and retain every ineligible task."""
    by_id = _validated_bindings(policy, bindings)
    output_directory = output_path.parent
    task_results = []
    for task in policy["taskAdmission"]:
        if task["eligibility"] == "ineligible":
            task_results.append(_ineligible_result(task))
            continue
        task_results.append(
            _eligible_result(
                task,
                by_id[task["taskId"]],
                output_directory,
                transport,
            )
        )
    eligible_pass = all(
        task["executionStatus"] == "passed"
        for task in task_results
        if task["eligibility"] == "eligible"
    )
    clock = now or (
        lambda: datetime.datetime.now(datetime.timezone.utc).isoformat()
    )
    report = {
        "schemaVersion": 1,
        "reportKind": "fawn-k0-external-comparator-result",
        "executionId": bindings["executionId"],
        "comparatorId": "K0",
        "policyDigest": _sha256(_canonical_bytes(policy)),
        "evidenceStatus": (
            "passed-unpromoted" if eligible_pass else "failed-unpromoted"
        ),
        "claimAllowed": False,
        "fawnCreditAllowed": False,
        "doeRuntimeCreditAllowed": False,
        "directProtocolCreditAllowed": False,
        "tasks": task_results,
        "generatedAtUtc": clock(),
    }
    _write_json_atomic(output_path, report)
    return report
