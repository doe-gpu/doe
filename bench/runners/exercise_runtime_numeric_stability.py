#!/usr/bin/env python3
"""Exercise promoted numeric-fragility cases through the live runtime service."""

from __future__ import annotations

import argparse
import json
import math
import os
import struct
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
for _path_entry in (str(REPO_ROOT), str(BENCH_ROOT)):
    if _path_entry not in os.sys.path:
        os.sys.path.insert(0, _path_entry)

from bench.lib.bench_utils import load_json_object as load_json
from bench.lib.config_validation import load_validated_config
from bench.runners.promote_numeric_fragility_signatures import (
    FRAGILITY_SIGNATURE_SCHEMA_PATH,
    PROMOTED_CATALOG_SCHEMA_PATH,
    build_catalog,
    sanitize_signature_file_name,
)


DEFAULT_PLAN_PATH = REPO_ROOT / "config" / "runtime-numeric-stability-exercise.json"
DEFAULT_MODULE_RUNNER_CANDIDATES = [
    REPO_ROOT / "runtime" / "zig" / "zig-out" / "bin" / "module-core-runner",
    REPO_ROOT / "runtime" / "zig-out" / "bin" / "module-core-runner",
]
CASE_REPORT_NAME = "runtime-numeric-stability.case.json"
RESULT_FILE_NAME = "runtime-numeric-stability.result.json"
REQUEST_FILE_NAME = "runtime-numeric-stability.request.json"
RECEIPT_FILE_NAME = "runtime-numeric-stability.receipt.jsonl"
TRACE_META_FILE_NAME = "runtime-numeric-stability.trace-meta.json"
MANIFEST_FILE_NAME = "apple_metal_runtime_numeric_stability.manifest.json"
SUPPORTED_OPERATOR_FAMILY = "lm-head-slice"
SUPPORTED_SEMANTIC_OP_ID = "matmul.logits"
SUPPORTED_FAST_POLICY_ID = "lm-head-slice/forward-f16accum-v1"
SUPPORTED_STABLE_POLICY_ID = "lm-head-slice/forward-serial-v1"
DEFAULT_TRIGGER_POLICY_ID = (
    "numeric-instability/selected-token-disagreement-with-reference-improvement-v1"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--plan",
        default=str(DEFAULT_PLAN_PATH),
        help="Runtime numeric-stability exercise plan JSON.",
    )
    parser.add_argument(
        "--timestamp",
        default=None,
        help="UTC timestamp label. Default: current UTC time.",
    )
    parser.add_argument(
        "--module-runner",
        default=None,
        help="Explicit module-core-runner path.",
    )
    return parser.parse_args()


def timestamp_label() -> str:
    import datetime as dt

    return dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def repo_rel(path_value: str | Path | None) -> str | None:
    if path_value is None:
        return None
    path = Path(path_value)
    absolute = path if path.is_absolute() else (REPO_ROOT / path)
    absolute = absolute.resolve()
    try:
        return str(absolute.relative_to(REPO_ROOT.resolve()))
    except ValueError:
        return str(absolute)


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w",
        encoding="utf-8",
        dir=path.parent,
        prefix=f".{path.name}.",
        suffix=".tmp",
        delete=False,
    ) as handle:
        handle.write(json.dumps(payload, indent=2) + "\n")
        temp_path = Path(handle.name)
    temp_path.replace(path)


def unique_paths(paths: list[str | None]) -> list[str]:
    seen: set[str] = set()
    ordered: list[str] = []
    for item in paths:
        if item is None:
            continue
        if item in seen:
            continue
        seen.add(item)
        ordered.append(item)
    return ordered


def find_module_runner_path(explicit_path: str | None) -> Path:
    candidates: list[Path] = []
    if explicit_path:
        candidates.append(Path(explicit_path))
    env_path = os.environ.get("DOE_MODULE_RUNNER")
    if env_path:
        candidates.append(Path(env_path))
    candidates.extend(DEFAULT_MODULE_RUNNER_CANDIDATES)
    for candidate in candidates:
        if candidate.exists():
            return candidate
    raise FileNotFoundError(
        "module-core-runner not found; build it with `zig build module-core-runner` or pass --module-runner"
    )


