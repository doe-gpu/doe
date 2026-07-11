#!/usr/bin/env python3
"""Tests for the public claim index gate."""

from __future__ import annotations

import copy
import hashlib
import json
import tempfile
from pathlib import Path

import jsonschema

from bench.browser.browser_gate import stable_hash
from bench.gates import claim_index_browser_release as browser_release_gate
from bench.gates import claim_index_gate as gate


REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = REPO_ROOT / "config" / "claim-index.schema.json"
INDEX_PATH = REPO_ROOT / "reports" / "claim-index.json"
UNIT_RELEASE_ARCHIVE_BYTES = b"unit browser release archive\n"
UNIT_RELEASE_ARCHIVE_SHA256 = hashlib.sha256(UNIT_RELEASE_ARCHIVE_BYTES).hexdigest()
UNIT_DOWNLOAD_URL = "https://downloads.doe.dev/Fawn-Doe-unit-macos-arm64.zip"
UNIT_BROWSER_BINARY_SHA256 = "1" * 64
UNIT_APP_METADATA_SHA256 = "2" * 64
UNIT_DOE_RUNTIME_SHA256 = "3" * 64
UNIT_DAWN_FALLBACK_RUNTIME_SHA256 = "4" * 64
UNIT_SHADER_COMPILER_SHA256 = "5" * 64
UNIT_RELEASE_ARCHIVE_MANIFEST_PAYLOAD = {
    "schemaVersion": 1,
    "artifactKind": "browser_release_archive_manifest",
    "archive": {
        "path": "bench/out/unit/Fawn-Doe-unit-macos-arm64.zip",
        "sha256": UNIT_RELEASE_ARCHIVE_SHA256,
        "kind": "browser_release_archive",
    },
    "browserProduct": {
        "productId": "fawn-doe",
        "displayName": "Fawn Doe",
        "version": "0.0.0-unit",
        "channel": "release_candidate",
    },
    "platform": {
        "os": "macos",
        "arch": "arm64",
        "packageFormat": "zip",
    },
    "members": {
        "browserExecutable": {
            "archivePath": "Fawn.app/Contents/MacOS/Chromium",
            "sha256": UNIT_BROWSER_BINARY_SHA256,
            "executable": True,
        },
        "appMetadata": {
            "archivePath": "Fawn.app/Contents/Info.plist",
            "sha256": UNIT_APP_METADATA_SHA256,
            "executable": False,
        },
        "doeRuntime": {
            "archivePath": "Fawn.app/Contents/Frameworks/libwebgpu_doe.so",
            "sha256": UNIT_DOE_RUNTIME_SHA256,
            "executable": True,
        },
        "dawnFallbackRuntime": {
            "archivePath": "Fawn.app/Contents/Frameworks/libdawn_native.so",
            "sha256": UNIT_DAWN_FALLBACK_RUNTIME_SHA256,
            "executable": True,
        },
    },
}
UNIT_RELEASE_ARCHIVE_MANIFEST_SHA256 = hashlib.sha256(
    json.dumps(UNIT_RELEASE_ARCHIVE_MANIFEST_PAYLOAD).encode("utf-8")
).hexdigest()
UNIT_BROWSER_RELEASE_BUNDLE_COMPONENTS = {
    "runtimeFrontierBundlePath": (
        "runtimeFrontierBundle",
        "browser_runtime_frontier_bundle",
    ),
    "releaseArchiveManifestPath": (
        "releaseArchiveManifest",
        "browser_release_archive_manifest",
    ),
    "packageInputsPath": (
        "packageInputs",
        "browser_release_package_inputs_check",
    ),
    "publicDownloadReceiptPath": (
        "publicDownloadReceipt",
        "browser_public_download_receipt",
    ),
    "proofSurfacePath": (
        "proofSurface",
        "browser_published_proof_surface",
    ),
    "proofSurfaceCheckPath": (
        "proofSurfaceCheck",
        "browser_published_proof_surface_check",
    ),
    "browserLaunchReceiptPath": (
        "browserLaunchReceipt",
        "browser_release_launch_receipt",
    ),
}


def _schema() -> dict:
    return json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))


def _entry() -> dict:
    return {
        "id": "unit-claim",
        "surface": "native",
        "backend": "apple-metal",
        "comparison": "doe-vs-dawn",
        "metricDirection": "lower-is-better",
        "claimState": "claim-indexed",
        "comparisonStatus": "comparable",
        "claimStatus": "claimable",
        "reportPath": "bench/out/unit/compare.json",
        "claimPath": "bench/out/unit/claim.json",
    }


def _browser_release_paths(*, download_url: str = UNIT_DOWNLOAD_URL) -> dict[str, str]:
    return {
        "runtimeFrontierBundlePath": "bench/out/unit/browser-runtime-frontier-bundle.json",
        "releaseArtifactBundlePath": "bench/out/unit/browser-release-artifact-bundle.json",
        "releaseArchivePath": "bench/out/unit/Fawn-Doe-unit-macos-arm64.zip",
        "releaseArchiveSha256": UNIT_RELEASE_ARCHIVE_SHA256,
        "releaseArchiveManifestPath": "bench/out/unit/Fawn-Doe-unit-macos-arm64.manifest.json",
        "releaseArchiveManifestSha256": UNIT_RELEASE_ARCHIVE_MANIFEST_SHA256,
        "downloadUrl": download_url,
        "packageInputsPath": "bench/out/unit/browser-release-package-inputs.json",
        "provenanceReportPath": "bench/out/unit/browser-release-candidate-provenance.json",
        "publicDownloadReceiptPath": "bench/out/unit/browser-public-download-receipt.json",
        "proofSurfacePath": "bench/out/unit/browser-published-proof-surface.json",
        "proofSurfaceCheckPath": "bench/out/unit/browser-published-proof-surface-check.json",
        "browserLaunchReceiptPath": "bench/out/unit/browser-release-launch-receipt.json",
        "finalizerReportPath": "bench/out/unit/browser-release-candidate-finalizer.json",
        "finalizerCheckPath": "bench/out/unit/browser-release-candidate-finalizer-check.json",
        "readinessReportPath": "bench/out/unit/dawn-replacement-readiness-report.json",
    }


def _browser_chromium_entry(
    *,
    claim_state: str = "scaffolded",
    download_url: str = UNIT_DOWNLOAD_URL,
) -> dict:
    entry = {
        "id": "browser-chromium-unit",
        "surface": "browser-chromium",
        "runtimeHost": "browser",
        "backend": "apple-metal",
        "comparison": "doe-vs-dawn",
        "metricDirection": "status-only",
        "claimState": claim_state,
        "comparisonStatus": "not-evaluated",
        "claimStatus": "not-evaluated",
        "browserRelease": _browser_release_paths(download_url=download_url),
    }
    if claim_state == "claim-indexed":
        entry["comparisonStatus"] = "comparable"
        entry["claimStatus"] = "claimable"
        entry["reportPath"] = "bench/out/unit/compare.json"
        entry["claimPath"] = "bench/out/unit/claim.json"
    else:
        entry["blocker"] = "Browser release evidence is scaffolded for claim-index review."
    return entry


def _index(entry: dict) -> dict:
    return {
        "schemaVersion": 1,
        "kind": "doe-claim-index",
        "description": "unit",
        "entries": [entry],
    }


def _write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload), encoding="utf-8")


def _write_artifacts(root: Path, *, claim_status: str = "claimable") -> None:
    _write_json(
        root / "bench/out/unit/compare.json",
        {
            "artifactKind": "compare-report",
            "comparisonStatus": "comparable",
        },
    )
    _write_json(
        root / "bench/out/unit/claim.json",
        {
            "artifactKind": "claim-report",
            "comparisonStatus": "comparable",
            "claimStatus": claim_status,
            "pass": claim_status == "claimable",
            "compareReport": {
                "path": "bench/out/unit/compare.json",
                "sha256": "0" * 64,
            },
        },
    )


