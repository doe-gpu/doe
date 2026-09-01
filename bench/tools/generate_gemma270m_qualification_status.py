#!/usr/bin/env python3
"""Generate the Gemma 270M Electron AMD Vulkan qualification status bundle."""

from __future__ import annotations

import argparse
import hashlib
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import jsonschema

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bench.lib.bench_utils import load_json_object, write_json_object


DEFAULT_PLAN = Path("config/gemma270m-qualification-dashboard-plan.json")
DEFAULT_PLAN_SCHEMA = Path("config/gemma270m-qualification-dashboard-plan.schema.json")
DEFAULT_STATUS_SCHEMA = Path("config/gemma270m-qualification-status.schema.json")
DEFAULT_OUT = Path("bench/out/qualification/gemma270m-amd/status-bundle.json")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", default=str(DEFAULT_PLAN))
    parser.add_argument("--plan-schema", default=str(DEFAULT_PLAN_SCHEMA))
    parser.add_argument("--status-schema", default=str(DEFAULT_STATUS_SCHEMA))
    parser.add_argument("--out", default=str(DEFAULT_OUT))
    return parser.parse_args()


def resolve_path(raw: str | Path) -> Path:
    path = Path(raw)
    return path.resolve() if path.is_absolute() else (REPO_ROOT / path).resolve()


def display_path(path: Path) -> str:
    try:
        return path.resolve().relative_to(REPO_ROOT).as_posix()
    except ValueError:
        return path.resolve().as_posix()


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def evidence_ref(path: Path) -> dict[str, str]:
    return {"path": display_path(path), "sha256": sha256_file(path)}


def resolve_bound_evidence(
    artifact: dict[str, Any],
) -> tuple[Path | None, str]:
    raw_path = artifact.get("path")
    expected_sha256 = artifact.get("sha256")
    if not isinstance(raw_path, str) or not raw_path:
        return None, "evidence path is absent"
    if not isinstance(expected_sha256, str) or len(expected_sha256) != 64:
        return None, f"evidence sha256 is invalid for {raw_path}"
    path = resolve_path(raw_path)
    if not path.is_file():
        return None, f"evidence file is missing: {raw_path}"
    actual_sha256 = sha256_file(path)
    if actual_sha256 != expected_sha256:
        return None, (
            f"evidence hash mismatch for {raw_path}: "
            f"expected {expected_sha256}, observed {actual_sha256}"
        )
    return path, f"evidence hash matches for {raw_path}"


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def validate_payload(payload: dict[str, Any], schema: dict[str, Any], label: str) -> None:
    errors = sorted(
        jsonschema.Draft202012Validator(schema).iter_errors(payload),
        key=lambda error: tuple(str(part) for part in error.absolute_path),
    )
    if not errors:
        return
    details = "; ".join(
        f"{'.'.join(str(part) for part in error.absolute_path) or '<root>'}: {error.message}"
        for error in errors
    )
    raise ValueError(f"{label} schema validation failed: {details}")


def load_required_evidence(path: Path, label: str) -> dict[str, Any]:
    if not path.is_file():
        raise ValueError(f"required {label} evidence is missing: {display_path(path)}")
    return load_json_object(path)


def packed_vulkan_driver_version(value: Any) -> str:
    if not isinstance(value, int) or value < 0:
        return ""
    return f"{value >> 22}.{(value >> 12) & 0x3ff}.{value & 0xfff}"


def normalize_identity_text(value: Any) -> str:
    if not isinstance(value, str):
        return ""
    return "".join(character.lower() for character in value if character.isalnum())


def reproduction_execution_pass(receipt: dict[str, Any]) -> bool:
    return (
        receipt.get("actorId") == "doppler"
        and receipt.get("harnessId") == "gemma270m-electron"
        and receipt.get("status") == "passed"
        and receipt.get("failure") is None
        and receipt.get("preparation", {}).get("status") == "passed"
    )


