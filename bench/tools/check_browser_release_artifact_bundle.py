#!/usr/bin/env python3
"""Check browser release artifact bundle completeness."""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import sys
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any

try:
    from bench.tools._repo_import import ensure_repo_root
except ModuleNotFoundError:
    from _repo_import import ensure_repo_root

REPO_ROOT = ensure_repo_root(__file__)
from bench.lib.bench_utils import load_json_object as load_json

try:
    from bench.tools import check_browser_claim_promotion_receipt as promotion_check
except ModuleNotFoundError:
    import check_browser_claim_promotion_receipt as promotion_check  # type: ignore

try:
    from bench.tools import check_browser_published_proof_surface as proof_surface_check
except ModuleNotFoundError:
    import check_browser_published_proof_surface as proof_surface_check  # type: ignore

try:
    from bench.tools._public_url import is_public_https_url
except ModuleNotFoundError:
    from _public_url import is_public_https_url
try:
    from bench.tools.browser_release_archive_manifest import check_release_archive_manifest_artifact
except ModuleNotFoundError:
    from browser_release_archive_manifest import check_release_archive_manifest_artifact  # type: ignore

try:
    from bench.tools import check_browser_release_package_inputs as package_inputs_check
except ModuleNotFoundError:
    import check_browser_release_package_inputs as package_inputs_check  # type: ignore
try:
    from bench.tools.check_browser_release_package_inputs import detect_file_identity_bytes
except ModuleNotFoundError:
    from check_browser_release_package_inputs import detect_file_identity_bytes  # type: ignore