def _write_browser_release_artifacts(
    root: Path,
    *,
    claimable: bool = True,
    download_url: str = UNIT_DOWNLOAD_URL,
    artifact_kind_overrides: dict[str, str] | None = None,
) -> None:
    artifact_kind_overrides = artifact_kind_overrides or {}
    paths = _browser_release_paths(download_url=download_url)
    archive_path = root / paths["releaseArchivePath"]
    archive_path.parent.mkdir(parents=True, exist_ok=True)
    archive_path.write_bytes(UNIT_RELEASE_ARCHIVE_BYTES)
    release_archive = {
        "path": paths["releaseArchivePath"],
        "sha256": paths["releaseArchiveSha256"],
        "kind": "browser_release_archive",
        "downloadUrl": paths["downloadUrl"],
    }
    release_archive_manifest = {
        "path": paths["releaseArchiveManifestPath"],
        "sha256": paths["releaseArchiveManifestSha256"],
        "kind": "browser_release_archive_manifest",
    }
    browser_product = {
        "productId": "fawn-doe",
        "displayName": "Fawn Doe",
        "version": "0.0.0-unit",
        "channel": "release_candidate" if claimable else "diagnostic",
    }
    platform = {
        "os": "macos",
        "arch": "arm64",
        "packageFormat": "zip",
    }
    browser_executable_archive_path = "Fawn.app/Contents/MacOS/Chromium"
    browser_app_metadata_archive_path = "Fawn.app/Contents/Info.plist"
    doe_runtime_archive_path = "Fawn.app/Contents/Frameworks/libwebgpu_doe.so"
    dawn_fallback_runtime_archive_path = "Fawn.app/Contents/Frameworks/libdawn_native.so"
    browser_binary = {
        "path": "browser/chromium/src/out/fawn_release/chrome-wrapper",
        "sha256": UNIT_BROWSER_BINARY_SHA256,
        "kind": "browser_binary",
    }
    doe_runtime = {
        "path": "runtime/zig/zig-out/lib/libwebgpu_doe.so",
        "sha256": UNIT_DOE_RUNTIME_SHA256,
        "kind": "doe_runtime",
    }
    dawn_fallback_runtime = {
        "path": "browser/chromium/src/out/fawn_release/libdawn_native.so",
        "sha256": UNIT_DAWN_FALLBACK_RUNTIME_SHA256,
        "kind": "dawn_fallback_runtime",
    }
    shader_compiler = {
        "path": "runtime/zig/zig-out/bin/doe-zig-runtime",
        "sha256": UNIT_SHADER_COMPILER_SHA256,
        "kind": "shader_compiler",
    }
    release_provenance = {
        "browserProduct": browser_product,
        "platform": platform,
        "releaseArchive": release_archive,
        "releaseArchiveManifest": release_archive_manifest,
        "publicDownloadReceipt": {
            "path": paths["publicDownloadReceiptPath"],
            "kind": "browser_public_download_receipt",
            "downloadUrl": paths["downloadUrl"],
        },
        "browserExecutableArchivePath": browser_executable_archive_path,
        "browserAppMetadataArchivePath": browser_app_metadata_archive_path,
        "doeRuntimeArchivePath": doe_runtime_archive_path,
        "dawnFallbackRuntimeArchivePath": dawn_fallback_runtime_archive_path,
    }
    source_shader = "@compute @workgroup_size(1) fn main() {}"
    source_shader_sha256 = hashlib.sha256(source_shader.encode("utf-8")).hexdigest()

    def write_execution_receipt(
        *,
        receipt_id: str,
        rel_path: str,
        selected_runtime: str,
        backend: str,
        lowering_path: list[str],
        workload_id: str = "unit-compute",
    ) -> dict[str, str]:
        payload = {
            "schemaVersion": 1,
            "artifactKind": "browser_execution_receipt",
            "receiptId": receipt_id,
            "workloadId": workload_id,
            "selectedRuntime": selected_runtime,
            "sourceShader": {
                "language": "wgsl",
                "entryPoint": "main",
                "source": source_shader,
                "sha256": source_shader_sha256,
            },
            "loweringPath": lowering_path,
            "backend": backend,
            "driver": {
                "vendor": "unit",
                "api": "webgpu",
                "driver": "unit",
                "deviceFamily": "unit",
            },
            "device": {
                "adapterInfoSha256": "b" * 64,
                "featureCount": 0,
                "adapter": "unit-adapter",
                "device": "unit-device",
            },
            "commandGraph": {
                "graphSha256": "8" * 64,
                "artifactPath": "bench/out/unit/browser-smoke-report.json",
            },
            "flightRecorderRef": None,
            "commandCoverage": {
                "commandCount": 1,
                "successCount": 1,
                "dispatchCount": 1,
            },
            "runtimeSelectorState": {
                "selectionMode": selected_runtime,
                "selectedRuntime": selected_runtime,
                "forcedMode": selected_runtime,
                "fallbackApplied": False,
                "hiddenFallbackAllowed": False,
                "fallbackReasonCode": "",
                "selectorVersion": "unit-selector-v1",
            },
            "fallbackState": {
                "fallbackApplied": False,
                "hiddenFallbackAllowed": False,
                "reasonCode": "",
            },
            "outputHash": "9" * 64,
            "timing": {
                "timingClass": "browser-operation-proxy",
                "phases": {
                    "setupNs": 1,
                    "encodeNs": 2,
                    "submitWaitNs": 3,
                },
            },
        }
        path = root / rel_path
        _write_json(path, payload)
        return {
            "receiptId": receipt_id,
            "path": rel_path,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "kind": "browser_execution_receipt",
        }

    dawn_receipt = write_execution_receipt(
        receipt_id="unit-dawn-receipt",
        rel_path="bench/out/unit/browser-dawn-execution-receipt.json",
        selected_runtime="dawn",
        backend="webgpu-dawn",
        lowering_path=["wgsl", "tint", "dawn-native"],
    )
    doe_receipt = write_execution_receipt(
        receipt_id="unit-doe-receipt",
        rel_path="bench/out/unit/browser-doe-execution-receipt.json",
        selected_runtime="doe",
        backend="webgpu-doe",
        lowering_path=["wgsl", "doe-wgsl", "tsir", "hostplan", "webgpu"],
    )
    comparison_artifact_rel_path = "bench/out/unit/browser-smoke-report.json"
    comparison_artifact_path = root / comparison_artifact_rel_path
    smoke_passes = {
        "computeIncrement": {"pass": True},
        "renderTriangle": {"pass": True},
        "renderBundle": {"pass": True},
        "renderIndirect": {"pass": True},
        "timestampQuery": {"pass": True},
        "requestAdapterXrCompatible": {"pass": True},
        "copyExternalImageToTexture": {"pass": True},
        "importExternalTexture": {"pass": True},
    }

    def comparison_runtime_selection(mode: str) -> dict:
        return {
            "selectionMode": mode,
            "selectedRuntime": mode,
            "forcedMode": mode,
            "fallbackApplied": False,
            "fallbackReasonCode": "",
            "hiddenFallbackAllowed": False,
            "profile": {
                "vendor": "unit",
                "api": "webgpu",
                "deviceFamily": "unit",
                "driver": "unit",
            },
            "selectorVersion": "unit-selector-v1",
            "artifactIdentity": {
                "browserExecutablePath": "/unit/Fawn.app/Contents/MacOS/Chromium",
                "browserExecutableSha256": UNIT_BROWSER_BINARY_SHA256,
                "dawnRuntimePath": "/unit/Fawn.app/Contents/Frameworks/libdawn_native.so",
                "dawnRuntimeSha256": UNIT_DAWN_FALLBACK_RUNTIME_SHA256,
                "doeLibPath": "/unit/Fawn.app/Contents/Frameworks/libwebgpu_doe.so"
                if mode == "doe"
                else None,
                "doeLibSha256": UNIT_DOE_RUNTIME_SHA256 if mode == "doe" else None,
            },
            "launchArgsHash": "a" * 64,
        }

    def comparison_mode_result(mode: str, previous_hash: str | None) -> dict:
        entry = {
            "mode": mode,
            "runtimeSelection": comparison_runtime_selection(mode),
            "shaderCompilerIdentity": {
                "compilerSurface": "doe_runtime_embedded_shader_compiler"
                if mode == "doe"
                else "dawn_runtime_embedded_shader_compiler",
                "compilerArtifactPath": "/unit/Fawn.app/Contents/Frameworks/libwebgpu_doe.so"
                if mode == "doe"
                else "/unit/Fawn.app/Contents/Frameworks/libdawn_native.so",
                "compilerArtifactSha256": UNIT_DOE_RUNTIME_SHA256
                if mode == "doe"
                else UNIT_DAWN_FALLBACK_RUNTIME_SHA256,
                "identitySource": "runtime_artifact_identity",
            },
            "webgpuAvailable": True,
            "adapterAvailable": True,
            "adapterIdentity": {
                "adapterInfoSha256": "b" * 64,
                "featureCount": 0,
            },
            "errors": [],
            "smoke": smoke_passes,
        }
        return {
            **entry,
            "previousHash": previous_hash,
            "hash": stable_hash(
                {
                    "previousHash": previous_hash,
                    "entry": entry,
                }
            ),
        }

    dawn_mode_result = comparison_mode_result("dawn", None)
    doe_mode_result = comparison_mode_result("doe", dawn_mode_result["hash"])
    comparison_artifact_payload = {
        "schemaVersion": 1,
        "reportKind": "chromium-webgpu-playwright-smoke",
        "benchmarkClass": "diagnostic",
        "comparisonStatus": "diagnostic",
        "claimStatus": "diagnostic",
        "timingClass": "browser-operation-proxy",
        "timingSource": "performance.now",
        "generatedAt": "2026-06-30T00:00:00Z",
        "hashAlgorithm": "sha256",
        "workloadIdentity": {
            "kind": "browser_smoke_suite",
            "workloadHash": "c" * 64,
        },
        "mode": "both",
        "methodology": {
            "strictMode": True,
        },
        "runtimeSelections": [
            comparison_runtime_selection("dawn"),
            comparison_runtime_selection("doe"),
        ],
        "modeResults": [
            dawn_mode_result,
            doe_mode_result,
        ],
        "comparison": {
            "bothComputeSmokePass": True,
            "bothRenderSmokePass": True,
            "bothRenderBundleSmokePass": True,
            "bothRenderIndirectSmokePass": True,
            "bothTimestampQuerySmokePass": True,
        },
    }
    comparison_artifact_payload["reportHash"] = stable_hash(comparison_artifact_payload)
    _write_json(
        comparison_artifact_path,
        comparison_artifact_payload,
    )
    comparison_artifact = {
        "path": comparison_artifact_rel_path,
        "sha256": hashlib.sha256(comparison_artifact_path.read_bytes()).hexdigest(),
        "kind": "chromium-webgpu-playwright-smoke",
    }

    def bind_receipt_to_comparison_artifact(receipt_ref: dict) -> None:
        receipt_path = root / receipt_ref["path"]
        receipt_payload = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt_payload["commandGraph"]["artifactSha256"] = comparison_artifact["sha256"]
        _write_json(receipt_path, receipt_payload)
        receipt_ref["sha256"] = hashlib.sha256(receipt_path.read_bytes()).hexdigest()

    bind_receipt_to_comparison_artifact(dawn_receipt)
    bind_receipt_to_comparison_artifact(doe_receipt)
    gallery_receipts = {
        category: write_execution_receipt(
            receipt_id=f"unit-{category}-doe",
            rel_path=f"bench/out/unit/browser-{category}-execution-receipt.json",
            selected_runtime="doe",
            backend="webgpu-doe",
            lowering_path=["wgsl", "doe-wgsl", "webgpu"],
            workload_id=f"unit-{category}",
        )
        for category in (
            "compute",
            "rendering",
            "tensor",
            "shader_edge",
            "benchmark_trace",
        )
    }
    gallery_pages = []
    for category in (
        "compute",
        "rendering",
        "tensor",
        "shader_edge",
        "benchmark_trace",
    ):
        gallery_rel_path = f"bench/out/unit/browser-gallery-{category}.html"
        gallery_path = root / gallery_rel_path
        gallery_path.parent.mkdir(parents=True, exist_ok=True)
        gallery_path.write_text(
            f"<html><body>{category} Doe WebGPU receipt gallery browser/chromium/contracts/browser-benchmark-superset.contract.md unit-{category} unit-{category}-doe {gallery_receipts[category]['path']} {'unit-dawn-vs-doe unit-compute bench/out/unit/browser-smoke-report.json bench/out/unit/browser-gallery-compute.html same_page dawn doe side_by_side_receipts unit-dawn-receipt bench/out/unit/browser-dawn-execution-receipt.json unit-doe-receipt bench/out/unit/browser-doe-execution-receipt.json' if category == 'compute' else ''}</body></html>",
            encoding="utf-8",
        )
        gallery_artifact = {
            "path": gallery_rel_path,
            "sha256": hashlib.sha256(gallery_path.read_bytes()).hexdigest(),
            "kind": "browser_gallery_page",
        }
        workload_contract_path = "browser/chromium/contracts/browser-benchmark-superset.contract.md"
        public_receipt_rel_path = f"bench/out/unit/browser-public-gallery-{category}.json"
        public_receipt_path = root / public_receipt_rel_path
        public_receipt_payload = {
            "schemaVersion": 1,
            "artifactKind": "browser_public_gallery_receipt",
            "receiptId": f"unit-gallery-{category}",
            "category": category,
            "url": f"https://gallery.doe.dev/unit/{category}.html",
            "method": "GET",
            "statusCode": 200,
            "contentSha256": gallery_artifact["sha256"],
            "contentLengthBytes": gallery_path.stat().st_size,
            "galleryArtifactPath": gallery_artifact["path"],
            "workloadContractPath": workload_contract_path,
            "workloadIds": [f"unit-{category}"],
            "receiptIds": [f"unit-{category}-doe"],
            "receiptArtifactPaths": [gallery_receipts[category]["path"]],
            "observedAt": "2026-06-30T00:00:00Z",
        }
        _write_json(public_receipt_path, public_receipt_payload)
        gallery_pages.append(
            {
                "category": category,
                "url": f"https://gallery.doe.dev/unit/{category}.html",
                "artifact": gallery_artifact,
                "publicReceipt": {
                    "path": public_receipt_rel_path,
                    "sha256": hashlib.sha256(public_receipt_path.read_bytes()).hexdigest(),
                    "kind": "browser_public_gallery_receipt",
                },
                "workloadContractPath": workload_contract_path,
                "workloadIds": [f"unit-{category}"],
                "receiptIds": [f"unit-{category}-doe"],
                "receiptArtifacts": [gallery_receipts[category]],
            }
        )
    comparison_receipts = [
        {
            "comparisonId": "unit-dawn-vs-doe",
            "workloadId": "unit-compute",
            "runner": {
                "pageArtifactPath": "bench/out/unit/browser-gallery-compute.html",
                "executionScope": "same_page",
                "modes": ["dawn", "doe"],
                "emitsSideBySideReceipts": True,
            },
            "comparisonPolicy": {
                "workloadIdentity": "same_workload_id",
                "sourceShaderIdentity": "same_source_shader_identity",
                "adapterDeviceIdentity": "same_device_identity",
                "timingScope": "browser-operation-proxy",
                "commandCoverage": "exact_match",
                "outputIdentity": "same_output_hash",
                "fallbackPolicy": "no_hidden_fallback",
            },
            "comparisonArtifact": {
                **comparison_artifact,
            },
            "dawnReceipt": dawn_receipt,
            "doeReceipt": doe_receipt,
        }
    ]
    runtime_identity_path = "bench/out/unit/browser-runtime-identity.json"
    claim_promotion_receipt_path = "bench/out/unit/browser-claim-promotion-receipt.json"
    runtime_artifact_identity = {
        "browserExecutablePath": browser_binary["path"],
        "browserExecutableSha256": browser_binary["sha256"],
        "dawnRuntimePath": dawn_fallback_runtime["path"],
        "dawnRuntimeSha256": dawn_fallback_runtime["sha256"],
        "doeLibPath": doe_runtime["path"],
        "doeLibSha256": doe_runtime["sha256"],
    }
    _write_json(
        root / runtime_identity_path,
        {
            "artifactKind": "browser_runtime_identity",
            "evidenceSource": "runtime_selection_artifact",
            "executionOwner": "chromium_runtime_selector",
            "provider": {
                "name": "chromium_runtime_selector",
                "artifactIdentity": runtime_artifact_identity,
            },
            "selectedRuntime": "doe",
            "doeRuntimeActive": True,
            "runtimeSelection": {
                "selectedRuntime": "doe",
                "fallbackApplied": False,
                "hiddenFallbackAllowed": False,
                "artifactIdentity": runtime_artifact_identity,
            },
        },
    )
    _write_json(
        root / claim_promotion_receipt_path,
        {
            "artifactKind": "browser_claim_promotion_receipt",
            "promotionStatus": "promotable",
            "hiddenFallbackCheck": {
                "passed": True,
            },
            "artifacts": [
                {
                    "path": "bench/out/unit/browser-claim-report.json",
                    "forcedDoe": True,
                    "hiddenFallbackUsed": False,
                    "claimPolicyPassed": True,
                }
            ],
        },
    )
    proof_page_diagnostics = {
        "activeRuntime": "doe",
        "activeBackend": "webgpu-doe",
        "webgpuAvailable": True,
        "compilerPath": "runtime/zig/zig-out/bin/doe-zig-runtime",
        "tsirStatus": "available",
        "hostPlanStatus": "not_applicable",
        "cslStatus": "not_applicable",
        "fallbackPolicyState": "hidden_fallback_disabled",
    }
    proof_page_release_provenance = release_provenance
    proof_page_recent_receipt_ids = [receipt_id for row in gallery_pages for receipt_id in row["receiptIds"]] + ["unit-dawn-receipt", "unit-doe-receipt"]
    proof_page_rel_path = "bench/out/unit/browser-proof-page.html"
    proof_page_path = root / proof_page_rel_path
    proof_page_path.parent.mkdir(parents=True, exist_ok=True)
    proof_page_path.write_text(
        f"<html><body>about:doe webgpu-doe runtime/zig/zig-out/bin/doe-zig-runtime available not_applicable hidden_fallback_disabled Fawn Doe 0.0.0-unit release_candidate release-candidate macos arm64 zip Fawn.app/Contents/MacOS/Chromium Fawn.app/Contents/Info.plist Fawn.app/Contents/Frameworks/libwebgpu_doe.so Fawn.app/Contents/Frameworks/libdawn_native.so {paths['releaseArchivePath']} {paths['releaseArchiveSha256']} {paths['downloadUrl']} {paths['releaseArchiveManifestPath']} {paths['releaseArchiveManifestSha256']} {paths['publicDownloadReceiptPath']} {' '.join(proof_page_recent_receipt_ids)} {' '.join(artifact['path'] for row in gallery_pages for artifact in row['receiptArtifacts'])} bench/out/unit/browser-dawn-execution-receipt.json bench/out/unit/browser-doe-execution-receipt.json</body></html>",
        encoding="utf-8",
    )
    proof_page_artifact = {
        "path": proof_page_rel_path, "sha256": hashlib.sha256(proof_page_path.read_bytes()).hexdigest(), "kind": "browser_proof_page"
    }
    proof_page_receipt_rel_path = "bench/out/unit/browser-proof-page-receipt.json"
    proof_page_receipt_path = root / proof_page_receipt_rel_path
    _write_json(
        proof_page_receipt_path,
        {
            "schemaVersion": 1,
            "artifactKind": "browser_proof_page_receipt",
            "receiptId": "unit-proof-page",
            "url": "about:doe",
            "loadType": "browser_internal_page",
            "status": "loaded",
            "contentSha256": proof_page_artifact["sha256"],
            "contentLengthBytes": proof_page_path.stat().st_size,
            "proofArtifactPath": proof_page_artifact["path"],
            "runtimeIdentityPath": runtime_identity_path,
            "diagnostics": proof_page_diagnostics,
            "releaseProvenance": proof_page_release_provenance,
            "recentReceiptIds": proof_page_recent_receipt_ids,
            "observedAt": "2026-06-30T00:00:00Z",
        },
    )
    proof_page_receipt_artifact = {
        "path": proof_page_receipt_rel_path,
        "sha256": hashlib.sha256(proof_page_receipt_path.read_bytes()).hexdigest(),
        "kind": "browser_proof_page_receipt",
    }
    payloads = {
        "runtimeFrontierBundlePath": {
            "artifactKind": "browser_runtime_frontier_bundle",
            "status": "pass",
            "claimabilityStatus": "claimable" if claimable else "blocked",
            "componentReceipts": {
                "runtimeIdentity": {
                    "path": runtime_identity_path,
                    "status": "pass",
                    "evidenceSource": "runtime_selection_artifact",
                    "selectedRuntime": "doe",
                    "doeRuntimeActive": True,
                },
                "claimPromotionReceipt": {
                    "path": claim_promotion_receipt_path,
                    "status": "pass",
                    "promotionStatus": "promotable",
                    "artifactCount": 1,
                    "hiddenFallbackPassed": True,
                },
                "releaseArtifactBundle": {
                    "path": paths["releaseArtifactBundlePath"],
                    "status": "pass",
                    "bundleId": "browser-release-unit-v1",
                    "releaseStatus": "release_candidate" if claimable else "diagnostic",
                    "artifactVerification": {
                        "requiredForClaimable": True,
                        "verifyFilesRootProvided": claimable,
                        "verified": claimable,
                    },
                    "claimReports": [],
                }
            },
            "claimBlockers": [],
            "claimBlockerSummary": [],
            "failures": [],
            "summary": {
                "claimBlockerCount": 0,
                "failureCount": 0,
            },
        },
        "releaseArtifactBundlePath": {
            "artifactKind": "browser_release_artifact_bundle",
            "releaseStatus": "release_candidate" if claimable else "diagnostic",
            "artifactVerification": {
                "requiredForClaimable": True,
                "verifyFilesRootProvided": claimable,
                "verified": claimable,
            },
            "browserProduct": browser_product,
            "platform": platform,
            "browserExecutableArchivePath": browser_executable_archive_path,
            "browserAppMetadataArchivePath": browser_app_metadata_archive_path,
            "doeRuntimeArchivePath": doe_runtime_archive_path,
            "dawnFallbackRuntimeArchivePath": dawn_fallback_runtime_archive_path,
            "browserBinary": browser_binary,
            "doeRuntime": doe_runtime,
            "dawnFallbackRuntime": dawn_fallback_runtime,
            "shaderCompiler": shader_compiler,
            "releaseArchive": release_archive,
            "releaseArchiveManifest": release_archive_manifest,
            "promotionReceipts": [
                {
                    "path": claim_promotion_receipt_path,
                    "sha256": hashlib.sha256(
                        (root / claim_promotion_receipt_path).read_bytes()
                    ).hexdigest(),
                    "kind": "browser_claim_promotion_receipt",
                }
            ],
        },
        "releaseArchiveManifestPath": {
            **UNIT_RELEASE_ARCHIVE_MANIFEST_PAYLOAD,
        },
        "packageInputsPath": {
            "artifactKind": "browser_release_package_inputs_check",
            "status": "pass",
            "releaseCandidateEligible": claimable,
            "evidenceMode": "release_candidate" if claimable else "diagnostic",
            "browserProduct": browser_product,
            "platform": platform,
            "inputs": {
                "browserExecutable": {
                    "kind": browser_binary["kind"],
                    "path": browser_binary["path"],
                    "archivePath": browser_executable_archive_path,
                    "sha256": browser_binary["sha256"],
                },
                "appMetadata": {
                    "kind": "browser_app_metadata",
                    "path": "browser/chromium/src/out/fawn_release/Info.plist",
                    "archivePath": browser_app_metadata_archive_path,
                    "sha256": UNIT_APP_METADATA_SHA256,
                },
                "doeRuntime": {
                    "kind": doe_runtime["kind"],
                    "path": doe_runtime["path"],
                    "archivePath": doe_runtime_archive_path,
                    "sha256": doe_runtime["sha256"],
                },
                "dawnFallbackRuntime": {
                    "kind": dawn_fallback_runtime["kind"],
                    "path": dawn_fallback_runtime["path"],
                    "archivePath": dawn_fallback_runtime_archive_path,
                    "sha256": dawn_fallback_runtime["sha256"],
                },
                "shaderCompiler": {
                    "kind": shader_compiler["kind"],
                    "path": shader_compiler["path"],
                    "sha256": shader_compiler["sha256"],
                },
            },
            "releaseCandidateBlockers": [],
            "failures": [],
            "summary": {
                "packageable": claimable,
                "metadataSource": "package",
                "requiredArchiveMemberCount": 4,
                "runtimeReplacementCount": 2,
            },
        },
        "provenanceReportPath": {
            "artifactKind": "browser_release_candidate_provenance_report",
            "status": "pass" if claimable else "fail",
            "releaseStatus": "release_candidate",
            "browserProduct": browser_product,
            "platform": platform,
            "expectedProvenance": release_provenance,
            "componentArtifacts": {
                "releaseArchive": release_archive,
                "releaseArchiveManifest": release_archive_manifest,
            },
            "failures": [],
            "summary": {
                "failureCount": 0,
                "componentCount": 6,
            },
        },
        "publicDownloadReceiptPath": {
            "artifactKind": "browser_public_download_receipt",
            "receiptId": "unit-public-download",
            "method": "GET",
            "statusCode": 200,
            "url": paths["downloadUrl"],
            "contentSha256": paths["releaseArchiveSha256"],
            "contentLengthBytes": len(UNIT_RELEASE_ARCHIVE_BYTES),
            "releaseArchivePath": paths["releaseArchivePath"],
            "releaseArchiveManifestPath": paths["releaseArchiveManifestPath"],
            "releaseArchiveManifestSha256": paths["releaseArchiveManifestSha256"],
            "browserProduct": browser_product,
            "platform": platform,
            "browserExecutableArchivePath": browser_executable_archive_path,
            "browserAppMetadataArchivePath": browser_app_metadata_archive_path,
            "doeRuntimeArchivePath": doe_runtime_archive_path,
            "dawnFallbackRuntimeArchivePath": dawn_fallback_runtime_archive_path,
            "observedAt": "2026-06-30T00:00:00Z",
        },
        "proofSurfacePath": {
            "artifactKind": "browser_published_proof_surface",
            "surfaceId": "unit-browser-proof-surface",
            "capturePolicyPath": "config/browser-capture-policy.json",
            "runtimeIdentityPath": runtime_identity_path,
            "proofPage": {
                "artifact": proof_page_artifact,
                "url": "about:doe",
                "diagnosticReceipt": proof_page_receipt_artifact,
                "diagnostics": proof_page_diagnostics,
                "releaseProvenance": proof_page_release_provenance,
                "recentReceiptIds": proof_page_recent_receipt_ids,
                "receiptPayloads": [
                    comparison_receipts[0]["dawnReceipt"],
                    comparison_receipts[0]["doeReceipt"],
                ],
            },
            "galleryPages": gallery_pages,
            "comparisonReceipts": comparison_receipts,
        },
        "proofSurfaceCheckPath": {
            "schemaVersion": 1,
            "artifactKind": "browser_published_proof_surface_check",
            "surfacePath": paths["proofSurfacePath"],
            "surfaceSha256": "0" * 64,
            "status": "pass",
            "verifyFilesRootProvided": claimable,
            "requirePublicUrls": claimable,
            "failures": [],
        },
        "browserLaunchReceiptPath": {
            "artifactKind": "browser_release_launch_receipt",
            "launchSource": "release_archive",
            "runtimeMode": "doe",
            "activeRuntime": "doe",
            "activeBackend": "webgpu-doe",
            "hiddenFallbackAllowed": False,
            "hiddenFallbackUsed": False,
            "webgpuAvailable": True,
            "browserProduct": browser_product,
            "platform": platform,
            "browserExecutableArchivePath": browser_executable_archive_path,
            "browserAppMetadataArchivePath": browser_app_metadata_archive_path,
            "doeRuntimeArchivePath": doe_runtime_archive_path,
            "dawnFallbackRuntimeArchivePath": dawn_fallback_runtime_archive_path,
            "releaseArchive": release_archive,
            "releaseArchiveManifest": release_archive_manifest,
            "proofSurface": {
                "path": paths["proofSurfacePath"],
                "sha256": "0" * 64,
                "kind": "browser_published_proof_surface",
            },
            "proofPage": {
                "url": "about:doe",
                "loaded": True,
                "artifactPath": "bench/out/unit/browser-proof-page.html",
                "receiptId": "unit-proof-page",
            },
            "galleryPage": {
                "url": "https://gallery.doe.dev/unit/compute.html",
                "loaded": True,
                "category": "compute",
                "artifactPath": "bench/out/unit/browser-gallery-compute.html",
                "receiptId": "unit-gallery-compute",
            },
            "comparisonReceipt": {
                "comparisonId": "unit-dawn-vs-doe",
                "workloadId": "unit-compute",
                "pageArtifactPath": "bench/out/unit/browser-gallery-compute.html",
                "loaded": True,
                "executionScope": "same_page",
                "modes": ["dawn", "doe"],
                "emitsSideBySideReceipts": True,
                "comparisonArtifactPath": "bench/out/unit/browser-smoke-report.json",
                "dawnReceiptId": "unit-dawn-receipt",
                "doeReceiptId": "unit-doe-receipt",
            },
            "observedReceiptIds": [
                "unit-proof-page",
                "unit-gallery-compute",
                "unit-dawn-receipt",
                "unit-doe-receipt",
            ],
        },
        "finalizerReportPath": {
            "artifactKind": "browser_release_candidate_finalizer",
            "status": "pass" if claimable else "fail",
            "failures": [],
            "summary": {
                "claimabilityStatus": "claimable" if claimable else "blocked",
                "failureCount": 0,
            },
        },
        "finalizerCheckPath": {
            "artifactKind": "browser_release_candidate_finalizer_check",
            "status": "pass",
            "finalizerStatus": "pass" if claimable else "fail",
            "finalizerReportPath": paths["finalizerReportPath"],
            "finalizerReportSha256": "0" * 64,
            "verifyFilesRootProvided": claimable,
            "requirePass": claimable,
            "failures": [],
        },
    }
    release_bundle_payload = payloads.pop("releaseArtifactBundlePath")
    for field, payload in payloads.items():
        override = artifact_kind_overrides.get(field)
        if override is not None:
            payload["artifactKind"] = override
        _write_json(root / paths[field], payload)

    proof_surface_check_path = root / paths["proofSurfaceCheckPath"]
    proof_surface_check = json.loads(proof_surface_check_path.read_text(encoding="utf-8"))
    proof_surface_check["surfaceSha256"] = hashlib.sha256(
        (root / paths["proofSurfacePath"]).read_bytes()
    ).hexdigest()
    _write_json(proof_surface_check_path, proof_surface_check)

    browser_launch_path = root / paths["browserLaunchReceiptPath"]
    browser_launch = json.loads(browser_launch_path.read_text(encoding="utf-8"))
    browser_launch["proofSurface"]["sha256"] = hashlib.sha256(
        (root / paths["proofSurfacePath"]).read_bytes()
    ).hexdigest()
    _write_json(browser_launch_path, browser_launch)

    provenance_path = root / paths["provenanceReportPath"]
    provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
    provenance_components = provenance["componentArtifacts"]
    for field, (component_key, kind) in (
        ("packageInputsPath", ("packageInputs", "browser_release_package_inputs_check")),
        (
            "publicDownloadReceiptPath",
            ("publicDownloadReceipt", "browser_public_download_receipt"),
        ),
        ("proofSurfacePath", ("proofSurface", "browser_published_proof_surface")),
        (
            "proofSurfaceCheckPath",
            ("proofSurfaceCheck", "browser_published_proof_surface_check"),
        ),
        ("browserLaunchReceiptPath", ("browserLaunchReceipt", "browser_release_launch_receipt")),
    ):
        provenance_components[component_key] = {
            "path": paths[field],
            "sha256": hashlib.sha256((root / paths[field]).read_bytes()).hexdigest(),
            "kind": kind,
        }
    _write_json(provenance_path, provenance)

    for field, (component_key, kind) in UNIT_BROWSER_RELEASE_BUNDLE_COMPONENTS.items():
        release_bundle_payload[component_key] = {
            "path": paths[field],
            "sha256": hashlib.sha256((root / paths[field]).read_bytes()).hexdigest(),
            "kind": kind,
        }
    override = artifact_kind_overrides.get("releaseArtifactBundlePath")
    if override is not None:
        release_bundle_payload["artifactKind"] = override
    payloads["releaseArtifactBundlePath"] = release_bundle_payload
    _write_json(root / paths["releaseArtifactBundlePath"], release_bundle_payload)

    runtime_frontier_path = root / paths["runtimeFrontierBundlePath"]
    runtime_frontier = json.loads(runtime_frontier_path.read_text(encoding="utf-8"))
    release_summary = runtime_frontier["componentReceipts"]["releaseArtifactBundle"]
    release_summary["artifactKind"] = release_bundle_payload.get("artifactKind", "")
    release_summary["releaseBundleIdentitySha256"] = (
        browser_release_gate.release_bundle_identity_sha256(release_bundle_payload)
    )
    _write_json(runtime_frontier_path, runtime_frontier)
    release_bundle_payload["runtimeFrontierBundle"]["sha256"] = hashlib.sha256(
        runtime_frontier_path.read_bytes()
    ).hexdigest()
    _write_json(root / paths["releaseArtifactBundlePath"], release_bundle_payload)

    finalizer_report_path = root / paths["finalizerReportPath"]
    finalizer_report = json.loads(finalizer_report_path.read_text(encoding="utf-8"))
    finalizer_report["outputs"] = {
        "releaseArtifactBundle": {
            "path": paths["releaseArtifactBundlePath"],
            "sha256": hashlib.sha256(
                (root / paths["releaseArtifactBundlePath"]).read_bytes()
            ).hexdigest(),
            "kind": "browser_release_artifact_bundle",
        },
        "runtimeFrontierBundle": {
            "path": paths["runtimeFrontierBundlePath"],
            "sha256": hashlib.sha256(
                (root / paths["runtimeFrontierBundlePath"]).read_bytes()
            ).hexdigest(),
            "kind": "browser_runtime_frontier_bundle",
        },
    }
    finalizer_report["inputs"] = {
        "packageInputs": {
            "path": paths["packageInputsPath"],
            "sha256": hashlib.sha256((root / paths["packageInputsPath"]).read_bytes()).hexdigest(),
            "kind": "browser_release_package_inputs_check",
        },
        "provenanceReport": {
            "path": paths["provenanceReportPath"],
            "sha256": hashlib.sha256((root / paths["provenanceReportPath"]).read_bytes()).hexdigest(),
            "kind": "browser_release_candidate_provenance_report",
        }
    }
    finalizer_report["summary"]["releaseBundleIdentitySha256"] = (
        browser_release_gate.release_bundle_identity_sha256(release_bundle_payload)
    )
    _write_json(finalizer_report_path, finalizer_report)

    finalizer_check_path = root / paths["finalizerCheckPath"]
    finalizer_check = json.loads(finalizer_check_path.read_text(encoding="utf-8"))
    finalizer_check["finalizerReportSha256"] = hashlib.sha256(
        finalizer_report_path.read_bytes()
    ).hexdigest()
    if finalizer_check.get("finalizerStatus") == "pass":
        finalizer_check["outputs"] = finalizer_report["outputs"]
        finalizer_check["inputs"] = finalizer_report["inputs"]
    _write_json(finalizer_check_path, finalizer_check)

    artifact_hashes = {
        field: hashlib.sha256((root / paths[field]).read_bytes()).hexdigest()
        for field in payloads
    }
    readiness_payload = {
        "artifactKind": "dawn-replacement-readiness-report",
        "rows": [
            {
                "id": "browser-chromium-runtime",
                "claimAllowed": claimable,
                "readinessStatus": "claimable" if claimable else "blocked",
                "claimIndexEntries": [
                    {
                        "id": "browser-chromium-unit",
                        "browserRelease": paths,
                    }
                ],
                "frontierBundleEvidence": {
                    "path": paths["runtimeFrontierBundlePath"],
                    "sha256": artifact_hashes["runtimeFrontierBundlePath"],
                    "componentReceipts": {
                        "releaseArtifactBundle": {
                            "path": paths["releaseArtifactBundlePath"],
                            "sha256": artifact_hashes["releaseArtifactBundlePath"],
                        }
                    },
                    "releaseCandidateEvidence": {
                        "packageInputs": {
                            "path": paths["packageInputsPath"],
                            "sha256": artifact_hashes["packageInputsPath"],
                        },
                        "provenanceReport": {
                            "path": paths["provenanceReportPath"],
                            "sha256": artifact_hashes["provenanceReportPath"],
                        },
                        "publicDownloadReceipt": {
                            "path": paths["publicDownloadReceiptPath"],
                            "sha256": artifact_hashes["publicDownloadReceiptPath"],
                            "url": paths["downloadUrl"],
                            "contentSha256": paths["releaseArchiveSha256"],
                            "releaseArchivePath": paths["releaseArchivePath"],
                            "releaseArchiveManifestPath": paths["releaseArchiveManifestPath"],
                            "releaseArchiveManifestSha256": paths[
                                "releaseArchiveManifestSha256"
                            ],
                        },
                        "publishedProofSurface": {
                            "path": paths["proofSurfacePath"],
                            "sha256": artifact_hashes["proofSurfacePath"],
                        },
                        "proofSurfaceCheck": {
                            "path": paths["proofSurfaceCheckPath"],
                            "sha256": artifact_hashes["proofSurfaceCheckPath"],
                        },
                        "browserLaunchReceipt": {
                            "path": paths["browserLaunchReceiptPath"],
                            "sha256": artifact_hashes["browserLaunchReceiptPath"],
                        },
                        "finalizerReport": {
                            "path": paths["finalizerReportPath"],
                            "sha256": artifact_hashes["finalizerReportPath"],
                        },
                        "finalizerCheck": {
                            "path": paths["finalizerCheckPath"],
                            "sha256": artifact_hashes["finalizerCheckPath"],
                        },
                    },
                },
            }
        ],
    }
    override = artifact_kind_overrides.get("readinessReportPath")
    if override is not None:
        readiness_payload["artifactKind"] = override
    _write_json(root / paths["readinessReportPath"], readiness_payload)


