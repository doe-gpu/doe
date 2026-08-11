#!/usr/bin/env python3
"""Run and validate promoted browser diagnostics through lane wrappers."""

from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
for _path_entry in (str(REPO_ROOT), str(BENCH_ROOT)):
    if _path_entry not in sys.path:
        sys.path.insert(0, _path_entry)


import argparse
import hashlib
import json
import math
import re
import subprocess
import sys
from datetime import UTC, datetime
from decimal import Decimal
from pathlib import Path
from typing import Any

BENCH_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = Path(__file__).resolve().parents[2]
if str(BENCH_ROOT) not in sys.path:
    sys.path.insert(0, str(BENCH_ROOT))

from bench.lib import output_paths
from bench.lib.bench_utils import load_json
from bench.tools import check_browser_responsibility_map


def repo_root() -> Path:
    return REPO_ROOT


def default_gate_report_path(root: Path) -> Path:
    stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    return root / "bench/out/browser-promotion" / stamp / "browser_gate.json"


def default_artifact_root(root: Path) -> Path:
    stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    return root / "browser/chromium/artifacts" / stamp


def parse_args() -> argparse.Namespace:
    root = repo_root()
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=str(root))
    parser.add_argument(
        "--promotion-approvals",
        default=str(root / "browser/chromium/bench/workflows/browser-promotion-approvals.json"),
    )
    parser.add_argument(
        "--ownership",
        default=str(root / "config/browser-ownership.json"),
    )
    parser.add_argument(
        "--responsibility-map",
        default=str(root / "config/browser-responsibility-map.json"),
    )
    parser.add_argument(
        "--runtime-selector-policy",
        default=str(root / "config/browser-runtime-selector-policy.json"),
    )
    parser.add_argument(
        "--fork-maintenance-policy",
        default=str(root / "config/chromium-fork-maintenance-policy.json"),
    )
    parser.add_argument(
        "--capture-policy",
        default=str(root / "config/browser-capture-policy.json"),
    )
    parser.add_argument(
        "--artifact-root",
        default="",
        help="Optional artifact directory for smoke/layered outputs.",
    )
    parser.add_argument(
        "--report",
        default="",
        help="Optional gate report path. Defaults to bench/out/browser-promotion/<timestamp>/browser_gate.json",
    )
    parser.add_argument("--chrome", default="")
    parser.add_argument("--dawn-chrome", default="")
    parser.add_argument("--doe-chrome", default="")
    parser.add_argument("--doe-lib", default="")
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def js_number_literal(value: int | float) -> str:
    if isinstance(value, int):
        return str(value)
    if not math.isfinite(value):
        return "null"
    if value == 0:
        return "0"
    absolute = abs(value)
    if value.is_integer() and absolute < 1e21:
        return str(int(value))

    text = repr(value).lower()
    if "e" not in text:
        return text

    if 1e-6 <= absolute < 1e21:
        fixed = format(Decimal(text), "f")
        fixed = fixed.rstrip("0").rstrip(".")
        return "0" if fixed in {"", "-0"} else fixed

    mantissa, exponent = text.split("e", 1)
    if "." in mantissa:
        mantissa = mantissa.rstrip("0").rstrip(".")
    exponent_value = int(exponent)
    exponent_prefix = "+" if exponent_value >= 0 else ""
    return f"{mantissa}e{exponent_prefix}{exponent_value}"


def js_canonical_json(payload: Any) -> str:
    if payload is None:
        return "null"
    if isinstance(payload, bool):
        return "true" if payload else "false"
    if isinstance(payload, (int, float)):
        return js_number_literal(payload)
    if isinstance(payload, str):
        return json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    if isinstance(payload, list):
        return "[" + ",".join(js_canonical_json(item) for item in payload) + "]"
    if isinstance(payload, dict):
        entries = []
        for key in sorted(payload):
            entries.append(
                json.dumps(str(key), ensure_ascii=False, separators=(",", ":"))
                + ":"
                + js_canonical_json(payload[key])
            )
        return "{" + ",".join(entries) + "}"
    return json.dumps(payload, sort_keys=True, separators=(",", ":"))


def stable_hash(payload: Any) -> str:
    encoded = js_canonical_json(payload).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def resolve_dawn_chrome(root: Path, explicit: str) -> str:
    if explicit:
        return explicit
    candidate = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    if candidate.exists():
        return str(candidate)
    return ""


def run_step(label: str, command: list[str], cwd: Path) -> None:
    print(f"[browser-gate] {label}: {' '.join(command)}", flush=True)
    subprocess.run(command, cwd=cwd, check=True)


