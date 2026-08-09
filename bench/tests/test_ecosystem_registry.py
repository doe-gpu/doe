"""Focused tests for the Doe ecosystem registry semantic contract."""

from __future__ import annotations

import copy
import unittest
from pathlib import Path

from bench.lib.ecosystem_registry import (
    derive_label,
    evaluate_registry,
    load_json_object,
    registry_rows,
    render_markdown,
)


REPO_ROOT = Path(__file__).resolve().parents[2]


class EcosystemRegistryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.registry = load_json_object(
            REPO_ROOT / "config/ecosystem-registry.json"
        )
        cls.policy = load_json_object(
            REPO_ROOT / "config/ecosystem-scoring-policy.json"
        )
        cls.claim_index = load_json_object(REPO_ROOT / "reports/claim-index.json")

    def evaluate(self, registry: dict, policy: dict | None = None) -> dict:
        return evaluate_registry(
            registry,
            policy or self.policy,
            REPO_ROOT,
            self.claim_index,
        )

    def failure_codes(self, result: dict) -> set[str]:
        return {item["code"] for item in result["failures"]}

    def source_only_actor(self, registry: dict) -> dict:
        return next(
            actor
            for actor in registry["actors"]
            if actor["evidenceMaturity"] == "source-only"
            and not actor["reviewedReports"]
        )

    def test_checked_in_registry_passes(self) -> None:
        result = self.evaluate(self.registry)

        self.assertTrue(result["ok"], result["failures"])

    def test_relationship_is_derived_from_both_scores(self) -> None:
        self.assertEqual(derive_label(self.policy, 5, 1), "adoption-candidate")
        self.assertEqual(derive_label(self.policy, 5, 3), "design-partner")
        self.assertEqual(derive_label(self.policy, 1, 5), "reference-baseline")

    def test_duplicate_actor_ids_fail(self) -> None:
        registry = copy.deepcopy(self.registry)
        duplicate = copy.deepcopy(registry["actors"][0])
        duplicate["name"] = "Duplicate actor"
        registry["actors"].append(duplicate)

        result = self.evaluate(registry)

        self.assertIn("duplicate_actor_id", self.failure_codes(result))

    def test_score_reason_requires_known_observation(self) -> None:
        registry = copy.deepcopy(self.registry)
        revision = registry["actors"][0]["scoreHistory"][-1]
        revision["changedByObservationRefs"].append("missing-observation")

        result = self.evaluate(registry)

        self.assertIn("unknown_score_observation", self.failure_codes(result))

    def test_registry_state_can_advance_without_rewriting_score_history(self) -> None:
        registry = copy.deepcopy(self.registry)
        registry["registryRevision"] = str(int(registry["registryRevision"]) + 1)

        result = self.evaluate(registry)

        self.assertTrue(result["ok"], result["failures"])

    def test_score_revision_cannot_name_a_future_registry(self) -> None:
        registry = copy.deepcopy(self.registry)
        registry["actors"][0]["scoreHistory"][-1]["registryRevision"] = str(
            int(registry["registryRevision"]) + 1
        )

        result = self.evaluate(registry)

        self.assertIn("score_revision_from_future_registry", self.failure_codes(result))

    def test_harness_ready_requires_oracle(self) -> None:
        registry = copy.deepcopy(self.registry)
        actor = registry["actors"][0]
        actor["engagementStatus"] = "harness-ready"
        actor["harnesses"][0]["status"] = "ready"
        del actor["harnesses"][0]["oracle"]

        result = self.evaluate(registry)

        self.assertIn("harness_missing_oracle", self.failure_codes(result))

    def test_measured_actor_requires_pinned_commit(self) -> None:
        registry = copy.deepcopy(self.registry)
        actor = registry["actors"][0]
        actor["engagementStatus"] = "measured"
        actor["source"]["upstreamCommit"] = "main"

        result = self.evaluate(registry)

        self.assertIn("unpinned_active_actor", self.failure_codes(result))

    def test_claim_reference_requires_reviewed_report(self) -> None:
        registry = copy.deepcopy(self.registry)
        actor = self.source_only_actor(registry)
        actor["claimIndexRefs"] = [
            {
                "entryId": "package-node-apple-metal",
                "reviewedReportId": "missing-report",
            }
        ]

        result = self.evaluate(registry)

        self.assertIn("claim_without_reviewed_report", self.failure_codes(result))

    def test_final_score_requires_measured_harness_and_report(self) -> None:
        registry = copy.deepcopy(self.registry)
        actor = self.source_only_actor(registry)
        actor["scoreHistory"][-1]["reviewStatus"] = "reviewed"

        result = self.evaluate(registry)

        self.assertIn("final_score_without_harness_review", self.failure_codes(result))

    def test_policy_requires_complete_label_grid(self) -> None:
        policy = copy.deepcopy(self.policy)
        policy["derivedLabels"].pop()

        result = self.evaluate(self.registry, policy)

        self.assertIn("invalid_derived_label_mapping", self.failure_codes(result))

    def test_evaluation_queue_requires_known_harness(self) -> None:
        registry = copy.deepcopy(self.registry)
        registry["evaluationQueue"][0]["plannedHarnessIds"] = [
            "missing-harness"
        ]

        result = self.evaluate(registry)

        self.assertIn("unknown_evaluation_queue_harness", self.failure_codes(result))

    def test_outreach_requires_comparable_actionable_evidence(self) -> None:
        registry = copy.deepcopy(self.registry)
        self.source_only_actor(registry)["engagementStatus"] = "outreach-ready"

        result = self.evaluate(registry)

        codes = self.failure_codes(result)
        self.assertIn("outreach_without_comparable_evidence", codes)
        self.assertIn("outreach_without_actionable_outcome", codes)

    def test_validation_workload_requires_measurement_and_report(self) -> None:
        registry = copy.deepcopy(self.registry)
        actor = self.source_only_actor(registry)
        actor["adoptionStage"] = "validation-workload"

        result = self.evaluate(registry)

        self.assertIn(
            "validation_workload_without_measurement", self.failure_codes(result)
        )

    def test_promoted_actor_requires_adoption_and_eligible_artifacts(self) -> None:
        registry = copy.deepcopy(self.registry)
        actor = registry["actors"][0]
        actor["promotionStatus"] = "promoted"

        result = self.evaluate(registry)

        codes = self.failure_codes(result)
        self.assertIn("promotion_without_adoption", codes)
        self.assertIn("promotion_without_eligible_artifacts", codes)

    def test_renderer_uses_derived_current_scores(self) -> None:
        rows = registry_rows(self.registry, self.policy)
        markdown = render_markdown(self.registry, self.policy)

        self.assertEqual(len(rows), len(self.registry["actors"]))
        self.assertIn("| HoloScript SNN WebGPU | package | 5 | 3 |", markdown)
        self.assertIn("design-partner", markdown)
        self.assertIn("validation-workload", markdown)
        self.assertIn("not-promoted", markdown)


if __name__ == "__main__":
    unittest.main()
