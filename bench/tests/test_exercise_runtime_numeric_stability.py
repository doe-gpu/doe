#!/usr/bin/env python3
"""Tests for the live runtime numeric-stability exercise runner."""

from __future__ import annotations

import json
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]

from bench.runners.exercise_runtime_numeric_stability import (  # noqa: E402
    prompt_request_from_signature,
    update_signature_from_result,
)
from bench.runners.promote_numeric_fragility_signatures import FRAGILITY_SIGNATURE_SCHEMA_PATH  # noqa: E402
from bench.lib.config_validation import load_validated_config  # noqa: E402


def _has_primary_fixture(signature: dict) -> bool:
    return any(
        (REPO_ROOT / related_path).is_file()
        for related_path in signature.get("relatedArtifactPaths") or []
        if related_path.endswith(".fixture.json")
        and "selective_stable_rerun" not in related_path
    )


class ExerciseRuntimeNumericStabilityTests(unittest.TestCase):
    def test_prompt_request_from_signature_decodes_real_red_light_operands(self) -> None:
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
        request, source_info = prompt_request_from_signature(
            signature,
            "numeric-stability/prefer-stable-on-selected-token-disagreement-v1",
        )
        self.assertEqual(request["operatorFamily"], "lm-head-slice")
        self.assertEqual(request["semanticOpId"], "matmul.logits")
        self.assertEqual([candidate["tokenId"] for candidate in request["candidates"]], [817, 4721])
        self.assertEqual(len(request["hiddenState"]), 640)
        self.assertEqual(len(request["candidates"][0]["weights"]), 640)
        self.assertIn("red-go-stop-answer_prefix2.fixture.json", source_info["fixturePath"])

    def test_update_signature_from_result_marks_runtime_exercised(self) -> None:
        signature = load_validated_config(
            REPO_ROOT
            / "config"
            / "fragility-signatures"
            / "promoted"
            / "prompt-lm-head-flip-red-go-stop-answer-2f8677733c.json",
            FRAGILITY_SIGNATURE_SCHEMA_PATH,
        )
        result = json.loads(
            (
                REPO_ROOT / "examples" / "numeric-stability-service.result.sample.json"
            ).read_text(encoding="utf-8")
        )
        updated = update_signature_from_result(
            signature,
            result=result,
            case_report_rel="bench/out/test/runtime-numeric-stability.case.json",
            request_rel="bench/out/test/runtime-numeric-stability.request.json",
            result_rel="bench/out/test/runtime-numeric-stability.result.json",
            receipt_rel="bench/out/test/runtime-numeric-stability.receipt.jsonl",
            trace_meta_rel="bench/out/test/runtime-numeric-stability.trace-meta.json",
        )
        self.assertEqual(updated["contractStage"], "runtime-exercised")
        self.assertEqual(updated["routeOutcome"]["decision"], "prefer-stable")
        self.assertEqual(updated["routeOutcome"]["selectedTokenId"], 817)
        self.assertEqual(updated["fastSelection"]["tokenId"], 4721)
        self.assertEqual(updated["stableSelection"]["tokenId"], 817)
        self.assertIn(
            "bench/out/test/runtime-numeric-stability.result.json",
            updated["relatedArtifactPaths"],
        )


if __name__ == "__main__":
    unittest.main()
