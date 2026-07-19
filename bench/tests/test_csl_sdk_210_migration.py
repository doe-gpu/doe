#!/usr/bin/env python3
"""Regression checks for the CSL SDK 2.10 migration surface."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]

FORBIDDEN_CSL_TOKENS = (
    "comptime_struct",
    "@concat_struct",
)

SOURCE_SCAN_ROOTS = (
    REPO_ROOT / "examples" / "csl",
    REPO_ROOT / "runtime" / "zig" / "examples" / "simulator",
    REPO_ROOT / "runtime" / "zig" / "src" / "compiler" / "wgsl" / "emit" / "csl",
)

SOURCE_SUFFIXES = {".csl", ".zig"}

SOURCE_SKIP_FILES = {
    REPO_ROOT
    / "runtime"
    / "zig"
    / "src"
    / "compiler"
    / "wgsl"
    / "emit"
    / "csl"
    / "emit_csl_validate.zig",
}

VERSION_SCAN_ROOTS = (
    REPO_ROOT / "examples",
    REPO_ROOT / "runtime" / "zig" / "examples",
)

LAYER_BLOCK_CSL_SOURCE = REPO_ROOT / (
    "bench/out/streaming-executor/e2b-layer-block-source/"
    "transformer_layer_shape.csl"
)

LAYER_BLOCK_RUNNER_SOURCES = (
    REPO_ROOT / "bench/tools/generate_e2b_layer_block_runner.py",
    REPO_ROOT / "bench/runners/csl-runners/e2b_layer_block_smoke.py",
    REPO_ROOT / "bench/runners/csl-runners/gemma_4_31b_layer_block_smoke.py",
)

LAYER_BLOCK_COLOR_PARAMS = (
    "rx_ple_rows",
    "rx_ple_projection",
    "rx_layer_weights",
    "tx_activation",
)


def _iter_files(roots: tuple[Path, ...], suffixes: set[str]):
    for root in roots:
        if not root.exists():
            continue
        for path in root.rglob("*"):
            if not path.is_file():
                continue
            if path.suffix not in suffixes:
                continue
            yield path


class CslSdk210MigrationTests(unittest.TestCase):
    def test_generated_csl_sources_do_not_use_removed_struct_constructs(self) -> None:
        offenders: list[str] = []
        for path in _iter_files(SOURCE_SCAN_ROOTS, SOURCE_SUFFIXES):
            if path.resolve() in SOURCE_SKIP_FILES:
                continue
            text = path.read_text(encoding="utf-8")
            for token in FORBIDDEN_CSL_TOKENS:
                if token in text:
                    offenders.append(f"{path.relative_to(REPO_ROOT)}: {token}")
        self.assertEqual([], offenders)

    def test_fabric_dsds_use_queue_color_binding(self) -> None:
        offenders: list[str] = []
        for path in _iter_files(SOURCE_SCAN_ROOTS, SOURCE_SUFFIXES):
            if path.resolve() in SOURCE_SKIP_FILES:
                continue
            lines = path.read_text(encoding="utf-8").splitlines()
            for index, line in enumerate(lines):
                window = "\n".join(lines[index : index + 8])
                rel = path.relative_to(REPO_ROOT)
                if "@get_dsd(fabin_dsd" in line:
                    if ".input_queue" not in window:
                        offenders.append(f"{rel}:{index + 1}: fabin_dsd missing input_queue")
                    if ".fabric_color" in window:
                        offenders.append(f"{rel}:{index + 1}: fabin_dsd uses fabric_color")
                if "@get_dsd(fabout_dsd" in line:
                    if ".output_queue" not in window:
                        offenders.append(f"{rel}:{index + 1}: fabout_dsd missing output_queue")
                    if ".fabric_color" in window:
                        offenders.append(f"{rel}:{index + 1}: fabout_dsd uses fabric_color")
        self.assertEqual([], offenders)

    def test_current_csl_contract_fixtures_use_sdk_210_floor(self) -> None:
        offenders: list[str] = []
        for path in _iter_files(VERSION_SCAN_ROOTS, {".json"}):
            text = path.read_text(encoding="utf-8")
            if "sdkVersionFloor" not in text and "minimumVersion" not in text:
                continue
            if '"1.4.0"' in text:
                offenders.append(str(path.relative_to(REPO_ROOT)))
        self.assertEqual([], offenders)

    def test_e2b_layer_block_sdklayout_color_binding_is_sdk_210_clean(self) -> None:
        csl_text = LAYER_BLOCK_CSL_SOURCE.read_text(encoding="utf-8")
        self.assertNotIn(".fabric_color", csl_text)
        for color_param in LAYER_BLOCK_COLOR_PARAMS:
            with self.subTest(color_param=color_param):
                self.assertRegex(
                    csl_text,
                    rf"param\s+{re.escape(color_param)}\s*:\s*u16;",
                )
                self.assertIn(f"@get_color({color_param})", csl_text)

        for path in LAYER_BLOCK_RUNNER_SOURCES:
            text = path.read_text(encoding="utf-8")
            for color_param in LAYER_BLOCK_COLOR_PARAMS:
                with self.subTest(path=path.name, color_param=color_param):
                    self.assertNotIn(
                        f'region.set_param_all("{color_param}"',
                        text,
                    )
                    self.assertIn(
                        f"region.set_param_all({color_param})",
                        text,
                    )


if __name__ == "__main__":
    unittest.main()