def reproduction_contract_matches(
    receipt: dict[str, Any], expected_commit: str
) -> tuple[bool, str]:
    if not reproduction_execution_pass(receipt):
        return False, "canonical Electron reproduction did not complete"
    preparation_ref = receipt.get("preparation")
    if not isinstance(preparation_ref, dict):
        return False, "reproduction receipt does not bind its preparation receipt"
    preparation_path, integrity_detail = resolve_bound_evidence(preparation_ref)
    if preparation_path is None:
        return False, integrity_detail
    preparation = load_json_object(preparation_path)
    source = preparation.get("source", {})
    identity_pass = (
        preparation.get("status") == "passed"
        and preparation.get("actorId") == receipt.get("actorId")
        and preparation.get("harnessId") == receipt.get("harnessId")
        and preparation.get("runId") == receipt.get("runId")
        and source.get("requestedCommit") == expected_commit
        and source.get("actualCommit") == expected_commit
        and source.get("clean") is True
    )
    if identity_pass:
        return True, (
            f"canonical Electron reproduction binds clean Doppler commit "
            f"{expected_commit}; {integrity_detail}"
        )
    return False, (
        f"stale reproduction contract: expected clean Doppler commit "
        f"{expected_commit}; requested={source.get('requestedCommit')!r}, "
        f"actual={source.get('actualCommit')!r}"
    )


def oracle_contract_matches(
    oracle: dict[str, Any], contract: dict[str, Any]
) -> tuple[bool, str]:
    expected_model = contract.get("modelId")
    expected_steps = contract.get("execution", {}).get("decodeSteps")
    actual_model = oracle.get("modelId")
    actual_steps = oracle.get("requestedDecodeSteps")
    passed = actual_model == expected_model and actual_steps == expected_steps
    if passed:
        return True, f"oracle binds model={expected_model} decodeSteps={expected_steps}"
    return False, (
        f"stale oracle contract: expected model={expected_model!r} "
        f"decodeSteps={expected_steps!r}; observed model={actual_model!r} "
        f"decodeSteps={actual_steps!r}"
    )


def cts_identity_matches(
    report: dict[str, Any],
    *,
    provider: str,
    adapter: str,
    driver: str,
) -> tuple[bool, str]:
    summary = report.get("summary", {})
    probe = report.get("identityProbe", {})
    identity = probe.get("identity", {})
    adapter_info = identity.get("adapterInfo", {})
    actual_provider = identity.get("provider")
    actual_adapter = " ".join(
        str(adapter_info.get(field, "")) for field in ("device", "description")
    )
    adapter_match = normalize_identity_text(adapter) in normalize_identity_text(actual_adapter)
    driver_text = str(adapter_info.get("description", ""))
    packed_driver = packed_vulkan_driver_version(adapter_info.get("driverVersion"))
    driver_match = driver in driver_text or driver.removeprefix("Mesa ") == packed_driver
    passed = (
        summary.get("identityBound") is True
        and summary.get("dryRun") is False
        and probe.get("pass") is True
        and adapter_info.get("isFallbackAdapter") is False
        and actual_provider == provider
        and adapter_match
        and driver_match
    )
    if passed:
        return True, f"{provider} is bound to {adapter} on {driver}"
    return False, (
        f"expected {provider}, {adapter}, {driver}; observed provider={actual_provider!r}, "
        f"adapter={actual_adapter.strip()!r}, driver={driver_text or packed_driver!r}"
    )


