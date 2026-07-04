#!/usr/bin/env python3
"""Tests for browser release artifact bundle checks."""

from __future__ import annotations

import json
import hashlib
import plistlib
import struct
import sys
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any

from bench.tools import check_browser_release_artifact_bundle as bundle_check
from bench.tools import build_browser_release_artifact_bundle as builder

REPO_ROOT = Path(__file__).resolve().parents[2]
BUNDLE_PATH = REPO_ROOT / "examples" / "browser-release-artifact-bundle.sample.json"

def _load() -> dict: return json.loads(BUNDLE_PATH.read_text(encoding="utf-8"))


def _write_file(path: Path, content: str | bytes) -> Path:
    if isinstance(content, bytes):
        path.write_bytes(content)
    else:
        path.write_text(content, encoding="utf-8")
    return path


DEFAULT_BROWSER_ARCHIVE_PATH = "Fawn.app/Contents/MacOS/Chromium"
DEFAULT_APP_METADATA_ARCHIVE_PATH = "Fawn.app/Contents/Info.plist"
DEFAULT_DOE_RUNTIME_ARCHIVE_PATH = "Fawn.app/Contents/Frameworks/libwebgpu_doe.so"
DEFAULT_DAWN_RUNTIME_ARCHIVE_PATH = "Fawn.app/Contents/Frameworks/libdawn_native.so"
DEFAULT_BROWSER_PRODUCT = {"productId": "fawn-doe", "displayName": "Fawn Doe", "version": "0.0.0-test", "channel": "diagnostic"}
CONCRETE_RELEASE_PROOF_STATUSES = {
    "tsirStatus": "available",
    "hostPlanStatus": "not_applicable",
    "cslStatus": "not_applicable",
}
PROOF_SURFACE_SAMPLE_REFERENCES = (
    "config/browser-capture-policy.json", "examples/browser-runtime-identity.selector.sample.json",
    "examples/browser-proof-page.sample.html", "examples/browser-proof-page-receipt.sample.json",
    "examples/browser-release-archive.sample.zip", "examples/browser-release-archive-manifest.sample.json",
    "examples/browser-public-download-receipt.sample.json",
    "examples/browser-gallery-compute.sample.html", "examples/browser-gallery-rendering.sample.html",
    "examples/browser-gallery-tensor.sample.html", "examples/browser-gallery-shader-edge.sample.html",
    "examples/browser-gallery-benchmark-trace.sample.html", "examples/browser-dawn-execution-receipt.sample.json",
    "examples/browser-doe-execution-receipt.sample.json", "examples/browser-smoke-report.sample.json",
    "examples/browser-rendering-execution-receipt.sample.json", "examples/browser-tensor-execution-receipt.sample.json",
    "examples/browser-shader-edge-execution-receipt.sample.json", "examples/browser-benchmark-trace-execution-receipt.sample.json",
    "browser/chromium/contracts/browser-benchmark-superset.contract.md",
    "browser/chromium/contracts/browser-local-ai-workloads.contract.md", "browser/chromium/contracts/browser-shader-links.contract.md",
)


def _macho_payload(arch: str = "arm64") -> bytes:
    cpu_type = {
        "arm64": 0x0100000C,
        "x64": 0x01000007,
    }[arch]
    return struct.pack("<IiiIIIII", 0xFEEDFACF, cpu_type, 0, 2, 0, 0, 0, 0)


def _elf_payload(arch: str = "x64") -> bytes:
    machine = {
        "x64": 0x3E,
        "arm64": 0xB7,
    }[arch]
    return b"\x7fELF\x02\x01" + b"\0" * 12 + struct.pack("<H", machine) + b"\0" * 14


def _write_zip(
    path: Path,
    *,
    member_path: str = DEFAULT_BROWSER_ARCHIVE_PATH,
    member_content: str | bytes | None = None,
    browser_executable: bool = True,
    app_metadata_member_path: str = DEFAULT_APP_METADATA_ARCHIVE_PATH,
    app_display_name: str = "Fawn Doe",
    doe_runtime_member_path: str = DEFAULT_DOE_RUNTIME_ARCHIVE_PATH,
    doe_runtime_member_content: str | bytes | None = None,
    dawn_runtime_member_path: str = DEFAULT_DAWN_RUNTIME_ARCHIVE_PATH,
    dawn_runtime_member_content: str | bytes | None = None,
) -> Path:
    if member_content is None:
        member_content = _macho_payload()
    if doe_runtime_member_content is None:
        doe_runtime_member_content = _macho_payload()
    if dawn_runtime_member_content is None:
        dawn_runtime_member_content = _macho_payload()
    info = zipfile.ZipInfo("README.txt", (1980, 1, 1, 0, 0, 0))
    info.compress_type = zipfile.ZIP_STORED
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr(info, "browser release archive fixture\n")
        binary_info = zipfile.ZipInfo(member_path, (1980, 1, 1, 0, 0, 0))
        binary_info.compress_type = zipfile.ZIP_STORED
        binary_info.external_attr = (0o755 if browser_executable else 0o644) << 16
        archive.writestr(binary_info, member_content)
        plist_info = zipfile.ZipInfo(app_metadata_member_path, (1980, 1, 1, 0, 0, 0))
        plist_info.compress_type = zipfile.ZIP_STORED
        archive.writestr(plist_info, plistlib.dumps({
            "CFBundleDisplayName": app_display_name,
            "CFBundleExecutable": PurePosixPath(member_path).name,
            "CFBundleIdentifier": "dev.doe.fawn-doe",
            "CFBundleName": app_display_name,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "0.0.0-test",
            "CFBundleVersion": "0.0.0-test",
        }))
        doe_info = zipfile.ZipInfo(doe_runtime_member_path, (1980, 1, 1, 0, 0, 0))
        doe_info.compress_type = zipfile.ZIP_STORED
        archive.writestr(doe_info, doe_runtime_member_content)
        dawn_info = zipfile.ZipInfo(dawn_runtime_member_path, (1980, 1, 1, 0, 0, 0))
        dawn_info.compress_type = zipfile.ZIP_STORED
        archive.writestr(dawn_info, dawn_runtime_member_content)
    return path


def _copy_repo_file(root: Path, relative_path: str) -> Path:
    out_path = root / relative_path
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_bytes((REPO_ROOT / relative_path).read_bytes())
    return out_path


def _release_provenance(
    release_archive: Path,
    release_archive_manifest: Path,
    public_download_receipt: Path,
    browser_product: dict[str, str],
) -> dict[str, Any]:
    return {
        "browserProduct": browser_product,
        "platform": {"os": "macos", "arch": "arm64", "packageFormat": "zip"},
        "releaseArchive": {
            "path": builder.repo_relative(release_archive),
            "sha256": builder.sha256_file(release_archive),
            "kind": "browser_release_archive",
            "downloadUrl": "https://downloads.doe.dev/Fawn-Doe-macos-arm64.zip",
        },
        "releaseArchiveManifest": {
            "path": builder.repo_relative(release_archive_manifest),
            "sha256": builder.sha256_file(release_archive_manifest),
            "kind": "browser_release_archive_manifest",
        },
        "publicDownloadReceipt": {
            "path": builder.repo_relative(public_download_receipt),
            "sha256": builder.sha256_file(public_download_receipt),
            "kind": "browser_public_download_receipt",
        },
        "browserExecutableArchivePath": DEFAULT_BROWSER_ARCHIVE_PATH,
        "browserAppMetadataArchivePath": DEFAULT_APP_METADATA_ARCHIVE_PATH,
        "doeRuntimeArchivePath": DEFAULT_DOE_RUNTIME_ARCHIVE_PATH,
        "dawnFallbackRuntimeArchivePath": DEFAULT_DAWN_RUNTIME_ARCHIVE_PATH,
    }


def _write_proof_surface_fixture(
    root: Path,
    release_archive: Path | None = None,
    release_archive_manifest: Path | None = None,
    public_download_receipt: Path | None = None,
    browser_product: dict[str, str] | None = None,
    browser_binary: Path | None = None,
    doe_runtime: Path | None = None,
    dawn_fallback_runtime: Path | None = None,
    shader_compiler: Path | None = None,
) -> Path:
    for relative_path in PROOF_SURFACE_SAMPLE_REFERENCES:
        _copy_repo_file(root, relative_path)
    proof_surface_path = _copy_repo_file(root, "examples/browser-published-proof-surface.sample.json")
    payload = json.loads(proof_surface_path.read_text(encoding="utf-8"))
    if (
        release_archive is not None
        and release_archive_manifest is not None
        and public_download_receipt is not None
        and browser_product is not None
    ):
        provenance = _release_provenance(
            release_archive,
            release_archive_manifest,
            public_download_receipt,
            browser_product,
        )
        payload["proofPage"]["releaseProvenance"] = provenance
        proof_page_path = root / payload["proofPage"]["artifact"]["path"]
        proof_page_text = proof_page_path.read_text(encoding="utf-8")
        if browser_product["channel"] in {"release_candidate", "release"}:
            diagnostics = payload["proofPage"]["diagnostics"]
            for field, value in CONCRETE_RELEASE_PROOF_STATUSES.items():
                old_value = diagnostics.get(field)
                diagnostics[field] = value
                if isinstance(old_value, str) and old_value in proof_page_text:
                    proof_page_text = proof_page_text.replace(old_value, value, 1)
                elif value not in proof_page_text:
                    proof_page_text += f"<p>{value}</p>\n"
        proof_page_path.write_text(
            proof_page_text
            + "\n".join(f"<p>{fragment}</p>" for fragment in (
                browser_product["version"], browser_product["channel"],
                builder.repo_relative(release_archive), provenance["releaseArchive"]["sha256"],
                provenance["releaseArchive"]["downloadUrl"],
                builder.repo_relative(release_archive_manifest), provenance["releaseArchiveManifest"]["sha256"],
                builder.repo_relative(public_download_receipt), provenance["publicDownloadReceipt"]["sha256"],
                provenance["browserExecutableArchivePath"],
                provenance["browserAppMetadataArchivePath"],
                provenance["doeRuntimeArchivePath"],
                provenance["dawnFallbackRuntimeArchivePath"],
            ))
            + "\n",
            encoding="utf-8",
        )
        payload["proofPage"]["artifact"]["sha256"] = builder.sha256_file(proof_page_path)
        receipt_path = root / payload["proofPage"]["diagnosticReceipt"]["path"]
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["releaseProvenance"] = provenance
        receipt["diagnostics"] = payload["proofPage"]["diagnostics"]
        receipt["contentSha256"] = payload["proofPage"]["artifact"]["sha256"]
        receipt["contentLengthBytes"] = proof_page_path.stat().st_size
        receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
        payload["proofPage"]["diagnosticReceipt"]["sha256"] = builder.sha256_file(receipt_path)
    if shader_compiler is not None:
        proof_page = payload["proofPage"]
        diagnostics = proof_page["diagnostics"]
        old_compiler_path = diagnostics.get("compilerPath")
        diagnostics["compilerPath"] = builder.repo_relative(shader_compiler)
        proof_page_path = root / proof_page["artifact"]["path"]
        proof_page_text = proof_page_path.read_text(encoding="utf-8")
        if isinstance(old_compiler_path, str) and old_compiler_path in proof_page_text:
            proof_page_text = proof_page_text.replace(old_compiler_path, diagnostics["compilerPath"])
        else:
            proof_page_text += f"<p>{diagnostics['compilerPath']}</p>\n"
        proof_page_path.write_text(proof_page_text, encoding="utf-8")
        proof_page["artifact"]["sha256"] = builder.sha256_file(proof_page_path)
        receipt_path = root / proof_page["diagnosticReceipt"]["path"]
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["diagnostics"] = diagnostics
        receipt["contentSha256"] = proof_page["artifact"]["sha256"]
        receipt["contentLengthBytes"] = proof_page_path.stat().st_size
        receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
        proof_page["diagnosticReceipt"]["sha256"] = builder.sha256_file(receipt_path)
    if browser_binary is not None and doe_runtime is not None and dawn_fallback_runtime is not None:
        runtime_identity_path = root / payload["runtimeIdentityPath"]
        runtime_identity = json.loads(runtime_identity_path.read_text(encoding="utf-8"))
        artifact_identity = {
            "browserExecutablePath": builder.repo_relative(browser_binary),
            "browserExecutableSha256": builder.sha256_file(browser_binary),
            "dawnRuntimePath": builder.repo_relative(dawn_fallback_runtime),
            "dawnRuntimeSha256": builder.sha256_file(dawn_fallback_runtime),
            "doeLibPath": builder.repo_relative(doe_runtime),
            "doeLibSha256": builder.sha256_file(doe_runtime),
        }
        runtime_identity.setdefault("provider", {})["artifactIdentity"] = artifact_identity
        runtime_selection = runtime_identity.setdefault("runtimeSelection", {})
        runtime_selection["artifactIdentity"] = artifact_identity
        runtime_identity_path.write_text(json.dumps(runtime_identity, indent=2) + "\n", encoding="utf-8")
    for row in payload["galleryPages"]:
        row["url"] = f"https://gallery.doe.dev/doe/{row['category']}.html"
        receipt_path = root / f"examples/browser-public-gallery-{row['category']}-receipt.json"
        gallery_path = root / row["artifact"]["path"]
        receipt = {
            "schemaVersion": 1,
            "artifactKind": "browser_public_gallery_receipt",
            "receiptId": f"browser-public-gallery-{row['category']}",
            "category": row["category"],
            "url": row["url"],
            "method": "GET",
            "statusCode": 200,
            "contentSha256": row["artifact"]["sha256"],
            "contentLengthBytes": gallery_path.stat().st_size,
            "galleryArtifactPath": row["artifact"]["path"],
            "workloadContractPath": row["workloadContractPath"],
            "workloadIds": row["workloadIds"],
            "receiptIds": row["receiptIds"],
            "receiptArtifactPaths": [
                artifact["path"]
                for artifact in row["receiptArtifacts"]
            ],
            "observedAt": "2026-06-30T00:00:00Z",
        }
        receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
        row["publicReceipt"] = {
            "path": str(receipt_path.relative_to(root)),
            "sha256": builder.sha256_file(receipt_path),
            "kind": "browser_public_gallery_receipt",
        }
    proof_surface_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return proof_surface_path


