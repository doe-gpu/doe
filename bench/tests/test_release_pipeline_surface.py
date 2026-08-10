"""Tests for release-pipeline surface classification."""

from __future__ import annotations

import unittest
from pathlib import Path

from bench.runners.run_release_pipeline import (
    is_amd_vulkan_config,
    is_package_surface_config,
)


REPO_ROOT = Path(__file__).resolve().parents[2]


class ReleasePipelineSurfaceTests(unittest.TestCase):
    def test_amd_vulkan_package_config_is_package_surface(self) -> None:
        config_path = REPO_ROOT / (
            "bench/native-compare/"
            "compare.config.amd.vulkan.gemma64.bun-package.warm.ir.json"
        )
        self.assertTrue(is_amd_vulkan_config(config_path))
        self.assertTrue(is_package_surface_config(config_path))

    def test_amd_vulkan_native_config_is_not_package_surface(self) -> None:
        config_path = REPO_ROOT / (
            "bench/native-compare/compare.config.amd.vulkan.release.json"
        )
        self.assertTrue(is_amd_vulkan_config(config_path))
        self.assertFalse(is_package_surface_config(config_path))


if __name__ == "__main__":
    unittest.main()
