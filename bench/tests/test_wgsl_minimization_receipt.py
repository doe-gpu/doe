#!/usr/bin/env python3
"""Tests for WGSL corpus failure minimization receipts."""

from __future__ import annotations

import json
import re
import tempfile
from pathlib import Path

import jsonschema
try:
    import pytest
except ModuleNotFoundError:
    pytest = None

from bench.tools import check_wgsl_minimization_receipt as check_minimize
from bench.tools import minimize_wgsl_corpus_failure as minimize


REPO_ROOT = Path(__file__).resolve().parents[2]
MANIFEST_PATH = REPO_ROOT / "config" / "wgsl-browser-corpus.json"
TAXONOMY_PATH = REPO_ROOT / "config" / "shader-error-taxonomy.json"
SCHEMA_PATH = REPO_ROOT / "config" / "wgsl-minimization-receipt.schema.json"
SAMPLE_PATH = REPO_ROOT / "examples" / "wgsl-minimization-receipt.sample.json"


def _load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


class _Raises:
    def __init__(self, expected: type[BaseException], match: str) -> None:
        self.expected = expected
        self.match = match

    def __enter__(self) -> "_Raises":
        return self

    def __exit__(self, exc_type, exc, tb) -> bool:
        if exc_type is None:
            raise AssertionError(f"{self.expected.__name__} was not raised")
        if not issubclass(exc_type, self.expected):
            return False
        if self.match and re.search(self.match, str(exc)) is None:
            raise AssertionError(
                f"exception message {str(exc)!r} did not match {self.match!r}"
            )
        return True


def _raises(expected: type[BaseException], *, match: str):
    if pytest is not None:
        return pytest.raises(expected, match=match)
    return _Raises(expected, match)


def test_wgsl_minimization_receipt_preserves_source_identity() -> None:
    with tempfile.TemporaryDirectory() as tmpdir:
        receipt = minimize.build_receipt(
            manifest=_load(MANIFEST_PATH),
            manifest_path="config/wgsl-browser-corpus.json",
            taxonomy=_load(TAXONOMY_PATH),
            shader_id="invalid-missing-return",
            taxonomy_code="wgsl_sema_failed",
            failure_stage="sema",
            diagnostic_category="control_flow",
            backend_targets=["msl"],
            diagnostic_line=3,
            context_lines=1,
            out_dir=Path(tmpdir),
        )

    jsonschema.Draft202012Validator(_load(SCHEMA_PATH)).validate(receipt)
    parent_hash = receipt["source"]["normalizedSourceSha256"]
    assert receipt["minimizationPolicy"] == {
        "candidateStatus": "pending_replay",
        "preservesOriginalIdentity": True,
        "freeFormDiagnosticCompared": False,
        "replayRequired": True,
    }
    assert {row["transformation"] for row in receipt["candidates"]} >= {
        "normalized_original",
        "drop_local_declarations",
    }
    assert all(row["parentSourceSha256"] == parent_hash for row in receipt["candidates"])
    assert all(row["status"] == "pending_replay" for row in receipt["candidates"])
    assert check_minimize.check_receipt(receipt) == []


def test_wgsl_minimization_checker_accepts_sample() -> None:
    assert check_minimize.check_receipt(_load(SAMPLE_PATH)) == []


def test_wgsl_minimization_checker_verifies_sample_files() -> None:
    assert check_minimize.check_receipt(_load(SAMPLE_PATH), REPO_ROOT) == []


def test_wgsl_minimization_checker_rejects_unsafe_source_path() -> None:
    receipt = _load(SAMPLE_PATH)
    receipt["source"]["sourcePath"] = "../invalid/missing-return.wgsl"

    assert {
        "code": "unsafe_source_path",
        "path": "source.sourcePath",
        "message": "sourcePath must be repo-relative",
    } in check_minimize.check_receipt(receipt, REPO_ROOT)