def _write_proof_surface_check_fixture(
    path: Path,
    proof_surface: Path,
    *,
    status: str = "pass",
) -> Path:
    failures = [] if status == "pass" else [
        {
            "code": "invalid_gallery_page_url",
            "path": "galleryPages[0].url",
            "message": "release proof gallery page URL must be public HTTPS",
        }
    ]
    payload = {
        "schemaVersion": 1,
        "artifactKind": "browser_published_proof_surface_check",
        "surfacePath": builder.repo_relative(proof_surface),
        "surfaceSha256": builder.sha256_file(proof_surface),
        "verifyFilesRootProvided": True,
        "requirePublicUrls": True,
        "status": status,
        "failures": failures,
    }
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return path


def _write_public_download_receipt(
    path: Path,
    release_archive: Path,
    release_archive_manifest: Path,
    browser_product: dict[str, str],
) -> Path:
    payload = {
        "schemaVersion": 1,
        "artifactKind": "browser_public_download_receipt",
        "receiptId": "test-browser-public-download",
        "url": "https://downloads.doe.dev/Fawn-Doe-macos-arm64.zip",
        "method": "GET",
        "statusCode": 200,
        "contentSha256": builder.sha256_file(release_archive),
        "contentLengthBytes": release_archive.stat().st_size,
        "releaseArchivePath": builder.repo_relative(release_archive),
        "releaseArchiveManifestPath": builder.repo_relative(release_archive_manifest),
        "releaseArchiveManifestSha256": builder.sha256_file(release_archive_manifest),
        "browserProduct": browser_product,
        "platform": {"os": "macos", "arch": "arm64", "packageFormat": "zip"},
        "browserExecutableArchivePath": DEFAULT_BROWSER_ARCHIVE_PATH,
        "browserAppMetadataArchivePath": DEFAULT_APP_METADATA_ARCHIVE_PATH,
        "doeRuntimeArchivePath": DEFAULT_DOE_RUNTIME_ARCHIVE_PATH,
        "dawnFallbackRuntimeArchivePath": DEFAULT_DAWN_RUNTIME_ARCHIVE_PATH,
        "observedAt": "2026-06-30T00:00:00Z",
    }
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return path


def _write_release_archive_manifest(
    path: Path,
    release_archive: Path,
    browser_product: dict[str, str],
    *,
    source_package_inputs: Path | None = None,
) -> Path:
    source_paths: dict[str, str] = {}
    if source_package_inputs is not None:
        package_inputs = json.loads(source_package_inputs.read_text(encoding="utf-8"))
        inputs = package_inputs.get("inputs")
        if isinstance(inputs, dict):
            for role in ("browserExecutable", "appMetadata", "doeRuntime", "dawnFallbackRuntime"):
                row = inputs.get(role)
                if not isinstance(row, dict) or row.get("generated") is True:
                    continue
                source_path = row.get("path")
                if isinstance(source_path, str) and source_path:
                    source_paths[role] = source_path

    with zipfile.ZipFile(release_archive) as archive:
        def member(name: str, role: str | None = None) -> dict[str, Any]:
            info = archive.getinfo(name); data = archive.read(name); mode = (info.external_attr >> 16) & 0o777
            payload = {"archivePath": name, "sha256": hashlib.sha256(data).hexdigest(), "byteLength": len(data), "executable": bool(mode & 0o100)}
            if role is not None and role in source_paths:
                payload["sourcePath"] = source_paths[role]
            return payload
        names = sorted(info.filename for info in archive.infolist() if info.filename.startswith("Fawn.app/") and not info.is_dir())
        member_roles = {
            DEFAULT_BROWSER_ARCHIVE_PATH: "browserExecutable",
            DEFAULT_APP_METADATA_ARCHIVE_PATH: "appMetadata",
            DEFAULT_DOE_RUNTIME_ARCHIVE_PATH: "doeRuntime",
            DEFAULT_DAWN_RUNTIME_ARCHIVE_PATH: "dawnFallbackRuntime",
        }
        payload = {"schemaVersion": 1, "artifactKind": "browser_release_archive_manifest", "archive": {"path": builder.repo_relative(release_archive), "sha256": builder.sha256_file(release_archive), "byteLength": release_archive.stat().st_size, "kind": "browser_release_archive"}, "browserProduct": browser_product, "platform": {"os": "macos", "arch": "arm64", "packageFormat": "zip"}, "appBundleName": "Fawn.app", "members": {"browserExecutable": member(DEFAULT_BROWSER_ARCHIVE_PATH, "browserExecutable"), "appMetadata": member(DEFAULT_APP_METADATA_ARCHIVE_PATH, "appMetadata"), "doeRuntime": member(DEFAULT_DOE_RUNTIME_ARCHIVE_PATH, "doeRuntime"), "dawnFallbackRuntime": member(DEFAULT_DAWN_RUNTIME_ARCHIVE_PATH, "dawnFallbackRuntime")}, "archiveMembers": [member(name, member_roles.get(name)) for name in names]}
    if source_package_inputs is not None:
        payload["sourcePackageInputs"] = {
            "path": builder.repo_relative(source_package_inputs),
            "sha256": builder.sha256_file(source_package_inputs),
            "kind": "browser_release_package_inputs_check",
        }
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return path


def _write_release_package_inputs(
    path: Path,
    release_archive_manifest: Path,
    browser_binary: Path,
    doe_runtime: Path,
    dawn_fallback_runtime: Path,
    shader_compiler: Path,
) -> Path:
    manifest = json.loads(release_archive_manifest.read_text(encoding="utf-8"))

    def row(
        role: str,
        kind: str,
        source: Path,
        *,
        archive_path: str | None = None,
    ) -> dict[str, Any]:
        payload = {
            "kind": kind,
            "path": builder.repo_relative(source),
            "exists": True,
            "generated": False,
            "sha256": builder.sha256_file(source),
            "byteLength": source.stat().st_size,
            "executable": role == "browserExecutable" or source.name == "doe-zig-runtime",
        }
        if role in {"browserExecutable", "doeRuntime", "dawnFallbackRuntime", "shaderCompiler"}:
            payload["detectedFormat"] = "macho"
            payload["detectedArchitectures"] = ["arm64"]
        if archive_path is not None:
            payload["archivePath"] = archive_path
        return payload

    payload = {
        "schemaVersion": 1,
        "artifactKind": "browser_release_package_inputs_check",
        "packageDir": {"path": "Fawn.app", "exists": True},
        "packageRootName": manifest["appBundleName"],
        "browserProduct": manifest["browserProduct"],
        "platform": manifest["platform"],
        "evidenceMode": "release_candidate",
        "releaseCandidateEligible": True,
        "releaseCandidateBlockers": [],
        "inputs": {
            "browserExecutable": row(
                "browserExecutable",
                "browser_binary",
                browser_binary,
                archive_path=manifest["members"]["browserExecutable"]["archivePath"],
            ),
            "appMetadata": {
                "kind": "browser_app_metadata",
                "path": "Fawn.app/Contents/Info.plist",
                "archivePath": manifest["members"]["appMetadata"]["archivePath"],
                "exists": True,
                "generated": False,
                "sha256": manifest["members"]["appMetadata"]["sha256"],
                "byteLength": manifest["members"]["appMetadata"]["byteLength"],
                "executable": manifest["members"]["appMetadata"]["executable"],
            },
            "doeRuntime": row(
                "doeRuntime",
                "doe_runtime",
                doe_runtime,
                archive_path=manifest["members"]["doeRuntime"]["archivePath"],
            ),
            "dawnFallbackRuntime": row(
                "dawnFallbackRuntime",
                "dawn_fallback_runtime",
                dawn_fallback_runtime,
                archive_path=manifest["members"]["dawnFallbackRuntime"]["archivePath"],
            ),
            "shaderCompiler": row("shaderCompiler", "shader_compiler", shader_compiler),
        },
        "overwrittenPackageMembers": [],
        "status": "pass",
        "failures": [],
        "summary": {
            "packageable": True,
            "metadataSource": "package",
            "requiredArchiveMemberCount": 4,
            "runtimeReplacementCount": 2,
        },
    }
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return path

def _write_runtime_frontier_bundle(path: Path, release_status: str, promotion_receipt: Path) -> Path:
    payload = {"schemaVersion": 1, "artifactKind": "browser_runtime_frontier_bundle", "status": "pass", "claimabilityStatus": "claimable", "claimBlockers": [], "claimBlockerSummary": [], "failures": [], "summary": {"claimBlockerCount": 0, "failureCount": 0}, "componentReceipts": {"runtimeIdentity": {"path": "examples/browser-runtime-identity.selector.sample.json", "status": "pass"}, "claimPromotionReceipt": {"path": builder.repo_relative(promotion_receipt), "status": "pass", "promotionStatus": "promotable"}, "releaseArtifactBundle": {"path": "release-bundle.json", "status": "pass", "artifactKind": "browser_release_artifact_bundle", "bundleId": "test-bundle", "releaseStatus": release_status, "releaseBundleIdentitySha256": "0" * 64, "artifactVerification": {"verified": True}}}}
    path.write_text(json.dumps(payload) + "\n", encoding="utf-8")
    return path


def _sync_runtime_frontier_bundle_release_summary(
    release_bundle: dict[str, Any],
    frontier_path: Path,
) -> None:
    frontier = json.loads(frontier_path.read_text(encoding="utf-8"))
    release_summary = frontier["componentReceipts"]["releaseArtifactBundle"]
    release_summary["artifactKind"] = release_bundle["artifactKind"]
    release_summary["bundleId"] = release_bundle["bundleId"]
    release_summary["releaseStatus"] = release_bundle["releaseStatus"]
    release_summary["releaseBundleIdentitySha256"] = (
        bundle_check.release_bundle_identity_sha256(release_bundle)
    )
    frontier_path.write_text(json.dumps(frontier, indent=2) + "\n", encoding="utf-8")
    release_bundle["runtimeFrontierBundle"]["sha256"] = builder.sha256_file(
        frontier_path
    )


def _mutate_package_inputs_fixture(
    payload: dict[str, Any],
    root: Path,
    mutate: Any,
) -> dict[str, Any]:
    package_inputs_path = root / payload["packageInputs"]["path"]
    package_inputs = json.loads(package_inputs_path.read_text(encoding="utf-8"))
    mutate(package_inputs)
    package_inputs_path.write_text(json.dumps(package_inputs, indent=2) + "\n", encoding="utf-8")
    payload["packageInputs"]["sha256"] = builder.sha256_file(package_inputs_path)

    manifest_path = root / payload["releaseArchiveManifest"]["path"]
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    source_package_inputs = manifest.get("sourcePackageInputs")
    if isinstance(source_package_inputs, dict):
        source_package_inputs["sha256"] = payload["packageInputs"]["sha256"]
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        payload["releaseArchiveManifest"]["sha256"] = builder.sha256_file(manifest_path)
    return package_inputs


