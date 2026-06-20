#!/usr/bin/env python3
"""Run a repeated-byte determinism probe against Doe and Dawn on one command stream."""

from __future__ import annotations

import argparse
import collections
import copy
import datetime as dt
import hashlib
import json
import os
import struct
import subprocess
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bench.lib.bench_utils import load_json

DEFAULT_FIXTURE = REPO_ROOT / "bench" / "fixtures" / "determinism" / "apple-metal-gemma3-270m-decode1tok.json"
DEFAULT_OUTPUT_ROOT = REPO_ROOT / "bench" / "out" / "apple-metal-determinism"
RUNTIME_BIN = REPO_ROOT / "runtime" / "zig" / "zig-out" / "bin" / "doe-zig-runtime"
DAWN_LIB_DIR = REPO_ROOT / "bench" / "vendor" / "dawn" / "out" / "Release"
WEBKIT_SHIM_DIR = REPO_ROOT / "bench" / "vendor" / "webkit-webgpu" / "out" / "shim"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", default=str(DEFAULT_FIXTURE), help="Determinism probe fixture JSON.")
    parser.add_argument("--runs", type=int, default=None, help="Override repeat count from the fixture.")
    parser.add_argument(
        "--mode",
        choices=["receipt", "stable-token", "stable-decode-step"],
        default=None,
        help="Override the fixture determinism mode.",
    )
    parser.add_argument("--timestamp", default=None, help="UTC timestamp label (default: current UTC time).")
    parser.add_argument("--output-root", default=str(DEFAULT_OUTPUT_ROOT), help="Output root for probe artifacts.")
    parser.add_argument("--build", action="store_true", help="Build doe-zig-runtime before running the probe.")
    return parser.parse_args()


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def sha256_path(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def resolve_repo_path(raw: str) -> Path:
    path = Path(raw)
    if path.is_absolute():
        return path
    return REPO_ROOT / path


def timestamp_label(raw: str | None) -> str:
    if raw:
        return raw
    return dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def ensure_fixture_shape(fixture: dict[str, Any]) -> None:
    required = [
        "scenarioId",
        "commandsPath",
        "kernelRoot",
        "profile",
        "backendLanes",
        "captures",
        "defaultRunCount",
    ]
    missing = [field for field in required if field not in fixture]
    if missing:
        raise ValueError(f"fixture missing required fields: {', '.join(missing)}")
    if not fixture["backendLanes"]:
        raise ValueError("fixture must define at least one backend lane")
    if not fixture.get("captures") and not fixture.get("determinismMode"):
        raise ValueError("fixture must define at least one capture point or determinismMode")


def annotate_commands(
    commands: list[dict[str, Any]],
    captures: list[dict[str, Any]],
    *,
    execution_plan_hash: str,
) -> list[dict[str, Any]]:
    annotated = copy.deepcopy(commands)
    for capture in captures:
        index = capture["commandIndex"]
        command = annotated[index]
        command["semanticOpId"] = capture["semanticOpId"]
        command["semanticStage"] = capture["semanticStage"]
        command["semanticPhase"] = capture["semanticPhase"]
        command["semanticExecutionPlanHash"] = execution_plan_hash
        if "semanticTokenIndex" in capture:
            command["semanticTokenIndex"] = capture["semanticTokenIndex"]
        if "semanticLayerIndex" in capture:
            command["semanticLayerIndex"] = capture["semanticLayerIndex"]
        command["captureBufferHandle"] = capture["captureBufferHandle"]
        command["captureOffset"] = capture.get("captureOffset", 0)
        command["captureSize"] = capture["captureSize"]
        if "decode" in capture:
            command["decode"] = capture["decode"]
    return annotated


def _command_kind(command: dict[str, Any]) -> str:
    return str(command.get("kind") or command.get("command") or command.get("command_kind") or "")


def _command_kernel(command: dict[str, Any]) -> str:
    return str(command.get("kernel") or command.get("kernel_name") or "")


def _command_bindings(command: dict[str, Any]) -> list[dict[str, Any]]:
    bindings = command.get("bindings")
    return bindings if isinstance(bindings, list) else []


def _binding_int(binding: dict[str, Any], *names: str) -> int | None:
    for name in names:
        value = binding.get(name)
        if isinstance(value, int):
            return value
    return None


def _binding_text(binding: dict[str, Any], *names: str) -> str | None:
    for name in names:
        value = binding.get(name)
        if isinstance(value, str):
            return value
    return None


def _find_binding(command: dict[str, Any], binding_index: int) -> dict[str, Any] | None:
    for binding in _command_bindings(command):
        if _binding_int(binding, "binding") == binding_index:
            return binding
    return None


def _find_latest_writer(commands: list[dict[str, Any]], *, before_index: int, handle: int) -> int | None:
    for index in range(before_index - 1, -1, -1):
        command = commands[index]
        if _command_kind(command) == "buffer_write":
            if _binding_int(command, "handle") == handle:
                return index
        for binding in _command_bindings(command):
            if _binding_int(binding, "resourceHandle", "resource_handle", "handle") != handle:
                continue
            if (_binding_text(binding, "bufferType", "buffer_type") or "").lower() == "storage":
                return index
    return None


def _capture_id(base: str, token_index: int, total_steps: int) -> str:
    if total_steps <= 1:
        return base
    return f"{base}.t{token_index:03d}"


def infer_captures_for_mode(
    commands: list[dict[str, Any]],
    *,
    determinism_mode: str,
    semantic_stage: str | None = None,
) -> list[dict[str, Any]]:
    stage = semantic_stage or determinism_mode.replace("-", "_")
    sample_indices = [index for index, command in enumerate(commands) if _command_kernel(command).endswith("sample.wgsl")]
    if not sample_indices:
        raise ValueError(f"determinism mode {determinism_mode} requires at least one sample.wgsl command")

    captures: list[dict[str, Any]] = []
    total_steps = len(sample_indices)
    for token_index, sample_index in enumerate(sample_indices):
        sample_command = commands[sample_index]
        logits_binding = _find_binding(sample_command, 1)
        token_binding = _find_binding(sample_command, 2)
        if logits_binding is None or token_binding is None:
            raise ValueError(
                f"determinism mode {determinism_mode} requires sample.wgsl bindings 1(readonly logits) and 2(storage token) "
                f"at command index {sample_index}"
            )
        token_handle = _binding_int(token_binding, "resourceHandle", "resource_handle", "handle")
        token_size = _binding_int(token_binding, "bufferSize", "buffer_size")
        if token_handle is None or token_size is None:
            raise ValueError(f"sample.wgsl token binding is missing handle/size at command index {sample_index}")
        if determinism_mode == "stable-decode-step":
            logits_handle = _binding_int(logits_binding, "resourceHandle", "resource_handle", "handle")
            logits_size = _binding_int(logits_binding, "bufferSize", "buffer_size")
            if logits_handle is None or logits_size is None:
                raise ValueError(f"sample.wgsl logits binding is missing handle/size at command index {sample_index}")
            producer_index = _find_latest_writer(commands, before_index=sample_index, handle=logits_handle)
            if producer_index is None:
                raise ValueError(
                    f"stable-decode-step could not find a producer for sample logits handle {logits_handle} "
                    f"before command index {sample_index}"
                )
            captures.append(
                {
                    "commandIndex": producer_index,
                    "semanticOpId": _capture_id("decode.final_logits", token_index, total_steps),
                    "semanticStage": stage,
                    "semanticPhase": "final_logits",
                    "semanticTokenIndex": token_index,
                    "captureBufferHandle": logits_handle,
                    "captureOffset": 0,
                    "captureSize": logits_size,
                }
            )
            token_op_id = _capture_id("decode.sample_token", token_index, total_steps)
            token_phase = "sample_token"
        else:
            token_op_id = _capture_id("sample.output_token", token_index, total_steps)
            token_phase = "output_token"
        captures.append(
            {
                "commandIndex": sample_index,
                "semanticOpId": token_op_id,
                "semanticStage": stage,
                "semanticPhase": token_phase,
                "semanticTokenIndex": token_index,
                "captureBufferHandle": token_handle,
                "captureOffset": 0,
                "captureSize": token_size,
                "decode": "u32le",
            }
        )
    return captures


def resolve_captures(
    fixture: dict[str, Any],
    commands: list[dict[str, Any]],
    *,
    mode_override: str | None,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    resolved_mode = mode_override or fixture.get("determinismMode")
    if resolved_mode:
        captures = infer_captures_for_mode(
            commands,
            determinism_mode=resolved_mode,
            semantic_stage=fixture.get("semanticStage"),
        )
        return captures, {
            "kind": "inferred",
            "determinismMode": resolved_mode,
            "semanticStage": fixture.get("semanticStage") or resolved_mode.replace("-", "_"),
            "captureCount": len(captures),
        }
    captures = fixture.get("captures") or []
    return captures, {
        "kind": "explicit",
        "determinismMode": "explicit-captures",
        "captureCount": len(captures),
    }


def build_runtime() -> None:
    subprocess.run(
        ["zig", "build", "doe-zig-runtime"],
        cwd=REPO_ROOT / "runtime" / "zig",
        check=True,
        capture_output=True,
        text=True,
    )


WEBKIT_RUNTIME_STATE = REPO_ROOT / "bench" / "fixtures" / "webkit_webgpu_runtime_state.json"


def _webkit_framework_dir() -> str | None:
    """Resolve the DerivedData products dir for the WebKit WebGPU build."""
    if not WEBKIT_RUNTIME_STATE.is_file():
        return None
    state = json.loads(WEBKIT_RUNTIME_STATE.read_text())
    dd = state.get("derivedData", "")
    if dd:
        return str(Path(dd) / "Build" / "Products" / state.get("configuration", "Release"))
    return None


def runtime_env(backend_lane: str = "") -> dict[str, str]:
    env = os.environ.copy()
    existing = env.get("DYLD_LIBRARY_PATH", "")
    if backend_lane.startswith("metal_webkit_"):
        lib_dir = str(WEBKIT_SHIM_DIR)
        fw_dir = _webkit_framework_dir()
        if fw_dir:
            existing_fw = env.get("DYLD_FRAMEWORK_PATH", "")
            env["DYLD_FRAMEWORK_PATH"] = fw_dir if not existing_fw else f"{fw_dir}:{existing_fw}"
    else:
        lib_dir = str(DAWN_LIB_DIR)
    env["DYLD_LIBRARY_PATH"] = lib_dir if not existing else f"{lib_dir}:{existing}"
    return env


def lane_command(
    *,
    commands_path: Path,
    trace_meta_path: Path,
    trace_jsonl_path: Path,
    profile: dict[str, Any],
    kernel_root: Path,
    backend_lane: str,
    queue_wait_mode: str,
    queue_sync_mode: str,
) -> list[str]:
    return [
        str(RUNTIME_BIN),
        "--commands",
        str(commands_path),
        "--quirk-mode",
        "trace",
        "--vendor",
        profile["vendor"],
        "--api",
        profile["api"],
        "--family",
        profile["family"],
        "--driver",
        profile["driver"],
        "--backend",
        "native",
        "--backend-lane",
        backend_lane,
        "--execute",
        "--trace",
        "--trace-jsonl",
        str(trace_jsonl_path),
        "--trace-meta",
        str(trace_meta_path),
        "--kernel-root",
        str(kernel_root),
        "--queue-wait-mode",
        queue_wait_mode,
        "--queue-sync-mode",
        queue_sync_mode,
        "--gpu-timestamp-mode",
        "off",
    ]


def resolve_artifact_path(raw: str) -> Path:
    path = Path(raw)
    if path.is_absolute():
        return path
    return REPO_ROOT / path


def decode_capture_value(path: Path, decode_kind: str | None) -> int | None:
    if decode_kind != "u32le":
        return None
    payload = path.read_bytes()
    if len(payload) != 4:
        raise ValueError(f"expected 4-byte payload for u32le decode, got {len(payload)} bytes from {path}")
    return struct.unpack("<I", payload)[0]


def decode_capture_f32le(path: Path) -> list[float]:
    payload = path.read_bytes()
    if len(payload) % 4 != 0:
        raise ValueError(f"expected 4-byte aligned payload for f32le decode, got {len(payload)} bytes from {path}")
    if not payload:
        return []
    return list(struct.unpack("<" + "f" * (len(payload) // 4), payload))


def audit_greedy_tie_break(logits_path: Path, sampled_token: int | None) -> dict[str, Any]:
    logits = decode_capture_f32le(logits_path)
    if not logits:
        raise ValueError(f"cannot audit greedy tie break from empty logits payload: {logits_path}")
    max_value = max(logits)
    max_indices = [index for index, value in enumerate(logits) if value == max_value]
    expected_index = min(max_indices)
    return {
        "available": sampled_token is not None,
        "logitCount": len(logits),
        "maxValue": max_value,
        "exactMaxTieCount": len(max_indices),
        "expectedGreedyToken": expected_index,
        "actualSampledToken": sampled_token,
        "matchesExpectedGreedyToken": sampled_token == expected_index if sampled_token is not None else None,
    }


def _base_sample_id(semantic_op_id: str) -> str:
    if ".t" in semantic_op_id:
        prefix, suffix = semantic_op_id.rsplit(".t", 1)
        if suffix.isdigit():
            return prefix
    return semantic_op_id


def build_tie_break_audit(
    lane_summaries: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    audits: dict[str, Any] = {}
    for lane_id, lane_summary in lane_summaries.items():
        lane_ops = lane_summary["operators"]
        lane_audit: dict[str, Any] = {}
        for op_id, op_summary in lane_ops.items():
            if _base_sample_id(op_id) != "decode.final_logits":
                continue
            paired_token_id = op_id.replace("decode.final_logits", "decode.sample_token")
            token_summary = lane_ops.get(paired_token_id)
            if token_summary is None:
                continue
            logits_artifact = op_summary["artifacts"][0]["capturePath"]
            sampled_token = token_summary.get("dominantDecodedValue")
            lane_audit[op_id] = audit_greedy_tie_break(
                Path(logits_artifact),
                sampled_token,
            )
        audits[lane_id] = lane_audit
    cross_lane: dict[str, Any] = {}
    lane_ids = list(lane_summaries.keys())
    if len(lane_ids) >= 2:
        shared_op_ids = set.intersection(
            *(set(audits[lane_id].keys()) for lane_id in lane_ids if audits[lane_id]),
        ) if any(audits.values()) else set()
        for op_id in sorted(shared_op_ids):
            expected = {lane_id: audits[lane_id][op_id]["expectedGreedyToken"] for lane_id in lane_ids}
            actual = {lane_id: audits[lane_id][op_id]["actualSampledToken"] for lane_id in lane_ids}
            cross_lane[op_id] = {
                "expectedGreedyTokenByLane": expected,
                "actualSampledTokenByLane": actual,
                "sameExpectedGreedyTokenAcrossLanes": len(set(expected.values())) == 1,
                "sameActualSampledTokenAcrossLanes": len(set(actual.values())) == 1,
                "allLanesMatchExpectedGreedyToken": all(
                    audits[lane_id][op_id]["matchesExpectedGreedyToken"] for lane_id in lane_ids
                ),
            }
    return {"lanes": audits, "crossLane": cross_lane}


def capture_rows_by_op(manifest: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    rows: dict[str, dict[str, Any]] = {}
    for row in manifest:
        semantic_op_id = row.get("semanticOpId")
        if semantic_op_id:
            rows[semantic_op_id] = row
    return rows


def summarize_lane_runs(
    runs: list[dict[str, Any]],
    captures: list[dict[str, Any]],
) -> dict[str, Any]:
    operators: dict[str, Any] = {}
    for capture in captures:
        op_id = capture["semanticOpId"]
        digests: list[str] = []
        statuses: list[str] = []
        decoded_values: list[int] = []
        artifact_rows: list[dict[str, Any]] = []
        for run in runs:
            row = run["operatorRows"][op_id]
            artifact_rows.append(
                {
                    "runIndex": run["runIndex"],
                    "capturePath": row["capture"]["path"],
                    "captureSha256": row["capture"]["sha256"],
                }
            )
            capture_info = row["capture"]
            statuses.append(capture_info["status"])
            digests.append(capture_info["sha256"])
            decoded = decode_capture_value(resolve_artifact_path(capture_info["path"]), capture.get("decode"))
            if decoded is not None:
                decoded_values.append(decoded)
        digest_counts = collections.Counter(digests)
        dominant_digest, dominant_count = digest_counts.most_common(1)[0]
        operator_summary: dict[str, Any] = {
            "stableAcrossRuns": len(digest_counts) == 1 and all(status == "ok" for status in statuses),
            "runCount": len(runs),
            "captureSize": capture["captureSize"],
            "statusCounts": dict(collections.Counter(statuses)),
            "uniqueDigestCount": len(digest_counts),
            "sameByteRate": dominant_count / len(runs),
            "dominantDigest": dominant_digest,
            "digestCounts": dict(digest_counts),
            "artifacts": artifact_rows,
            "firstDivergenceRunIndex": next(
                (run["runIndex"] for run, digest in zip(runs, digests) if digest != dominant_digest),
                None,
            ),
        }
        if decoded_values:
            decoded_counts = collections.Counter(decoded_values)
            dominant_value, dominant_value_count = decoded_counts.most_common(1)[0]
            operator_summary["decodedValueCounts"] = dict(decoded_counts)
            operator_summary["dominantDecodedValue"] = dominant_value
            operator_summary["decodedValueStableAcrossRuns"] = len(decoded_counts) == 1
            operator_summary["decodedValueRate"] = dominant_value_count / len(decoded_values)
        operators[op_id] = operator_summary

    lane_stable = all(summary["stableAcrossRuns"] for summary in operators.values())
    return {
        "stableAcrossRuns": lane_stable,
        "operators": operators,
    }


def compare_lanes(lane_summaries: dict[str, dict[str, Any]], captures: list[dict[str, Any]]) -> dict[str, Any]:
    lane_ids = list(lane_summaries.keys())
    operators: dict[str, Any] = {}
    for capture in captures:
        op_id = capture["semanticOpId"]
        per_lane = {
            lane_id: lane_summaries[lane_id]["operators"][op_id]["dominantDigest"]
            for lane_id in lane_ids
        }
        same_across_lanes = len(set(per_lane.values())) == 1
        op_summary: dict[str, Any] = {
            "sameAcrossLanes": same_across_lanes,
            "laneDominantDigests": per_lane,
        }
        decoded_by_lane = {
            lane_id: lane_summaries[lane_id]["operators"][op_id].get("dominantDecodedValue")
            for lane_id in lane_ids
        }
        if any(value is not None for value in decoded_by_lane.values()):
            op_summary["sameDecodedValueAcrossLanes"] = len({value for value in decoded_by_lane.values() if value is not None}) == 1
            op_summary["laneDominantDecodedValues"] = decoded_by_lane
        operators[op_id] = op_summary
    return {"operators": operators}


def run_lane(
    *,
    lane_id: str,
    backend_lane: str,
    run_count: int,
    commands_path: Path,
    output_dir: Path,
    profile: dict[str, Any],
    kernel_root: Path,
    queue_wait_mode: str,
    queue_sync_mode: str,
    captures: list[dict[str, Any]],
) -> dict[str, Any]:
    lane_dir = output_dir / lane_id
    lane_dir.mkdir(parents=True, exist_ok=True)
    runs: list[dict[str, Any]] = []
    for run_index in range(run_count):
        trace_meta_path = lane_dir / f"run{run_index:03d}.meta.json"
        trace_jsonl_path = lane_dir / f"run{run_index:03d}.trace.jsonl"
        command = lane_command(
            commands_path=commands_path,
            trace_meta_path=trace_meta_path,
            trace_jsonl_path=trace_jsonl_path,
            profile=profile,
            kernel_root=kernel_root,
            backend_lane=backend_lane,
            queue_wait_mode=queue_wait_mode,
            queue_sync_mode=queue_sync_mode,
        )
        completed = subprocess.run(
            command,
            cwd=REPO_ROOT,
            env=runtime_env(backend_lane),
            capture_output=True,
            text=True,
            check=False,
        )
        if completed.returncode != 0:
            raise RuntimeError(
                f"{lane_id} run {run_index} failed with code {completed.returncode}\n"
                f"stdout:\n{completed.stdout}\n\nstderr:\n{completed.stderr}"
            )
        meta = load_json(trace_meta_path)
        manifest_path_raw = meta.get("operatorRecordManifestPath")
        if not manifest_path_raw:
            raise RuntimeError(f"{lane_id} run {run_index} did not emit operatorRecordManifestPath")
        manifest_path = resolve_artifact_path(manifest_path_raw)
        manifest = load_json(manifest_path)
        if not isinstance(manifest, list):
            raise RuntimeError(f"{lane_id} run {run_index} operator manifest must be a list: {manifest_path}")
        operator_rows = capture_rows_by_op(manifest)
        for capture in captures:
            row = operator_rows.get(capture["semanticOpId"])
            if row is None:
                raise RuntimeError(
                    f"{lane_id} run {run_index} missing semantic operator {capture['semanticOpId']} in {manifest_path}"
                )
            execution_info = row.get("execution")
            if not isinstance(execution_info, dict) or execution_info.get("status") != "ok":
                raise RuntimeError(
                    f"{lane_id} run {run_index} execution failed for {capture['semanticOpId']}: {execution_info}"
                )
            capture_info = row.get("capture")
            if not capture_info or capture_info.get("status") != "ok":
                raise RuntimeError(
                    f"{lane_id} run {run_index} capture failed for {capture['semanticOpId']}: {capture_info}"
                )
        runs.append(
            {
                "runIndex": run_index,
                "traceMetaPath": str(trace_meta_path),
                "traceJsonlPath": str(trace_jsonl_path),
                "operatorManifestPath": str(manifest_path),
                "operatorRows": operator_rows,
            }
        )

    lane_summary = summarize_lane_runs(runs, captures)
    lane_summary.update(
        {
            "id": lane_id,
            "backendLane": backend_lane,
            "runs": [
                {
                    "runIndex": run["runIndex"],
                    "traceMetaPath": run["traceMetaPath"],
                    "traceJsonlPath": run["traceJsonlPath"],
                    "operatorManifestPath": run["operatorManifestPath"],
                }
                for run in runs
            ],
        }
    )
    return lane_summary


def claim_summary(
    lanes: dict[str, dict[str, Any]],
    cross_lane: dict[str, Any],
    captures: list[dict[str, Any]],
    *,
    determinism_mode: str,
    tie_break_audit: dict[str, Any],
) -> dict[str, Any]:
    doe = lanes.get("doe")
    dawn = lanes.get("dawn")
    webkit = lanes.get("webkit")
    result = {
        "mode": determinism_mode,
        "doeReceiptAvailable": doe is not None,
        "dawnReceiptAvailable": dawn is not None,
        "webkitReceiptAvailable": webkit is not None,
        "doeStableAcrossRuns": doe["stableAcrossRuns"] if doe else None,
        "dawnStableAcrossRuns": dawn["stableAcrossRuns"] if dawn else None,
        "webkitStableAcrossRuns": webkit["stableAcrossRuns"] if webkit else None,
        "doeMoreDeterministicThanDawn": bool(doe and dawn and doe["stableAcrossRuns"] and not dawn["stableAcrossRuns"]),
        "crossLaneSameBytes": all(summary["sameAcrossLanes"] for summary in cross_lane["operators"].values()),
        "tieBreakAuditAvailable": any(bool(v) for v in tie_break_audit["lanes"].values()),
        "perOperator": {},
    }
    for capture in captures:
        op_id = capture["semanticOpId"]
        operator_claim: dict[str, Any] = {
            "doeStableAcrossRuns": doe["operators"][op_id]["stableAcrossRuns"] if doe else None,
            "dawnStableAcrossRuns": dawn["operators"][op_id]["stableAcrossRuns"] if dawn else None,
            "webkitStableAcrossRuns": webkit["operators"][op_id]["stableAcrossRuns"] if webkit else None,
            "sameAcrossLanes": cross_lane["operators"][op_id]["sameAcrossLanes"],
        }
        if doe and "dominantDecodedValue" in doe["operators"][op_id]:
            operator_claim["doeDecodedValue"] = doe["operators"][op_id]["dominantDecodedValue"]
        if dawn and "dominantDecodedValue" in dawn["operators"][op_id]:
            operator_claim["dawnDecodedValue"] = dawn["operators"][op_id]["dominantDecodedValue"]
        if webkit and "dominantDecodedValue" in webkit["operators"][op_id]:
            operator_claim["webkitDecodedValue"] = webkit["operators"][op_id]["dominantDecodedValue"]
        if "sameDecodedValueAcrossLanes" in cross_lane["operators"][op_id]:
            operator_claim["sameDecodedValueAcrossLanes"] = cross_lane["operators"][op_id]["sameDecodedValueAcrossLanes"]
        result["perOperator"][op_id] = operator_claim
    return result


def main() -> None:
    args = parse_args()
    if args.build:
        build_runtime()
    if not RUNTIME_BIN.exists():
        raise SystemExit(f"runtime binary missing: {RUNTIME_BIN}")

    fixture_path = resolve_repo_path(args.fixture)
    fixture = load_json(fixture_path)
    ensure_fixture_shape(fixture)

    base_commands_path = resolve_repo_path(fixture["commandsPath"])
    base_commands = load_json(base_commands_path)
    if not isinstance(base_commands, list):
        raise SystemExit(f"commands file must contain a list: {base_commands_path}")
    base_commands_bytes = base_commands_path.read_bytes()
    base_commands_sha256 = sha256_bytes(base_commands_bytes)
    captures, capture_plan = resolve_captures(
        fixture,
        base_commands,
        mode_override=args.mode,
    )
    if not captures:
        raise SystemExit("resolved determinism capture set is empty")

    annotated_commands = annotate_commands(
        base_commands,
        captures,
        execution_plan_hash=base_commands_sha256,
    )
    annotated_bytes = (json.dumps(annotated_commands, indent=2) + "\n").encode("utf-8")
    annotated_sha256 = sha256_bytes(annotated_bytes)

    stamp = timestamp_label(args.timestamp)
    output_dir = resolve_repo_path(args.output_root) / stamp
    output_dir.mkdir(parents=True, exist_ok=True)

    annotated_commands_path = output_dir / f"{fixture['scenarioId']}.commands.annotated.json"
    annotated_commands_path.write_bytes(annotated_bytes)
    run_count = args.runs or fixture["defaultRunCount"]
    kernel_root = resolve_repo_path(fixture["kernelRoot"])

    lane_summaries: dict[str, dict[str, Any]] = {}
    for lane in fixture["backendLanes"]:
        lane_summaries[lane["id"]] = run_lane(
            lane_id=lane["id"],
            backend_lane=lane["backendLane"],
            run_count=run_count,
            commands_path=annotated_commands_path,
            output_dir=output_dir,
            profile=fixture["profile"],
            kernel_root=kernel_root,
            queue_wait_mode=fixture.get("queueWaitMode", "process-events"),
            queue_sync_mode=fixture.get("queueSyncMode", "per-command"),
            captures=captures,
        )

    cross_lane = compare_lanes(lane_summaries, captures)
    tie_break_audit = build_tie_break_audit(lane_summaries)
    determinism_mode = capture_plan["determinismMode"]
    report = {
        "schemaVersion": 1,
        "scenarioId": fixture["scenarioId"],
        "description": fixture.get("description"),
        "fixturePath": str(fixture_path),
        "timestamp": stamp,
        "runCount": run_count,
        "profile": fixture["profile"],
        "baseCommandsPath": str(base_commands_path),
        "baseCommandsSha256": base_commands_sha256,
        "annotatedCommandsPath": str(annotated_commands_path),
        "annotatedCommandsSha256": annotated_sha256,
        "determinismMode": determinism_mode,
        "capturePlan": capture_plan,
        "captures": captures,
        "lanes": lane_summaries,
        "crossLane": cross_lane,
        "tieBreakAudit": tie_break_audit,
        "claim": claim_summary(
            lane_summaries,
            cross_lane,
            captures,
            determinism_mode=determinism_mode,
            tie_break_audit=tie_break_audit,
        ),
    }

    report_path = output_dir / f"{fixture['scenarioId']}.determinism.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(report_path)


if __name__ == "__main__":
    main()