def percentile(values: list[int], ratio: float) -> int:
    if not values:
        return 0
    if len(values) == 1:
        return values[0]
    index = int(math.ceil(ratio * len(values))) - 1
    index = max(0, min(index, len(values) - 1))
    return sorted(values)[index]


def build_stats(values: list[int]) -> dict[str, Any]:
    ordered = sorted(values)
    return {
        "count": len(ordered),
        "min": ordered[0],
        "max": ordered[-1],
        "mean": sum(ordered) / len(ordered),
        "p50": percentile(ordered, 0.50),
        "p95": percentile(ordered, 0.95),
    }


def u32_words_to_f32(words: list[int]) -> list[float]:
    return [struct.unpack("<f", struct.pack("<I", int(word)))[0] for word in words]


def candidate_label(token_text: str) -> str:
    stripped = token_text.strip()
    return stripped if stripped else token_text


def find_prompt_fixture_path(signature: dict[str, Any]) -> Path:
    for related_path in signature.get("relatedArtifactPaths") or []:
        if not related_path.endswith(".fixture.json"):
            continue
        if "selective_stable_rerun" in related_path:
            continue
        return (REPO_ROOT / related_path).resolve()
    raise FileNotFoundError(f"no prompt fixture found for signature {signature['signatureId']}")


def find_logits_capture(fixture: dict[str, Any]) -> dict[str, Any]:
    for capture in fixture.get("captures") or []:
        if capture.get("semanticOpId") == SUPPORTED_SEMANTIC_OP_ID:
            return capture
    raise ValueError(f"fixture {fixture.get('scenarioId')} is missing {SUPPORTED_SEMANTIC_OP_ID} capture")


def find_forward_commands_path(fixture: dict[str, Any]) -> Path:
    for variant in fixture.get("variants") or []:
        if variant.get("id") == "forward":
            return (REPO_ROOT / variant["commandsPath"]).resolve()
    raise ValueError(f"fixture {fixture.get('scenarioId')} is missing forward commands")


def hidden_and_weights_from_commands(commands_path: Path) -> tuple[list[float], list[list[float]]]:
    commands = json.loads(commands_path.read_text(encoding="utf-8"))
    logits_dispatch = None
    for command in commands:
        if not isinstance(command, dict):
            continue
        if command.get("kind") != "kernel_dispatch":
            continue
        if not str(command.get("kernel", "")).startswith("matmul_logits_"):
            continue
        logits_dispatch = command
        break
    if logits_dispatch is None:
        raise ValueError(f"{commands_path} is missing matmul logits dispatch")
    hidden_handle = None
    weight_handle = None
    for binding in logits_dispatch.get("bindings") or []:
        if binding.get("binding") == 1:
            hidden_handle = binding.get("resource_handle")
        elif binding.get("binding") == 2:
            weight_handle = binding.get("resource_handle")
    if hidden_handle is None or weight_handle is None:
        raise ValueError(f"{commands_path} is missing hidden-state or weight bindings")
    hidden_words = None
    weight_words = None
    for command in commands:
        if not isinstance(command, dict) or command.get("kind") != "buffer_write":
            continue
        if command.get("handle") == hidden_handle:
            hidden_words = command.get("data")
        elif command.get("handle") == weight_handle:
            weight_words = command.get("data")
    if hidden_words is None or weight_words is None:
        raise ValueError(f"{commands_path} is missing hidden-state or weight data")
    hidden_state = u32_words_to_f32(hidden_words)
    flat_weights = u32_words_to_f32(weight_words)
    if len(hidden_state) == 0 or len(flat_weights) % len(hidden_state) != 0:
        raise ValueError(f"{commands_path} has inconsistent hidden-state and weight lengths")
    candidate_count = len(flat_weights) // len(hidden_state)
    weights = [
        flat_weights[index * len(hidden_state) : (index + 1) * len(hidden_state)]
        for index in range(candidate_count)
    ]
    return hidden_state, weights