def _write_chromium_source_checkout_report(
    path: Path,
    *,
    require_runtime_selector: bool = True,
    status: str = "pass",
) -> Path:
    payload = {
        "schemaVersion": 1,
        "artifactKind": "chromium_source_checkout_check",
        "sourceRoot": "browser/chromium/src",
        "requireReady": True,
        "requireRuntimeSelector": require_runtime_selector,
        "status": status,
        "checks": [
            {
                "checkId": "source_root",
                "status": "pass" if status == "pass" else "fail",
                "required": True,
                "path": "browser/chromium/src",
                "message": "Chromium source root exists",
            }
        ],
        "missingRequired": [] if status == "pass" else ["source_root"],
    }
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return path


def _write_browser_launch_receipt(
    path: Path,
    release_archive: Path,
    release_archive_manifest: Path,
    proof_surface: Path,
    browser_product: dict[str, str],
    *,
    webgpu_available: bool = True,
    active_backend: str = "webgpu-doe",
) -> Path:
    payload = {
        "schemaVersion": 1,
        "artifactKind": "browser_release_launch_receipt",
        "receiptId": "test-browser-release-launch",
        "observedAt": "2026-06-30T00:00:00Z",
        "launchSource": "release_archive",
        "browserProduct": browser_product,
        "platform": {"os": "macos", "arch": "arm64", "packageFormat": "zip"},
        "releaseArchive": {
            "path": builder.repo_relative(release_archive),
            "sha256": builder.sha256_file(release_archive),
            "kind": "browser_release_archive",
            "downloadUrl": "https://downloads.doe.dev/Fawn-Doe-macos-arm64.zip",
        },
        "releaseArchiveManifest": {
            "path": builder.repo_relative(release_archive_manifest),
            "sha256": builder.sha256_file(release_archive_manifest),
            "kind": "browser_release_archive_manifest",
        },
        "proofSurface": {
            "path": builder.repo_relative(proof_surface),
            "sha256": builder.sha256_file(proof_surface),
            "kind": "browser_published_proof_surface",
        },
        "browserExecutableArchivePath": DEFAULT_BROWSER_ARCHIVE_PATH,
        "browserAppMetadataArchivePath": DEFAULT_APP_METADATA_ARCHIVE_PATH,
        "doeRuntimeArchivePath": DEFAULT_DOE_RUNTIME_ARCHIVE_PATH,
        "dawnFallbackRuntimeArchivePath": DEFAULT_DAWN_RUNTIME_ARCHIVE_PATH,
        "runtimeMode": "doe",
        "activeRuntime": "doe",
        "activeBackend": active_backend,
        "hiddenFallbackAllowed": False,
        "hiddenFallbackUsed": False,
        "webgpuAvailable": webgpu_available,
        "proofPage": {
            "url": "about:doe",
            "loaded": True,
            "artifactPath": "examples/browser-proof-page.sample.html",
            "receiptId": "browser-proof-page-sample",
        },
        "galleryPage": {
            "url": "https://gallery.doe.dev/doe/compute.html",
            "loaded": True,
            "category": "compute",
            "artifactPath": "examples/browser-gallery-compute.sample.html",
            "receiptId": "browser-public-gallery-compute",
        },
        "comparisonReceipt": {
            "comparisonId": "browser-smoke-compute-dawn-vs-doe",
            "workloadId": "browser-smoke-compute",
            "pageArtifactPath": "examples/browser-gallery-compute.sample.html",
            "loaded": True,
            "executionScope": "same_page",
            "modes": ["dawn", "doe"],
            "emitsSideBySideReceipts": True,
            "comparisonArtifactPath": "examples/browser-smoke-report.sample.json",
            "dawnReceiptId": "browser-smoke-compute-dawn",
            "doeReceiptId": "browser-smoke-compute-doe",
        },
        "observedReceiptIds": [
            "browser-proof-page-sample",
            "browser-public-gallery-compute",
            "browser-smoke-compute-dawn",
            "browser-smoke-compute-doe",
        ],
    }
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return path


def _write_promotion_receipt(path: Path, claim_report: Path) -> Path:
    payload = {
        "schemaVersion": 1,
        "artifactKind": "browser_claim_promotion_receipt",
        "receiptId": "test-browser-claim-promotion",
        "claimPolicyPath": "config/browser-claim-policy.json",
        "promotionStatus": "promotable",
        "artifacts": [
            {
                "path": str(claim_report),
                "sha256": builder.sha256_file(claim_report),
                "mode": "doe",
                "forcedDoe": True,
                "hiddenFallbackUsed": False,
                "claimPolicyPassed": True,
            }
        ],
        "hiddenFallbackCheck": {
            "required": True,
            "passed": True,
        },
        "failureCodes": [],
    }
    path.write_text(json.dumps(payload) + "\n", encoding="utf-8")
    return path


def _write_diagnostic_promotion_receipt(path: Path, claim_report: Path) -> Path:
    payload = {
        "schemaVersion": 1,
        "artifactKind": "browser_claim_promotion_receipt",
        "receiptId": "test-browser-claim-promotion-diagnostic",
        "claimPolicyPath": "config/browser-claim-policy.json",
        "promotionStatus": "diagnostic",
        "artifacts": [
            {
                "path": str(claim_report),
                "sha256": builder.sha256_file(claim_report),
                "mode": "doe",
                "forcedDoe": False,
                "hiddenFallbackUsed": False,
                "claimPolicyPassed": False,
            }
        ],
        "hiddenFallbackCheck": {
            "required": True,
            "passed": False,
        },
        "failureCodes": [],
    }
    path.write_text(json.dumps(payload) + "\n", encoding="utf-8")
    return path


def _release_bundle_inputs(tmp_path: Path, *, release_status: str = "diagnostic") -> dict[str, Any]:
    claim_report = tmp_path / "browser-claim-report.json"
    claim_report.write_bytes((REPO_ROOT / "examples/browser-claim-report.sample.json").read_bytes())
    release_archive = _write_zip(tmp_path / "Fawn-Doe-macos-arm64.zip")
    browser_product = {**DEFAULT_BROWSER_PRODUCT, "channel": release_status}
    release_archive_manifest = _write_release_archive_manifest(
        tmp_path / "browser-release-archive-manifest.json",
        release_archive,
        browser_product,
    )
    browser_binary = _write_file(tmp_path / "chrome", _macho_payload())
    doe_runtime = _write_file(tmp_path / "libwebgpu_doe.dylib", _macho_payload())
    dawn_fallback_runtime = _write_file(tmp_path / "libdawn_native.so", _macho_payload())
    shader_compiler = _write_file(tmp_path / "doe-zig-runtime", _macho_payload())
    package_inputs = None
    if release_status == "release_candidate":
        package_inputs = _write_release_package_inputs(
            tmp_path / "browser-release-package-inputs.json",
            release_archive_manifest,
            browser_binary,
            doe_runtime,
            dawn_fallback_runtime,
            shader_compiler,
        )
        release_archive_manifest = _write_release_archive_manifest(
            release_archive_manifest,
            release_archive,
            browser_product,
            source_package_inputs=package_inputs,
        )
    public_download_receipt = _write_public_download_receipt(
        tmp_path / "browser-public-download-receipt.json",
        release_archive,
        release_archive_manifest,
        browser_product,
    )
    promotion_receipt = _write_promotion_receipt(tmp_path / "browser-claim-report.promotion-receipt.json", claim_report)
    proof_surface = _write_proof_surface_fixture(
        tmp_path,
        release_archive,
        release_archive_manifest,
        public_download_receipt,
        browser_product,
        browser_binary,
        doe_runtime,
        dawn_fallback_runtime,
        shader_compiler,
    )
    proof_surface_check = _write_proof_surface_check_fixture(
        tmp_path / "browser-published-proof-surface-check.json",
        proof_surface,
    )
    return {
        "release_archive": release_archive,
        "release_archive_manifest": release_archive_manifest,
        "package_inputs": package_inputs,
        "public_download_receipt": public_download_receipt,
        "browser_binary_archive_path": DEFAULT_BROWSER_ARCHIVE_PATH,
        "browser_binary": browser_binary,
        "doe_runtime": doe_runtime,
        "dawn_fallback_runtime": dawn_fallback_runtime,
        "shader_compiler": shader_compiler,
        "chromium_source_checkout": _write_chromium_source_checkout_report(
            tmp_path / "chromium-source-checkout-check.json"
        ),
        "browser_launch_receipt": _write_browser_launch_receipt(
            tmp_path / "browser-release-launch-receipt.json",
            release_archive,
            release_archive_manifest,
            proof_surface,
            browser_product,
        ),
        "runtime_frontier_bundle": _write_runtime_frontier_bundle(tmp_path / "browser-runtime-frontier-bundle.json", release_status, promotion_receipt),
        "proof_surface": proof_surface,
        "proof_surface_check": proof_surface_check,
        "contracts": [
            _write_file(tmp_path / "browser-claim-methodology.contract.md", "contract")
        ],
        "claim_reports": [claim_report],
        "promotion_receipts": [promotion_receipt],
        "policies": [
            _write_file(tmp_path / "browser-runtime-selector-policy.json", "{}\n"),
            _write_file(tmp_path / "chromium-fork-maintenance-policy.json", "{}\n"),
            _write_file(tmp_path / "chromium-patch-manifest.json", "{}\n"),
            _write_file(tmp_path / "browser-claim-policy.json", "{}\n"),
            _write_file(tmp_path / "browser-capture-policy.json", "{}\n"),
            _write_file(tmp_path / "browser-artifact-identity-coverage.json", "{}\n"),
            _write_file(tmp_path / "browser-unsupported-reason-taxonomy.json", "{}\n"),
        ],
    }


def _build_test_bundle(tmp_path: Path, *, release_status: str) -> dict:
    paths = _release_bundle_inputs(tmp_path, release_status=release_status)
    browser_product = {**DEFAULT_BROWSER_PRODUCT, "channel": release_status}
    payload = builder.build_bundle(
        bundle_id="test-bundle",
        release_status=release_status,
        release_archive=paths["release_archive"],
        release_archive_url="https://downloads.doe.dev/Fawn-Doe-macos-arm64.zip",
        release_archive_manifest=paths["release_archive_manifest"],
        public_download_receipt=paths["public_download_receipt"],
        package_inputs=paths["package_inputs"],
        browser_product=browser_product,
        platform={"os": "macos", "arch": "arm64", "packageFormat": "zip"},
        browser_binary_archive_path=paths["browser_binary_archive_path"],
        browser_app_metadata_archive_path=DEFAULT_APP_METADATA_ARCHIVE_PATH,
        doe_runtime_archive_path=DEFAULT_DOE_RUNTIME_ARCHIVE_PATH,
        dawn_fallback_runtime_archive_path=DEFAULT_DAWN_RUNTIME_ARCHIVE_PATH,
        browser_binary=paths["browser_binary"],
        doe_runtime=paths["doe_runtime"],
        dawn_fallback_runtime=paths["dawn_fallback_runtime"],
        shader_compiler=paths["shader_compiler"],
        proof_surface=paths["proof_surface"],
        proof_surface_check=paths["proof_surface_check"],
        chromium_source_checkout=paths["chromium_source_checkout"],
        browser_launch_receipt=paths["browser_launch_receipt"],
        runtime_frontier_bundle=paths["runtime_frontier_bundle"],
        contracts=paths["contracts"],
        claim_reports=paths["claim_reports"],
        promotion_receipts=paths["promotion_receipts"],
        policies=paths["policies"],
    )
    _sync_runtime_frontier_bundle_release_summary(
        payload,
        paths["runtime_frontier_bundle"],
    )
    return payload


def test_browser_release_artifact_bundle_passes_check() -> None:
    assert bundle_check.check_bundle(_load()) == []


def test_browser_release_artifact_bundle_requires_release_artifact_kind() -> None:
    payload = _load()
    payload["artifactKind"] = "browser_release_bundle"

    assert {
        "code": "invalid_release_bundle_artifact_kind",
        "path": "artifactKind",
        "message": (
            "browser release artifact bundle artifactKind must be "
            "browser_release_artifact_bundle"
        ),
    } in bundle_check.check_bundle(payload)


def test_browser_release_artifact_bundle_requires_runtime_hash() -> None:
    payload = _load()
    payload["doeRuntime"]["sha256"] = ""

    assert {
        "code": "missing_artifact_hash",
        "path": "doeRuntime.sha256",
        "message": "artifact sha256 is required",
    } in bundle_check.check_bundle(payload)


