#!/usr/bin/env python3
"""Semantic contract tests for browser product comparison policy."""

from __future__ import annotations

import json
import unittest
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
POLICY_PATH = REPO_ROOT / "config" / "browser-product-comparison-policy.json"
STRATEGY_PATH = REPO_ROOT / "config" / "doe-product-strategy.json"

EXPECTED_CLOUDFLARE_SOURCES = {
    "https://blog.cloudflare.com/kitesurf/",
    "https://developers.cloudflare.com/browser-run/kitesurf/",
    "https://developers.cloudflare.com/browser-run/quick-actions/",
}


def _load_policy() -> dict[str, Any]:
    """Load the governed browser product comparison policy."""
    return json.loads(POLICY_PATH.read_text(encoding="utf-8"))


class BrowserProductComparisonPolicyTests(unittest.TestCase):
    """Protect causal lanes, external comparison, and fork boundaries."""

    def test_no_regret_trunk_is_incumbent_qualification_only(self) -> None:
        policy = _load_policy()

        self.assertEqual(
            [item["id"] for item in policy["noRegretTrunk"]["workItems"]],
            ["doeproof-incumbent-qualification"],
        )

    def test_internal_lanes_preserve_abcd_causal_order(self) -> None:
        policy = _load_policy()
        lanes = policy["internalCausalLanes"]

        self.assertEqual([lane["laneId"] for lane in lanes], ["A", "B", "C", "D"])
        self.assertEqual(
            [(lane["browser"], lane["runtime"]) for lane in lanes],
            [
                ("stock Chromium with Playwright", "Dawn"),
                ("Fawn with Playwright", "Dawn"),
                ("Fawn with Playwright", "DoeRuntime"),
                ("Fawn Direct Protocol", "DoeRuntime"),
            ],
        )

    def test_k0_is_external_and_not_a_component_substitution(self) -> None:
        policy = _load_policy()
        comparators = policy["externalComparators"]
        internal_ids = {lane["laneId"] for lane in policy["internalCausalLanes"]}

        self.assertEqual([item["comparatorId"] for item in comparators], ["K0"])
        self.assertNotIn("K0", internal_ids)
        self.assertFalse(comparators[0]["componentSubstitution"])
        self.assertEqual(
            set(comparators[0]["officialSources"]),
            EXPECTED_CLOUDFLARE_SOURCES,
        )
        self.assertEqual(
            comparators[0]["executorPath"],
            "bench/fawn_matrix/k0_cli.py",
        )
        self.assertEqual(
            comparators[0]["admissionPolicyPath"],
            "config/fawn-k0-workloads.json",
        )

    def test_suites_freeze_shared_and_differentiation_tasks(self) -> None:
        policy = _load_policy()
        suites = {suite["suiteId"]: suite for suite in policy["suites"]}

        self.assertEqual(
            set(suites),
            {"shared-agent-browser-tasks", "fawn-differentiation-tasks"},
        )
        self.assertEqual(
            suites["shared-agent-browser-tasks"]["tasks"],
            ["HTML extraction", "screenshots", "navigation", "automation success"],
        )
        self.assertEqual(
            suites["fawn-differentiation-tasks"]["tasks"],
            [
                "persistent authentication",
                "restart recovery",
                "offline local operation",
                "WebGL",
                "WebGPU",
                "private state",
                "long-running sessions",
            ],
        )
        for suite in suites.values():
            self.assertIn("total task outcome", suite["requiredObservations"])
            self.assertIn("compatibility failures", suite["requiredObservations"])

    def test_independence_tests_preserve_required_comparisons(self) -> None:
        policy = _load_policy()

        self.assertEqual(
            [test["comparison"] for test in policy["independenceTests"]],
            ["I1 to W0", "B to A", "C to B", "D to C", "K0 beside A/B/C/D"],
        )

    def test_fork_authorities_are_explicit_and_evidence_references_exist(self) -> None:
        policy = _load_policy()

        self.assertEqual(
            [fork["forkId"] for fork in policy["forkAuthorities"]],
            [
                "doeproof-commercial",
                "fawn-product",
                "doeruntime-browser",
                "fawn-direct-protocol",
            ],
        )
        for reference in policy["evidenceReferences"]:
            self.assertTrue((REPO_ROOT / reference).exists(), reference)

    def test_product_strategy_projects_the_canonical_policy(self) -> None:
        strategy = json.loads(STRATEGY_PATH.read_text(encoding="utf-8"))
        comparison = strategy["externalProductComparison"]

        self.assertEqual(
            comparison["authorityPath"],
            "config/browser-product-comparison-policy.json",
        )
        self.assertEqual(
            [suite["id"] for suite in comparison["suites"]],
            ["shared-agent-browser-tasks", "fawn-differentiation-tasks"],
        )


if __name__ == "__main__":
    unittest.main()
