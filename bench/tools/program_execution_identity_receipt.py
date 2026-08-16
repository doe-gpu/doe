#!/usr/bin/env python3
"""Build or verify one source-to-backend-to-output execution identity receipt."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def stable_sha256(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def repo_path(path: Path) -> str:
    resolved = path.resolve()
    try:
        return resolved.relative_to(REPO_ROOT).as_posix()
    except ValueError as exc:
        raise ValueError(f"path escapes repository: {path}") from exc


def resolve_repo_path(value: str) -> Path:
    path = (REPO_ROOT / value).resolve()
    repo_path(path)
    return path


def load_object(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"expected JSON object: {path}")
    return value


def load_commands(path: Path) -> list[dict[str, Any]]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, list) or len(value) != 1 or not isinstance(value[0], dict):
        raise ValueError("identity receipt requires exactly one command object")
    return value


def load_trace(path: Path) -> list[dict[str, Any]]:
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip():
            row = json.loads(line)
            if not isinstance(row, dict):
                raise ValueError("trace rows must be JSON objects")
            rows.append(row)
    return rows


def file_ref(path: Path) -> dict[str, str]:
    return {"path": repo_path(path), "sha256": file_sha256(path)}


def build_receipt(
    runtime_path: Path,
    commands_path: Path,
    kernel_root: Path,
    trace_meta_path: Path,
    trace_path: Path,
) -> dict[str, Any]:
    command = load_commands(commands_path)[0]
    trace_meta = load_object(trace_meta_path)
    trace_rows = load_trace(trace_path)
    failures: list[str] = []

    if command.get("kind") != "kernel_dispatch":
        failures.append("command_not_kernel_dispatch")
    kernel = str(command.get("kernel", ""))
    source_path = (kernel_root / kernel).resolve()
    repo_path(source_path)

    manifest_raw = trace_meta.get("shaderArtifactManifestPath")
    if not isinstance(manifest_raw, str) or not manifest_raw:
        raise ValueError("trace metadata is missing shaderArtifactManifestPath")
    manifest_path = resolve_repo_path(manifest_raw)
    manifest = load_object(manifest_path)

    spirv_stages = [
        stage
        for stage in manifest.get("stages", [])
        if isinstance(stage, dict) and stage.get("stage") == "ir_to_spirv"
    ]
    if len(spirv_stages) != 1:
        raise ValueError("manifest must contain exactly one ir_to_spirv stage")
    artifact_raw = spirv_stages[0].get("artifactPath")
    if not isinstance(artifact_raw, str) or not artifact_raw:
        raise ValueError("SPIR-V stage is missing artifactPath")
    artifact_path = (manifest_path.parent / artifact_raw).resolve()
    repo_path(artifact_path)

    oracle = command.get("output_oracle")
    if not isinstance(oracle, dict):
        raise ValueError("kernel command is missing output_oracle")
    reference_id = str(oracle.get("reference_id", ""))
    reference_path = resolve_repo_path(reference_id)

    source_hash = file_sha256(source_path)
    artifact_hash = file_sha256(artifact_path)
    expected_hash = str(oracle.get("expected_sha256", ""))
    trace_events = [row for row in trace_rows if row.get("opCode") == "dispatch"]
    event = trace_events[0] if len(trace_events) == 1 else {}

    checks = {
        "sourceMatchesManifest": source_hash == manifest.get("wgslSha256"),
        "moduleMatchesCommand": kernel == manifest.get("module"),
        "manifestIdentityMatchesTrace": (
            manifest.get("hash") == trace_meta.get("shaderArtifactManifestHash")
            == event.get("executionShaderArtifactManifestHash")
        ),
        "manifestPathMatchesTrace": (
            repo_path(manifest_path) == manifest_raw
            == event.get("executionShaderArtifactManifestPath")
        ),
        "backendMatchesExecution": (
            manifest.get("backendId") == trace_meta.get("executionBackend")
            == event.get("executionBackend") == "doe_vulkan"
        ),
        "backendArtifactMatchesManifest": (
            artifact_hash == manifest.get("spirvSha256")
            == spirv_stages[0].get("artifactSha256")
        ),
        "executionSucceeded": (
            trace_meta.get("executionSuccessCount") == 1
            and trace_meta.get("executionErrorCount") == 0
            and event.get("executionStatus") == "ok"
        ),
        "dispatchCountMatchesCommand": (
            trace_meta.get("executionDispatchCount") == command.get("repeat")
            == event.get("executionDispatchCount")
        ),
        "fallbackAbsent": trace_meta.get("fallbackUsed") is False,
        "outputOracleMatched": (
            trace_meta.get("outputOracleCount") == 1
            and trace_meta.get("outputOracleMatchedCount") == 1
            and trace_meta.get("outputOracleFailedCount") == 0
            and trace_meta.get("outputOracleExpectedSha256") == expected_hash
            and trace_meta.get("outputOracleActualSha256") == expected_hash
            and trace_meta.get("outputOracleReferenceId") == reference_id
        ),
    }
    failures.extend(name for name, passed in checks.items() if not passed)

    receipt: dict[str, Any] = {
        "schemaVersion": 1,
        "artifactKind": "doe_program_execution_identity_receipt",
        "inputs": {
            "runtime": file_ref(runtime_path),
            "commands": file_ref(commands_path),
            "kernelRoot": repo_path(kernel_root),
            "source": file_ref(source_path),
            "traceMeta": file_ref(trace_meta_path),
            "trace": file_ref(trace_path),
            "shaderManifest": file_ref(manifest_path),
            "backendArtifact": file_ref(artifact_path),
            "oracleReference": file_ref(reference_path),
        },
        "identity": {
            "kernel": kernel,
            "backend": manifest.get("backendId"),
            "backendLane": trace_meta.get("backendLane"),
            "profile": trace_meta.get("profile"),
            "wgslSha256": manifest.get("wgslSha256"),
            "semanticSha256": next(
                (stage.get("artifactSha256") for stage in manifest.get("stages", [])
                 if isinstance(stage, dict) and stage.get("stage") == "sema"),
                None,
            ),
            "irSha256": manifest.get("irSha256"),
            "backendArtifactSha256": manifest.get("spirvSha256"),
            "toolchainSha256": manifest.get("toolchainSha256"),
            "shaderManifestIdentity": manifest.get("hash"),
            "pipelineHash": manifest.get("pipelineHash"),
            "dispatchCount": trace_meta.get("executionDispatchCount"),
            "outputSha256": trace_meta.get("outputOracleActualSha256"),
        },
        "oracle": {
            "kind": oracle.get("kind"),
            "referenceId": reference_id,
            "expectedSha256": expected_hash,
            "actualSha256": trace_meta.get("outputOracleActualSha256"),
        },
        "checks": checks,
        "verdict": {
            "status": "passed" if not failures else "failed",
            "failureCodes": failures,
            "claimBoundary": (
                "runtime-reported source-to-SPIR-V execution identity and exact output; "
                "not a driver-binary, operating-system dependency, or performance claim"
            ),
        },
    }
    receipt["receiptSha256"] = stable_sha256(receipt)
    return receipt


def verify_receipt(receipt_path: Path) -> list[str]:
    receipt = load_object(receipt_path)
    inputs = receipt.get("inputs", {})
    try:
        rebuilt = build_receipt(
            resolve_repo_path(inputs["runtime"]["path"]),
            resolve_repo_path(inputs["commands"]["path"]),
            resolve_repo_path(inputs["kernelRoot"]),
            resolve_repo_path(inputs["traceMeta"]["path"]),
            resolve_repo_path(inputs["trace"]["path"]),
        )
    except (KeyError, OSError, ValueError, json.JSONDecodeError) as exc:
        return [f"receipt input error: {exc}"]
    failures = [] if rebuilt == receipt else ["receipt does not match its current inputs"]
    if rebuilt.get("verdict", {}).get("status") != "passed":
        failure_codes = rebuilt.get("verdict", {}).get("failureCodes", [])
        suffix = ", ".join(str(code) for code in failure_codes) or "unknown failure"
        failures.append(f"current inputs do not produce a passing receipt: {suffix}")
    return failures


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime")
    parser.add_argument("--commands")
    parser.add_argument("--kernel-root")
    parser.add_argument("--trace-meta")
    parser.add_argument("--trace")
    parser.add_argument("--out")
    parser.add_argument("--check")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.check:
        failures = verify_receipt(Path(args.check))
        if failures:
            print("FAIL: program execution identity receipt")
            for failure in failures:
                print(f"  {failure}")
            return 1
        print("PASS: program execution identity receipt")
        return 0
    required = [args.runtime, args.commands, args.kernel_root, args.trace_meta, args.trace, args.out]
    if any(value is None for value in required):
        raise SystemExit("build mode requires --runtime, --commands, --kernel-root, --trace-meta, --trace, and --out")
    receipt = build_receipt(
        resolve_repo_path(args.runtime),
        resolve_repo_path(args.commands),
        resolve_repo_path(args.kernel_root),
        resolve_repo_path(args.trace_meta),
        resolve_repo_path(args.trace),
    )
    resolve_repo_path(args.out).write_text(
        json.dumps(receipt, indent=2) + "\n",
        encoding="utf-8",
    )
    return 0 if receipt["verdict"]["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