def test_browser_release_artifact_bundle_requires_claim_report() -> None:
    payload = _load()
    payload["claimReports"] = []

    assert {
        "code": "missing_claim_report_kind",
        "path": "claimReports",
        "message": "missing claim report artifact kind browser_claim_report",
    } in bundle_check.check_bundle(payload)


def test_browser_release_artifact_bundle_requires_promotion_receipt() -> None:
    payload = _load()
    payload["promotionReceipts"] = []

    assert {
        "code": "missing_promotion_receipt_kind",
        "path": "promotionReceipts",
        "message": "missing promotion receipt artifact kind browser_claim_promotion_receipt",
    } in bundle_check.check_bundle(payload)


def test_browser_release_artifact_bundle_defaults_include_browser_contract_surface() -> None:
    contract_paths = {
        path.relative_to(REPO_ROOT).as_posix()
        for path in builder.defaulted_paths([], builder.DEFAULT_CONTRACTS)
    }

    assert "browser/chromium/contracts/browser-benchmark-superset.contract.md" in contract_paths
    assert "browser/chromium/contracts/browser-gpu-flight-recorder.contract.md" in contract_paths
    assert "browser/chromium/contracts/browser-shader-links.contract.md" in contract_paths
    assert "browser/chromium/contracts/browser-pipeline-cache-receipts.contract.md" in contract_paths
    assert "browser/chromium/contracts/browser-published-release.contract.md" in contract_paths
    assert "browser/chromium/contracts/browser-cts-subset.contract.md" in contract_paths


def test_browser_release_artifact_bundle_defaults_include_chromium_patch_manifest() -> None:
    policy_paths = {
        path.relative_to(REPO_ROOT).as_posix()
        for path in builder.defaulted_paths([], builder.DEFAULT_POLICIES)
    }

    assert "config/chromium-fork-maintenance-policy.json" in policy_paths
    assert "config/chromium-patch-manifest.json" in policy_paths
    assert "config/browser-artifact-identity-coverage.json" in policy_paths
    assert "config/browser-unsupported-reason-taxonomy.json" in policy_paths


def test_browser_release_artifact_bundle_requires_claim_policy() -> None:
    payload = _load()
    payload["policies"] = [
        row
        for row in payload["policies"]
        if row["kind"] != "browser_claim_policy"
    ]

    assert {
        "code": "missing_policy_kind",
        "path": "policies",
        "message": "missing policy artifact kind browser_claim_policy",
    } in bundle_check.check_bundle(payload)


def test_browser_release_artifact_bundle_requires_capture_policy() -> None:
    payload = _load()
    payload["policies"] = [
        row
        for row in payload["policies"]
        if row["kind"] != "browser_capture_policy"
    ]

    assert {
        "code": "missing_policy_kind",
        "path": "policies",
        "message": "missing policy artifact kind browser_capture_policy",
    } in bundle_check.check_bundle(payload)


def test_browser_release_artifact_bundle_requires_chromium_patch_manifest() -> None:
    payload = _load()
    payload["policies"] = [
        row
        for row in payload["policies"]
        if row["kind"] != "chromium_patch_manifest"
    ]

    assert {
        "code": "missing_policy_kind",
        "path": "policies",
        "message": "missing policy artifact kind chromium_patch_manifest",
    } in bundle_check.check_bundle(payload)


def test_browser_release_artifact_bundle_rejects_candidate_failures() -> None:
    payload = _load()
    payload["releaseStatus"] = "release_candidate"
    payload["failureCodes"] = [{"code": "x", "path": "y", "message": "z"}]

    assert {
        "code": "release_candidate_has_failures",
        "path": "failureCodes",
        "message": "release candidates cannot carry failureCodes",
    } in bundle_check.check_bundle(payload)


def test_browser_release_artifact_bundle_require_candidate_rejects_diagnostic() -> None:
    assert {
        "code": "release_candidate_required",
        "path": "releaseStatus",
        "message": "browser release artifact bundle must be a release_candidate",
    } in bundle_check.check_bundle(_load(), require_release_candidate=True)


def test_browser_release_artifact_bundle_require_candidate_requires_verification_root() -> None:
    payload = _load()
    payload["releaseStatus"] = "release_candidate"

    assert {
        "code": "release_candidate_requires_verification",
        "path": "verifyFilesRoot",
        "message": "release-candidate browser release bundles require --verify-files-root",
    } in bundle_check.check_bundle(payload, require_release_candidate=True)


def test_browser_release_artifact_bundle_candidate_requires_release_archive() -> None:
    payload = _load()
    payload["releaseStatus"] = "release_candidate"
    del payload["releaseArchive"]

    assert {
        "code": "missing_release_archive",
        "path": "releaseArchive",
        "message": "release candidates must hash-bind the downloadable browser archive",
    } in bundle_check.check_bundle(payload)


