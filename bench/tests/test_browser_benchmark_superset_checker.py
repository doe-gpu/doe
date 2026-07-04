from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = REPO_ROOT / "browser/chromium/scripts/check-browser-benchmark-superset.py"
HASH_A = "a" * 64
HASH_B = "b" * 64


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
        },
        "runtimeProbe": {
            "webgpuAvailable": True,
            "adapterAvailable": True,
            "adapterInfo": {},
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
        "methodology": {
            "sourceKernelSamples": 1,
            "sourceKernelWarmupSamples": 0,
            "sourceKernelSubmitPolicy": "iteration-batch-v1",
            "adapterRequest": {
                "powerPreference": "high-performance",
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


if __name__ == "__main__":
    unittest.main()