def prompt_request_from_signature(signature: dict[str, Any], routing_policy_id: str) -> tuple[dict[str, Any], dict[str, Any]]:
    fixture_path = find_prompt_fixture_path(signature)
    fixture = load_json(fixture_path)
    capture = find_logits_capture(fixture)
    hidden_state, weight_rows = hidden_and_weights_from_commands(find_forward_commands_path(fixture))
    candidate_rows = fixture["candidateRows"]
    if len(candidate_rows) != len(weight_rows):
        raise ValueError(f"{fixture_path} candidate rows do not match decoded weights")
    request = {
        "schemaVersion": 1,
        "moduleId": "doe_numeric_stability",
        "artifactKind": "request",
        "serviceId": "matmul_logits_slice",
        "operatorFamily": SUPPORTED_OPERATOR_FAMILY,
        "semanticOpId": SUPPORTED_SEMANTIC_OP_ID,
        "semanticStage": capture.get("semanticStage") or fixture.get("scenarioId"),
        "semanticPhase": capture.get("semanticPhase") or "logits",
        "triggerPolicyId": DEFAULT_TRIGGER_POLICY_ID,
        "routingPolicyId": routing_policy_id,
        "fastPolicyId": SUPPORTED_FAST_POLICY_ID,
        "stablePolicyId": SUPPORTED_STABLE_POLICY_ID,
        "hiddenState": hidden_state,
        "candidates": [
            {
                "tokenId": int(candidate["tokenId"]),
                "label": candidate_label(str(candidate["tokenText"])),
                "weights": weight_rows[index],
            }
            for index, candidate in enumerate(candidate_rows)
        ],
    }
    source_info = {
        "fixturePath": repo_rel(fixture_path),
        "commandsPath": repo_rel(find_forward_commands_path(fixture)),
    }
    return request, source_info


def token_text_from_receipt(receipt: dict[str, Any], token_id: int | None) -> str | None:
    if token_id is None:
        return None
    for candidate in receipt.get("candidates") or []:
        if int(candidate["tokenId"]) == int(token_id):
            label = candidate.get("label")
            if label is not None:
                return str(label)
            return f"token:{token_id}"
    return f"token:{token_id}"


def selection_payload(
    *,
    token_id: int | None,
    token_text: str | None,
    variant_id: str | None,
    policy_id: str | None,
    exact_reference_token_id: int | None,
) -> dict[str, Any] | None:
    if token_id is None or token_text is None:
        return None
    payload: dict[str, Any] = {
        "tokenId": int(token_id),
        "tokenText": str(token_text),
        "matchesExactReference": (
            exact_reference_token_id is not None and int(token_id) == int(exact_reference_token_id)
        ),
    }
    if variant_id:
        payload["variantId"] = str(variant_id)
    if policy_id:
        payload["policyId"] = str(policy_id)
    return payload


def selected_variant_id(route_decision: str) -> str | None:
    if route_decision == "prefer-stable":
        return "forward"
    if route_decision == "accept-fast":
        return "f16accum"
    return None


