"""Tests for run receipt build/load round-trip."""

from __future__ import annotations

import json
import hashlib
import tempfile
import unittest
from pathlib import Path

import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from native_compare_modules.run_artifact import (
    RUN_ARTIFACT_KIND,
    RUN_ARTIFACT_SCHEMA_VERSION,
    artifact_filename,
    build_run_artifact,
    load_run_artifact,
    write_run_artifact,
)
from native_compare_modules.workload_spec import ProductRunConfig, WorkloadSpec


REPO_ROOT = Path(__file__).resolve().parents[2]
WORKLOAD_MANIFEST_PATH = (
    REPO_ROOT / "bench" / "workloads" / "workloads.package.gemma270m.json"
)


def _make_spec() -> WorkloadSpec:
    return WorkloadSpec(
        id="compute_test",
        name="test workload",
        description="unit test workload",
        domain="compute",
        commands_path="examples/test.json",
        quirks_path="examples/quirks/noop.json",
        vendor="amd",
        api="vulkan",
        family="gfx11",
        driver="24.0.0",
        extra_args=[],
        comparable=True,
        benchmark_class="comparable",
        comparability_notes="test",
        directional_reason="",
        path_asymmetry=False,
        path_asymmetry_note="",
        strict_normalization_unit="",
    )


def _make_run_config() -> ProductRunConfig:
    return ProductRunConfig(product="doe", command_repeat=4, timing_divisor=2.0)


def _make_run_result() -> dict:
    return {
        "commandSamples": [
            {
                "runIndex": 0,
                "command": [
                    "runtime/zig/zig-out/bin/doe-zig-runtime",
                    "--backend",
                    "native",
                ],
                "elapsedMs": 10.0,
                "measuredRawMs": 8.0,
                "measuredMs": 8.0,
                "timingSource": "doe-execution-total-ns",
                "timing": {
                    "commandRepeat": 4,
                    "timingNormalizationDivisor": 2.0,
                    "timingConfiguredDivisor": 2.0,
                    "workloadUnitNormalizationDivisor": 4.0,
                    "traceMetaSource": "doe-execution-total-ns",
                },
                "returnCode": 0,
                "traceJsonlPath": "bench/out/sample.ndjson",
                "traceMetaPath": "bench/out/sample.meta.json",
                "resource": {},
                "commandRepeat": 4,
                "uploadIgnoreFirstOps": 0,
                "uploadBufferUsage": "copy-dst-copy-src",
                "uploadSubmitEvery": 1,
                "timingNormalizationDivisor": 2.0,
                "workloadUnitNormalizationDivisor": 4.0,
                "traceMeta": {
                    "executionBackend": "doe_vulkan",
                    "executionProvider": "doe",
                    "executionProviderName": "doe-gpu",
                    "executionTotalNs": 8_000_000,
                    "executionSetupTotalNs": 1_000_000,
                    "executionEncodeTotalNs": 2_000_000,
                    "executionSubmitWaitTotalNs": 3_000_000,
                    "adapterInfo": {
                        "vendor": "amd",
                        "device": "gfx1100",
                        "architecture": "rdna3",
                        "description": "AMD Radeon Graphics",
                        "vendorID": 0x1002,
                        "deviceID": 0x744C,
                        "driverVersion": 109051904,
                    },
                },
            }
        ],
        "stats": {"count": 1, "p50Ms": 8.0, "p95Ms": 8.0, "meanMs": 8.0},
        "timingsMs": [8.0],
        "lastMeta": {"module": "doe-zig-runtime"},
        "timingSources": ["doe-execution-total-ns"],
        "timingClasses": ["operation"],
        "resourceStats": {},
        "timingMetricsRawStatsMs": {},
        "timingMetricsNormalizedStatsMs": {},
    }


def _make_command_only_run_result() -> dict:
    return {
        "commandSamples": [
            {
                "runIndex": 0,
                "command": [
                    "runtime/zig/zig-out/bin/doe-zig-runtime",
                    "--backend",
                    "native",
                ],
                "commandRepeat": 4,
                "uploadIgnoreFirstOps": 0,
                "uploadBufferUsage": "copy-dst-copy-src",
                "uploadSubmitEvery": 1,
                "timingNormalizationDivisor": 2.0,
                "workloadUnitNormalizationDivisor": 4.0,
                "workloadDomain": "compute",
                "strictNormalizationUnit": "",
            }
        ],
        "stats": {"count": 0},
        "timingsMs": [],
        "lastMeta": {},
        "timingSources": [],
        "timingClasses": [],
        "resourceStats": {},
        "timingMetricsRawStatsMs": {},
        "timingMetricsNormalizedStatsMs": {},
    }


def _with_sample_command_and_backend(
    run_result: dict,
    *,
    command: list[str],
    execution_backend: str,
) -> dict:
    cloned = json.loads(json.dumps(run_result))
    sample = cloned["commandSamples"][0]
    sample["command"] = command
    sample["traceMeta"]["executionBackend"] = execution_backend
    return cloned


