#!/usr/bin/env python3
"""Tests for numeric fragility promotion helpers."""

from __future__ import annotations

import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]

from bench.runners.promote_numeric_fragility_signatures import (  # noqa: E402
    build_catalog,
    build_signature,
    corpus_class_for_row,
    latest_corpus_paths,
    load_jsonl,
    selection_rule_for_row,
)
from bench.lib.config_validation import load_validated_config  # noqa: E402


class PromoteNumericFragilitySignaturesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.policy = load_validated_config(REPO_ROOT / "config" / "fragility-promotion-policy.json")
        cls.registry = load_validated_config(REPO_ROOT / "config" / "numeric-stability-policy.json")
        cls.route_metadata_by_decision = {
            entry["decision"]: entry for entry in cls.registry["routeDecisionMetadata"]
        }
        try:
            cls.source_jsonl_path, cls.source_manifest_path = latest_corpus_paths(
                REPO_ROOT / "bench" / "out" / "apple-metal-numeric-fragility-corpus"
            )
        except FileNotFoundError as exc:
            raise unittest.SkipTest(
                "requires materialized numeric fragility corpus export"
            ) from exc
        cls.rows = load_jsonl(cls.source_jsonl_path)

    def test_selection_rules_match_prompt_and_operator_promotions(self) -> None:
        selected = [row for row in self.rows if selection_rule_for_row(row, self.policy) is not None]
        self.assertTrue(selected)
        entry_types = {row["entryType"] for row in selected}
        self.assertEqual(entry_types, {"prompt-lm-head-flip", "operator-control"})

    def test_build_signature_marks_promoted_rows_without_route_outcome(self) -> None:
        promoted_prompt = next(
            row for row in self.rows if row["entryId"] == "prompt-lm-head-flip::red-go-stop-answer::2f8677733c"
        )
        rule = selection_rule_for_row(promoted_prompt, self.policy)
        self.assertIsNotNone(rule)
        signature = build_signature(
            promoted_prompt,
            contract_stage=rule["contractStage"],
            corpus_class=corpus_class_for_row(promoted_prompt, self.policy),
            route_taxonomy_version=self.registry["routeTaxonomyVersion"],
            policy_id=self.policy["policyId"],
            route_metadata_by_decision=self.route_metadata_by_decision,
        )
        self.assertEqual(signature["contractStage"], "promoted")
        self.assertNotIn("routeOutcome", signature)
        self.assertEqual(signature["routeExpectation"]["decision"], "prefer-stable")
        self.assertEqual(signature["fastSelection"]["tokenId"], 4721)
        self.assertEqual(signature["stableSelection"]["tokenId"], 817)
        self.assertIn("selectedValueForRoute_preferStable_returns_stable", {
            link["theorem"] for link in signature["proofLinks"]
        })

    def test_build_catalog_summary_counts_entries(self) -> None:
        selected = []
        for row in self.rows:
            rule = selection_rule_for_row(row, self.policy)
            if rule is None:
                continue
            signature = build_signature(
                row,
                contract_stage=rule["contractStage"],
                corpus_class=corpus_class_for_row(row, self.policy),
                route_taxonomy_version=self.registry["routeTaxonomyVersion"],
                policy_id=self.policy["policyId"],
                route_metadata_by_decision=self.route_metadata_by_decision,
            )
            selected.append((Path("config") / "fragility-signatures" / "promoted" / (signature["signatureId"] + ".json"), signature))
        catalog = build_catalog(
            signatures=selected,
            catalog_version=self.policy["policyId"],
            promotion_policy_id=self.policy["policyId"],
            route_taxonomy_version=self.registry["routeTaxonomyVersion"],
            source_corpus_path=str(self.source_jsonl_path.relative_to(REPO_ROOT)),
            source_manifest_path=str(self.source_manifest_path.relative_to(REPO_ROOT)),
        )
        self.assertEqual(catalog["summary"]["entryCount"], len(selected))
        self.assertEqual(catalog["routeTaxonomyVersion"], self.registry["routeTaxonomyVersion"])
        self.assertIn("countsByRouteOutcome", catalog["summary"])


if __name__ == "__main__":
    unittest.main()