def validate_ownership(payload: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    if payload.get("schemaVersion") != 1:
        errors.append("ownership schemaVersion must be 1")
    areas = payload.get("areas")
    if not isinstance(areas, dict):
        return errors + ["ownership missing areas object"]
    required_areas = {
        "browser_runtime_integration",
        "browser_compatibility",
        "browser_performance_methodology",
    }
    for area in required_areas:
        row = areas.get(area)
        if not isinstance(row, dict):
            errors.append(f"ownership missing area: {area}")
            continue
        for key in (
            "runtimeIntegrationOwner",
            "qualityOwner",
            "benchmarkMethodologyOwner",
            "promotedAt",
        ):
            if not isinstance(row.get(key), str) or not row[key].strip():
                errors.append(f"ownership {area} missing non-empty {key}")
        if row.get("nurseryExitApproved") is not True:
            errors.append(f"ownership {area} nurseryExitApproved must be true")
    return errors


def validate_responsibility_map(path: Path, root: Path) -> list[str]:
    payload = load_json(path)
    return [
        f"responsibility-map:{item['code']}: {item['path']}: {item['message']}"
        for item in check_browser_responsibility_map.check_responsibility_map(payload, root)
    ]


def validate_cts_subset(path: Path, root: Path) -> list[str]:
    checker = root / "browser/chromium/scripts/check-browser-cts-subset.py"
    completed = subprocess.run(
        [sys.executable, str(checker), "--subset", str(path), "--json"],
        cwd=root,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    output = completed.stdout.strip()
    if output:
        try:
            payload = json.loads(output)
        except json.JSONDecodeError:
            return [f"cts-subset: checker emitted invalid JSON: {output}"]
        failures = payload.get("failures")
        if isinstance(failures, list):
            return [
                f"cts-subset:{item.get('code')}: {item.get('path')}: {item.get('message')}"
                for item in failures
                if isinstance(item, dict)
            ]
    if completed.returncode != 0:
        detail = completed.stderr.strip() or output or "check failed"
        return [f"cts-subset: {detail}"]
    return []


def validate_recovery_parity(path: Path, root: Path) -> list[str]:
    checker = root / "browser/chromium/scripts/check-browser-recovery-parity.py"
    completed = subprocess.run(
        [sys.executable, str(checker), "--parity", str(path), "--json"],
        cwd=root,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    output = completed.stdout.strip()
    if output:
        try:
            payload = json.loads(output)
        except json.JSONDecodeError:
            return [f"recovery-parity: checker emitted invalid JSON: {output}"]
        failures = payload.get("failures")
        if isinstance(failures, list):
            return [
                f"recovery-parity:{item.get('code')}: {item.get('path')}: {item.get('message')}"
                for item in failures
                if isinstance(item, dict)
            ]
    if completed.returncode != 0:
        detail = completed.stderr.strip() or output or "check failed"
        return [f"recovery-parity: {detail}"]
    return []


def validate_json_checker(
    *,
    label: str,
    root: Path,
    checker: Path,
    path_flag: str,
    artifact_path: Path,
    extra_args: list[str] | None = None,
) -> list[str]:
    command = [sys.executable, str(checker), path_flag, str(artifact_path), "--json"]
    if extra_args:
        command.extend(extra_args)
    completed = subprocess.run(
        command,
        cwd=root,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    output = completed.stdout.strip()
    if output:
        try:
            payload = json.loads(output)
        except json.JSONDecodeError:
            return [f"{label}: checker emitted invalid JSON: {output}"]
        failures = payload.get("failures")
        if isinstance(failures, list):
            return [
                f"{label}:{item.get('code')}: {item.get('path')}: {item.get('message')}"
                for item in failures
                if isinstance(item, dict)
            ]
    if completed.returncode != 0:
        detail = completed.stderr.strip() or output or "check failed"
        return [f"{label}: {detail}"]
    return []


def validate_pipeline_cache_receipts(path: Path, root: Path | None = None) -> list[str]:
    repo_root = root if root is not None else Path(__file__).resolve().parents[2]
    return validate_json_checker(
        label="pipeline-cache-receipts",
        root=repo_root,
        checker=repo_root / "browser/chromium/scripts/check-browser-pipeline-cache-receipts.py",
        path_flag="--receipts",
        artifact_path=path,
        extra_args=[
            "--verify-workloads-root",
            str(repo_root),
            "--runtime-identity-root",
            str(repo_root),
        ],
    )


def validate_flight_recorder_replay(
    *,
    root: Path,
    flight_recorder_path: Path,
    replay_report_path: Path,
    capture_policy_path: Path,
) -> list[str]:
    checker = root / "browser/chromium/scripts/replay-browser-gpu-flight-recorder.py"
    completed = subprocess.run(
        [
            sys.executable,
            str(checker),
            "--flight-recorder",
            str(flight_recorder_path),
            "--out",
            str(replay_report_path),
            "--capture-policy",
            str(capture_policy_path),
            "--responsibility-map-root",
            str(root),
            "--json",
        ],
        cwd=root,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    output = completed.stdout.strip()
    if output:
        try:
            payload = json.loads(output)
        except json.JSONDecodeError:
            return [f"flight-recorder-replay: checker emitted invalid JSON: {output}"]
        failures = payload.get("failureCodes")
        if isinstance(failures, list):
            return [
                f"flight-recorder-replay:{item.get('code')}: {item.get('path')}: {item.get('message')}"
                for item in failures
                if isinstance(item, dict) and item.get("severity") in {"error", "fatal"}
            ]
    if completed.returncode != 0:
        detail = completed.stderr.strip() or output or "check failed"
        return [f"flight-recorder-replay: {detail}"]
    return []


def validate_runtime_selection(payload: Any, mode: str, label: str) -> list[str]:
    errors: list[str] = []
    if not isinstance(payload, dict):
        return [f"{label} runtimeSelection must be object"]
    if payload.get("selectionMode") != mode:
        errors.append(f"{label} selectionMode must be {mode}")
    if payload.get("selectedRuntime") != mode:
        errors.append(f"{label} selectedRuntime must be {mode}")
    if payload.get("forcedMode") != mode:
        errors.append(f"{label} forcedMode must be {mode}")
    if payload.get("fallbackApplied") is not False:
        errors.append(f"{label} fallbackApplied must be false")
    if payload.get("fallbackReasonCode") != "":
        errors.append(f"{label} fallbackReasonCode must be empty")
    if payload.get("hiddenFallbackAllowed") is not False:
        errors.append(f"{label} hiddenFallbackAllowed must be false")
    profile = payload.get("profile")
    if not isinstance(profile, dict):
        errors.append(f"{label} profile must be object")
    else:
        for field in ("vendor", "api", "deviceFamily", "driver"):
            if not isinstance(profile.get(field), str) or not profile[field].strip():
                errors.append(f"{label} profile.{field} must be non-empty")
    adapter_denylist = payload.get("adapterDenylist")
    if adapter_denylist is not None:
        if not isinstance(adapter_denylist, dict):
            errors.append(f"{label} adapterDenylist must be object")
        else:
            if not isinstance(adapter_denylist.get("matched"), bool):
                errors.append(f"{label} adapterDenylist.matched must be bool")
            for field in ("reasonCode", "profileId", "vendor", "api", "deviceFamily", "driverPattern"):
                if not isinstance(adapter_denylist.get(field), str):
                    errors.append(f"{label} adapterDenylist.{field} must be string")
            if payload.get("fallbackReasonCode") == "profile_denylisted":
                if adapter_denylist.get("matched") is not True:
                    errors.append(f"{label} adapterDenylist.matched must be true for profile_denylisted")
                if adapter_denylist.get("reasonCode") != "profile_denylisted":
                    errors.append(f"{label} adapterDenylist.reasonCode must be profile_denylisted")
    elif payload.get("fallbackReasonCode") == "profile_denylisted":
        errors.append(f"{label} adapterDenylist must be present for profile_denylisted")
    if not isinstance(payload.get("selectorVersion"), str) or not payload["selectorVersion"].strip():
        errors.append(f"{label} selectorVersion must be non-empty")
    if not isinstance(payload.get("launchArgsHash"), str) or not re.fullmatch(
        r"[a-f0-9]{64}", payload["launchArgsHash"]
    ):
        errors.append(f"{label} launchArgsHash must be sha256 hex")

    artifact = payload.get("artifactIdentity")
    if not isinstance(artifact, dict):
        errors.append(f"{label} artifactIdentity must be object")
        return errors
    if not isinstance(artifact.get("browserExecutablePath"), str) or not artifact[
        "browserExecutablePath"
    ].strip():
        errors.append(f"{label} artifactIdentity.browserExecutablePath must be non-empty")
    if not isinstance(artifact.get("browserExecutableSha256"), str) or not re.fullmatch(
        r"[a-f0-9]{64}", artifact["browserExecutableSha256"]
    ):
        errors.append(f"{label} artifactIdentity.browserExecutableSha256 must be sha256 hex")
    if not isinstance(artifact.get("dawnRuntimePath"), str) or not artifact["dawnRuntimePath"].strip():
        errors.append(f"{label} artifactIdentity.dawnRuntimePath must be non-empty")
    if not isinstance(artifact.get("dawnRuntimeSha256"), str) or not re.fullmatch(
        r"[a-f0-9]{64}", artifact["dawnRuntimeSha256"]
    ):
        errors.append(f"{label} artifactIdentity.dawnRuntimeSha256 must be sha256 hex")
    if mode == "doe":
        if not isinstance(artifact.get("doeLibPath"), str) or not artifact["doeLibPath"].strip():
            errors.append(f"{label} artifactIdentity.doeLibPath must be non-empty for doe")
        if not isinstance(artifact.get("doeLibSha256"), str) or not re.fullmatch(
            r"[a-f0-9]{64}", artifact["doeLibSha256"]
        ):
            errors.append(f"{label} artifactIdentity.doeLibSha256 must be sha256 hex for doe")
    else:
        if artifact.get("doeLibPath") is not None:
            errors.append(f"{label} artifactIdentity.doeLibPath must be null for dawn")
        if artifact.get("doeLibSha256") is not None:
            errors.append(f"{label} artifactIdentity.doeLibSha256 must be null for dawn")
    return errors


def validate_adapter_identity(payload: Any, label: str) -> list[str]:
    errors: list[str] = []
    if not isinstance(payload, dict):
        return [f"{label} adapterIdentity must be object"]
    for field in ("adapterInfoSha256",):
        if not isinstance(payload.get(field), str) or not re.fullmatch(r"[a-f0-9]{64}", payload[field]):
            errors.append(f"{label} adapterIdentity.{field} must be sha256 hex")
    feature_count = payload.get("featureCount")
    if not isinstance(feature_count, int) or feature_count < 0:
        errors.append(f"{label} adapterIdentity.featureCount must be non-negative integer")
    return errors


def validate_shader_compiler_identity(payload: Any, mode: str, label: str) -> list[str]:
    errors: list[str] = []
    if not isinstance(payload, dict):
        return [f"{label} shaderCompilerIdentity must be object"]
    if not isinstance(payload.get("compilerSurface"), str) or not payload["compilerSurface"].strip():
        errors.append(f"{label} shaderCompilerIdentity.compilerSurface must be non-empty")
    if payload.get("identitySource") != "runtime_artifact_identity":
        errors.append(f"{label} shaderCompilerIdentity.identitySource must be runtime_artifact_identity")
    if not isinstance(payload.get("compilerArtifactPath"), str) or not payload["compilerArtifactPath"].strip():
        errors.append(f"{label} shaderCompilerIdentity.compilerArtifactPath must be non-empty")
    if not isinstance(payload.get("compilerArtifactSha256"), str) or not re.fullmatch(
        r"[a-f0-9]{64}", payload["compilerArtifactSha256"]
    ):
        errors.append(f"{label} shaderCompilerIdentity.compilerArtifactSha256 must be sha256 hex")
    expected_surface = (
        "doe_runtime_embedded_shader_compiler"
        if mode == "doe"
        else "dawn_runtime_embedded_shader_compiler"
    )
    if payload.get("compilerSurface") != expected_surface:
        errors.append(f"{label} shaderCompilerIdentity.compilerSurface must be {expected_surface}")
    return errors


def validate_trace_hash_fields(payload: Any, label: str) -> list[str]:
    errors: list[str] = []
    if not isinstance(payload, dict):
        return [f"{label} trace row must be object"]
    if not isinstance(payload.get("hash"), str) or not re.fullmatch(r"[a-f0-9]{64}", payload["hash"]):
        errors.append(f"{label} hash must be sha256 hex")
    previous_hash = payload.get("previousHash")
    if previous_hash is not None and (
        not isinstance(previous_hash, str) or not re.fullmatch(r"[a-f0-9]{64}", previous_hash)
    ):
        errors.append(f"{label} previousHash must be null or sha256 hex")
    return errors


def validate_workload_identity(payload: Any, label: str) -> list[str]:
    errors: list[str] = []
    if not isinstance(payload, dict):
        return [f"{label} workloadIdentity must be object"]
    if not isinstance(payload.get("kind"), str) or not payload["kind"].strip():
        errors.append(f"{label} workloadIdentity.kind must be non-empty")
    digest_fields = (
        "workloadHash",
        "sourceWorkloadsSha256",
        "taskConfigHash",
    )
    if not any(
        isinstance(payload.get(field), str) and re.fullmatch(r"[a-f0-9]{64}", payload[field])
        for field in digest_fields
    ):
        errors.append(f"{label} workloadIdentity must include a sha256 workload digest")
    return errors


def _without_hash_fields(payload: dict[str, Any], fields: tuple[str, ...]) -> dict[str, Any]:
    return {key: value for key, value in payload.items() if key not in fields}


def validate_report_hash(payload: dict[str, Any], label: str) -> list[str]:
    report_hash = payload.get("reportHash")
    if not isinstance(report_hash, str) or not re.fullmatch(r"[a-f0-9]{64}", report_hash):
        return [f"{label} reportHash must be sha256 hex"]
    expected_hash = stable_hash(_without_hash_fields(payload, ("reportHash",)))
    if report_hash != expected_hash:
        return [f"{label} reportHash mismatch"]
    return []


def validate_mode_hash_chain(rows: list[Any], label: str) -> list[str]:
    errors: list[str] = []
    previous_hash: str | None = None
    for index, row in enumerate(rows):
        row_label = f"{label} modeResults[{index}]"
        if not isinstance(row, dict):
            errors.append(f"{row_label} must be object")
            continue
        actual_previous = row.get("previousHash")
        if actual_previous != previous_hash:
            expected = "null" if previous_hash is None else previous_hash
            errors.append(f"{row_label} previousHash must be {expected}")
        actual_hash = row.get("hash")
        if not isinstance(actual_hash, str) or not re.fullmatch(r"[a-f0-9]{64}", actual_hash):
            errors.append(f"{row_label} hash must be sha256 hex")
            previous_hash = actual_hash if isinstance(actual_hash, str) else previous_hash
            continue
        expected_hash = stable_hash(
            {
                "previousHash": previous_hash,
                "entry": _without_hash_fields(row, ("previousHash", "hash")),
            }
        )
        if actual_hash != expected_hash:
            errors.append(f"{row_label} hash mismatch")
        previous_hash = actual_hash
    return errors


def validate_smoke_report(
    payload: dict[str, Any],
    *,
    required_modes: tuple[str, ...] = ("dawn", "doe"),
    require_strict: bool = True,
    require_hash_chain: bool = True,
) -> list[str]:
    errors: list[str] = []
    required_mode_set = set(required_modes)
    if required_mode_set - {"dawn", "doe"}:
        errors.append(f"smoke required_modes invalid: {sorted(required_mode_set)}")
    if payload.get("schemaVersion") != 2:
        errors.append("smoke schemaVersion must be 2")
    if payload.get("reportKind") != "chromium-webgpu-playwright-smoke":
        errors.append("smoke reportKind must be chromium-webgpu-playwright-smoke")
    if payload.get("benchmarkClass") != "diagnostic":
        errors.append("smoke benchmarkClass must be diagnostic")
    if payload.get("comparisonStatus") != "diagnostic":
        errors.append("smoke comparisonStatus must be diagnostic")
    if payload.get("claimStatus") != "diagnostic":
        errors.append("smoke claimStatus must be diagnostic")
    if payload.get("hashAlgorithm") != "sha256":
        errors.append("smoke hashAlgorithm must be sha256")
    report_mode = payload.get("mode")
    if required_mode_set == {"dawn", "doe"} and report_mode != "both":
        errors.append("smoke mode must be both when dawn and doe are required")
    elif len(required_mode_set) == 1 and report_mode not in required_mode_set | {"both"}:
        errors.append(f"smoke mode must match required modes, found {report_mode!r}")
    methodology = payload.get("methodology")
    if not isinstance(methodology, dict):
        errors.append("smoke methodology must be object")
    elif require_strict and methodology.get("strictMode") is not True:
        errors.append("smoke methodology.strictMode must be true")
    if require_hash_chain:
        errors.extend(validate_report_hash(payload, "smoke"))
    errors.extend(validate_workload_identity(payload.get("workloadIdentity"), "smoke report"))
    comparison = payload.get("comparison")
    if required_mode_set == {"dawn", "doe"}:
        if not isinstance(comparison, dict):
            errors.append("smoke comparison missing")
            return errors
        if comparison.get("bothComputeSmokePass") is not True:
            errors.append("smoke bothComputeSmokePass must be true")
        if comparison.get("bothRenderSmokePass") is not True:
            errors.append("smoke bothRenderSmokePass must be true")
        if comparison.get("bothRenderBundleSmokePass") is not True:
            errors.append("smoke bothRenderBundleSmokePass must be true")
        if comparison.get("bothRenderIndirectSmokePass") is not True:
            errors.append("smoke bothRenderIndirectSmokePass must be true")
        if comparison.get("bothTimestampQuerySmokePass") is not True:
            errors.append("smoke bothTimestampQuerySmokePass must be true")
    mode_results = payload.get("modeResults")
    if not isinstance(mode_results, list) or len(mode_results) < len(required_mode_set):
        errors.append(f"smoke modeResults must include {sorted(required_mode_set)}")
        return errors
    if require_hash_chain:
        errors.extend(validate_mode_hash_chain(mode_results, "smoke"))
    modes_seen = set()
    for row in mode_results:
        if not isinstance(row, dict):
            errors.append("smoke modeResults entry must be object")
            continue
        mode = row.get("mode")
        if not isinstance(mode, str):
            errors.append("smoke modeResults entry missing mode")
            continue
        modes_seen.add(mode)
        errors.extend(validate_trace_hash_fields(row, f"smoke mode {mode}"))
        errors.extend(validate_runtime_selection(row.get("runtimeSelection"), mode, f"smoke {mode}"))
        errors.extend(
            validate_shader_compiler_identity(
                row.get("shaderCompilerIdentity"),
                mode,
                f"smoke {mode}",
            )
        )
        if row.get("webgpuAvailable") is not True:
            errors.append(f"smoke mode {mode} webgpuAvailable must be true")
        if row.get("adapterAvailable") is not True:
            errors.append(f"smoke mode {mode} adapterAvailable must be true")
        else:
            errors.extend(validate_adapter_identity(row.get("adapterIdentity"), f"smoke mode {mode}"))
        active_proof = row.get("activeRuntimeProof")
        if not isinstance(active_proof, dict):
            errors.append(f"smoke mode {mode} activeRuntimeProof must be object")
        else:
            if active_proof.get("identitySource") != "wgpuAdapterGetInfo":
                errors.append(f"smoke mode {mode} activeRuntimeProof.identitySource must be wgpuAdapterGetInfo")
            if active_proof.get("selectedRuntime") != mode:
                errors.append(f"smoke mode {mode} activeRuntimeProof.selectedRuntime must be {mode}")
            if active_proof.get("matched") is not True:
                errors.append(f"smoke mode {mode} activeRuntimeProof.matched must be true")
        if row.get("errors"):
            errors.append(f"smoke mode {mode} errors must be empty")
        browser_close = row.get("browserClose")
        if browser_close is not None and (
            not isinstance(browser_close, dict) or browser_close.get("pass") is not True
        ):
            errors.append(f"smoke mode {mode} browserClose pass must be true")
        smoke = row.get("smoke")
        if not isinstance(smoke, dict):
            errors.append(f"smoke mode {mode} missing smoke object")
            continue
        for key in (
            "computeIncrement",
            "renderTriangle",
            "renderBundle",
            "renderIndirect",
            "timestampQuery",
            "requestAdapterXrCompatible",
            "copyExternalImageToTexture",
            "importExternalTexture",
        ):
            part = smoke.get(key)
            if not isinstance(part, dict) or part.get("pass") is not True:
                errors.append(f"smoke mode {mode} {key} pass must be true")
    if not required_mode_set.issubset(modes_seen):
        errors.append(
            f"smoke modeResults must contain {sorted(required_mode_set)}, found {sorted(modes_seen)}"
        )
    unknown_modes = modes_seen - {"dawn", "doe"}
    if unknown_modes:
        errors.append(f"smoke modeResults contains unknown modes: {sorted(unknown_modes)}")
    runtime_selections = payload.get("runtimeSelections")
    if not isinstance(runtime_selections, list):
        errors.append("smoke runtimeSelections must be list")
    else:
        selection_modes = []
        for index, selection in enumerate(runtime_selections):
            if not isinstance(selection, dict):
                errors.append(f"smoke runtimeSelections[{index}] must be object")
                continue
            mode = selection.get("selectionMode")
            if isinstance(mode, str):
                selection_modes.append(mode)
                if mode in {"dawn", "doe"}:
                    errors.extend(
                        validate_runtime_selection(selection, mode, f"smoke runtimeSelections[{index}]")
                    )
                else:
                    errors.append(
                        f"smoke runtimeSelections[{index}] selectionMode must be dawn or doe"
                    )
            else:
                errors.append(f"smoke runtimeSelections[{index}] missing selectionMode")
        if not required_mode_set.issubset(set(selection_modes)):
            errors.append(
                f"smoke runtimeSelections must contain {sorted(required_mode_set)}, found {selection_modes}"
            )
    return errors


def validate_layered_artifacts(
    report_payload: dict[str, Any],
    summary_payload: dict[str, Any],
    check_payload: dict[str, Any],
) -> list[str]:
    errors: list[str] = []
    if report_payload.get("reportKind") != "browser-layered-diagnostic":
        errors.append("layered reportKind must be browser-layered-diagnostic")
    errors.extend(validate_workload_identity(report_payload.get("workloadIdentity"), "layered report"))
    if not isinstance(report_payload.get("browserEnvironmentEvidence"), dict):
        errors.append("layered report missing browserEnvironmentEvidence")
    runtime_selections = report_payload.get("runtimeSelections")
    if not isinstance(runtime_selections, list):
        errors.append("layered report runtimeSelections must be list")
    else:
        selection_modes = []
        for index, selection in enumerate(runtime_selections):
            mode = selection.get("selectionMode") if isinstance(selection, dict) else None
            if isinstance(mode, str):
                selection_modes.append(mode)
                errors.extend(
                    validate_runtime_selection(selection, mode, f"layered runtimeSelections[{index}]")
                )
            else:
                errors.append(f"layered runtimeSelections[{index}] missing selectionMode")
        if sorted(selection_modes) != ["dawn", "doe"]:
            errors.append(f"layered runtimeSelections must contain dawn and doe, found {selection_modes}")
    mode_details = report_payload.get("modeRunDetails")
    if not isinstance(mode_details, list):
        errors.append("layered report modeRunDetails must be list")
    else:
        for index, detail in enumerate(mode_details):
            if not isinstance(detail, dict):
                errors.append(f"layered modeRunDetails[{index}] must be object")
                continue
            mode = detail.get("mode")
            if not isinstance(mode, str):
                errors.append(f"layered modeRunDetails[{index}] missing mode")
                continue
            errors.extend(validate_trace_hash_fields(detail, f"layered modeRunDetails[{index}]"))
            errors.extend(
                validate_runtime_selection(
                    detail.get("runtimeSelection"),
                    mode,
                    f"layered modeRunDetails[{index}]",
                )
            )
            errors.extend(
                validate_shader_compiler_identity(
                    detail.get("shaderCompilerIdentity"),
                    mode,
                    f"layered modeRunDetails[{index}]",
                )
            )
            runtime_probe = detail.get("runtimeProbe")
            if not isinstance(runtime_probe, dict):
                errors.append(f"layered modeRunDetails[{index}] runtimeProbe must be object")
            elif runtime_probe.get("adapterAvailable") is True:
                errors.extend(
                    validate_adapter_identity(
                        runtime_probe.get("adapterIdentity"),
                        f"layered modeRunDetails[{index}]",
                    )
                )
    if summary_payload.get("reportKind") != "browser-layered-superset-summary":
        errors.append("summary reportKind must be browser-layered-superset-summary")
    if summary_payload.get("comparisonStatus") != "diagnostic":
        errors.append("summary comparisonStatus must be diagnostic")
    if summary_payload.get("claimStatus") != "diagnostic":
        errors.append("summary claimStatus must be diagnostic")
    run = summary_payload.get("run")
    if not isinstance(run, dict):
        errors.append("summary missing run object")
    else:
        if run.get("strictRun") is not True:
            errors.append("summary run.strictRun must be true")
        if run.get("overallRequiredFailures") != 0:
            errors.append("summary overallRequiredFailures must be 0")
        for phase in ("l1", "l2"):
            phase_payload = run.get(phase)
            if not isinstance(phase_payload, dict):
                errors.append(f"summary missing {phase} object")
                continue
            for mode in ("dawn", "doe"):
                mode_payload = phase_payload.get(mode)
                if not isinstance(mode_payload, dict):
                    errors.append(f"summary missing {phase}.{mode}")
                    continue
                if mode_payload.get("requiredFailures") != 0:
                    errors.append(f"summary {phase}.{mode}.requiredFailures must be 0")
    if check_payload.get("ok") is not True:
        errors.append("check payload ok must be true")
    if check_payload.get("reportChecked") is not True:
        errors.append("check payload reportChecked must be true")
    if check_payload.get("promotionChecked") is not True:
        errors.append("check payload promotionChecked must be true")
    required_modes = check_payload.get("requiredModes")
    if required_modes != ["dawn", "doe"]:
        errors.append(f"check requiredModes must be ['dawn', 'doe'], found {required_modes}")
    summary = check_payload.get("summary")
    if not isinstance(summary, dict) or summary.get("rowCount", 0) <= 0:
        errors.append("check summary.rowCount must be > 0")
    return errors


def main() -> int:
    args = parse_args()
    root = Path(args.root).resolve()
    artifacts_root = Path(args.artifact_root).resolve() if args.artifact_root else default_artifact_root(root)
    artifacts_root.mkdir(parents=True, exist_ok=True)
    report_path = Path(args.report).resolve() if args.report else default_gate_report_path(root)
    report_path.parent.mkdir(parents=True, exist_ok=True)

    smoke_report = artifacts_root / "dawn-vs-doe.browser.playwright-smoke.diagnostic.json"
    cts_subset_report = artifacts_root / "browser-cts-subset.json"
    recovery_parity_report = artifacts_root / "browser-recovery-parity.json"
    canvas_webgpu_fusion_report = artifacts_root / "browser-canvas-webgpu-fusion.json"
    media_path_probe_report = artifacts_root / "browser-media-path-probe.json"
    gpu_scheduler_report = artifacts_root / "browser-gpu-scheduler.json"
    webgpu_effect_experiment_report = artifacts_root / "browser-webgpu-effect-experiment.json"
    flight_recorder_report = artifacts_root / "browser-gpu-flight-recorder.json"
    flight_replay_report = artifacts_root / "browser-gpu-flight-replay.json"
    shader_links_report = artifacts_root / "browser-shader-links.json"
    local_ai_workloads_report = artifacts_root / "browser-local-ai-workloads.json"
    pipeline_cache_receipts_report = artifacts_root / "browser-pipeline-cache-receipts.json"
    fallback_explanations_report = artifacts_root / "browser-fallback-explanations.json"
    layered_report = artifacts_root / "dawn-vs-doe.browser-layered.superset.diagnostic.json"
    summary_report = artifacts_root / "dawn-vs-doe.browser-layered.superset.summary.json"
    check_report = artifacts_root / "dawn-vs-doe.browser-layered.superset.check.json"

    approvals_path = Path(args.promotion_approvals).resolve()
    ownership_path = Path(args.ownership).resolve()
    responsibility_map_path = Path(args.responsibility_map).resolve()
    runtime_selector_policy_path = Path(args.runtime_selector_policy).resolve()
    fork_maintenance_policy_path = Path(args.fork_maintenance_policy).resolve()
    capture_policy_path = Path(args.capture_policy).resolve()

    selector_policy_check = [
        sys.executable,
        str(root / "browser/chromium/scripts/check-browser-runtime-selector-policy.py"),
        "--policy",
        str(runtime_selector_policy_path),
    ]
    run_step("runtime-selector-policy", selector_policy_check, root)

    fork_maintenance_policy_check = [
        sys.executable,
        str(root / "bench/tools/check_chromium_fork_maintenance_policy.py"),
        "--policy",
        str(fork_maintenance_policy_path),
        "--root",
        str(root),
    ]
    run_step("chromium-fork-maintenance-policy", fork_maintenance_policy_check, root)

    fork_maintenance_policy = load_json(fork_maintenance_policy_path)
    patch_manifest_path = root / fork_maintenance_policy["patchIsolation"]["patchManifestPath"]
    patch_manifest_check = [
        sys.executable,
        str(root / "bench/tools/check_chromium_patch_manifest.py"),
        "--manifest",
        str(patch_manifest_path),
        "--policy",
        str(fork_maintenance_policy_path),
        "--root",
        str(root),
    ]
    run_step("chromium-patch-manifest", patch_manifest_check, root)

    capture_policy_check = [
        sys.executable,
        str(root / "bench/tools/check_browser_capture_policy.py"),
        "--policy",
        str(capture_policy_path),
    ]
    run_step("browser-capture-policy", capture_policy_check, root)

    preflight = [
        "./browser/chromium/scripts/preflight.sh",
        "--mode",
        "bench",
    ]
    run_step("preflight", preflight, root)

    smoke_command = [
        "./browser/chromium/scripts/run-smoke.sh",
        "--mode",
        "both",
        "--strict",
        "--runtime-selector-policy",
        str(runtime_selector_policy_path),
        "--out",
        str(smoke_report),
        "--cts-subset-out",
        str(cts_subset_report),
        "--recovery-parity-out",
        str(recovery_parity_report),
        "--canvas-webgpu-fusion-out",
        str(canvas_webgpu_fusion_report),
        "--media-path-probe-out",
        str(media_path_probe_report),
        "--media-path-probe-capture-policy",
        str(capture_policy_path),
        "--gpu-scheduler-out",
        str(gpu_scheduler_report),
        "--webgpu-effect-experiment-out",
        str(webgpu_effect_experiment_report),
        "--flight-recorder-components",
        str(root / "examples/browser-gpu-flight-recorder.sample.json"),
        "--flight-recorder-out",
        str(flight_recorder_report),
        "--flight-recorder-mode",
        "doe",
        "--shader-links-out",
        str(shader_links_report),
        "--local-ai-workloads-out",
        str(local_ai_workloads_report),
        "--pipeline-cache-receipts-out",
        str(pipeline_cache_receipts_report),
        "--fallback-explanations-out",
        str(fallback_explanations_report),
        "--fallback-explanations-taxonomy",
        str(root / "config/browser-unsupported-reason-taxonomy.json"),
    ]
    if args.chrome:
        smoke_command.extend(["--chrome", args.chrome])
    if args.doe_lib:
        smoke_command.extend(["--doe-lib", args.doe_lib])
    run_step("smoke", smoke_command, root)

    bench_command = [
        "./browser/chromium/scripts/run-bench.sh",
        "--mode",
        "both",
        "--strict-run",
        "--require-promotion-approvals",
        "--promotion-approvals",
        str(approvals_path),
        "--runtime-selector-policy",
        str(runtime_selector_policy_path),
        "--out",
        str(layered_report),
        "--summary-out",
        str(summary_report),
        "--check-out",
        str(check_report),
    ]
    if args.chrome:
        bench_command.extend(["--chrome", args.chrome])
    resolved_dawn_chrome = resolve_dawn_chrome(root, args.dawn_chrome)
    if resolved_dawn_chrome:
        bench_command.extend(["--dawn-chrome", resolved_dawn_chrome])
    if args.doe_chrome:
        bench_command.extend(["--doe-chrome", args.doe_chrome])
    if args.doe_lib:
        bench_command.extend(["--doe-lib", args.doe_lib])
    run_step("layered", bench_command, root)

    ownership_errors = validate_ownership(load_json(ownership_path))
    responsibility_map_errors = validate_responsibility_map(responsibility_map_path, root)
    cts_subset_errors = validate_cts_subset(cts_subset_report, root)
    recovery_parity_errors = validate_recovery_parity(recovery_parity_report, root)
    canvas_webgpu_fusion_errors = validate_json_checker(
        label="canvas-webgpu-fusion",
        root=root,
        checker=root / "browser/chromium/scripts/check-browser-canvas-webgpu-fusion.py",
        path_flag="--probe",
        artifact_path=canvas_webgpu_fusion_report,
        extra_args=["--runtime-identity-root", str(root)],
    )
    media_path_probe_errors = validate_json_checker(
        label="media-path-probe",
        root=root,
        checker=root / "browser/chromium/scripts/check-browser-media-path-probe.py",
        path_flag="--probe",
        artifact_path=media_path_probe_report,
        extra_args=[
            "--capture-policy-root",
            str(root),
            "--runtime-identity-root",
            str(root),
        ],
    )
    gpu_scheduler_errors = validate_json_checker(
        label="gpu-scheduler",
        root=root,
        checker=root / "browser/chromium/scripts/check-browser-gpu-scheduler.py",
        path_flag="--probe",
        artifact_path=gpu_scheduler_report,
        extra_args=["--runtime-identity-root", str(root)],
    )
    webgpu_effect_experiment_errors = validate_json_checker(
        label="webgpu-effect-experiment",
        root=root,
        checker=root / "browser/chromium/scripts/check-browser-webgpu-effect-experiment.py",
        path_flag="--experiment",
        artifact_path=webgpu_effect_experiment_report,
        extra_args=["--runtime-identity-root", str(root)],
    )
    flight_recorder_replay_errors = validate_flight_recorder_replay(
        root=root,
        flight_recorder_path=flight_recorder_report,
        replay_report_path=flight_replay_report,
        capture_policy_path=capture_policy_path,
    )
    shader_links_errors = validate_json_checker(
        label="shader-links",
        root=root,
        checker=root / "browser/chromium/scripts/check-browser-shader-links.py",
        path_flag="--links",
        artifact_path=shader_links_report,
        extra_args=[
            "--verify-flight-recorder-root",
            str(root),
            "--verify-lowering-root",
            str(root),
        ],
    )
    local_ai_workloads_errors = validate_json_checker(
        label="local-ai-workloads",
        root=root,
        checker=root / "browser/chromium/scripts/check-browser-local-ai-workloads.py",
        path_flag="--workloads",
        artifact_path=local_ai_workloads_report,
        extra_args=["--runtime-identity-root", str(root)],
    )
    pipeline_cache_receipts_errors = validate_pipeline_cache_receipts(pipeline_cache_receipts_report, root)
    fallback_explanations_errors = validate_json_checker(
        label="fallback-explanations",
        root=root,
        checker=root / "browser/chromium/scripts/check-browser-fallback-explanations.py",
        path_flag="--explanations",
        artifact_path=fallback_explanations_report,
        extra_args=[
            "--taxonomy-root",
            str(root),
            "--runtime-identity-root",
            str(root),
        ],
    )
    smoke_payload = load_json(smoke_report)
    smoke_errors = validate_smoke_report(smoke_payload)
    report_payload = load_json(layered_report)
    summary_payload = load_json(summary_report)
    check_payload = load_json(check_report)
    layered_errors = validate_layered_artifacts(report_payload, summary_payload, check_payload)

    failures = (
        ownership_errors
        + responsibility_map_errors
        + cts_subset_errors
        + recovery_parity_errors
        + canvas_webgpu_fusion_errors
        + media_path_probe_errors
        + gpu_scheduler_errors
        + webgpu_effect_experiment_errors
        + flight_recorder_replay_errors
        + shader_links_errors
        + local_ai_workloads_errors
        + pipeline_cache_receipts_errors
        + fallback_explanations_errors
        + smoke_errors
        + layered_errors
    )
    payload = {
        "laneId": "browser_diagnostic",
        "ok": not failures,
        "generatedAt": datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "ownershipOk": not ownership_errors,
        "responsibilityMapOk": not responsibility_map_errors,
        "ctsSubsetOk": not cts_subset_errors,
        "recoveryParityOk": not recovery_parity_errors,
        "canvasWebgpuFusionOk": not canvas_webgpu_fusion_errors,
        "mediaPathProbeOk": not media_path_probe_errors,
        "gpuSchedulerOk": not gpu_scheduler_errors,
        "webgpuEffectExperimentOk": not webgpu_effect_experiment_errors,
        "flightRecorderReplayOk": not flight_recorder_replay_errors,
        "shaderLinksOk": not shader_links_errors,
        "localAiWorkloadsOk": not local_ai_workloads_errors,
        "pipelineCacheReceiptsOk": not pipeline_cache_receipts_errors,
        "fallbackExplanationsOk": not fallback_explanations_errors,
        "smokeOk": not smoke_errors,
        "layeredOk": not layered_errors,
        "artifacts": {
            "smokeReport": str(smoke_report),
            "layeredReport": str(layered_report),
            "summaryReport": str(summary_report),
            "checkReport": str(check_report),
            "promotionApprovals": str(approvals_path),
            "ownership": str(ownership_path),
            "responsibilityMap": str(responsibility_map_path),
            "runtimeSelectorPolicy": str(runtime_selector_policy_path),
            "forkMaintenancePolicy": str(fork_maintenance_policy_path),
            "chromiumPatchManifest": str(patch_manifest_path),
            "capturePolicy": str(capture_policy_path),
            "ctsSubsetReport": str(cts_subset_report),
            "recoveryParityReport": str(recovery_parity_report),
            "canvasWebgpuFusionReport": str(canvas_webgpu_fusion_report),
            "mediaPathProbeReport": str(media_path_probe_report),
            "gpuSchedulerReport": str(gpu_scheduler_report),
            "webgpuEffectExperimentReport": str(webgpu_effect_experiment_report),
            "flightRecorderReport": str(flight_recorder_report),
            "flightReplayReport": str(flight_replay_report),
            "shaderLinksReport": str(shader_links_report),
            "localAiWorkloadsReport": str(local_ai_workloads_report),
            "pipelineCacheReceiptsReport": str(pipeline_cache_receipts_report),
            "fallbackExplanationsReport": str(fallback_explanations_report),
        },
        "hashes": {
            "smokeReport": stable_hash(smoke_payload),
            "ctsSubsetReport": stable_hash(load_json(cts_subset_report)),
            "recoveryParityReport": stable_hash(load_json(recovery_parity_report)),
            "canvasWebgpuFusionReport": stable_hash(load_json(canvas_webgpu_fusion_report)),
            "mediaPathProbeReport": stable_hash(load_json(media_path_probe_report)),
            "gpuSchedulerReport": stable_hash(load_json(gpu_scheduler_report)),
            "webgpuEffectExperimentReport": stable_hash(load_json(webgpu_effect_experiment_report)),
            "flightRecorderReport": stable_hash(load_json(flight_recorder_report)),
            "flightReplayReport": stable_hash(load_json(flight_replay_report)),
            "shaderLinksReport": stable_hash(load_json(shader_links_report)),
            "localAiWorkloadsReport": stable_hash(load_json(local_ai_workloads_report)),
            "pipelineCacheReceiptsReport": stable_hash(load_json(pipeline_cache_receipts_report)),
            "fallbackExplanationsReport": stable_hash(load_json(fallback_explanations_report)),
            "layeredReport": stable_hash(report_payload),
            "summaryReport": stable_hash(summary_payload),
            "checkReport": stable_hash(check_payload),
        },
        "failures": failures,
    }
    report_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    output_paths.write_run_manifest_for_outputs(
        [report_path],
        {
            "runType": "browser-gate",
            "fullRun": True,
            "claimGateRan": False,
            "status": "pass" if not failures else "fail",
            "smokeReport": str(smoke_report),
            "ctsSubsetReport": str(cts_subset_report),
            "recoveryParityReport": str(recovery_parity_report),
            "canvasWebgpuFusionReport": str(canvas_webgpu_fusion_report),
            "mediaPathProbeReport": str(media_path_probe_report),
            "gpuSchedulerReport": str(gpu_scheduler_report),
            "webgpuEffectExperimentReport": str(webgpu_effect_experiment_report),
            "flightRecorderReport": str(flight_recorder_report),
            "flightReplayReport": str(flight_replay_report),
            "shaderLinksReport": str(shader_links_report),
            "localAiWorkloadsReport": str(local_ai_workloads_report),
            "pipelineCacheReceiptsReport": str(pipeline_cache_receipts_report),
            "fallbackExplanationsReport": str(fallback_explanations_report),
            "layeredReport": str(layered_report),
        },
    )
    if args.emit_json or True:
        print(json.dumps(payload, indent=2))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