def _refresh_runtime_frontier_dependent_hashes(root: Path, paths: dict[str, str]) -> None:
    runtime_path = root / paths["runtimeFrontierBundlePath"]
    runtime_sha = hashlib.sha256(runtime_path.read_bytes()).hexdigest()

    bundle_path = root / paths["releaseArtifactBundlePath"]
    bundle = json.loads(bundle_path.read_text(encoding="utf-8"))
    bundle["runtimeFrontierBundle"]["sha256"] = runtime_sha
    _write_json(bundle_path, bundle)
    bundle_sha = hashlib.sha256(bundle_path.read_bytes()).hexdigest()

    finalizer_path = root / paths["finalizerReportPath"]
    finalizer = json.loads(finalizer_path.read_text(encoding="utf-8"))
    finalizer["outputs"]["releaseArtifactBundle"]["sha256"] = bundle_sha
    finalizer["outputs"]["runtimeFrontierBundle"]["sha256"] = runtime_sha
    _write_json(finalizer_path, finalizer)
    finalizer_sha = hashlib.sha256(finalizer_path.read_bytes()).hexdigest()

    finalizer_check_path = root / paths["finalizerCheckPath"]
    finalizer_check = json.loads(finalizer_check_path.read_text(encoding="utf-8"))
    finalizer_check["finalizerReportSha256"] = finalizer_sha
    _write_json(finalizer_check_path, finalizer_check)
    finalizer_check_sha = hashlib.sha256(finalizer_check_path.read_bytes()).hexdigest()

    readiness_path = root / paths["readinessReportPath"]
    readiness = json.loads(readiness_path.read_text(encoding="utf-8"))
    evidence = readiness["rows"][0]["frontierBundleEvidence"]
    release_candidate = evidence["releaseCandidateEvidence"]
    evidence["sha256"] = runtime_sha
    evidence["componentReceipts"]["releaseArtifactBundle"]["sha256"] = bundle_sha
    release_candidate["finalizerReport"]["sha256"] = finalizer_sha
    release_candidate["finalizerCheck"]["sha256"] = finalizer_check_sha
    _write_json(readiness_path, readiness)


