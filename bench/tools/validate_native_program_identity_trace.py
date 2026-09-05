#!/usr/bin/env python3
"""Validate one Doe native program-identity journal and its SPIR-V artifacts."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

import jsonschema

REPO_ROOT = Path(__file__).resolve().parents[2]
if __name__ == "__main__" and not __package__:
    environment = os.environ.copy()
    environment['PYTHONPATH'] = os.pathsep.join(
        [str(REPO_ROOT), *([environment['PYTHONPATH']] if environment.get('PYTHONPATH') else [])]
    )
    os.execve(sys.executable,
              [sys.executable, '-m', 'bench.tools.validate_native_program_identity_trace', *sys.argv[1:]],
              environment)

from bench.lib.hash_utils import file_sha256
from bench.lib.native_program_replay import validate_gpu_replays


DEFAULT_SCHEMA = REPO_ROOT / "config/native-program-identity-trace-row.schema.json"
DEFAULT_SPIRV_VAL = Path("/usr/bin/spirv-val")
ARTIFACT_PREFIX = "doe-native-vulkan-"
ARTIFACT_SUFFIX = ".spv"
RENDER_COMPLETION = "internal_submit_and_wait_succeeded"


def stable_sha256(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def repo_path(path: Path) -> str:
    resolved = path.resolve()
    try:
        return resolved.relative_to(REPO_ROOT).as_posix()
    except ValueError as exc:
        raise ValueError(f"path escapes repository: {path}") from exc


def file_ref(path: Path) -> dict[str, str]:
    return {"path": repo_path(path), "sha256": file_sha256(path)}


def load_rows(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        value = json.loads(line)
        if not isinstance(value, dict):
            raise ValueError(f"trace line {line_number} is not an object")
        rows.append(value)
    if not rows:
        raise ValueError("trace contains no rows")
    return rows


def artifact_bindings(rows: list[dict[str, Any]]) -> list[tuple[str, str, str]]:
    bindings: list[tuple[str, str, str]] = []
    for row in rows:
        if row.get("event") == "dispatch_encoded":
            bindings.append((
                "compute",
                str(row.get("backendArtifactFile", "")),
                str(row.get("backendArtifactSha256", "")),
            ))
        elif row.get("event") == "render_draw_executed":
            bindings.extend((
                (
                    "vertex",
                    str(row.get("vertexBackendArtifactFile", "")),
                    str(row.get("vertexBackendArtifactSha256", "")),
                ),
                (
                    "fragment",
                    str(row.get("fragmentBackendArtifactFile", "")),
                    str(row.get("fragmentBackendArtifactSha256", "")),
                ),
            ))
    return bindings


def build_validation(
    trace_path: Path,
    *,
    row_schema_path: Path = DEFAULT_SCHEMA,
    artifact_root: Path | None = None,
    spirv_val_path: Path = DEFAULT_SPIRV_VAL,
    require_render_completion: bool = False,
) -> dict[str, Any]:
    trace_path = trace_path.resolve()
    row_schema_path = row_schema_path.resolve()
    artifact_root = (artifact_root or trace_path.parent).resolve()
    spirv_val_path = spirv_val_path.resolve()
    rows = load_rows(trace_path)
    row_schema = json.loads(row_schema_path.read_text(encoding="utf-8"))
    failures: list[str] = []

    schema_valid = True
    for index, row in enumerate(rows):
        try:
            jsonschema.validate(row, row_schema)
        except jsonschema.ValidationError as exc:
            schema_valid = False
            failures.append(f"row_{index}_schema_invalid:{exc.message}")

    per_process_sequences: dict[int, list[int]] = {}
    for row in rows:
        process_id = row.get("processId")
        sequence = row.get("sequence")
        if isinstance(process_id, int) and isinstance(sequence, int):
            per_process_sequences.setdefault(process_id, []).append(sequence)
    sequence_valid = all(
        sequences == sorted(sequences) and len(sequences) == len(set(sequences))
        for sequences in per_process_sequences.values()
    )
    if not sequence_valid:
        failures.append("process_sequence_invalid")

    dispatch_rows = [row for row in rows if row.get("event") == "dispatch_encoded"]
    render_rows = [row for row in rows if row.get("event") == "render_draw_executed"]
    submission_rows = [row for row in rows if row.get("event") == "submission_succeeded"]
    replay_valid = True
    replay_dispatches: set[tuple[int, int]] = set()
    try:
        for recording in validate_gpu_replays(rows):
            if recording['submissions']:
                replay_dispatches.update((row['processId'], row['sequence']) for row in recording['dispatches'])
    except (ValueError, KeyError) as error:
        replay_valid = False
        failures.append(f"compute_program_replay_invalid:{error}")
    compute_submission_valid = replay_valid and all(
        (dispatch.get('processId'), dispatch.get('sequence')) in replay_dispatches or any(
            submission.get("processId") == dispatch.get("processId")
            and isinstance(submission.get("sequence"), int)
            and isinstance(dispatch.get("sequence"), int)
            and submission["sequence"] > dispatch["sequence"]
            for submission in submission_rows
        )
        for dispatch in dispatch_rows
    )
    if not compute_submission_valid:
        failures.append("compute_dispatch_lacks_later_submission")
    submission_rows += [row for row in rows if row.get('event') == 'compute_program_submitted']

    render_completion_valid = (
        not require_render_completion
        or all(row.get("completion") == RENDER_COMPLETION for row in render_rows)
    )
    if not render_completion_valid:
        failures.append("render_draw_lacks_internal_completion")

    artifacts: list[dict[str, Any]] = []
    artifact_valid = True
    seen: set[tuple[str, str, str]] = set()
    for stage, filename, expected_sha256 in artifact_bindings(rows):
        binding = (stage, filename, expected_sha256)
        if binding in seen:
            continue
        seen.add(binding)
        valid_name = (
            filename == f"{ARTIFACT_PREFIX}{expected_sha256}{ARTIFACT_SUFFIX}"
            and len(expected_sha256) == 64
            and all(character in "0123456789abcdef" for character in expected_sha256)
        )
        artifact_path = (artifact_root / filename).resolve()
        try:
            artifact_path.relative_to(artifact_root)
        except ValueError:
            valid_name = False
        actual_sha256 = file_sha256(artifact_path) if artifact_path.is_file() else None
        validator = None
        if actual_sha256 is not None:
            validator = subprocess.run(
                [str(spirv_val_path), str(artifact_path)],
                check=False,
                capture_output=True,
                text=True,
            )
        valid = (
            valid_name
            and actual_sha256 == expected_sha256
            and validator is not None
            and validator.returncode == 0
        )
        if not valid:
            artifact_valid = False
            failures.append(f"backend_artifact_invalid:{stage}:{filename}")
        artifacts.append({
            "stage": stage,
            "path": repo_path(artifact_path),
            "expectedSha256": expected_sha256,
            "actualSha256": actual_sha256,
            "spirvValPassed": validator is not None and validator.returncode == 0,
        })

    checks = {
        "rowSchemaValid": schema_valid,
        "processSequenceValid": sequence_valid,
        "computeSubmissionValid": compute_submission_valid,
        "renderCompletionValid": render_completion_valid,
        "backendArtifactsValid": artifact_valid,
    }
    validation: dict[str, Any] = {
        "schemaVersion": 1,
        "artifactKind": "doe_native_program_identity_trace_validation",
        "inputs": {
            "trace": file_ref(trace_path),
            "rowSchema": file_ref(row_schema_path),
            "artifactRoot": repo_path(artifact_root),
            "spirvValidator": str(spirv_val_path),
            "requireRenderCompletion": require_render_completion,
        },
        "counts": {
            "rows": len(rows),
            "processes": len(per_process_sequences),
            "dispatches": len(dispatch_rows),
            "renderDraws": len(render_rows),
            "submissions": len(submission_rows),
            "artifacts": len(artifacts),
        },
        "checks": checks,
        "artifacts": artifacts,
        "verdict": {
            "status": "passed" if not failures else "failed",
            "failureCodes": failures,
            "claimBoundary": (
                "native journal schema, event sequence, completion, and exact SPIR-V bytes; "
                "not public-observer identity, output correctness, driver identity, or performance"
            ),
        },
    }
    validation["validationSha256"] = stable_sha256(validation)
    return validation


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--trace", required=True)
    parser.add_argument("--row-schema", default=str(DEFAULT_SCHEMA))
    parser.add_argument("--artifact-root")
    parser.add_argument("--spirv-val", default=str(DEFAULT_SPIRV_VAL))
    parser.add_argument("--require-render-completion", action="store_true")
    parser.add_argument("--out")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        validation = build_validation(
            Path(args.trace),
            row_schema_path=Path(args.row_schema),
            artifact_root=Path(args.artifact_root) if args.artifact_root else None,
            spirv_val_path=Path(args.spirv_val),
            require_render_completion=args.require_render_completion,
        )
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"FAIL: native program identity trace: {exc}", file=sys.stderr)
        return 1
    encoded = f"{json.dumps(validation, indent=2)}\n"
    if args.out:
        Path(args.out).write_text(encoded, encoding="utf-8")
    else:
        print(encoded, end="")
    return 0 if validation["verdict"]["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