def test_browser_release_artifact_bundle_candidate_requires_archive_download_url(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    del payload["releaseArchive"]["downloadUrl"]

    assert {
        "code": "missing_release_archive_download_url",
        "path": "releaseArchive.downloadUrl",
        "message": "release candidates must expose a hosted HTTPS browser archive download URL",
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_candidate_requires_package_inputs(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    del payload["packageInputs"]

    assert {
        "code": "missing_package_inputs",
        "path": "packageInputs",
        "message": "release candidates must hash-bind a passing browser release package-inputs check",
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_candidate_rejects_non_candidate_package_inputs(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")

    def mutate(package_inputs: dict[str, Any]) -> None:
        package_inputs["releaseCandidateEligible"] = False
        package_inputs["evidenceMode"] = "diagnostic"
        package_inputs["releaseCandidateBlockers"] = [
            {
                "code": "initial_macos_arm64_release_required",
                "path": "platform",
                "message": "initial browser release artifact must be macOS arm64 zip",
            }
        ]

    _mutate_package_inputs_fixture(payload, tmp_path, mutate)
    failures = bundle_check.check_bundle(payload, verify_files_root=tmp_path)

    assert {
        "code": "package_inputs_not_release_candidate_eligible",
        "path": "packageInputs.releaseCandidateEligible",
        "message": "release-candidate bundles require release-candidate eligible package inputs",
    } in failures
    assert {
        "code": "package_inputs_not_release_candidate_evidence",
        "path": "packageInputs.evidenceMode",
        "message": "release-candidate bundles require package inputs evidenceMode=release_candidate",
    } in failures
    assert {
        "code": "package_inputs_release_candidate_blockers_present",
        "path": "packageInputs.releaseCandidateBlockers",
        "message": "release-candidate package inputs must carry no release-candidate blockers",
    } in failures


def test_browser_release_artifact_bundle_candidate_rejects_dirty_passing_package_inputs(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")

    def mutate(package_inputs: dict[str, Any]) -> None:
        package_inputs["failures"] = [
            {"code": "stale_failure", "path": "status", "message": "stale failure"}
        ]
        package_inputs["summary"]["packageable"] = False

    _mutate_package_inputs_fixture(payload, tmp_path, mutate)
    failures = bundle_check.check_bundle(payload, verify_files_root=tmp_path)

    assert {
        "code": "package_inputs_failures_present",
        "path": "packageInputs.failures",
        "message": "passing package inputs must carry no failures",
    } in failures
    assert {
        "code": "package_inputs_summary_not_packageable",
        "path": "packageInputs.summary.packageable",
        "message": "passing package inputs summary.packageable must be true",
    } in failures


def test_browser_release_artifact_bundle_candidate_rejects_stale_package_input_binary_identity(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")

    def mutate(package_inputs: dict[str, Any]) -> None:
        for role in ("browserExecutable", "doeRuntime", "dawnFallbackRuntime", "shaderCompiler"):
            package_inputs["inputs"][role].pop("detectedFormat", None)
            package_inputs["inputs"][role].pop("detectedArchitectures", None)

    _mutate_package_inputs_fixture(payload, tmp_path, mutate)
    failures = bundle_check.check_bundle(payload, verify_files_root=tmp_path)
    failure_codes = [item["code"] for item in failures]

    assert failure_codes.count("package_inputs_macos_binary_format_mismatch") == 4
    assert failure_codes.count("package_inputs_macos_binary_arch_mismatch") == 4
    assert {
        "code": "package_inputs_macos_binary_format_mismatch",
        "path": "packageInputs.inputs.browserExecutable.detectedFormat",
        "message": "release-candidate package inputs browserExecutable must be Mach-O for macOS",
    } in failures
    assert {
        "code": "package_inputs_macos_binary_format_mismatch",
        "path": "packageInputs.inputs.shaderCompiler.detectedFormat",
        "message": "release-candidate package inputs shaderCompiler must be Mach-O for macOS",
    } in failures


def test_browser_release_artifact_bundle_candidate_rejects_local_archive_download_url(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    payload["releaseArchive"]["downloadUrl"] = "http://localhost/Fawn-Doe-macos-arm64.zip"

    assert {
        "code": "invalid_release_archive_download_url",
        "path": "releaseArchive.downloadUrl",
        "message": "release archive download URL must be public HTTPS",
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_candidate_rejects_reserved_archive_download_url(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    payload["releaseArchive"]["downloadUrl"] = "https://example.invalid/Fawn-Doe-macos-arm64.zip"

    assert {
        "code": "invalid_release_archive_download_url",
        "path": "releaseArchive.downloadUrl",
        "message": "release archive download URL must be public HTTPS",
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_candidate_requires_browser_product(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    del payload["browserProduct"]

    assert {
        "code": "missing_browser_product",
        "path": "browserProduct",
        "message": "downloadable browser artifacts must declare Doe Browser or Fawn Doe identity",
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_rejects_product_channel_mismatch(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    payload["browserProduct"]["channel"] = "diagnostic"

    assert {
        "code": "browser_product_channel_mismatch",
        "path": "browserProduct.channel",
        "message": "browser product channel must match releaseStatus",
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_candidate_requires_public_download_receipt(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    del payload["publicDownloadReceipt"]

    assert {
        "code": "missing_public_download_receipt",
        "path": "publicDownloadReceipt",
        "message": "release candidates must hash-bind a public download receipt",
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_candidate_requires_browser_launch_receipt(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    del payload["browserLaunchReceipt"]

    assert {
        "code": "missing_browser_launch_receipt",
        "path": "browserLaunchReceipt",
        "message": "release candidates must hash-bind a browser release launch receipt",
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_candidate_rejects_launch_without_webgpu(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    receipt_path = tmp_path / payload["browserLaunchReceipt"]["path"]
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    receipt["webgpuAvailable"] = False
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    payload["browserLaunchReceipt"]["sha256"] = builder.sha256_file(receipt_path)

    assert {
        "code": "browser_launch_webgpu_unavailable",
        "path": "browserLaunchReceipt.webgpuAvailable",
        "message": "browser launch receipt must prove WebGPU is available",
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_candidate_rejects_launch_hidden_fallback_used(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    receipt_path = tmp_path / payload["browserLaunchReceipt"]["path"]
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    receipt["hiddenFallbackUsed"] = True
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    payload["browserLaunchReceipt"]["sha256"] = builder.sha256_file(receipt_path)

    assert {
        "code": "browser_launch_hidden_fallback_used",
        "path": "browserLaunchReceipt.hiddenFallbackUsed",
        "message": "browser launch receipt must prove hidden fallback was not used",
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_candidate_rejects_launch_backend_drift(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    receipt_path = tmp_path / payload["browserLaunchReceipt"]["path"]
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    receipt["activeBackend"] = "webgpu-other"
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    payload["browserLaunchReceipt"]["sha256"] = builder.sha256_file(receipt_path)

    assert {
        "code": "browser_launch_active_backend_mismatch",
        "path": "browserLaunchReceipt.activeBackend",
        "message": "browser launch activeBackend must match proof surface diagnostics",
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_candidate_rejects_launch_comparison_page_drift(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    receipt_path = tmp_path / payload["browserLaunchReceipt"]["path"]
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    receipt["comparisonReceipt"]["pageArtifactPath"] = "examples/browser-gallery-rendering.sample.html"
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    payload["browserLaunchReceipt"]["sha256"] = builder.sha256_file(receipt_path)

    assert {
        "code": "browser_launch_comparison_page_not_loaded_gallery",
        "path": "browserLaunchReceipt.comparisonReceipt.pageArtifactPath",
        "message": "browser launch comparison pageArtifactPath must match the loaded gallery artifactPath",
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_candidate_rejects_launch_comparison_receipt_drift(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    receipt_path = tmp_path / payload["browserLaunchReceipt"]["path"]
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    receipt["comparisonReceipt"]["dawnReceiptId"] = "other-dawn-receipt"
    receipt["observedReceiptIds"].append("other-dawn-receipt")
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    payload["browserLaunchReceipt"]["sha256"] = builder.sha256_file(receipt_path)

    assert {
        "code": "browser_launch_comparison_dawn_receipt_mismatch",
        "path": "browserLaunchReceipt.comparisonReceipt.dawnReceiptId",
        "message": "browser launch Dawn receipt ID must match proof surface comparison",
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_candidate_rejects_duplicate_launch_observed_receipts(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    receipt_path = tmp_path / payload["browserLaunchReceipt"]["path"]
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    receipt["observedReceiptIds"].append(receipt["observedReceiptIds"][0])
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    payload["browserLaunchReceipt"]["sha256"] = builder.sha256_file(receipt_path)

    assert {
        "code": "duplicate_browser_launch_observed_receipts",
        "path": "browserLaunchReceipt.observedReceiptIds",
        "message": "browser launch observedReceiptIds must be unique",
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_candidate_rejects_unlinked_launch_observed_receipts(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    receipt_path = tmp_path / payload["browserLaunchReceipt"]["path"]
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    receipt["observedReceiptIds"].append("browser-unlinked-receipt")
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    payload["browserLaunchReceipt"]["sha256"] = builder.sha256_file(receipt_path)

    assert {
        "code": "browser_launch_unlinked_observed_receipts",
        "path": "browserLaunchReceipt.observedReceiptIds",
        "message": "browser launch observedReceiptIds must exactly match proof, gallery, Dawn, and Doe receipt IDs",
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_candidate_requires_chromium_source_checkout(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    del payload["chromiumSourceCheckout"]

    assert {
        "code": "missing_chromium_source_checkout",
        "path": "chromiumSourceCheckout",
        "message": (
            "release candidates must hash-bind a passing Chromium source "
            "checkout report"
        ),
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_diagnostic_accepts_blocked_chromium_source_checkout(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="diagnostic")
    report_path = tmp_path / payload["chromiumSourceCheckout"]["path"]
    _write_chromium_source_checkout_report(
        report_path,
        status="blocked",
        require_runtime_selector=True,
    )
    payload["chromiumSourceCheckout"]["sha256"] = builder.sha256_file(report_path)

    assert bundle_check.check_bundle(payload, verify_files_root=tmp_path) == []


def test_browser_release_artifact_bundle_rejects_inconsistent_chromium_source_checkout_status(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="diagnostic")
    report_path = tmp_path / payload["chromiumSourceCheckout"]["path"]
    _write_chromium_source_checkout_report(report_path, status="pass")
    report = json.loads(report_path.read_text(encoding="utf-8"))
    report["missingRequired"] = ["selector:runtime_switch"]
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    payload["chromiumSourceCheckout"]["sha256"] = builder.sha256_file(report_path)

    assert {
        "code": "chromium_source_checkout_pass_has_missing_required",
        "path": "chromiumSourceCheckout.missingRequired",
        "message": (
            "passing Chromium source checkout report must have no missing "
            "required checks"
        ),
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_candidate_rejects_blocked_chromium_source_checkout(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    report_path = tmp_path / payload["chromiumSourceCheckout"]["path"]
    _write_chromium_source_checkout_report(report_path, status="blocked")
    payload["chromiumSourceCheckout"]["sha256"] = builder.sha256_file(report_path)

    failures = bundle_check.check_bundle(payload, verify_files_root=tmp_path)

    assert {
        "code": "chromium_source_checkout_not_pass",
        "path": "chromiumSourceCheckout.status",
        "message": "release-candidate Chromium source checkout report must pass",
    } in failures
    assert {
        "code": "chromium_source_checkout_missing_required",
        "path": "chromiumSourceCheckout.missingRequired",
        "message": (
            "release-candidate Chromium source checkout report must have no "
            "missing required checks"
        ),
    } in failures


def test_browser_release_artifact_bundle_candidate_rejects_source_checkout_without_runtime_selector(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    report_path = tmp_path / payload["chromiumSourceCheckout"]["path"]
    _write_chromium_source_checkout_report(
        report_path,
        require_runtime_selector=False,
    )
    payload["chromiumSourceCheckout"]["sha256"] = builder.sha256_file(report_path)

    assert {
        "code": "chromium_source_checkout_runtime_selector_not_required",
        "path": "chromiumSourceCheckout.requireRuntimeSelector",
        "message": (
            "release-candidate Chromium source checkout must require runtime "
            "selector markers"
        ),
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_candidate_rejects_public_download_hash_mismatch(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    receipt_path = tmp_path / payload["publicDownloadReceipt"]["path"]
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    receipt["contentSha256"] = "0" * 64
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    payload["publicDownloadReceipt"]["sha256"] = builder.sha256_file(receipt_path)

    assert {
        "code": "public_download_hash_mismatch",
        "path": "publicDownloadReceipt.contentSha256",
        "message": "public download receipt contentSha256 must match releaseArchive.sha256",
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_candidate_rejects_public_download_manifest_path_mismatch(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    receipt_path = tmp_path / payload["publicDownloadReceipt"]["path"]
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    receipt["releaseArchiveManifestPath"] = "examples/wrong-browser-release-archive-manifest.json"
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    payload["publicDownloadReceipt"]["sha256"] = builder.sha256_file(receipt_path)

    assert {
        "code": "public_download_archive_manifest_path_mismatch",
        "path": "publicDownloadReceipt.releaseArchiveManifestPath",
        "message": "public download receipt releaseArchiveManifestPath must match releaseArchiveManifest.path",
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_candidate_rejects_public_download_manifest_hash_mismatch(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    receipt_path = tmp_path / payload["publicDownloadReceipt"]["path"]
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    receipt["releaseArchiveManifestSha256"] = "0" * 64
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    payload["publicDownloadReceipt"]["sha256"] = builder.sha256_file(receipt_path)

    assert {
        "code": "public_download_archive_manifest_hash_mismatch",
        "path": "publicDownloadReceipt.releaseArchiveManifestSha256",
        "message": "public download receipt releaseArchiveManifestSha256 must match releaseArchiveManifest.sha256",
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_candidate_rejects_failed_public_download(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    receipt_path = tmp_path / payload["publicDownloadReceipt"]["path"]
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    receipt["statusCode"] = 404
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    payload["publicDownloadReceipt"]["sha256"] = builder.sha256_file(receipt_path)

    assert {
        "code": "invalid_public_download_status",
        "path": "publicDownloadReceipt.statusCode",
        "message": "public download receipt statusCode must be 200",
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_rejects_public_download_product_mismatch(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    receipt_path = tmp_path / payload["publicDownloadReceipt"]["path"]
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    receipt["browserProduct"] = {
        "productId": "doe-browser",
        "displayName": "Doe Browser",
        "version": "0.0.0-test",
        "channel": "release_candidate",
    }
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    payload["publicDownloadReceipt"]["sha256"] = builder.sha256_file(receipt_path)

    assert {
        "code": "public_download_browser_product_mismatch",
        "path": "publicDownloadReceipt.browserProduct",
        "message": "public download receipt browserProduct must match release bundle browserProduct",
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_release_archive_requires_platform() -> None:
    payload = _load()
    del payload["platform"]

    assert {
        "code": "missing_platform",
        "path": "platform",
        "message": "releaseArchive requires platform identity",
    } in bundle_check.check_bundle(payload)


def test_browser_release_artifact_bundle_builder_hashes_artifacts(tmp_path: Path) -> None:
    release_archive = _write_zip(tmp_path / "Fawn-Doe-macos-arm64.zip")
    browser_binary = _write_file(tmp_path / "chrome", "browser")
    doe_runtime = _write_file(tmp_path / "libwebgpu_doe.dylib", "runtime")
    dawn_fallback_runtime = _write_file(tmp_path / "libdawn_native.so", "dawn")
    shader_compiler = _write_file(tmp_path / "doe-zig-runtime", "compiler")
    release_archive_manifest = _write_release_archive_manifest(
        tmp_path / "browser-release-archive-manifest.json",
        release_archive,
        DEFAULT_BROWSER_PRODUCT,
    )
    public_download_receipt = _write_public_download_receipt(
        tmp_path / "browser-public-download-receipt.json",
        release_archive,
        release_archive_manifest,
        DEFAULT_BROWSER_PRODUCT,
    )
    proof_surface = _write_proof_surface_fixture(
        tmp_path,
        release_archive,
        release_archive_manifest,
        public_download_receipt,
        DEFAULT_BROWSER_PRODUCT,
    )
    contract = _write_file(tmp_path / "browser-claim-methodology.contract.md", "contract")
    claim_report = _write_file(tmp_path / "browser-claim-report.json", "{}\n")
    promotion_receipt = _write_promotion_receipt(tmp_path / "browser-claim-report.promotion-receipt.json", claim_report)
    runtime_policy = _write_file(tmp_path / "browser-runtime-selector-policy.json", "{}\n")
    fork_policy = _write_file(tmp_path / "chromium-fork-maintenance-policy.json", "{}\n")
    patch_manifest = _write_file(tmp_path / "chromium-patch-manifest.json", "{}\n")
    claim_policy = _write_file(tmp_path / "browser-claim-policy.json", "{}\n")
    capture_policy = _write_file(tmp_path / "browser-capture-policy.json", "{}\n")
    identity_coverage = _write_file(tmp_path / "browser-artifact-identity-coverage.json", "{}\n")
    unsupported_taxonomy = _write_file(tmp_path / "browser-unsupported-reason-taxonomy.json", "{}\n")

    payload = builder.build_bundle(
        bundle_id="test-bundle",
        release_status="diagnostic",
        release_archive=release_archive,
        release_archive_url="https://downloads.doe.dev/Fawn-Doe-macos-arm64.zip",
        release_archive_manifest=release_archive_manifest,
        public_download_receipt=public_download_receipt,
        browser_product=DEFAULT_BROWSER_PRODUCT,
        platform={"os": "macos", "arch": "arm64", "packageFormat": "zip"},
        browser_binary_archive_path=DEFAULT_BROWSER_ARCHIVE_PATH,
        browser_app_metadata_archive_path=DEFAULT_APP_METADATA_ARCHIVE_PATH,
        doe_runtime_archive_path=DEFAULT_DOE_RUNTIME_ARCHIVE_PATH,
        dawn_fallback_runtime_archive_path=DEFAULT_DAWN_RUNTIME_ARCHIVE_PATH,
        browser_binary=browser_binary,
        doe_runtime=doe_runtime,
        dawn_fallback_runtime=dawn_fallback_runtime,
        shader_compiler=shader_compiler,
        proof_surface=proof_surface,
        proof_surface_check=_write_proof_surface_check_fixture(
            tmp_path / "browser-published-proof-surface-check.json",
            proof_surface,
        ),
        contracts=[contract],
        claim_reports=[claim_report],
        promotion_receipts=[promotion_receipt],
        policies=[
            runtime_policy,
            fork_policy,
            patch_manifest,
            claim_policy,
            capture_policy,
            identity_coverage,
            unsupported_taxonomy,
        ],
    )

    assert payload["releaseArchive"]["sha256"] == builder.sha256_file(release_archive)
    assert payload["releaseArchive"]["downloadUrl"] == "https://downloads.doe.dev/Fawn-Doe-macos-arm64.zip"
    assert payload["publicDownloadReceipt"]["kind"] == "browser_public_download_receipt"
    assert payload["browserBinary"]["sha256"] == builder.sha256_file(browser_binary)
    assert payload["doeRuntime"]["sha256"] == builder.sha256_file(doe_runtime)
    assert payload["dawnFallbackRuntime"]["sha256"] == builder.sha256_file(dawn_fallback_runtime)
    assert payload["proofSurface"]["sha256"] == builder.sha256_file(proof_surface)
    assert payload["proofSurfaceCheck"]["kind"] == "browser_published_proof_surface_check"
    assert payload["promotionReceipts"][0]["sha256"] == builder.sha256_file(promotion_receipt)
    assert bundle_check.check_bundle(payload) == []
    assert bundle_check.check_bundle(payload, verify_files_root=tmp_path) == []


def test_browser_release_artifact_bundle_builder_requires_verification_for_candidate(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")

    assert {
        "code": "release_candidate_requires_verification",
        "path": "verifyFilesRoot",
        "message": "release_candidate browser release bundles require --verify-files-root",
    } in builder.bundle_verification_failures(payload, None)


def test_browser_release_artifact_bundle_builder_requires_platform_for_archive(tmp_path: Path) -> None:
    paths = _release_bundle_inputs(tmp_path)
    payload = builder.build_bundle(
        bundle_id="test-bundle",
        release_status="diagnostic",
        release_archive=paths["release_archive"],
        browser_product=DEFAULT_BROWSER_PRODUCT,
        platform=None,
        browser_binary_archive_path=paths["browser_binary_archive_path"],
        browser_app_metadata_archive_path=DEFAULT_APP_METADATA_ARCHIVE_PATH,
        doe_runtime_archive_path=DEFAULT_DOE_RUNTIME_ARCHIVE_PATH,
        dawn_fallback_runtime_archive_path=DEFAULT_DAWN_RUNTIME_ARCHIVE_PATH,
        browser_binary=paths["browser_binary"],
        doe_runtime=paths["doe_runtime"],
        dawn_fallback_runtime=paths["dawn_fallback_runtime"],
        shader_compiler=paths["shader_compiler"],
        proof_surface=paths["proof_surface"],
        contracts=paths["contracts"],
        claim_reports=paths["claim_reports"],
        promotion_receipts=paths["promotion_receipts"],
        policies=paths["policies"],
    )

    assert {
        "code": "missing_platform",
        "path": "platform",
        "message": "releaseArchive requires platform identity",
    } in builder.bundle_verification_failures(payload, None)


def test_browser_release_artifact_bundle_builder_requires_browser_archive_member_path(tmp_path: Path) -> None:
    paths = _release_bundle_inputs(tmp_path)
    payload = builder.build_bundle(
        bundle_id="test-bundle",
        release_status="diagnostic",
        release_archive=paths["release_archive"],
        browser_product=DEFAULT_BROWSER_PRODUCT,
        platform={"os": "macos", "arch": "arm64", "packageFormat": "zip"},
        browser_app_metadata_archive_path=DEFAULT_APP_METADATA_ARCHIVE_PATH,
        doe_runtime_archive_path=DEFAULT_DOE_RUNTIME_ARCHIVE_PATH,
        dawn_fallback_runtime_archive_path=DEFAULT_DAWN_RUNTIME_ARCHIVE_PATH,
        browser_binary=paths["browser_binary"],
        doe_runtime=paths["doe_runtime"],
        dawn_fallback_runtime=paths["dawn_fallback_runtime"],
        shader_compiler=paths["shader_compiler"],
        proof_surface=paths["proof_surface"],
        contracts=paths["contracts"],
        claim_reports=paths["claim_reports"],
        promotion_receipts=paths["promotion_receipts"],
        policies=paths["policies"],
    )

    assert {
        "code": "missing_browser_executable_archive_path",
        "path": "browserExecutableArchivePath",
        "message": "releaseArchive requires the browser executable path inside the archive",
    } in builder.bundle_verification_failures(payload, None)


def test_browser_release_artifact_bundle_builder_requires_app_metadata_path(tmp_path: Path) -> None:
    paths = _release_bundle_inputs(tmp_path)
    payload = builder.build_bundle(
        bundle_id="test-bundle",
        release_status="diagnostic",
        release_archive=paths["release_archive"],
        browser_product=DEFAULT_BROWSER_PRODUCT,
        platform={"os": "macos", "arch": "arm64", "packageFormat": "zip"},
        browser_binary_archive_path=paths["browser_binary_archive_path"],
        doe_runtime_archive_path=DEFAULT_DOE_RUNTIME_ARCHIVE_PATH,
        dawn_fallback_runtime_archive_path=DEFAULT_DAWN_RUNTIME_ARCHIVE_PATH,
        browser_binary=paths["browser_binary"],
        doe_runtime=paths["doe_runtime"],
        dawn_fallback_runtime=paths["dawn_fallback_runtime"],
        shader_compiler=paths["shader_compiler"],
        proof_surface=paths["proof_surface"],
        contracts=paths["contracts"],
        claim_reports=paths["claim_reports"],
        promotion_receipts=paths["promotion_receipts"],
        policies=paths["policies"],
    )

    assert {
        "code": "missing_browser_app_metadata_archive_path",
        "path": "browserAppMetadataArchivePath",
        "message": "macOS releaseArchive requires the app metadata Info.plist path inside the archive",
    } in builder.bundle_verification_failures(payload, None)


def test_browser_release_artifact_bundle_builder_requires_doe_runtime_archive_path(tmp_path: Path) -> None:
    paths = _release_bundle_inputs(tmp_path)
    payload = builder.build_bundle(
        bundle_id="test-bundle",
        release_status="diagnostic",
        release_archive=paths["release_archive"],
        browser_product=DEFAULT_BROWSER_PRODUCT,
        platform={"os": "macos", "arch": "arm64", "packageFormat": "zip"},
        browser_binary_archive_path=paths["browser_binary_archive_path"],
        browser_app_metadata_archive_path=DEFAULT_APP_METADATA_ARCHIVE_PATH,
        dawn_fallback_runtime_archive_path=DEFAULT_DAWN_RUNTIME_ARCHIVE_PATH,
        browser_binary=paths["browser_binary"],
        doe_runtime=paths["doe_runtime"],
        dawn_fallback_runtime=paths["dawn_fallback_runtime"],
        shader_compiler=paths["shader_compiler"],
        proof_surface=paths["proof_surface"],
        contracts=paths["contracts"],
        claim_reports=paths["claim_reports"],
        promotion_receipts=paths["promotion_receipts"],
        policies=paths["policies"],
    )

    assert {
        "code": "missing_doe_runtime_archive_path",
        "path": "doeRuntimeArchivePath",
        "message": "releaseArchive requires the Doe runtime path inside the archive",
    } in builder.bundle_verification_failures(payload, None)


def test_browser_release_artifact_bundle_builder_requires_dawn_runtime_archive_path(tmp_path: Path) -> None:
    paths = _release_bundle_inputs(tmp_path)
    payload = builder.build_bundle(
        bundle_id="test-bundle",
        release_status="diagnostic",
        release_archive=paths["release_archive"],
        browser_product=DEFAULT_BROWSER_PRODUCT,
        platform={"os": "macos", "arch": "arm64", "packageFormat": "zip"},
        browser_binary_archive_path=paths["browser_binary_archive_path"],
        browser_app_metadata_archive_path=DEFAULT_APP_METADATA_ARCHIVE_PATH,
        doe_runtime_archive_path=DEFAULT_DOE_RUNTIME_ARCHIVE_PATH,
        browser_binary=paths["browser_binary"],
        doe_runtime=paths["doe_runtime"],
        dawn_fallback_runtime=paths["dawn_fallback_runtime"],
        shader_compiler=paths["shader_compiler"],
        proof_surface=paths["proof_surface"],
        contracts=paths["contracts"],
        claim_reports=paths["claim_reports"],
        promotion_receipts=paths["promotion_receipts"],
        policies=paths["policies"],
    )

    assert {
        "code": "missing_dawn_fallback_runtime_archive_path",
        "path": "dawnFallbackRuntimeArchivePath",
        "message": "releaseArchive requires the Dawn fallback runtime path inside the archive",
    } in builder.bundle_verification_failures(payload, None)


def test_browser_release_artifact_bundle_candidate_requires_dawn_fallback_runtime(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    del payload["dawnFallbackRuntime"]

    assert {
        "code": "missing_dawn_fallback_runtime",
        "path": "dawnFallbackRuntime",
        "message": "release candidates must hash-bind the Dawn fallback runtime",
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_candidate_requires_proof_surface(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    del payload["proofSurface"]

    assert {
        "code": "missing_proof_surface",
        "path": "proofSurface",
        "message": "release candidates must hash-bind the browser published proof surface",
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_candidate_requires_proof_surface_check(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    del payload["proofSurfaceCheck"]

    assert {
        "code": "missing_proof_surface_check",
        "path": "proofSurfaceCheck",
        "message": "release candidates must hash-bind the browser published proof-surface checker report",
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_rejects_stale_proof_surface_check(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    check_path = Path(payload["proofSurfaceCheck"]["path"])
    if not check_path.is_absolute():
        check_path = tmp_path / check_path
    check_payload = json.loads(check_path.read_text(encoding="utf-8"))
    check_payload["surfaceSha256"] = "0" * 64
    check_path.write_text(json.dumps(check_payload, indent=2) + "\n", encoding="utf-8")
    payload["proofSurfaceCheck"]["sha256"] = builder.sha256_file(check_path)

    assert {
        "code": "proof_surface_check_hash_mismatch",
        "path": "proofSurfaceCheck.surfaceSha256",
        "message": "proof-surface checker report surfaceSha256 must match proofSurface.sha256",
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_rejects_failing_proof_surface_check(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    check_path = Path(payload["proofSurfaceCheck"]["path"])
    if not check_path.is_absolute():
        check_path = tmp_path / check_path
    proof_surface_path = Path(payload["proofSurface"]["path"])
    if not proof_surface_path.is_absolute():
        proof_surface_path = tmp_path / proof_surface_path
    check_path = _write_proof_surface_check_fixture(
        check_path,
        proof_surface_path,
        status="fail",
    )
    payload["proofSurfaceCheck"]["sha256"] = builder.sha256_file(check_path)

    assert {
        "code": "proof_surface_check_not_pass",
        "path": "proofSurfaceCheck.status",
        "message": "proof-surface checker report must pass",
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_rejects_proof_surface_release_provenance_mismatch(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    proof_surface_path = Path(payload["proofSurface"]["path"])
    if not proof_surface_path.is_absolute():
        proof_surface_path = tmp_path / proof_surface_path
    proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
    proof_surface["proofPage"]["releaseProvenance"]["browserProduct"]["version"] = "0.0.0-other"
    proof_page_path = tmp_path / proof_surface["proofPage"]["artifact"]["path"]
    proof_page_path.write_text(
        proof_page_path.read_text(encoding="utf-8") + "<p>0.0.0-other</p>\n",
        encoding="utf-8",
    )
    proof_surface["proofPage"]["artifact"]["sha256"] = builder.sha256_file(proof_page_path)
    receipt_path = tmp_path / proof_surface["proofPage"]["diagnosticReceipt"]["path"]
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    receipt["releaseProvenance"] = proof_surface["proofPage"]["releaseProvenance"]
    receipt["contentSha256"] = proof_surface["proofPage"]["artifact"]["sha256"]
    receipt["contentLengthBytes"] = proof_page_path.stat().st_size
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    proof_surface["proofPage"]["diagnosticReceipt"]["sha256"] = builder.sha256_file(receipt_path)
    proof_surface_path.write_text(json.dumps(proof_surface, indent=2) + "\n", encoding="utf-8")
    payload["proofSurface"]["sha256"] = builder.sha256_file(proof_surface_path)

    assert {
        "code": "proof_surface_release_provenance_mismatch",
        "path": "proofSurface.proofPage.releaseProvenance",
        "message": "proof page releaseProvenance must match release bundle",
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_candidate_rejects_runtime_identity_hash_mismatch(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    proof_surface_path = Path(payload["proofSurface"]["path"])
    if not proof_surface_path.is_absolute():
        proof_surface_path = tmp_path / proof_surface_path
    proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
    runtime_identity_path = tmp_path / proof_surface["runtimeIdentityPath"]
    runtime_identity = json.loads(runtime_identity_path.read_text(encoding="utf-8"))
    runtime_identity["provider"]["artifactIdentity"]["doeLibSha256"] = "0" * 64
    runtime_identity_path.write_text(json.dumps(runtime_identity, indent=2) + "\n", encoding="utf-8")

    assert {
        "code": "proof_surface_runtime_identity_doe_hash_mismatch",
        "path": "proofSurface.runtimeIdentityPath.provider.artifactIdentity.doeLibSha256",
        "message": "runtime identity doeLibSha256 must match release bundle doeRuntime.sha256",
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_candidate_rejects_compiler_path_mismatch(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    proof_surface_path = Path(payload["proofSurface"]["path"])
    if not proof_surface_path.is_absolute():
        proof_surface_path = tmp_path / proof_surface_path
    proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
    diagnostics = proof_surface["proofPage"]["diagnostics"]
    old_compiler_path = diagnostics["compilerPath"]
    diagnostics["compilerPath"] = "other/compiler"

    proof_page_path = tmp_path / proof_surface["proofPage"]["artifact"]["path"]
    proof_page_path.write_text(
        proof_page_path.read_text(encoding="utf-8").replace(old_compiler_path, diagnostics["compilerPath"]),
        encoding="utf-8",
    )
    proof_surface["proofPage"]["artifact"]["sha256"] = builder.sha256_file(proof_page_path)

    receipt_path = tmp_path / proof_surface["proofPage"]["diagnosticReceipt"]["path"]
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    receipt["diagnostics"] = diagnostics
    receipt["contentSha256"] = proof_surface["proofPage"]["artifact"]["sha256"]
    receipt["contentLengthBytes"] = proof_page_path.stat().st_size
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    proof_surface["proofPage"]["diagnosticReceipt"]["sha256"] = builder.sha256_file(receipt_path)
    proof_surface_path.write_text(json.dumps(proof_surface, indent=2) + "\n", encoding="utf-8")
    payload["proofSurface"]["sha256"] = builder.sha256_file(proof_surface_path)

    assert {
        "code": "proof_surface_compiler_path_mismatch",
        "path": "proofSurface.proofPage.diagnostics.compilerPath",
        "message": "proof page compilerPath must match release bundle shaderCompiler.path",
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_builder_accepts_verified_candidate(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")

    assert builder.bundle_verification_failures(payload, tmp_path) == []
    payload["platform"]["arch"] = "x64"
    assert any(f["code"] == "release_candidate_platform_not_macos_arm64" for f in builder.bundle_verification_failures(payload, tmp_path))
    payload["platform"]["arch"] = "arm64"
    del payload["runtimeFrontierBundle"]
    assert any(f["code"] == "missing_runtime_frontier_bundle" for f in builder.bundle_verification_failures(payload, tmp_path))
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    frontier_path = tmp_path / payload["runtimeFrontierBundle"]["path"]; frontier = json.loads(frontier_path.read_text(encoding="utf-8"))
    frontier["componentReceipts"]["releaseArtifactBundle"]["bundleId"] = "other-bundle"; frontier_path.write_text(json.dumps(frontier) + "\n", encoding="utf-8"); payload["runtimeFrontierBundle"]["sha256"] = builder.sha256_file(frontier_path)
    assert any(f["code"] == "runtime_frontier_bundle_id_mismatch" for f in builder.bundle_verification_failures(payload, tmp_path))
    frontier["componentReceipts"]["releaseArtifactBundle"]["bundleId"] = "test-bundle"; frontier["claimabilityStatus"] = "blocked"; frontier["claimBlockers"] = [{"code": "x", "path": "y", "message": "z"}]
    frontier_path.write_text(json.dumps(frontier) + "\n", encoding="utf-8"); payload["runtimeFrontierBundle"]["sha256"] = builder.sha256_file(frontier_path); assert any(f["code"] == "runtime_frontier_not_claimable" for f in builder.bundle_verification_failures(payload, tmp_path))
    frontier["claimabilityStatus"] = "claimable"; frontier["claimBlockers"] = []; frontier["componentReceipts"]["claimPromotionReceipt"]["status"] = "fail"
    frontier_path.write_text(json.dumps(frontier) + "\n", encoding="utf-8"); payload["runtimeFrontierBundle"]["sha256"] = builder.sha256_file(frontier_path); assert any(f["code"] == "runtime_frontier_component_not_pass" for f in builder.bundle_verification_failures(payload, tmp_path))
    frontier["componentReceipts"]["claimPromotionReceipt"]["status"] = "pass"; frontier["componentReceipts"]["releaseArtifactBundle"]["bundleId"] = "test-bundle"; frontier["componentReceipts"]["releaseArtifactBundle"]["path"] = "other-release-bundle.json"
    frontier_path.write_text(json.dumps(frontier) + "\n", encoding="utf-8"); payload["runtimeFrontierBundle"]["sha256"] = builder.sha256_file(frontier_path)
    assert any(f["code"] == "runtime_frontier_bundle_path_mismatch" for f in builder.bundle_verification_failures(payload, tmp_path, bundle_path="release-bundle.json"))
    frontier["componentReceipts"]["claimPromotionReceipt"]["path"] = "other-promotion.json"; frontier_path.write_text(json.dumps(frontier) + "\n", encoding="utf-8"); payload["runtimeFrontierBundle"]["sha256"] = builder.sha256_file(frontier_path)
    assert any(f["code"] == "runtime_frontier_promotion_receipt_mismatch" for f in builder.bundle_verification_failures(payload, tmp_path))
    frontier["componentReceipts"]["claimPromotionReceipt"]["path"] = payload["promotionReceipts"][0]["path"]; frontier["componentReceipts"]["runtimeIdentity"]["path"] = "other-runtime-identity.json"
    frontier_path.write_text(json.dumps(frontier) + "\n", encoding="utf-8"); payload["runtimeFrontierBundle"]["sha256"] = builder.sha256_file(frontier_path)
    assert any(f["code"] == "runtime_frontier_runtime_identity_mismatch" for f in builder.bundle_verification_failures(payload, tmp_path))


def test_browser_release_artifact_bundle_rejects_runtime_frontier_release_identity_hash_drift(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    frontier_path = Path(payload["runtimeFrontierBundle"]["path"])
    frontier = json.loads(frontier_path.read_text(encoding="utf-8"))
    frontier["componentReceipts"]["releaseArtifactBundle"][
        "releaseBundleIdentitySha256"
    ] = "0" * 64
    frontier_path.write_text(json.dumps(frontier, indent=2) + "\n", encoding="utf-8")
    payload["runtimeFrontierBundle"]["sha256"] = builder.sha256_file(frontier_path)

    assert {
        "code": "runtime_frontier_release_identity_hash_mismatch",
        "path": (
            "runtimeFrontierBundle.componentReceipts.releaseArtifactBundle."
            "releaseBundleIdentitySha256"
        ),
        "message": (
            "runtime frontier release bundle identity hash must match checked "
            "release bundle"
        ),
    } in builder.bundle_verification_failures(payload, tmp_path)


def test_browser_release_artifact_bundle_builder_bootstraps_runtime_frontier(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    payload.pop("runtimeFrontierBundle")
    out_path = tmp_path / "release-bundle.json"
    frontier_path = tmp_path / "generated-runtime-frontier-bundle.json"
    runtime_identity_path = tmp_path / "examples/browser-runtime-identity.selector.sample.json"
    promotion_receipt_path = tmp_path / payload["promotionReceipts"][0]["path"]

    final_payload, frontier_report, failures = (
        builder.bootstrap_runtime_frontier_bundle(
            payload,
            out_path=out_path,
            runtime_frontier_bundle=frontier_path,
            runtime_identity=runtime_identity_path,
            claim_promotion_receipt=promotion_receipt_path,
            verify_files_root=tmp_path,
        )
    )
    builder.write_json(out_path, final_payload)

    assert failures == []
    assert frontier_report["claimabilityStatus"] == "claimable"
    assert frontier_report["claimBlockers"] == []
    assert frontier_report["componentReceipts"]["releaseArtifactBundle"]["path"] == out_path.name
    assert final_payload["runtimeFrontierBundle"] == {
        "path": str(frontier_path),
        "sha256": builder.sha256_file(frontier_path),
        "kind": "browser_runtime_frontier_bundle",
    }
    assert bundle_check.check_bundle(
        final_payload,
        verify_files_root=tmp_path,
        require_release_candidate=True,
        bundle_path=out_path.name,
    ) == []


def test_browser_release_artifact_bundle_builder_cli_bootstraps_runtime_frontier(tmp_path: Path) -> None:
    paths = _release_bundle_inputs(tmp_path, release_status="release_candidate")
    out_path = tmp_path / "release-bundle.json"
    frontier_path = tmp_path / "generated-runtime-frontier-bundle.json"
    argv = [
        "build_browser_release_artifact_bundle.py",
        "--bundle-id",
        "test-bundle",
        "--release-status",
        "release_candidate",
        "--release-archive",
        str(paths["release_archive"]),
        "--release-archive-url",
        "https://downloads.doe.dev/Fawn-Doe-macos-arm64.zip",
        "--release-archive-manifest",
        str(paths["release_archive_manifest"]),
        "--public-download-receipt",
        str(paths["public_download_receipt"]),
        "--package-inputs",
        str(paths["package_inputs"]),
        "--product-version",
        "0.0.0-test",
        "--platform-os",
        "macos",
        "--platform-arch",
        "arm64",
        "--browser-binary-archive-path",
        DEFAULT_BROWSER_ARCHIVE_PATH,
        "--browser-app-metadata-archive-path",
        DEFAULT_APP_METADATA_ARCHIVE_PATH,
        "--doe-runtime-archive-path",
        DEFAULT_DOE_RUNTIME_ARCHIVE_PATH,
        "--dawn-fallback-runtime-archive-path",
        DEFAULT_DAWN_RUNTIME_ARCHIVE_PATH,
        "--browser-binary",
        str(paths["browser_binary"]),
        "--doe-runtime",
        str(paths["doe_runtime"]),
        "--dawn-fallback-runtime",
        str(paths["dawn_fallback_runtime"]),
        "--shader-compiler",
        str(paths["shader_compiler"]),
        "--proof-surface",
        str(paths["proof_surface"]),
        "--proof-surface-check",
        str(paths["proof_surface_check"]),
        "--chromium-source-checkout",
        str(paths["chromium_source_checkout"]),
        "--browser-launch-receipt",
        str(paths["browser_launch_receipt"]),
        "--runtime-frontier-bundle",
        str(frontier_path),
        "--bootstrap-runtime-frontier",
        "--runtime-identity",
        str(tmp_path / "examples/browser-runtime-identity.selector.sample.json"),
        "--claim-report",
        str(paths["claim_reports"][0]),
        "--promotion-receipt",
        str(paths["promotion_receipts"][0]),
        "--verify-files-root",
        str(tmp_path),
        "--out",
        str(out_path),
    ]
    for contract in paths["contracts"]:
        argv.extend(["--contract", str(contract)])
    for policy in paths["policies"]:
        argv.extend(["--policy", str(policy)])

    original_argv = sys.argv
    try:
        sys.argv = argv
        assert builder.main() == 0
    finally:
        sys.argv = original_argv

    payload = json.loads(out_path.read_text(encoding="utf-8"))
    assert frontier_path.is_file()
    assert payload["runtimeFrontierBundle"]["sha256"] == builder.sha256_file(frontier_path)
    assert bundle_check.check_bundle(
        payload,
        verify_files_root=tmp_path,
        require_release_candidate=True,
        bundle_path=out_path.name,
    ) == []


def test_browser_release_artifact_bundle_rejects_invalid_zip_archive(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    bad_archive = _write_file(tmp_path / "bad-browser.zip", "not a zip")
    payload["releaseArchive"] = {
        "path": str(bad_archive),
        "sha256": builder.sha256_file(bad_archive),
        "kind": "browser_release_archive",
    }

    assert {
        "code": "invalid_release_archive_zip",
        "path": "releaseArchive.path",
        "message": f"release archive is not a valid zip file: {bad_archive}",
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_rejects_macos_candidate_non_macho_archive_members(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    bad_archive = _write_zip(
        tmp_path / "script-and-elf-browser.zip",
        member_content=b"#!/bin/sh\n",
        doe_runtime_member_content=_elf_payload("x64"),
        dawn_runtime_member_content=_elf_payload("x64"),
    )
    payload["releaseArchive"] = {
        "path": str(bad_archive),
        "sha256": builder.sha256_file(bad_archive),
        "kind": "browser_release_archive",
        "downloadUrl": "https://downloads.doe.dev/Fawn-Doe-macos-arm64.zip",
    }

    failures = bundle_check.check_bundle(payload, verify_files_root=tmp_path)

    assert {
        "code": "release_archive_binary_format_mismatch",
        "path": "browserExecutableArchivePath",
        "message": (
            "macOS browser executable archive member must be Mach-O: "
            "Fawn.app/Contents/MacOS/Chromium"
        ),
    } in failures
    assert {
        "code": "release_archive_binary_arch_mismatch",
        "path": "doeRuntimeArchivePath",
        "message": (
            "macOS Doe runtime archive member must include arm64 code: "
            "Fawn.app/Contents/Frameworks/libwebgpu_doe.so"
        ),
    } in failures


def test_browser_release_artifact_bundle_rejects_missing_browser_archive_member(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    payload["browserExecutableArchivePath"] = "Missing.app/Contents/MacOS/Chromium"

    assert {
        "code": "browser_executable_archive_member_missing",
        "path": "browserExecutableArchivePath",
        "message": "browser executable archive member not found: Missing.app/Contents/MacOS/Chromium",
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_rejects_current_segment_browser_archive_member(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    payload["browserExecutableArchivePath"] = "Fawn.app/./Contents/MacOS/Chromium"

    assert {
        "code": "unsafe_browser_executable_archive_path",
        "path": "browserExecutableArchivePath",
        "message": (
            "browser executable archive path must be relative and safe: "
            "Fawn.app/./Contents/MacOS/Chromium"
        ),
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_rejects_non_executable_browser_archive_member(tmp_path: Path) -> None:
    bad_archive = _write_zip(
        tmp_path / "non-executable-browser-member.zip",
        browser_executable=False,
    )
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    payload["releaseArchive"] = {
        "path": str(bad_archive),
        "sha256": builder.sha256_file(bad_archive),
        "kind": "browser_release_archive",
        "downloadUrl": "https://downloads.doe.dev/Fawn-Doe-macos-arm64.zip",
    }

    assert {
        "code": "browser_executable_archive_member_not_executable",
        "path": "browserExecutableArchivePath",
        "message": (
            "browser executable archive member is not executable: "
            "Fawn.app/Contents/MacOS/Chromium"
        ),
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_rejects_missing_doe_runtime_archive_member(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    payload["doeRuntimeArchivePath"] = "Missing.app/Contents/Frameworks/libwebgpu_doe.so"

    assert {
        "code": "doe_runtime_archive_member_missing",
        "path": "doeRuntimeArchivePath",
        "message": "Doe runtime archive member not found: Missing.app/Contents/Frameworks/libwebgpu_doe.so",
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_rejects_duplicate_required_member_paths(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    payload["dawnFallbackRuntimeArchivePath"] = DEFAULT_DOE_RUNTIME_ARCHIVE_PATH

    assert {
        "code": "duplicate_release_archive_member_path",
        "path": "dawnFallbackRuntimeArchivePath",
        "message": (
            "Dawn fallback runtime archive path duplicates Doe runtime "
            "archive path from doeRuntimeArchivePath"
        ),
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_rejects_app_metadata_product_mismatch(tmp_path: Path) -> None:
    bad_archive = _write_zip(tmp_path / "bad-app-metadata.zip", app_display_name="Wrong")
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    payload["releaseArchive"] = {
        "path": str(bad_archive),
        "sha256": builder.sha256_file(bad_archive),
        "kind": "browser_release_archive",
        "downloadUrl": "https://downloads.doe.dev/Fawn-Doe-macos-arm64.zip",
    }

    assert any(
        failure["code"] == "browser_app_metadata_product_mismatch"
        for failure in bundle_check.check_bundle(payload, verify_files_root=tmp_path)
    )


def test_browser_release_artifact_bundle_rejects_public_download_app_metadata_path_mismatch(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    receipt_path = tmp_path / payload["publicDownloadReceipt"]["path"]
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    receipt["browserAppMetadataArchivePath"] = "Fawn.app/Contents/Bad.plist"
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    payload["publicDownloadReceipt"]["sha256"] = builder.sha256_file(receipt_path)

    assert {
        "code": "public_download_app_metadata_member_mismatch",
        "path": "publicDownloadReceipt.browserAppMetadataArchivePath",
        "message": "public download receipt browserAppMetadataArchivePath must match release bundle",
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_rejects_public_download_doe_runtime_path_mismatch(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")
    receipt_path = tmp_path / payload["publicDownloadReceipt"]["path"]
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    receipt["doeRuntimeArchivePath"] = "Fawn.app/Contents/Frameworks/libwebgpu_doe_alt.so"
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    payload["publicDownloadReceipt"]["sha256"] = builder.sha256_file(receipt_path)

    assert {
        "code": "public_download_doe_runtime_member_mismatch",
        "path": "publicDownloadReceipt.doeRuntimeArchivePath",
        "message": "public download receipt doeRuntimeArchivePath must match release bundle",
    } in bundle_check.check_bundle(payload, verify_files_root=tmp_path)


def test_browser_release_artifact_bundle_rejects_browser_archive_member_hash_mismatch(tmp_path: Path) -> None:
    paths = _release_bundle_inputs(tmp_path)
    bad_archive = _write_zip(
        tmp_path / "bad-browser-member.zip",
        member_path=paths["browser_binary_archive_path"],
        member_content="different browser",
    )
    payload = builder.build_bundle(
        bundle_id="test-bundle",
        release_status="release_candidate",
        release_archive=bad_archive,
        browser_product={**DEFAULT_BROWSER_PRODUCT, "channel": "release_candidate"},
        platform={"os": "macos", "arch": "arm64", "packageFormat": "zip"},
        browser_binary_archive_path=paths["browser_binary_archive_path"],
        browser_app_metadata_archive_path=DEFAULT_APP_METADATA_ARCHIVE_PATH,
        doe_runtime_archive_path=DEFAULT_DOE_RUNTIME_ARCHIVE_PATH,
        dawn_fallback_runtime_archive_path=DEFAULT_DAWN_RUNTIME_ARCHIVE_PATH,
        browser_binary=paths["browser_binary"],
        doe_runtime=paths["doe_runtime"],
        dawn_fallback_runtime=paths["dawn_fallback_runtime"],
        shader_compiler=paths["shader_compiler"],
        proof_surface=paths["proof_surface"],
        contracts=paths["contracts"],
        claim_reports=paths["claim_reports"],
        promotion_receipts=paths["promotion_receipts"],
        policies=paths["policies"],
    )

    assert any(
        failure["code"] == "browser_executable_archive_hash_mismatch"
        for failure in bundle_check.check_bundle(payload, verify_files_root=tmp_path)
    )


def test_browser_release_artifact_bundle_require_candidate_accepts_verified_bundle(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")

    assert bundle_check.check_bundle(
        payload,
        verify_files_root=tmp_path,
        require_release_candidate=True,
    ) == []


def test_browser_release_artifact_bundle_builder_verifies_diagnostic_when_root_is_set(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="diagnostic")
    payload["browserBinary"]["sha256"] = "0" * 64

    assert any(
        failure["code"] == "artifact_hash_mismatch"
        for failure in builder.bundle_verification_failures(payload, tmp_path)
    )


def test_browser_release_artifact_bundle_verifies_artifact_hash(tmp_path: Path) -> None:
    browser_binary = _write_file(tmp_path / "chrome", "browser")
    doe_runtime = _write_file(tmp_path / "libwebgpu_doe.dylib", "runtime")
    shader_compiler = _write_file(tmp_path / "doe-zig-runtime", "compiler")
    contract = _write_file(tmp_path / "browser-claim-methodology.contract.md", "contract")
    claim_report = _write_file(tmp_path / "browser-claim-report.json", "{}\n")
    promotion_receipt = _write_promotion_receipt(tmp_path / "browser-claim-report.promotion-receipt.json", claim_report)
    runtime_policy = _write_file(tmp_path / "browser-runtime-selector-policy.json", "{}\n")
    fork_policy = _write_file(tmp_path / "chromium-fork-maintenance-policy.json", "{}\n")
    patch_manifest = _write_file(tmp_path / "chromium-patch-manifest.json", "{}\n")
    claim_policy = _write_file(tmp_path / "browser-claim-policy.json", "{}\n")
    capture_policy = _write_file(tmp_path / "browser-capture-policy.json", "{}\n")
    identity_coverage = _write_file(tmp_path / "browser-artifact-identity-coverage.json", "{}\n")
    unsupported_taxonomy = _write_file(tmp_path / "browser-unsupported-reason-taxonomy.json", "{}\n")
    payload = builder.build_bundle(
        bundle_id="test-bundle",
        release_status="diagnostic",
        browser_binary=browser_binary,
        doe_runtime=doe_runtime,
        shader_compiler=shader_compiler,
        contracts=[contract],
        claim_reports=[claim_report],
        promotion_receipts=[promotion_receipt],
        policies=[
            runtime_policy,
            fork_policy,
            patch_manifest,
            claim_policy,
            capture_policy,
            identity_coverage,
            unsupported_taxonomy,
        ],
    )
    payload["browserBinary"]["sha256"] = "0" * 64

    assert any(
        failure["code"] == "artifact_hash_mismatch"
        for failure in bundle_check.check_bundle(payload, verify_files_root=tmp_path)
    )


def test_browser_release_artifact_bundle_rejects_artifact_path_escape(tmp_path: Path) -> None:
    payload = _load()
    payload["browserBinary"]["path"] = "../chrome"

    failures = bundle_check.check_bundle(payload, verify_files_root=tmp_path)

    assert {
        "code": "unsafe_artifact_path",
        "path": "browserBinary.path",
        "message": "artifact path must resolve under verify-files-root: ../chrome",
    } in failures


def test_browser_release_artifact_bundle_verifies_promotion_receipt_covers_claim(tmp_path: Path) -> None:
    browser_binary = _write_file(tmp_path / "chrome", "browser")
    doe_runtime = _write_file(tmp_path / "libwebgpu_doe.dylib", "runtime")
    shader_compiler = _write_file(tmp_path / "doe-zig-runtime", "compiler")
    contract = _write_file(tmp_path / "browser-claim-methodology.contract.md", "contract")
    claim_report = _write_file(tmp_path / "browser-claim-report.json", "{}\n")
    other_claim_report = _write_file(tmp_path / "other-browser-claim-report.json", "{\"other\": true}\n")
    promotion_receipt = _write_promotion_receipt(
        tmp_path / "browser-claim-report.promotion-receipt.json",
        other_claim_report,
    )
    runtime_policy = _write_file(tmp_path / "browser-runtime-selector-policy.json", "{}\n")
    fork_policy = _write_file(tmp_path / "chromium-fork-maintenance-policy.json", "{}\n")
    patch_manifest = _write_file(tmp_path / "chromium-patch-manifest.json", "{}\n")
    claim_policy = _write_file(tmp_path / "browser-claim-policy.json", "{}\n")
    capture_policy = _write_file(tmp_path / "browser-capture-policy.json", "{}\n")
    identity_coverage = _write_file(tmp_path / "browser-artifact-identity-coverage.json", "{}\n")
    unsupported_taxonomy = _write_file(tmp_path / "browser-unsupported-reason-taxonomy.json", "{}\n")

    payload = builder.build_bundle(
        bundle_id="test-bundle",
        release_status="diagnostic",
        browser_binary=browser_binary,
        doe_runtime=doe_runtime,
        shader_compiler=shader_compiler,
        contracts=[contract],
        claim_reports=[claim_report],
        promotion_receipts=[promotion_receipt],
        policies=[
            runtime_policy,
            fork_policy,
            patch_manifest,
            claim_policy,
            capture_policy,
            identity_coverage,
            unsupported_taxonomy,
        ],
    )

    assert any(
        failure["code"] == "promotion_receipt_missing_claim_report"
        for failure in bundle_check.check_bundle(payload, verify_files_root=tmp_path)
    )


def test_browser_release_artifact_bundle_accepts_diagnostic_promotion_claim_failures(tmp_path: Path) -> None:
    paths = _release_bundle_inputs(tmp_path)
    diagnostic_receipt = _write_diagnostic_promotion_receipt(
        tmp_path / "browser-claim-report.diagnostic-promotion-receipt.json",
        paths["claim_reports"][0],
    )
    payload = builder.build_bundle(
        bundle_id="test-bundle",
        release_status="diagnostic",
        browser_binary=paths["browser_binary"],
        doe_runtime=paths["doe_runtime"],
        shader_compiler=paths["shader_compiler"],
        contracts=paths["contracts"],
        claim_reports=paths["claim_reports"],
        promotion_receipts=[diagnostic_receipt],
        policies=paths["policies"],
    )

    failures = bundle_check.check_bundle(payload, verify_files_root=tmp_path)

    assert failures == []


def test_browser_release_artifact_bundle_candidate_rejects_diagnostic_promotion_claim_failures(tmp_path: Path) -> None:
    paths = _release_bundle_inputs(tmp_path)
    diagnostic_receipt = _write_diagnostic_promotion_receipt(
        tmp_path / "browser-claim-report.diagnostic-promotion-receipt.json",
        paths["claim_reports"][0],
    )
    payload = builder.build_bundle(
        bundle_id="test-bundle",
        release_status="release_candidate",
        browser_binary=paths["browser_binary"],
        doe_runtime=paths["doe_runtime"],
        shader_compiler=paths["shader_compiler"],
        contracts=paths["contracts"],
        claim_reports=paths["claim_reports"],
        promotion_receipts=[diagnostic_receipt],
        policies=paths["policies"],
    )

    failure_codes = {
        failure["code"]
        for failure in bundle_check.check_bundle(payload, verify_files_root=tmp_path)
    }

    assert "promotion_receipt_artifact_not_forced_doe" in failure_codes
    assert "promotion_receipt_claim_policy_not_passed" in failure_codes
    assert "promotion_receipt_hidden_fallback_check_failed" in failure_codes
