#!/usr/bin/env python3
"""Build browser execution receipts from browser smoke evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
LOWERING_PATHS = {
    "dawn": ["wgsl", "tint", "dawn-native"],
    "doe": ["wgsl", "doe-wgsl", "tsir", "hostplan", "webgpu"],
}
REQUIRED_PROFILE_FIELDS = ("vendor", "api", "driver", "deviceFamily")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--smoke-report", required=True)
    parser.add_argument("--mode", choices=("dawn", "doe"), required=True)
    parser.add_argument("--receipt-id", required=True)
    parser.add_argument("--workload-id", required=True)
    parser.add_argument("--source-language", default="wgsl")
    parser.add_argument("--source-entry-point", default="main")
    parser.add_argument("--source-shader", required=True)
    parser.add_argument("--source-shader-sha256", default="")
    parser.add_argument("--command-count", type=int, required=True)
    parser.add_argument("--success-count", type=int, default=None)
    parser.add_argument("--dispatch-count", type=int, default=0)
    output = parser.add_mutually_exclusive_group(required=True)
    output.add_argument("--output-hash")
    output.add_argument("--frame-hash")
    parser.add_argument("--setup-ns", type=int, required=True)
    parser.add_argument("--encode-ns", type=int, required=True)
    parser.add_argument("--submit-wait-ns", type=int, required=True)
    parser.add_argument("--out", required=True)
    return parser.parse_args()


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def repo_relative(path: Path) -> str:
    resolved = path.resolve()
    try:
        return str(resolved.relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def require_hash(hash_text: str, label: str) -> None:
    if not isinstance(hash_text, str) or len(hash_text) != 64:
        raise ValueError(f"{label} must be a 64-character sha256")
    if any(char not in "0123456789abcdef" for char in hash_text):
        raise ValueError(f"{label} must be lowercase hex")


def source_shader_payload(
    *,
    language: str,
    entry_point: str,
    source: str | None,
    source_hash: str | None,
) -> dict[str, str]:
    if not isinstance(source, str) or not source:
        raise ValueError("source shader source text is required")
    computed_hash = sha256_text(source)
    if source_hash:
        require_hash(source_hash, "source shader sha256")
        if source_hash != computed_hash:
            raise ValueError("source shader sha256 must match source shader text")
    return {
        "language": language,
        "entryPoint": entry_point,
        "source": source,
        "sha256": computed_hash,
    }


def find_mode_result(report: dict[str, Any], mode: str) -> dict[str, Any]:
    rows = report.get("modeResults")
    if not isinstance(rows, list):
        raise ValueError("smoke report modeResults must be an array")
    for row in rows:
        if isinstance(row, dict) and row.get("mode") == mode:
            return row
    raise ValueError(f"smoke report does not contain mode result: {mode}")


def runtime_selector_state(mode_result: dict[str, Any], mode: str) -> dict[str, Any]:
    selection = mode_result.get("runtimeSelection")
    if not isinstance(selection, dict):
        raise ValueError("mode result runtimeSelection must be an object")
    selected_runtime = selection.get("selectedRuntime")
    if selected_runtime != mode:
        raise ValueError("runtimeSelection.selectedRuntime must match requested mode")
    if selection.get("fallbackApplied") is not False:
        raise ValueError("runtimeSelection.fallbackApplied must be false")
    if selection.get("hiddenFallbackAllowed") is not False:
        raise ValueError("runtimeSelection.hiddenFallbackAllowed must be false")
    fallback_reason = selection.get("fallbackReasonCode", "")
    if fallback_reason != "":
        raise ValueError("runtimeSelection.fallbackReasonCode must be empty")
    selector_version = selection.get("selectorVersion")
    if not isinstance(selector_version, str) or not selector_version:
        raise ValueError("runtimeSelection.selectorVersion is required")
    return {
        "selectionMode": selection.get("selectionMode", mode),
        "selectedRuntime": selected_runtime,
        "forcedMode": selection.get("forcedMode", mode),
        "fallbackApplied": False,
        "hiddenFallbackAllowed": False,
        "fallbackReasonCode": "",
        "selectorVersion": selector_version,
    }


def driver_identity(mode_result: dict[str, Any]) -> dict[str, Any]:
    profile = mode_result.get("runtimeSelection", {}).get("profile", {})
    if not isinstance(profile, dict):
        raise ValueError("mode result runtimeSelection.profile must be an object")
    identity: dict[str, str] = {}
    for field in REQUIRED_PROFILE_FIELDS:
        value = profile.get(field)
        if not isinstance(value, str) or not value or value == "unknown":
            raise ValueError(f"mode result runtimeSelection.profile.{field} must be concrete")
        identity[field] = value
    profile_id = profile.get("profileId")
    if isinstance(profile_id, str) and profile_id:
        identity["profileId"] = profile_id
    return identity


def require_adapter_info_sha(adapter_identity: dict[str, Any]) -> str:
    value = adapter_identity.get("adapterInfoSha256")
    if (
        not isinstance(value, str)
        or len(value) != 64
        or any(char not in "0123456789abcdef" for char in value)
    ):
        raise ValueError("mode result adapterIdentity.adapterInfoSha256 must be lowercase SHA-256")
    return value


def require_feature_count(adapter_identity: dict[str, Any]) -> int:
    value = adapter_identity.get("featureCount")
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise ValueError("mode result adapterIdentity.featureCount must be non-negative integer")
    return value


def require_adapter_label(adapter_identity: dict[str, Any]) -> str:
    for field in ("adapter", "device", "name"):
        value = adapter_identity.get(field)
        if isinstance(value, str) and value and value != "unknown":
            return value
    raise ValueError("mode result adapterIdentity requires a concrete adapter, device, or name")


def device_identity(mode_result: dict[str, Any]) -> dict[str, Any]:
    adapter_identity = mode_result.get("adapterIdentity")
    if not isinstance(adapter_identity, dict):
        raise ValueError("mode result adapterIdentity must be an object")
    return {
        "adapterInfoSha256": require_adapter_info_sha(adapter_identity),
        "featureCount": require_feature_count(adapter_identity),
        "adapter": require_adapter_label(adapter_identity),
    }


def report_hash(report: dict[str, Any], report_path: Path) -> str:
    hash_text = report.get("reportHash")
    if isinstance(hash_text, str) and len(hash_text) == 64:
        return hash_text
    return sha256_file(report_path)


def validate_coverage(command_count: int, success_count: int, dispatch_count: int) -> None:
    if command_count < 1:
        raise ValueError("command-count must be positive")
    if success_count < 0 or success_count > command_count:
        raise ValueError("success-count must be between 0 and command-count")
    if dispatch_count < 0 or dispatch_count > command_count:
        raise ValueError("dispatch-count must be between 0 and command-count")


def build_receipt(
    *,
    smoke_report_path: Path,
    smoke_report: dict[str, Any],
    mode: str,
    receipt_id: str,
    workload_id: str,
    source_shader: dict[str, str],
    command_count: int,
    success_count: int,
    dispatch_count: int,
    output_hash: str | None,
    frame_hash: str | None,
    timing_phases: dict[str, int],
) -> dict[str, Any]:
    if mode not in LOWERING_PATHS:
        raise ValueError(f"unsupported runtime mode: {mode}")
    if not receipt_id:
        raise ValueError("receipt-id is required")
    if not workload_id:
        raise ValueError("workload-id is required")
    validate_coverage(command_count, success_count, dispatch_count)
    if output_hash is not None:
        require_hash(output_hash, "output hash")
    if frame_hash is not None:
        require_hash(frame_hash, "frame hash")
    if any(value < 0 for value in timing_phases.values()):
        raise ValueError("timing phases must be non-negative")
    mode_result = find_mode_result(smoke_report, mode)
    selector_state = runtime_selector_state(mode_result, mode)
    receipt = {
        "schemaVersion": 1,
        "artifactKind": "browser_execution_receipt",
        "receiptId": receipt_id,
        "workloadId": workload_id,
        "selectedRuntime": mode,
        "sourceShader": source_shader,
        "loweringPath": LOWERING_PATHS[mode],
        "backend": f"webgpu-{mode}",
        "driver": driver_identity(mode_result),
        "device": device_identity(mode_result),
        "commandGraph": {
            "graphSha256": report_hash(smoke_report, smoke_report_path),
            "artifactPath": repo_relative(smoke_report_path),
        },
        "commandCoverage": {
            "commandCount": command_count,
            "successCount": success_count,
            "dispatchCount": dispatch_count,
        },
        "runtimeSelectorState": selector_state,
        "fallbackState": {
            "fallbackApplied": False,
            "hiddenFallbackAllowed": False,
            "reasonCode": "",
        },
        "timing": {
            "timingClass": smoke_report.get("timingClass", "browser-operation-proxy"),
            "phases": timing_phases,
        },
    }
    if output_hash is not None:
        receipt["outputHash"] = output_hash
    else:
        receipt["frameHash"] = frame_hash
    return receipt


def main() -> int:
    args = parse_args()
    try:
        smoke_report_path = Path(args.smoke_report)
        smoke_report = load_json(smoke_report_path)
        if not isinstance(smoke_report, dict):
            raise ValueError("smoke report must be a JSON object")
        source = Path(args.source_shader).read_text(encoding="utf-8")
        source_shader = source_shader_payload(
            language=args.source_language,
            entry_point=args.source_entry_point,
            source=source,
            source_hash=args.source_shader_sha256,
        )
        success_count = args.command_count if args.success_count is None else args.success_count
        receipt = build_receipt(
            smoke_report_path=smoke_report_path,
            smoke_report=smoke_report,
            mode=args.mode,
            receipt_id=args.receipt_id,
            workload_id=args.workload_id,
            source_shader=source_shader,
            command_count=args.command_count,
            success_count=success_count,
            dispatch_count=args.dispatch_count,
            output_hash=args.output_hash,
            frame_hash=args.frame_hash,
            timing_phases={
                "setupNs": args.setup_ns,
                "encodeNs": args.encode_ns,
                "submitWaitNs": args.submit_wait_ns,
            },
        )
        out_path = Path(args.out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    except Exception as exc:
        sys.stderr.write(f"build_browser_execution_receipt: {exc}\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
