#!/usr/bin/env python3
"""Tests for the browser runtime selector policy checker."""

from __future__ import annotations

import importlib.util
import json
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
POLICY_PATH = REPO_ROOT / "config" / "browser-runtime-selector-policy.json"
CHECKER_PATH = REPO_ROOT / "browser" / "chromium" / "scripts" / "check-browser-runtime-selector-policy.py"


def _load_policy() -> dict:
    return json.loads(POLICY_PATH.read_text(encoding="utf-8"))


def _load_checker():
    spec = importlib.util.spec_from_file_location("browser_runtime_selector_policy", CHECKER_PATH)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class BrowserRuntimeSelectorPolicyTests(unittest.TestCase):
    def test_browser_runtime_selector_policy_passes_check(self) -> None:
        checker = _load_checker()

        self.assertEqual(checker.check_policy(_load_policy()), [])

    def test_browser_runtime_selector_policy_rejects_missing_mode(self) -> None:
        checker = _load_checker()
        policy = _load_policy()
        policy["selectionModes"] = ["dawn", "auto"]

        failures = checker.check_policy(policy)

        self.assertIn(
            {
                "code": "invalid_selection_modes",
                "path": "selectionModes",
                "message": "selection modes must be exactly dawn, doe, auto",
            },
            failures,
        )

    def test_browser_runtime_selector_policy_rejects_forced_doe_fallback(self) -> None:
        checker = _load_checker()
        policy = _load_policy()
        policy["forcedDoeFailure"]["fallbackToDawn"] = True

        failures = checker.check_policy(policy)

        self.assertIn(
            {
                "code": "forced_doe_not_fail_closed",
                "path": "forcedDoeFailure",
                "message": "forced Doe must fail closed without falling back to Dawn",
            },
            failures,
        )

    def test_browser_runtime_selector_policy_requires_observability_field(self) -> None:
        checker = _load_checker()
        policy = _load_policy()
        policy["observabilityFields"].remove("artifactIdentity.dawnRuntimeSha256")

        failures = checker.check_policy(policy)

        self.assertIn(
            {
                "code": "missing_observability_field",
                "path": "observabilityFields",
                "message": "missing observability field artifactIdentity.dawnRuntimeSha256",
            },
            failures,
        )

    def test_browser_runtime_selector_policy_requires_evidence_blocker_mapping(self) -> None:
        checker = _load_checker()
        policy = _load_policy()
        del policy["evidenceBlockerMap"]["profile_denylisted"]

        failures = checker.check_policy(policy)

        self.assertIn(
            {
                "code": "missing_evidence_blocker_mapping",
                "path": "evidenceBlockerMap",
                "message": "missing evidence blocker mapping for fallback reason profile_denylisted",
            },
            failures,
        )

    def test_browser_runtime_selector_policy_rejects_unknown_evidence_blocker(self) -> None:
        checker = _load_checker()
        policy = _load_policy()
        policy["evidenceBlockerMap"]["profile_denylisted"] = "unknown_blocker"

        failures = checker.check_policy(policy)

        self.assertIn(
            {
                "code": "unknown_evidence_blocker_code",
                "path": "evidenceBlockerMap.profile_denylisted",
                "message": "evidence blocker code 'unknown_blocker' is not defined in config/evidence-blocker-taxonomy.json",
            },
            failures,
        )


if __name__ == "__main__":
    unittest.main()
