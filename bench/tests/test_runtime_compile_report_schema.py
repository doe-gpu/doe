#!/usr/bin/env python3
"""Tests for the runtime compile report schema contract."""

from __future__ import annotations

import json
from pathlib import Path

import jsonschema


REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = REPO_ROOT / "config" / "runtime-compile-report.schema.json"
SAMPLE_PATH = REPO_ROOT / "examples" / "runtime-compile-report.sample.json"
TARGETS_PATH = REPO_ROOT / "config" / "schema-targets.json"


def _load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def test_runtime_compile_report_sample_matches_schema() -> None:
    schema = _load_json(SCHEMA_PATH)
    sample = _load_json(SAMPLE_PATH)

    jsonschema.Draft202012Validator(schema).validate(sample)

    assert sample["kind"] == "runtime_compile_report"
    assert sample["schemaVersion"] == 1
    assert sample["target"] == "msl"
    assert sample["outputBytes"] == sample["mslBytes"]
    assert sample["spirvBytes"] == 0
    assert set(sample["phaseTimingsNs"]) == {"parse", "sema", "lower", "emit", "total"}


def test_runtime_compile_report_is_registered_in_schema_gate() -> None:
    registry = _load_json(TARGETS_PATH)

    assert {
        "schema": "config/runtime-compile-report.schema.json",
        "data": "examples/runtime-compile-report.sample.json",
    } in registry["targets"]