def _with_package_provider_name(
    run_result: dict,
    provider_name: str,
) -> dict:
    cloned = json.loads(json.dumps(run_result))
    trace_meta = cloned["commandSamples"][0]["traceMeta"]
    trace_meta["providerName"] = provider_name
    trace_meta["executionProviderName"] = provider_name
    return cloned


class TestRunReceiptRoundTrip(unittest.TestCase):
    def test_build_receipt_has_required_fields(self) -> None:
        artifact = build_run_artifact(
            run_result=_make_run_result(),
            product="doe",
            executor_id="doe_direct_vulkan",
            workload_spec=_make_spec(),
            run_config=_make_run_config(),
            iterations=2,
            warmup=0,
            workload_contract_path=WORKLOAD_MANIFEST_PATH,
        )
        self.assertEqual(artifact["schemaVersion"], RUN_ARTIFACT_SCHEMA_VERSION)
        self.assertEqual(artifact["artifactKind"], RUN_ARTIFACT_KIND)
        self.assertEqual(artifact["product"], "doe")
        self.assertEqual(artifact["executorId"], "doe_direct_vulkan")
        self.assertEqual(artifact["workloadManifest"]["ownership"], "standalone")
        self.assertEqual(artifact["workload"]["id"], "compute_test")
        self.assertEqual(artifact["invocation"]["iterations"], 2)
        self.assertEqual(len(artifact["samples"]), 1)
        self.assertEqual(artifact["execution"]["timedSampleCount"], 1)
        self.assertEqual(artifact["hostIdentity"]["driver"], "109051904")
        self.assertEqual(artifact["hostIdentity"]["adapter"]["vendorID"], 0x1002)

    def test_command_only_receipt_is_not_timed_execution_evidence(self) -> None:
        artifact = build_run_artifact(
            run_result=_make_command_only_run_result(),
            product="doe",
            executor_id="doe_direct_vulkan",
            workload_spec=_make_spec(),
            run_config=_make_run_config(),
            iterations=1,
            warmup=0,
            workload_contract_path=WORKLOAD_MANIFEST_PATH,
        )
        self.assertEqual(len(artifact["samples"]), 1)
        self.assertEqual(artifact["samples"][0]["returnCode"], 1)
        self.assertFalse(artifact["samples"][0]["success"])
        self.assertFalse(artifact["execution"]["success"])
        self.assertEqual(artifact["execution"]["timedSampleCount"], 0)
        self.assertEqual(artifact["execution"]["returnCodes"], [1])

    def test_env_wrapped_command_resolves_runner_binary(self) -> None:
        artifact = build_run_artifact(
            run_result=_with_sample_command_and_backend(
                _make_run_result(),
                command=[
                    "env",
                    "DYLD_LIBRARY_PATH=bench/vendor/dawn/out/Release:$DYLD_LIBRARY_PATH",
                    sys.executable,
                    "--backend",
                    "native",
                ],
                execution_backend="doe_metal",
            ),
            product="doe",
            executor_id="doe_direct_metal",
            workload_spec=_make_spec(),
            run_config=_make_run_config(),
            iterations=2,
            warmup=0,
            workload_contract_path=WORKLOAD_MANIFEST_PATH,
        )
        self.assertEqual(artifact["runtimeIdentity"]["binaryPath"], sys.executable)
        self.assertEqual(
            artifact["runtimeIdentity"]["binarySha256"],
            hashlib.sha256(Path(sys.executable).read_bytes()).hexdigest(),
        )
        self.assertNotIn("nativeDelegate", artifact["runtimeIdentity"])

    def test_dawn_delegate_receipt_pins_delegate_library(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            library_path = Path(tmpdir) / "libwebgpu_dawn.dylib"
            library_path.write_bytes(b"test-dawn-delegate-library")
            artifact = build_run_artifact(
                run_result=_with_sample_command_and_backend(
                    _make_run_result(),
                    command=[
                        "env",
                        f"DYLD_LIBRARY_PATH={tmpdir}:$DYLD_LIBRARY_PATH",
                        sys.executable,
                        "--backend",
                        "native",
                    ],
                    execution_backend="dawn_delegate",
                ),
                product="dawn_delegate",
                executor_id="dawn_delegate_metal",
                workload_spec=_make_spec(),
                run_config=_make_run_config(),
                iterations=2,
                warmup=0,
                workload_contract_path=WORKLOAD_MANIFEST_PATH,
            )
            self.assertEqual(artifact["runtimeIdentity"]["binaryPath"], sys.executable)
            self.assertEqual(
                artifact["runtimeIdentity"]["nativeDelegate"],
                {
                    "kind": "dawn",
                    "libraryPath": str(library_path),
                    "librarySha256": hashlib.sha256(library_path.read_bytes()).hexdigest(),
                },
            )

    def test_doe_native_direct_receipt_uses_doe_package_identity(self) -> None:
        artifact = build_run_artifact(
            run_result=_with_package_provider_name(
                _make_run_result(),
                "doe-gpu/native-direct",
            ),
            product="doe",
            executor_id="doe_node_native_direct",
            workload_spec=_make_spec(),
            run_config=_make_run_config(),
            iterations=2,
            warmup=0,
            workload_contract_path=WORKLOAD_MANIFEST_PATH,
        )
        identity = artifact["runtimeIdentity"]
        self.assertEqual(identity["providerName"], "doe-gpu/native-direct")
        self.assertEqual(identity["packageName"], "doe-gpu")
        self.assertTrue(identity["packageVersion"])
        self.assertTrue(identity["packageLockHash"])

    def test_write_and_load_round_trip(self) -> None:
        artifact = build_run_artifact(
            run_result=_make_run_result(),
            product="doe",
            executor_id="doe_direct_vulkan",
            workload_spec=_make_spec(),
            run_config=_make_run_config(),
            iterations=2,
            warmup=0,
            workload_contract_path=WORKLOAD_MANIFEST_PATH,
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "test.run.json"
            write_run_artifact(artifact, path)
            loaded = load_run_artifact(path)
            self.assertEqual(loaded["product"], "doe")
            self.assertEqual(loaded["workload"]["id"], "compute_test")
            self.assertEqual(len(loaded["samples"]), 1)
            self.assertEqual(
                loaded["samples"][0]["timing"]["traceMetaSource"],
                "doe-execution-total-ns",
            )
            self.assertEqual(loaded["samples"][0]["commandRepeat"], 4)
            self.assertEqual(loaded["samples"][0]["timingNormalizationDivisor"], 2.0)
            self.assertEqual(
                loaded["samples"][0]["workloadUnitNormalizationDivisor"],
                4.0,
            )

    def test_load_normalizes_legacy_run_artifact(self) -> None:
        legacy_payload = {
            "schemaVersion": 2,
            "artifactKind": "run",
            "generatedAt": "2026-04-05T12:00:00+00:00",
            "product": "doe",
            "executorId": "doe_direct_vulkan",
            "workloadContract": {
                "path": str(WORKLOAD_MANIFEST_PATH),
                "sha256": "a" * 64,
            },
            "workload": {
                "id": "compute_test",
                "name": "test workload",
                "description": "unit test",
                "domain": "compute",
                "commandsPath": "examples/test.json",
                "quirksPath": "examples/quirks/noop.json",
                "vendor": "amd",
                "api": "vulkan",
                "family": "gfx11",
                "driver": "24.0.0",
                "comparable": True,
                "benchmarkClass": "comparable",
                "comparabilityNotes": "test",
                "directionalReason": "",
                "pathAsymmetry": False,
                "pathAsymmetryNote": "",
                "claimEligible": True,
                "strictNormalizationUnit": ""
            },
            "runParameters": {
                "iterations": 1,
                "warmup": 0,
                "commandRepeat": 1,
                "ignoreFirstOps": 0,
                "timingDivisor": 1.0,
                "uploadBufferUsage": "copy-dst-copy-src",
                "uploadSubmitEvery": 1,
                "allowNoExecution": False,
                "timingNormalizationNote": "",
                "comparabilityMode": "strict",
                "requiredTimingClass": "operation"
            },
            "host": {
                "os": "linux",
                "arch": "x86_64"
            },
            "commandSamples": _make_run_result()["commandSamples"],
            "stats": {
                "count": 1
            },
            "timingsMs": [
                8.0
            ],
            "timingSources": [
                "doe-execution-total-ns"
            ],
            "timingClasses": [
                "operation"
            ],
            "lastMeta": {}
        }
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "legacy.run.json"
            path.write_text(json.dumps(legacy_payload), encoding="utf-8")
            loaded = load_run_artifact(path)
            self.assertEqual(loaded["artifactKind"], RUN_ARTIFACT_KIND)
            self.assertEqual(loaded["workloadManifest"]["ownership"], "standalone")

    def test_load_rejects_wrong_kind(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "bad.json"
            path.write_text(
                json.dumps({"artifactKind": "report", "schemaVersion": 1}),
                encoding="utf-8",
            )
            with self.assertRaises(ValueError):
                load_run_artifact(path)

    def test_load_rejects_missing_file(self) -> None:
        with self.assertRaises(FileNotFoundError):
            load_run_artifact("/nonexistent/path.json")

    def test_artifact_filename(self) -> None:
        name = artifact_filename("doe", "compute_test", "20260405T120000Z")
        self.assertEqual(name, "doe-compute_test-20260405T120000Z.run.json")


if __name__ == "__main__":
    unittest.main()
