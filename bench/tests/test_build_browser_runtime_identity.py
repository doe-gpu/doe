#!/usr/bin/env python3
"""Tests for browser runtime identity builder."""

from __future__ import annotations

import importlib.util
import json
import unittest
from pathlib import Path

from bench.tools import build_browser_runtime_identity as builder


REPO_ROOT = Path(__file__).resolve().parents[2]
SMOKE_SAMPLE = REPO_ROOT / "examples" / "browser-smoke-report.sample.json"
CHECKER_PATH = REPO_ROOT / "browser" / "chromium" / "scripts" / "check-browser-runtime-identity.py"


def _load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def _load_checker():
    spec = importlib.util.spec_from_file_location("browser_runtime_identity", CHECKER_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load checker: {CHECKER_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class BrowserRuntimeIdentityBuilderTests(unittest.TestCase):
    def test_builds_claim_grade_doe_identity_from_smoke_report(self) -> None:
        identity = builder.build_identity(
            _load_json(SMOKE_SAMPLE),
            report_path=SMOKE_SAMPLE,
            mode="doe",
        )

        self.assertEqual(identity["evidenceSource"], "runtime_selection_artifact")
        self.assertEqual(identity["selectedRuntime"], "doe")
        self.assertEqual(identity["executionOwner"], "chromium_runtime_selector")
        self.assertIs(identity["doeRuntimeActive"], True)
        self.assertIs(identity["webgpuAvailable"], True)
        self.assertEqual(_load_checker().check_identity(identity), [])

    def test_builds_inactive_dawn_identity_from_smoke_report(self) -> None:
        identity = builder.build_identity(
            _load_json(SMOKE_SAMPLE),
            report_path=SMOKE_SAMPLE,
            mode="dawn",
        )

        self.assertEqual(identity["selectedRuntime"], "dawn")
        self.assertIs(identity["doeRuntimeActive"], False)
        self.assertEqual(_load_checker().check_identity(identity), [])

    def test_rejects_missing_mode(self) -> None:
        with self.assertRaises(ValueError):
            builder.build_identity(
                {"reportKind": "test", "modeResults": []},
                report_path=Path("missing.json"),
                mode="doe",
            )

    def test_builds_from_layered_mode_run_details(self) -> None:
        payload = {
            "reportKind": "browser-layered-diagnostic",
            "modeRunDetails": [
                {
                    "mode": "doe",
                    "runtimeSelection": {
                        "selectedRuntime": "doe",
                        "fallbackApplied": False,
                        "fallbackReasonCode": "",
                        "hiddenFallbackAllowed": False,
                        "selectorVersion": "browser-runtime-selector-v1",
                    },
                    "runtimeProbe": {
                        "webgpuAvailable": True,
                        "adapterAvailable": True,
                        "adapterIdentity": {"adapterInfoSha256": "a" * 64},
                    },
                    "runtimeEvidence": {
                        "browserVersion": "Chrome/126.0.0.0",
                        "userAgent": "Mozilla/5.0",
                        "pageTargetKind": "local_http",
                    },
                }
            ],
        }

        identity = builder.build_identity(payload, report_path=Path("layered.json"), mode="doe")

        self.assertEqual(identity["selectedRuntime"], "doe")
        self.assertEqual(identity["provider"]["sourceReportKind"], "browser-layered-diagnostic")
        self.assertEqual(identity["provider"]["pageTargetKind"], "local_http")
        self.assertEqual(_load_checker().check_identity(identity), [])


if __name__ == "__main__":
    unittest.main()
