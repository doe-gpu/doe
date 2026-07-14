from __future__ import annotations

import importlib.util
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = REPO_ROOT / "browser/chromium/scripts/check-browser-benchmark-superset.py"
HASH_A = "a" * 64
HASH_B = "b" * 64
HASH_C = "c" * 64
TRACE_CONFIG_PATH = REPO_ROOT / "config/browser-metal-native-trace.json"
TRACE_CONFIG_HASH = hashlib.sha256(TRACE_CONFIG_PATH.read_bytes()).hexdigest()


def _browser_workload() -> dict[str, Any]:
    return {
        "sourceComparable": True,
        "sourceClaimEligible": True,
        "benchmarkClass": "comparable",
    }


def _l1_contract_fields() -> dict[str, Any]:
    return {
        "comparabilityExpectation": "strict",
        "browserWorkload": _browser_workload(),
    }


def _load_module() -> Any:
    spec = importlib.util.spec_from_file_location("check_browser_benchmark_superset", MODULE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load module: {MODULE_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _runtime_selection(mode: str, selected_runtime: str | None = None) -> dict[str, Any]:
    runtime = selected_runtime or mode
    artifact_identity: dict[str, Any] = {
        "browserExecutablePath": f"/tmp/{runtime}/chrome",
        "browserExecutableSha256": HASH_A,
        "dawnRuntimePath": f"/tmp/{runtime}/chrome",
        "dawnRuntimeSha256": HASH_A,
        "doeLibPath": None,
        "doeLibSha256": None,
    }
    if runtime == "doe":
        artifact_identity["doeLibPath"] = "/tmp/libwebgpu_doe_full.so"
        artifact_identity["doeLibSha256"] = HASH_B
    return {
        "selectionMode": mode,
        "selectedRuntime": runtime,
        "forcedMode": None if mode == "auto" else mode,
        "fallbackApplied": mode == "auto" and runtime == "dawn",
        "fallbackReasonCode": "runtime_artifact_missing" if mode == "auto" and runtime == "dawn" else "",
        "hiddenFallbackAllowed": False,
        "profile": {
            "profileId": "",
            "vendor": "unknown",
            "api": "unknown",
            "deviceFamily": "unknown",
            "driver": "unknown",
        },
        "selectorVersion": "browser-runtime-selector-v1",
        "artifactIdentity": artifact_identity,
        "launchArgsHash": HASH_A,
    }


def _mode_detail(mode: str, selected_runtime: str | None = None) -> dict[str, Any]:
    runtime = selected_runtime or mode
    selection = _runtime_selection(mode, runtime)
    adapter_info = {
        "vendor": "Doe" if runtime == "doe" else "Apple",
        "architecture": "metal" if runtime == "doe" else "applegpu",
        "device": "Doe Metal Adapter" if runtime == "doe" else "Apple M3",
        "description": "",
    }
    active_runtime_proof = {
        "schemaVersion": 1,
        "identitySource": "wgpuAdapterGetInfo",
        "selectedRuntime": runtime,
        "expected": (
            {"vendor": "Doe", "architecture": "metal"}
            if runtime == "doe"
            else {"vendorMustNotEqual": "Doe", "vendorMustBeNonEmpty": True}
        ),
        "observed": dict(adapter_info),
        "matched": True,
    }
    compiler_surface = (
        "doe_runtime_embedded_shader_compiler"
        if runtime == "doe"
        else "dawn_runtime_embedded_shader_compiler"
    )
    return {
        "mode": mode,
        "module": "browser_layered_bench",
        "opCode": "mode_result",
        "seq": 1 if mode == "dawn" else 2,
        "previousHash": HASH_A,
        "hash": HASH_B,
        "runtimeSelection": selection,
        "shaderCompilerIdentity": {
            "compilerSurface": compiler_surface,
            "compilerArtifactPath": "/tmp/libwebgpu_doe_full.so" if runtime == "doe" else f"/tmp/{runtime}/chrome",
            "compilerArtifactSha256": HASH_B if runtime == "doe" else HASH_A,
            "identitySource": "runtime_artifact_identity",
        },
        "runtimeEvidence": {
            "modeRequested": mode,
            "runtimeSelection": selection,
            "pageTargetKind": "http",
            "browserVersion": "Chromium",
            "userAgent": "Chromium",
            "activeRuntimeProof": active_runtime_proof,
            "nativeMetalTrace": {
                "requested": False,
                "enabled": False,
                "status": "disabled",
                "reason": "not_requested",
                "traceId": "doe-metal-browser-command-path-v1",
                "traceKind": "doe_metal_browser_command_path_v1",
                "configPath": str(TRACE_CONFIG_PATH),
                "configSha256": TRACE_CONFIG_HASH,
                "environmentVariable": "DOE_METAL_BROWSER_TRACE_PATH",
                "evidenceClass": "diagnostic_only",
                "timingsPerturbed": False,
            },
        },
        "runtimeProbe": {
            "webgpuAvailable": True,
            "adapterAvailable": True,
            "adapterInfo": adapter_info,
            "adapterIdentity": {
                "adapterInfoSha256": HASH_A,
                "featureCount": 0,
            },
            "featureCount": 0,
            "errors": [],
        },
    }


def _report() -> dict[str, Any]:
    return {
        "schemaVersion": 5,
        "reportKind": "browser-layered-diagnostic",
        "comparisonStatus": "diagnostic",
        "claimStatus": "diagnostic",
        "projectionContractHash": HASH_A,
        "workloadIdentity": {
            "kind": "browser_layered_superset",
            "sourceWorkloadsSha256": HASH_A,
            "projectionContractHash": HASH_A,
            "workflowManifestSha256": HASH_B,
        },
        "invocation": {
            "platform": "darwin",
        },
        "methodology": {
            "sourceKernelSamples": 1,
            "sourceKernelWarmupSamples": 0,
            "sourceKernelSubmitPolicy": "iteration-batch-v1",
            "adapterRequest": {
                "powerPreference": "high-performance",
            },
            "nativeMetalTrace": {
                "requested": False,
                "configPath": str(TRACE_CONFIG_PATH),
                "configSha256": TRACE_CONFIG_HASH,
                "traceId": "doe-metal-browser-command-path-v1",
                "environmentVariable": "DOE_METAL_BROWSER_TRACE_PATH",
                "evidenceClass": "diagnostic_only",
                "timingsPerturbed": False,
                "scoreEligible": True,
            },
        },
        "browserEnvironmentEvidence": {},
        "modeOrder": ["dawn", "doe"],
        "modeRunDetails": [_mode_detail("dawn"), _mode_detail("doe")],
        "l1": {
            "rows": [
                {
                    "sourceWorkloadId": "copy_buffer",
                    "domain": "copy",
                    "claimScope": "l1_strict_candidate",
                    **_l1_contract_fields(),
                    "requiredStatus": "ok",
                    "runtimes": {
                        "dawn": {"status": "ok", "statusCode": "ok"},
                        "doe": {"status": "ok", "statusCode": "ok"},
                    },
                }
            ]
        },
        "l2": {"rows": []},
    }


def _auto_report(selected_runtime: str = "dawn") -> dict[str, Any]:
    report = _report()
    report["modeOrder"] = ["auto"]
    report["modeRunDetails"] = [_mode_detail("auto", selected_runtime)]
    report["l1"]["rows"][0]["runtimes"] = {
        "auto": {"status": "ok", "statusCode": "ok"},
    }
    return report


def _manifest() -> dict[str, Any]:
    return {
        "projectionContractHash": HASH_A,
        "sourceWorkloadsSha256": HASH_A,
        "rows": [
            {
                "sourceWorkloadId": "copy_buffer",
                "domain": "copy",
                "projectionClass": "high",
                "claimScope": "l1_strict_candidate",
                **_l1_contract_fields(),
                "requiredStatus": "ok",
            }
        ],
    }


def _projection_manifest() -> dict[str, Any]:
    return {
        "sourceWorkloadsPath": "bench/workloads/specialized/workloads.amd.vulkan.superset.json",
        "sourceWorkloadsSha256": HASH_A,
        "rulesPath": "browser/chromium/bench/projection-rules.json",
        "rulesSha256": HASH_A,
        "projectionContractHash": HASH_A,
        "rows": [],
    }


def _projection_row(
    comparability: str = "strict",
    benchmark_class: str = "comparable",
) -> dict[str, Any]:
    claim_scope = (
        "l1_strict_candidate" if comparability == "strict" else "l1_component_only"
    )
    return {
        "sourceWorkloadId": "copy_buffer",
        "sourceWorkloadName": "copy buffer",
        "domain": "copy",
        "projectionClass": "high",
        "layerTarget": "l1_browser_api",
        "scenarioTemplate": "copy_buffer",
        "comparabilityExpectation": comparability,
        "requiredStatus": "ok",
        "claimScope": claim_scope,
        "claimLanguage": "test claim language",
        "projectionNote": "test projection note",
        "browserWorkload": {
            "sourceComparable": True,
            "sourceClaimEligible": True,
            "benchmarkClass": benchmark_class,
        },
    }


def _parseable_projection_manifest(row: dict[str, Any]) -> dict[str, Any]:
    manifest = _projection_manifest()
    manifest["schemaVersion"] = 6
    manifest["generatedAt"] = "2026-07-04T00:00:00Z"
    manifest["sourceWorkloadCount"] = 1
    manifest["rows"] = [row]
    return manifest


def _workflow_manifest() -> dict[str, Any]:
    return {
        "schemaVersion": 3,
        "promotionGateRequiredApprovals": [
            "browser_runtime_integration_owner",
            "browser_quality_owner",
            "browser_benchmark_methodology_owner",
            "module_contracts_owner",
            "coordinator",
        ],
        "rows": [],
    }


def _source_kernel_manifest_row() -> dict[str, Any]:
    row = _projection_row()
    row["sourceWorkloadId"] = "compute_workgroup_atomic_1024"
    row["domain"] = "compute"
    row["scenarioTemplate"] = "compute_dispatch_basic"
    row["browserWorkload"] = {
        "sourceComparable": True,
        "sourceClaimEligible": True,
        "benchmarkClass": "comparable",
        "computeProjection": "source_kernel_dispatch_oracle_v2",
        "bindGroupLayoutMode": "explicit_min_binding_size_v1",
        "readbackBindingPolicy": "first_writable_storage_binding_v1",
        "commandsPath": "examples/workgroup_atomic_commands.json",
        "commandsSha256": HASH_A,
        "kernelPath": "bench/kernels/workgroup_atomic.wgsl",
        "kernelSha256": HASH_B,
        "dispatchX": 1024,
        "dispatchY": 1,
        "dispatchZ": 1,
        "dispatchRepeat": 100,
        "warmupDispatchCount": 1,
        "storageBindings": [
            {
                "group": 0,
                "binding": 0,
                "bufferSize": 1024,
                "minBindingSize": 1024,
                "bufferType": "storage",
                "bufferBindingType": "storage",
            }
        ],
        "outputOracle": {
            "schemaVersion": 1,
            "kind": "sha256_exact_v1",
            "initialization": "zero_fill_v1",
            "bindingGroup": 0,
            "binding": 0,
            "dispatchCount": 1,
            "expectedSha256": HASH_C,
            "referenceId": "cpu_test_reference_v1",
        },
    }
    return row


def _source_kernel_metrics() -> dict[str, Any]:
    metrics: dict[str, Any] = {
        "iterations": 2,
        "sourceKernelSampleCount": 2,
        "orderBalancedSampleCount": 2,
        "sourceKernelWarmupSampleCount": 0,
        "sourceKernelWarmupDispatches": 0,
        "sourceKernelWarmupSubmits": 0,
        "sourceKernelSubmitPolicy": "iteration-batch-v1",
        "submitsPerSample": 2,
        "warmupSubmitCount": 1,
        "totalWarmupDispatches": 2,
        "totalWarmupSubmits": 2,
        "totalSubmits": 4,
        "dispatchesPerSample": 200,
        "dispatchWorkgroupsX": 1024,
        "dispatchWorkgroupsY": 1,
        "dispatchWorkgroupsZ": 1,
        "dispatchRepeat": 100,
        "warmupDispatchCount": 1,
        "totalDispatches": 400,
        "dispatchElapsedMsSamples": [10.0, 12.0],
        "encodeSubmitMsSamples": [2.0, 4.0],
        "waitMsSamples": [8.0, 8.0],
        "usPerOpSamples": [50.0, 60.0],
        "sourceKernelTimingPolicy": "batched_source_kernel_samples_v1",
        "kernelPath": "bench/kernels/workgroup_atomic.wgsl",
        "kernelSha256": HASH_B,
        "commandsPath": "examples/workgroup_atomic_commands.json",
        "commandsSha256": HASH_A,
        "bindGroupLayoutMode": "explicit_min_binding_size_v1",
        "readbackBindingPolicy": "first_writable_storage_binding_v1",
        "bindGroupLayoutEntryCount": 1,
        "bindGroupLayoutEntries": [
            {
                "group": 0,
                "binding": 0,
                "bufferBindingType": "storage",
                "minBindingSize": 1024,
            }
        ],
        "minBindingSizeBytes": 1024,
        "storageBindingCount": 1,
        "storageBufferBytes": 1024,
        "storageBufferUsage": ["STORAGE", "COPY_DST", "COPY_SRC"],
        "readbackBindingGroup": 0,
        "readbackBinding": 0,
        "readbackBytes": 1024,
        "readbackChecksum": 1234,
        "readbackSha256": HASH_C,
        "readbackSampleBytes": [1, 2, 3, 4] * 4,
        "outputOracleResetMs": 0.1,
        "outputOracleDispatchMs": 0.1,
        "outputOracleReadbackMs": 0.1,
        "outputOracleSchemaVersion": 1,
        "outputOracleKind": "sha256_exact_v1",
        "outputOracleInitialization": "zero_fill_v1",
        "outputOracleBindingGroup": 0,
        "outputOracleBinding": 0,
        "outputOracleDispatchCount": 1,
        "outputOracleExpectedSha256": HASH_C,
        "outputOracleActualSha256": HASH_C,
        "outputOracleReferenceId": "cpu_test_reference_v1",
        "outputOracleSampleBytes": [1, 2, 3, 4] * 4,
        "outputOracleMatched": True,
        "createBindGroupLayoutMs": 0.1,
        "createPipelineLayoutMs": 0.1,
        "submitReadbackMs": 0.1,
        "mapReadMs": 0.1,
    }
    for metric_name, samples in (
        ("dispatchElapsedMs", metrics["dispatchElapsedMsSamples"]),
        ("encodeSubmitMs", metrics["encodeSubmitMsSamples"]),
        ("waitMs", metrics["waitMsSamples"]),
        ("usPerOp", metrics["usPerOpSamples"]),
    ):
        metrics[metric_name] = samples[0]
        metrics[f"{metric_name}Avg"] = sum(samples) / len(samples)
        metrics[f"{metric_name}P10"] = samples[0]
        metrics[f"{metric_name}P50"] = samples[0]
        metrics[f"{metric_name}P95"] = samples[1]
        metrics[f"{metric_name}P99"] = samples[1]
    return metrics


class BrowserBenchmarkSupersetCheckerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = _load_module()

    def test_report_coverage_requires_runtime_selector_identity(self) -> None:
        errors = self.module.check_report_coverage(
            _report(),
            _manifest(),
            {"rows": []},
            ["dawn", "doe"],
        )

        self.assertEqual(errors, [])

    def test_report_coverage_accepts_auto_mode_runtime_selector_identity(self) -> None:
        errors = self.module.check_report_coverage(
            _auto_report("dawn"),
            _manifest(),
            {"rows": []},
            ["auto"],
        )

        self.assertEqual(errors, [])

    def test_source_kernel_runtime_evidence_requires_phase_samples(self) -> None:
        row = _source_kernel_manifest_row()
        mode_result = {
            "status": "ok",
            "statusCode": "ok",
            "metrics": _source_kernel_metrics(),
        }

        errors = self.module.check_source_kernel_runtime_evidence(
            mode_result,
            row,
            "compute_workgroup_atomic_1024",
            "doe",
        )

        self.assertEqual(errors, [])

        del mode_result["metrics"]["waitMsSamples"]
        errors = self.module.check_source_kernel_runtime_evidence(
            mode_result,
            row,
            "compute_workgroup_atomic_1024",
            "doe",
        )

        self.assertIn(
            "compute_workgroup_atomic_1024: metrics.waitMsSamples must have sourceKernelSampleCount entries for mode 'doe'",
            errors,
        )

    def test_source_kernel_runtime_evidence_rejects_oracle_mismatch(self) -> None:
        row = _source_kernel_manifest_row()
        metrics = _source_kernel_metrics()
        metrics["outputOracleActualSha256"] = HASH_A
        metrics["outputOracleMatched"] = False

        errors = self.module.check_source_kernel_runtime_evidence(
            {"status": "ok", "statusCode": "ok", "metrics": metrics},
            row,
            "compute_workgroup_atomic_1024",
            "doe",
        )

        self.assertIn(
            "compute_workgroup_atomic_1024: output oracle SHA-256 mismatch for mode 'doe'",
            errors,
        )
        self.assertIn(
            "compute_workgroup_atomic_1024: output oracle did not match for mode 'doe'",
            errors,
        )

    def test_source_kernel_cross_runtime_parity_rejects_hash_drift(self) -> None:
        report_row = {
            "runtimes": {
                "dawn": {
                    "status": "ok",
                    "metrics": {"readbackSha256": HASH_A},
                },
                "doe": {
                    "status": "ok",
                    "metrics": {"readbackSha256": HASH_B},
                },
            }
        }

        errors = self.module.check_source_kernel_cross_runtime_parity(
            report_row,
            _source_kernel_manifest_row(),
            "L1:compute_workgroup_atomic_1024",
        )

        self.assertEqual(len(errors), 1)
        self.assertIn("timed output SHA-256 differs across Dawn and Doe", errors[0])

    def test_report_coverage_rejects_missing_adapter_request_policy(self) -> None:
        report = _report()
        report["methodology"] = {}

        errors = self.module.check_report_coverage(
            report,
            _manifest(),
            {"rows": []},
            ["dawn", "doe"],
        )

        self.assertIn("report methodology.adapterRequest must be an object", errors)

    def test_report_methodology_accepts_repeated_paired_schedule(self) -> None:
        methodology = _report()["methodology"]
        methodology["modeSchedule"] = "paired-balanced"
        methodology["modeScheduleRepetitions"] = 8

        errors = self.module.check_report_methodology(methodology, "paired-balanced")

        self.assertEqual(errors, [])

    def test_report_methodology_rejects_repeated_grouped_schedule(self) -> None:
        methodology = _report()["methodology"]
        methodology["modeSchedule"] = "grouped"
        methodology["modeScheduleRepetitions"] = 2

        errors = self.module.check_report_methodology(methodology, "grouped")

        self.assertIn(
            "report methodology.modeScheduleRepetitions greater than 1 requires paired mode scheduling",
            errors,
        )

    def test_native_metal_trace_evidence_recomputes_file_totals(self) -> None:
        row = {
            "schemaVersion": 1,
            "traceKind": "doe_metal_browser_command_path_v1",
            "sequence": 1,
            "submissionCount": 2,
            "sourceCommandBufferCount": 2,
            "recordedCommandCount": 7,
            "nativeCommandBufferCount": 2,
            "commandBufferCreateNs": 11,
            "commandEncodeNs": 13,
            "commandCommitNs": 17,
            "waitCompletedNs": 19,
            "deferredCopyNs": 23,
            "deferredResolveNs": 29,
            "directReadback": True,
        }
        trace_bytes = (json.dumps(row, separators=(",", ":")) + "\n").encode()
        with tempfile.TemporaryDirectory() as tmp_dir:
            trace_path = Path(tmp_dir) / "trace.jsonl"
            trace_path.write_bytes(trace_bytes)
            evidence = {
                "requested": True,
                "enabled": True,
                "status": "ok",
                "reason": "",
                "traceId": "doe-metal-browser-command-path-v1",
                "traceKind": "doe_metal_browser_command_path_v1",
                "configPath": str(TRACE_CONFIG_PATH),
                "configSha256": TRACE_CONFIG_HASH,
                "environmentVariable": "DOE_METAL_BROWSER_TRACE_PATH",
                "evidenceClass": "diagnostic_only",
                "timingsPerturbed": True,
                "tracePath": str(trace_path),
                "traceSha256": hashlib.sha256(trace_bytes).hexdigest(),
                "byteCount": len(trace_bytes),
                "rowCount": 1,
                "malformedRowCount": 0,
                "totals": {
                    field: row[field]
                    for field in self.module.NATIVE_METAL_TRACE_NUMERIC_FIELDS
                },
                "errors": [],
            }

            errors = self.module.check_native_metal_trace_evidence(
                evidence,
                "modeRunDetails[doe]",
                True,
                "doe",
            )

        self.assertEqual(errors, [])

    def test_native_metal_trace_evidence_rejects_summary_drift(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            trace_path = Path(tmp_dir) / "trace.jsonl"
            trace_path.write_text(
                '{"schemaVersion":1,"traceKind":"doe_metal_browser_command_path_v1",'
                '"sequence":1,"submissionCount":1,"sourceCommandBufferCount":1,'
                '"recordedCommandCount":1,"nativeCommandBufferCount":1,'
                '"commandBufferCreateNs":1,"commandEncodeNs":1,"commandCommitNs":1,'
                '"waitCompletedNs":1,"deferredCopyNs":1,"deferredResolveNs":1,'
                '"directReadback":false}\n',
                encoding="utf-8",
            )
            trace_bytes = trace_path.read_bytes()
            totals = {field: 1 for field in self.module.NATIVE_METAL_TRACE_NUMERIC_FIELDS}
            totals["commandEncodeNs"] = 99
            evidence = {
                "requested": True,
                "enabled": True,
                "status": "ok",
                "traceId": "doe-metal-browser-command-path-v1",
                "traceKind": "doe_metal_browser_command_path_v1",
                "configSha256": TRACE_CONFIG_HASH,
                "evidenceClass": "diagnostic_only",
                "timingsPerturbed": True,
                "tracePath": str(trace_path),
                "traceSha256": hashlib.sha256(trace_bytes).hexdigest(),
                "byteCount": len(trace_bytes),
                "rowCount": 1,
                "malformedRowCount": 0,
                "totals": totals,
                "errors": [],
            }

            errors = self.module.check_native_metal_trace_evidence(
                evidence,
                "modeRunDetails[doe]",
                True,
                "doe",
            )

        self.assertIn("modeRunDetails[doe]: nativeMetalTrace totals mismatch", errors)

    def test_report_coverage_accepts_category_filtered_report(self) -> None:
        manifest = _manifest()
        manifest["rows"].append(
            {
                "sourceWorkloadId": "render_triangle",
                "domain": "render",
                "projectionClass": "high",
                "claimScope": "l1_strict_candidate",
                **_l1_contract_fields(),
                "requiredStatus": "ok",
            }
        )
        report = _report()
        report["workloadFilter"] = {
            "kind": "category",
            "categories": ["memory"],
            "l1RowsBeforeFilter": 2,
            "l1RowsAfterFilter": 1,
            "l2RowsBeforeFilter": 0,
            "l2RowsAfterFilter": 0,
        }

        errors = self.module.check_report_coverage(
            report,
            manifest,
            {"rows": []},
            ["dawn", "doe"],
        )

        self.assertEqual(errors, [])

    def test_report_coverage_rejects_category_filtered_row_outside_filter(self) -> None:
        manifest = _manifest()
        manifest["rows"].append(
            {
                "sourceWorkloadId": "render_triangle",
                "domain": "render",
                "projectionClass": "high",
                "claimScope": "l1_strict_candidate",
                **_l1_contract_fields(),
                "requiredStatus": "ok",
            }
        )
        report = _report()
        report["workloadFilter"] = {
            "kind": "category",
            "categories": ["memory"],
            "l1RowsBeforeFilter": 2,
            "l1RowsAfterFilter": 1,
            "l2RowsBeforeFilter": 0,
            "l2RowsAfterFilter": 0,
        }
        report["l1"]["rows"].append(
            {
                "sourceWorkloadId": "render_triangle",
                "domain": "render",
                "claimScope": "l1_strict_candidate",
                **_l1_contract_fields(),
                "requiredStatus": "ok",
                "runtimes": {
                    "dawn": {"status": "ok", "statusCode": "ok"},
                    "doe": {"status": "ok", "statusCode": "ok"},
                },
            }
        )

        errors = self.module.check_report_coverage(
            report,
            manifest,
            {"rows": []},
            ["dawn", "doe"],
        )

        self.assertIn("report contains L1 row outside workloadFilter: render_triangle", errors)

    def test_report_coverage_accepts_cross_category_l1_and_l2_filtered_report(self) -> None:
        resource_path = "browser/chromium/resources/fawn-heavy-particles.html"
        resource_sha256 = self.module.file_sha256(REPO_ROOT / resource_path)
        manifest = _manifest()
        manifest["rows"].append(
            {
                "sourceWorkloadId": "texture_sampling",
                "domain": "texture-raster",
                "projectionClass": "high",
                "claimScope": "l1_strict_candidate",
                **_l1_contract_fields(),
                "requiredStatus": "ok",
            }
        )
        workflow = {
            "rows": [
                {
                    "id": "fawn_visual_particle_trails",
                    "scenarioTemplate": "fawn_visual_resource",
                    "resourcePath": resource_path,
                    "resourceSha256": resource_sha256,
                    "claimScope": "l2_diagnostic_only",
                    "required": False,
                    "requiredStatus": "optional",
                }
            ]
        }
        report = _report()
        report["workloadFilter"] = {
            "kind": "category",
            "categories": ["texture", "visual"],
            "l1RowsBeforeFilter": 2,
            "l1RowsAfterFilter": 1,
            "l2RowsBeforeFilter": 1,
            "l2RowsAfterFilter": 1,
        }
        report["l1"]["rows"] = [
            {
                "sourceWorkloadId": "texture_sampling",
                "domain": "texture-raster",
                "claimScope": "l1_strict_candidate",
                **_l1_contract_fields(),
                "requiredStatus": "ok",
                "runtimes": {
                    "dawn": {"status": "ok", "statusCode": "ok"},
                    "doe": {"status": "ok", "statusCode": "ok"},
                },
            }
        ]
        report["l2"]["rows"] = [
            {
                "id": "fawn_visual_particle_trails",
                "scenarioTemplate": "fawn_visual_resource",
                "resourcePath": resource_path,
                "resourceSha256": resource_sha256,
                "claimScope": "l2_diagnostic_only",
                "requiredStatus": "optional",
                "runtimes": {
                    "dawn": {
                        "status": "ok",
                        "statusCode": "ok",
                        "metrics": {"resourceSha256": resource_sha256},
                    },
                    "doe": {
                        "status": "ok",
                        "statusCode": "ok",
                        "metrics": {"resourceSha256": resource_sha256},
                    },
                },
            }
        ]

        errors = self.module.check_report_coverage(
            report,
            manifest,
            workflow,
            ["dawn", "doe"],
        )

        self.assertEqual(errors, [])

    def test_report_coverage_rejects_visual_resource_hash_drift(self) -> None:
        resource_path = "browser/chromium/resources/fawn-heavy-particles.html"
        resource_sha256 = self.module.file_sha256(REPO_ROOT / resource_path)
        workflow = {
            "rows": [
                {
                    "id": "fawn_visual_particle_trails",
                    "scenarioTemplate": "fawn_visual_resource",
                    "resourcePath": resource_path,
                    "resourceSha256": resource_sha256,
                    "claimScope": "l2_diagnostic_only",
                    "required": False,
                    "requiredStatus": "optional",
                }
            ]
        }
        report = _report()
        report["l2"]["rows"] = [
            {
                "id": "fawn_visual_particle_trails",
                "scenarioTemplate": "fawn_visual_resource",
                "resourcePath": resource_path,
                "resourceSha256": HASH_A,
                "claimScope": "l2_diagnostic_only",
                "requiredStatus": "optional",
                "runtimes": {
                    "dawn": {
                        "status": "ok",
                        "statusCode": "ok",
                        "metrics": {"resourceSha256": resource_sha256},
                    },
                    "doe": {
                        "status": "ok",
                        "statusCode": "ok",
                        "metrics": {"resourceSha256": HASH_B},
                    },
                },
            }
        ]

        errors = self.module.check_report_coverage(
            report,
            _manifest(),
            workflow,
            ["dawn", "doe"],
        )

        self.assertIn("L2 row resourceSha256 drift for fawn_visual_particle_trails", errors)
        self.assertIn(
            "L2:fawn_visual_particle_trails: metrics.resourceSha256 drift for mode 'doe'",
            errors,
        )

    def test_required_modes_accepts_auto(self) -> None:
        self.assertEqual(self.module.parse_required_modes("auto"), ["auto"])

    def test_report_coverage_rejects_missing_doe_library_hash(self) -> None:
        report = _report()
        selection = report["modeRunDetails"][1]["runtimeEvidence"]["runtimeSelection"]
        selection["artifactIdentity"]["doeLibSha256"] = None
        report["modeRunDetails"][1]["runtimeSelection"] = selection

        errors = self.module.check_report_coverage(
            report,
            _manifest(),
            {"rows": []},
            ["dawn", "doe"],
        )

        self.assertTrue(
            any("artifactIdentity.doeLibSha256" in error for error in errors),
            errors,
        )

    def test_report_coverage_rejects_legacy_report_schema(self) -> None:
        report = _report()
        report["schemaVersion"] = 4

        errors = self.module.check_report_coverage(
            report,
            _manifest(),
            {"rows": []},
            ["dawn", "doe"],
        )

        self.assertIn("report schemaVersion must be 5", errors)

    def test_report_coverage_rejects_missing_dawn_runtime_hash(self) -> None:
        report = _report()
        selection = report["modeRunDetails"][1]["runtimeEvidence"]["runtimeSelection"]
        selection["artifactIdentity"]["dawnRuntimeSha256"] = None
        report["modeRunDetails"][1]["runtimeSelection"] = selection

        errors = self.module.check_report_coverage(
            report,
            _manifest(),
            {"rows": []},
            ["dawn", "doe"],
        )

        self.assertTrue(
            any("artifactIdentity.dawnRuntimeSha256" in error for error in errors),
            errors,
        )

    def test_report_coverage_rejects_hidden_fallback(self) -> None:
        report = _report()
        selection = report["modeRunDetails"][1]["runtimeEvidence"]["runtimeSelection"]
        selection["fallbackApplied"] = True
        report["modeRunDetails"][1]["runtimeSelection"] = selection

        errors = self.module.check_report_coverage(
            report,
            _manifest(),
            {"rows": []},
            ["dawn", "doe"],
        )

        self.assertTrue(
            any("runtimeSelection.fallbackApplied must be false" in error for error in errors),
            errors,
        )

    def test_report_coverage_rejects_missing_runtime_profile(self) -> None:
        report = _report()
        selection = report["modeRunDetails"][1]["runtimeEvidence"]["runtimeSelection"]
        selection.pop("profile")
        report["modeRunDetails"][1]["runtimeSelection"] = selection

        errors = self.module.check_report_coverage(
            report,
            _manifest(),
            {"rows": []},
            ["dawn", "doe"],
        )

        self.assertTrue(any("runtimeSelection.profile missing" in error for error in errors), errors)

    def test_report_coverage_rejects_missing_adapter_identity(self) -> None:
        report = _report()
        report["modeRunDetails"][1]["runtimeProbe"].pop("adapterIdentity")

        errors = self.module.check_report_coverage(
            report,
            _manifest(),
            {"rows": []},
            ["dawn", "doe"],
        )

        self.assertTrue(any("adapterIdentity missing" in error for error in errors), errors)

    def test_report_coverage_rejects_doe_runtime_identity_mismatch(self) -> None:
        report = _report()
        detail = report["modeRunDetails"][1]
        detail["runtimeProbe"]["adapterInfo"]["vendor"] = "Apple"
        detail["runtimeEvidence"]["activeRuntimeProof"]["observed"]["vendor"] = "Apple"
        detail["runtimeEvidence"]["activeRuntimeProof"]["matched"] = False

        errors = self.module.check_report_coverage(
            report,
            _manifest(),
            {"rows": []},
            ["dawn", "doe"],
        )

        self.assertIn(
            "modeRunDetails[doe]: active runtime does not match requested doe runtime",
            errors,
        )

    def test_report_coverage_rejects_missing_active_runtime_proof(self) -> None:
        report = _report()
        report["modeRunDetails"][1]["runtimeEvidence"].pop("activeRuntimeProof")

        errors = self.module.check_report_coverage(
            report,
            _manifest(),
            {"rows": []},
            ["dawn", "doe"],
        )

        self.assertIn("modeRunDetails[doe]: activeRuntimeProof missing", errors)

    def test_report_coverage_rejects_missing_invocation_platform(self) -> None:
        report = _report()
        report.pop("invocation")

        errors = self.module.check_report_coverage(
            report,
            _manifest(),
            {"rows": []},
            ["dawn", "doe"],
        )

        self.assertIn(
            "report invocation.platform must be darwin, linux, or win32",
            errors,
        )

    def test_report_coverage_rejects_active_runtime_observation_drift(self) -> None:
        report = _report()
        report["modeRunDetails"][1]["runtimeEvidence"]["activeRuntimeProof"][
            "observed"
        ]["device"] = "fabricated"

        errors = self.module.check_report_coverage(
            report,
            _manifest(),
            {"rows": []},
            ["dawn", "doe"],
        )

        self.assertIn(
            "modeRunDetails[doe]: activeRuntimeProof.observed drift",
            errors,
        )

    def test_report_coverage_rejects_doe_backend_incompatible_with_platform(self) -> None:
        report = _report()
        detail = report["modeRunDetails"][1]
        detail["runtimeProbe"]["adapterInfo"]["architecture"] = "vulkan"
        proof = detail["runtimeEvidence"]["activeRuntimeProof"]
        proof["expected"]["architecture"] = "vulkan"
        proof["observed"]["architecture"] = "vulkan"

        errors = self.module.check_report_coverage(
            report,
            _manifest(),
            {"rows": []},
            ["dawn", "doe"],
        )

        self.assertIn(
            "modeRunDetails[doe]: activeRuntimeProof expected Doe architecture "
            "must be metal on darwin",
            errors,
        )
        self.assertIn(
            "modeRunDetails[doe]: active runtime does not match requested doe runtime",
            errors,
        )

    def test_report_coverage_rejects_missing_shader_compiler_identity(self) -> None:
        report = _report()
        report["modeRunDetails"][1].pop("shaderCompilerIdentity")

        errors = self.module.check_report_coverage(
            report,
            _manifest(),
            {"rows": []},
            ["dawn", "doe"],
        )

        self.assertTrue(any("shaderCompilerIdentity missing" in error for error in errors), errors)

    def test_report_coverage_rejects_missing_trace_hash(self) -> None:
        report = _report()
        report["modeRunDetails"][1].pop("hash")

        errors = self.module.check_report_coverage(
            report,
            _manifest(),
            {"rows": []},
            ["dawn", "doe"],
        )

        self.assertTrue(any("hash must be sha256 hex" in error for error in errors), errors)

    def test_report_coverage_rejects_missing_workload_identity(self) -> None:
        report = _report()
        report.pop("workloadIdentity")

        errors = self.module.check_report_coverage(
            report,
            _manifest(),
            {"rows": []},
            ["dawn", "doe"],
        )

        self.assertIn("report workloadIdentity missing", errors)

    def test_parse_workflow_manifest_requires_module_contracts_owner(self) -> None:
        workflow = _workflow_manifest()
        workflow["promotionGateRequiredApprovals"].remove("module_contracts_owner")

        with self.assertRaisesRegex(
            ValueError,
            "workflow manifest missing promotion approver role: module_contracts_owner",
        ):
            self.module.parse_workflow_manifest(workflow)

    def test_promotion_approvals_reject_roles_missing_from_workflow(self) -> None:
        errors = self.module.check_promotion_approvals(
            {
                "requiredApprovals": [
                    "module_contracts_owner",
                    "coordinator",
                ],
                "approvals": {
                    "module_contracts_owner": {
                        "approved": True,
                        "by": "module_contracts_owner",
                        "at": "2026-03-09T00:00:00Z",
                    },
                    "coordinator": {
                        "approved": True,
                        "by": "coordinator",
                        "at": "2026-03-09T00:00:00Z",
                    },
                },
            },
            {"requiredApprovals": ["coordinator"]},
        )

        self.assertIn(
            "promotion approvals role not workflow-required: module_contracts_owner",
            errors,
        )

    def test_projection_hash_sync_rejects_unsafe_manifest_paths(self) -> None:
        manifest = _projection_manifest()
        manifest["sourceWorkloadsPath"] = "../workloads.json"
        manifest["rulesPath"] = "/tmp/projection-rules.json"

        errors = self.module.check_projection_hash_sync(
            manifest,
            REPO_ROOT / "bench/workloads/specialized/workloads.amd.vulkan.superset.json",
        )

        self.assertIn(
            "manifest sourceWorkloadsPath must be repo-relative: ../workloads.json",
            errors,
        )
        self.assertIn(
            "manifest rulesPath must be repo-relative: /tmp/projection-rules.json",
            errors,
        )

    def test_parse_projection_manifest_accepts_strict_comparable_row(self) -> None:
        manifest = _parseable_projection_manifest(_projection_row())

        parsed = self.module.parse_projection_manifest(manifest)

        self.assertEqual(
            parsed["rows"][0]["browserWorkload"]["benchmarkClass"],
            "comparable",
        )

    def test_parse_projection_manifest_rejects_non_strict_comparable_class(self) -> None:
        manifest = _parseable_projection_manifest(
            _projection_row(
                comparability="component",
                benchmark_class="comparable",
            )
        )

        with self.assertRaisesRegex(
            ValueError,
            "non-strict browser projection must not use benchmarkClass=comparable",
        ):
            self.module.parse_projection_manifest(manifest)


if __name__ == "__main__":
    unittest.main()
