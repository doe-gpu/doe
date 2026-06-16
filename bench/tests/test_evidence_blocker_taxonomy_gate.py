#!/usr/bin/env python3
"""Tests for evidence blocker taxonomy checks."""

from __future__ import annotations

import copy
import json
import unittest
from pathlib import Path

from bench.gates import evidence_blocker_taxonomy_gate as taxonomy

REPO_ROOT = Path(__file__).resolve().parents[2]
TAXONOMY_PATH = REPO_ROOT / "config" / "evidence-blocker-taxonomy.json"
MODEL_RUNTIME_SCHEMA_PATH = REPO_ROOT / "config" / "doe-model-runtime-receipt.schema.json"


def _load_taxonomy() -> dict:
    return json.loads(TAXONOMY_PATH.read_text(encoding="utf-8"))


def _load_model_runtime_schema() -> dict:
    return json.loads(MODEL_RUNTIME_SCHEMA_PATH.read_text(encoding="utf-8"))


class EvidenceBlockerTaxonomyGateTests(unittest.TestCase):
    def test_evidence_blocker_taxonomy_passes_check(self) -> None:
        self.assertEqual(
            taxonomy.check_taxonomy(
                _load_taxonomy(),
                model_runtime_schema=_load_model_runtime_schema(),
            ),
            [],
        )

    def test_rejects_duplicate_blocker_code(self) -> None:
        payload = _load_taxonomy()
        payload["codes"].append(copy.deepcopy(payload["codes"][0]))

        self.assertTrue(
            any(
                failure["code"] == "duplicate_blocker_code"
                for failure in taxonomy.check_taxonomy(payload)
            )
        )

    def test_requires_core_provider_code(self) -> None:
        payload = _load_taxonomy()
        payload["codes"] = [
            row
            for row in payload["codes"]
            if row["blockerCode"] != "native_webgpu_unavailable"
        ]

        self.assertIn(
            {
                "code": "missing_required_blocker_code",
                "path": "codes",
                "message": "missing required blockerCode native_webgpu_unavailable",
            },
            taxonomy.check_taxonomy(payload),
        )

    def test_rejects_digest_mismatch_without_digest_stage(self) -> None:
        payload = _load_taxonomy()
        for row in payload["codes"]:
            if row["blockerCode"] == "digest_mismatch":
                row["stages"] = ["runner"]
                break

        self.assertTrue(
            any(
                failure["code"] == "digest_mismatch_stage"
                and failure["message"] == "digest_mismatch must include digest stage"
                for failure in taxonomy.check_taxonomy(payload)
            )
        )

    def test_model_runtime_blockers_must_be_registered(self) -> None:
        payload = _load_taxonomy()
        payload["codes"] = [
            row
            for row in payload["codes"]
            if row["blockerCode"] != "real_weights_absent"
        ]

        self.assertIn(
            {
                "code": "unregistered_model_runtime_blocker",
                "path": "codes",
                "message": "model runtime executionBlocker real_weights_absent is not registered",
            },
            taxonomy.check_taxonomy(
                payload,
                model_runtime_schema=_load_model_runtime_schema(),
            ),
        )

    def test_nonvisible_codes_are_diagnostic_only(self) -> None:
        payload = _load_taxonomy()
        payload["codes"][0]["developerVisible"] = False

        self.assertIn(
            {
                "code": "nonvisible_blocker_not_diagnostic",
                "path": "codes[0].developerVisible",
                "message": "non-visible blocker codes must remain diagnostic-only",
            },
            taxonomy.check_taxonomy(payload),
        )


if __name__ == "__main__":
    unittest.main()