def _refresh_finalizer_dependent_hashes(root: Path, paths: dict[str, str]) -> None:
    finalizer_path = root / paths["finalizerReportPath"]
    finalizer_sha = hashlib.sha256(finalizer_path.read_bytes()).hexdigest()

    finalizer_check_path = root / paths["finalizerCheckPath"]
    finalizer_check = json.loads(finalizer_check_path.read_text(encoding="utf-8"))
    finalizer_check["finalizerReportSha256"] = finalizer_sha
    _write_json(finalizer_check_path, finalizer_check)
    finalizer_check_sha = hashlib.sha256(finalizer_check_path.read_bytes()).hexdigest()

    readiness_path = root / paths["readinessReportPath"]
    readiness = json.loads(readiness_path.read_text(encoding="utf-8"))
    release_candidate = readiness["rows"][0]["frontierBundleEvidence"][
        "releaseCandidateEvidence"
    ]
    release_candidate["finalizerReport"]["sha256"] = finalizer_sha
    release_candidate["finalizerCheck"]["sha256"] = finalizer_check_sha
    _write_json(readiness_path, readiness)


def _refresh_release_archive_manifest_dependent_hashes(
    root: Path,
    paths: dict[str, str],
    manifest_sha: str,
) -> None:
    public_download_path = root / paths["publicDownloadReceiptPath"]
    public_download = json.loads(public_download_path.read_text(encoding="utf-8"))
    public_download["releaseArchiveManifestSha256"] = manifest_sha
    _write_json(public_download_path, public_download)
    public_download_sha = hashlib.sha256(public_download_path.read_bytes()).hexdigest()

    provenance_path = root / paths["provenanceReportPath"]
    provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
    provenance["expectedProvenance"]["releaseArchiveManifest"]["sha256"] = manifest_sha
    provenance["componentArtifacts"]["releaseArchiveManifest"]["sha256"] = manifest_sha
    provenance["componentArtifacts"]["publicDownloadReceipt"]["sha256"] = public_download_sha
    _write_json(provenance_path, provenance)
    provenance_sha = hashlib.sha256(provenance_path.read_bytes()).hexdigest()

    proof_surface_path = root / paths["proofSurfacePath"]
    proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
    proof_surface["proofPage"]["releaseProvenance"]["releaseArchiveManifest"][
        "sha256"
    ] = manifest_sha
    _write_json(proof_surface_path, proof_surface)
    proof_surface_sha = hashlib.sha256(proof_surface_path.read_bytes()).hexdigest()

    proof_surface_check_path = root / paths["proofSurfaceCheckPath"]
    proof_surface_check = json.loads(proof_surface_check_path.read_text(encoding="utf-8"))
    proof_surface_check["surfaceSha256"] = proof_surface_sha
    _write_json(proof_surface_check_path, proof_surface_check)
    proof_surface_check_sha = hashlib.sha256(
        proof_surface_check_path.read_bytes()
    ).hexdigest()

    launch_path = root / paths["browserLaunchReceiptPath"]
    launch = json.loads(launch_path.read_text(encoding="utf-8"))
    launch["releaseArchiveManifest"]["sha256"] = manifest_sha
    launch["proofSurface"]["sha256"] = proof_surface_sha
    _write_json(launch_path, launch)
    launch_sha = hashlib.sha256(launch_path.read_bytes()).hexdigest()

    bundle_path = root / paths["releaseArtifactBundlePath"]
    bundle = json.loads(bundle_path.read_text(encoding="utf-8"))
    bundle["releaseArchiveManifest"]["sha256"] = manifest_sha
    bundle["publicDownloadReceipt"]["sha256"] = public_download_sha
    bundle["proofSurface"]["sha256"] = proof_surface_sha
    bundle["proofSurfaceCheck"]["sha256"] = proof_surface_check_sha
    bundle["browserLaunchReceipt"]["sha256"] = launch_sha
    _write_json(bundle_path, bundle)
    bundle_sha = hashlib.sha256(bundle_path.read_bytes()).hexdigest()

    finalizer_path = root / paths["finalizerReportPath"]
    finalizer = json.loads(finalizer_path.read_text(encoding="utf-8"))
    finalizer["outputs"]["releaseArtifactBundle"]["sha256"] = bundle_sha
    _write_json(finalizer_path, finalizer)
    finalizer_sha = hashlib.sha256(finalizer_path.read_bytes()).hexdigest()

    finalizer_check_path = root / paths["finalizerCheckPath"]
    finalizer_check = json.loads(finalizer_check_path.read_text(encoding="utf-8"))
    finalizer_check["finalizerReportSha256"] = finalizer_sha
    _write_json(finalizer_check_path, finalizer_check)
    finalizer_check_sha = hashlib.sha256(finalizer_check_path.read_bytes()).hexdigest()

    readiness_path = root / paths["readinessReportPath"]
    readiness = json.loads(readiness_path.read_text(encoding="utf-8"))
    browser_row = readiness["rows"][0]
    browser_row["claimIndexEntries"][0]["browserRelease"][
        "releaseArchiveManifestSha256"
    ] = manifest_sha
    evidence = browser_row["frontierBundleEvidence"]
    release_candidate = evidence["releaseCandidateEvidence"]
    evidence["componentReceipts"]["releaseArtifactBundle"]["sha256"] = bundle_sha
    release_candidate["publicDownloadReceipt"]["sha256"] = public_download_sha
    release_candidate["publicDownloadReceipt"]["releaseArchiveManifestSha256"] = manifest_sha
    release_candidate["provenanceReport"]["sha256"] = provenance_sha
    release_candidate["publishedProofSurface"]["sha256"] = proof_surface_sha
    release_candidate["proofSurfaceCheck"]["sha256"] = proof_surface_check_sha
    release_candidate["browserLaunchReceipt"]["sha256"] = launch_sha
    release_candidate["finalizerReport"]["sha256"] = finalizer_sha
    release_candidate["finalizerCheck"]["sha256"] = finalizer_check_sha
    _write_json(readiness_path, readiness)


def test_tracked_claim_index_is_schema_valid_and_gate_clean() -> None:
    schema = _schema()
    payload = json.loads(INDEX_PATH.read_text(encoding="utf-8"))

    jsonschema.Draft202012Validator(schema).validate(payload)
    result = gate.evaluate_index(payload, schema, REPO_ROOT)

    assert result["ok"], result["failures"]


def test_claim_indexed_entry_requires_claim_path_and_claimable_status() -> None:
    schema = _schema()
    entry = _entry()
    entry.pop("claimPath")
    entry["claimStatus"] = "diagnostic"

    result = gate.evaluate_index(_index(entry), schema, REPO_ROOT)
    codes = {item["code"] for item in result["failures"]}

    assert "schema_validation" in codes
    assert "claim_indexed_missing_claim_path" in codes
    assert "claim_indexed_not_claimable" in codes


def test_browser_style_diagnostic_entry_cannot_be_marked_claimable() -> None:
    schema = _schema()
    entry = _entry()
    entry["id"] = "browser-unit"
    entry["surface"] = "browser-ort"
    entry["runtimeHost"] = "browser"
    entry["claimState"] = "diagnostic"
    entry["claimStatus"] = "claimable"
    entry.pop("claimPath")

    result = gate.evaluate_index(_index(entry), schema, REPO_ROOT)
    codes = {item["code"] for item in result["failures"]}

    assert "schema_validation" in codes
    assert "claimable_without_claim_indexed_state" in codes


def test_browser_chromium_scaffolded_release_evidence_is_typed() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_browser_release_artifacts(root, claimable=False)

        result = gate.evaluate_index(_index(_browser_chromium_entry()), schema, root)

    assert result["ok"], result["failures"]


def test_browser_chromium_release_rejects_wrong_artifact_kind() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_browser_release_artifacts(
            root,
            artifact_kind_overrides={
                "proofSurfacePath": "browser_public_download_receipt",
            },
        )

        result = gate.evaluate_index(_index(_browser_chromium_entry()), schema, root)

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_artifact_kind_mismatch" in codes


def test_browser_chromium_release_rejects_readiness_path_drift() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_browser_release_artifacts(root)
        readiness_path = root / _browser_release_paths()["readinessReportPath"]
        readiness = json.loads(readiness_path.read_text(encoding="utf-8"))
        browser_row = readiness["rows"][0]
        release_candidate = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]
        release_candidate["provenanceReport"]["path"] = "bench/out/unit/other-provenance.json"
        _write_json(readiness_path, readiness)

        result = gate.evaluate_index(_index(_browser_chromium_entry()), schema, root)

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_readiness_path_mismatch" in codes


def test_browser_chromium_release_rejects_readiness_hash_drift() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_browser_release_artifacts(root)
        readiness_path = root / _browser_release_paths()["readinessReportPath"]
        readiness = json.loads(readiness_path.read_text(encoding="utf-8"))
        browser_row = readiness["rows"][0]
        release_candidate = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]
        browser_row["frontierBundleEvidence"]["sha256"] = "0" * 64
        release_bundle = browser_row["frontierBundleEvidence"]["componentReceipts"][
            "releaseArtifactBundle"
        ]
        release_bundle["sha256"] = "1" * 64
        release_candidate["provenanceReport"]["sha256"] = "0" * 64
        _write_json(readiness_path, readiness)

        result = gate.evaluate_index(_index(_browser_chromium_entry()), schema, root)

    codes = {item["code"] for item in result["failures"]}
    paths = {item["path"] for item in result["failures"]}

    assert "browser_release_readiness_hash_mismatch" in codes
    assert "entries[0].browserRelease.runtimeFrontierBundlePath" in paths
    assert "entries[0].browserRelease.releaseArtifactBundlePath" in paths


def test_browser_chromium_release_rejects_release_bundle_component_hash_drift() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_browser_release_artifacts(root)
        bundle_path = root / _browser_release_paths()["releaseArtifactBundlePath"]
        bundle = json.loads(bundle_path.read_text(encoding="utf-8"))
        bundle["proofSurface"]["sha256"] = "0" * 64
        _write_json(bundle_path, bundle)

        result = gate.evaluate_index(_index(_browser_chromium_entry()), schema, root)

    codes = {item["code"] for item in result["failures"]}
    paths = {item["path"] for item in result["failures"]}

    assert "browser_release_bundle_component_mismatch" in codes
    assert "entries[0].browserRelease.proofSurfacePath" in paths


def test_browser_chromium_release_rejects_archive_hash_drift() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_browser_release_artifacts(root)
        entry = _browser_chromium_entry()
        entry["browserRelease"]["releaseArchiveSha256"] = "0" * 64

        result = gate.evaluate_index(_index(entry), schema, root)

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_archive_hash_mismatch" in codes
    assert "browser_release_archive_sha_mismatch" in codes


def test_browser_chromium_release_rejects_absolute_archive_without_statting_it() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir, tempfile.TemporaryDirectory() as outside_dir:
        root = Path(tmpdir)
        _write_browser_release_artifacts(root)
        outside_archive = Path(outside_dir) / "outside-browser.zip"
        outside_archive.write_bytes(b"outside archive must not become claim evidence\n")
        entry = _browser_chromium_entry()
        entry["browserRelease"]["releaseArchivePath"] = outside_archive.as_posix()
        entry["browserRelease"]["releaseArchiveSha256"] = hashlib.sha256(
            outside_archive.read_bytes()
        ).hexdigest()

        result = gate.evaluate_index(_index(entry), schema, root)

    codes = {item["code"] for item in result["failures"]}
    failures = {
        (item["code"], item["path"], item["message"])
        for item in result["failures"]
    }

    assert (
        "unsafe_browser_release_path",
        "entries[0].browserRelease.releaseArchivePath",
        "path must be repository-relative",
    ) in failures
    assert "browser_release_public_download_length_mismatch" not in codes


