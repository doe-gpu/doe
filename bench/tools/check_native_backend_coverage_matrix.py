#!/usr/bin/env python3
"""Check native backend coverage matrix completeness and evidence discipline."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
from pathlib import PurePosixPath
from typing import Any

import jsonschema

ROOT = Path(__file__).resolve().parents[2]

REQUIRED_BACKENDS = {"doe_metal", "doe_vulkan", "doe_d3d12"}
REQUIRED_CLASSES = {
    "upload",
    "pipeline_creation",
    "compute",
    "readback",
    "small_command_stream",
    "cache_behavior",
    "concurrency",
    "tails",
}
EXPECTED_ARTIFACT_KINDS = {
    "upload": {"native_upload_path_receipts"},
    "pipeline_creation": {"native_pipeline_cache_receipts"},
    "compute": {"run-receipt", "native_command_graph_receipt"},
    "readback": {"run-receipt", "native_command_graph_receipt"},
    "small_command_stream": {"native_command_graph_receipt"},
    "cache_behavior": {"native_pipeline_cache_receipts"},
    "concurrency": {"run-receipt", "native_command_graph_receipt"},
    "tails": {"run-receipt", "native_command_graph_receipt"},
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--matrix", required=True, help="Native backend coverage matrix JSON.")
    parser.add_argument(
        "--verify-evidence-root",
        default="",
        help="Resolve relative covered-row evidence paths under this root and verify artifact kind.",
    )
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def load_json(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"expected JSON object: {path}")
    return payload


def failure(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def resolve_path(path_text: str, root: Path | None) -> Path:
    path = Path(path_text)
    if path.is_absolute() or root is None:
        return path
    return root / path


def safe_repo_path(path_text: str) -> bool:
    path = PurePosixPath(path_text)
    return bool(path_text) and not path.is_absolute() and ".." not in path.parts


def is_example(path_text: str) -> bool:
    path = PurePosixPath(path_text)
    return 'examples' in path.parts or '.sample.' in path.name


def verify_bound_file(path_text: str, expected: str, root: Path) -> Path:
    if not safe_repo_path(path_text) or is_example(path_text):
        raise ValueError(f'expected retained repository evidence, got {path_text!r}')
    path = (root / path_text).resolve()
    if not path.is_relative_to(root.resolve()):
        raise ValueError(f'evidence symlink escapes repository: {path_text}')
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != expected:
        raise ValueError(f'evidence hash mismatch: {path_text}')
    return path


def verify_execution(payload: dict[str, Any], backend: str, root: Path) -> None:
    """Require the artifact's actual execution identity, not a receipt label."""
    if payload.get('artifactKind') != 'run-receipt':
        path = verify_bound_file(str(payload.get('runReceiptPath', '')),
                                 str(payload.get('runReceiptSha256', '')), root)
        payload = load_json(path)
    schema = load_json(ROOT / 'config/run-receipt.schema.json')
    jsonschema.Draft202012Validator(schema).validate(payload)
    identity = payload['runtimeIdentity']
    if (identity['executionBackend'] != backend or identity['providerId'] != 'doe'
            or payload['hostIdentity']['api'] != backend.removeprefix('doe_')):
        raise ValueError('execution provider/backend differs from coverage row')
    execution = payload['execution']
    samples = payload['samples']
    if (execution['success'] is not True or execution['timedSampleCount'] <= 0
            or not samples or any(sample['success'] is not True or sample['returnCode'] != 0
                                  for sample in samples)):
        raise ValueError('coverage requires successful physical execution samples')
    if not payload['hostIdentity']['driver'] or not payload['hostIdentity']['adapter']['description']:
        raise ValueError('coverage requires an identified adapter and driver')
    verify_bound_file(identity['binaryPath'], identity['binarySha256'], root)
    for sample in samples:
        for key in ('jsonlPath', 'metaPath'):
            path = sample['traceArtifacts'].get(key, '')
            if not safe_repo_path(path) or is_example(path) or not (root / path).is_file():
                raise ValueError(f'coverage requires retained native trace artifacts: {path!r}')
        meta_path = root / sample['traceArtifacts']['metaPath']
        trace_path = root / sample['traceArtifacts']['jsonlPath']
        meta = load_json(meta_path)
        if (meta.get('executionBackend') != backend or meta.get('fallbackUsed') is not False
                or meta.get('executionRowCount', 0) <= 0
                or meta.get('executionSuccessCount') != meta.get('executionRowCount')
                or any(meta.get(key) != 0 for key in ('executionErrorCount', 'executionSkippedCount',
                                                    'executionUnsupportedCount'))):
            raise ValueError('native trace lacks successful matched-backend work without fallback')
        if any(sample.get('traceMeta', {}).get(key) != meta.get(key)
               for key in ('hash', 'previousHash', 'rowCount', 'executionBackend')):
            raise ValueError('retained trace metadata differs from the bound execution receipt')
        replay = subprocess.run([sys.executable, str(ROOT / 'pipeline/trace/replay.py'),
                                 '--trace-meta', str(meta_path), '--trace-jsonl', str(trace_path)],
                                capture_output=True, text=True, check=False)
        if replay.returncode:
            raise ValueError(f'native trace replay failed: {replay.stdout or replay.stderr}')
        rows = [json.loads(line) for line in trace_path.read_text(encoding='utf-8').splitlines()
                if line.strip()]
        executed = [item for item in rows if 'executionStatus' in item]
        if (len(executed) != meta['executionRowCount']
                or any(item['executionStatus'] != 'ok' or item.get('executionBackend') != backend
                       for item in executed)
                or sum(item.get('executionDispatchCount', 0) for item in executed)
                != meta.get('executionDispatchCount')
                or sum(item.get('executionSubmitCount', 0) for item in executed)
                != meta.get('executionSubmitCount')):
            raise ValueError('native trace work differs from execution totals')


