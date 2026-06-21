#!/usr/bin/env python3
"""Validate shader artifact manifests referenced by trace metadata."""

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
import subprocess
from typing import Any

from bench.lib.bench_utils import load_json_object as load_json
from native_compare_modules import contracts


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", default="bench/out/dawn-vs-doe.json")
    parser.add_argument("--schema", default="config/shader-artifact.schema.json")
    parser.add_argument(
        "--require-manifest",
        action="store_true",
        help="Fail when shader manifest is missing for successful baseline-side samples.",
    )
    parser.add_argument(
        "--spirv-val",
        default="",
        help="Optional spirv-val executable used to validate SPIR-V artifacts.",
    )
    parser.add_argument(
        "--require-spirv-validation",
        action="store_true",
        help="Fail when SPIR-V artifacts are present but no validator is configured.",
    )
    return parser.parse_args()


def load_json_file(path: Path) -> dict[str, Any] | None:
    try:
        return load_json(path)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
        return None


def workload_side_payload(workload: dict[str, Any], side: str) -> dict[str, Any]:
    inline = workload.get(side)
    if isinstance(inline, dict):
        return inline

    receipts = workload.get("receipts")
    if not isinstance(receipts, dict):
        return {}

    receipt_key = "left" if side == "baseline" else "right"
    receipt = receipts.get(receipt_key)
    if not isinstance(receipt, dict):
        return {}

    path_value = receipt.get("path")
    if not isinstance(path_value, str) or not path_value:
        return {}

    payload = load_json_file(Path(path_value))
    if isinstance(payload, dict):
        return payload
    return {}


def side_command_samples(side_payload: dict[str, Any]) -> list[Any]:
    command_samples = side_payload.get("commandSamples")
    if isinstance(command_samples, list):
        return command_samples
    samples = side_payload.get("samples")
    if isinstance(samples, list):
        return samples
    return []


def sample_trace_meta_path(sample: dict[str, Any]) -> Path | None:
    trace_meta_path = sample.get("traceMetaPath")
    if isinstance(trace_meta_path, str) and trace_meta_path:
        return Path(trace_meta_path)

    trace_artifacts = sample.get("traceArtifacts")
    if isinstance(trace_artifacts, dict):
        meta_path = trace_artifacts.get("metaPath")
        if isinstance(meta_path, str) and meta_path:
            return Path(meta_path)
    return None


def sample_trace_meta(sample: dict[str, Any]) -> dict[str, Any] | None:
    inline = sample.get("traceMeta")
    if isinstance(inline, dict):
        return inline

    path = sample_trace_meta_path(sample)
    if path is None:
        return None
    return load_json_file(path)