def test_wgsl_minimization_checker_rejects_candidate_path_escape(tmp_path: Path) -> None:
    receipt = _load(SAMPLE_PATH)
    receipt["candidates"][0]["candidatePath"] = "../minimized/candidate.wgsl"

    assert {
        "code": "unsafe_candidate_path",
        "path": "candidates[0].candidatePath",
        "message": "candidatePath must resolve under verify-files-root",
    } in check_minimize.check_receipt(receipt, tmp_path)


def test_wgsl_minimization_checker_rejects_parent_hash_drift() -> None:
    receipt = _load(SAMPLE_PATH)
    receipt["candidates"][0]["parentSourceSha256"] = "0" * 64

    assert {
        "code": "parent_hash_mismatch",
        "path": "candidates[0].parentSourceSha256",
        "message": "candidate parent hash must match source hash",
    } in check_minimize.check_receipt(receipt)


def test_wgsl_minimization_rejects_unknown_shader_id() -> None:
    with tempfile.TemporaryDirectory() as tmpdir:
        with _raises(ValueError, match="shader id 'missing' not found"):
            minimize.build_receipt(
                manifest=_load(MANIFEST_PATH),
                manifest_path="config/wgsl-browser-corpus.json",
                taxonomy=_load(TAXONOMY_PATH),
                shader_id="missing",
                taxonomy_code="wgsl_sema_failed",
                failure_stage="sema",
                diagnostic_category="control_flow",
                backend_targets=["msl"],
                diagnostic_line=None,
                context_lines=1,
                out_dir=Path(tmpdir),
            )


def test_wgsl_minimization_rejects_unsafe_manifest_source_path() -> None:
    manifest = _load(MANIFEST_PATH)
    manifest["rows"][-1]["sourcePath"] = "/tmp/missing-return.wgsl"
    with tempfile.TemporaryDirectory() as tmpdir:
        with _raises(ValueError, match="unsafe sourcePath"):
            minimize.build_receipt(
                manifest=manifest,
                manifest_path="config/wgsl-browser-corpus.json",
                taxonomy=_load(TAXONOMY_PATH),
                shader_id="invalid-missing-return",
                taxonomy_code="wgsl_sema_failed",
                failure_stage="sema",
                diagnostic_category="control_flow",
                backend_targets=["msl"],
                diagnostic_line=None,
                context_lines=1,
                out_dir=Path(tmpdir),
            )


def test_wgsl_minimization_rejects_taxonomy_stage_mismatch() -> None:
    with tempfile.TemporaryDirectory() as tmpdir:
        with _raises(ValueError, match="has stage 'sema', not 'wgsl_parse'"):
            minimize.build_receipt(
                manifest=_load(MANIFEST_PATH),
                manifest_path="config/wgsl-browser-corpus.json",
                taxonomy=_load(TAXONOMY_PATH),
                shader_id="invalid-missing-return",
                taxonomy_code="wgsl_sema_failed",
                failure_stage="wgsl_parse",
                diagnostic_category="control_flow",
                backend_targets=["msl"],
                diagnostic_line=None,
                context_lines=1,
                out_dir=Path(tmpdir),
            )


def test_wgsl_minimization_rejects_unexpected_backend_target() -> None:
    manifest = _load(MANIFEST_PATH)
    manifest["rows"][-1]["expectedBackendTargets"] = ["msl"]
    with tempfile.TemporaryDirectory() as tmpdir:
        with _raises(ValueError, match="backend target not expected"):
            minimize.build_receipt(
                manifest=manifest,
                manifest_path="config/wgsl-browser-corpus.json",
                taxonomy=_load(TAXONOMY_PATH),
                shader_id="invalid-missing-return",
                taxonomy_code="wgsl_sema_failed",
                failure_stage="sema",
                diagnostic_category="control_flow",
                backend_targets=["spirv"],
                diagnostic_line=None,
                context_lines=1,
                out_dir=Path(tmpdir),
            )