def check_evidence_file(
    row: dict[str, Any],
    row_path: str,
    evidence_root: Path | None,
) -> list[dict[str, str]]:
    if row.get("status") != "covered":
        return []
    evidence_path = row.get("evidencePath")
    if not isinstance(evidence_path, str) or not evidence_path:
        return []
    if not safe_repo_path(evidence_path):
        return [failure("unsafe_evidence_path", f"{row_path}.evidencePath", "evidencePath must be repo-relative")]
    if is_example(evidence_path):
        return [failure('example_is_not_evidence', f'{row_path}.evidencePath',
                        'schema examples cannot establish physical backend coverage')]
    if not re.fullmatch('[a-f0-9]{64}', str(row.get('evidenceSha256', ''))):
        return [failure('covered_row_missing_hash', f'{row_path}.evidenceSha256',
                        'covered rows require the retained artifact hash')]
    if evidence_root is None:
        return []
    resolved = resolve_path(evidence_path, evidence_root)
    if not resolved.is_file():
        return [failure("evidence_file_missing", f"{row_path}.evidencePath", f"evidence file not found: {evidence_path}")]
    try:
        payload = load_json(resolved)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        return [failure("evidence_file_invalid", f"{row_path}.evidencePath", str(exc))]
    expected_kinds = EXPECTED_ARTIFACT_KINDS.get(str(row.get("coverageClass", "")), set())
    artifact_kind = payload.get("artifactKind")
    if expected_kinds and artifact_kind not in expected_kinds:
        return [
            failure(
                "evidence_artifact_kind_mismatch",
                f"{row_path}.evidencePath",
                f"expected one of {sorted(expected_kinds)}, got {artifact_kind!r}",
            )
        ]
    try:
        verify_bound_file(evidence_path, row['evidenceSha256'], evidence_root)
        verify_execution(payload, row['backend'], evidence_root)
    except (OSError, ValueError, KeyError, jsonschema.ValidationError) as exc:
        return [failure('evidence_execution_invalid', f'{row_path}.evidencePath', str(exc))]
    return []


def check_matrix(payload: dict[str, Any], evidence_root: Path | None = None) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    seen: set[tuple[str, str]] = set()
    for index, row in enumerate(row for row in payload.get("rows", []) if isinstance(row, dict)):
        row_path = f"rows[{index}]"
        key = (str(row.get("backend", "")), str(row.get("coverageClass", "")))
        if key in seen:
            failures.append(failure("duplicate_coverage_row", row_path, f"duplicate coverage row {key}"))
        seen.add(key)
        status = row.get("status")
        if status == "covered" and not row.get("evidencePath"):
            failures.append(failure("covered_row_missing_evidence", f"{row_path}.evidencePath", "covered rows require evidencePath"))
        if status != "covered" and not row.get("reasonCode"):
            failures.append(failure("diagnostic_row_missing_reason", f"{row_path}.reasonCode", "diagnostic and missing rows require reasonCode"))
        if status == "covered" and row.get("reasonCode"):
            failures.append(failure("covered_row_has_reason", f"{row_path}.reasonCode", "covered rows must not carry reasonCode"))
        failures.extend(check_evidence_file(row, row_path, evidence_root))

    for backend in sorted(REQUIRED_BACKENDS):
        for coverage_class in sorted(REQUIRED_CLASSES):
            if (backend, coverage_class) not in seen:
                failures.append(failure("missing_coverage_row", "rows", f"missing coverage row {backend}:{coverage_class}"))
    return failures


def main() -> int:
    args = parse_args()
    evidence_root = Path(args.verify_evidence_root).resolve() if args.verify_evidence_root else ROOT
    failures = check_matrix(load_json(Path(args.matrix)), evidence_root)
    report = {
        "schemaVersion": 1,
        "artifactKind": "native_backend_coverage_matrix_check",
        "status": "fail" if failures else "pass",
        "failures": failures,
    }
    if args.emit_json:
        print(json.dumps(report, indent=2))
    elif failures:
        print("FAIL: native backend coverage matrix")
        for item in failures:
            print(f"- {item['code']}: {item['path']}: {item['message']}")
    else:
        print("PASS: native backend coverage matrix")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
