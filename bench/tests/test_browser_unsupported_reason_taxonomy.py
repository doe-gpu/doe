#!/usr/bin/env python3
"""Tests for browser unsupported reason taxonomy checks."""

from __future__ import annotations

import copy
import json
import unittest
from pathlib import Path

from bench.tools import check_browser_unsupported_reason_taxonomy as taxonomy


REPO_ROOT = Path(__file__).resolve().parents[2]
TAXONOMY_PATH = REPO_ROOT / "config" / "browser-unsupported-reason-taxonomy.json"


def _load() -> dict:
    return json.loads(TAXONOMY_PATH.read_text(encoding="utf-8"))


class BrowserUnsupportedReasonTaxonomyTests(unittest.TestCase):
    def test_browser_unsupported_reason_taxonomy_passes_check(self) -> None:
        self.assertEqual(taxonomy.check_taxonomy(_load()), [])

    def test_browser_unsupported_reason_taxonomy_rejects_duplicate_code(self) -> None:
        payload = _load()
        payload["codes"].append(copy.deepcopy(payload["codes"][0]))

        self.assertTrue(
            any(
                failure["code"] == "duplicate_reason_code"
                for failure in taxonomy.check_taxonomy(payload)
            )
        )

    def test_browser_unsupported_reason_taxonomy_requires_core_code(self) -> None:
        payload = _load()
        payload["codes"] = [
            row for row in payload["codes"] if row["reasonCode"] != "profile_denylisted"
        ]

        self.assertIn(
            {
                "code": "missing_required_reason_code",
                "path": "codes",
                "message": "missing required reasonCode profile_denylisted",
            },
            taxonomy.check_taxonomy(payload),
        )

    def test_browser_unsupported_reason_taxonomy_rejects_invalid_category(self) -> None:
        payload = _load()
        payload["codes"][0]["category"] = "maybe"

        self.assertIn(
            {
                "code": "invalid_category",
                "path": "codes[0].category",
                "message": "category must use the browser unsupported reason taxonomy",
            },
            taxonomy.check_taxonomy(payload),
        )

    def test_browser_unsupported_reason_taxonomy_restricts_nonvisible_codes_to_diagnostics(self) -> None:
        payload = _load()
        payload["codes"][0]["developerVisible"] = False
        payload["codes"][0]["notes"] = ""

        failures = taxonomy.check_taxonomy(payload)

        self.assertIn(
            {
                "code": "nonvisible_reason_not_diagnostic",
                "path": "codes[0].developerVisible",
                "message": "non-visible reason codes must remain diagnostic-only",
            },
            failures,
        )
        self.assertIn(
            {
                "code": "missing_notes",
                "path": "codes[0].notes",
                "message": "developer-visible reason codes require notes",
            },
            failures,
        )

    def test_browser_unsupported_reason_taxonomy_rejects_duplicate_status(self) -> None:
        payload = _load()
        payload["codes"][0]["statuses"].append(payload["codes"][0]["statuses"][0])

        self.assertIn(
            {
                "code": "duplicate_status",
                "path": "codes[0].statuses",
                "message": "statuses must be unique",
            },
            taxonomy.check_taxonomy(payload),
        )

    def test_browser_unsupported_reason_taxonomy_rejects_category_status_mismatch(self) -> None:
        payload = _load()
        payload["codes"][0]["statuses"] = ["blocked"]

        self.assertIn(
            {
                "code": "category_status_mismatch",
                "path": "codes[0].statuses",
                "message": "category 'supported' requires status 'supported'",
            },
            taxonomy.check_taxonomy(payload),
        )

    def test_browser_unsupported_reason_taxonomy_requires_evidence_blocker_mapping(self) -> None:
        payload = _load()
        del payload["evidenceBlockerMap"]["profile_denylisted"]

        self.assertIn(
            {
                "code": "missing_evidence_blocker_mapping",
                "path": "evidenceBlockerMap",
                "message": "missing evidence blocker mapping for reasonCode profile_denylisted",
            },
            taxonomy.check_taxonomy(payload),
        )

    def test_browser_unsupported_reason_taxonomy_rejects_unknown_evidence_blocker(self) -> None:
        payload = _load()
        payload["evidenceBlockerMap"]["profile_denylisted"] = "unknown_blocker"

        self.assertIn(
            {
                "code": "unknown_evidence_blocker_code",
                "path": "evidenceBlockerMap.profile_denylisted",
                "message": "evidence blocker code 'unknown_blocker' is not defined in config/evidence-blocker-taxonomy.json",
            },
            taxonomy.check_taxonomy(payload),
        )

    def test_browser_unsupported_reason_taxonomy_rejects_supported_blocker_mapping(self) -> None:
        payload = _load()
        payload["evidenceBlockerMap"]["runtime_available"] = "runtime_incomplete"

        self.assertIn(
            {
                "code": "supported_reason_has_blocker",
                "path": "evidenceBlockerMap.runtime_available",
                "message": "supported reasonCode runtime_available must map to none",
            },
            taxonomy.check_taxonomy(payload),
        )


if __name__ == "__main__":
    unittest.main()