def is_spirv_artifact_stage(stage: dict[str, Any]) -> bool:
    stage_name = stage.get("stage")
    if not isinstance(stage_name, str):
        return False
    if "spirv" not in stage_name:
        return False
    return not stage_name.endswith("validate")


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    args = parse_args()
    report = load_json(Path(args.report))
    schema = contracts.load_schema(Path(args.schema))

    failures: list[str] = []
    validated = 0
    spirv_validated = 0

    workloads = report.get("workloads")
    if not isinstance(workloads, list):
        print("FAIL: invalid report workloads")
        return 1

    for workload in workloads:
        if not isinstance(workload, dict):
            continue
        workload_id = str(workload.get("id", "unknown"))
        baseline = workload_side_payload(workload, "baseline")
        if not baseline:
            if args.require_manifest:
                failures.append(f"{workload_id}: missing baseline payload")
            continue
        samples = side_command_samples(baseline)
        if not samples:
            if args.require_manifest:
                failures.append(f"{workload_id}: missing baseline samples")
            continue
        for sample in samples:
            if not isinstance(sample, dict):
                continue
            if sample.get("returnCode") != 0:
                continue
            trace_meta = sample_trace_meta(sample)
            if not isinstance(trace_meta, dict):
                continue

            manifest_path_raw = trace_meta.get("shaderArtifactManifestPath")
            if not isinstance(manifest_path_raw, str) or not manifest_path_raw:
                if args.require_manifest:
                    failures.append(f"{workload_id}: missing shaderArtifactManifestPath")
                continue
            manifest_path = Path(manifest_path_raw)
            manifest_errors = contracts.validate_manifest(manifest_path, schema)
            if manifest_errors:
                for err in manifest_errors:
                    failures.append(f"{workload_id}: {err}")
            else:
                validated += 1
                manifest = load_json(manifest_path)
                expected_manifest_hash = trace_meta.get("shaderArtifactManifestHash")
                actual_manifest_hash = manifest.get("hash")
                if (
                    isinstance(expected_manifest_hash, str)
                    and expected_manifest_hash
                    and actual_manifest_hash != expected_manifest_hash
                ):
                    failures.append(
                        f"{workload_id}: manifest hash mismatch for {manifest_path}: "
                        f"trace={expected_manifest_hash} manifest={actual_manifest_hash}"
                    )
                spirv_failures, spirv_count = validate_spirv_artifacts(
                    manifest_path,
                    manifest,
                    args.spirv_val.strip(),
                    args.require_spirv_validation,
                )
                failures.extend(f"{workload_id}: {item}" for item in spirv_failures)
                spirv_validated += spirv_count

    if failures:
        print("FAIL: shader artifact gate")
        for item in failures:
            print(f"  {item}")
        return 1

    print(
        f"PASS: shader artifact gate (validated={validated}, spirvValidated={spirv_validated})"
    )
    return 0


def validate_spirv_artifacts(
    manifest_path: Path,
    manifest: dict[str, Any],
    spirv_val: str,
    require_spirv_validation: bool,
) -> tuple[list[str], int]:
    stages = manifest.get("stages")
    if not isinstance(stages, list):
        return [], 0

    failures: list[str] = []
    validated = 0
    saw_spirv_output = isinstance(manifest.get("spirvSha256"), str)
    saw_spirv_stage = False
    for stage in stages:
        if not isinstance(stage, dict):
            continue
        if not is_spirv_artifact_stage(stage):
            continue
        saw_spirv_stage = True
        artifact_path = stage.get("artifactPath")
        if not isinstance(artifact_path, str) or not artifact_path:
            if require_spirv_validation:
                failures.append("SPIR-V stage missing artifactPath for validation")
            continue
        resolved_artifact_path = artifact_path
        if not Path(artifact_path).is_absolute():
            resolved_artifact_path = str((manifest_path.parent / artifact_path).resolve())
        resolved_path = Path(resolved_artifact_path)
        try:
            actual_hash = file_sha256(resolved_path)
        except OSError as exc:
            failures.append(f"SPIR-V artifact unreadable {resolved_artifact_path}: {exc}")
            continue
        declared_stage_hash = stage.get("artifactSha256")
        if declared_stage_hash != actual_hash:
            failures.append(
                "SPIR-V stage artifactSha256 mismatch for "
                f"{resolved_artifact_path}: declared={declared_stage_hash} actual={actual_hash}"
            )
        declared_manifest_hash = manifest.get("spirvSha256")
        if declared_manifest_hash != actual_hash:
            failures.append(
                "SPIR-V manifest spirvSha256 mismatch for "
                f"{resolved_artifact_path}: declared={declared_manifest_hash} actual={actual_hash}"
            )
        if not spirv_val:
            if require_spirv_validation:
                failures.append("SPIR-V stage present but --spirv-val not provided")
            continue
        completed = subprocess.run(
            [spirv_val, resolved_artifact_path],
            capture_output=True,
            text=True,
            check=False,
        )
        if completed.returncode != 0:
            stderr = completed.stderr.strip() or completed.stdout.strip() or "spirv-val failed"
            failures.append(f"spirv-val failed for {resolved_artifact_path}: {stderr}")
            continue
        validated += 1
    if require_spirv_validation and saw_spirv_output and not saw_spirv_stage:
        failures.append("SPIR-V artifact present but manifest has no SPIR-V artifact stage")
    return failures, validated


if __name__ == "__main__":
    raise SystemExit(main())