def identity_gate(
    harness: dict[str, Any],
    reproduction: dict[str, Any],
    oracle: dict[str, Any],
    w0_cts: dict[str, Any],
    d0_cts: dict[str, Any],
    tuple_id: str,
    evidence: list[dict[str, str]],
) -> dict[str, Any]:
    workload = harness.get("workload", {})
    contract = workload.get("modelContract", {})
    application = contract.get("application", {})
    providers = contract.get("providers", {})
    targets = harness.get("supportTargets", [])
    target = targets[0] if len(targets) == 1 and isinstance(targets[0], dict) else {}

    contract_bound = (
        harness.get("harnessId") == "gemma270m-electron"
        and isinstance(harness.get("upstream", {}).get("commit"), str)
        and len(harness["upstream"]["commit"]) == 40
        and contract.get("modelId") == "gemma-3-270m-it-q4k-ehf16-af32"
        and application.get("runtime") == "electron"
        and application.get("version") == "43.4.0"
        and contract.get("execution", {}).get("decodeSteps") == 4
        and providers.get("W0", {}).get("id") == "dawn-node-webgpu"
        and providers.get("D0", {}).get("id") == "doe-gpu"
        and target.get("os") == "linux"
        and target.get("arch") == "x86_64"
        and target.get("adapter") == "Radeon 8060S Graphics"
        and target.get("driver") == "Mesa 26.0.3"
        and isinstance(tuple_id, str)
        and tuple_id != ""
    )
    w0_pass, w0_detail = cts_identity_matches(
        w0_cts,
        provider="dawn-node-gpu-provider",
        adapter=target.get("adapter", ""),
        driver=target.get("driver", ""),
    )
    d0_pass, d0_detail = cts_identity_matches(
        d0_cts,
        provider="fawn-node-gpu-provider",
        adapter=target.get("adapter", ""),
        driver=target.get("driver", ""),
    )
    oracle_contract_pass, oracle_contract_detail = oracle_contract_matches(
        oracle, contract
    )
    oracle_identity_pass = oracle.get("identity", {}).get("pass") is True
    reproduction_pass, reproduction_detail = reproduction_contract_matches(
        reproduction, harness.get("upstream", {}).get("commit", "")
    )
    passed = (
        contract_bound
        and reproduction_pass
        and oracle_contract_pass
        and oracle_identity_pass
        and w0_pass
        and d0_pass
    )
    details = [
        "hash-bound harness contract is complete" if contract_bound else "harness contract identity is incomplete",
        reproduction_detail,
        (
            "W0/D0 transcripts match the frozen application contract"
            if oracle_identity_pass
            else "W0/D0 transcript identity does not match the frozen application contract"
        ),
        oracle_contract_detail,
        w0_detail,
        d0_detail,
    ]
    return {
        "id": "identity",
        "status": "PASS" if passed else "FAIL",
        "detail": "; ".join(details),
        "evidence": evidence,
    }


def correctness_gate(
    oracle: dict[str, Any],
    contract: dict[str, Any],
    evidence: list[dict[str, str]],
) -> dict[str, Any]:
    logits = oracle.get("logitsComparisons", [])
    failing_logits = [row for row in logits if isinstance(row, dict) and row.get("pass") is not True]
    max_abs = max(
        (float(row.get("maxAbs", 0)) for row in logits if isinstance(row, dict)),
        default=0.0,
    )
    coverage = oracle.get("checkpointCoverage", {})
    kv = oracle.get("kv", {})
    complete_coverage = all(
        coverage.get(lane, {}).get("pass") is True for lane in ("W0", "D0")
    )
    nonzero_kv = all(kv.get(lane) is True for lane in ("W0", "D0"))
    identity_pass = oracle.get("identity", {}).get("pass") is True
    contract_pass, contract_detail = oracle_contract_matches(oracle, contract)
    passed = (
        contract_pass
        and identity_pass
        and oracle.get("pass") is True
        and oracle.get("stepCountPass") is True
        and oracle.get("modelCheckpoints", {}).get("pass") is True
        and not failing_logits
        and complete_coverage
        and nonzero_kv
    )
    detail = (
        f"{len(logits)} prefill/decode logits comparisons; {len(failing_logits)} failed; "
        f"maxAbs={max_abs:.10g}; checkpoint coverage complete={str(complete_coverage).lower()}; "
        f"non-zero KV W0/D0={str(nonzero_kv).lower()}; "
        f"Electron transcript identity={str(identity_pass).lower()}; {contract_detail}"
    )
    if not contract_pass or not identity_pass:
        detail = (
            "identity-valid Electron correctness evidence is unavailable; "
            f"diagnostic comparisons are non-qualifying; {detail}"
        )
    return {
        "id": "correctness",
        "status": "PASS" if passed else (
            "NOT_TESTED" if not contract_pass or not identity_pass else "FAIL"
        ),
        "detail": detail,
        "evidence": evidence,
    }


def cts_execution_pass(report: dict[str, Any]) -> bool:
    summary = report.get("summary", {})
    rows = report.get("rows", [])
    return (
        summary.get("identityBound") is True
        and summary.get("dryRun") is False
        and summary.get("queryCount", 0) > 0
        and summary.get("passCount") == summary.get("queryCount")
        and summary.get("failCount") == 0
        and isinstance(rows, list)
        and len(rows) == summary.get("queryCount")
        and all(isinstance(row, dict) and row.get("pass") is True for row in rows)
    )


