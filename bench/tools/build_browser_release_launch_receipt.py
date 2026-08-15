#!/usr/bin/env python3
"""Build a browser release launch receipt from observed packaged-browser facts."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import sys
from pathlib import Path
from typing import Any

try:
    from bench.tools._public_url import is_public_https_url
except ModuleNotFoundError:
    from _public_url import is_public_https_url


REPO_ROOT = Path(__file__).resolve().parents[2]
PRODUCT_DISPLAY_NAMES = {
    "doe-browser": "Doe Browser",
    "fawn-doe": "Fawn Doe",
}
PRODUCT_CHANNELS = ("diagnostic", "release_candidate", "release")
PLATFORM_OS = ("macos", "linux", "windows")
PLATFORM_ARCH = ("arm64", "x64")
GALLERY_CATEGORIES = ("compute", "rendering", "tensor", "shader_edge", "benchmark_trace")
MANIFEST_MEMBER_PATH_BINDINGS = (
    ("browserExecutable", "browserExecutableArchivePath", "browser executable archive path"),
    ("appMetadata", "browserAppMetadataArchivePath", "browser app metadata archive path"),
    ("doeRuntime", "doeRuntimeArchivePath", "Doe runtime archive path"),
    ("dawnFallbackRuntime", "dawnFallbackRuntimeArchivePath", "Dawn fallback runtime archive path"),
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--receipt-id", required=True)
    parser.add_argument("--observed-at", default="")
    parser.add_argument("--release-archive", required=True)
    parser.add_argument("--release-archive-url", default="")
    parser.add_argument("--release-archive-manifest", required=True)
    parser.add_argument("--proof-surface", required=True)
    parser.add_argument(
        "--clean-install-check",
        default="",
        help="Passing browser_release_clean_install_check; required for release candidates and releases.",
    )
    parser.add_argument("--product-id", choices=tuple(PRODUCT_DISPLAY_NAMES), default="fawn-doe")
    parser.add_argument("--product-name", choices=tuple(PRODUCT_DISPLAY_NAMES.values()), default="Fawn Doe")
    parser.add_argument("--product-version", required=True)
    parser.add_argument("--product-channel", choices=PRODUCT_CHANNELS, required=True)
    parser.add_argument("--platform-os", choices=PLATFORM_OS, required=True)
    parser.add_argument("--platform-arch", choices=PLATFORM_ARCH, required=True)
    parser.add_argument("--package-format", choices=("zip",), default="zip")
    parser.add_argument("--browser-executable-archive-path", required=True)
    parser.add_argument("--browser-app-metadata-archive-path", required=True)
    parser.add_argument("--doe-runtime-archive-path", required=True)
    parser.add_argument("--dawn-fallback-runtime-archive-path", required=True)
    parser.add_argument("--active-backend", required=True)
    parser.add_argument("--proof-page-url", default="about:doe")
    parser.add_argument("--proof-page-artifact-path", required=True)
    parser.add_argument("--proof-page-receipt-id", required=True)
    parser.add_argument("--gallery-url", required=True)
    parser.add_argument("--gallery-category", choices=GALLERY_CATEGORIES, required=True)
    parser.add_argument("--gallery-artifact-path", required=True)
    parser.add_argument("--gallery-receipt-id", required=True)
    parser.add_argument("--comparison-id", required=True)
    parser.add_argument("--comparison-workload-id", required=True)
    parser.add_argument("--comparison-page-artifact-path", required=True)
    parser.add_argument("--comparison-artifact-path", required=True)
    parser.add_argument("--comparison-dawn-receipt-id", required=True)
    parser.add_argument("--comparison-doe-receipt-id", required=True)
    parser.add_argument("--observed-receipt-id", action="append", required=True)
    parser.add_argument("--out", required=True)
    return parser.parse_args()


def repo_relative(path: Path) -> str:
    resolved = path.resolve()
    try:
        return str(resolved.relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_json_object(path: Path, label: str) -> dict[str, Any]:
    require_file(path, label)
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ValueError(f"{label} must be valid JSON: {exc}") from exc
    if not isinstance(payload, dict):
        raise ValueError(f"{label} must be a JSON object")
    return payload


def observed_at_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def require_non_empty(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{label} is required")
    return value


def require_file(path: Path, label: str) -> None:
    if not path.is_file():
        raise FileNotFoundError(f"{label} must be an existing file: {path}")


def validate_product(browser_product: dict[str, str]) -> None:
    product_id = require_non_empty(browser_product.get("productId"), "browser product productId")
    display_name = require_non_empty(browser_product.get("displayName"), "browser product displayName")
    require_non_empty(browser_product.get("version"), "browser product version")
    channel = require_non_empty(browser_product.get("channel"), "browser product channel")
    if product_id not in PRODUCT_DISPLAY_NAMES:
        raise ValueError(f"browser product productId must be one of {', '.join(PRODUCT_DISPLAY_NAMES)}")
    if display_name != PRODUCT_DISPLAY_NAMES[product_id]:
        raise ValueError(f"product-name must be {PRODUCT_DISPLAY_NAMES[product_id]!r} for product-id {product_id!r}")
    if channel not in PRODUCT_CHANNELS:
        raise ValueError(f"browser product channel must be one of {', '.join(PRODUCT_CHANNELS)}")


def validate_platform(platform: dict[str, str]) -> None:
    if platform.get("os") not in PLATFORM_OS:
        raise ValueError(f"platform os must be one of {', '.join(PLATFORM_OS)}")
    if platform.get("arch") not in PLATFORM_ARCH:
        raise ValueError(f"platform arch must be one of {', '.join(PLATFORM_ARCH)}")
    if platform.get("packageFormat") != "zip":
        raise ValueError("platform packageFormat must be zip")


def validate_clean_install_check(
    clean_install_check: Path | None,
    *,
    release_archive: Path,
    release_archive_manifest: Path,
    browser_product: dict[str, str],
    platform: dict[str, str],
) -> dict[str, str] | None:
    required = browser_product.get("channel") in {"release_candidate", "release"}
    if clean_install_check is None:
        if required:
            raise ValueError("clean install check is required for release candidates and releases")
        return None
    payload = load_json_object(clean_install_check, "clean install check")
    if payload.get("schemaVersion") != 1:
        raise ValueError("clean install check schemaVersion must be 1")
    if payload.get("artifactKind") != "browser_release_clean_install_check":
        raise ValueError("clean install check artifactKind must be browser_release_clean_install_check")
    if payload.get("status") != "pass" or payload.get("releaseCandidateEligible") is not True:
        raise ValueError("clean install check must pass and be release-candidate eligible")
    if payload.get("verificationLevel") != "webgpu_smoke" or payload.get("sourceMode") != "release_archive":
        raise ValueError("clean install check must verify WebGPU smoke from the release archive")
    extraction = payload.get("extraction")
    if not isinstance(extraction, dict) or extraction.get("isolation") != "fresh_temporary_directory":
        raise ValueError("clean install check must use a fresh temporary extraction")
    if not isinstance(extraction, dict) or extraction.get("borrowedMemberCount") != 0:
        raise ValueError("clean install check must not borrow package members")
    if (
        not isinstance(extraction.get("archiveMemberCount"), int)
        or extraction.get("archiveMemberCount") <= 0
        or extraction.get("extractedMemberCount") != extraction.get("archiveMemberCount")
    ):
        raise ValueError("clean install check must extract every archive member")
    for field, label in (("launchProbe", "launch probe"),):
        process = payload.get(field)
        if not isinstance(process, dict) or process.get("attempted") is not True or process.get("exitCode") != 0 or process.get("timedOut") is not False:
            raise ValueError(f"clean install check {label} must pass")
    smoke = payload.get("webgpuSmoke")
    if not isinstance(smoke, dict) or smoke.get("required") is not True or smoke.get("modes") != ["dawn", "doe"]:
        raise ValueError("clean install check must require Dawn and Doe WebGPU smoke")
    smoke_process = smoke.get("process") if isinstance(smoke, dict) else None
    if not isinstance(smoke_process, dict) or smoke_process.get("attempted") is not True or smoke_process.get("exitCode") != 0 or smoke_process.get("timedOut") is not False:
        raise ValueError("clean install check WebGPU smoke process must pass")
    if payload.get("failures") != []:
        raise ValueError("passing clean install check must carry no failures")
    if payload.get("browserProduct") != browser_product or payload.get("platform") != platform:
        raise ValueError("clean install check product and platform must match launch receipt")
    for field, path, kind in (
        ("releaseArchive", release_archive, "browser_release_archive"),
        ("releaseArchiveManifest", release_archive_manifest, "browser_release_archive_manifest"),
    ):
        row = payload.get(field)
        if not isinstance(row, dict):
            raise ValueError(f"clean install check {field} is required")
        if row.get("sha256") != sha256_file(path) or row.get("kind") != kind:
            raise ValueError(f"clean install check {field} must bind launch receipt bytes")
    for row, kind, label in (
        (payload.get("verifier"), "browser_release_clean_install_verifier", "verifier"),
        (smoke.get("script") if isinstance(smoke, dict) else None, "browser_webgpu_smoke_runner", "smoke script"),
        (smoke.get("report") if isinstance(smoke, dict) else None, "chromium-webgpu-playwright-smoke", "smoke report"),
    ):
        if not isinstance(row, dict) or row.get("kind") != kind:
            raise ValueError(f"clean install check {label} artifact is required")
        path_text = row.get("path")
        if not isinstance(path_text, str) or not path_text:
            raise ValueError(f"clean install check {label} path is required")
        artifact_path = Path(path_text)
        if not artifact_path.is_absolute():
            repo_candidate = REPO_ROOT / artifact_path
            artifact_path = repo_candidate if repo_candidate.is_file() else clean_install_check.parent / artifact_path
        if not artifact_path.is_file() or row.get("sha256") != sha256_file(artifact_path):
            raise ValueError(f"clean install check {label} bytes must match its artifact hash")
    return artifact(clean_install_check, "browser_release_clean_install_check", "clean install check")


def artifact(path: Path, kind: str, label: str, *, download_url: str = "") -> dict[str, str]:
    require_file(path, label)
    payload = {
        "path": repo_relative(path),
        "sha256": sha256_file(path),
        "kind": kind,
    }
    if download_url:
        if not is_public_https_url(download_url):
            raise ValueError(f"{label} download URL must be public HTTPS")
        payload["downloadUrl"] = download_url
    return payload


def resolve_artifact_path(path_value: str, *, proof_surface_path: Path) -> Path:
    artifact_path = Path(path_value)
    if artifact_path.is_absolute():
        return artifact_path
    repo_path = REPO_ROOT / artifact_path
    if repo_path.is_file():
        return repo_path
    return proof_surface_path.parent / artifact_path


def load_referenced_receipt(
    artifact_payload: Any,
    *,
    label: str,
    proof_surface_path: Path,
) -> dict[str, Any]:
    if not isinstance(artifact_payload, dict):
        raise ValueError(f"proof surface {label} must be an artifact object")
    path_value = artifact_payload.get("path")
    if not isinstance(path_value, str) or not path_value:
        raise ValueError(f"proof surface {label} artifact path is required")
    return load_json_object(resolve_artifact_path(path_value, proof_surface_path=proof_surface_path), f"proof surface {label} receipt")


def require_equal(actual: Any, expected: Any, label: str) -> None:
    if actual != expected:
        raise ValueError(f"{label} must match proof surface")


def require_manifest_equal(actual: Any, expected: Any, label: str) -> None:
    if actual != expected:
        raise ValueError(f"{label} must match release launch receipt")


def validate_manifest_member_path(
    *,
    manifest: dict[str, Any],
    receipt: dict[str, Any],
    member_key: str,
    receipt_field: str,
    label: str,
) -> None:
    members = manifest.get("members")
    if not isinstance(members, dict):
        raise ValueError("release archive manifest members must be an object")
    member = members.get(member_key)
    if not isinstance(member, dict):
        raise ValueError(f"release archive manifest missing {member_key} member")
    require_manifest_equal(
        member.get("archivePath"),
        receipt.get(receipt_field),
        f"release archive manifest {label}",
    )
    archive_members = manifest.get("archiveMembers")
    if not isinstance(archive_members, list):
        raise ValueError("release archive manifest archiveMembers must be an array")
    if not any(
        isinstance(row, dict) and row.get("archivePath") == member.get("archivePath")
        for row in archive_members
    ):
        raise ValueError(
            f"release archive manifest archiveMembers must include {label}"
        )


def validate_receipt_against_release_archive_manifest(
    receipt: dict[str, Any],
    release_archive_manifest: Path,
    release_archive: Path,
) -> None:
    manifest = load_json_object(release_archive_manifest, "release archive manifest")
    require_manifest_equal(
        manifest.get("schemaVersion"),
        1,
        "release archive manifest schemaVersion",
    )
    require_manifest_equal(
        manifest.get("artifactKind"),
        "browser_release_archive_manifest",
        "release archive manifest artifactKind",
    )
    archive = manifest.get("archive")
    if not isinstance(archive, dict):
        raise ValueError("release archive manifest archive must be an object")
    release_archive_artifact = receipt["releaseArchive"]
    for key in ("path", "sha256", "kind"):
        require_manifest_equal(
            archive.get(key),
            release_archive_artifact.get(key),
            f"release archive manifest archive.{key}",
        )
    require_manifest_equal(
        archive.get("byteLength"),
        release_archive.stat().st_size,
        "release archive manifest archive.byteLength",
    )
    require_manifest_equal(
        manifest.get("browserProduct"),
        receipt.get("browserProduct"),
        "release archive manifest browserProduct",
    )
    require_manifest_equal(
        manifest.get("platform"),
        receipt.get("platform"),
        "release archive manifest platform",
    )
    for member_key, receipt_field, label in MANIFEST_MEMBER_PATH_BINDINGS:
        validate_manifest_member_path(
            manifest=manifest,
            receipt=receipt,
            member_key=member_key,
            receipt_field=receipt_field,
            label=label,
        )


def validate_receipt_against_proof_surface(
    receipt: dict[str, Any],
    proof_surface_path: Path,
) -> None:
    proof_payload = load_json_object(proof_surface_path, "proof surface")
    require_equal(proof_payload.get("artifactKind"), "browser_published_proof_surface", "proof surface artifactKind")

    proof_page_payload = proof_payload.get("proofPage")
    if not isinstance(proof_page_payload, dict):
        raise ValueError("proof surface proofPage must be an object")
    proof_page = receipt["proofPage"]
    require_equal(proof_page.get("url"), proof_page_payload.get("url"), "proof page URL")
    proof_page_artifact = proof_page_payload.get("artifact")
    if not isinstance(proof_page_artifact, dict):
        raise ValueError("proof surface proofPage.artifact must be an object")
    require_equal(proof_page.get("artifactPath"), proof_page_artifact.get("path"), "proof page artifactPath")

    diagnostic_payload = load_referenced_receipt(
        proof_page_payload.get("diagnosticReceipt"),
        label="proofPage.diagnosticReceipt",
        proof_surface_path=proof_surface_path,
    )
    require_equal(proof_page.get("receiptId"), diagnostic_payload.get("receiptId"), "proof page receiptId")

    diagnostics = proof_page_payload.get("diagnostics")
    if not isinstance(diagnostics, dict):
        raise ValueError("proof surface proofPage.diagnostics must be an object")
    require_equal(receipt.get("activeBackend"), diagnostics.get("activeBackend"), "active backend")

    release_provenance = proof_page_payload.get("releaseProvenance")
    if not isinstance(release_provenance, dict):
        raise ValueError("proof surface proofPage.releaseProvenance must be an object")
    for field in (
        "browserProduct",
        "platform",
        "releaseArchive",
        "releaseArchiveManifest",
        "browserExecutableArchivePath",
        "browserAppMetadataArchivePath",
        "doeRuntimeArchivePath",
        "dawnFallbackRuntimeArchivePath",
    ):
        require_equal(receipt.get(field), release_provenance.get(field), f"release provenance {field}")

    gallery_page = receipt["galleryPage"]
    matching_gallery = None
    gallery_pages = proof_payload.get("galleryPages")
    if not isinstance(gallery_pages, list):
        raise ValueError("proof surface galleryPages must be an array")
    for row in gallery_pages:
        if (
            isinstance(row, dict)
            and isinstance(row.get("artifact"), dict)
            and row["artifact"].get("path") == gallery_page.get("artifactPath")
        ):
            matching_gallery = row
            break
    if not isinstance(matching_gallery, dict):
        raise ValueError("gallery artifactPath must match a proof-surface gallery page")
    require_equal(gallery_page.get("url"), matching_gallery.get("url"), "gallery URL")
    require_equal(gallery_page.get("category"), matching_gallery.get("category"), "gallery category")
    gallery_receipt_payload = load_referenced_receipt(
        matching_gallery.get("publicReceipt"),
        label="gallery publicReceipt",
        proof_surface_path=proof_surface_path,
    )
    require_equal(gallery_page.get("receiptId"), gallery_receipt_payload.get("receiptId"), "gallery receiptId")

    comparison_receipt = receipt["comparisonReceipt"]
    matching_comparison = None
    comparison_rows = proof_payload.get("comparisonReceipts")
    if not isinstance(comparison_rows, list):
        raise ValueError("proof surface comparisonReceipts must be an array")
    for row in comparison_rows:
        if isinstance(row, dict) and row.get("comparisonId") == comparison_receipt.get("comparisonId"):
            matching_comparison = row
            break
    if not isinstance(matching_comparison, dict):
        raise ValueError("comparisonId must match a proof-surface comparison receipt")
    require_equal(comparison_receipt.get("workloadId"), matching_comparison.get("workloadId"), "comparison workloadId")
    runner = matching_comparison.get("runner")
    if not isinstance(runner, dict):
        raise ValueError("proof surface comparison runner must be an object")
    require_equal(comparison_receipt.get("pageArtifactPath"), runner.get("pageArtifactPath"), "comparison pageArtifactPath")
    require_equal(comparison_receipt.get("executionScope"), runner.get("executionScope"), "comparison executionScope")
    require_equal(comparison_receipt.get("modes"), runner.get("modes"), "comparison modes")
    require_equal(
        comparison_receipt.get("emitsSideBySideReceipts"),
        runner.get("emitsSideBySideReceipts"),
        "comparison side-by-side setting",
    )
    comparison_artifact = matching_comparison.get("comparisonArtifact")
    if not isinstance(comparison_artifact, dict):
        raise ValueError("proof surface comparisonArtifact must be an object")
    require_equal(comparison_receipt.get("comparisonArtifactPath"), comparison_artifact.get("path"), "comparison artifactPath")
    dawn_receipt = matching_comparison.get("dawnReceipt")
    doe_receipt = matching_comparison.get("doeReceipt")
    if not isinstance(dawn_receipt, dict) or not isinstance(doe_receipt, dict):
        raise ValueError("proof surface comparison receipts must include Dawn and Doe receipt artifacts")
    require_equal(comparison_receipt.get("dawnReceiptId"), dawn_receipt.get("receiptId"), "comparison Dawn receiptId")
    require_equal(comparison_receipt.get("doeReceiptId"), doe_receipt.get("receiptId"), "comparison Doe receiptId")


def build_receipt(
    *,
    receipt_id: str,
    observed_at: str,
    release_archive: Path,
    release_archive_url: str,
    release_archive_manifest: Path,
    proof_surface: Path,
    clean_install_check: Path | None,
    browser_product: dict[str, str],
    platform: dict[str, str],
    browser_executable_archive_path: str,
    browser_app_metadata_archive_path: str,
    doe_runtime_archive_path: str,
    dawn_fallback_runtime_archive_path: str,
    active_backend: str,
    proof_page_url: str,
    proof_page_artifact_path: str,
    proof_page_receipt_id: str,
    gallery_url: str,
    gallery_category: str,
    gallery_artifact_path: str,
    gallery_receipt_id: str,
    comparison_id: str,
    comparison_workload_id: str,
    comparison_page_artifact_path: str,
    comparison_artifact_path: str,
    comparison_dawn_receipt_id: str,
    comparison_doe_receipt_id: str,
    observed_receipt_ids: list[str],
) -> dict[str, Any]:
    require_non_empty(receipt_id, "receipt ID")
    require_non_empty(observed_at, "observedAt")
    validate_product(browser_product)
    validate_platform(platform)
    for value, label in (
        (browser_executable_archive_path, "browser executable archive path"),
        (browser_app_metadata_archive_path, "browser app metadata archive path"),
        (doe_runtime_archive_path, "Doe runtime archive path"),
        (dawn_fallback_runtime_archive_path, "Dawn fallback runtime archive path"),
        (active_backend, "active backend"),
        (proof_page_url, "proof page URL"),
        (proof_page_artifact_path, "proof page artifact path"),
        (proof_page_receipt_id, "proof page receipt ID"),
        (gallery_category, "gallery category"),
        (gallery_artifact_path, "gallery artifact path"),
        (gallery_receipt_id, "gallery receipt ID"),
        (comparison_id, "comparison ID"),
        (comparison_workload_id, "comparison workload ID"),
        (comparison_page_artifact_path, "comparison page artifact path"),
        (comparison_artifact_path, "comparison artifact path"),
        (comparison_dawn_receipt_id, "comparison Dawn receipt ID"),
        (comparison_doe_receipt_id, "comparison Doe receipt ID"),
    ):
        require_non_empty(value, label)
    if not is_public_https_url(gallery_url):
        raise ValueError("gallery URL must be public HTTPS")
    if gallery_category not in GALLERY_CATEGORIES:
        raise ValueError(f"gallery category must be one of {', '.join(GALLERY_CATEGORIES)}")
    if comparison_page_artifact_path != gallery_artifact_path:
        raise ValueError("comparison page artifact path must match loaded gallery artifact path")
    if not observed_receipt_ids or any(not isinstance(value, str) or not value for value in observed_receipt_ids):
        raise ValueError("at least one observed receipt ID is required")
    if len(set(observed_receipt_ids)) != len(observed_receipt_ids):
        raise ValueError("observed receipt IDs must be unique")
    if proof_page_receipt_id not in observed_receipt_ids:
        raise ValueError("observed receipt IDs must include proof page receipt ID")
    if gallery_receipt_id not in observed_receipt_ids:
        raise ValueError("observed receipt IDs must include gallery receipt ID")
    if comparison_dawn_receipt_id not in observed_receipt_ids:
        raise ValueError("observed receipt IDs must include comparison Dawn receipt ID")
    if comparison_doe_receipt_id not in observed_receipt_ids:
        raise ValueError("observed receipt IDs must include comparison Doe receipt ID")
    expected_observed_receipt_ids = {
        proof_page_receipt_id,
        gallery_receipt_id,
        comparison_dawn_receipt_id,
        comparison_doe_receipt_id,
    }
    if set(observed_receipt_ids) != expected_observed_receipt_ids:
        raise ValueError(
            "observed receipt IDs must exactly match proof page, gallery, Dawn, and Doe receipt IDs"
        )

    receipt = {
        "schemaVersion": 1,
        "artifactKind": "browser_release_launch_receipt",
        "receiptId": receipt_id,
        "observedAt": observed_at,
        "launchSource": "release_archive",
        "browserProduct": browser_product,
        "platform": platform,
        "releaseArchive": artifact(
            release_archive,
            "browser_release_archive",
            "release archive",
            download_url=release_archive_url,
        ),
        "releaseArchiveManifest": artifact(
            release_archive_manifest,
            "browser_release_archive_manifest",
            "release archive manifest",
        ),
        "proofSurface": artifact(
            proof_surface,
            "browser_published_proof_surface",
            "proof surface",
        ),
        "browserExecutableArchivePath": browser_executable_archive_path,
        "browserAppMetadataArchivePath": browser_app_metadata_archive_path,
        "doeRuntimeArchivePath": doe_runtime_archive_path,
        "dawnFallbackRuntimeArchivePath": dawn_fallback_runtime_archive_path,
        "runtimeMode": "doe",
        "activeRuntime": "doe",
        "activeBackend": active_backend,
        "hiddenFallbackAllowed": False,
        "hiddenFallbackUsed": False,
        "webgpuAvailable": True,
        "proofPage": {
            "url": proof_page_url,
            "loaded": True,
            "artifactPath": proof_page_artifact_path,
            "receiptId": proof_page_receipt_id,
        },
        "galleryPage": {
            "url": gallery_url,
            "loaded": True,
            "category": gallery_category,
            "artifactPath": gallery_artifact_path,
            "receiptId": gallery_receipt_id,
        },
        "comparisonReceipt": {
            "comparisonId": comparison_id,
            "workloadId": comparison_workload_id,
            "pageArtifactPath": comparison_page_artifact_path,
            "loaded": True,
            "executionScope": "same_page",
            "modes": ["dawn", "doe"],
            "emitsSideBySideReceipts": True,
            "comparisonArtifactPath": comparison_artifact_path,
            "dawnReceiptId": comparison_dawn_receipt_id,
            "doeReceiptId": comparison_doe_receipt_id,
        },
        "observedReceiptIds": observed_receipt_ids,
    }
    validate_receipt_against_release_archive_manifest(
        receipt,
        release_archive_manifest,
        release_archive,
    )
    validate_receipt_against_proof_surface(receipt, proof_surface)
    clean_install_artifact = validate_clean_install_check(
        clean_install_check,
        release_archive=release_archive,
        release_archive_manifest=release_archive_manifest,
        browser_product=browser_product,
        platform=platform,
    )
    if clean_install_artifact is not None:
        receipt["cleanInstallCheck"] = clean_install_artifact
    return receipt


def main() -> int:
    args = parse_args()
    try:
        receipt = build_receipt(
            receipt_id=args.receipt_id,
            observed_at=args.observed_at or observed_at_now(),
            release_archive=Path(args.release_archive),
            release_archive_url=args.release_archive_url,
            release_archive_manifest=Path(args.release_archive_manifest),
            proof_surface=Path(args.proof_surface),
            clean_install_check=Path(args.clean_install_check) if args.clean_install_check else None,
            browser_product={
                "productId": args.product_id,
                "displayName": args.product_name,
                "version": args.product_version,
                "channel": args.product_channel,
            },
            platform={
                "os": args.platform_os,
                "arch": args.platform_arch,
                "packageFormat": args.package_format,
            },
            browser_executable_archive_path=args.browser_executable_archive_path,
            browser_app_metadata_archive_path=args.browser_app_metadata_archive_path,
            doe_runtime_archive_path=args.doe_runtime_archive_path,
            dawn_fallback_runtime_archive_path=args.dawn_fallback_runtime_archive_path,
            active_backend=args.active_backend,
            proof_page_url=args.proof_page_url,
            proof_page_artifact_path=args.proof_page_artifact_path,
            proof_page_receipt_id=args.proof_page_receipt_id,
            gallery_url=args.gallery_url,
            gallery_category=args.gallery_category,
            gallery_artifact_path=args.gallery_artifact_path,
            gallery_receipt_id=args.gallery_receipt_id,
            comparison_id=args.comparison_id,
            comparison_workload_id=args.comparison_workload_id,
            comparison_page_artifact_path=args.comparison_page_artifact_path,
            comparison_artifact_path=args.comparison_artifact_path,
            comparison_dawn_receipt_id=args.comparison_dawn_receipt_id,
            comparison_doe_receipt_id=args.comparison_doe_receipt_id,
            observed_receipt_ids=args.observed_receipt_id,
        )
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
