#!/usr/bin/env python3
"""Contract tests for the external K0 comparator connector."""

from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from typing import Any

import jsonschema

from bench.fawn_matrix.k0 import execute_k0_suite


REPO_ROOT = Path(__file__).resolve().parents[2]
POLICY_PATH = REPO_ROOT / "config" / "fawn-k0-workloads.json"
RESULT_SCHEMA_PATH = REPO_ROOT / "config" / "fawn-k0-result.schema.json"


def _sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


class FawnK0ConnectorTests(unittest.TestCase):
    """Protect task admission, exact oracles, and attribution boundaries."""

    def setUp(self) -> None:
        self.policy = json.loads(POLICY_PATH.read_text(encoding="utf-8"))
        self.responses = {
            "content": b"<html><body>frozen fixture</body></html>",
            "screenshot": b"\x89PNG\r\n\x1a\nfrozen-fixture",
            "cdp-navigation": b'{"finalUrl":"https://example.com/navigation","observations":{},"title":"Navigation"}',
            "cdp-automation": b'{"finalUrl":"https://example.com/automation","observations":{"status":"passed"},"title":"Automation"}',
        }
        self.bindings = {
            "schemaVersion": 1,
            "executionId": "k0-frozen-fixture-v1",
            "comparatorId": "K0",
            "tasks": [
                {
                    "taskId": "html-extraction",
                    "url": "https://example.com/frozen-html",
                    "oracle": {
                        "kind": "exact-response-sha256",
                        "expectedSha256": _sha256(self.responses["content"]),
                    },
                },
                {
                    "taskId": "navigation",
                    "url": "https://example.com/navigation",
                    "oracle": {
                        "kind": "exact-response-sha256",
                        "expectedSha256": _sha256(self.responses["cdp-navigation"]),
                    },
                },
                {
                    "taskId": "automation-success",
                    "url": "https://example.com/automation",
                    "steps": [{"action": "click", "selector": "#run"}],
                    "observations": [{
                        "id": "status",
                        "selector": "#status",
                        "property": "textContent",
                    }],
                    "oracle": {
                        "kind": "exact-response-sha256",
                        "expectedSha256": _sha256(self.responses["cdp-automation"]),
                    },
                },
                {
                    "taskId": "screenshots",
                    "url": "https://example.com/frozen-screenshot",
                    "oracle": {
                        "kind": "exact-response-sha256",
                        "expectedSha256": _sha256(self.responses["screenshot"]),
                    },
                },
            ],
        }

    def _execute(
        self,
        bindings: dict[str, Any] | None = None,
    ) -> tuple[dict[str, Any], list[tuple[str, str]], Path]:
        calls: list[tuple[str, str]] = []

        def transport(action: str, binding: dict[str, Any]) -> dict[str, Any]:
            calls.append((action, binding["url"]))
            return {
                "body": self.responses[action],
                "headers": {
                    "Content-Type": "application/octet-stream",
                    "X-Browser-Ms-Used": "12.5",
                },
                "httpStatus": 200,
            }

        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        output = Path(temporary.name) / "k0-result.json"
        report = execute_k0_suite(
            self.policy,
            bindings or self.bindings,
            output,
            transport,
            now=lambda: "2026-08-24T00:00:00+00:00",
        )
        return report, calls, output

    def test_policy_admits_only_implemented_quick_actions(self) -> None:
        admitted = [
            task for task in self.policy["taskAdmission"]
            if task["eligibility"] == "eligible"
        ]

        self.assertEqual(
            [(task["taskId"], task["action"]) for task in admitted],
            [
                ("html-extraction", "content"),
                ("screenshots", "screenshot"),
                ("navigation", "cdp-navigation"),
                ("automation-success", "cdp-automation"),
            ],
        )

    def test_suite_executes_admitted_rows_and_retains_ineligible_rows(self) -> None:
        report, calls, output = self._execute()
        schema = json.loads(RESULT_SCHEMA_PATH.read_text(encoding="utf-8"))
        jsonschema.Draft202012Validator(schema).validate(report)

        self.assertEqual(len(calls), 4)
        self.assertEqual(len(report["tasks"]), 11)
        self.assertEqual(report["evidenceStatus"], "passed-unpromoted")
        self.assertFalse(report["claimAllowed"])
        self.assertFalse(report["fawnCreditAllowed"])
        self.assertFalse(report["doeRuntimeCreditAllowed"])
        self.assertFalse(report["directProtocolCreditAllowed"])
        self.assertTrue(output.is_file())
        for task in report["tasks"]:
            self.assertFalse(task["fawnCreditAllowed"])
            if task["eligibility"] == "ineligible":
                self.assertEqual(task["executionStatus"], "ineligible")
                self.assertIsNone(task["request"])
                self.assertIsNone(task["response"])

    def test_exact_oracle_failure_remains_non_promoting(self) -> None:
        bindings = json.loads(json.dumps(self.bindings))
        bindings["tasks"][0]["oracle"]["expectedSha256"] = "0" * 64

        report, _, _ = self._execute(bindings)

        self.assertEqual(report["evidenceStatus"], "failed-unpromoted")
        failed = next(
            task for task in report["tasks"]
            if task["taskId"] == "html-extraction"
        )
        self.assertEqual(failed["failure"], "exact-response-sha256-mismatch")
        self.assertFalse(failed["oracle"]["pass"])
        self.assertFalse(report["claimAllowed"])

    def test_missing_admitted_binding_fails_before_network_execution(self) -> None:
        bindings = json.loads(json.dumps(self.bindings))
        bindings["tasks"] = bindings["tasks"][:1]

        with self.assertRaisesRegex(ValueError, "exactly the admitted tasks"):
            self._execute(bindings)


if __name__ == "__main__":
    unittest.main()