def compatibility_gate(
    coverage: dict[str, Any],
    w0_cts: dict[str, Any],
    d0_cts: dict[str, Any],
    evidence: list[dict[str, str]],
) -> dict[str, Any]:
    coverage_pass = (
        coverage.get("supportStatus") == "full"
        and coverage.get("fullSupportAllowed") is True
        and coverage.get("summary", {}).get("failCount") == 0
    )
    w0_pass = cts_execution_pass(w0_cts)
    d0_pass = cts_execution_pass(d0_cts)
    passed = coverage_pass and w0_pass and d0_pass
    return {
        "id": "compatibility",
        "status": "PASS" if passed else "FAIL",
        "detail": (
            f"generated admitted-shader coverage full={str(coverage_pass).lower()}; "
            f"W0 subgroup CTS pass={str(w0_pass).lower()}; "
            f"D0 subgroup CTS pass={str(d0_pass).lower()}"
        ),
        "evidence": evidence,
    }


def optional_campaign_gate(gate_id: str, path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {
            "id": gate_id,
            "status": "NOT_TESTED",
            "detail": f"configured evidence is absent: {display_path(path)}",
            "evidence": [],
        }
    payload = load_json_object(path)
    passed = payload.get("pass") is True
    reported = payload.get("status")
    reason = payload.get("detail") or payload.get("reason")
    detail = f"artifact pass={str(passed).lower()}"
    if isinstance(reported, str) and reported:
        detail += f"; status={reported}"
    if isinstance(reason, str) and reason:
        detail += f"; {reason}"
    return {
        "id": gate_id,
        "status": "PASS" if passed else "FAIL",
        "detail": detail,
        "evidence": [evidence_ref(path)],
    }


def reliability_gate(
    reproduction: dict[str, Any],
    reproduction_path: Path,
    campaign_path: Path,
) -> dict[str, Any]:
    result_ref = next(
        (
            item
            for item in reproduction.get("evidence", [])
            if isinstance(item, dict)
            and item.get("id") == "qualification-result"
            and isinstance(item.get("path"), str)
        ),
        None,
    )
    result_path = None
    if result_ref is not None:
        result_path, result_integrity = resolve_bound_evidence(result_ref)
        if result_path is None:
            return {
                "id": "reliability",
                "status": "FAIL",
                "detail": (
                    "canonical Electron result evidence is not trustworthy; "
                    + result_integrity
                ),
                "evidence": [evidence_ref(reproduction_path)],
            }
    result = load_json_object(result_path) if result_path is not None else {}
    failed_lanes = []
    for lane, run in result.get("runs", {}).items():
        if not isinstance(run, dict):
            continue
        if (
            run.get("exitCode") != 0
            or run.get("signal") is not None
            or run.get("timedOut") is True
            or run.get("outputLimitExceeded") is True
        ):
            failed_lanes.append(
                f"{lane}(exitCode={run.get('exitCode')!r}, "
                f"signal={run.get('signal')!r}, timedOut={run.get('timedOut')!r})"
            )
    if failed_lanes:
        evidence = [evidence_ref(reproduction_path)]
        if result_path is not None:
            evidence.append(evidence_ref(result_path))
        return {
            "id": "reliability",
            "status": "FAIL",
            "detail": (
                "canonical Electron lane failed before clean completion; "
                + ", ".join(failed_lanes)
            ),
            "evidence": evidence,
        }
    return optional_campaign_gate("reliability", campaign_path)


def ownership_gate(gates: list[dict[str, Any]]) -> dict[str, Any]:
    blockers = [gate["id"] for gate in gates if gate.get("status") != "PASS"]
    accepted = not blockers
    detail = (
        "all prerequisite gates pass"
        if accepted
        else "ownership rejected; non-passing gates: " + ", ".join(blockers)
    )
    return {
        "id": "ownership",
        "status": "PASS" if accepted else "REJECTED",
        "detail": detail,
        "evidence": [ref for gate in gates for ref in gate.get("evidence", [])],
    }


def build_status_bundle(
    plan: dict[str, Any],
    plan_path: Path,
    harness: dict[str, Any],
    harness_path: Path,
    reproduction: dict[str, Any],
    reproduction_path: Path,
    oracle: dict[str, Any],
    oracle_path: Path,
    coverage: dict[str, Any],
    coverage_path: Path,
    w0_cts: dict[str, Any],
    w0_cts_path: Path,
    d0_cts: dict[str, Any],
    d0_cts_path: Path,
    reliability_path: Path,
    performance_path: Path,
) -> dict[str, Any]:
    contract = harness["workload"]["modelContract"]
    application = contract["application"]
    target = harness["supportTargets"][0]
    source_refs = [
        evidence_ref(harness_path),
        evidence_ref(reproduction_path),
        evidence_ref(oracle_path),
        evidence_ref(w0_cts_path),
        evidence_ref(d0_cts_path),
    ]
    gates = [
        identity_gate(
            harness,
            reproduction,
            oracle,
            w0_cts,
            d0_cts,
            plan["tupleId"],
            source_refs,
        ),
        correctness_gate(oracle, contract, [evidence_ref(oracle_path)]),
        compatibility_gate(
            coverage,
            w0_cts,
            d0_cts,
            [evidence_ref(coverage_path), evidence_ref(w0_cts_path), evidence_ref(d0_cts_path)],
        ),
        reliability_gate(reproduction, reproduction_path, reliability_path),
        optional_campaign_gate("performance", performance_path),
    ]
    gates.append(ownership_gate(gates))
    accepted = gates[-1]["status"] == "PASS"
    return {
        "schemaVersion": 1,
        "artifactKind": "gemma270m_qualification_status",
        "dashboardId": plan["dashboardId"],
        "generatedAtUtc": utc_now(),
        "sourcePlan": evidence_ref(plan_path),
        "tuple": {
            "tupleId": plan["tupleId"],
            "modelId": contract["modelId"],
            "application": f"Electron {application['version']} ({application['mode']})",
            "os": target["os"],
            "arch": target["arch"],
            "adapter": target["adapter"],
            "driver": target["driver"],
            "providers": {
                "W0": contract["providers"]["W0"]["id"],
                "D0": contract["providers"]["D0"]["id"],
            },
        },
        "gates": gates,
        "decision": "ACCEPTED" if accepted else "REJECTED",
    }


def main() -> int:
    args = parse_args()
    plan_path = resolve_path(args.plan)
    plan_schema = load_json_object(resolve_path(args.plan_schema))
    status_schema = load_json_object(resolve_path(args.status_schema))
    plan = load_json_object(plan_path)
    validate_payload(plan, plan_schema, "dashboard plan")

    evidence = plan["evidence"]
    harness_path = resolve_path(plan["harnessPath"])
    reproduction_path = resolve_path(evidence["reproductionReceipt"])
    oracle_path = resolve_path(evidence["checkpointOracle"])
    coverage_path = resolve_path(evidence["compilerCoverage"])
    w0_cts_path = resolve_path(evidence["subgroupCtsW0"])
    d0_cts_path = resolve_path(evidence["subgroupCtsD0"])

    bundle = build_status_bundle(
        plan,
        plan_path,
        load_required_evidence(harness_path, "harness"),
        harness_path,
        load_required_evidence(reproduction_path, "reproduction receipt"),
        reproduction_path,
        load_required_evidence(oracle_path, "checkpoint oracle"),
        oracle_path,
        load_required_evidence(coverage_path, "compiler coverage"),
        coverage_path,
        load_required_evidence(w0_cts_path, "W0 subgroup CTS"),
        w0_cts_path,
        load_required_evidence(d0_cts_path, "D0 subgroup CTS"),
        d0_cts_path,
        resolve_path(evidence["reliabilityCampaign"]),
        resolve_path(evidence["performanceComparison"]),
    )
    validate_payload(bundle, status_schema, "qualification status")
    out_path = resolve_path(args.out)
    write_json_object(out_path, bundle)
    print(
        f"Gemma 270M qualification status: {bundle['decision']} "
        f"({display_path(out_path)})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
