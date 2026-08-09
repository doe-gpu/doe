"""Capture physical old/new kernel-dispatch semantic equivalence."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from source_architecture import canonical_json, sha256_file


RUNTIME_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = RUNTIME_ROOT.parents[1]
BASELINE_PATH = RUNTIME_ROOT / "reports/recomposition/baseline.json"
OUTPUT_PATH = (
    RUNTIME_ROOT / "reports/recomposition/kernel-dispatch-equivalence.json"
)
RAW_ROOT = (
    REPO_ROOT
    / "bench/out/recomposition/kernel-dispatch-equivalence"
    / "amd-vulkan-workgroup-atomic-v1"
)
COMMAND_PATH = Path("examples/workgroup_atomic_commands.json")
KERNEL_PATH = Path("bench/kernels/workgroup_atomic.wgsl")
QUIRKS_PATH = Path("examples/quirks/amd_radv_noop_list.json")
WORKLOAD_ID = "compute_workgroup_atomic_1024"
ARCHIVE_PATHS = (
    "runtime/zig",
    "bench/kernels",
    "config",
    COMMAND_PATH.as_posix(),
    QUIRKS_PATH.as_posix(),
    "pipeline/lean",
    "runtime/bridge/onnxruntime-ep",
)
FIELD_RE = re.compile(r"^\s*(?P<name>\w+)\s*=\s*(?P<value>.+?)\s*$", re.MULTILINE)


def _run(
    command: list[str],
    cwd: Path,
    *,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[bytes]:
    result = subprocess.run(
        command,
        cwd=cwd,
        env=env,
        check=False,
        capture_output=True,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        if not detail:
            detail = result.stdout.decode("utf-8", errors="replace").strip()
        raise RuntimeError(
            f"command failed at {' '.join(command[:2])}: {detail[-4096:]}"
        )
    return result


def _git_text(*arguments: str) -> str:
    return _run(["git", *arguments], REPO_ROOT).stdout.decode("ascii").strip()


def _load_object(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"expected JSON object: {path}")
    return payload


def _baseline_commit() -> str:
    baseline = _load_object(BASELINE_PATH)
    commit = baseline.get("git", {}).get("baseCommit")
    if not isinstance(commit, str) or not re.fullmatch(r"[a-f0-9]{40}", commit):
        raise ValueError("recomposition baseline has no valid base commit")
    return commit


def _find_zig() -> Path:
    candidates = sorted((REPO_ROOT / ".tooling").glob("zig-*/zig"))
    workspace_root = REPO_ROOT.parent
    candidates.extend(sorted((workspace_root / ".tooling").glob("zig-*/zig")))
    system_zig = shutil.which("zig")
    if system_zig:
        candidates.append(Path(system_zig))
    if not candidates:
        raise RuntimeError("Zig executable not found")
    return candidates[-1].resolve()


def _materialize_baseline(commit: str, destination: Path) -> Path:
    destination.mkdir(parents=True, exist_ok=True)
    archive = _run(
        ["git", "archive", "--format=tar", commit, *ARCHIVE_PATHS],
        REPO_ROOT,
    ).stdout
    archive_path = destination / "baseline.tar"
    archive_path.write_bytes(archive)
    with tarfile.open(archive_path, mode="r:") as handle:
        handle.extractall(destination, filter="data")
    archive_path.unlink()
    snapshot = destination / "runtime/zig"
    if not (snapshot / "build.zig").is_file():
        raise RuntimeError("materialized baseline has no runtime build")
    return snapshot


def _build_runtime(
    zig: Path,
    runtime_root: Path,
    build_root: Path,
) -> Path:
    prefix = build_root / "prefix"
    _run(
        [
            str(zig),
            "build",
            "doe-runtime",
            "-Doptimize=ReleaseSafe",
            "-j1",
            "--seed",
            "0",
            "--summary",
            "none",
            "--cache-dir",
            str(build_root / "cache"),
            "--global-cache-dir",
            str(build_root / "global-cache"),
            "--prefix",
            str(prefix),
        ],
        runtime_root,
    )
    binary = prefix / "bin/doe-zig-runtime"
    if not binary.is_file():
        raise RuntimeError("runtime build did not produce doe-zig-runtime")
    return binary


def _runtime_command(
    binary: Path,
    execution_root: Path,
    trace_path: Path,
    trace_meta_path: Path,
    pipeline_cache: Path,
) -> list[str]:
    return [
        str(binary),
        "--commands",
        str(execution_root / COMMAND_PATH),
        "--quirks",
        str(execution_root / QUIRKS_PATH),
        "--vendor",
        "amd",
        "--api",
        "vulkan",
        "--family",
        "gfx11",
        "--driver",
        "24.0.0",
        "--backend",
        "native",
        "--backend-lane",
        "vulkan_doe_comparable",
        "--execute",
        "--pipeline-cache-dir",
        str(pipeline_cache),
        "--queue-sync-mode",
        "per-command",
        "--webgpu-ffi-queue-wait-timeout-ns",
        "10000000000",
        "--upload-buffer-usage",
        "copy-dst-copy-src",
        "--upload-submit-every",
        "1",
        "--gpu-timestamp-mode",
        "off",
        "--trace-jsonl",
        str(trace_path),
        "--trace-meta",
        str(trace_meta_path),
        "--kernel-root",
        str(execution_root / "bench/kernels"),
        "--validate-output-oracles",
    ]


def _without_timing(value: Any) -> Any:
    if isinstance(value, dict):
        return {
            key: _without_timing(item)
            for key, item in sorted(value.items())
            if not key.endswith("Ns")
        }
    if isinstance(value, list):
        return [_without_timing(item) for item in value]
    return value


def _canonical_sha256(value: Any) -> str:
    return hashlib.sha256(canonical_json(value).encode("utf-8")).hexdigest()


def _copy_evidence(source: Path, destination: Path) -> dict[str, str]:
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    return {
        "path": destination.relative_to(REPO_ROOT).as_posix(),
        "sha256": sha256_file(destination),
    }


def _run_side(
    side: str,
    binary: Path,
    execution_root: Path,
    temporary_root: Path,
    raw_root: Path,
    env: dict[str, str],
) -> dict[str, Any]:
    side_temporary = temporary_root / side
    side_temporary.mkdir(parents=True, exist_ok=True)
    trace_path = side_temporary / "trace.jsonl"
    trace_meta_path = side_temporary / "trace-meta.json"
    normalized_command = _run(
        [
            str(binary),
            "--commands",
            str(execution_root / COMMAND_PATH),
            "--emit-normalized",
        ],
        execution_root,
        env=env,
    ).stdout
    _run(
        _runtime_command(
            binary,
            execution_root,
            trace_path,
            trace_meta_path,
            side_temporary / "pipeline-cache",
        ),
        execution_root,
        env=env,
    )
    trace_rows = [
        json.loads(line)
        for line in trace_path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    if len(trace_rows) != 1 or not isinstance(trace_rows[0], dict):
        raise ValueError(f"{side} execution did not emit one trace row")
    trace_meta = _load_object(trace_meta_path)
    if trace_meta.get("outputOracleMatchedCount") != 1:
        raise ValueError(f"{side} output oracle did not match")
    if trace_meta.get("outputOracleFailedCount") != 0:
        raise ValueError(f"{side} output oracle failed")
    if trace_meta.get("executionSuccessCount") != 1:
        raise ValueError(f"{side} execution was not successful")
    manifest_relative = trace_meta.get("shaderArtifactManifestPath")
    if not isinstance(manifest_relative, str):
        raise ValueError(f"{side} shader artifact manifest path is missing")
    manifest_path = execution_root / manifest_relative
    manifest = _load_object(manifest_path)
    if manifest.get("hash") != trace_meta.get("shaderArtifactManifestHash"):
        raise ValueError(f"{side} shader artifact identity mismatch")
    spirv_stages = [
        stage
        for stage in manifest.get("stages", [])
        if isinstance(stage, dict) and stage.get("stage") == "ir_to_spirv"
    ]
    if len(spirv_stages) != 1:
        raise ValueError(f"{side} shader manifest has no unique SPIR-V stage")
    spirv_path = manifest_path.parent / spirv_stages[0]["artifactPath"]
    if sha256_file(spirv_path) != spirv_stages[0].get("artifactSha256"):
        raise ValueError(f"{side} SPIR-V artifact identity mismatch")

    raw_side = raw_root / side
    public_evidence = {
        "binarySha256": sha256_file(binary),
        "shaderArtifactManifest": _copy_evidence(
            manifest_path,
            raw_side / "shader-artifact-manifest.json",
        ),
        "spirvArtifact": _copy_evidence(
            spirv_path,
            raw_side / "shader-artifact.spv",
        ),
        "trace": _copy_evidence(trace_path, raw_side / "trace.jsonl"),
        "traceMeta": _copy_evidence(trace_meta_path, raw_side / "trace-meta.json"),
    }
    artifact_identity = {
        "manifestFileSha256": sha256_file(manifest_path),
        "manifestHash": manifest["hash"],
        "spirvSha256": sha256_file(spirv_path),
        "wgslSha256": manifest["wgslSha256"],
        "irSha256": manifest["irSha256"],
    }
    return {
        "artifactDigest": _canonical_sha256(artifact_identity),
        "normalizedCommandSha256": hashlib.sha256(normalized_command).hexdigest(),
        "public": public_evidence,
        "receiptIdentitySha256": _canonical_sha256(_without_timing(trace_meta)),
        "traceMeta": trace_meta,
        "traceRow": trace_rows[0],
    }


def _vulkan_host(icd_path: Path) -> tuple[dict[str, str], dict[str, str]]:
    if not icd_path.is_file():
        raise ValueError(f"Vulkan ICD does not exist: {icd_path}")
    env = dict(os.environ)
    env["VK_ICD_FILENAMES"] = str(icd_path.resolve())
    summary = _run(["vulkaninfo", "--summary"], REPO_ROOT, env=env)
    content = (summary.stdout + summary.stderr).decode("utf-8", errors="replace")
    fields = {
        match.group("name"): match.group("value")
        for match in FIELD_RE.finditer(content)
    }
    device_type = fields.get("deviceType", "")
    device_name = fields.get("deviceName", "")
    if device_type not in {
        "PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU",
        "PHYSICAL_DEVICE_TYPE_DISCRETE_GPU",
    }:
        raise ValueError(f"Vulkan ICD did not expose a physical GPU: {device_type}")
    if "llvmpipe" in device_name.lower():
        raise ValueError("Vulkan ICD exposed a prohibited software renderer")
    return env, {
        "architecture": platform.machine(),
        "deviceName": device_name,
        "deviceType": device_type,
        "driverInfo": fields.get("driverInfo", ""),
        "driverName": fields.get("driverName", ""),
        "operatingSystem": platform.system(),
        "release": platform.release(),
        "vulkanIcdPath": str(icd_path.resolve()),
        "vulkanIcdSha256": sha256_file(icd_path),
    }


def _comparison(left: str, right: str) -> dict[str, object]:
    return {
        "baselineSha256": left,
        "candidateSha256": right,
        "equal": left == right,
    }


def capture(
    icd_path: Path,
    output_path: Path,
    raw_root: Path,
) -> dict[str, Any]:
    baseline_commit = _baseline_commit()
    candidate_commit = _git_text("rev-parse", "HEAD")
    runtime_changes = _git_text(
        "status",
        "--porcelain",
        "--",
        "runtime/zig/src",
        "runtime/zig/build.zig",
        "runtime/zig/build.zig.zon",
    )
    if runtime_changes:
        raise ValueError("runtime Zig worktree must be clean before equivalence capture")
    baseline_tree = _git_text("rev-parse", f"{baseline_commit}:runtime/zig/src")
    candidate_tree = _git_text("rev-parse", f"{candidate_commit}:runtime/zig/src")
    env, host = _vulkan_host(icd_path)
    zig = _find_zig()

    with tempfile.TemporaryDirectory(
        prefix="doe-kernel-dispatch-equivalence-"
    ) as temporary:
        temporary_root = Path(temporary)
        baseline_runtime = _materialize_baseline(
            baseline_commit,
            temporary_root / "baseline-source",
        )
        baseline_execution_root = baseline_runtime.parents[1]
        baseline_binary = _build_runtime(
            zig,
            baseline_runtime,
            temporary_root / "baseline-build",
        )
        candidate_binary = _build_runtime(
            zig,
            RUNTIME_ROOT,
            temporary_root / "candidate-build",
        )
        baseline = _run_side(
            "baseline",
            baseline_binary,
            baseline_execution_root,
            temporary_root,
            raw_root,
            env,
        )
        candidate = _run_side(
            "candidate",
            candidate_binary,
            REPO_ROOT,
            temporary_root,
            raw_root,
            env,
        )

    baseline_meta = baseline["traceMeta"]
    candidate_meta = candidate["traceMeta"]
    baseline_row = baseline["traceRow"]
    candidate_row = candidate["traceRow"]
    error_equal = all(
        baseline_row.get(field) == candidate_row.get(field)
        for field in (
            "executionStatus",
            "executionStatusCode",
            "executionStatusMessage",
        )
    )
    output_equal = (
        baseline_meta.get("outputOracleExpectedSha256")
        == baseline_meta.get("outputOracleActualSha256")
        == candidate_meta.get("outputOracleActualSha256")
    )
    trace_equal = (
        baseline_meta.get("hash") == candidate_meta.get("hash")
        and baseline_meta.get("previousHash") == candidate_meta.get("previousHash")
    )
    comparisons = {
        "artifactDigests": _comparison(
            baseline["artifactDigest"],
            candidate["artifactDigest"],
        ),
        "errorSemantics": {
            "baselineStatus": baseline_row["executionStatus"],
            "baselineStatusCode": baseline_row["executionStatusCode"],
            "baselineStatusMessage": baseline_row["executionStatusMessage"],
            "candidateStatus": candidate_row["executionStatus"],
            "candidateStatusCode": candidate_row["executionStatusCode"],
            "candidateStatusMessage": candidate_row["executionStatusMessage"],
            "equal": error_equal,
        },
        "normalizedCommand": _comparison(
            baseline["normalizedCommandSha256"],
            candidate["normalizedCommandSha256"],
        ),
        "normalizedOutput": {
            "baselineActualSha256": baseline_meta["outputOracleActualSha256"],
            "candidateActualSha256": candidate_meta["outputOracleActualSha256"],
            "equal": output_equal,
            "expectedSha256": baseline_meta["outputOracleExpectedSha256"],
        },
        "receiptIdentity": _comparison(
            baseline["receiptIdentitySha256"],
            candidate["receiptIdentitySha256"],
        ),
        "traceIdentity": {
            "baselineHash": baseline_meta["hash"],
            "baselinePreviousHash": baseline_meta["previousHash"],
            "candidateHash": candidate_meta["hash"],
            "candidatePreviousHash": candidate_meta["previousHash"],
            "equal": trace_equal,
        },
    }
    exact = all(comparison["equal"] for comparison in comparisons.values())
    payload = {
        "artifactKind": "recomposition-kernel-dispatch-equivalence",
        "baseline": {
            **baseline["public"],
            "commit": baseline_commit,
            "runtimeSourceTreeHash": baseline_tree,
        },
        "candidate": {
            **candidate["public"],
            "commit": candidate_commit,
            "runtimeSourceTreeHash": candidate_tree,
        },
        "classification": "exact-equivalence" if exact else "failure",
        "comparisons": comparisons,
        "excludedVolatileFields": ["JSON object keys ending in Ns"],
        "generatedAt": datetime.now(timezone.utc).isoformat().replace(
            "+00:00", "Z"
        ),
        "host": host,
        "schemaVersion": 1,
        "status": "passed" if exact else "failed",
        "toolchain": {
            "sha256": sha256_file(zig),
            "version": _run([str(zig), "version"], RUNTIME_ROOT)
            .stdout.decode("ascii")
            .strip(),
        },
        "workload": {
            "commandPath": COMMAND_PATH.as_posix(),
            "commandSha256": sha256_file(REPO_ROOT / COMMAND_PATH),
            "kernelPath": KERNEL_PATH.as_posix(),
            "kernelSha256": sha256_file(REPO_ROOT / KERNEL_PATH),
            "workloadId": WORKLOAD_ID,
        },
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(canonical_json(payload), encoding="utf-8")
    return payload


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vulkan-icd", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=OUTPUT_PATH)
    parser.add_argument("--raw-root", type=Path, default=RAW_ROOT)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        payload = capture(
            args.vulkan_icd.resolve(),
            args.output.resolve(),
            args.raw_root.resolve(),
        )
    except (
        KeyError,
        OSError,
        RuntimeError,
        subprocess.SubprocessError,
        tarfile.TarError,
        ValueError,
        json.JSONDecodeError,
    ) as exc:
        print(f"kernel-dispatch equivalence capture failed: {exc}", file=sys.stderr)
        return 1
    if payload["status"] != "passed":
        print("kernel-dispatch equivalence capture failed: semantic mismatch", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