def update_signature_from_result(
    signature: dict[str, Any],
    *,
    result: dict[str, Any],
    case_report_rel: str,
    request_rel: str,
    result_rel: str,
    receipt_rel: str,
    trace_meta_rel: str,
) -> dict[str, Any]:
    receipt = result["receipt"]
    updated = dict(signature)
    updated["contractStage"] = "runtime-exercised"
    updated["notes"] = (
        "Runtime-exercised through the live Zig numeric-stability service; "
        f"see `{case_report_rel}` for route and overhead details."
    )
    updated["relatedArtifactPaths"] = unique_paths(
        list(updated.get("relatedArtifactPaths") or [])
        + [request_rel, result_rel, receipt_rel, trace_meta_rel, case_report_rel]
    )
    reference_token_id = int(receipt["selectedToken"]["reference"])
    fast_token_id = int(receipt["selectedToken"]["fast"])
    stable_token_id = int(receipt["selectedToken"]["stable"])
    updated["referenceSelection"] = selection_payload(
        token_id=reference_token_id,
        token_text=token_text_from_receipt(receipt, reference_token_id),
        variant_id="exact-reference",
        policy_id=receipt["referencePolicyId"],
        exact_reference_token_id=reference_token_id,
    )
    updated["fastSelection"] = selection_payload(
        token_id=fast_token_id,
        token_text=token_text_from_receipt(receipt, fast_token_id),
        variant_id="f16accum",
        policy_id=receipt["fastPolicyId"],
        exact_reference_token_id=reference_token_id,
    )
    updated["stableSelection"] = selection_payload(
        token_id=stable_token_id,
        token_text=token_text_from_receipt(receipt, stable_token_id),
        variant_id="forward",
        policy_id=receipt["stablePolicyId"],
        exact_reference_token_id=reference_token_id,
    )
    if receipt.get("firstDivergence") is not None:
        divergence = receipt["firstDivergence"]
        updated["firstDivergence"] = {
            "semanticOpId": divergence["semanticOpId"],
            "operatorFamily": receipt["operatorFamily"],
            "semanticStage": divergence["semanticStage"],
            "semanticPhase": divergence["semanticPhase"],
            "fastDigest": divergence["fastDigest"],
            "stableDigest": divergence["stableDigest"],
        }
    updated["routeOutcome"] = {
        "decision": result["routeDecision"],
        "receiptArtifactPath": receipt_rel,
    }
    variant_id = selected_variant_id(result["routeDecision"])
    if variant_id is not None:
        updated["routeOutcome"]["selectedVariantId"] = variant_id
    if result.get("selectedToken") is not None:
        updated["routeOutcome"]["selectedTokenId"] = int(result["selectedToken"])
    proof_links = []
    for container in (receipt.get("trigger", {}), receipt.get("route", {})):
        for link in container.get("proofLinks") or []:
            normalized = dict(link)
            normalized["artifactPath"] = repo_rel(link.get("artifactPath")) or str(link.get("artifactPath"))
            if normalized not in proof_links:
                proof_links.append(normalized)
    if proof_links:
        updated["proofLinks"] = proof_links
    return updated