REQUIRED_CONTRACT_KINDS = {"contract"}
REQUIRED_CLAIM_KINDS = {"browser_claim_report"}
REQUIRED_PROMOTION_RECEIPT_KINDS = {"browser_claim_promotion_receipt"}
REQUIRED_POLICY_KINDS = {
    "runtime_selector_policy", "fork_maintenance_policy", "chromium_patch_manifest",
    "browser_claim_policy", "browser_capture_policy", "browser_artifact_identity_coverage",
    "browser_unsupported_reason_taxonomy",
}
ALLOWED_PLATFORM_OS = {"macos", "linux", "windows"}
ALLOWED_PLATFORM_ARCH = {"arm64", "x64"}
ALLOWED_PACKAGE_FORMATS = {"zip"}
ALLOWED_BROWSER_PRODUCTS = {
    "doe-browser": "Doe Browser",
    "fawn-doe": "Fawn Doe",
}
ALLOWED_BROWSER_PRODUCT_BUNDLE_IDS = {"doe-browser": "dev.doe.doe-browser", "fawn-doe": "dev.doe.fawn-doe"}
ALLOWED_PRODUCT_CHANNELS = {"diagnostic", "release_candidate", "release"}
BROWSER_RELEASE_ARTIFACT_KIND = "browser_release_artifact_bundle"
PROMOTION_RECEIPT_CLAIM_FAILURE_CODES = {
    "artifact_not_forced_doe", "hidden_fallback_used", "claim_policy_not_passed",
    "hidden_fallback_check_failed", "promotable_receipt_has_failures",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", required=True, help="Browser release artifact bundle JSON.")
    parser.add_argument(
        "--verify-files-root",
        default="",
        help="Resolve relative artifact paths under this root and verify sha256 values.",
    )
    parser.add_argument(
        "--require-release-candidate",
        action="store_true",
        help="Require releaseStatus=release_candidate and verified artifact files.",
    )
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def failure(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def resolve_artifact_path(path_text: str, verify_files_root: Path) -> Path | None:
    root = verify_files_root.resolve()
    path = Path(path_text)
    candidate = path if path.is_absolute() else root.joinpath(*PurePosixPath(path_text).parts)
    resolved = candidate.resolve()
    try:
        resolved.relative_to(root)
    except ValueError:
        return None
    return resolved


def safe_archive_member_path(path_text: str) -> bool:
    path = PurePosixPath(path_text)
    raw_parts = path_text.split("/")
    return (
        bool(path_text)
        and not path.is_absolute()
        and "\\" not in path_text
        and not any(part in ("", ".", "..") for part in raw_parts)
    )


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def release_bundle_identity_sha256(payload: dict[str, Any]) -> str:
    projection = {
        key: value
        for key, value in payload.items()
        if key != "runtimeFrontierBundle"
    }
    encoded = json.dumps(
        projection,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def artifact_field(payload: dict[str, Any], field: str, key: str) -> Any:
    artifact = payload.get(field)
    return artifact.get(key) if isinstance(artifact, dict) else None


def check_release_bundle_identity(payload: dict[str, Any]) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    if payload.get("schemaVersion") != 1:
        failures.append(
            failure(
                "invalid_release_bundle_schema_version",
                "schemaVersion",
                "browser release artifact bundle schemaVersion must be 1",
            )
        )
    if payload.get("artifactKind") != BROWSER_RELEASE_ARTIFACT_KIND:
        failures.append(
            failure(
                "invalid_release_bundle_artifact_kind",
                "artifactKind",
                "browser release artifact bundle artifactKind must be browser_release_artifact_bundle",
            )
        )
    return failures


def artifact_path_matches(path_text: str, candidates: set[str], root: Path) -> bool:
    resolved = resolve_artifact_path(path_text, root)
    for candidate in candidates:
        if path_text == candidate:
            return True
        candidate_resolved = resolve_artifact_path(candidate, root)
        if (
            resolved is not None
            and candidate_resolved is not None
            and resolved == candidate_resolved
        ):
            return True
    return False


def check_artifact(
    artifact: Any,
    path: str,
    expected_kind: str | None = None,
    verify_files_root: Path | None = None,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    if not isinstance(artifact, dict):
        return [failure("invalid_artifact", path, "artifact must be object")]
    if expected_kind is not None and artifact.get("kind") != expected_kind:
        failures.append(failure("wrong_artifact_kind", f"{path}.kind", f"expected {expected_kind}"))
    artifact_path = artifact.get("path")
    artifact_hash = artifact.get("sha256")
    if not artifact_path:
        failures.append(failure("missing_artifact_path", f"{path}.path", "artifact path is required"))
    if not isinstance(artifact_hash, str) or len(artifact_hash) != 64:
        failures.append(failure("missing_artifact_hash", f"{path}.sha256", "artifact sha256 is required"))
    if verify_files_root is not None and isinstance(artifact_path, str) and isinstance(artifact_hash, str):
        resolved_path = resolve_artifact_path(artifact_path, verify_files_root)
        if resolved_path is None:
            failures.append(
                failure(
                    "unsafe_artifact_path",
                    f"{path}.path",
                    f"artifact path must resolve under verify-files-root: {artifact_path}",
                )
            )
            return failures
        if not resolved_path.is_file():
            failures.append(failure("artifact_file_missing", f"{path}.path", f"artifact file not found: {artifact_path}"))
        else:
            actual_hash = sha256_file(resolved_path)
            if actual_hash != artifact_hash:
                failures.append(
                    failure(
                        "artifact_hash_mismatch",
                        f"{path}.sha256",
                        f"expected {actual_hash} for {artifact_path}",
                    )
                )
    return failures


def check_platform(platform: Any, path: str) -> list[dict[str, str]]:
    if not isinstance(platform, dict):
        return [failure("invalid_platform", path, "platform must be object")]
    failures: list[dict[str, str]] = []
    os_name = platform.get("os")
    arch = platform.get("arch")
    package_format = platform.get("packageFormat")
    if os_name not in ALLOWED_PLATFORM_OS:
        failures.append(
            failure(
                "invalid_platform_os",
                f"{path}.os",
                f"platform os must be one of {sorted(ALLOWED_PLATFORM_OS)}",
            )
        )
    if arch not in ALLOWED_PLATFORM_ARCH:
        failures.append(
            failure(
                "invalid_platform_arch",
                f"{path}.arch",
                f"platform arch must be one of {sorted(ALLOWED_PLATFORM_ARCH)}",
            )
        )
    if package_format not in ALLOWED_PACKAGE_FORMATS:
        failures.append(
            failure(
                "invalid_package_format",
                f"{path}.packageFormat",
                f"packageFormat must be one of {sorted(ALLOWED_PACKAGE_FORMATS)}",
            )
        )
    return failures


def check_browser_product(
    product: Any,
    path: str,
    *,
    release_status: Any = None,
) -> list[dict[str, str]]:
    if not isinstance(product, dict):
        return [failure("invalid_browser_product", path, "browserProduct must be object")]
    failures: list[dict[str, str]] = []
    product_id = product.get("productId")
    display_name = product.get("displayName")
    version = product.get("version")
    channel = product.get("channel")
    if product_id not in ALLOWED_BROWSER_PRODUCTS:
        failures.append(
            failure(
                "invalid_browser_product_id",
                f"{path}.productId",
                f"browser productId must be one of {sorted(ALLOWED_BROWSER_PRODUCTS)}",
            )
        )
    elif display_name != ALLOWED_BROWSER_PRODUCTS[product_id]:
        failures.append(
            failure(
                "browser_product_name_mismatch",
                f"{path}.displayName",
                f"browser product displayName must be {ALLOWED_BROWSER_PRODUCTS[product_id]}",
            )
        )
    if not isinstance(display_name, str) or not display_name:
        failures.append(
            failure(
                "missing_browser_product_display_name",
                f"{path}.displayName",
                "browser product displayName is required",
            )
        )
    if not isinstance(version, str) or not version:
        failures.append(
            failure(
                "missing_browser_product_version",
                f"{path}.version",
                "browser product version is required",
            )
        )
    if channel not in ALLOWED_PRODUCT_CHANNELS:
        failures.append(
            failure(
                "invalid_browser_product_channel",
                f"{path}.channel",
                f"browser product channel must be one of {sorted(ALLOWED_PRODUCT_CHANNELS)}",
            )
        )
    elif release_status in {"diagnostic", "release_candidate"} and channel != release_status:
        failures.append(
            failure(
                "browser_product_channel_mismatch",
                f"{path}.channel",
                "browser product channel must match releaseStatus",
            )
        )
    return failures


def check_browser_product_identity(
    payload: dict[str, Any],
    *,
    require_release_candidate: bool,
) -> list[dict[str, str]]:
    product = payload.get("browserProduct")
    requires_product = (
        require_release_candidate
        or payload.get("releaseStatus") == "release_candidate"
        or payload.get("releaseArchive") is not None
    )
    if product is None:
        if not requires_product:
            return []
        return [
            failure(
                "missing_browser_product",
                "browserProduct",
                "downloadable browser artifacts must declare Doe Browser or Fawn Doe identity",
            )
        ]
    return check_browser_product(product, "browserProduct", release_status=payload.get("releaseStatus"))


def check_zip_archive(
    artifact: Any,
    platform: Any,
    verify_files_root: Path | None,
) -> list[dict[str, str]]:
    if verify_files_root is None:
        return []
    if not isinstance(artifact, dict) or not isinstance(platform, dict):
        return []
    if platform.get("packageFormat") != "zip":
        return []
    artifact_path = artifact.get("path")
    if not isinstance(artifact_path, str) or not artifact_path:
        return []
    resolved_path = resolve_artifact_path(artifact_path, verify_files_root)
    if resolved_path is None or not resolved_path.is_file():
        return []
    if not zipfile.is_zipfile(resolved_path):
        return [
            failure(
                "invalid_release_archive_zip",
                "releaseArchive.path",
                f"release archive is not a valid zip file: {artifact_path}",
            )
        ]
    try:
        with zipfile.ZipFile(resolved_path) as archive:
            bad_member = archive.testzip()
    except zipfile.BadZipFile:
        return [
            failure(
                "invalid_release_archive_zip",
                "releaseArchive.path",
                f"release archive is not a valid zip file: {artifact_path}",
            )
        ]
    if bad_member is not None:
        return [
            failure(
                "corrupt_release_archive_zip_member",
                "releaseArchive.path",
                f"release archive zip member failed integrity check: {bad_member}",
            )
        ]
    return []


def check_unique_release_archive_member_paths(payload: dict[str, Any]) -> list[dict[str, str]]:
    member_fields = (
        ("browserExecutableArchivePath", "browser executable"),
        ("browserAppMetadataArchivePath", "browser app metadata"),
        ("doeRuntimeArchivePath", "Doe runtime"),
        ("dawnFallbackRuntimeArchivePath", "Dawn fallback runtime"),
    )
    failures: list[dict[str, str]] = []
    seen: dict[str, tuple[str, str]] = {}
    for field, label in member_fields:
        member_path = payload.get(field)
        if not isinstance(member_path, str) or not member_path:
            continue
        previous = seen.get(member_path)
        if previous is not None:
            previous_field, previous_label = previous
            failures.append(
                failure(
                    "duplicate_release_archive_member_path",
                    field,
                    (
                        f"{label} archive path duplicates {previous_label} "
                        f"archive path from {previous_field}"
                    ),
                )
            )
            continue
        seen[member_path] = (field, label)
    return failures


def check_initial_release_candidate_platform(platform: Any) -> list[dict[str, str]]:
    if not isinstance(platform, dict) or (platform.get("os"), platform.get("arch"), platform.get("packageFormat")) == ("macos", "arm64", "zip"):
        return []
    return [failure("release_candidate_platform_not_macos_arm64", "platform", "initial release candidates must target macOS arm64 zip")]


def check_archive_member_matches_artifact(
    payload: dict[str, Any],
    verify_files_root: Path | None,
    *,
    artifact_field: str,
    member_path_field: str,
    label: str,
    missing_code: str,
    missing_message: str,
    unsafe_code: str,
    member_missing_code: str,
    member_directory_code: str,
    member_not_executable_code: str | None = None,
    hash_mismatch_code: str,
    require_executable: bool = False,
) -> list[dict[str, str]]:
    release_archive = payload.get("releaseArchive")
    artifact = payload.get(artifact_field)
    member_path = payload.get(member_path_field)
    failures: list[dict[str, str]] = []
    if not isinstance(member_path, str) or not member_path:
        return [
            failure(
                missing_code,
                member_path_field,
                missing_message,
            )
        ]
    if not safe_archive_member_path(member_path):
        return [
            failure(
                unsafe_code,
                member_path_field,
                f"{label} archive path must be relative and safe: {member_path}",
            )
        ]
    if (
        verify_files_root is None
        or not isinstance(release_archive, dict)
        or not isinstance(artifact, dict)
    ):
        return failures
    artifact_path = release_archive.get("path")
    expected_hash = artifact.get("sha256")
    if not isinstance(artifact_path, str) or not artifact_path:
        return failures
    if not isinstance(expected_hash, str) or len(expected_hash) != 64:
        return failures
    resolved_path = resolve_artifact_path(artifact_path, verify_files_root)
    if resolved_path is None or not resolved_path.is_file() or not zipfile.is_zipfile(resolved_path):
        return failures
    try:
        with zipfile.ZipFile(resolved_path) as archive:
            try:
                info = archive.getinfo(member_path)
            except KeyError:
                return [
                    failure(
                        member_missing_code,
                        member_path_field,
                        f"{label} archive member not found: {member_path}",
                    )
                ]
            if info.is_dir():
                return [
                    failure(
                        member_directory_code,
                        member_path_field,
                        f"{label} archive member is a directory: {member_path}",
                    )
                ]
            if require_executable:
                mode = (info.external_attr >> 16) & 0o777
                if not mode & 0o100:
                    return [
                        failure(
                            member_not_executable_code
                            or "archive_member_not_executable",
                            member_path_field,
                            f"{label} archive member is not executable: {member_path}",
                        )
                    ]
            member_hash = hashlib.sha256(archive.read(info)).hexdigest()
    except zipfile.BadZipFile:
        return failures
    if member_hash != expected_hash:
        failures.append(
            failure(
                hash_mismatch_code,
                f"{artifact_field}.sha256",
                f"{label} archive member hash is {member_hash} for {member_path}",
            )
        )
    return failures


def check_browser_executable_archive_member(
    payload: dict[str, Any],
    verify_files_root: Path | None,
) -> list[dict[str, str]]:
    return check_archive_member_matches_artifact(
        payload,
        verify_files_root,
        artifact_field="browserBinary",
        member_path_field="browserExecutableArchivePath",
        label="browser executable",
        missing_code="missing_browser_executable_archive_path",
        missing_message="releaseArchive requires the browser executable path inside the archive",
        unsafe_code="unsafe_browser_executable_archive_path",
        member_missing_code="browser_executable_archive_member_missing",
        member_directory_code="browser_executable_archive_member_is_directory",
        member_not_executable_code="browser_executable_archive_member_not_executable",
        hash_mismatch_code="browser_executable_archive_hash_mismatch",
        require_executable=True,
    )


def check_doe_runtime_archive_member(
    payload: dict[str, Any],
    verify_files_root: Path | None,
) -> list[dict[str, str]]:
    return check_archive_member_matches_artifact(
        payload,
        verify_files_root,
        artifact_field="doeRuntime",
        member_path_field="doeRuntimeArchivePath",
        label="Doe runtime",
        missing_code="missing_doe_runtime_archive_path",
        missing_message="releaseArchive requires the Doe runtime path inside the archive",
        unsafe_code="unsafe_doe_runtime_archive_path",
        member_missing_code="doe_runtime_archive_member_missing",
        member_directory_code="doe_runtime_archive_member_is_directory",
        hash_mismatch_code="doe_runtime_archive_hash_mismatch",
    )


def check_dawn_fallback_runtime_archive_member(
    payload: dict[str, Any],
    verify_files_root: Path | None,
) -> list[dict[str, str]]:
    return check_archive_member_matches_artifact(
        payload,
        verify_files_root,
        artifact_field="dawnFallbackRuntime",
        member_path_field="dawnFallbackRuntimeArchivePath",
        label="Dawn fallback runtime",
        missing_code="missing_dawn_fallback_runtime_archive_path",
        missing_message="releaseArchive requires the Dawn fallback runtime path inside the archive",
        unsafe_code="unsafe_dawn_fallback_runtime_archive_path",
        member_missing_code="dawn_fallback_runtime_archive_member_missing",
        member_directory_code="dawn_fallback_runtime_archive_member_is_directory",
        hash_mismatch_code="dawn_fallback_runtime_archive_hash_mismatch",
    )


def check_release_archive_binary_identity(
    payload: dict[str, Any],
    verify_files_root: Path | None,
) -> list[dict[str, str]]:
    platform = payload.get("platform")
    release_archive = payload.get("releaseArchive")
    if (
        verify_files_root is None
        or not isinstance(platform, dict)
        or platform.get("os") != "macos"
        or not isinstance(release_archive, dict)
    ):
        return []
    expected_arch = platform.get("arch")
    if not isinstance(expected_arch, str):
        return []
    archive_path = release_archive.get("path")
    if not isinstance(archive_path, str) or not archive_path:
        return []
    resolved_path = resolve_artifact_path(archive_path, verify_files_root)
    if resolved_path is None or not resolved_path.is_file() or not zipfile.is_zipfile(resolved_path):
        return []

    failures: list[dict[str, str]] = []
    member_fields = (
        (
            "browserExecutableArchivePath",
            "browser_binary",
            "browser executable",
        ),
        ("doeRuntimeArchivePath", "doe_runtime", "Doe runtime"),
        ("dawnFallbackRuntimeArchivePath", "dawn_fallback_runtime", "Dawn fallback runtime"),
    )
    try:
        with zipfile.ZipFile(resolved_path) as archive:
            for member_path_field, kind, label in member_fields:
                member_path = payload.get(member_path_field)
                if not isinstance(member_path, str) or not member_path:
                    continue
                try:
                    info = archive.getinfo(member_path)
                except KeyError:
                    continue
                if info.is_dir():
                    continue
                identity = detect_file_identity_bytes(archive.read(info), kind)
                if identity.get("detectedFormat") != "macho":
                    failures.append(
                        failure(
                            "release_archive_binary_format_mismatch",
                            member_path_field,
                            f"macOS {label} archive member must be Mach-O: {member_path}",
                        )
                    )
                architectures = identity.get("detectedArchitectures")
                if not isinstance(architectures, list) or expected_arch not in architectures:
                    failures.append(
                        failure(
                            "release_archive_binary_arch_mismatch",
                            member_path_field,
                            (
                                f"macOS {label} archive member must include "
                                f"{expected_arch} code: {member_path}"
                            ),
                        )
                    )
    except zipfile.BadZipFile:
        return []
    return failures


def check_macos_app_metadata_archive_member(
    payload: dict[str, Any],
    verify_files_root: Path | None,
) -> list[dict[str, str]]:
    platform = payload.get("platform")
    if not isinstance(platform, dict) or platform.get("os") != "macos":
        return []
    member_path = payload.get("browserAppMetadataArchivePath")
    if not isinstance(member_path, str) or not member_path:
        return [
            failure(
                "missing_browser_app_metadata_archive_path",
                "browserAppMetadataArchivePath",
                "macOS releaseArchive requires the app metadata Info.plist path inside the archive",
            )
        ]
    if not safe_archive_member_path(member_path):
        return [
            failure(
                "unsafe_browser_app_metadata_archive_path",
                "browserAppMetadataArchivePath",
                f"app metadata archive path must be relative and safe: {member_path}",
            )
        ]
    release_archive = payload.get("releaseArchive")
    if verify_files_root is None or not isinstance(release_archive, dict):
        return []
    archive_path = release_archive.get("path")
    if not isinstance(archive_path, str) or not archive_path:
        return []
    resolved_path = resolve_artifact_path(archive_path, verify_files_root)
    if resolved_path is None or not resolved_path.is_file() or not zipfile.is_zipfile(resolved_path):
        return []
    try:
        with zipfile.ZipFile(resolved_path) as archive:
            try:
                info = archive.getinfo(member_path)
            except KeyError:
                return [
                    failure(
                        "browser_app_metadata_archive_member_missing",
                        "browserAppMetadataArchivePath",
                        f"app metadata archive member not found: {member_path}",
                    )
                ]
            if info.is_dir():
                return [
                    failure(
                        "browser_app_metadata_archive_member_is_directory",
                        "browserAppMetadataArchivePath",
                        f"app metadata archive member is a directory: {member_path}",
                    )
                ]
            plist = plistlib.loads(archive.read(info))
    except (plistlib.InvalidFileException, TypeError, ValueError) as exc:
        return [
            failure(
                "invalid_browser_app_metadata_plist",
                "browserAppMetadataArchivePath",
                f"app metadata Info.plist is invalid: {exc}",
            )
        ]
    except zipfile.BadZipFile:
        return []
    if not isinstance(plist, dict):
        return [
            failure(
                "invalid_browser_app_metadata_plist",
                "browserAppMetadataArchivePath",
                "app metadata Info.plist must be a dictionary",
            )
        ]
    return check_macos_app_metadata_payload(payload, plist)


def check_non_macos_app_metadata_archive_member(
    payload: dict[str, Any],
    verify_files_root: Path | None,
) -> list[dict[str, str]]:
    platform = payload.get("platform")
    if not isinstance(platform, dict) or platform.get("os") == "macos":
        return []
    member_path = payload.get("browserAppMetadataArchivePath")
    if not isinstance(member_path, str) or not member_path:
        return [
            failure(
                "missing_browser_app_metadata_archive_path",
                "browserAppMetadataArchivePath",
                "non-macOS releaseArchive requires the browser metadata JSON path inside the archive",
            )
        ]
    if not safe_archive_member_path(member_path):
        return [
            failure(
                "unsafe_browser_app_metadata_archive_path",
                "browserAppMetadataArchivePath",
                f"browser metadata archive path must be relative and safe: {member_path}",
            )
        ]
    release_archive = payload.get("releaseArchive")
    if verify_files_root is None or not isinstance(release_archive, dict):
        return []
    archive_path = release_archive.get("path")
    if not isinstance(archive_path, str) or not archive_path:
        return []
    resolved_path = resolve_artifact_path(archive_path, verify_files_root)
    if resolved_path is None or not resolved_path.is_file() or not zipfile.is_zipfile(resolved_path):
        return []
    try:
        with zipfile.ZipFile(resolved_path) as archive:
            try:
                info = archive.getinfo(member_path)
            except KeyError:
                return [
                    failure(
                        "browser_app_metadata_archive_member_missing",
                        "browserAppMetadataArchivePath",
                        f"browser metadata archive member not found: {member_path}",
                    )
                ]
            if info.is_dir():
                return [
                    failure(
                        "browser_app_metadata_archive_member_is_directory",
                        "browserAppMetadataArchivePath",
                        f"browser metadata archive member is a directory: {member_path}",
                    )
                ]
            metadata = json.loads(archive.read(info).decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        return [
            failure(
                "invalid_browser_app_metadata_json",
                "browserAppMetadataArchivePath",
                f"browser metadata JSON is invalid: {exc}",
            )
        ]
    except zipfile.BadZipFile:
        return []
    if not isinstance(metadata, dict):
        return [
            failure(
                "invalid_browser_app_metadata_json",
                "browserAppMetadataArchivePath",
                "browser metadata JSON must be an object",
            )
        ]
    return check_non_macos_app_metadata_payload(payload, metadata)


def check_non_macos_app_metadata_payload(
    payload: dict[str, Any],
    metadata: dict[str, Any],
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    for field, expected, code, message in (
        (
            "browserProduct",
            payload.get("browserProduct"),
            "browser_app_metadata_product_mismatch",
            "browser metadata browserProduct must match release bundle",
        ),
        (
            "platform",
            payload.get("platform"),
            "browser_app_metadata_platform_mismatch",
            "browser metadata platform must match release bundle",
        ),
        (
            "browserExecutableArchivePath",
            payload.get("browserExecutableArchivePath"),
            "browser_app_metadata_executable_mismatch",
            "browser metadata browserExecutableArchivePath must match release bundle",
        ),
        (
            "doeRuntimeArchivePath",
            payload.get("doeRuntimeArchivePath"),
            "browser_app_metadata_doe_runtime_mismatch",
            "browser metadata doeRuntimeArchivePath must match release bundle",
        ),
        (
            "dawnFallbackRuntimeArchivePath",
            payload.get("dawnFallbackRuntimeArchivePath"),
            "browser_app_metadata_dawn_runtime_mismatch",
            "browser metadata dawnFallbackRuntimeArchivePath must match release bundle",
        ),
    ):
        if metadata.get(field) != expected:
            failures.append(
                failure(
                    code,
                    f"browserAppMetadataArchivePath.{field}",
                    message,
                )
            )
    return failures


def check_macos_app_metadata_payload(
    payload: dict[str, Any],
    plist: dict[str, Any],
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    product = payload.get("browserProduct")
    executable_path = payload.get("browserExecutableArchivePath")
    if isinstance(product, dict):
        display_name = product.get("displayName")
        product_id = product.get("productId")
        version = product.get("version")
        bundle_id = (
            ALLOWED_BROWSER_PRODUCT_BUNDLE_IDS.get(product_id)
            if isinstance(product_id, str)
            else None
        )
        for field in ("CFBundleName", "CFBundleDisplayName"):
            if plist.get(field) != display_name:
                failures.append(
                    failure(
                        "browser_app_metadata_product_mismatch",
                        f"browserAppMetadataArchivePath.{field}",
                        f"app metadata {field} must match browserProduct.displayName",
                    )
                )
        if bundle_id is not None and plist.get("CFBundleIdentifier") != bundle_id:
            failures.append(
                failure(
                    "browser_app_metadata_bundle_id_mismatch",
                    "browserAppMetadataArchivePath.CFBundleIdentifier",
                    "app metadata CFBundleIdentifier must match browserProduct.productId",
                )
            )
        for field in ("CFBundleShortVersionString", "CFBundleVersion"):
            if isinstance(version, str) and plist.get(field) != version:
                failures.append(
                    failure(
                        "browser_app_metadata_version_mismatch",
                        f"browserAppMetadataArchivePath.{field}",
                        f"app metadata {field} must match browserProduct.version",
                    )
                )
    if isinstance(executable_path, str) and executable_path:
        executable_name = PurePosixPath(executable_path).name
        if plist.get("CFBundleExecutable") != executable_name:
            failures.append(
                failure(
                    "browser_app_metadata_executable_mismatch",
                    "browserAppMetadataArchivePath.CFBundleExecutable",
                    "app metadata CFBundleExecutable must match browserExecutableArchivePath",
                )
            )
    if plist.get("CFBundlePackageType") != "APPL":
        failures.append(
            failure(
                "browser_app_metadata_package_type_mismatch",
                "browserAppMetadataArchivePath.CFBundlePackageType",
                "app metadata CFBundlePackageType must be APPL",
            )
        )
    return failures


def check_release_archive_surface(
    payload: dict[str, Any],
    verify_files_root: Path | None,
    *,
    require_release_candidate: bool,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    release_archive = payload.get("releaseArchive")
    platform = payload.get("platform")
    candidate_required = require_release_candidate or payload.get("releaseStatus") == "release_candidate"
    if release_archive is None:
        if candidate_required:
            failures.append(
                failure(
                    "missing_release_archive",
                    "releaseArchive",
                    "release candidates must hash-bind the downloadable browser archive",
                )
            )
        if platform is not None:
            failures.append(
                failure(
                    "platform_requires_release_archive",
                    "platform",
                    "platform identity requires releaseArchive",
                )
            )
        return failures

    failures.extend(
        check_artifact(
            release_archive,
            "releaseArchive",
            "browser_release_archive",
            verify_files_root,
        )
    )
    download_url = release_archive.get("downloadUrl") if isinstance(release_archive, dict) else None
    if candidate_required:
        if not isinstance(download_url, str) or not download_url:
            failures.append(
                failure(
                    "missing_release_archive_download_url",
                    "releaseArchive.downloadUrl",
                    "release candidates must expose a hosted HTTPS browser archive download URL",
                )
            )
        elif not is_public_https_url(download_url):
            failures.append(
                failure(
                    "invalid_release_archive_download_url",
                    "releaseArchive.downloadUrl",
                    "release archive download URL must be public HTTPS",
                )
            )
    if platform is None:
        failures.append(
            failure(
                "missing_platform",
                "platform",
                "releaseArchive requires platform identity",
            )
        )
    else:
        failures.extend(check_platform(platform, "platform"))
        if candidate_required:
            failures.extend(check_initial_release_candidate_platform(platform))
        failures.extend(check_zip_archive(release_archive, platform, verify_files_root))
        failures.extend(check_unique_release_archive_member_paths(payload))
        member_verify_root = verify_files_root if candidate_required else None
        failures.extend(check_browser_executable_archive_member(payload, member_verify_root))
        failures.extend(check_doe_runtime_archive_member(payload, member_verify_root))
        if payload.get("dawnFallbackRuntime") is not None or candidate_required:
            failures.extend(
                check_dawn_fallback_runtime_archive_member(payload, member_verify_root)
            )
        if candidate_required:
            failures.extend(check_release_archive_binary_identity(payload, verify_files_root))
        failures.extend(check_macos_app_metadata_archive_member(payload, verify_files_root))
        failures.extend(check_non_macos_app_metadata_archive_member(payload, verify_files_root))
    return failures


def load_artifact_payload(
    artifact: dict[str, Any],
    path: str,
    verify_files_root: Path | None,
) -> dict[str, Any] | None:
    if verify_files_root is None:
        return None
    artifact_path = artifact.get("path")
    artifact_hash = artifact.get("sha256")
    if not (
        isinstance(artifact_path, str)
        and artifact_path
        and isinstance(artifact_hash, str)
        and len(artifact_hash) == 64
    ):
        return None
    resolved = resolve_artifact_path(artifact_path, verify_files_root)
    if resolved is None or not resolved.is_file():
        return None
    try:
        payload = json.loads(resolved.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        return {
            "_invalid_payload_error": failure(
                "invalid_artifact_payload",
                f"{path}.path",
                f"artifact payload is not valid JSON: {exc}",
            )
        }
    if not isinstance(payload, dict):
        return {
            "_invalid_payload_error": failure(
                "invalid_artifact_payload",
                f"{path}.path",
                "artifact payload must be a JSON object",
            )
        }
    return payload


def check_public_download_receipt_payload(
    receipt: dict[str, Any],
    payload: dict[str, Any],
) -> list[dict[str, str]]:
    invalid_payload_error = receipt.get("_invalid_payload_error")
    if isinstance(invalid_payload_error, dict):
        return [invalid_payload_error]
    failures: list[dict[str, str]] = []
    release_archive = payload.get("releaseArchive")
    platform = payload.get("platform")
    browser_product = payload.get("browserProduct")
    download_url = release_archive.get("downloadUrl") if isinstance(release_archive, dict) else None
    archive_path = release_archive.get("path") if isinstance(release_archive, dict) else None
    archive_sha = release_archive.get("sha256") if isinstance(release_archive, dict) else None
    release_archive_manifest = payload.get("releaseArchiveManifest")
    manifest_path = (
        release_archive_manifest.get("path")
        if isinstance(release_archive_manifest, dict)
        else None
    )
    manifest_sha = (
        release_archive_manifest.get("sha256")
        if isinstance(release_archive_manifest, dict)
        else None
    )
    browser_member_path = payload.get("browserExecutableArchivePath")
    app_metadata_member_path = payload.get("browserAppMetadataArchivePath")
    doe_runtime_member_path = payload.get("doeRuntimeArchivePath")
    dawn_runtime_member_path = payload.get("dawnFallbackRuntimeArchivePath")
    if receipt.get("schemaVersion") != 1:
        failures.append(
            failure(
                "invalid_public_download_receipt_schema_version",
                "publicDownloadReceipt.path",
                "public download receipt schemaVersion must be 1",
            )
        )
    if receipt.get("artifactKind") != "browser_public_download_receipt":
        failures.append(
            failure(
                "invalid_public_download_receipt_artifact_kind",
                "publicDownloadReceipt.path",
                "public download receipt artifactKind must be browser_public_download_receipt",
            )
        )
    if not isinstance(receipt.get("receiptId"), str) or not receipt.get("receiptId"):
        failures.append(
            failure(
                "missing_public_download_receipt_id",
                "publicDownloadReceipt.path",
                "public download receiptId is required",
            )
        )
    if receipt.get("url") != download_url:
        failures.append(
            failure(
                "public_download_url_mismatch",
                "publicDownloadReceipt.url",
                "public download receipt URL must match releaseArchive.downloadUrl",
            )
        )
    elif not is_public_https_url(receipt.get("url")):
        failures.append(
            failure(
                "invalid_public_download_url",
                "publicDownloadReceipt.url",
                "public download receipt URL must be public HTTPS",
            )
        )
    if receipt.get("method") != "GET":
        failures.append(
            failure(
                "invalid_public_download_method",
                "publicDownloadReceipt.method",
                "public download receipt method must be GET",
            )
        )
    if receipt.get("statusCode") != 200:
        failures.append(
            failure(
                "invalid_public_download_status",
                "publicDownloadReceipt.statusCode",
                "public download receipt statusCode must be 200",
            )
        )
    if receipt.get("contentSha256") != archive_sha:
        failures.append(
            failure(
                "public_download_hash_mismatch",
                "publicDownloadReceipt.contentSha256",
                "public download receipt contentSha256 must match releaseArchive.sha256",
            )
        )
    if not isinstance(receipt.get("contentLengthBytes"), int) or receipt.get("contentLengthBytes") <= 0:
        failures.append(
            failure(
                "invalid_public_download_length",
                "publicDownloadReceipt.contentLengthBytes",
                "public download receipt contentLengthBytes must be positive",
            )
        )
    if receipt.get("releaseArchivePath") != archive_path:
        failures.append(
            failure(
                "public_download_archive_path_mismatch",
                "publicDownloadReceipt.releaseArchivePath",
                "public download receipt releaseArchivePath must match releaseArchive.path",
            )
        )
    if receipt.get("releaseArchiveManifestPath") != manifest_path:
        failures.append(
            failure(
                "public_download_archive_manifest_path_mismatch",
                "publicDownloadReceipt.releaseArchiveManifestPath",
                "public download receipt releaseArchiveManifestPath must match releaseArchiveManifest.path",
            )
        )
    if receipt.get("releaseArchiveManifestSha256") != manifest_sha:
        failures.append(
            failure(
                "public_download_archive_manifest_hash_mismatch",
                "publicDownloadReceipt.releaseArchiveManifestSha256",
                "public download receipt releaseArchiveManifestSha256 must match releaseArchiveManifest.sha256",
            )
        )
    if receipt.get("platform") != platform:
        failures.append(
            failure(
                "public_download_platform_mismatch",
                "publicDownloadReceipt.platform",
                "public download receipt platform must match release bundle platform",
            )
        )
    if receipt.get("browserProduct") != browser_product:
        failures.append(
            failure(
                "public_download_browser_product_mismatch",
                "publicDownloadReceipt.browserProduct",
                "public download receipt browserProduct must match release bundle browserProduct",
            )
        )
    for field, expected, code in (
        ("browserExecutableArchivePath", browser_member_path, "public_download_browser_member_mismatch"),
        ("browserAppMetadataArchivePath", app_metadata_member_path, "public_download_app_metadata_member_mismatch"),
        ("doeRuntimeArchivePath", doe_runtime_member_path, "public_download_doe_runtime_member_mismatch"),
        ("dawnFallbackRuntimeArchivePath", dawn_runtime_member_path, "public_download_dawn_runtime_member_mismatch"),
    ):
        if receipt.get(field) != expected:
            failures.append(
                failure(
                    code,
                    f"publicDownloadReceipt.{field}",
                    f"public download receipt {field} must match release bundle",
                )
            )
    if not isinstance(receipt.get("observedAt"), str) or not receipt.get("observedAt"):
        failures.append(
            failure(
                "missing_public_download_observed_at",
                "publicDownloadReceipt.observedAt",
                "public download receipt observedAt is required",
            )
        )
    return failures


def check_public_download_receipt_artifact(
    payload: dict[str, Any],
    verify_files_root: Path | None,
    *,
    require_release_candidate: bool,
) -> list[dict[str, str]]:
    public_download_receipt = payload.get("publicDownloadReceipt")
    candidate_required = require_release_candidate or payload.get("releaseStatus") == "release_candidate"
    if public_download_receipt is None:
        if not candidate_required:
            return []
        return [
            failure(
                "missing_public_download_receipt",
                "publicDownloadReceipt",
                "release candidates must hash-bind a public download receipt",
            )
        ]
    failures = check_artifact(
        public_download_receipt,
        "publicDownloadReceipt",
        "browser_public_download_receipt",
        verify_files_root,
    )
    if not isinstance(public_download_receipt, dict):
        return failures
    receipt_payload = load_artifact_payload(
        public_download_receipt,
        "publicDownloadReceipt",
        verify_files_root,
    )
    if receipt_payload is not None:
        failures.extend(check_public_download_receipt_payload(receipt_payload, payload))
        if verify_files_root is not None:
            release_archive = payload.get("releaseArchive")
            archive_path = release_archive.get("path") if isinstance(release_archive, dict) else None
            resolved_archive = (
                resolve_artifact_path(archive_path, verify_files_root)
                if isinstance(archive_path, str)
                else None
            )
            content_length = receipt_payload.get("contentLengthBytes")
            if (
                resolved_archive is not None
                and resolved_archive.is_file()
                and isinstance(content_length, int)
                and content_length != resolved_archive.stat().st_size
            ):
                failures.append(
                    failure(
                        "public_download_length_mismatch",
                        "publicDownloadReceipt.contentLengthBytes",
                        "public download receipt contentLengthBytes must match release archive size",
                    )
                )
    return failures


def check_chromium_source_checkout_payload(
    report: dict[str, Any],
    *,
    require_release_candidate: bool,
) -> list[dict[str, str]]:
    invalid_payload_error = report.get("_invalid_payload_error")
    if isinstance(invalid_payload_error, dict):
        return [invalid_payload_error]
    failures: list[dict[str, str]] = []
    if report.get("schemaVersion") != 1:
        failures.append(
            failure(
                "invalid_chromium_source_checkout_schema_version",
                "chromiumSourceCheckout.path",
                "Chromium source checkout report schemaVersion must be 1",
            )
        )
    if report.get("artifactKind") != "chromium_source_checkout_check":
        failures.append(
            failure(
                "invalid_chromium_source_checkout_artifact_kind",
                "chromiumSourceCheckout.path",
                "Chromium source checkout report artifactKind must be chromium_source_checkout_check",
            )
        )
    missing_required = report.get("missingRequired")
    status = report.get("status")
    if status == "pass" and missing_required != []:
        failures.append(
            failure(
                "chromium_source_checkout_pass_has_missing_required",
                "chromiumSourceCheckout.missingRequired",
                "passing Chromium source checkout report must have no missing required checks",
            )
        )
    if status == "blocked" and missing_required == []:
        failures.append(
            failure(
                "chromium_source_checkout_blocked_without_missing_required",
                "chromiumSourceCheckout.missingRequired",
                "blocked Chromium source checkout report must list missing required checks",
            )
        )
    if require_release_candidate and report.get("requireRuntimeSelector") is not True:
        failures.append(
            failure(
                "chromium_source_checkout_runtime_selector_not_required",
                "chromiumSourceCheckout.requireRuntimeSelector",
                "release-candidate Chromium source checkout must require runtime selector markers",
            )
        )
    if require_release_candidate and status != "pass":
        failures.append(
            failure(
                "chromium_source_checkout_not_pass",
                "chromiumSourceCheckout.status",
                "release-candidate Chromium source checkout report must pass",
            )
        )
    if require_release_candidate and missing_required != []:
        failures.append(
            failure(
                "chromium_source_checkout_missing_required",
                "chromiumSourceCheckout.missingRequired",
                "release-candidate Chromium source checkout report must have no missing required checks",
            )
        )
    if not isinstance(report.get("sourceRoot"), str) or not report["sourceRoot"]:
        failures.append(
            failure(
                "chromium_source_checkout_missing_source_root",
                "chromiumSourceCheckout.sourceRoot",
                "Chromium source checkout report sourceRoot is required",
            )
        )
    return failures


def check_chromium_source_checkout_artifact(
    payload: dict[str, Any],
    verify_files_root: Path | None,
    *,
    require_release_candidate: bool,
) -> list[dict[str, str]]:
    artifact = payload.get("chromiumSourceCheckout")
    candidate_required = require_release_candidate or payload.get("releaseStatus") == "release_candidate"
    if artifact is None:
        if not candidate_required:
            return []
        return [
            failure(
                "missing_chromium_source_checkout",
                "chromiumSourceCheckout",
                "release candidates must hash-bind a passing Chromium source checkout report",
            )
        ]
    failures = check_artifact(
        artifact,
        "chromiumSourceCheckout",
        "chromium_source_checkout_check",
        verify_files_root,
    )
    if not isinstance(artifact, dict):
        return failures
    report = load_artifact_payload(artifact, "chromiumSourceCheckout", verify_files_root)
    if report is not None:
        failures.extend(
            check_chromium_source_checkout_payload(
                report,
                require_release_candidate=candidate_required,
            )
        )
    return failures


def path_values_match(left: Any, right: Any, verify_files_root: Path | None) -> bool:
    if not isinstance(left, str) or not isinstance(right, str):
        return False
    if left == right:
        return True
    if verify_files_root is None:
        return False
    left_resolved = resolve_artifact_path(left, verify_files_root)
    right_resolved = resolve_artifact_path(right, verify_files_root)
    return left_resolved is not None and right_resolved is not None and left_resolved == right_resolved


def check_package_inputs_payload(
    report: dict[str, Any],
    payload: dict[str, Any],
    verify_files_root: Path | None,
    *,
    require_release_candidate: bool = False,
) -> list[dict[str, str]]:
    invalid_payload_error = report.get("_invalid_payload_error")
    if isinstance(invalid_payload_error, dict):
        return [invalid_payload_error]
    failures: list[dict[str, str]] = []
    if report.get("schemaVersion") != 1:
        failures.append(failure("invalid_package_inputs_schema_version", "packageInputs.path", "package inputs report schemaVersion must be 1"))
    if report.get("artifactKind") != "browser_release_package_inputs_check":
        failures.append(failure("invalid_package_inputs_artifact_kind", "packageInputs.path", "package inputs report artifactKind must be browser_release_package_inputs_check"))
    if report.get("status") != "pass":
        failures.append(failure("package_inputs_not_passing", "packageInputs.status", "package inputs report must pass before bundle assembly"))
    if require_release_candidate:
        if report.get("releaseCandidateEligible") is not True:
            failures.append(failure("package_inputs_not_release_candidate_eligible", "packageInputs.releaseCandidateEligible", "release-candidate bundles require release-candidate eligible package inputs"))
        if report.get("evidenceMode") != "release_candidate":
            failures.append(failure("package_inputs_not_release_candidate_evidence", "packageInputs.evidenceMode", "release-candidate bundles require package inputs evidenceMode=release_candidate"))
        if report.get("releaseCandidateBlockers") != []:
            failures.append(failure("package_inputs_release_candidate_blockers_present", "packageInputs.releaseCandidateBlockers", "release-candidate package inputs must carry no release-candidate blockers"))
        if report.get("failures") != []:
            failures.append(failure("package_inputs_failures_present", "packageInputs.failures", "passing package inputs must carry no failures"))
        summary = report.get("summary")
        if not isinstance(summary, dict) or summary.get("packageable") is not True:
            failures.append(failure("package_inputs_summary_not_packageable", "packageInputs.summary.packageable", "passing package inputs summary.packageable must be true"))
        failures.extend(
            package_inputs_check.release_candidate_binary_identity_failures(
                report,
                path_prefix="packageInputs",
            )
        )
    if report.get("browserProduct") != payload.get("browserProduct"):
        failures.append(failure("package_inputs_browser_product_mismatch", "packageInputs.browserProduct", "package inputs browserProduct must match release bundle"))
    if report.get("platform") != payload.get("platform"):
        failures.append(failure("package_inputs_platform_mismatch", "packageInputs.platform", "package inputs platform must match release bundle"))
    inputs = report.get("inputs")
    if not isinstance(inputs, dict):
        failures.append(failure("package_inputs_missing_inputs", "packageInputs.inputs", "package inputs report must carry inputs object"))
        return failures
    for role, bundle_artifact_field in (
        ("browserExecutable", "browserBinary"),
        ("doeRuntime", "doeRuntime"),
        ("dawnFallbackRuntime", "dawnFallbackRuntime"),
        ("shaderCompiler", "shaderCompiler"),
    ):
        row = inputs.get(role)
        if not isinstance(row, dict):
            failures.append(failure("package_inputs_missing_row", f"packageInputs.inputs.{role}", f"package inputs report missing row: {role}"))
            continue
        expected_path = artifact_field(payload, bundle_artifact_field, "path")
        expected_hash = artifact_field(payload, bundle_artifact_field, "sha256")
        if not path_values_match(row.get("path"), expected_path, verify_files_root):
            failures.append(failure("package_inputs_artifact_path_mismatch", f"packageInputs.inputs.{role}.path", f"package inputs {role}.path must match {bundle_artifact_field}.path"))
        if row.get("sha256") != expected_hash:
            failures.append(failure("package_inputs_artifact_hash_mismatch", f"packageInputs.inputs.{role}.sha256", f"package inputs {role}.sha256 must match {bundle_artifact_field}.sha256"))
    for role, bundle_field in (
        ("browserExecutable", "browserExecutableArchivePath"),
        ("appMetadata", "browserAppMetadataArchivePath"),
        ("doeRuntime", "doeRuntimeArchivePath"),
        ("dawnFallbackRuntime", "dawnFallbackRuntimeArchivePath"),
    ):
        row = inputs.get(role)
        if isinstance(row, dict) and row.get("archivePath") != payload.get(bundle_field):
            failures.append(failure("package_inputs_archive_path_mismatch", f"packageInputs.inputs.{role}.archivePath", f"package inputs {role}.archivePath must match {bundle_field}"))
    return failures


def check_package_inputs_artifact(
    payload: dict[str, Any],
    verify_files_root: Path | None,
    *,
    require_release_candidate: bool,
) -> list[dict[str, str]]:
    artifact = payload.get("packageInputs")
    candidate_required = require_release_candidate or payload.get("releaseStatus") == "release_candidate"
    if artifact is None:
        if candidate_required:
            return [
                failure(
                    "missing_package_inputs",
                    "packageInputs",
                    "release candidates must hash-bind a passing browser release package-inputs check",
                )
            ]
        return []
    failures = check_artifact(
        artifact,
        "packageInputs",
        "browser_release_package_inputs_check",
        verify_files_root,
    )
    if not isinstance(artifact, dict):
        return failures
    report = load_artifact_payload(artifact, "packageInputs", verify_files_root)
    if report is not None:
        failures.extend(
            check_package_inputs_payload(
                report,
                payload,
                verify_files_root,
                require_release_candidate=candidate_required,
            )
        )
    failures.extend(check_package_inputs_archive_manifest_binding(payload, verify_files_root))
    return failures


def check_package_inputs_archive_manifest_binding(
    payload: dict[str, Any],
    verify_files_root: Path | None,
) -> list[dict[str, str]]:
    if verify_files_root is None:
        return []
    package_inputs = payload.get("packageInputs")
    release_archive_manifest = payload.get("releaseArchiveManifest")
    if not isinstance(package_inputs, dict) or not isinstance(release_archive_manifest, dict):
        return []
    manifest = load_artifact_payload(
        release_archive_manifest,
        "releaseArchiveManifest",
        verify_files_root,
    )
    if manifest is None:
        return []
    invalid_payload_error = manifest.get("_invalid_payload_error")
    if isinstance(invalid_payload_error, dict):
        return [invalid_payload_error]
    source_package_inputs = manifest.get("sourcePackageInputs")
    if not isinstance(source_package_inputs, dict):
        return [
            failure(
                "missing_release_archive_manifest_source_package_inputs",
                "releaseArchiveManifest.sourcePackageInputs",
                "release archive manifest must bind sourcePackageInputs when release bundle binds packageInputs",
            )
        ]
    failures: list[dict[str, str]] = []
    for key in ("path", "sha256", "kind"):
        if source_package_inputs.get(key) != package_inputs.get(key):
            failures.append(
                failure(
                    "release_archive_manifest_source_package_inputs_mismatch",
                    f"releaseArchiveManifest.sourcePackageInputs.{key}",
                    "release archive manifest sourcePackageInputs must match release bundle packageInputs",
                )
            )
    return failures


def artifact_identity(payload: dict[str, Any], field: str) -> Any:
    artifact = payload.get(field)
    if not isinstance(artifact, dict):
        return None
    return artifact


def check_browser_launch_receipt_payload(
    receipt: dict[str, Any],
    payload: dict[str, Any],
    verify_files_root: Path | None,
) -> list[dict[str, str]]:
    invalid_payload_error = receipt.get("_invalid_payload_error")
    if isinstance(invalid_payload_error, dict):
        return [invalid_payload_error]
    failures: list[dict[str, str]] = []
    if receipt.get("schemaVersion") != 1:
        failures.append(
            failure(
                "invalid_browser_launch_receipt_schema_version",
                "browserLaunchReceipt.path",
                "browser launch receipt schemaVersion must be 1",
            )
        )
    if receipt.get("artifactKind") != "browser_release_launch_receipt":
        failures.append(
            failure(
                "invalid_browser_launch_receipt_artifact_kind",
                "browserLaunchReceipt.path",
                "browser launch receipt artifactKind must be browser_release_launch_receipt",
            )
        )
    for field, expected, code, message in (
        ("launchSource", "release_archive", "browser_launch_source_mismatch", "browser launch receipt must launch from the release archive"),
        ("runtimeMode", "doe", "browser_launch_runtime_mode_mismatch", "browser launch receipt runtimeMode must be doe"),
        ("activeRuntime", "doe", "browser_launch_active_runtime_mismatch", "browser launch receipt activeRuntime must be doe"),
        ("hiddenFallbackAllowed", False, "browser_launch_hidden_fallback_allowed", "browser launch receipt must prove hidden fallback is disabled"),
        ("hiddenFallbackUsed", False, "browser_launch_hidden_fallback_used", "browser launch receipt must prove hidden fallback was not used"),
        ("webgpuAvailable", True, "browser_launch_webgpu_unavailable", "browser launch receipt must prove WebGPU is available"),
    ):
        if receipt.get(field) != expected:
            failures.append(failure(code, f"browserLaunchReceipt.{field}", message))
    if not isinstance(receipt.get("receiptId"), str) or not receipt.get("receiptId"):
        failures.append(failure("missing_browser_launch_receipt_id", "browserLaunchReceipt.receiptId", "browser launch receiptId is required"))
    if not isinstance(receipt.get("observedAt"), str) or not receipt.get("observedAt"):
        failures.append(failure("missing_browser_launch_observed_at", "browserLaunchReceipt.observedAt", "browser launch observedAt is required"))
    for field, bundle_field, code, message in (
        ("browserProduct", "browserProduct", "browser_launch_product_mismatch", "browser launch receipt browserProduct must match release bundle"),
        ("platform", "platform", "browser_launch_platform_mismatch", "browser launch receipt platform must match release bundle"),
        ("releaseArchive", "releaseArchive", "browser_launch_archive_mismatch", "browser launch receipt releaseArchive must match release bundle"),
        ("releaseArchiveManifest", "releaseArchiveManifest", "browser_launch_archive_manifest_mismatch", "browser launch receipt releaseArchiveManifest must match release bundle"),
        ("proofSurface", "proofSurface", "browser_launch_proof_surface_mismatch", "browser launch receipt proofSurface must match release bundle"),
        ("browserExecutableArchivePath", "browserExecutableArchivePath", "browser_launch_browser_member_mismatch", "browser launch receipt browserExecutableArchivePath must match release bundle"),
        ("browserAppMetadataArchivePath", "browserAppMetadataArchivePath", "browser_launch_app_metadata_member_mismatch", "browser launch receipt browserAppMetadataArchivePath must match release bundle"),
        ("doeRuntimeArchivePath", "doeRuntimeArchivePath", "browser_launch_doe_runtime_member_mismatch", "browser launch receipt doeRuntimeArchivePath must match release bundle"),
        ("dawnFallbackRuntimeArchivePath", "dawnFallbackRuntimeArchivePath", "browser_launch_dawn_runtime_member_mismatch", "browser launch receipt dawnFallbackRuntimeArchivePath must match release bundle"),
    ):
        if receipt.get(field) != payload.get(bundle_field):
            failures.append(failure(code, f"browserLaunchReceipt.{field}", message))
    proof_page = receipt.get("proofPage")
    if not isinstance(proof_page, dict):
        failures.append(failure("missing_browser_launch_proof_page", "browserLaunchReceipt.proofPage", "browser launch receipt must include proofPage launch evidence"))
    else:
        if proof_page.get("loaded") is not True:
            failures.append(failure("browser_launch_proof_page_not_loaded", "browserLaunchReceipt.proofPage.loaded", "browser launch receipt proof page must be loaded"))
        for field in ("url", "artifactPath", "receiptId"):
            if not isinstance(proof_page.get(field), str) or not proof_page[field]:
                failures.append(failure("missing_browser_launch_proof_page_field", f"browserLaunchReceipt.proofPage.{field}", f"browser launch proofPage.{field} is required"))
    gallery_page = receipt.get("galleryPage")
    if not isinstance(gallery_page, dict):
        failures.append(failure("missing_browser_launch_gallery_page", "browserLaunchReceipt.galleryPage", "browser launch receipt must include galleryPage launch evidence"))
    else:
        if gallery_page.get("loaded") is not True:
            failures.append(failure("browser_launch_gallery_page_not_loaded", "browserLaunchReceipt.galleryPage.loaded", "browser launch receipt gallery page must be loaded"))
        for field in ("url", "category", "artifactPath", "receiptId"):
            if not isinstance(gallery_page.get(field), str) or not gallery_page[field]:
                failures.append(failure("missing_browser_launch_gallery_page_field", f"browserLaunchReceipt.galleryPage.{field}", f"browser launch galleryPage.{field} is required"))
        if isinstance(gallery_page.get("url"), str) and not is_public_https_url(gallery_page["url"]):
            failures.append(failure("invalid_browser_launch_gallery_url", "browserLaunchReceipt.galleryPage.url", "browser launch gallery URL must be public HTTPS"))
    comparison_receipt = receipt.get("comparisonReceipt")
    if not isinstance(comparison_receipt, dict):
        failures.append(failure("missing_browser_launch_comparison_receipt", "browserLaunchReceipt.comparisonReceipt", "browser launch receipt must include same-page Dawn/Doe comparison evidence"))
    else:
        if comparison_receipt.get("loaded") is not True:
            failures.append(failure("browser_launch_comparison_not_loaded", "browserLaunchReceipt.comparisonReceipt.loaded", "browser launch comparison page must be loaded"))
        for field in ("comparisonId", "workloadId", "pageArtifactPath", "comparisonArtifactPath", "dawnReceiptId", "doeReceiptId"):
            if not isinstance(comparison_receipt.get(field), str) or not comparison_receipt[field]:
                failures.append(failure("missing_browser_launch_comparison_field", f"browserLaunchReceipt.comparisonReceipt.{field}", f"browser launch comparisonReceipt.{field} is required"))
        if comparison_receipt.get("executionScope") != "same_page":
            failures.append(failure("browser_launch_comparison_scope_mismatch", "browserLaunchReceipt.comparisonReceipt.executionScope", "browser launch comparison must use same_page execution scope"))
        if comparison_receipt.get("modes") != ["dawn", "doe"]:
            failures.append(failure("browser_launch_comparison_modes_mismatch", "browserLaunchReceipt.comparisonReceipt.modes", "browser launch comparison modes must be dawn then doe"))
        if comparison_receipt.get("emitsSideBySideReceipts") is not True:
            failures.append(failure("browser_launch_comparison_not_side_by_side", "browserLaunchReceipt.comparisonReceipt.emitsSideBySideReceipts", "browser launch comparison must emit side-by-side receipts"))
        if isinstance(gallery_page, dict) and comparison_receipt.get("pageArtifactPath") != gallery_page.get("artifactPath"):
            failures.append(failure("browser_launch_comparison_page_not_loaded_gallery", "browserLaunchReceipt.comparisonReceipt.pageArtifactPath", "browser launch comparison pageArtifactPath must match the loaded gallery artifactPath"))
    observed_receipt_ids = receipt.get("observedReceiptIds")
    if not isinstance(observed_receipt_ids, list) or not observed_receipt_ids or any(not isinstance(value, str) or not value for value in observed_receipt_ids):
        failures.append(failure("missing_browser_launch_observed_receipts", "browserLaunchReceipt.observedReceiptIds", "browser launch receipt must include observed receipt IDs"))
    else:
        if len(set(observed_receipt_ids)) != len(observed_receipt_ids):
            failures.append(failure("duplicate_browser_launch_observed_receipts", "browserLaunchReceipt.observedReceiptIds", "browser launch observedReceiptIds must be unique"))
        if isinstance(proof_page, dict) and proof_page.get("receiptId") not in observed_receipt_ids:
            failures.append(failure("browser_launch_missing_observed_proof_receipt", "browserLaunchReceipt.observedReceiptIds", "browser launch observedReceiptIds must include proofPage.receiptId"))
        if isinstance(gallery_page, dict) and gallery_page.get("receiptId") not in observed_receipt_ids:
            failures.append(failure("browser_launch_missing_observed_gallery_receipt", "browserLaunchReceipt.observedReceiptIds", "browser launch observedReceiptIds must include galleryPage.receiptId"))
        if isinstance(comparison_receipt, dict):
            if comparison_receipt.get("dawnReceiptId") not in observed_receipt_ids:
                failures.append(failure("browser_launch_missing_observed_comparison_dawn_receipt", "browserLaunchReceipt.observedReceiptIds", "browser launch observedReceiptIds must include comparisonReceipt.dawnReceiptId"))
            if comparison_receipt.get("doeReceiptId") not in observed_receipt_ids:
                failures.append(failure("browser_launch_missing_observed_comparison_doe_receipt", "browserLaunchReceipt.observedReceiptIds", "browser launch observedReceiptIds must include comparisonReceipt.doeReceiptId"))
        expected_observed_ids = {
            value
            for value in (
                proof_page.get("receiptId") if isinstance(proof_page, dict) else None,
                gallery_page.get("receiptId") if isinstance(gallery_page, dict) else None,
                comparison_receipt.get("dawnReceiptId") if isinstance(comparison_receipt, dict) else None,
                comparison_receipt.get("doeReceiptId") if isinstance(comparison_receipt, dict) else None,
            )
            if isinstance(value, str) and value
        }
        if set(observed_receipt_ids) != expected_observed_ids:
            failures.append(failure("browser_launch_unlinked_observed_receipts", "browserLaunchReceipt.observedReceiptIds", "browser launch observedReceiptIds must exactly match proof, gallery, Dawn, and Doe receipt IDs"))

    proof_surface = artifact_identity(payload, "proofSurface")
    proof_payload = (
        load_artifact_payload(proof_surface, "proofSurface", verify_files_root)
        if isinstance(proof_surface, dict)
        else None
    )
    if isinstance(proof_payload, dict) and "_invalid_payload_error" not in proof_payload:
        proof_page_payload = proof_payload.get("proofPage")
        if isinstance(proof_page, dict) and isinstance(proof_page_payload, dict):
            proof_artifact = proof_page_payload.get("artifact")
            if proof_page.get("url") != proof_page_payload.get("url"):
                failures.append(failure("browser_launch_proof_page_url_mismatch", "browserLaunchReceipt.proofPage.url", "browser launch proof page URL must match proof surface"))
            if isinstance(proof_artifact, dict) and proof_page.get("artifactPath") != proof_artifact.get("path"):
                failures.append(failure("browser_launch_proof_page_artifact_mismatch", "browserLaunchReceipt.proofPage.artifactPath", "browser launch proof page artifactPath must match proof surface"))
            diagnostic_receipt = proof_page_payload.get("diagnosticReceipt")
            diagnostic_payload = (
                load_artifact_payload(diagnostic_receipt, "proofSurface.proofPage.diagnosticReceipt", verify_files_root)
                if isinstance(diagnostic_receipt, dict)
                else None
            )
            if isinstance(diagnostic_payload, dict) and "_invalid_payload_error" not in diagnostic_payload and proof_page.get("receiptId") != diagnostic_payload.get("receiptId"):
                failures.append(failure("browser_launch_proof_page_receipt_mismatch", "browserLaunchReceipt.proofPage.receiptId", "browser launch proof page receiptId must match proof-page diagnostic receipt"))
        if isinstance(gallery_page, dict):
            matching_gallery = None
            for row in proof_payload.get("galleryPages", []):
                if isinstance(row, dict) and isinstance(row.get("artifact"), dict) and row["artifact"].get("path") == gallery_page.get("artifactPath"):
                    matching_gallery = row
                    break
            if not isinstance(matching_gallery, dict):
                failures.append(failure("browser_launch_gallery_not_in_proof_surface", "browserLaunchReceipt.galleryPage.artifactPath", "browser launch gallery artifactPath must match a proof-surface gallery page"))
            else:
                if gallery_page.get("url") != matching_gallery.get("url"):
                    failures.append(failure("browser_launch_gallery_url_mismatch", "browserLaunchReceipt.galleryPage.url", "browser launch gallery URL must match proof surface"))
                if gallery_page.get("category") != matching_gallery.get("category"):
                    failures.append(failure("browser_launch_gallery_category_mismatch", "browserLaunchReceipt.galleryPage.category", "browser launch gallery category must match proof surface"))
                public_receipt = matching_gallery.get("publicReceipt")
                public_payload = (
                    load_artifact_payload(public_receipt, "proofSurface.galleryPages.publicReceipt", verify_files_root)
                    if isinstance(public_receipt, dict)
                    else None
                )
                if isinstance(public_payload, dict) and "_invalid_payload_error" not in public_payload and gallery_page.get("receiptId") != public_payload.get("receiptId"):
                    failures.append(failure("browser_launch_gallery_receipt_mismatch", "browserLaunchReceipt.galleryPage.receiptId", "browser launch gallery receiptId must match gallery public receipt"))
        if isinstance(comparison_receipt, dict):
            matching_comparison = None
            for row in proof_payload.get("comparisonReceipts", []):
                if isinstance(row, dict) and row.get("comparisonId") == comparison_receipt.get("comparisonId"):
                    matching_comparison = row
                    break
            if not isinstance(matching_comparison, dict):
                failures.append(failure("browser_launch_comparison_not_in_proof_surface", "browserLaunchReceipt.comparisonReceipt.comparisonId", "browser launch comparisonId must match a proof-surface comparison receipt"))
            else:
                runner = matching_comparison.get("runner")
                comparison_artifact = matching_comparison.get("comparisonArtifact")
                dawn_receipt = matching_comparison.get("dawnReceipt")
                doe_receipt = matching_comparison.get("doeReceipt")
                if comparison_receipt.get("workloadId") != matching_comparison.get("workloadId"):
                    failures.append(failure("browser_launch_comparison_workload_mismatch", "browserLaunchReceipt.comparisonReceipt.workloadId", "browser launch comparison workloadId must match proof surface"))
                if isinstance(runner, dict):
                    if comparison_receipt.get("pageArtifactPath") != runner.get("pageArtifactPath"):
                        failures.append(failure("browser_launch_comparison_page_mismatch", "browserLaunchReceipt.comparisonReceipt.pageArtifactPath", "browser launch comparison pageArtifactPath must match proof surface runner"))
                    if comparison_receipt.get("executionScope") != runner.get("executionScope"):
                        failures.append(failure("browser_launch_comparison_scope_mismatch", "browserLaunchReceipt.comparisonReceipt.executionScope", "browser launch comparison executionScope must match proof surface runner"))
                    if comparison_receipt.get("modes") != runner.get("modes"):
                        failures.append(failure("browser_launch_comparison_modes_mismatch", "browserLaunchReceipt.comparisonReceipt.modes", "browser launch comparison modes must match proof surface runner"))
                    if comparison_receipt.get("emitsSideBySideReceipts") != runner.get("emitsSideBySideReceipts"):
                        failures.append(failure("browser_launch_comparison_side_by_side_mismatch", "browserLaunchReceipt.comparisonReceipt.emitsSideBySideReceipts", "browser launch comparison side-by-side setting must match proof surface runner"))
                if isinstance(comparison_artifact, dict) and comparison_receipt.get("comparisonArtifactPath") != comparison_artifact.get("path"):
                    failures.append(failure("browser_launch_comparison_artifact_mismatch", "browserLaunchReceipt.comparisonReceipt.comparisonArtifactPath", "browser launch comparisonArtifactPath must match proof surface"))
                if isinstance(dawn_receipt, dict) and comparison_receipt.get("dawnReceiptId") != dawn_receipt.get("receiptId"):
                    failures.append(failure("browser_launch_comparison_dawn_receipt_mismatch", "browserLaunchReceipt.comparisonReceipt.dawnReceiptId", "browser launch Dawn receipt ID must match proof surface comparison"))
                if isinstance(doe_receipt, dict) and comparison_receipt.get("doeReceiptId") != doe_receipt.get("receiptId"):
                    failures.append(failure("browser_launch_comparison_doe_receipt_mismatch", "browserLaunchReceipt.comparisonReceipt.doeReceiptId", "browser launch Doe receipt ID must match proof surface comparison"))
        diagnostics = proof_page_payload.get("diagnostics") if isinstance(proof_page_payload, dict) else None
        if isinstance(diagnostics, dict) and receipt.get("activeBackend") != diagnostics.get("activeBackend"):
            failures.append(failure("browser_launch_active_backend_mismatch", "browserLaunchReceipt.activeBackend", "browser launch activeBackend must match proof surface diagnostics"))
    return failures


def check_browser_launch_receipt_artifact(
    payload: dict[str, Any],
    verify_files_root: Path | None,
    *,
    require_release_candidate: bool,
) -> list[dict[str, str]]:
    artifact = payload.get("browserLaunchReceipt")
    candidate_required = require_release_candidate or payload.get("releaseStatus") == "release_candidate"
    if artifact is None:
        if not candidate_required:
            return []
        return [
            failure(
                "missing_browser_launch_receipt",
                "browserLaunchReceipt",
                "release candidates must hash-bind a browser release launch receipt",
            )
        ]
    failures = check_artifact(
        artifact,
        "browserLaunchReceipt",
        "browser_release_launch_receipt",
        verify_files_root,
    )
    if not isinstance(artifact, dict):
        return failures
    receipt_payload = load_artifact_payload(artifact, "browserLaunchReceipt", verify_files_root)
    if receipt_payload is not None:
        failures.extend(check_browser_launch_receipt_payload(receipt_payload, payload, verify_files_root))
    return failures


def expected_release_provenance(payload: dict[str, Any]) -> dict[str, Any]:
    fields = ("browserProduct", "platform", "releaseArchive", "releaseArchiveManifest", "publicDownloadReceipt", "browserExecutableArchivePath", "browserAppMetadataArchivePath", "doeRuntimeArchivePath", "dawnFallbackRuntimeArchivePath")
    return {field: payload.get(field) for field in fields}


def check_proof_surface_release_provenance(proof_payload: dict[str, Any], payload: dict[str, Any]) -> list[dict[str, str]]:
    proof_page = proof_payload.get("proofPage")
    provenance = proof_page.get("releaseProvenance") if isinstance(proof_page, dict) else None
    if provenance == expected_release_provenance(payload):
        return []
    return [failure(
        "proof_surface_release_provenance_mismatch", "proofSurface.proofPage.releaseProvenance",
        "proof page releaseProvenance must match release bundle",
    )]


def check_proof_surface_diagnostics_match_release_artifacts(
    proof_payload: dict[str, Any],
    payload: dict[str, Any],
    *,
    require_release_candidate: bool,
) -> list[dict[str, str]]:
    if not require_release_candidate:
        return []
    proof_page = proof_payload.get("proofPage")
    diagnostics = proof_page.get("diagnostics") if isinstance(proof_page, dict) else None
    if not isinstance(diagnostics, dict):
        return []
    expected_compiler_path = artifact_field(payload, "shaderCompiler", "path")
    if diagnostics.get("compilerPath") == expected_compiler_path:
        return []
    return [
        failure(
            "proof_surface_compiler_path_mismatch",
            "proofSurface.proofPage.diagnostics.compilerPath",
            "proof page compilerPath must match release bundle shaderCompiler.path",
        )
    ]


def runtime_identity_artifact_identity_rows(runtime_identity: dict[str, Any]) -> tuple[tuple[str, dict[str, Any]], ...]:
    rows: list[tuple[str, dict[str, Any]]] = []
    provider = runtime_identity.get("provider")
    provider_identity = provider.get("artifactIdentity") if isinstance(provider, dict) else None
    if isinstance(provider_identity, dict):
        rows.append(("provider.artifactIdentity", provider_identity))
    runtime_selection = runtime_identity.get("runtimeSelection")
    selection_identity = (
        runtime_selection.get("artifactIdentity")
        if isinstance(runtime_selection, dict)
        else None
    )
    if isinstance(selection_identity, dict):
        rows.append(("runtimeSelection.artifactIdentity", selection_identity))
    return tuple(rows)


def check_runtime_identity_matches_release_artifacts(
    proof_payload: dict[str, Any],
    payload: dict[str, Any],
    verify_files_root: Path | None,
    *,
    require_release_candidate: bool,
) -> list[dict[str, str]]:
    if not require_release_candidate or verify_files_root is None:
        return []
    runtime_identity_path = proof_payload.get("runtimeIdentityPath")
    if not isinstance(runtime_identity_path, str) or not runtime_identity_path:
        return [
            failure(
                "missing_proof_surface_runtime_identity_path",
                "proofSurface.runtimeIdentityPath",
                "release-candidate proof surface must name runtimeIdentityPath",
            )
        ]
    resolved_path = resolve_artifact_path(runtime_identity_path, verify_files_root)
    if resolved_path is None or not resolved_path.is_file():
        return [
            failure(
                "proof_surface_runtime_identity_missing",
                "proofSurface.runtimeIdentityPath",
                "release-candidate runtime identity path must resolve under verify-files-root",
            )
        ]
    try:
        runtime_identity = load_json(resolved_path)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        return [
            failure(
                "proof_surface_runtime_identity_load_failed",
                "proofSurface.runtimeIdentityPath",
                f"release-candidate runtime identity cannot be loaded: {exc}",
            )
        ]
    identity_rows = runtime_identity_artifact_identity_rows(runtime_identity)
    if not identity_rows:
        return [
            failure(
                "proof_surface_runtime_identity_artifact_identity_missing",
                "proofSurface.runtimeIdentityPath",
                "release-candidate runtime identity must carry artifactIdentity hashes",
            )
        ]
    failures: list[dict[str, str]] = []
    for source_path, artifact_identity in identity_rows:
        for field, bundle_artifact_field, code, message in (
            (
                "browserExecutableSha256",
                "browserBinary",
                "proof_surface_runtime_identity_browser_hash_mismatch",
                "runtime identity browserExecutableSha256 must match release bundle browserBinary.sha256",
            ),
            (
                "doeLibSha256",
                "doeRuntime",
                "proof_surface_runtime_identity_doe_hash_mismatch",
                "runtime identity doeLibSha256 must match release bundle doeRuntime.sha256",
            ),
            (
                "dawnRuntimeSha256",
                "dawnFallbackRuntime",
                "proof_surface_runtime_identity_dawn_hash_mismatch",
                "runtime identity dawnRuntimeSha256 must match release bundle dawnFallbackRuntime.sha256",
            ),
        ):
            expected = artifact_field(payload, bundle_artifact_field, "sha256")
            if artifact_identity.get(field) != expected:
                failures.append(
                    failure(
                        code,
                        f"proofSurface.runtimeIdentityPath.{source_path}.{field}",
                        message,
                    )
                )
    return failures


def check_promotion_receipt_matches_claims(
    promotion_receipts: Any,
    claim_reports: Any,
    verify_files_root: Path | None,
    *,
    require_claimable_promotion: bool = False,
) -> list[dict[str, str]]:
    if verify_files_root is None or not isinstance(promotion_receipts, list) or not isinstance(claim_reports, list):
        return []

    claim_hashes = {
        row.get("sha256")
        for row in claim_reports
        if isinstance(row, dict) and isinstance(row.get("sha256"), str)
    }
    covered_hashes: set[str] = set()
    failures: list[dict[str, str]] = []
    for index, artifact in enumerate(promotion_receipts):
        if not isinstance(artifact, dict) or artifact.get("kind") != "browser_claim_promotion_receipt":
            continue
        artifact_path = artifact.get("path")
        if not isinstance(artifact_path, str) or not artifact_path:
            continue
        resolved_path = resolve_artifact_path(artifact_path, verify_files_root)
        if resolved_path is None:
            continue
        if not resolved_path.is_file():
            continue
        payload = load_json(resolved_path)
        for item in promotion_check.check_receipt(payload, verify_files_root):
            if (
                not require_claimable_promotion
                and item["code"] in PROMOTION_RECEIPT_CLAIM_FAILURE_CODES
            ):
                continue
            failures.append(
                failure(
                    f"promotion_receipt_{item['code']}",
                    f"promotionReceipts[{index}].{item['path']}",
                    item["message"],
                )
            )
        for row in payload.get("artifacts", []):
            if isinstance(row, dict) and isinstance(row.get("sha256"), str):
                covered_hashes.add(row["sha256"])

    for index, claim_report in enumerate(claim_reports):
        if not isinstance(claim_report, dict):
            continue
        claim_hash = claim_report.get("sha256")
        if isinstance(claim_hash, str) and claim_hash not in covered_hashes:
            failures.append(
                failure(
                    "promotion_receipt_missing_claim_report",
                    f"claimReports[{index}].sha256",
                    "promotion receipts must cover every bundled claim report hash",
                )
            )
    return failures


def check_proof_surface_artifact(
    payload: dict[str, Any],
    verify_files_root: Path | None,
    *,
    require_release_candidate: bool,
) -> list[dict[str, str]]:
    proof_surface = payload.get("proofSurface")
    candidate_required = require_release_candidate or payload.get("releaseStatus") == "release_candidate"
    if proof_surface is None:
        if not candidate_required:
            return []
        return [
            failure(
                "missing_proof_surface",
                "proofSurface",
                "release candidates must hash-bind the browser published proof surface",
            )
        ]
    failures = check_artifact(
        proof_surface,
        "proofSurface",
        "browser_published_proof_surface",
        verify_files_root,
    )
    if verify_files_root is None or not isinstance(proof_surface, dict):
        return failures
    proof_surface_path = proof_surface.get("path")
    if not isinstance(proof_surface_path, str) or not proof_surface_path:
        return failures
    resolved_path = resolve_artifact_path(proof_surface_path, verify_files_root)
    if resolved_path is None or not resolved_path.is_file():
        return failures
    try:
        proof_payload = load_json(resolved_path)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        failures.append(
            failure(
                "proof_surface_load_failed",
                "proofSurface.path",
                f"proof surface cannot be loaded: {exc}",
            )
        )
        return failures
    for item in proof_surface_check.check_surface(
        proof_payload,
        verify_files_root=verify_files_root,
        root=verify_files_root,
        require_public_urls=candidate_required,
    ):
        failures.append(
            failure(
                f"proof_surface_{item['code']}",
                f"proofSurface.{item['path']}",
                item["message"],
            )
        )
    failures.extend(check_proof_surface_release_provenance(proof_payload, payload))
    failures.extend(
        check_proof_surface_diagnostics_match_release_artifacts(
            proof_payload,
            payload,
            require_release_candidate=candidate_required,
        )
    )
    failures.extend(
        check_runtime_identity_matches_release_artifacts(
            proof_payload,
            payload,
            verify_files_root,
            require_release_candidate=candidate_required,
        )
    )
    return failures


def check_proof_surface_check_artifact(
    payload: dict[str, Any],
    verify_files_root: Path | None,
    *,
    require_release_candidate: bool,
) -> list[dict[str, str]]:
    proof_surface_check_artifact = payload.get("proofSurfaceCheck")
    candidate_required = require_release_candidate or payload.get("releaseStatus") == "release_candidate"
    if proof_surface_check_artifact is None:
        if not candidate_required:
            return []
        return [
            failure(
                "missing_proof_surface_check",
                "proofSurfaceCheck",
                "release candidates must hash-bind the browser published proof-surface checker report",
            )
        ]
    failures = check_artifact(
        proof_surface_check_artifact,
        "proofSurfaceCheck",
        "browser_published_proof_surface_check",
        verify_files_root,
    )
    if verify_files_root is None or not isinstance(proof_surface_check_artifact, dict):
        return failures
    check_payload = load_artifact_payload(
        proof_surface_check_artifact,
        "proofSurfaceCheck",
        verify_files_root,
    )
    if check_payload is None:
        return failures
    if check_payload.get("artifactKind") != "browser_published_proof_surface_check":
        failures.append(
            failure(
                "proof_surface_check_wrong_kind",
                "proofSurfaceCheck.artifactKind",
                "proofSurfaceCheck artifactKind must be browser_published_proof_surface_check",
            )
        )
    if check_payload.get("status") != "pass":
        failures.append(
            failure(
                "proof_surface_check_not_pass",
                "proofSurfaceCheck.status",
                "proof-surface checker report must pass",
            )
        )
    if check_payload.get("verifyFilesRootProvided") is not True:
        failures.append(
            failure(
                "proof_surface_check_without_file_verification",
                "proofSurfaceCheck.verifyFilesRootProvided",
                "proof-surface checker report must verify referenced files",
            )
        )
    if candidate_required and check_payload.get("requirePublicUrls") is not True:
        failures.append(
            failure(
                "proof_surface_check_without_public_urls",
                "proofSurfaceCheck.requirePublicUrls",
                "release-candidate proof-surface checker report must require public gallery URLs",
            )
        )
    proof_surface = payload.get("proofSurface")
    if isinstance(proof_surface, dict):
        if check_payload.get("surfacePath") != proof_surface.get("path"):
            failures.append(
                failure(
                    "proof_surface_check_path_mismatch",
                    "proofSurfaceCheck.surfacePath",
                    "proof-surface checker report surfacePath must match proofSurface.path",
                )
            )
        if check_payload.get("surfaceSha256") != proof_surface.get("sha256"):
            failures.append(
                failure(
                    "proof_surface_check_hash_mismatch",
                    "proofSurfaceCheck.surfaceSha256",
                    "proof-surface checker report surfaceSha256 must match proofSurface.sha256",
                )
            )
    return failures


def check_runtime_frontier_bundle_artifact(payload: dict[str, Any], verify_files_root: Path | None, *, require_release_candidate: bool, bundle_path: str | None = None) -> list[dict[str, str]]:
    artifact = payload.get("runtimeFrontierBundle")
    candidate_required = require_release_candidate or payload.get("releaseStatus") == "release_candidate"
    if artifact is None:
        return [failure("missing_runtime_frontier_bundle", "runtimeFrontierBundle", "release candidates must hash-bind the browser runtime frontier bundle")] if candidate_required else []
    failures = check_artifact(artifact, "runtimeFrontierBundle", "browser_runtime_frontier_bundle", verify_files_root)
    if verify_files_root is None or not isinstance(artifact, dict):
        return failures
    receipt = load_artifact_payload(artifact, "runtimeFrontierBundle", verify_files_root)
    if receipt is None:
        return failures
    invalid_payload_error = receipt.get("_invalid_payload_error")
    if isinstance(invalid_payload_error, dict):
        return failures + [invalid_payload_error]
    if receipt.get("artifactKind") != "browser_runtime_frontier_bundle":
        failures.append(failure("invalid_runtime_frontier_bundle_artifact_kind", "runtimeFrontierBundle.path", "runtime frontier bundle artifactKind must be browser_runtime_frontier_bundle"))
    if receipt.get("status") != "pass": failures.append(failure("runtime_frontier_bundle_status_not_pass", "runtimeFrontierBundle.status", "runtime frontier bundle status must be pass"))
    if candidate_required and (receipt.get("claimabilityStatus") != "claimable" or receipt.get("claimBlockers") != [] or receipt.get("claimBlockerSummary") != [] or receipt.get("failures") != [] or not isinstance(receipt.get("summary"), dict) or receipt["summary"].get("claimBlockerCount") != 0 or receipt["summary"].get("failureCount") != 0):
        failures.append(failure("runtime_frontier_not_claimable", "runtimeFrontierBundle.claimabilityStatus", "release-candidate runtime frontier bundle must be claimable with no claim blockers or failures"))
    components = receipt.get("componentReceipts")
    release_summary = components.get("releaseArtifactBundle") if isinstance(components, dict) else None
    if not isinstance(release_summary, dict):
        return failures + [failure("missing_runtime_frontier_release_summary", "runtimeFrontierBundle.componentReceipts.releaseArtifactBundle", "runtime frontier bundle must summarize the release artifact bundle")]
    base = "runtimeFrontierBundle.componentReceipts.releaseArtifactBundle"
    promotion_receipts = payload.get("promotionReceipts", [])
    promotion_paths = {row.get("path") for row in promotion_receipts if isinstance(row, dict)} if isinstance(promotion_receipts, list) else set()
    promotion_summary = components.get("claimPromotionReceipt")
    runtime_summary = components.get("runtimeIdentity")
    if candidate_required and (not isinstance(runtime_summary, dict) or runtime_summary.get("status") != "pass" or not isinstance(promotion_summary, dict) or promotion_summary.get("status") != "pass" or promotion_summary.get("promotionStatus") != "promotable" or release_summary.get("status") != "pass"):
        failures.append(failure("runtime_frontier_component_not_pass", "runtimeFrontierBundle.componentReceipts", "release-candidate runtime frontier components must be pass and promotion must be promotable"))
    promotion_path = (
        promotion_summary.get("path") if isinstance(promotion_summary, dict) else None
    )
    if not isinstance(promotion_path, str) or not artifact_path_matches(
        promotion_path,
        {path for path in promotion_paths if isinstance(path, str)},
        verify_files_root,
    ):
        failures.append(failure("runtime_frontier_promotion_receipt_mismatch", "runtimeFrontierBundle.componentReceipts.claimPromotionReceipt.path", "runtime frontier promotion receipt path must match release bundle promotionReceipts"))
    proof_surface = payload.get("proofSurface"); proof_payload = load_artifact_payload(proof_surface, "proofSurface", verify_files_root) if isinstance(proof_surface, dict) else None
    runtime_path = (
        runtime_summary.get("path") if isinstance(runtime_summary, dict) else None
    )
    proof_runtime_path = (
        proof_payload.get("runtimeIdentityPath") if isinstance(proof_payload, dict) else None
    )
    if (
        isinstance(proof_payload, dict)
        and "_invalid_payload_error" not in proof_payload
        and (
            not isinstance(runtime_path, str)
            or not isinstance(proof_runtime_path, str)
            or not artifact_path_matches(
                runtime_path,
                {proof_runtime_path},
                verify_files_root,
            )
        )
    ):
        failures.append(failure("runtime_frontier_runtime_identity_mismatch", "runtimeFrontierBundle.componentReceipts.runtimeIdentity.path", "runtime frontier runtime identity path must match proof surface runtimeIdentityPath"))
    if bundle_path is not None and release_summary.get("path") != bundle_path:
        failures.append(failure("runtime_frontier_bundle_path_mismatch", f"{base}.path", "runtime frontier release bundle path must match checked release bundle"))
    if release_summary.get("artifactKind") != payload.get("artifactKind"):
        failures.append(failure("runtime_frontier_release_artifact_kind_mismatch", f"{base}.artifactKind", "runtime frontier release artifactKind must match release bundle"))
    for field, code, message in (
        ("bundleId", "runtime_frontier_bundle_id_mismatch", "runtime frontier release bundleId must match release bundle"),
        ("releaseStatus", "runtime_frontier_release_status_mismatch", "runtime frontier releaseStatus must match release bundle"),
    ):
        if release_summary.get(field) != payload.get(field):
            failures.append(failure(code, f"{base}.{field}", message))
    if candidate_required and release_summary.get("releaseBundleIdentitySha256") != release_bundle_identity_sha256(payload):
        failures.append(failure("runtime_frontier_release_identity_hash_mismatch", f"{base}.releaseBundleIdentitySha256", "runtime frontier release bundle identity hash must match checked release bundle"))
    verification = release_summary.get("artifactVerification")
    if candidate_required and (not isinstance(verification, dict) or verification.get("verified") is not True):
        failures.append(failure("runtime_frontier_release_not_verified", f"{base}.artifactVerification.verified", "runtime frontier release artifact verification must be true for release candidates"))
    return failures


def check_bundle(
    payload: dict[str, Any],
    verify_files_root: Path | None = None,
    *,
    require_release_candidate: bool = False,
    bundle_path: str | None = None,
    skip_runtime_frontier_bundle_artifact: bool = False,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    candidate_required = require_release_candidate or payload.get("releaseStatus") == "release_candidate"
    failures.extend(check_release_bundle_identity(payload))
    if require_release_candidate:
        if payload.get("releaseStatus") != "release_candidate":
            failures.append(failure("release_candidate_required", "releaseStatus", "browser release artifact bundle must be a release_candidate"))
        if verify_files_root is None:
            failures.append(failure("release_candidate_requires_verification", "verifyFilesRoot", "release-candidate browser release bundles require --verify-files-root"))
    failures.extend(check_browser_product_identity(payload, require_release_candidate=require_release_candidate))
    failures.extend(check_artifact(payload.get("browserBinary"), "browserBinary", "browser_binary", verify_files_root))
    failures.extend(check_release_archive_surface(payload, verify_files_root, require_release_candidate=require_release_candidate))
    failures.extend(check_release_archive_manifest_artifact(payload, verify_files_root, require_release_candidate=require_release_candidate))
    failures.extend(
        check_package_inputs_artifact(
            payload,
            verify_files_root,
            require_release_candidate=require_release_candidate,
        )
    )
    failures.extend(check_artifact(payload.get("doeRuntime"), "doeRuntime", "doe_runtime", verify_files_root))
    dawn_fallback_runtime = payload.get("dawnFallbackRuntime")
    if dawn_fallback_runtime is None and candidate_required:
        failures.append(failure("missing_dawn_fallback_runtime", "dawnFallbackRuntime", "release candidates must hash-bind the Dawn fallback runtime"))
    elif dawn_fallback_runtime is not None:
        failures.extend(check_artifact(dawn_fallback_runtime, "dawnFallbackRuntime", "dawn_fallback_runtime", verify_files_root))
    failures.extend(check_artifact(payload.get("shaderCompiler"), "shaderCompiler", "shader_compiler", verify_files_root))
    failures.extend(check_proof_surface_artifact(payload, verify_files_root, require_release_candidate=require_release_candidate))
    failures.extend(check_proof_surface_check_artifact(payload, verify_files_root, require_release_candidate=require_release_candidate))
    failures.extend(check_public_download_receipt_artifact(payload, verify_files_root, require_release_candidate=require_release_candidate))
    failures.extend(check_browser_launch_receipt_artifact(payload, verify_files_root, require_release_candidate=require_release_candidate))
    failures.extend(check_chromium_source_checkout_artifact(payload, verify_files_root, require_release_candidate=require_release_candidate))
    if skip_runtime_frontier_bundle_artifact:
        runtime_frontier_bundle = payload.get("runtimeFrontierBundle")
        if candidate_required and runtime_frontier_bundle is None:
            failures.append(failure("missing_runtime_frontier_bundle", "runtimeFrontierBundle", "release candidates must hash-bind the browser runtime frontier bundle"))
        elif runtime_frontier_bundle is not None:
            failures.extend(
                check_artifact(
                    runtime_frontier_bundle,
                    "runtimeFrontierBundle",
                    "browser_runtime_frontier_bundle",
                )
            )
    else:
        failures.extend(check_runtime_frontier_bundle_artifact(payload, verify_files_root, require_release_candidate=require_release_candidate, bundle_path=bundle_path))

    contracts = payload.get("contracts", [])
    claim_reports = payload.get("claimReports", [])
    promotion_receipts = payload.get("promotionReceipts", [])
    policies = payload.get("policies", [])
    for index, artifact in enumerate(contracts if isinstance(contracts, list) else []):
        failures.extend(check_artifact(artifact, f"contracts[{index}]", verify_files_root=verify_files_root))
    for index, artifact in enumerate(claim_reports if isinstance(claim_reports, list) else []):
        failures.extend(check_artifact(artifact, f"claimReports[{index}]", verify_files_root=verify_files_root))
    for index, artifact in enumerate(promotion_receipts if isinstance(promotion_receipts, list) else []):
        failures.extend(check_artifact(artifact, f"promotionReceipts[{index}]", verify_files_root=verify_files_root))
    for index, artifact in enumerate(policies if isinstance(policies, list) else []):
        failures.extend(check_artifact(artifact, f"policies[{index}]", verify_files_root=verify_files_root))

    contract_kinds = {row.get("kind") for row in contracts if isinstance(row, dict)}
    claim_kinds = {row.get("kind") for row in claim_reports if isinstance(row, dict)}
    promotion_receipt_kinds = {row.get("kind") for row in promotion_receipts if isinstance(row, dict)}
    policy_kinds = {row.get("kind") for row in policies if isinstance(row, dict)}
    for kind in sorted(REQUIRED_CONTRACT_KINDS - contract_kinds):
        failures.append(failure("missing_contract_kind", "contracts", f"missing contract artifact kind {kind}"))
    for kind in sorted(REQUIRED_CLAIM_KINDS - claim_kinds):
        failures.append(failure("missing_claim_report_kind", "claimReports", f"missing claim report artifact kind {kind}"))
    for kind in sorted(REQUIRED_PROMOTION_RECEIPT_KINDS - promotion_receipt_kinds):
        failures.append(
            failure(
                "missing_promotion_receipt_kind",
                "promotionReceipts",
                f"missing promotion receipt artifact kind {kind}",
            )
        )
    for kind in sorted(REQUIRED_POLICY_KINDS - policy_kinds):
        failures.append(failure("missing_policy_kind", "policies", f"missing policy artifact kind {kind}"))
    failures.extend(
        check_promotion_receipt_matches_claims(
            promotion_receipts,
            claim_reports,
            verify_files_root,
            require_claimable_promotion=candidate_required,
        )
    )
    if payload.get("releaseStatus") == "release_candidate" and payload.get("failureCodes"):
        failures.append(failure("release_candidate_has_failures", "failureCodes", "release candidates cannot carry failureCodes"))
    return failures


def main() -> int:
    args = parse_args()
    verify_files_root = Path(args.verify_files_root).resolve() if args.verify_files_root else None
    failures = check_bundle(
        load_json(Path(args.bundle)),
        verify_files_root,
        require_release_candidate=args.require_release_candidate,
        bundle_path=args.bundle,
    )
    report = {
        "schemaVersion": 1,
        "artifactKind": "browser_release_artifact_bundle_check",
        "status": "fail" if failures else "pass",
        "failures": failures,
    }
    if args.emit_json:
        print(json.dumps(report, indent=2))
    elif failures:
        print("FAIL: browser release artifact bundle")
        for item in failures:
            print(f"- {item['code']}: {item['path']}: {item['message']}")
    else:
        print("PASS: browser release artifact bundle")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
