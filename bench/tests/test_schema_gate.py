#!/usr/bin/env python3
"""Tests for the schema gate target handling."""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

MODULE_PATH = Path(__file__).resolve().parents[1] / "gates" / "schema_gate.py"


def _load_module() -> Any:
    spec = importlib.util.spec_from_file_location("schema_gate", MODULE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load schema_gate from {MODULE_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def _write_schema(root: Path) -> None:
    path = root / "config" / "sample.schema.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(
            {
                "$schema": "https://json-schema.org/draft/2020-12/schema",
                "type": "object",
                "additionalProperties": False,
                "required": ["ok"],
                "properties": {"ok": {"type": "boolean"}},
            }
        ),
        encoding="utf-8",
    )


def test_missing_generated_bench_out_target_is_optional() -> None:
    module = _load_module()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_schema(root)

        failures = module.validate_target(
            root,
            module.ValidationTarget(
                schema_rel="config/sample.schema.json",
                data_rel="bench/out/generated/receipt.json",
            ),
        )

    assert failures == []


def test_missing_non_generated_target_still_fails() -> None:
    module = _load_module()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_schema(root)

        failures = module.validate_target(
            root,
            module.ValidationTarget(
                schema_rel="config/sample.schema.json",
                data_rel="examples/missing.json",
            ),
        )

    assert failures == ["missing data: examples/missing.json"]


class SchemaKindRoutingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.module = _load_module()
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        config = self.root / "config"
        config.mkdir()
        registry_schema = MODULE_PATH.parents[2] / "config/schema-targets.schema.json"
        (config / registry_schema.name).write_bytes(registry_schema.read_bytes())
        self.mapping = {}
        for kind in ("matrix", "package"):
            path = f"config/{kind}.schema.json"
            self.mapping[kind] = path
            self.write_json(path, {
                "type": "object",
                "required": ["kind", "result"],
                "additionalProperties": False,
                "properties": {
                    "kind": {"const": kind},
                    "result": {"type": "boolean"},
                },
            })
        self.registry = {
            "schemaVersion": 2,
            "targets": [],
            "globTargets": [{
                "schemasByKind": self.mapping,
                "glob": "bench/out/*-final/summary.json",
                "allowEmpty": True,
            }],
        }
        self.write_json("config/schema-targets.json", self.registry)

    def write_json(self, relative: str, payload: Any) -> None:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload), encoding="utf-8")

    def test_identical_filename_suffix_routes_each_body(self) -> None:
        for kind in self.mapping:
            self.write_json(f"bench/out/{kind}-final/summary.json", {
                "kind": kind, "result": True,
            })
        targets = self.module.collect_targets(self.root)
        self.assertEqual(len(targets), len(self.mapping))
        self.assertEqual({target.schema_rel for target in targets},
                         set(self.mapping.values()))
        for target in targets:
            self.assertEqual(self.module.validate_target(self.root, target), [])

    def test_unknown_missing_and_non_string_kinds_fail(self) -> None:
        for payload in ({"kind": "unknown"}, {}, {"kind": []}, []):
            with self.subTest(payload=payload):
                self.write_json("bench/out/run-final/summary.json", payload)
                with self.assertRaisesRegex(ValueError, "expected registered kind"):
                    self.module.collect_targets(self.root)

    def test_known_kind_does_not_bypass_body_validation(self) -> None:
        self.write_json("bench/out/run-final/summary.json", {"kind": "package"})
        target, = self.module.collect_targets(self.root)
        self.assertEqual(target.schema_rel, self.mapping["package"])
        failures = self.module.validate_target(self.root, target)
        self.assertTrue(any("'result' is a required property" in f for f in failures))

    def test_ambiguous_selection_forms_fail_registry_validation(self) -> None:
        self.registry["globTargets"][0]["schema"] = self.mapping["matrix"]
        self.write_json("config/schema-targets.json", self.registry)
        with self.assertRaisesRegex(ValueError, "schema-targets.json is invalid"):
            self.module.collect_targets(self.root)

    def test_empty_mapping_fails_registry_validation(self) -> None:
        self.registry["globTargets"][0]["schemasByKind"] = {}
        self.write_json("config/schema-targets.json", self.registry)
        with self.assertRaisesRegex(ValueError, "schema-targets.json is invalid"):
            self.module.collect_targets(self.root)

    def test_fixed_schema_globs_keep_body_validation(self) -> None:
        target = self.registry["globTargets"][0]
        del target["schemasByKind"]
        target["schema"] = self.mapping["matrix"]
        self.write_json("config/schema-targets.json", self.registry)
        self.write_json("bench/out/package-final/summary.json", {
            "kind": "package", "result": True,
        })
        selected, = self.module.collect_targets(self.root)
        self.assertTrue(self.module.validate_target(self.root, selected))

    def test_empty_glob_policy_is_preserved(self) -> None:
        self.assertEqual(self.module.collect_targets(self.root), [])
        self.registry["globTargets"][0]["allowEmpty"] = False
        self.write_json("config/schema-targets.json", self.registry)
        with self.assertRaisesRegex(ValueError, "glob has no matches"):
            self.module.collect_targets(self.root)
