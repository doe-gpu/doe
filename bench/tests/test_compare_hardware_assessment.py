"""Tests for strict physical adapter identity comparability."""

from __future__ import annotations

import unittest
import sys
from pathlib import Path

BENCH_ROOT = Path(__file__).resolve().parents[1]
if str(BENCH_ROOT) not in sys.path:
    sys.path.insert(0, str(BENCH_ROOT))

from native_compare_modules.compare_hardware_assessment import (  # noqa: E402
    record_hardware_path_obligation,
)
from native_compare_modules.comparability import _record_obligation  # noqa: E402


def _sample(adapter_info: dict[str, object]) -> dict[str, object]:
    return {"traceMeta": {"adapterInfo": adapter_info}}


def _assessment(
    left_info: dict[str, object],
    right_info: dict[str, object],
) -> tuple[list[dict[str, object]], list[str]]:
    obligations: list[dict[str, object]] = []
    reasons: list[str] = []
    record_hardware_path_obligation(
        record_obligation=_record_obligation,
        obligations=obligations,
        reasons=reasons,
        comparability_mode="strict",
        is_dawn_vs_doe=True,
        package_execution_applies=True,
        workload_path_asymmetry=False,
        workload_path_asymmetry_note="",
        left_samples=[_sample(left_info)],
        right_samples=[_sample(right_info)],
    )
    return obligations, reasons


class CompareHardwareAssessmentTests(unittest.TestCase):
    def test_vulkan_raw_and_text_driver_identities_match(self) -> None:
        obligations, reasons = _assessment(
            {
                "vendor": "AMD",
                "vendorID": 0x1002,
                "device": "Radeon 8060S Graphics (RADV STRIX_HALO)",
                "deviceID": 0x1586,
                "architecture": "vulkan",
                "driverVersion": 109051907,
            },
            {
                "vendor": "amd",
                "vendorID": 0x1002,
                "device": "radeon-8060s-graphics-radv-strix-halo",
                "deviceID": 0x1586,
                "architecture": "rdna-3",
                "description": "radv: Mesa 26.0.3-1ubuntu1",
            },
        )
        self.assertEqual(reasons, [])
        self.assertTrue(obligations[0]["passes"])
        self.assertTrue(obligations[0]["details"]["physicalAdapterIdentityMatch"])

    def test_vulkan_missing_comparison_identity_fails(self) -> None:
        obligations, reasons = _assessment(
            {
                "vendor": "AMD",
                "vendorID": 0x1002,
                "device": "Radeon 8060S Graphics (RADV STRIX_HALO)",
                "deviceID": 0x1586,
                "architecture": "vulkan",
                "driverVersion": 109051907,
            },
            {"vendor": "generic", "architecture": "", "device": ""},
        )
        self.assertFalse(obligations[0]["passes"])
        self.assertIn("matching physical vendorID/deviceID/driverVersion", reasons[0])


if __name__ == "__main__":
    unittest.main()
