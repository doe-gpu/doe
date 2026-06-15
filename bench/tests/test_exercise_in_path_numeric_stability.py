#!/usr/bin/env python3
"""Tests for the in-path numeric-stability exercise runner."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]

from bench.lib.config_validation import load_validated_config  # noqa: E402
from bench.runners.exercise_in_path_numeric_stability import (  # noqa: E402
    build_commands_from_request,
    commit_staged_updates,
    stage_signature_tree,
    stage_signature_updates,
)
from bench.runners.exercise_runtime_numeric_stability import (  # noqa: E402
    prompt_request_from_signature,
    rebuild_catalog,
    write_json,
)
from bench.runners.promote_numeric_fragility_signatures import FRAGILITY_SIGNATURE_SCHEMA_PATH  # noqa: E402


def _has_primary_fixture(signature: dict[str, object]) -> bool:
    return any(
        (REPO_ROOT / str(related_path)).is_file()
        for related_path in signature.get("relatedArtifactPaths", [])
        if str(related_path).endswith(".fixture.json")
        and "selective_stable_rerun" not in str(related_path)
    )


class ExerciseInPathNumericStabilityTests(unittest.TestCase):
    def make_staged_signature_fixture(
        self,
    ) -> tuple[
        Path,
        Path,
        Path,
        dict[str, object],
        dict[str, object],
        dict[str, object],
        dict[str, object],
    ]:
        temp_dir = tempfile.TemporaryDirectory(dir=REPO_ROOT)
        self.addCleanup(temp_dir.cleanup)
        temp_root = Path(temp_dir.name)
        signature_root = temp_root / "config" / "fragility-signatures" / "promoted"
        signature_root.mkdir(parents=True, exist_ok=True)
        signature_path = signature_root / "prompt-test.json"
        source_signature = load_validated_config(
            REPO_ROOT
            / "config"
            / "fragility-signatures"
            / "promoted"
            / "prompt-lm-head-flip-red-go-stop-answer-2f8677733c.json",
            FRAGILITY_SIGNATURE_SCHEMA_PATH,
        )
        original_signature = json.loads(json.dumps(source_signature))
        write_json(signature_path, original_signature)
        updated_signature = json.loads(json.dumps(source_signature))
        updated_signature["notes"] = "runtime-exercised only after full plan success"

        catalog_path = temp_root / "config" / "promoted-fragility-catalog.json"
        original_catalog = {
            "schemaVersion": 1,
            "catalogVersion": "test-catalog-v1",
            "promotionPolicyId": "test-policy",
            "routeTaxonomyVersion": "numeric-stability-routes-v1",
            "sourceCorpusPath": "bench/out/test/source.jsonl",
            "entries": [],
            "summary": {
                "entryCount": 0,
                "countsByContractStage": {},
                "countsByArtifactKind": {},
                "countsByCorpusClass": {},
                "countsByRouteOutcome": {},
            },
        }
        write_json(catalog_path, original_catalog)
        updated_catalog = {
            **original_catalog,
            "catalogVersion": "test-catalog-v2",
            "summary": {
                **original_catalog["summary"],
                "entryCount": 1,
            },
        }
        return (
            temp_root,
            signature_path,
            catalog_path,
            original_signature,
            original_catalog,
            updated_signature,
            updated_catalog,
        )

    def test_build_commands_from_real_signature_relies_on_semantic_auto_detect(self) -> None:
        signature = load_validated_config(
            REPO_ROOT
            / "config"
            / "fragility-signatures"
            / "promoted"
            / "prompt-lm-head-flip-red-go-stop-answer-2f8677733c.json",
            FRAGILITY_SIGNATURE_SCHEMA_PATH,
        )
        if not _has_primary_fixture(signature):
            self.skipTest("requires materialized red-light LM-head fixture")
        request, _ = prompt_request_from_signature(
            signature,
            "numeric-stability/prefer-stable-on-selected-token-disagreement-v1",
        )
        commands = build_commands_from_request(request)
        self.assertEqual(len(commands), 4)
        kernel_dispatch = commands[-1]
        self.assertEqual(kernel_dispatch["kind"], "kernel_dispatch")
        self.assertEqual(
            kernel_dispatch["kernel"],
            "bench/inference-pipeline/kernels/matmul_logits_forward_f16accum.wgsl",
        )
        self.assertEqual(kernel_dispatch["semanticOpId"], "matmul.logits")
        self.assertEqual(kernel_dispatch["semanticPhase"], "logits")
        self.assertNotIn("numericStability", kernel_dispatch)

    def test_staged_updates_do_not_touch_canonical_files_before_commit(self) -> None:
        (
            temp_root,
            signature_path,
            catalog_path,
            original_signature,
            original_catalog,
            updated_signature,
            updated_catalog,
        ) = self.make_staged_signature_fixture()
        staging_root = temp_root / "staging"
        staged_signature_root = stage_signature_tree(signature_path.parent, staging_root)
        staged_signature_paths = stage_signature_updates(
            staging_root,
            {signature_path: updated_signature},
        )
        staged_catalog_path = staging_root / catalog_path.relative_to(REPO_ROOT)
        write_json(staged_catalog_path, updated_catalog)

        self.assertEqual(json.loads(signature_path.read_text(encoding="utf-8")), original_signature)
        self.assertEqual(json.loads(catalog_path.read_text(encoding="utf-8")), original_catalog)
        self.assertEqual(
            json.loads(staged_signature_paths[signature_path].read_text(encoding="utf-8")),
            updated_signature,
        )
        self.assertEqual(
            json.loads((staged_signature_root / "prompt-test.json").read_text(encoding="utf-8")),
            updated_signature,
        )
        rebuilt_catalog = rebuild_catalog(
            staged_signature_root,
            original_catalog,
            catalog_signature_root=REPO_ROOT / "config" / "fragility-signatures" / "promoted",
        )
        self.assertEqual(
            rebuilt_catalog["entries"][0]["signaturePath"],
            "config/fragility-signatures/promoted/prompt-test.json",
        )

        commit_staged_updates(
            staged_signature_paths=staged_signature_paths,
            staged_catalog_path=staged_catalog_path,
            catalog_path=catalog_path,
            rollback_root=staging_root,
        )

        self.assertEqual(json.loads(signature_path.read_text(encoding="utf-8")), updated_signature)
        self.assertEqual(json.loads(catalog_path.read_text(encoding="utf-8")), updated_catalog)

    def test_commit_staged_updates_rolls_back_if_catalog_replace_fails(self) -> None:
        (
            temp_root,
            signature_path,
            catalog_path,
            original_signature,
            original_catalog,
            updated_signature,
            updated_catalog,
        ) = self.make_staged_signature_fixture()
        staging_root = temp_root / "staging"
        stage_signature_tree(signature_path.parent, staging_root)
        staged_signature_paths = stage_signature_updates(
            staging_root,
            {signature_path: updated_signature},
        )
        staged_catalog_path = staging_root / catalog_path.relative_to(REPO_ROOT)
        write_json(staged_catalog_path, updated_catalog)

        original_replace = Path.replace

        def flaky_replace(self: Path, target: str | Path) -> Path:
            if self == staged_catalog_path:
                raise OSError("simulated catalog replace failure")
            return original_replace(self, target)

        with mock.patch("pathlib.Path.replace", new=flaky_replace):
            with self.assertRaises(OSError):
                commit_staged_updates(
                    staged_signature_paths=staged_signature_paths,
                    staged_catalog_path=staged_catalog_path,
                    catalog_path=catalog_path,
                    rollback_root=staging_root,
                )

        self.assertEqual(json.loads(signature_path.read_text(encoding="utf-8")), original_signature)
        self.assertEqual(json.loads(catalog_path.read_text(encoding="utf-8")), original_catalog)


if __name__ == "__main__":
    unittest.main()
