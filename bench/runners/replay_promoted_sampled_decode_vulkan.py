#!/usr/bin/env python3
"""Replay promoted sampled decode cases on the Vulkan lane."""

from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
for _path_entry in (str(REPO_ROOT), str(BENCH_ROOT)):
    if _path_entry not in sys.path:
        sys.path.insert(0, _path_entry)

from bench.lib.config_validation import load_validated_config
from bench.lib.sampled_decode_fragility import (
    COMMANDS_FILE_NAME,
    TRACE_JSONL_FILE_NAME,
    TRACE_META_FILE_NAME,
    decode_step_index as receipt_decode_step_index,
    decode_rows_by_step,
    find_runtime_bin,
    load_json,
    load_jsonl,
    meaningful_token_class,
    patch_commands_for_sampled_decode,
    repo_rel,
    semantic_scenario_bucket,
    write_json,
)


DEFAULT_CATALOG_PATH = REPO_ROOT / "config" / "numeric-stability-decode-promoted-catalog.json"
DEFAULT_PLAN_PATH = REPO_ROOT / "config" / "numeric-stability-decode-vulkan-replay-plan.json"
DEFAULT_OUTPUT_ROOT = REPO_ROOT / "bench" / "out" / "amd-vulkan-sampled-decode-replay"
REPORT_FILE_NAME = "numeric_stability_decode_vulkan_replay.report.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", default=str(DEFAULT_CATALOG_PATH), help="Promoted decode catalog.")
    parser.add_argument("--plan", default=str(DEFAULT_PLAN_PATH), help="Vulkan replay plan JSON.")
    parser.add_argument("--runtime-bin", default=None, help="Explicit doe-zig-runtime path.")
    parser.add_argument("--timestamp", default=None, help="UTC timestamp label.")
    parser.add_argument("--output-root", default=str(DEFAULT_OUTPUT_ROOT), help="Output root.")
    return parser.parse_args()


def timestamp_label() -> str:
    import datetime as dt

    return dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def run_runtime(
    *,
    runtime_bin: Path,
    commands_path: Path,
    kernel_root: Path,
    trace_meta_path: Path,
    trace_jsonl_path: Path,
    policy_path: Path,
    execution_profile_id: str,
    backend: dict[str, Any],
) -> int:
    start_ns = time.perf_counter_ns()
    result = subprocess.run(
        [
            str(runtime_bin),
            "--commands",
            str(commands_path),
            "--trace-meta",
            str(trace_meta_path),
            "--trace-jsonl",
            str(trace_jsonl_path),
            "--numeric-stability-policy",
            str(policy_path),
            "--numeric-stability-execution-profile",
            execution_profile_id,
            "--kernel-root",
            str(kernel_root),
            "--backend",
            "native",
            "--execute",
            "--vendor",
            str(backend["vendor"]),
            "--api",
            str(backend["api"]),
            "--family",
            str(backend["family"]),
            "--driver",
            str(backend["driver"]),
            "--backend-lane",
            str(backend["backendLane"]),
        ],
        cwd=REPO_ROOT,
        check=False,
        text=True,
        capture_output=True,
    )
    elapsed_ns = time.perf_counter_ns() - start_ns
    if result.returncode != 0:
        raise RuntimeError(
            f"doe-zig-runtime failed ({result.returncode})\nstdout:\n{result.stdout}\n\nstderr:\n{result.stderr}"
        )
    return elapsed_ns


def receipt_path_from_trace_meta(trace_meta_path: Path) -> Path:
    return trace_meta_path.with_name(trace_meta_path.name + ".numeric-stability.jsonl")


def find_replayed_receipt(receipts: list[dict[str, Any]], decode_step: int) -> dict[str, Any]:
    for receipt in decode_rows_by_step(receipts):
        if decode_step == receipt_decode_step_index(receipt):
            return receipt
    raise KeyError(f"decode.sample_token step {decode_step} not found in replay receipts")