def build_synthetic_signature(
    control: dict[str, Any],
    *,
    result: dict[str, Any],
    request_rel: str,
    result_rel: str,
    receipt_rel: str,
    trace_meta_rel: str,
    case_report_rel: str,
    route_taxonomy_version: str,
) -> dict[str, Any]:
    receipt = result["receipt"]
    reference_token_id = int(receipt["selectedToken"]["reference"])
    fast_token_id = int(receipt["selectedToken"]["fast"])
    stable_token_id = int(receipt["selectedToken"]["stable"])
    signature: dict[str, Any] = {
        "schemaVersion": 1,
        "signatureId": control["signatureId"],
        "contractStage": "runtime-exercised",
        "artifactKind": control["artifactKind"],
        "corpusClass": control["corpusClass"],
        "routeTaxonomyVersion": route_taxonomy_version,
        "sourceArtifactPath": result_rel,
        "scenarioStem": control["scenarioStem"],
        "sourceSearchArtifactPath": request_rel,
        "relatedArtifactPaths": [request_rel, result_rel, receipt_rel, trace_meta_rel, case_report_rel],
        "answerSet": {
            "answerSetId": "_".join(
                candidate_label(str(candidate.get("label") or candidate["tokenId"])).lower()
                for candidate in control["request"]["candidates"]
            ),
            "candidateSetSource": "runtime-exercise-control",
            "candidates": [
                {
                    "tokenId": int(candidate["tokenId"]),
                    "tokenText": candidate_label(str(candidate.get("label") or candidate["tokenId"])),
                    "priority": index,
                }
                for index, candidate in enumerate(control["request"]["candidates"])
            ],
        },
        "referenceSelection": selection_payload(
            token_id=reference_token_id,
            token_text=token_text_from_receipt(receipt, reference_token_id),
            variant_id="exact-reference",
            policy_id=receipt["referencePolicyId"],
            exact_reference_token_id=reference_token_id,
        ),
        "fastSelection": selection_payload(
            token_id=fast_token_id,
            token_text=token_text_from_receipt(receipt, fast_token_id),
            variant_id="f16accum",
            policy_id=receipt["fastPolicyId"],
            exact_reference_token_id=reference_token_id,
        ),
        "stableSelection": selection_payload(
            token_id=stable_token_id,
            token_text=token_text_from_receipt(receipt, stable_token_id),
            variant_id="forward",
            policy_id=receipt["stablePolicyId"],
            exact_reference_token_id=reference_token_id,
        ),
        "routeExpectation": {
            "decision": control["expectedRouteDecision"],
            "status": "realized-in-runtime-control",
            "sourceArtifactPath": result_rel,
            "hasPromotionEvidence": False,
        },
        "routeOutcome": {
            "decision": result["routeDecision"],
            "receiptArtifactPath": receipt_rel,
        },
        "notes": (
            "Synthetic live runtime control used to prove the `accept-fast` route "
            f"on the explicit Zig numeric-stability service; see `{case_report_rel}`."
        ),
    }
    if receipt.get("firstDivergence") is not None:
        signature["firstDivergence"] = {
            "semanticOpId": receipt["firstDivergence"]["semanticOpId"],
            "operatorFamily": receipt["operatorFamily"],
            "semanticStage": receipt["firstDivergence"]["semanticStage"],
            "semanticPhase": receipt["firstDivergence"]["semanticPhase"],
            "fastDigest": receipt["firstDivergence"]["fastDigest"],
            "stableDigest": receipt["firstDivergence"]["stableDigest"],
        }
    if result.get("selectedToken") is not None:
        signature["routeOutcome"]["selectedTokenId"] = int(result["selectedToken"])
    variant_id = selected_variant_id(result["routeDecision"])
    if variant_id is not None:
        signature["routeOutcome"]["selectedVariantId"] = variant_id
    return signature


def build_manifest_case_entry(
    *,
    case_id: str,
    signature_id: str,
    scenario_stem: str,
    route_decision: str,
    expected_route_decision: str,
    contract_stage: str,
    request_rel: str,
    result_rel: str,
    receipt_rel: str,
    trace_meta_rel: str,
    case_report_rel: str,
    process_wall_ns: list[int],
    dispatch_ns: list[int],
    bytes_moved: int,
    candidate_count: int,
) -> dict[str, Any]:
    return {
        "caseId": case_id,
        "signatureId": signature_id,
        "scenarioStem": scenario_stem,
        "contractStage": contract_stage,
        "routeDecision": route_decision,
        "expectedRouteDecision": expected_route_decision,
        "requestPath": request_rel,
        "resultPath": result_rel,
        "receiptPath": receipt_rel,
        "traceMetaPath": trace_meta_rel,
        "caseReportPath": case_report_rel,
        "processWallNs": build_stats(process_wall_ns),
        "dispatchNs": build_stats(dispatch_ns),
        "bytesMoved": bytes_moved,
        "candidateCount": candidate_count,
    }


def run_module_runner(
    *,
    module_runner_path: Path,
    request_path: Path,
    policy_path: Path,
) -> tuple[dict[str, Any], int]:
    start_ns = time.perf_counter_ns()
    result = subprocess.run(
        [
            str(module_runner_path),
            "--module",
            "doe_numeric_stability",
            "--request",
            str(request_path),
            "--policy",
            str(policy_path),
        ],
        cwd=REPO_ROOT,
        check=False,
        text=True,
        capture_output=True,
    )
    elapsed_ns = time.perf_counter_ns() - start_ns
    if result.returncode != 0:
        raise RuntimeError(
            f"module-core-runner failed ({result.returncode}): {result.stderr or result.stdout}"
        )
    payload = json.loads(result.stdout)
    return payload, elapsed_ns


