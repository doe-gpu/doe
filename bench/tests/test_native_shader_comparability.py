#!/usr/bin/env python3
"""Regression tests for source-bound native Vulkan comparison evidence."""

from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

BENCH_ROOT = Path(__file__).resolve().parents[1]
if str(BENCH_ROOT) not in sys.path:
    sys.path.insert(0, str(BENCH_ROOT))

from native_compare_modules import comparability as _comparability  # noqa: F401
from native_compare_modules import comparability_runtime
from native_compare_modules.normalization import derive_counter_derived_divisor


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


class NativeShaderComparabilityTests(unittest.TestCase):
    def _fixture(
        self,
        root: Path,
        *,
        stale_source: bool = False,
        oracle_match: bool = True,
        oracle_dispatch_count: int = 3,
    ):
        kernel_root = root / "bench" / "kernels"
        kernel_root.mkdir(parents=True)
        source = b"@compute @workgroup_size(1) fn main() {}\n"
        spirv = b"\x03\x02\x23\x07"
        (kernel_root / "test.wgsl").write_bytes(source)
        (kernel_root / "test.spv").write_bytes(spirv)
        commands = root / "commands.json"
        commands.write_text(json.dumps([{
            "kind": "kernel_dispatch",
            "kernel": "test.wgsl",
            "x": 1,
            "y": 1,
            "z": 1,
            "repeat": 3,
            "output_oracle": {
                "kind": "sha256_exact_v1",
                "dispatch_count": oracle_dispatch_count,
            },
        }]), encoding="utf-8")
        manifest = root / "manifest.json"
        manifest.write_text(json.dumps({
            "module": "test.wgsl",
            "wgslSha256": _sha256(b"stale") if stale_source else _sha256(source),
            "spirvSha256": _sha256(spirv),
        }), encoding="utf-8")
        expected = "a" * 64
        doe_sample = {"traceMeta": {
            "executionBackend": "doe_vulkan",
            "shaderArtifactManifestPath": str(manifest),
            "outputOracleCount": 1,
            "outputOracleMatchedCount": 1 if oracle_match else 0,
            "outputOracleFailedCount": 0 if oracle_match else 1,
            "outputOracleExpectedSha256": expected,
            "outputOracleActualSha256": expected if oracle_match else "b" * 64,
        }}
        dawn_sample = {"traceMeta": {
            "executionBackend": "dawn_delegate",
            "outputOracleCount": 1,
            "outputOracleMatchedCount": 1,
            "outputOracleFailedCount": 0,
            "outputOracleExpectedSha256": expected,
            "outputOracleActualSha256": expected,
        }}
        return kernel_root, commands, doe_sample, dawn_sample

    def _assess(self, root: Path, **kwargs):
        kernel_root, commands, doe_sample, dawn_sample = self._fixture(root, **kwargs)
        with mock.patch.object(comparability_runtime, "REPO_ROOT", root), mock.patch.object(
            comparability_runtime, "_DEFAULT_COMPARE_KERNEL_ROOT", kernel_root
        ):
            return comparability_runtime.assess_native_shader_artifact_equivalence(
                workload_api="vulkan",
                workload_commands_path=str(commands),
                comparability_mode="strict",
                is_dawn_vs_doe=True,
                left_execution_backends={"doe_vulkan"},
                right_execution_backends={"dawn_delegate"},
                left_command_samples=[doe_sample],
                right_command_samples=[dawn_sample],
            )

    def test_source_bound_spirv_and_oracles_pass(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            applies, passes, _, reason = self._assess(Path(tmpdir))
        self.assertTrue(applies)
        self.assertTrue(passes, reason)

    def test_stale_wgsl_hash_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            _, passes, details, reason = self._assess(Path(tmpdir), stale_source=True)
        self.assertFalse(passes)
        self.assertGreater(details["nativeShaderArtifactMismatchCount"], 0)
        self.assertIn("WGSL hash is stale", reason)

    def test_failed_output_oracle_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            _, passes, _, reason = self._assess(Path(tmpdir), oracle_match=False)
        self.assertFalse(passes)
        self.assertIn("output oracle evidence is missing or failed", reason)

    def test_oracle_must_cover_the_timed_dispatch_count(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            _, passes, details, reason = self._assess(
                Path(tmpdir), oracle_dispatch_count=1
            )
        self.assertFalse(passes)
        self.assertEqual(
            details["kernelDispatchOutputOracleDispatchMismatches"],
            [{"commandIndex": 0, "timedDispatchCount": 3, "oracleDispatchCount": 1}],
        )
        self.assertIn("oracle dispatch count must equal", reason)

    def test_dispatch_count_is_not_an_implicit_wall_time_divisor(self) -> None:
        divisor, _, _, dispatches = derive_counter_derived_divisor(
            workload_domain="compute",
            strict_normalization_unit="",
            trace_meta={
                "executionDispatchCount": 100,
                "executionRowCount": 1,
                "executionSuccessCount": 1,
            },
            command_repeat=1,
        )
        self.assertEqual(dispatches, 100)
        self.assertEqual(divisor, 1.0)


if __name__ == "__main__":
    unittest.main()
