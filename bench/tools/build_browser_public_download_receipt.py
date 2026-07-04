#!/usr/bin/env python3
"""Build browser public download receipts from hosted archive bytes."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import sys
import urllib.error
import urllib.request
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
PACKAGE_FORMATS = ("zip",)
HEX_DIGITS = frozenset("0123456789abcdef")
MANIFEST_MEMBER_PATH_BINDINGS = (
    ("browserExecutable", "browserExecutableArchivePath", "browser executable archive path"),
    ("appMetadata", "browserAppMetadataArchivePath", "browser app metadata archive path"),
    ("doeRuntime", "doeRuntimeArchivePath", "Doe runtime archive path"),
    ("dawnFallbackRuntime", "dawnFallbackRuntimeArchivePath", "Dawn fallback runtime archive path"),
)


@dataclass(frozen=True)
class DownloadResult:
    status_code: int
    content: bytes


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--receipt-id", required=True)
    parser.add_argument("--release-archive", default="")
    parser.add_argument("--release-archive-path", default="")
    parser.add_argument("--release-archive-manifest", required=True)
    parser.add_argument("--release-archive-manifest-path", default="")
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
    parser.add_argument("--observed-at", default="")
    parser.add_argument("--out", required=True)
    return parser.parse_args()


def repo_relative(path: Path) -> str:
    resolved = path.resolve()
    try:
        return str(resolved.relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def observed_at_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def fetch_url(url: str) -> DownloadResult:
    request = urllib.request.Request(
        url,
        method="GET",
        headers={"User-Agent": "DoeBrowserPublicDownloadReceipt/1"},
    )
    try:
        with urllib.request.urlopen(request) as response:
            return DownloadResult(
                status_code=int(response.getcode()),
                content=response.read(),
            )
    except urllib.error.HTTPError as exc:
        return DownloadResult(status_code=int(exc.code), content=exc.read())


def require_non_empty(value: Any, label: str) -> None:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{label} is required")


def require_choice(value: Any, label: str, choices: tuple[str, ...]) -> str:
    require_non_empty(value, label)
    if value not in choices:
        raise ValueError(f"{label} must be one of {', '.join(choices)}")
    return value


def require_hash(value: Any, label: str) -> None:
    require_non_empty(value, label)
    if len(value) != 64 or any(char not in HEX_DIGITS for char in value):
        raise ValueError(f"{label} must be a lowercase SHA-256 hash")


def validate_product(browser_product: dict[str, str]) -> None:
    if not isinstance(browser_product, dict):
        raise ValueError("browser product identity is required")
    product_id = require_choice(
        browser_product.get("productId"),
        "browser product productId",
        tuple(PRODUCT_DISPLAY_NAMES),
    )
    display_name = require_choice(
        browser_product.get("displayName"),
        "browser product displayName",
        tuple(PRODUCT_DISPLAY_NAMES.values()),
    )
    require_non_empty(browser_product.get("version"), "browser product version")
    require_choice(browser_product.get("channel"), "browser product channel", PRODUCT_CHANNELS)
    expected_name = PRODUCT_DISPLAY_NAMES[product_id]
    if display_name != expected_name:
        raise ValueError(
            f"product-name must be {expected_name!r} for product-id {product_id!r}"
        )


def validate_platform(platform: dict[str, str]) -> None:
    if not isinstance(platform, dict):
        raise ValueError("platform identity is required")
    require_choice(platform.get("os"), "platform os", PLATFORM_OS)
    require_choice(platform.get("arch"), "platform arch", PLATFORM_ARCH)
    require_choice(platform.get("packageFormat"), "platform packageFormat", PACKAGE_FORMATS)


def validate_expected_archive(download: DownloadResult, expected_archive: Path | None) -> None:
    if expected_archive is None:
        return
    if not expected_archive.is_file():
        raise FileNotFoundError(f"release archive must be an existing file: {expected_archive}")
    expected_hash = sha256_file(expected_archive)
    actual_hash = sha256_bytes(download.content)
    if actual_hash != expected_hash:
        raise ValueError(
            f"downloaded archive sha256 {actual_hash} does not match {expected_archive}"
        )
    expected_size = expected_archive.stat().st_size
    actual_size = len(download.content)
    if actual_size != expected_size:
        raise ValueError(
            f"downloaded archive byte length {actual_size} does not match {expected_archive}"
        )


def load_json_object(path: Path, label: str) -> dict[str, Any]:
    if not path.is_file():
        raise FileNotFoundError(f"{label} must be an existing file: {path}")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ValueError(f"{label} must be valid JSON: {exc}") from exc
    if not isinstance(payload, dict):
        raise ValueError(f"{label} must be a JSON object")
    return payload


def require_manifest_equal(actual: Any, expected: Any, label: str) -> None:
    if actual != expected:
        raise ValueError(f"{label} must match public download receipt")


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
    release_archive_manifest: Path | None,
) -> None:
    if release_archive_manifest is None:
        return
    actual_manifest_sha = sha256_file(release_archive_manifest)
    require_manifest_equal(
        actual_manifest_sha,
        receipt.get("releaseArchiveManifestSha256"),
        "release archive manifest sha256",
    )
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
    for key, receipt_field in (
        ("path", "releaseArchivePath"),
        ("sha256", "contentSha256"),
    ):
        require_manifest_equal(
            archive.get(key),
            receipt.get(receipt_field),
            f"release archive manifest archive.{key}",
        )
    require_manifest_equal(
        archive.get("byteLength"),
        receipt.get("contentLengthBytes"),
        "release archive manifest archive.byteLength",
    )
    require_manifest_equal(
        archive.get("kind"),
        "browser_release_archive",
        "release archive manifest archive.kind",
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


def build_receipt(
    *,
    receipt_id: str,
    url: str,
    download: DownloadResult,
    release_archive_path: str,
    release_archive_manifest_path: str,
    release_archive_manifest_sha256: str,
    browser_product: dict[str, str],
    platform: dict[str, str],
    browser_executable_archive_path: str,
    browser_app_metadata_archive_path: str,
    doe_runtime_archive_path: str,
    dawn_fallback_runtime_archive_path: str,
    observed_at: str,
    expected_archive: Path | None = None,
    release_archive_manifest: Path | None = None,
) -> dict[str, Any]:
    require_non_empty(receipt_id, "receipt ID")
    require_non_empty(release_archive_path, "release archive path")
    require_non_empty(release_archive_manifest_path, "release archive manifest path")
    require_hash(release_archive_manifest_sha256, "release archive manifest sha256")
    require_non_empty(browser_executable_archive_path, "browser executable archive path")
    require_non_empty(browser_app_metadata_archive_path, "browser app metadata archive path")
    require_non_empty(doe_runtime_archive_path, "Doe runtime archive path")
    require_non_empty(dawn_fallback_runtime_archive_path, "Dawn fallback runtime archive path")
    require_non_empty(observed_at, "observedAt")
    if not is_public_https_url(url):
        raise ValueError("public download URL must be public HTTPS")
    if download.status_code != 200:
        raise ValueError(f"public download GET returned status {download.status_code}")
    if not download.content:
        raise ValueError("public download content must not be empty")
    validate_product(browser_product)
    validate_platform(platform)
    validate_expected_archive(download, expected_archive)
    receipt = {
        "schemaVersion": 1,
        "artifactKind": "browser_public_download_receipt",
        "receiptId": receipt_id,
        "url": url,
        "method": "GET",
        "statusCode": download.status_code,
        "contentSha256": sha256_bytes(download.content),
        "contentLengthBytes": len(download.content),
        "releaseArchivePath": release_archive_path,
        "releaseArchiveManifestPath": release_archive_manifest_path,
        "releaseArchiveManifestSha256": release_archive_manifest_sha256,
        "browserProduct": browser_product,
        "platform": platform,
        "browserExecutableArchivePath": browser_executable_archive_path,
        "browserAppMetadataArchivePath": browser_app_metadata_archive_path,
        "doeRuntimeArchivePath": doe_runtime_archive_path,
        "dawnFallbackRuntimeArchivePath": dawn_fallback_runtime_archive_path,
        "observedAt": observed_at,
    }
    validate_receipt_against_release_archive_manifest(receipt, release_archive_manifest)
    return receipt


def release_archive_path_arg(args: argparse.Namespace) -> tuple[str, Path | None]:
    expected_archive = Path(args.release_archive) if args.release_archive else None
    if args.release_archive_path:
        return args.release_archive_path, expected_archive
    if expected_archive is not None:
        return repo_relative(expected_archive), expected_archive
    raise ValueError("--release-archive-path is required when --release-archive is omitted")


def release_archive_manifest_path_arg(args: argparse.Namespace) -> tuple[str, Path]:
    manifest = Path(args.release_archive_manifest)
    if not manifest.is_file():
        raise FileNotFoundError(
            f"release archive manifest must be an existing file: {manifest}"
        )
    if args.release_archive_manifest_path:
        return args.release_archive_manifest_path, manifest
    return repo_relative(manifest), manifest


def main() -> int:
    args = parse_args()
    try:
        release_archive_path, expected_archive = release_archive_path_arg(args)
        release_archive_manifest_path, release_archive_manifest = (
            release_archive_manifest_path_arg(args)
        )
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
        receipt = build_receipt(
            receipt_id=args.receipt_id,
            url=args.url,
            download=fetch_url(args.url),
            release_archive_path=release_archive_path,
            release_archive_manifest_path=release_archive_manifest_path,
            release_archive_manifest_sha256=sha256_file(release_archive_manifest),
            browser_product=browser_product,
            platform=platform,
            browser_executable_archive_path=args.browser_executable_archive_path,
            browser_app_metadata_archive_path=args.browser_app_metadata_archive_path,
            doe_runtime_archive_path=args.doe_runtime_archive_path,
            dawn_fallback_runtime_archive_path=args.dawn_fallback_runtime_archive_path,
            observed_at=args.observed_at or observed_at_now(),
            expected_archive=expected_archive,
            release_archive_manifest=release_archive_manifest,
        )
        out_path = Path(args.out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    except Exception as exc:
        sys.stderr.write(f"build_browser_public_download_receipt: {exc}\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