def exercise_request(
    *,
    module_runner_path: Path,
    policy_path: Path,
    request: dict[str, Any],
    case_dir: Path,
    repeat_count: int,
) -> tuple[dict[str, Any], dict[str, Any]]:
    case_dir.mkdir(parents=True, exist_ok=True)
    request_path = case_dir / REQUEST_FILE_NAME
    result_path = case_dir / RESULT_FILE_NAME
    receipt_path = case_dir / RECEIPT_FILE_NAME
    trace_meta_path = case_dir / TRACE_META_FILE_NAME
    request = dict(request)
    request["receiptPath"] = repo_rel(receipt_path)
    request["traceMetaPath"] = repo_rel(trace_meta_path)
    write_json(request_path, request)

    process_wall_ns: list[int] = []
    dispatch_ns: list[int] = []
    last_result: dict[str, Any] | None = None
    last_receipt_key: str | None = None
    for _ in range(repeat_count):
        result, wall_ns = run_module_runner(
            module_runner_path=module_runner_path,
            request_path=request_path,
            policy_path=policy_path,
        )
        process_wall_ns.append(wall_ns)
        dispatch_ns.append(int(result["timingStats"]["dispatchNs"]))
        receipt_key = json.dumps(result["receipt"], sort_keys=True)
        if last_result is None:
            last_result = result
            last_receipt_key = receipt_key
            continue
        if result["routeDecision"] != last_result["routeDecision"]:
            raise RuntimeError(
                f"inconsistent route decisions across repeats: {last_result['routeDecision']} vs {result['routeDecision']}"
            )
        if receipt_key != last_receipt_key:
            raise RuntimeError(
                f"inconsistent numeric-stability receipts across repeats for {request_path}"
            )
        last_result = result
        last_receipt_key = receipt_key

    assert last_result is not None
    write_json(result_path, last_result)
    case_report = {
        "schemaVersion": 1,
        "artifactKind": "runtime-numeric-stability-exercise-case",
        "routeDecision": last_result["routeDecision"],
        "selectedToken": last_result.get("selectedToken"),
        "requestPath": repo_rel(request_path),
        "resultPath": repo_rel(result_path),
        "receiptPath": repo_rel(receipt_path),
        "traceMetaPath": repo_rel(trace_meta_path),
        "processWallNs": build_stats(process_wall_ns),
        "dispatchNs": build_stats(dispatch_ns),
        "executionStats": last_result["executionStats"],
    }
    case_report_path = case_dir / CASE_REPORT_NAME
    write_json(case_report_path, case_report)
    return last_result, {
        "requestPath": repo_rel(request_path),
        "resultPath": repo_rel(result_path),
        "receiptPath": repo_rel(receipt_path),
        "traceMetaPath": repo_rel(trace_meta_path),
        "caseReportPath": repo_rel(case_report_path),
        "processWallNs": process_wall_ns,
        "dispatchNs": dispatch_ns,
    }


def rebuild_catalog(
    signature_root: Path,
    existing_catalog: dict[str, Any],
    *,
    catalog_signature_root: Path | None = None,
) -> dict[str, Any]:
    signatures: list[tuple[Path, dict[str, Any]]] = []
    for signature_path in sorted(signature_root.glob("*.json")):
        signature = load_validated_config(signature_path, FRAGILITY_SIGNATURE_SCHEMA_PATH)
        catalog_path = (
            signature_path
            if catalog_signature_root is None
            else catalog_signature_root / signature_path.name
        )
        signatures.append((catalog_path, signature))
    return build_catalog(
        signatures=signatures,
        catalog_version=existing_catalog["catalogVersion"],
        promotion_policy_id=existing_catalog["promotionPolicyId"],
        route_taxonomy_version=existing_catalog["routeTaxonomyVersion"],
        source_corpus_path=existing_catalog["sourceCorpusPath"],
        source_manifest_path=existing_catalog.get("sourceManifestPath"),
    )