def test_browser_chromium_release_rejects_public_download_url_drift() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_browser_release_artifacts(root)
        public_download_path = root / _browser_release_paths()["publicDownloadReceiptPath"]
        public_download = json.loads(public_download_path.read_text(encoding="utf-8"))
        public_download["url"] = "https://downloads.doe.dev/other.zip"
        _write_json(public_download_path, public_download)

        result = gate.evaluate_index(_index(_browser_chromium_entry()), schema, root)

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_download_url_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_public_download_url() -> None:
    schema = _schema()
    reserved_url = "https://download.doe.test/Fawn-Doe-unit-macos-arm64.zip"
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root, download_url=reserved_url)

        result = gate.evaluate_index(
            _index(
                _browser_chromium_entry(
                    claim_state="claim-indexed",
                    download_url=reserved_url,
                )
            ),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_download_url_not_public" in codes
    assert "browser_release_download_url_mismatch" not in codes


def test_browser_chromium_claim_indexed_release_requires_public_download_get_receipt() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        paths = _browser_release_paths()

        public_download_path = root / paths["publicDownloadReceiptPath"]
        public_download = json.loads(public_download_path.read_text(encoding="utf-8"))
        public_download["method"] = "HEAD"
        _write_json(public_download_path, public_download)
        public_download_sha = hashlib.sha256(public_download_path.read_bytes()).hexdigest()

        bundle_path = root / paths["releaseArtifactBundlePath"]
        bundle = json.loads(bundle_path.read_text(encoding="utf-8"))
        bundle["publicDownloadReceipt"]["sha256"] = public_download_sha
        _write_json(bundle_path, bundle)
        bundle_sha = hashlib.sha256(bundle_path.read_bytes()).hexdigest()

        readiness_path = root / paths["readinessReportPath"]
        readiness = json.loads(readiness_path.read_text(encoding="utf-8"))
        evidence = readiness["rows"][0]["frontierBundleEvidence"]
        evidence["componentReceipts"]["releaseArtifactBundle"]["sha256"] = bundle_sha
        evidence["releaseCandidateEvidence"]["publicDownloadReceipt"][
            "sha256"
        ] = public_download_sha
        _write_json(readiness_path, readiness)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_public_download_not_get" in codes


def test_browser_chromium_claim_indexed_release_requires_public_download_length() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        paths = _browser_release_paths()

        public_download_path = root / paths["publicDownloadReceiptPath"]
        public_download = json.loads(public_download_path.read_text(encoding="utf-8"))
        public_download["contentLengthBytes"] = len(UNIT_RELEASE_ARCHIVE_BYTES) + 1
        _write_json(public_download_path, public_download)
        public_download_sha = hashlib.sha256(public_download_path.read_bytes()).hexdigest()

        bundle_path = root / paths["releaseArtifactBundlePath"]
        bundle = json.loads(bundle_path.read_text(encoding="utf-8"))
        bundle["publicDownloadReceipt"]["sha256"] = public_download_sha
        _write_json(bundle_path, bundle)
        bundle_sha = hashlib.sha256(bundle_path.read_bytes()).hexdigest()

        readiness_path = root / paths["readinessReportPath"]
        readiness = json.loads(readiness_path.read_text(encoding="utf-8"))
        evidence = readiness["rows"][0]["frontierBundleEvidence"]
        evidence["componentReceipts"]["releaseArtifactBundle"]["sha256"] = bundle_sha
        evidence["releaseCandidateEvidence"]["publicDownloadReceipt"][
            "sha256"
        ] = public_download_sha
        _write_json(readiness_path, readiness)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_public_download_length_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_clean_package_inputs() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        paths = _browser_release_paths()

        package_path = root / paths["packageInputsPath"]
        package_inputs = json.loads(package_path.read_text(encoding="utf-8"))
        package_inputs["failures"] = [
            {
                "code": "unit_package_input_failure",
                "path": "packageInputs",
                "message": "unit package input failure",
            }
        ]
        package_inputs["summary"]["packageable"] = False
        _write_json(package_path, package_inputs)
        package_sha = hashlib.sha256(package_path.read_bytes()).hexdigest()

        bundle_path = root / paths["releaseArtifactBundlePath"]
        bundle = json.loads(bundle_path.read_text(encoding="utf-8"))
        bundle["packageInputs"]["sha256"] = package_sha
        _write_json(bundle_path, bundle)
        bundle_sha = hashlib.sha256(bundle_path.read_bytes()).hexdigest()

        finalizer_path = root / paths["finalizerReportPath"]
        finalizer = json.loads(finalizer_path.read_text(encoding="utf-8"))
        finalizer["inputs"]["packageInputs"]["sha256"] = package_sha
        _write_json(finalizer_path, finalizer)
        finalizer_sha = hashlib.sha256(finalizer_path.read_bytes()).hexdigest()

        finalizer_check_path = root / paths["finalizerCheckPath"]
        finalizer_check = json.loads(finalizer_check_path.read_text(encoding="utf-8"))
        finalizer_check["finalizerReportSha256"] = finalizer_sha
        _write_json(finalizer_check_path, finalizer_check)
        finalizer_check_sha = hashlib.sha256(finalizer_check_path.read_bytes()).hexdigest()

        readiness_path = root / paths["readinessReportPath"]
        readiness = json.loads(readiness_path.read_text(encoding="utf-8"))
        evidence = readiness["rows"][0]["frontierBundleEvidence"]
        release_candidate = evidence["releaseCandidateEvidence"]
        evidence["componentReceipts"]["releaseArtifactBundle"]["sha256"] = bundle_sha
        release_candidate["packageInputs"]["sha256"] = package_sha
        release_candidate["finalizerReport"]["sha256"] = finalizer_sha
        release_candidate["finalizerCheck"]["sha256"] = finalizer_check_sha
        _write_json(readiness_path, readiness)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_package_inputs_not_clean" in codes


def test_browser_chromium_claim_indexed_release_requires_clean_provenance() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        paths = _browser_release_paths()

        provenance_path = root / paths["provenanceReportPath"]
        provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
        provenance["failures"] = [
            {
                "code": "unit_provenance_failure",
                "path": "provenance",
                "message": "unit provenance failure",
            }
        ]
        provenance["summary"]["failureCount"] = 1
        _write_json(provenance_path, provenance)
        provenance_sha = hashlib.sha256(provenance_path.read_bytes()).hexdigest()

        readiness_path = root / paths["readinessReportPath"]
        readiness = json.loads(readiness_path.read_text(encoding="utf-8"))
        readiness["rows"][0]["frontierBundleEvidence"]["releaseCandidateEvidence"][
            "provenanceReport"
        ]["sha256"] = provenance_sha
        _write_json(readiness_path, readiness)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_provenance_not_clean" in codes


def test_browser_chromium_claim_indexed_release_requires_provenance_component_identity() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        paths = _browser_release_paths()

        provenance_path = root / paths["provenanceReportPath"]
        provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
        provenance["componentArtifacts"]["proofSurface"]["sha256"] = "0" * 64
        _write_json(provenance_path, provenance)
        provenance_sha = hashlib.sha256(provenance_path.read_bytes()).hexdigest()

        readiness_path = root / paths["readinessReportPath"]
        readiness = json.loads(readiness_path.read_text(encoding="utf-8"))
        readiness["rows"][0]["frontierBundleEvidence"]["releaseCandidateEvidence"][
            "provenanceReport"
        ]["sha256"] = provenance_sha
        _write_json(readiness_path, readiness)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_provenance_component_identity_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_package_input_release_identity() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        paths = _browser_release_paths()

        package_path = root / paths["packageInputsPath"]
        package_inputs = json.loads(package_path.read_text(encoding="utf-8"))
        package_inputs["browserProduct"]["version"] = "0.0.0-other"
        _write_json(package_path, package_inputs)
        package_sha = hashlib.sha256(package_path.read_bytes()).hexdigest()

        bundle_path = root / paths["releaseArtifactBundlePath"]
        bundle = json.loads(bundle_path.read_text(encoding="utf-8"))
        bundle["packageInputs"]["sha256"] = package_sha
        _write_json(bundle_path, bundle)
        bundle_sha = hashlib.sha256(bundle_path.read_bytes()).hexdigest()

        finalizer_path = root / paths["finalizerReportPath"]
        finalizer = json.loads(finalizer_path.read_text(encoding="utf-8"))
        finalizer["inputs"]["packageInputs"]["sha256"] = package_sha
        finalizer["outputs"]["releaseArtifactBundle"]["sha256"] = bundle_sha
        _write_json(finalizer_path, finalizer)
        finalizer_sha = hashlib.sha256(finalizer_path.read_bytes()).hexdigest()

        finalizer_check_path = root / paths["finalizerCheckPath"]
        finalizer_check = json.loads(finalizer_check_path.read_text(encoding="utf-8"))
        finalizer_check["finalizerReportSha256"] = finalizer_sha
        _write_json(finalizer_check_path, finalizer_check)
        finalizer_check_sha = hashlib.sha256(finalizer_check_path.read_bytes()).hexdigest()

        readiness_path = root / paths["readinessReportPath"]
        readiness = json.loads(readiness_path.read_text(encoding="utf-8"))
        evidence = readiness["rows"][0]["frontierBundleEvidence"]
        release_candidate = evidence["releaseCandidateEvidence"]
        evidence["componentReceipts"]["releaseArtifactBundle"]["sha256"] = bundle_sha
        release_candidate["packageInputs"]["sha256"] = package_sha
        release_candidate["finalizerReport"]["sha256"] = finalizer_sha
        release_candidate["finalizerCheck"]["sha256"] = finalizer_check_sha
        _write_json(readiness_path, readiness)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_package_inputs_identity_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_public_download_release_identity() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        paths = _browser_release_paths()

        public_download_path = root / paths["publicDownloadReceiptPath"]
        public_download = json.loads(public_download_path.read_text(encoding="utf-8"))
        public_download["platform"]["arch"] = "x64"
        _write_json(public_download_path, public_download)
        public_download_sha = hashlib.sha256(public_download_path.read_bytes()).hexdigest()

        provenance_path = root / paths["provenanceReportPath"]
        provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
        provenance["componentArtifacts"]["publicDownloadReceipt"][
            "sha256"
        ] = public_download_sha
        _write_json(provenance_path, provenance)
        provenance_sha = hashlib.sha256(provenance_path.read_bytes()).hexdigest()

        bundle_path = root / paths["releaseArtifactBundlePath"]
        bundle = json.loads(bundle_path.read_text(encoding="utf-8"))
        bundle["publicDownloadReceipt"]["sha256"] = public_download_sha
        _write_json(bundle_path, bundle)
        bundle_sha = hashlib.sha256(bundle_path.read_bytes()).hexdigest()

        finalizer_path = root / paths["finalizerReportPath"]
        finalizer = json.loads(finalizer_path.read_text(encoding="utf-8"))
        finalizer["outputs"]["releaseArtifactBundle"]["sha256"] = bundle_sha
        _write_json(finalizer_path, finalizer)
        finalizer_sha = hashlib.sha256(finalizer_path.read_bytes()).hexdigest()

        finalizer_check_path = root / paths["finalizerCheckPath"]
        finalizer_check = json.loads(finalizer_check_path.read_text(encoding="utf-8"))
        finalizer_check["finalizerReportSha256"] = finalizer_sha
        _write_json(finalizer_check_path, finalizer_check)
        finalizer_check_sha = hashlib.sha256(finalizer_check_path.read_bytes()).hexdigest()

        readiness_path = root / paths["readinessReportPath"]
        readiness = json.loads(readiness_path.read_text(encoding="utf-8"))
        evidence = readiness["rows"][0]["frontierBundleEvidence"]
        release_candidate = evidence["releaseCandidateEvidence"]
        evidence["componentReceipts"]["releaseArtifactBundle"]["sha256"] = bundle_sha
        release_candidate["publicDownloadReceipt"]["sha256"] = public_download_sha
        release_candidate["provenanceReport"]["sha256"] = provenance_sha
        release_candidate["finalizerReport"]["sha256"] = finalizer_sha
        release_candidate["finalizerCheck"]["sha256"] = finalizer_check_sha
        _write_json(readiness_path, readiness)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_public_download_identity_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_package_input_artifact_identity() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        paths = _browser_release_paths()

        package_path = root / paths["packageInputsPath"]
        package_inputs = json.loads(package_path.read_text(encoding="utf-8"))
        package_inputs["inputs"]["doeRuntime"]["sha256"] = "0" * 64
        _write_json(package_path, package_inputs)
        package_sha = hashlib.sha256(package_path.read_bytes()).hexdigest()

        bundle_path = root / paths["releaseArtifactBundlePath"]
        bundle = json.loads(bundle_path.read_text(encoding="utf-8"))
        bundle["packageInputs"]["sha256"] = package_sha
        _write_json(bundle_path, bundle)
        bundle_sha = hashlib.sha256(bundle_path.read_bytes()).hexdigest()

        finalizer_path = root / paths["finalizerReportPath"]
        finalizer = json.loads(finalizer_path.read_text(encoding="utf-8"))
        finalizer["inputs"]["packageInputs"]["sha256"] = package_sha
        finalizer["outputs"]["releaseArtifactBundle"]["sha256"] = bundle_sha
        _write_json(finalizer_path, finalizer)
        finalizer_sha = hashlib.sha256(finalizer_path.read_bytes()).hexdigest()

        finalizer_check_path = root / paths["finalizerCheckPath"]
        finalizer_check = json.loads(finalizer_check_path.read_text(encoding="utf-8"))
        finalizer_check["finalizerReportSha256"] = finalizer_sha
        _write_json(finalizer_check_path, finalizer_check)
        finalizer_check_sha = hashlib.sha256(finalizer_check_path.read_bytes()).hexdigest()

        readiness_path = root / paths["readinessReportPath"]
        readiness = json.loads(readiness_path.read_text(encoding="utf-8"))
        evidence = readiness["rows"][0]["frontierBundleEvidence"]
        release_candidate = evidence["releaseCandidateEvidence"]
        evidence["componentReceipts"]["releaseArtifactBundle"]["sha256"] = bundle_sha
        release_candidate["packageInputs"]["sha256"] = package_sha
        release_candidate["finalizerReport"]["sha256"] = finalizer_sha
        release_candidate["finalizerCheck"]["sha256"] = finalizer_check_sha
        _write_json(readiness_path, readiness)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_package_inputs_artifact_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_provenance_release_identity() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        paths = _browser_release_paths()

        provenance_path = root / paths["provenanceReportPath"]
        provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
        provenance["expectedProvenance"][
            "doeRuntimeArchivePath"
        ] = "Fawn.app/Contents/Frameworks/libwebgpu_doe_other.so"
        _write_json(provenance_path, provenance)
        provenance_sha = hashlib.sha256(provenance_path.read_bytes()).hexdigest()

        readiness_path = root / paths["readinessReportPath"]
        readiness = json.loads(readiness_path.read_text(encoding="utf-8"))
        readiness["rows"][0]["frontierBundleEvidence"]["releaseCandidateEvidence"][
            "provenanceReport"
        ]["sha256"] = provenance_sha
        _write_json(readiness_path, readiness)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_provenance_identity_mismatch" in codes


def test_browser_chromium_release_rejects_manifest_file_hash_drift() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_browser_release_artifacts(root)
        manifest_path = root / _browser_release_paths()["releaseArchiveManifestPath"]
        _write_json(
            manifest_path,
            {
                "artifactKind": "browser_release_archive_manifest",
                "drift": True,
            },
        )

        result = gate.evaluate_index(_index(_browser_chromium_entry()), schema, root)

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_archive_manifest_hash_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_archive_manifest_release_identity() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        paths = _browser_release_paths()

        manifest_path = root / paths["releaseArchiveManifestPath"]
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["members"]["doeRuntime"][
            "archivePath"
        ] = "Fawn.app/Contents/Frameworks/libwebgpu_doe_other.so"
        _write_json(manifest_path, manifest)
        manifest_sha = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
        _refresh_release_archive_manifest_dependent_hashes(root, paths, manifest_sha)
        entry = _browser_chromium_entry(claim_state="claim-indexed")
        entry["browserRelease"]["releaseArchiveManifestSha256"] = manifest_sha

        result = gate.evaluate_index(
            _index(entry),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_archive_manifest_identity_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_archive_manifest_member_artifacts() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        paths = _browser_release_paths()

        manifest_path = root / paths["releaseArchiveManifestPath"]
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["members"]["doeRuntime"]["sha256"] = "0" * 64
        _write_json(manifest_path, manifest)
        manifest_sha = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
        _refresh_release_archive_manifest_dependent_hashes(root, paths, manifest_sha)
        entry = _browser_chromium_entry(claim_state="claim-indexed")
        entry["browserRelease"]["releaseArchiveManifestSha256"] = manifest_sha

        result = gate.evaluate_index(
            _index(entry),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_archive_manifest_member_mismatch" in codes


def test_browser_chromium_claim_indexed_release_rejects_duplicate_bundle_member_paths() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        paths = _browser_release_paths()

        bundle_path = root / paths["releaseArtifactBundlePath"]
        bundle = json.loads(bundle_path.read_text(encoding="utf-8"))
        bundle["dawnFallbackRuntimeArchivePath"] = bundle["doeRuntimeArchivePath"]
        _write_json(bundle_path, bundle)
        bundle_sha = hashlib.sha256(bundle_path.read_bytes()).hexdigest()

        finalizer_path = root / paths["finalizerReportPath"]
        finalizer = json.loads(finalizer_path.read_text(encoding="utf-8"))
        finalizer["outputs"]["releaseArtifactBundle"]["sha256"] = bundle_sha
        _write_json(finalizer_path, finalizer)
        finalizer_sha = hashlib.sha256(finalizer_path.read_bytes()).hexdigest()

        finalizer_check_path = root / paths["finalizerCheckPath"]
        finalizer_check = json.loads(finalizer_check_path.read_text(encoding="utf-8"))
        finalizer_check["finalizerReportSha256"] = finalizer_sha
        _write_json(finalizer_check_path, finalizer_check)
        finalizer_check_sha = hashlib.sha256(finalizer_check_path.read_bytes()).hexdigest()

        readiness_path = root / paths["readinessReportPath"]
        readiness = json.loads(readiness_path.read_text(encoding="utf-8"))
        evidence = readiness["rows"][0]["frontierBundleEvidence"]
        release_candidate = evidence["releaseCandidateEvidence"]
        evidence["componentReceipts"]["releaseArtifactBundle"]["sha256"] = bundle_sha
        release_candidate["finalizerReport"]["sha256"] = finalizer_sha
        release_candidate["finalizerCheck"]["sha256"] = finalizer_check_sha
        _write_json(readiness_path, readiness)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_bundle_member_path_duplicate" in codes


def test_browser_chromium_claim_indexed_release_rejects_unsafe_bundle_member_path() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        paths = _browser_release_paths()

        bundle_path = root / paths["releaseArtifactBundlePath"]
        bundle = json.loads(bundle_path.read_text(encoding="utf-8"))
        bundle["browserExecutableArchivePath"] = "Fawn.app/./Contents/MacOS/Chromium"
        _write_json(bundle_path, bundle)
        _refresh_runtime_frontier_dependent_hashes(root, paths)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    failures = {
        (item["code"], item["path"], item["message"])
        for item in result["failures"]
    }

    assert (
        "browser_release_bundle_member_path_unsafe",
        "entries[0].browserRelease.releaseArtifactBundlePath",
        (
            "release artifact bundle browser executable archive member path "
            "must not contain empty, current, or parent segments"
        ),
    ) in failures


def test_browser_chromium_claim_indexed_release_rejects_duplicate_archive_members() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        paths = _browser_release_paths()

        manifest_path = root / paths["releaseArchiveManifestPath"]
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        members = manifest["members"]
        manifest["archiveMembers"] = [
            dict(members["browserExecutable"]),
            dict(members["appMetadata"]),
            dict(members["doeRuntime"]),
            dict(members["dawnFallbackRuntime"]),
            dict(members["doeRuntime"]),
        ]
        _write_json(manifest_path, manifest)
        manifest_sha = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
        _refresh_release_archive_manifest_dependent_hashes(root, paths, manifest_sha)
        entry = _browser_chromium_entry(claim_state="claim-indexed")
        entry["browserRelease"]["releaseArchiveManifestSha256"] = manifest_sha

        result = gate.evaluate_index(
            _index(entry),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_archive_manifest_member_duplicate" in codes


def test_browser_chromium_claim_indexed_release_rejects_unsafe_archive_manifest_member_path() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        paths = _browser_release_paths()

        manifest_path = root / paths["releaseArchiveManifestPath"]
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["members"]["browserExecutable"][
            "archivePath"
        ] = "Fawn.app//Contents/MacOS/Chromium"
        _write_json(manifest_path, manifest)
        manifest_sha = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
        _refresh_release_archive_manifest_dependent_hashes(root, paths, manifest_sha)
        entry = _browser_chromium_entry(claim_state="claim-indexed")
        entry["browserRelease"]["releaseArchiveManifestSha256"] = manifest_sha

        result = gate.evaluate_index(
            _index(entry),
            schema,
            root,
        )

    failures = {
        (item["code"], item["path"], item["message"])
        for item in result["failures"]
    }

    assert (
        "browser_release_archive_manifest_member_path_unsafe",
        "entries[0].browserRelease.releaseArchiveManifestPath",
        (
            "release archive manifest browserExecutable.archivePath archive "
            "member path must not contain empty, current, or parent segments"
        ),
    ) in failures


def test_browser_chromium_claim_indexed_release_checks_archive_manifest_source_package_inputs() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        paths = _browser_release_paths()

        manifest_path = root / paths["releaseArchiveManifestPath"]
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["sourcePackageInputs"] = {
            "path": "bench/out/unit/other-browser-release-package-inputs.json",
            "sha256": "0" * 64,
            "kind": "browser_release_package_inputs_check",
        }
        _write_json(manifest_path, manifest)
        manifest_sha = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
        _refresh_release_archive_manifest_dependent_hashes(root, paths, manifest_sha)
        entry = _browser_chromium_entry(claim_state="claim-indexed")
        entry["browserRelease"]["releaseArchiveManifestSha256"] = manifest_sha

        result = gate.evaluate_index(
            _index(entry),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_archive_manifest_source_package_inputs_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_loadable_evidence() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_artifact_unavailable" in codes


def test_browser_chromium_claim_indexed_release_accepts_complete_evidence() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    assert result["ok"], result["failures"]


def test_browser_chromium_claim_indexed_release_requires_proof_surface_check_identity() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        paths = _browser_release_paths()

        check_path = root / paths["proofSurfaceCheckPath"]
        check = json.loads(check_path.read_text(encoding="utf-8"))
        check["surfaceSha256"] = "0" * 64
        _write_json(check_path, check)
        check_sha = hashlib.sha256(check_path.read_bytes()).hexdigest()

        bundle_path = root / paths["releaseArtifactBundlePath"]
        bundle = json.loads(bundle_path.read_text(encoding="utf-8"))
        bundle["proofSurfaceCheck"]["sha256"] = check_sha
        _write_json(bundle_path, bundle)
        bundle_sha = hashlib.sha256(bundle_path.read_bytes()).hexdigest()

        readiness_path = root / paths["readinessReportPath"]
        readiness = json.loads(readiness_path.read_text(encoding="utf-8"))
        evidence = readiness["rows"][0]["frontierBundleEvidence"]
        evidence["componentReceipts"]["releaseArtifactBundle"]["sha256"] = bundle_sha
        evidence["releaseCandidateEvidence"]["proofSurfaceCheck"]["sha256"] = check_sha
        _write_json(readiness_path, readiness)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_check_identity_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_clean_proof_surface_check() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        paths = _browser_release_paths()

        check_path = root / paths["proofSurfaceCheckPath"]
        check = json.loads(check_path.read_text(encoding="utf-8"))
        check["failures"] = [
            {
                "code": "unit_proof_surface_check_failure",
                "path": "proofSurfaceCheck",
                "message": "unit proof-surface check failure",
            }
        ]
        _write_json(check_path, check)
        check_sha = hashlib.sha256(check_path.read_bytes()).hexdigest()

        bundle_path = root / paths["releaseArtifactBundlePath"]
        bundle = json.loads(bundle_path.read_text(encoding="utf-8"))
        bundle["proofSurfaceCheck"]["sha256"] = check_sha
        _write_json(bundle_path, bundle)
        bundle_sha = hashlib.sha256(bundle_path.read_bytes()).hexdigest()

        readiness_path = root / paths["readinessReportPath"]
        readiness = json.loads(readiness_path.read_text(encoding="utf-8"))
        evidence = readiness["rows"][0]["frontierBundleEvidence"]
        evidence["componentReceipts"]["releaseArtifactBundle"]["sha256"] = bundle_sha
        evidence["releaseCandidateEvidence"]["proofSurfaceCheck"]["sha256"] = check_sha
        _write_json(readiness_path, readiness)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_check_has_failures" in codes


def test_browser_chromium_claim_indexed_release_requires_clean_runtime_frontier() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        paths = _browser_release_paths()

        runtime_path = root / paths["runtimeFrontierBundlePath"]
        runtime_frontier = json.loads(runtime_path.read_text(encoding="utf-8"))
        runtime_frontier["failures"] = [
            {
                "code": "unit_runtime_frontier_failure",
                "path": "runtimeFrontierBundle",
                "message": "unit runtime frontier failure",
            }
        ]
        runtime_frontier["summary"]["failureCount"] = 1
        _write_json(runtime_path, runtime_frontier)
        runtime_sha = hashlib.sha256(runtime_path.read_bytes()).hexdigest()

        bundle_path = root / paths["releaseArtifactBundlePath"]
        bundle = json.loads(bundle_path.read_text(encoding="utf-8"))
        bundle["runtimeFrontierBundle"]["sha256"] = runtime_sha
        _write_json(bundle_path, bundle)
        bundle_sha = hashlib.sha256(bundle_path.read_bytes()).hexdigest()

        readiness_path = root / paths["readinessReportPath"]
        readiness = json.loads(readiness_path.read_text(encoding="utf-8"))
        evidence = readiness["rows"][0]["frontierBundleEvidence"]
        evidence["sha256"] = runtime_sha
        evidence["componentReceipts"]["releaseArtifactBundle"]["sha256"] = bundle_sha
        _write_json(readiness_path, readiness)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_runtime_frontier_not_clean" in codes


def test_browser_chromium_claim_indexed_release_requires_runtime_frontier_release_component() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        paths = _browser_release_paths()

        runtime_path = root / paths["runtimeFrontierBundlePath"]
        runtime_frontier = json.loads(runtime_path.read_text(encoding="utf-8"))
        runtime_frontier["componentReceipts"]["releaseArtifactBundle"][
            "path"
        ] = "bench/out/unit/other-release-artifact-bundle.json"
        _write_json(runtime_path, runtime_frontier)
        runtime_sha = hashlib.sha256(runtime_path.read_bytes()).hexdigest()

        bundle_path = root / paths["releaseArtifactBundlePath"]
        bundle = json.loads(bundle_path.read_text(encoding="utf-8"))
        bundle["runtimeFrontierBundle"]["sha256"] = runtime_sha
        _write_json(bundle_path, bundle)
        bundle_sha = hashlib.sha256(bundle_path.read_bytes()).hexdigest()

        finalizer_path = root / paths["finalizerReportPath"]
        finalizer = json.loads(finalizer_path.read_text(encoding="utf-8"))
        finalizer["outputs"]["releaseArtifactBundle"]["sha256"] = bundle_sha
        finalizer["outputs"]["runtimeFrontierBundle"]["sha256"] = runtime_sha
        _write_json(finalizer_path, finalizer)
        finalizer_sha = hashlib.sha256(finalizer_path.read_bytes()).hexdigest()

        finalizer_check_path = root / paths["finalizerCheckPath"]
        finalizer_check = json.loads(finalizer_check_path.read_text(encoding="utf-8"))
        finalizer_check["finalizerReportSha256"] = finalizer_sha
        _write_json(finalizer_check_path, finalizer_check)
        finalizer_check_sha = hashlib.sha256(finalizer_check_path.read_bytes()).hexdigest()

        readiness_path = root / paths["readinessReportPath"]
        readiness = json.loads(readiness_path.read_text(encoding="utf-8"))
        evidence = readiness["rows"][0]["frontierBundleEvidence"]
        release_candidate = evidence["releaseCandidateEvidence"]
        evidence["sha256"] = runtime_sha
        evidence["componentReceipts"]["releaseArtifactBundle"]["sha256"] = bundle_sha
        release_candidate["finalizerReport"]["sha256"] = finalizer_sha
        release_candidate["finalizerCheck"]["sha256"] = finalizer_check_sha
        _write_json(readiness_path, readiness)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_runtime_frontier_component_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_runtime_frontier_release_identity_hash() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        paths = _browser_release_paths()

        runtime_path = root / paths["runtimeFrontierBundlePath"]
        runtime_frontier = json.loads(runtime_path.read_text(encoding="utf-8"))
        runtime_frontier["componentReceipts"]["releaseArtifactBundle"][
            "releaseBundleIdentitySha256"
        ] = "0" * 64
        _write_json(runtime_path, runtime_frontier)
        _refresh_runtime_frontier_dependent_hashes(root, paths)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_runtime_frontier_component_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_runtime_frontier_runtime_identity_component() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        paths = _browser_release_paths()

        runtime_path = root / paths["runtimeFrontierBundlePath"]
        runtime_frontier = json.loads(runtime_path.read_text(encoding="utf-8"))
        runtime_frontier["componentReceipts"]["runtimeIdentity"][
            "path"
        ] = "bench/out/unit/other-runtime-identity.json"
        _write_json(runtime_path, runtime_frontier)
        _refresh_runtime_frontier_dependent_hashes(root, paths)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_runtime_frontier_runtime_identity_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_runtime_frontier_promotion_component() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        paths = _browser_release_paths()

        runtime_path = root / paths["runtimeFrontierBundlePath"]
        runtime_frontier = json.loads(runtime_path.read_text(encoding="utf-8"))
        runtime_frontier["componentReceipts"]["claimPromotionReceipt"][
            "path"
        ] = "bench/out/unit/other-claim-promotion-receipt.json"
        _write_json(runtime_path, runtime_frontier)
        _refresh_runtime_frontier_dependent_hashes(root, paths)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_runtime_frontier_promotion_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_bundle_components() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        bundle_path = root / _browser_release_paths()["releaseArtifactBundlePath"]
        bundle = json.loads(bundle_path.read_text(encoding="utf-8"))
        del bundle["packageInputs"]
        _write_json(bundle_path, bundle)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}
    paths = {item["path"] for item in result["failures"]}

    assert "browser_release_bundle_component_missing" in codes
    assert "entries[0].browserRelease.packageInputsPath" in paths


def test_browser_chromium_claim_indexed_release_requires_about_doe_proof_page() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        launch_path = root / _browser_release_paths()["browserLaunchReceiptPath"]
        launch = json.loads(launch_path.read_text(encoding="utf-8"))
        launch["proofPage"]["url"] = "chrome://doe"
        _write_json(launch_path, launch)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_launch_receipt_without_proof_page" in codes


def test_browser_chromium_claim_indexed_release_requires_same_page_receipts() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        launch_path = root / _browser_release_paths()["browserLaunchReceiptPath"]
        launch = json.loads(launch_path.read_text(encoding="utf-8"))
        launch["comparisonReceipt"]["emitsSideBySideReceipts"] = False
        launch["observedReceiptIds"].remove("unit-doe-receipt")
        _write_json(launch_path, launch)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_launch_receipt_without_same_page_comparison" in codes
    assert "browser_release_launch_receipt_missing_observed_receipts" in codes


def test_browser_chromium_claim_indexed_release_rejects_duplicate_launch_observed_receipts() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        launch_path = root / _browser_release_paths()["browserLaunchReceiptPath"]
        launch = json.loads(launch_path.read_text(encoding="utf-8"))
        launch["observedReceiptIds"].append(launch["observedReceiptIds"][0])
        _write_json(launch_path, launch)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    assert {
        "code": "browser_release_launch_receipt_duplicate_observed_receipts",
        "path": "entries[0].browserRelease.browserLaunchReceiptPath",
        "message": "browser launch observedReceiptIds must uniquely identify observed receipts",
    } in result["failures"]


def test_browser_chromium_claim_indexed_release_rejects_unlinked_launch_observed_receipts() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        launch_path = root / _browser_release_paths()["browserLaunchReceiptPath"]
        launch = json.loads(launch_path.read_text(encoding="utf-8"))
        launch["observedReceiptIds"].append("unit-unlinked-receipt")
        _write_json(launch_path, launch)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    assert {
        "code": "browser_release_launch_receipt_unlinked_observed_receipts",
        "path": "entries[0].browserRelease.browserLaunchReceiptPath",
        "message": "browser launch observedReceiptIds must exactly match proof, gallery, Dawn, and Doe receipt IDs",
    } in result["failures"]


def test_browser_chromium_claim_indexed_release_rejects_malformed_launch_observed_receipts() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        launch_path = root / _browser_release_paths()["browserLaunchReceiptPath"]
        launch = json.loads(launch_path.read_text(encoding="utf-8"))
        launch["observedReceiptIds"].append("")
        _write_json(launch_path, launch)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    assert {
        "code": "browser_release_launch_receipt_missing_observed_receipts",
        "path": "entries[0].browserRelease.browserLaunchReceiptPath",
        "message": "claim-indexed Chromium browser releases require observed proof, gallery, Dawn, and Doe receipt IDs",
    } in result["failures"]


def test_browser_chromium_claim_indexed_release_requires_launch_proof_surface_binding() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        launch_path = root / _browser_release_paths()["browserLaunchReceiptPath"]
        launch = json.loads(launch_path.read_text(encoding="utf-8"))
        launch["galleryPage"]["artifactPath"] = "bench/out/unit/other-gallery.html"
        _write_json(launch_path, launch)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_launch_proof_surface_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_launch_receipt_ids_match_proof_surface_payloads() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        launch_path = root / _browser_release_paths()["browserLaunchReceiptPath"]
        launch = json.loads(launch_path.read_text(encoding="utf-8"))
        launch["proofPage"]["receiptId"] = "unit-other-proof-page"
        launch["galleryPage"]["receiptId"] = "unit-other-gallery"
        launch["observedReceiptIds"] = [
            "unit-other-proof-page",
            "unit-other-gallery",
            "unit-dawn-receipt",
            "unit-doe-receipt",
        ]
        _write_json(launch_path, launch)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_launch_proof_surface_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_launch_proof_surface_identity() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        paths = _browser_release_paths()

        launch_path = root / paths["browserLaunchReceiptPath"]
        launch = json.loads(launch_path.read_text(encoding="utf-8"))
        launch["proofSurface"]["sha256"] = "0" * 64
        _write_json(launch_path, launch)
        launch_sha = hashlib.sha256(launch_path.read_bytes()).hexdigest()

        bundle_path = root / paths["releaseArtifactBundlePath"]
        bundle = json.loads(bundle_path.read_text(encoding="utf-8"))
        bundle["browserLaunchReceipt"]["sha256"] = launch_sha
        _write_json(bundle_path, bundle)
        bundle_sha = hashlib.sha256(bundle_path.read_bytes()).hexdigest()

        readiness_path = root / paths["readinessReportPath"]
        readiness = json.loads(readiness_path.read_text(encoding="utf-8"))
        evidence = readiness["rows"][0]["frontierBundleEvidence"]
        evidence["componentReceipts"]["releaseArtifactBundle"]["sha256"] = bundle_sha
        evidence["releaseCandidateEvidence"]["browserLaunchReceipt"][
            "sha256"
        ] = launch_sha
        _write_json(readiness_path, readiness)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_launch_proof_surface_identity_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_full_gallery_surface() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["galleryPages"] = [
            item
            for item in proof_surface["galleryPages"]
            if item["category"] != "shader_edge"
        ]
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_gallery_incomplete" in codes


def test_browser_chromium_claim_indexed_release_requires_public_gallery_urls() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)

        reserved_url = "https://gallery.test/unit/compute.html"
        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["galleryPages"][0]["url"] = reserved_url
        public_receipt_path = root / proof_surface["galleryPages"][0]["publicReceipt"]["path"]
        public_receipt = json.loads(public_receipt_path.read_text(encoding="utf-8"))
        public_receipt["url"] = reserved_url
        _write_json(public_receipt_path, public_receipt)
        proof_surface["galleryPages"][0]["publicReceipt"]["sha256"] = hashlib.sha256(
            public_receipt_path.read_bytes()
        ).hexdigest()
        _write_json(proof_surface_path, proof_surface)

        launch_path = root / _browser_release_paths()["browserLaunchReceiptPath"]
        launch = json.loads(launch_path.read_text(encoding="utf-8"))
        launch["galleryPage"]["url"] = reserved_url
        _write_json(launch_path, launch)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_launch_receipt_without_gallery" in codes
    assert "browser_release_proof_surface_gallery_incomplete" in codes


def test_browser_chromium_claim_indexed_release_rejects_unknown_gallery_categories() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        extra_row = copy.deepcopy(proof_surface["galleryPages"][0])
        extra_row["category"] = "local_only"
        extra_row["url"] = "https://gallery.doe.dev/unit/local-only.html"
        public_receipt = json.loads(
            (root / extra_row["publicReceipt"]["path"]).read_text(encoding="utf-8")
        )
        extra_row["publicReceipt"]["path"] = "bench/out/unit/browser-public-gallery-local-only.json"
        public_receipt_path = root / extra_row["publicReceipt"]["path"]
        public_receipt["category"] = extra_row["category"]
        public_receipt["url"] = extra_row["url"]
        _write_json(public_receipt_path, public_receipt)
        extra_row["publicReceipt"]["sha256"] = hashlib.sha256(
            public_receipt_path.read_bytes()
        ).hexdigest()
        proof_surface["galleryPages"].append(extra_row)
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_gallery_incomplete" in codes


def test_browser_chromium_claim_indexed_release_rejects_duplicate_gallery_artifacts() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["galleryPages"].append(copy.deepcopy(proof_surface["galleryPages"][0]))
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    assert {
        "code": "browser_release_proof_surface_gallery_identity_duplicate",
        "path": "entries[0].browserRelease.proofSurfacePath",
        "message": "claim-indexed Chromium browser gallery artifact paths must be unique",
    } in result["failures"]


def test_browser_chromium_claim_indexed_release_rejects_unsafe_gallery_artifact_path() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["galleryPages"][0]["artifact"]["path"] = "/tmp/browser-gallery-compute.html"
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    failures = {
        (item["code"], item["path"], item["message"])
        for item in result["failures"]
    }

    assert (
        "browser_release_proof_surface_public_gallery_receipt_incomplete",
        "entries[0].browserRelease.proofSurfacePath",
        "artifact path must be repository-relative",
    ) in failures


def test_browser_chromium_claim_indexed_release_rejects_unsafe_public_gallery_receipt_path() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["galleryPages"][0]["publicReceipt"][
            "path"
        ] = "/tmp/browser-public-gallery-compute.json"
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    failures = {
        (item["code"], item["path"], item["message"])
        for item in result["failures"]
    }

    assert (
        "browser_release_proof_surface_public_gallery_receipt_incomplete",
        "entries[0].browserRelease.proofSurfacePath",
        "receipt path must be repository-relative",
    ) in failures


def test_browser_chromium_claim_indexed_release_rejects_duplicate_gallery_urls() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["galleryPages"][1]["url"] = proof_surface["galleryPages"][0]["url"]
        public_receipt_path = root / proof_surface["galleryPages"][1]["publicReceipt"]["path"]
        public_receipt = json.loads(public_receipt_path.read_text(encoding="utf-8"))
        public_receipt["url"] = proof_surface["galleryPages"][1]["url"]
        _write_json(public_receipt_path, public_receipt)
        proof_surface["galleryPages"][1]["publicReceipt"]["sha256"] = hashlib.sha256(
            public_receipt_path.read_bytes()
        ).hexdigest()
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    assert {
        "code": "browser_release_proof_surface_gallery_url_duplicate",
        "path": "entries[0].browserRelease.proofSurfacePath",
        "message": "claim-indexed Chromium browser gallery URLs must be unique",
    } in result["failures"]


def test_browser_chromium_claim_indexed_release_requires_proof_surface_comparison_parity() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["comparisonReceipts"][0]["comparisonPolicy"][
            "sourceShaderIdentity"
        ] = "unmatched_source"
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_comparison_incomplete" in codes


def test_browser_chromium_claim_indexed_release_rejects_malformed_extra_comparison_rows() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["comparisonReceipts"].append(
            {
                "comparisonId": "unit-extra-dawn-vs-doe",
                "workloadId": "unit-extra-compute",
            }
        )
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    assert {
        "code": "browser_release_proof_surface_comparison_incomplete",
        "path": "entries[0].browserRelease.proofSurfacePath",
        "message": (
            "claim-indexed Chromium browser comparison entries require comparisonId, "
            "workloadId, runner, comparisonPolicy, comparisonArtifact, Dawn receipt, "
            "and Doe receipt"
        ),
    } in result["failures"]


def test_browser_chromium_claim_indexed_release_rejects_duplicate_comparison_ids() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["comparisonReceipts"].append(
            copy.deepcopy(proof_surface["comparisonReceipts"][0])
        )
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    assert {
        "code": "browser_release_proof_surface_comparison_identity_duplicate",
        "path": "entries[0].browserRelease.proofSurfacePath",
        "message": "claim-indexed Chromium browser comparison IDs must be unique",
    } in result["failures"]


def test_browser_chromium_claim_indexed_release_rejects_duplicate_comparison_evidence() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        duplicate = copy.deepcopy(proof_surface["comparisonReceipts"][0])
        duplicate["comparisonId"] = "unit-compute-dawn-vs-doe-copy"
        proof_surface["comparisonReceipts"].append(duplicate)
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    assert {
        "code": "browser_release_proof_surface_comparison_artifact_duplicate",
        "path": "entries[0].browserRelease.proofSurfacePath",
        "message": "claim-indexed Chromium browser comparison artifact paths must be unique",
    } in result["failures"]
    assert {
        "code": "browser_release_proof_surface_comparison_receipt_pair_duplicate",
        "path": "entries[0].browserRelease.proofSurfacePath",
        "message": "claim-indexed Chromium browser comparison receipt pairs must be unique",
    } in result["failures"]


def test_browser_chromium_claim_indexed_release_rejects_unsafe_comparison_artifact_path() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["comparisonReceipts"][0]["comparisonArtifact"][
            "path"
        ] = "/tmp/browser-smoke-report.json"
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    failures = {
        (item["code"], item["path"], item["message"])
        for item in result["failures"]
    }

    assert (
        "browser_release_proof_surface_comparison_artifact_incomplete",
        "entries[0].browserRelease.proofSurfacePath",
        "artifact path must be repository-relative",
    ) in failures


def test_browser_chromium_claim_indexed_release_rejects_unpaired_comparison_receipts() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["comparisonReceipts"][0]["doeReceipt"] = copy.deepcopy(
            proof_surface["comparisonReceipts"][0]["dawnReceipt"]
        )
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    assert {
        "code": "browser_release_proof_surface_comparison_receipt_duplicate",
        "path": "entries[0].browserRelease.proofSurfacePath",
        "message": "claim-indexed Chromium browser comparison rows must link distinct Dawn and Doe execution receipts",
    } in result["failures"]


def test_browser_chromium_claim_indexed_release_rejects_unsafe_execution_receipt_path() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["comparisonReceipts"][0]["dawnReceipt"][
            "path"
        ] = "/tmp/browser-dawn-execution-receipt.json"
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    failures = {
        (item["code"], item["path"], item["message"])
        for item in result["failures"]
    }

    assert (
        "browser_release_proof_surface_receipt_incomplete",
        "entries[0].browserRelease.proofSurfacePath",
        "receipt path must be repository-relative",
    ) in failures


def test_browser_chromium_claim_indexed_release_requires_comparison_runner_gallery_page() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["comparisonReceipts"][0]["runner"][
            "pageArtifactPath"
        ] = "bench/out/unit/browser-gallery-offsurface.html"
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    assert {
        "code": "browser_release_proof_surface_comparison_page_unpublished",
        "path": "entries[0].browserRelease.proofSurfacePath",
        "message": "claim-indexed Chromium browser comparison runner pages must be published gallery artifacts",
    } in result["failures"]


def test_browser_chromium_claim_indexed_release_requires_proof_page_diagnostics() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        diagnostics = proof_surface["proofPage"]["diagnostics"]
        diagnostics["compilerPath"] = ""
        diagnostics["tsirStatus"] = ""
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_without_doe_diagnostics" in codes


def test_browser_chromium_claim_indexed_release_requires_concrete_proof_diagnostics() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        diagnostics = proof_surface["proofPage"]["diagnostics"]
        diagnostics["tsirStatus"] = "diagnostic"
        diagnostics["hostPlanStatus"] = "diagnostic"
        diagnostics["cslStatus"] = "diagnostic"
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    failures = {
        (item["code"], item["path"], item["message"])
        for item in result["failures"]
    }

    assert (
        "browser_release_proof_surface_non_release_diagnostic_status",
        "entries[0].browserRelease.proofSurfacePath",
        "claim-indexed Chromium browser proof surfaces require concrete tsirStatus diagnostics",
    ) in failures
    assert (
        "browser_release_proof_surface_non_release_diagnostic_status",
        "entries[0].browserRelease.proofSurfacePath",
        "claim-indexed Chromium browser proof surfaces require concrete hostPlanStatus diagnostics",
    ) in failures
    assert (
        "browser_release_proof_surface_non_release_diagnostic_status",
        "entries[0].browserRelease.proofSurfacePath",
        "claim-indexed Chromium browser proof surfaces require concrete cslStatus diagnostics",
    ) in failures


def test_browser_chromium_claim_indexed_release_rejects_unsafe_proof_page_artifact_path() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["proofPage"]["artifact"]["path"] = "/tmp/browser-proof-page.html"
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    failures = {
        (item["code"], item["path"], item["message"])
        for item in result["failures"]
    }

    assert (
        "browser_release_proof_surface_proof_page_receipt_incomplete",
        "entries[0].browserRelease.proofSurfacePath",
        "artifact path must be repository-relative",
    ) in failures


def test_browser_chromium_claim_indexed_release_rejects_unsafe_proof_page_receipt_path() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["proofPage"]["diagnosticReceipt"][
            "path"
        ] = "/tmp/browser-proof-page-receipt.json"
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    failures = {
        (item["code"], item["path"], item["message"])
        for item in result["failures"]
    }

    assert (
        "browser_release_proof_surface_proof_page_receipt_incomplete",
        "entries[0].browserRelease.proofSurfacePath",
        "receipt path must be repository-relative",
    ) in failures


def test_browser_chromium_claim_indexed_release_requires_proof_page_compiler_release_identity() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["proofPage"]["diagnostics"][
            "compilerPath"
        ] = "runtime/zig/zig-out/bin/other-doe-compiler"
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_compiler_identity_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_proof_runtime_identity_release_hashes() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        runtime_identity_path = root / "bench/out/unit/browser-runtime-identity.json"
        runtime_identity = json.loads(runtime_identity_path.read_text(encoding="utf-8"))
        runtime_identity["provider"]["artifactIdentity"]["doeLibSha256"] = "0" * 64
        runtime_identity["runtimeSelection"]["artifactIdentity"]["doeLibSha256"] = "0" * 64
        _write_json(runtime_identity_path, runtime_identity)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_runtime_identity_release_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_recent_receipt_coverage() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["proofPage"]["recentReceiptIds"] = ["unit-dawn-receipt"]
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_recent_receipts_incomplete" in codes


def test_browser_chromium_claim_indexed_release_rejects_duplicate_recent_receipts() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["proofPage"]["recentReceiptIds"].append(
            proof_surface["proofPage"]["recentReceiptIds"][0]
        )
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    assert {
        "code": "browser_release_proof_surface_recent_receipts_duplicate",
        "path": "entries[0].browserRelease.proofSurfacePath",
        "message": "proof-page recentReceiptIds must uniquely identify exposed execution receipts",
    } in result["failures"]


def test_browser_chromium_claim_indexed_release_rejects_duplicate_receipt_payload_links() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["proofPage"]["receiptPayloads"].append(
            copy.deepcopy(proof_surface["proofPage"]["receiptPayloads"][0])
        )
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    assert {
        "code": "browser_release_proof_surface_receipt_payload_duplicate",
        "path": "entries[0].browserRelease.proofSurfacePath",
        "message": "proof-page receiptPayloads must uniquely identify execution receipt artifacts",
    } in result["failures"]


def test_browser_chromium_claim_indexed_release_requires_execution_receipt_fields() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        receipt_path = root / "bench/out/unit/browser-doe-execution-receipt.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        del receipt["sourceShader"]["source"]
        _write_json(receipt_path, receipt)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_receipt_hash_mismatch" in codes
    assert "browser_release_proof_surface_receipt_incomplete" in codes


def test_browser_chromium_claim_indexed_release_requires_execution_receipt_parity() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        receipt_path = root / "bench/out/unit/browser-doe-execution-receipt.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["outputHash"] = "7" * 64
        _write_json(receipt_path, receipt)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_receipt_hash_mismatch" in codes
    assert "browser_release_proof_surface_comparison_payload_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_clean_finalizer_check() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        paths = _browser_release_paths()

        finalizer_check_path = root / paths["finalizerCheckPath"]
        finalizer_check = json.loads(finalizer_check_path.read_text(encoding="utf-8"))
        finalizer_check["failures"] = [
            {
                "code": "unit_finalizer_check_failure",
                "path": "finalizerCheck",
                "message": "unit finalizer check failure",
            }
        ]
        _write_json(finalizer_check_path, finalizer_check)
        finalizer_check_sha = hashlib.sha256(finalizer_check_path.read_bytes()).hexdigest()

        readiness_path = root / paths["readinessReportPath"]
        readiness = json.loads(readiness_path.read_text(encoding="utf-8"))
        readiness["rows"][0]["frontierBundleEvidence"]["releaseCandidateEvidence"][
            "finalizerCheck"
        ]["sha256"] = finalizer_check_sha
        _write_json(readiness_path, readiness)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_finalizer_check_has_failures" in codes


def test_browser_chromium_claim_indexed_release_requires_finalizer_check_identity() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        paths = _browser_release_paths()

        finalizer_check_path = root / paths["finalizerCheckPath"]
        finalizer_check = json.loads(finalizer_check_path.read_text(encoding="utf-8"))
        finalizer_check["finalizerReportSha256"] = "0" * 64
        _write_json(finalizer_check_path, finalizer_check)
        finalizer_check_sha = hashlib.sha256(finalizer_check_path.read_bytes()).hexdigest()

        readiness_path = root / paths["readinessReportPath"]
        readiness = json.loads(readiness_path.read_text(encoding="utf-8"))
        readiness["rows"][0]["frontierBundleEvidence"]["releaseCandidateEvidence"][
            "finalizerCheck"
        ]["sha256"] = finalizer_check_sha
        _write_json(readiness_path, readiness)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_finalizer_check_identity_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_finalizer_check_output_identity() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        paths = _browser_release_paths()

        finalizer_check_path = root / paths["finalizerCheckPath"]
        finalizer_check = json.loads(finalizer_check_path.read_text(encoding="utf-8"))
        finalizer_check["outputs"]["releaseArtifactBundle"]["sha256"] = "0" * 64
        _write_json(finalizer_check_path, finalizer_check)
        finalizer_check_sha = hashlib.sha256(finalizer_check_path.read_bytes()).hexdigest()

        readiness_path = root / paths["readinessReportPath"]
        readiness = json.loads(readiness_path.read_text(encoding="utf-8"))
        readiness["rows"][0]["frontierBundleEvidence"]["releaseCandidateEvidence"][
            "finalizerCheck"
        ]["sha256"] = finalizer_check_sha
        _write_json(readiness_path, readiness)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_finalizer_check_output_identity_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_finalizer_check_input_identity() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        paths = _browser_release_paths()

        finalizer_check_path = root / paths["finalizerCheckPath"]
        finalizer_check = json.loads(finalizer_check_path.read_text(encoding="utf-8"))
        finalizer_check["inputs"]["provenanceReport"]["sha256"] = "0" * 64
        _write_json(finalizer_check_path, finalizer_check)
        finalizer_check_sha = hashlib.sha256(finalizer_check_path.read_bytes()).hexdigest()

        readiness_path = root / paths["readinessReportPath"]
        readiness = json.loads(readiness_path.read_text(encoding="utf-8"))
        readiness["rows"][0]["frontierBundleEvidence"]["releaseCandidateEvidence"][
            "finalizerCheck"
        ]["sha256"] = finalizer_check_sha
        _write_json(readiness_path, readiness)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_finalizer_check_input_identity_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_finalizer_check_bindings() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        paths = _browser_release_paths()

        finalizer_check_path = root / paths["finalizerCheckPath"]
        finalizer_check = json.loads(finalizer_check_path.read_text(encoding="utf-8"))
        del finalizer_check["outputs"]
        del finalizer_check["inputs"]
        _write_json(finalizer_check_path, finalizer_check)
        finalizer_check_sha = hashlib.sha256(finalizer_check_path.read_bytes()).hexdigest()

        readiness_path = root / paths["readinessReportPath"]
        readiness = json.loads(readiness_path.read_text(encoding="utf-8"))
        readiness["rows"][0]["frontierBundleEvidence"]["releaseCandidateEvidence"][
            "finalizerCheck"
        ]["sha256"] = finalizer_check_sha
        _write_json(readiness_path, readiness)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_finalizer_check_output_identity_mismatch" in codes
    assert "browser_release_finalizer_check_input_identity_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_finalizer_output_identity() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        paths = _browser_release_paths()

        finalizer_path = root / paths["finalizerReportPath"]
        finalizer = json.loads(finalizer_path.read_text(encoding="utf-8"))
        finalizer["outputs"]["releaseArtifactBundle"]["sha256"] = "0" * 64
        _write_json(finalizer_path, finalizer)
        finalizer_sha = hashlib.sha256(finalizer_path.read_bytes()).hexdigest()

        finalizer_check_path = root / paths["finalizerCheckPath"]
        finalizer_check = json.loads(finalizer_check_path.read_text(encoding="utf-8"))
        finalizer_check["finalizerReportSha256"] = finalizer_sha
        _write_json(finalizer_check_path, finalizer_check)
        finalizer_check_sha = hashlib.sha256(finalizer_check_path.read_bytes()).hexdigest()

        readiness_path = root / paths["readinessReportPath"]
        readiness = json.loads(readiness_path.read_text(encoding="utf-8"))
        release_candidate = readiness["rows"][0]["frontierBundleEvidence"][
            "releaseCandidateEvidence"
        ]
        release_candidate["finalizerReport"]["sha256"] = finalizer_sha
        release_candidate["finalizerCheck"]["sha256"] = finalizer_check_sha
        _write_json(readiness_path, readiness)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_finalizer_output_identity_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_finalizer_input_identity() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        paths = _browser_release_paths()

        finalizer_path = root / paths["finalizerReportPath"]
        finalizer = json.loads(finalizer_path.read_text(encoding="utf-8"))
        finalizer["inputs"]["packageInputs"]["sha256"] = "0" * 64
        _write_json(finalizer_path, finalizer)
        finalizer_sha = hashlib.sha256(finalizer_path.read_bytes()).hexdigest()

        finalizer_check_path = root / paths["finalizerCheckPath"]
        finalizer_check = json.loads(finalizer_check_path.read_text(encoding="utf-8"))
        finalizer_check["finalizerReportSha256"] = finalizer_sha
        _write_json(finalizer_check_path, finalizer_check)
        finalizer_check_sha = hashlib.sha256(finalizer_check_path.read_bytes()).hexdigest()

        readiness_path = root / paths["readinessReportPath"]
        readiness = json.loads(readiness_path.read_text(encoding="utf-8"))
        release_candidate = readiness["rows"][0]["frontierBundleEvidence"][
            "releaseCandidateEvidence"
        ]
        release_candidate["finalizerReport"]["sha256"] = finalizer_sha
        release_candidate["finalizerCheck"]["sha256"] = finalizer_check_sha
        _write_json(readiness_path, readiness)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_finalizer_input_identity_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_finalizer_provenance_input_identity() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        paths = _browser_release_paths()

        finalizer_path = root / paths["finalizerReportPath"]
        finalizer = json.loads(finalizer_path.read_text(encoding="utf-8"))
        finalizer["inputs"]["provenanceReport"]["sha256"] = "0" * 64
        _write_json(finalizer_path, finalizer)
        finalizer_sha = hashlib.sha256(finalizer_path.read_bytes()).hexdigest()

        finalizer_check_path = root / paths["finalizerCheckPath"]
        finalizer_check = json.loads(finalizer_check_path.read_text(encoding="utf-8"))
        finalizer_check["finalizerReportSha256"] = finalizer_sha
        _write_json(finalizer_check_path, finalizer_check)
        finalizer_check_sha = hashlib.sha256(finalizer_check_path.read_bytes()).hexdigest()

        readiness_path = root / paths["readinessReportPath"]
        readiness = json.loads(readiness_path.read_text(encoding="utf-8"))
        release_candidate = readiness["rows"][0]["frontierBundleEvidence"][
            "releaseCandidateEvidence"
        ]
        release_candidate["finalizerReport"]["sha256"] = finalizer_sha
        release_candidate["finalizerCheck"]["sha256"] = finalizer_check_sha
        _write_json(readiness_path, readiness)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_finalizer_input_identity_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_finalizer_summary_claimability() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        paths = _browser_release_paths()

        finalizer_path = root / paths["finalizerReportPath"]
        finalizer = json.loads(finalizer_path.read_text(encoding="utf-8"))
        finalizer["summary"]["claimabilityStatus"] = "blocked"
        _write_json(finalizer_path, finalizer)
        _refresh_finalizer_dependent_hashes(root, paths)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_finalizer_summary_claimability_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_finalizer_summary_release_identity() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        paths = _browser_release_paths()

        finalizer_path = root / paths["finalizerReportPath"]
        finalizer = json.loads(finalizer_path.read_text(encoding="utf-8"))
        finalizer["summary"]["releaseBundleIdentitySha256"] = "0" * 64
        _write_json(finalizer_path, finalizer)
        _refresh_finalizer_dependent_hashes(root, paths)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_finalizer_summary_release_identity_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_clean_finalizer_report() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        paths = _browser_release_paths()

        finalizer_path = root / paths["finalizerReportPath"]
        finalizer = json.loads(finalizer_path.read_text(encoding="utf-8"))
        finalizer["failures"] = [
            {
                "code": "unit_finalizer_failure",
                "path": "finalizer",
                "message": "unit finalizer failure",
            }
        ]
        finalizer["summary"]["failureCount"] = 1
        _write_json(finalizer_path, finalizer)
        finalizer_sha = hashlib.sha256(finalizer_path.read_bytes()).hexdigest()

        finalizer_check_path = root / paths["finalizerCheckPath"]
        finalizer_check = json.loads(finalizer_check_path.read_text(encoding="utf-8"))
        finalizer_check["finalizerReportSha256"] = finalizer_sha
        _write_json(finalizer_check_path, finalizer_check)
        finalizer_check_sha = hashlib.sha256(finalizer_check_path.read_bytes()).hexdigest()

        readiness_path = root / paths["readinessReportPath"]
        readiness = json.loads(readiness_path.read_text(encoding="utf-8"))
        release_candidate = readiness["rows"][0]["frontierBundleEvidence"][
            "releaseCandidateEvidence"
        ]
        release_candidate["finalizerReport"]["sha256"] = finalizer_sha
        release_candidate["finalizerCheck"]["sha256"] = finalizer_check_sha
        _write_json(readiness_path, readiness)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_finalizer_has_failures" in codes
    assert "browser_release_finalizer_failure_count_nonzero" in codes


def test_browser_chromium_claim_indexed_release_requires_claimable_evidence() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root, claimable=False)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_runtime_frontier_not_claimable" in codes
    assert "browser_release_bundle_not_release_candidate" in codes
    assert "browser_release_package_inputs_not_candidate_eligible" in codes
    assert "browser_release_provenance_not_pass" in codes
    assert "browser_release_finalizer_check_status_not_pass" in codes
    assert "browser_release_readiness_not_claimable" in codes


def test_scaffolded_entry_requires_blocker_not_report_artifacts() -> None:
    schema = _schema()
    entry = {
        "id": "d3d12-unit",
        "surface": "native",
        "backend": "d3d12",
        "comparison": "doe-vs-dawn",
        "metricDirection": "status-only",
        "claimState": "scaffolded",
        "blocker": "Fresh Windows evidence is not present.",
    }

    result = gate.evaluate_index(_index(entry), schema, REPO_ROOT)

    assert result["ok"], result["failures"]
    assert result["summary"]["localReportCount"] == 0
    assert result["summary"]["localClaimCount"] == 0


def test_scaffolded_entry_without_blocker_fails_schema() -> None:
    schema = _schema()
    entry = {
        "id": "d3d12-unit",
        "surface": "native",
        "backend": "d3d12",
        "comparison": "doe-vs-dawn",
        "metricDirection": "status-only",
        "claimState": "scaffolded",
    }

    result = gate.evaluate_index(_index(entry), schema, REPO_ROOT)
    codes = {item["code"] for item in result["failures"]}

    assert "schema_validation" in codes


def test_duplicate_ids_and_parent_paths_fail() -> None:
    schema = _schema()
    entry = _entry()
    duplicate = copy.deepcopy(entry)
    duplicate["reportPath"] = "../bench/out/unit/compare.json"
    payload = _index(entry)
    payload["entries"].append(duplicate)

    result = gate.evaluate_index(payload, schema, REPO_ROOT)
    codes = {item["code"] for item in result["failures"]}

    assert "duplicate_id" in codes
    assert "unsafe_report_path" in codes


def test_local_artifacts_are_checked_when_present() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)

        result = gate.evaluate_index(_index(_entry()), schema, root)

    assert result["ok"], result["failures"]
    assert result["summary"]["localReportCount"] == 1
    assert result["summary"]["localClaimCount"] == 1


def test_local_claim_status_mismatch_fails() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root, claim_status="diagnostic")

        result = gate.evaluate_index(_index(_entry()), schema, root)

    codes = {item["code"] for item in result["failures"]}

    assert "claim_status_mismatch" in codes
    assert "claim_indexed_sidecar_not_passing" in codes
