#!/usr/bin/env python3
"""Tests for native compare runner dependency-injection hooks."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path
from typing import Any
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
for _path_entry in (str(REPO_ROOT), str(BENCH_ROOT)):
    if _path_entry not in sys.path:
        sys.path.insert(0, _path_entry)

from bench.native_compare_modules import runner


def _sentinel_parse(path: Path, shader_name: str) -> dict[str, Any]:
    return {"path": str(path), "shaderName": shader_name}


def _sentinel_compile_samples(
    tint_bin: Path,
    shader_path: Path,
    target: str,
    iterations: int,
    warmup: int,
) -> list[float]:
    _ = (tint_bin, shader_path, target, iterations, warmup)
    return [1.0]


def _sentinel_startup_samples(
    tint_bin: Path,
    target: str,
    iterations: int,
    warmup: int,
) -> list[float]:
    _ = (tint_bin, target, iterations, warmup)
    return [0.25]


class NativeCompareRunnerHookTests(unittest.TestCase):
    def test_apply_compilation_runner_hooks_does_not_mutate_input(self) -> None:
        original = {"parse_compilation_ndjson": _sentinel_parse}

        updated = runner._apply_compilation_runner_hooks(original)

        self.assertEqual(original, {"parse_compilation_ndjson": _sentinel_parse})
        self.assertIs(updated["parse_compilation_ndjson"], _sentinel_parse)
        self.assertIs(updated["tint_compile_samples"], runner._tint_compile_samples)
        self.assertIs(
            updated["tint_startup_baseline_samples"],
            runner._tint_startup_baseline_samples,
        )

    def test_compilation_product_wrapper_forwards_hooks_without_module_monkeypatch(self) -> None:
        original_parse = runner.compilation_runner_mod._parse_compilation_ndjson
        original_compile = runner.compilation_runner_mod._tint_compile_samples
        original_startup = runner.compilation_runner_mod._tint_startup_baseline_samples
        captured: dict[str, Any] = {}

        def fake_run_compilation_product_workload(*args: Any, **kwargs: Any) -> dict[str, Any]:
            _ = args
            captured.update(kwargs)
            self.assertIs(runner.compilation_runner_mod._parse_compilation_ndjson, original_parse)
            self.assertIs(runner.compilation_runner_mod._tint_compile_samples, original_compile)
            self.assertIs(
                runner.compilation_runner_mod._tint_startup_baseline_samples,
                original_startup,
            )
            return {"status": "ok"}

        caller_kwargs: dict[str, Any] = {
            "product": "doe",
            "workload": object(),
            "iterations": 1,
            "warmup": 0,
            "out_dir": Path("out"),
            "doe_compilation_bin": "doe-runtime-compile-report",
            "tint_bin": "tint",
        }
        before = dict(caller_kwargs)

        with (
            mock.patch.object(runner, "_parse_compilation_ndjson", _sentinel_parse),
            mock.patch.object(runner, "_tint_compile_samples", _sentinel_compile_samples),
            mock.patch.object(runner, "_tint_startup_baseline_samples", _sentinel_startup_samples),
            mock.patch.object(
                runner.compilation_runner_mod,
                "run_compilation_product_workload",
                fake_run_compilation_product_workload,
            ),
        ):
            result = runner.run_compilation_product_workload(**caller_kwargs)

        self.assertEqual(result, {"status": "ok"})
        self.assertEqual(caller_kwargs, before)
        self.assertIs(captured["parse_compilation_ndjson"], _sentinel_parse)
        self.assertIs(captured["tint_compile_samples"], _sentinel_compile_samples)
        self.assertIs(captured["tint_startup_baseline_samples"], _sentinel_startup_samples)


if __name__ == "__main__":
    unittest.main()