def main() -> None:
    args = parse_args()
    plan_path = Path(args.plan)
    plan = load_validated_config(plan_path)
    policy_path = (REPO_ROOT / plan["policyRegistryPath"]).resolve()
    catalog_path = (REPO_ROOT / plan["promotedCatalogPath"]).resolve()
    signature_root = (REPO_ROOT / plan["signatureRoot"]).resolve()
    output_root = (REPO_ROOT / plan["outputRoot"]).resolve()
    catalog = load_validated_config(catalog_path)
    module_runner_path = find_module_runner_path(args.module_runner)
    timestamp = args.timestamp or timestamp_label()
    run_dir = output_root / timestamp
    run_dir.mkdir(parents=True, exist_ok=True)

    catalog_entries = {entry["signatureId"]: entry for entry in catalog["entries"]}
    manifest_cases: list[dict[str, Any]] = []

    for case in plan["cases"]:
        entry = catalog_entries[case["signatureId"]]
        signature_path = (REPO_ROOT / entry["signaturePath"]).resolve()
        signature = load_validated_config(signature_path, FRAGILITY_SIGNATURE_SCHEMA_PATH)
        request, _source_info = prompt_request_from_signature(signature, case["routingPolicyId"])
        result, artifact_paths = exercise_request(
            module_runner_path=module_runner_path,
            policy_path=policy_path,
            request=request,
            case_dir=run_dir / case["caseId"],
            repeat_count=int(plan["repeatCount"]),
        )
        if result["routeDecision"] != case["expectedRouteDecision"]:
            raise RuntimeError(
                f"{case['caseId']} expected {case['expectedRouteDecision']} but got {result['routeDecision']}"
            )
        updated_signature = update_signature_from_result(
            signature,
            result=result,
            case_report_rel=artifact_paths["caseReportPath"],
            request_rel=artifact_paths["requestPath"],
            result_rel=artifact_paths["resultPath"],
            receipt_rel=artifact_paths["receiptPath"],
            trace_meta_rel=artifact_paths["traceMetaPath"],
        )
        write_json(signature_path, updated_signature)
        load_validated_config(signature_path, FRAGILITY_SIGNATURE_SCHEMA_PATH)
        manifest_cases.append(
            build_manifest_case_entry(
                case_id=case["caseId"],
                signature_id=case["signatureId"],
                scenario_stem=updated_signature["scenarioStem"],
                route_decision=result["routeDecision"],
                expected_route_decision=case["expectedRouteDecision"],
                contract_stage=updated_signature["contractStage"],
                request_rel=artifact_paths["requestPath"],
                result_rel=artifact_paths["resultPath"],
                receipt_rel=artifact_paths["receiptPath"],
                trace_meta_rel=artifact_paths["traceMetaPath"],
                case_report_rel=artifact_paths["caseReportPath"],
                process_wall_ns=artifact_paths["processWallNs"],
                dispatch_ns=artifact_paths["dispatchNs"],
                bytes_moved=int(result["executionStats"]["bytesMoved"]),
                candidate_count=int(result["executionStats"]["candidateCount"]),
            )
        )

    for control in plan.get("syntheticControls") or []:
        request = {
            "schemaVersion": 1,
            "moduleId": "doe_numeric_stability",
            "artifactKind": "request",
            "serviceId": "matmul_logits_slice",
            "operatorFamily": control["request"]["operatorFamily"],
            "semanticOpId": control["request"]["semanticOpId"],
            "semanticStage": control["request"]["semanticStage"],
            "semanticPhase": control["request"]["semanticPhase"],
            "triggerPolicyId": control["request"]["triggerPolicyId"],
            "routingPolicyId": control["routingPolicyId"],
            "fastPolicyId": control["request"]["fastPolicyId"],
            "stablePolicyId": control["request"]["stablePolicyId"],
            "hiddenState": control["request"]["hiddenState"],
            "candidates": control["request"]["candidates"],
        }
        result, artifact_paths = exercise_request(
            module_runner_path=module_runner_path,
            policy_path=policy_path,
            request=request,
            case_dir=run_dir / control["caseId"],
            repeat_count=int(plan["repeatCount"]),
        )
        if result["routeDecision"] != control["expectedRouteDecision"]:
            raise RuntimeError(
                f"{control['caseId']} expected {control['expectedRouteDecision']} but got {result['routeDecision']}"
            )
        signature_path = signature_root / sanitize_signature_file_name(control["signatureId"])
        signature = build_synthetic_signature(
            control,
            result=result,
            request_rel=artifact_paths["requestPath"],
            result_rel=artifact_paths["resultPath"],
            receipt_rel=artifact_paths["receiptPath"],
            trace_meta_rel=artifact_paths["traceMetaPath"],
            case_report_rel=artifact_paths["caseReportPath"],
            route_taxonomy_version=catalog["routeTaxonomyVersion"],
        )
        write_json(signature_path, signature)
        load_validated_config(signature_path, FRAGILITY_SIGNATURE_SCHEMA_PATH)
        manifest_cases.append(
            build_manifest_case_entry(
                case_id=control["caseId"],
                signature_id=control["signatureId"],
                scenario_stem=control["scenarioStem"],
                route_decision=result["routeDecision"],
                expected_route_decision=control["expectedRouteDecision"],
                contract_stage="runtime-exercised",
                request_rel=artifact_paths["requestPath"],
                result_rel=artifact_paths["resultPath"],
                receipt_rel=artifact_paths["receiptPath"],
                trace_meta_rel=artifact_paths["traceMetaPath"],
                case_report_rel=artifact_paths["caseReportPath"],
                process_wall_ns=artifact_paths["processWallNs"],
                dispatch_ns=artifact_paths["dispatchNs"],
                bytes_moved=int(result["executionStats"]["bytesMoved"]),
                candidate_count=int(result["executionStats"]["candidateCount"]),
            )
        )

    updated_catalog = rebuild_catalog(signature_root, catalog)
    write_json(catalog_path, updated_catalog)
    load_validated_config(catalog_path, PROMOTED_CATALOG_SCHEMA_PATH)

    counts_by_route: dict[str, int] = {}
    counts_by_stage: dict[str, int] = {}
    max_bytes_moved = 0
    max_candidate_count = 0
    for case in manifest_cases:
        counts_by_route[case["routeDecision"]] = counts_by_route.get(case["routeDecision"], 0) + 1
        counts_by_stage[case["contractStage"]] = counts_by_stage.get(case["contractStage"], 0) + 1
        max_bytes_moved = max(max_bytes_moved, int(case["bytesMoved"]))
        max_candidate_count = max(max_candidate_count, int(case["candidateCount"]))
    manifest = {
        "schemaVersion": 1,
        "artifactKind": "runtime-numeric-stability-exercise",
        "timestamp": timestamp,
        "planPath": repo_rel(plan_path),
        "policyRegistryPath": repo_rel(policy_path),
        "policyRegistryVersion": load_json(policy_path)["registryVersion"],
        "moduleRunnerPath": repo_rel(module_runner_path),
        "catalogPath": repo_rel(catalog_path),
        "cases": manifest_cases,
        "summary": {
            "caseCount": len(manifest_cases),
            "countsByRouteDecision": counts_by_route,
            "countsByContractStage": counts_by_stage,
            "maxBytesMoved": max_bytes_moved,
            "maxCandidateCount": max_candidate_count,
        },
    }
    manifest_path = run_dir / MANIFEST_FILE_NAME
    write_json(manifest_path, manifest)
    print(manifest_path)


if __name__ == "__main__":
    main()
