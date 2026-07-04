#!/usr/bin/env python3
"""Build browser proof page diagnostic receipts from captured page artifacts."""

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
RELEASE_CHANNELS = {"release_candidate", "release"}
PROOF_DIAGNOSTIC_STATUS_FIELDS = ("tsirStatus", "hostPlanStatus", "cslStatus")
NON_RELEASE_DIAGNOSTIC_STATUS_VALUES = {
    "diagnostic",
    "placeholder",
    "sample",
    "tbd",
    "todo",
    "unknown",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--receipt-id", required=True)
    parser.add_argument("--url", default="about:doe")
    parser.add_argument("--proof-artifact", required=True)
    parser.add_argument("--proof-artifact-path", default="")
    parser.add_argument("--runtime-identity-path", required=True)
    parser.add_argument("--active-backend", required=True)
    parser.add_argument("--compiler-path", required=True)
    parser.add_argument("--tsir-status", required=True)
    parser.add_argument("--host-plan-status", required=True)
    parser.add_argument("--csl-status", required=True)
    parser.add_argument("--release-archive", required=True)
    parser.add_argument("--release-archive-url", required=True)
    parser.add_argument("--release-archive-manifest", required=True)
    parser.add_argument("--public-download-receipt", required=True)
    parser.add_argument("--product-id", choices=tuple(PRODUCT_DISPLAY_NAMES), default="fawn-doe")
    parser.add_argument("--product-name", choices=tuple(PRODUCT_DISPLAY_NAMES.values()), default="Fawn Doe")
    parser.add_argument("--product-version", required=True)
    parser.add_argument(
        "--product-channel",
        choices=("diagnostic", "release_candidate", "release"),
        required=True,
    )
    parser.add_argument("--platform-os", choices=("macos", "linux", "windows"), required=True)
    parser.add_argument("--platform-arch", choices=("arm64", "x64"), required=True)
    parser.add_argument("--package-format", choices=("zip",), default="zip")
    parser.add_argument("--browser-executable-archive-path", required=True)
    parser.add_argument("--browser-app-metadata-archive-path", required=True)
    parser.add_argument("--doe-runtime-archive-path", required=True)
    parser.add_argument("--dawn-fallback-runtime-archive-path", required=True)
    parser.add_argument("--recent-receipt-id", action="append", required=True)
    parser.add_argument("--observed-at", default="")
    parser.add_argument("--out", required=True)
    return parser.parse_args()


def repo_relative(path: Path) -> str:
    resolved = path.resolve()
    try:
        return str(resolved.relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def require_file(path: Path, label: str) -> None:
    if not path.is_file():
        raise FileNotFoundError(f"{label} must be an existing file: {path}")


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def observed_at_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def infer_load_type(url: str) -> str:
    if url == "about:doe" or url.startswith("chrome://"):
        return "browser_internal_page"
    if url.startswith("file:"):
        return "file"
    raise ValueError("proof page URL must be about:doe, chrome://, or file:")


def validate_product(product_id: str, display_name: str) -> None:
    expected_name = PRODUCT_DISPLAY_NAMES[product_id]
    if display_name != expected_name:
        raise ValueError(
            f"product-name must be {expected_name!r} for product-id {product_id!r}"
        )


def artifact(path: Path, kind: str, *, download_url: str = "") -> dict[str, str]:
    require_file(path, kind)
    payload = {
        "path": repo_relative(path),
        "sha256": sha256_file(path),
        "kind": kind,
    }
    if download_url:
        if not is_public_https_url(download_url):
            raise ValueError("release archive URL must be public HTTPS")
        payload["downloadUrl"] = download_url
    return payload


def build_release_provenance(
    *,
    release_archive: Path,
    release_archive_url: str,
    release_archive_manifest: Path,
    public_download_receipt: Path,
    browser_product: dict[str, str],
    platform: dict[str, str],
    browser_executable_archive_path: str,
    browser_app_metadata_archive_path: str,
    doe_runtime_archive_path: str,
    dawn_fallback_runtime_archive_path: str,
) -> dict[str, Any]:
    validate_product(browser_product["productId"], browser_product["displayName"])
    return {
        "browserProduct": browser_product,
        "platform": platform,
        "releaseArchive": artifact(
            release_archive,
            "browser_release_archive",
            download_url=release_archive_url,
        ),
        "releaseArchiveManifest": artifact(
            release_archive_manifest,
            "browser_release_archive_manifest",
        ),
        "publicDownloadReceipt": artifact(
            public_download_receipt,
            "browser_public_download_receipt",
        ),
        "browserExecutableArchivePath": browser_executable_archive_path,
        "browserAppMetadataArchivePath": browser_app_metadata_archive_path,
        "doeRuntimeArchivePath": doe_runtime_archive_path,
        "dawnFallbackRuntimeArchivePath": dawn_fallback_runtime_archive_path,
    }


def release_provenance_visible_fragments(
    provenance: dict[str, Any],
) -> list[tuple[str, str]]:
    fragments: list[tuple[str, str]] = []
    product = provenance.get("browserProduct")
    if isinstance(product, dict):
        for field, label in (
            ("displayName", "browser product"),
            ("version", "browser version"),
            ("channel", "release channel"),
        ):
            value = product.get(field)
            if isinstance(value, str) and value:
                fragments.append((label, value))
    platform = provenance.get("platform")
    if isinstance(platform, dict):
        for field, label in (
            ("os", "platform OS"),
            ("arch", "platform architecture"),
            ("packageFormat", "package format"),
        ):
            value = platform.get(field)
            if isinstance(value, str) and value:
                fragments.append((label, value))
    for field, label in (
        ("browserExecutableArchivePath", "browser executable member"),
        ("browserAppMetadataArchivePath", "app metadata member"),
        ("doeRuntimeArchivePath", "Doe runtime member"),
        ("dawnFallbackRuntimeArchivePath", "Dawn fallback runtime member"),
    ):
        value = provenance.get(field)
        if isinstance(value, str) and value:
            fragments.append((label, value))
    for field, label in (
        ("releaseArchive", "release archive"),
        ("releaseArchiveManifest", "release archive manifest"),
        ("publicDownloadReceipt", "public download receipt"),
    ):
        artifact_payload = provenance.get(field)
        if not isinstance(artifact_payload, dict):
            continue
        for key in ("path", "sha256", "downloadUrl"):
            value = artifact_payload.get(key)
            if isinstance(value, str) and value:
                fragments.append((label, value))
    return fragments


def diagnostic_visible_fragment(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    return value if isinstance(value, str) else ""


def validate_visible_proof_page_content(
    *,
    proof_artifact: Path,
    diagnostics: dict[str, Any],
    release_provenance: dict[str, Any],
    recent_receipt_ids: list[str],
) -> None:
    try:
        text = proof_artifact.read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:
        raise ValueError("proof page artifact must be UTF-8 text") from exc
    required_fragments: list[tuple[str, str]] = []
    for field, value in diagnostics.items():
        fragment = diagnostic_visible_fragment(value)
        if fragment:
            required_fragments.append((f"diagnostic {field}", fragment))
    required_fragments.extend(
        release_provenance_visible_fragments(release_provenance)
    )
    required_fragments.extend(
        ("recent receipt ID", value)
        for value in recent_receipt_ids
        if isinstance(value, str) and value
    )
    for label, fragment in required_fragments:
        if fragment not in text:
            raise ValueError(f"proof page artifact must show {label}: {fragment}")


def validate_release_diagnostic_statuses(
    diagnostics: dict[str, Any],
    release_provenance: dict[str, Any],
) -> None:
    product = release_provenance.get("browserProduct")
    channel = product.get("channel") if isinstance(product, dict) else None
    if channel not in RELEASE_CHANNELS:
        return
    for field in PROOF_DIAGNOSTIC_STATUS_FIELDS:
        value = diagnostics.get(field)
        if not isinstance(value, str) or value.lower() in NON_RELEASE_DIAGNOSTIC_STATUS_VALUES:
            raise ValueError(
                f"release proof page diagnostics {field} must be concrete"
            )


def build_receipt(
    *,
    receipt_id: str,
    url: str,
    proof_artifact: Path,
    proof_artifact_path: str,
    runtime_identity_path: str,
    diagnostics: dict[str, Any],
    release_provenance: dict[str, Any],
    recent_receipt_ids: list[str],
    observed_at: str,
) -> dict[str, Any]:
    require_file(proof_artifact, "proof artifact")
    if not recent_receipt_ids:
        raise ValueError("at least one recent receipt ID is required")
    if diagnostics.get("activeRuntime") != "doe":
        raise ValueError("proof page diagnostics must report activeRuntime=doe")
    if diagnostics.get("webgpuAvailable") is not True:
        raise ValueError("proof page diagnostics must report webgpuAvailable=true")
    if diagnostics.get("fallbackPolicyState") != "hidden_fallback_disabled":
        raise ValueError(
            "proof page diagnostics must report hidden_fallback_disabled fallback policy"
        )
    validate_release_diagnostic_statuses(diagnostics, release_provenance)
    validate_visible_proof_page_content(
        proof_artifact=proof_artifact,
        diagnostics=diagnostics,
        release_provenance=release_provenance,
        recent_receipt_ids=recent_receipt_ids,
    )
    return {
        "schemaVersion": 1,
        "artifactKind": "browser_proof_page_receipt",
        "receiptId": receipt_id,
        "url": url,
        "loadType": infer_load_type(url),
        "status": "loaded",
        "contentSha256": sha256_file(proof_artifact),
        "contentLengthBytes": proof_artifact.stat().st_size,
        "proofArtifactPath": proof_artifact_path,
        "runtimeIdentityPath": runtime_identity_path,
        "diagnostics": diagnostics,
        "releaseProvenance": release_provenance,
        "recentReceiptIds": recent_receipt_ids,
        "observedAt": observed_at,
    }


def diagnostics_from_args(args: argparse.Namespace) -> dict[str, Any]:
    return {
        "activeRuntime": "doe",
        "activeBackend": args.active_backend,
        "webgpuAvailable": True,
        "compilerPath": args.compiler_path,
        "tsirStatus": args.tsir_status,
        "hostPlanStatus": args.host_plan_status,
        "cslStatus": args.csl_status,
        "fallbackPolicyState": "hidden_fallback_disabled",
    }


def main() -> int:
    args = parse_args()
    try:
        proof_artifact = Path(args.proof_artifact)
        proof_artifact_path = args.proof_artifact_path or repo_relative(proof_artifact)
        browser_product = {
            "productId": args.product_id,
            "displayName": args.product_name,
            "version": args.product_version,
            "channel": args.product_channel,
        }
        platform = {
            "os": args.platform_os,
            "arch": args.platform_arch,
            "packageFormat": args.package_format,
        }
        release_provenance = build_release_provenance(
            release_archive=Path(args.release_archive),
            release_archive_url=args.release_archive_url,
            release_archive_manifest=Path(args.release_archive_manifest),
            public_download_receipt=Path(args.public_download_receipt),
            browser_product=browser_product,
            platform=platform,
            browser_executable_archive_path=args.browser_executable_archive_path,
            browser_app_metadata_archive_path=args.browser_app_metadata_archive_path,
            doe_runtime_archive_path=args.doe_runtime_archive_path,
            dawn_fallback_runtime_archive_path=args.dawn_fallback_runtime_archive_path,
        )
        receipt = build_receipt(
            receipt_id=args.receipt_id,
            url=args.url,
            proof_artifact=proof_artifact,
            proof_artifact_path=proof_artifact_path,
            runtime_identity_path=args.runtime_identity_path,
            diagnostics=diagnostics_from_args(args),
            release_provenance=release_provenance,
            recent_receipt_ids=args.recent_receipt_id,
            observed_at=args.observed_at or observed_at_now(),
        )
        out_path = Path(args.out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    except Exception as exc:
        sys.stderr.write(f"build_browser_proof_page_receipt: {exc}\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