def replay_entry(
    *,
    runtime_bin: Path,
    plan: dict[str, Any],
    signature_path: Path,
    signature: dict[str, Any],
    output_dir: Path,
) -> dict[str, Any]:
    commands = load_json(REPO_ROOT / signature["commandsPath"])
    patched_commands = patch_commands_for_sampled_decode(
        commands,
        semantic_stage=signature["caseId"].split("::step-", 1)[0],
        sample_config=signature["sampleConfig"],
        max_sample_steps=signature.get("maxSampleStepsToCapture"),
    )
    case_dir = output_dir / signature["signatureId"]
    case_dir.mkdir(parents=True, exist_ok=True)
    commands_path = case_dir / COMMANDS_FILE_NAME
    write_json(commands_path, patched_commands)
    trace_meta_path = case_dir / TRACE_META_FILE_NAME
    trace_jsonl_path = case_dir / TRACE_JSONL_FILE_NAME
    policy_path = REPO_ROOT / plan["policyPath"]
    kernel_root = REPO_ROOT / signature["kernelRoot"]
    result: dict[str, Any] = {
        "signatureId": signature["signatureId"],
        "signaturePath": repo_rel(signature_path),
        "commandsPath": repo_rel(commands_path),
        "backend": plan["backend"],
    }
    try:
        elapsed_ns = run_runtime(
            runtime_bin=runtime_bin,
            commands_path=commands_path,
            kernel_root=kernel_root,
            trace_meta_path=trace_meta_path,
            trace_jsonl_path=trace_jsonl_path,
            policy_path=policy_path,
            execution_profile_id=plan["executionProfileId"],
            backend=plan["backend"],
        )
        replay_receipts = load_jsonl(receipt_path_from_trace_meta(trace_meta_path))
        replayed = find_replayed_receipt(replay_receipts, int(signature["decodeStepIndex"]))
        selected_token_text = {
            "fast": signature["selectedTokens"]["fastText"],
            "stable": signature["selectedTokens"]["stableText"],
            "reference": signature["selectedTokens"]["referenceText"],
        }
        replay_bucket = semantic_scenario_bucket(selected_token_text, signature["semanticPriorityClass"])
        replay_meaningful = meaningful_token_class(selected_token_text, signature["semanticPriorityClass"])
        result.update(
            {
                "status": "success",
                "elapsedNs": elapsed_ns,
                "replayedReceiptPath": repo_rel(receipt_path_from_trace_meta(trace_meta_path)),
                "sameRouteDecision": replayed["route"]["decision"] == signature["routeDecision"],
                "sameSemanticScenarioBucket": replay_bucket == signature["semanticScenarioBucket"],
                "sameMeaningfulTokenClass": replay_meaningful == signature["meaningfulTokenClass"],
                "replayedRouteDecision": replayed["route"]["decision"],
            }
        )
    except Exception as exc:  # noqa: BLE001
        result.update({"status": "unsupported", "error": str(exc)})
    return result


def main() -> None:
    args = parse_args()
    catalog = load_json(Path(args.catalog))
    plan = load_validated_config(Path(args.plan))
    runtime_bin = find_runtime_bin(args.runtime_bin)
    timestamp = args.timestamp or timestamp_label()
    output_dir = Path(args.output_root) / timestamp
    output_dir.mkdir(parents=True, exist_ok=True)
    results: list[dict[str, Any]] = []
    for entry in catalog["entries"]:
        signature_path = REPO_ROOT / entry["signaturePath"]
        signature = load_json(signature_path)
        results.append(
            replay_entry(
                runtime_bin=runtime_bin,
                plan=plan,
                signature_path=signature_path,
                signature=signature,
                output_dir=output_dir,
            )
        )
    report = {
        "schemaVersion": 1,
        "artifactKind": "numeric-stability-decode-vulkan-replay-report",
        "timestamp": timestamp,
        "catalogPath": repo_rel(Path(args.catalog)),
        "planPath": repo_rel(Path(args.plan)),
        "results": results,
        "summary": {
            "caseCount": len(results),
            "successCount": sum(1 for item in results if item["status"] == "success"),
            "unsupportedCount": sum(1 for item in results if item["status"] == "unsupported"),
        },
    }
    report_path = output_dir / REPORT_FILE_NAME
    write_json(report_path, report)
    print(str(report_path))


if __name__ == "__main__":
    main()
