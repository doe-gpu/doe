#!/usr/bin/env python3
"""Preflight browser release-candidate provenance before bundle assembly."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path, PurePosixPath
from typing import Any

try:
    from bench.tools._public_url import is_public_https_url
except ModuleNotFoundError:
    from _public_url import is_public_https_url

try:
    from bench.tools import build_browser_release_artifact_bundle as bundle_builder
except ModuleNotFoundError:
    import build_browser_release_artifact_bundle as bundle_builder  # type: ignore

try:
    from bench.tools import check_browser_release_package_inputs as package_inputs_check
except ModuleNotFoundError:
    import check_browser_release_package_inputs as package_inputs_check  # type: ignore


REPO_ROOT = Path(__file__).resolve().parents[2]
PRODUCT_DISPLAY_NAMES = {
    "doe-browser": "Doe Browser",
    "fawn-doe": "Fawn Doe",
}
INITIAL_CANDIDATE_PLATFORM = {
    "os": "macos",
    "arch": "arm64",
    "packageFormat": "zip",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--release-archive", required=True)
    parser.add_argument("--release-archive-url", required=True)
    parser.add_argument("--release-archive-manifest", required=True)
    parser.add_argument("--public-download-receipt", required=True)
    parser.add_argument("--proof-surface", required=True)
    parser.add_argument("--proof-surface-check", required=True)
    parser.add_argument("--browser-launch-receipt", required=True)
    parser.add_argument(
        "--package-inputs",
        default="",
        help=(
            "Optional browser_release_package_inputs_check report used as the "
            "release-candidate source of truth for product/platform/member paths."
        ),
    )
    parser.add_argument("--product-id", choices=tuple(PRODUCT_DISPLAY_NAMES), default="fawn-doe")
    parser.add_argument("--product-name", choices=tuple(PRODUCT_DISPLAY_NAMES.values()), default="Fawn Doe")
    parser.add_argument("--product-version", default="")
    parser.add_argument(
        "--product-channel",
        choices=("diagnostic", "release_candidate", "release"),
        default="release_candidate",
    )
    parser.add_argument("--platform-os", choices=("macos", "linux", "windows"), default="macos")
    parser.add_argument("--platform-arch", choices=("arm64", "x64"), default="arm64")
    parser.add_argument("--package-format", choices=("zip",), default="zip")
    parser.add_argument("--browser-executable-archive-path", default="")
    parser.add_argument("--browser-app-metadata-archive-path", default="")
    parser.add_argument("--doe-runtime-archive-path", default="")
    parser.add_argument("--dawn-fallback-runtime-archive-path", default="")
    parser.add_argument(
        "--verify-files-root",
        default="",
        help="Resolve relative paths in nested receipt artifacts under this root.",
    )
    parser.add_argument("--out", default="")
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def failure(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def repo_relative(path: Path) -> str:
    resolved = path.resolve()
    try:
        return str(resolved.relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require_file(path: Path, label: str) -> None:
    if not path.is_file():
        raise FileNotFoundError(f"{label} must be an existing file: {path}")


def load_json_object(path: Path, label: str) -> dict[str, Any]:
    require_file(path, label)
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"{label} must be a JSON object: {path}")
    return payload


def artifact(path: Path, kind: str, label: str, *, download_url: str = "") -> dict[str, str]:
    require_file(path, label)
    payload = {
        "path": repo_relative(path),
        "sha256": sha256_file(path),
        "kind": kind,
    }
    if download_url:
        payload["downloadUrl"] = download_url
    return payload


def resolve_path(path_text: str, root: Path) -> Path | None:
    path = Path(path_text)
    candidate = path if path.is_absolute() else root.joinpath(*PurePosixPath(path_text).parts)
    resolved = candidate.resolve()
    if path.is_absolute():
        return resolved
    try:
        resolved.relative_to(root.resolve())
    except ValueError:
        return None
    return resolved


def path_matches(actual: Any, expected: Any, root: Path) -> bool:
    if not isinstance(actual, str) or not isinstance(expected, str):
        return False
    if actual == expected:
        return True
    actual_path = resolve_path(actual, root)
    expected_path = resolve_path(expected, root)
    return actual_path is not None and expected_path is not None and actual_path == expected_path


def string_map(value: Any) -> dict[str, str] | None:
    if not isinstance(value, dict):
        return None
    result: dict[str, str] = {}
    for key, item in value.items():
        if not isinstance(key, str) or not isinstance(item, str):
            return None
        result[key] = item
    return result


def load_package_inputs_report(
    path_text: str,
    root: Path,
) -> tuple[dict[str, Any] | None, Path | None, list[dict[str, str]]]:
    if not path_text:
        return None, None, []
    resolved = resolve_path(path_text, root)
    if resolved is None:
        raise ValueError(f"package inputs report must resolve under verify-files-root: {path_text}")
    payload = bundle_builder.package_inputs_descriptor(str(resolved))
    return payload, resolved, package_inputs_candidate_failures(payload)


def package_inputs_candidate_failures(payload: dict[str, Any]) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    if payload.get("releaseCandidateEligible") is not True:
        failures.append(
            failure(
                "package_inputs_not_release_candidate_eligible",
                "packageInputs.releaseCandidateEligible",
                "package inputs report must be release-candidate eligible",
            )
        )
    if payload.get("evidenceMode") != "release_candidate":
        failures.append(
            failure(
                "package_inputs_not_release_candidate_evidence",
                "packageInputs.evidenceMode",
                "package inputs evidenceMode must be release_candidate",
            )
        )
    if payload.get("releaseCandidateBlockers") != []:
        failures.append(
            failure(
                "package_inputs_release_candidate_blockers_present",
                "packageInputs.releaseCandidateBlockers",
                "package inputs report must carry no release-candidate blockers",
            )
        )
    if payload.get("failures") != []:
        failures.append(
            failure(
                "package_inputs_failures_present",
                "packageInputs.failures",
                "passing package inputs report must carry no failures",
            )
        )
    summary = payload.get("summary")
    if not isinstance(summary, dict) or summary.get("packageable") is not True:
        failures.append(
            failure(
                "package_inputs_summary_not_packageable",
                "packageInputs.summary.packageable",
                "passing package inputs report summary.packageable must be true",
            )
        )
    failures.extend(
        package_inputs_check.release_candidate_binary_identity_failures(
            payload,
            path_prefix="packageInputs",
        )
    )
    return failures


def required_text(value: str, label: str) -> str:
    if not value:
        raise ValueError(f"{label} is required when --package-inputs is not provided")
    return value


def resolve_member_path(
    *,
    explicit_path: str,
    package_inputs: dict[str, Any] | None,
    role: str,
    option: str,
) -> str:
    if package_inputs is None:
        return required_text(explicit_path, option)
    derived_path = bundle_builder.package_input_archive_path(package_inputs, role)
    if explicit_path and explicit_path != derived_path:
        raise ValueError(f"{option} must match package inputs role {role}")
    return derived_path


def candidate_identity(
    *,
    product_id: str,
    product_name: str,
    product_version: str,
    product_channel: str,
    platform_os: str,
    platform_arch: str,
    package_format: str,
    browser_executable_archive_path: str,
    browser_app_metadata_archive_path: str,
    doe_runtime_archive_path: str,
    dawn_fallback_runtime_archive_path: str,
    package_inputs: dict[str, Any] | None,
) -> tuple[dict[str, str], dict[str, str], dict[str, str]]:
    if package_inputs is not None:
        product = string_map(package_inputs.get("browserProduct"))
        platform = string_map(package_inputs.get("platform"))
        if product is None:
            raise ValueError("package inputs browserProduct must be a string object")
        if platform is None:
            raise ValueError("package inputs platform must be a string object")
    else:
        product = {
            "productId": product_id,
            "displayName": product_name,
            "version": required_text(product_version, "--product-version"),
            "channel": product_channel,
        }
        platform = {
            "os": platform_os,
            "arch": platform_arch,
            "packageFormat": package_format,
        }
    members = {
        "browserExecutable": resolve_member_path(
            explicit_path=browser_executable_archive_path,
            package_inputs=package_inputs,
            role="browserExecutable",
            option="--browser-executable-archive-path",
        ),
        "appMetadata": resolve_member_path(
            explicit_path=browser_app_metadata_archive_path,
            package_inputs=package_inputs,
            role="appMetadata",
            option="--browser-app-metadata-archive-path",
        ),
        "doeRuntime": resolve_member_path(
            explicit_path=doe_runtime_archive_path,
            package_inputs=package_inputs,
            role="doeRuntime",
            option="--doe-runtime-archive-path",
        ),
        "dawnFallbackRuntime": resolve_member_path(
            explicit_path=dawn_fallback_runtime_archive_path,
            package_inputs=package_inputs,
            role="dawnFallbackRuntime",
            option="--dawn-fallback-runtime-archive-path",
        ),
    }
    return product, platform, members


def check_equal(actual: Any, expected: Any, path: str, code: str, message: str) -> list[dict[str, str]]:
    if actual == expected:
        return []
    return [failure(code, path, message)]


def check_artifact_ref(
    actual: Any,
    expected: dict[str, Any],
    path: str,
    root: Path,
) -> list[dict[str, str]]:
    if not isinstance(actual, dict):
        return [failure("invalid_artifact", path, "artifact reference must be an object")]
    failures: list[dict[str, str]] = []
    if not path_matches(actual.get("path"), expected.get("path"), root):
        failures.append(
            failure(
                "artifact_path_mismatch",
                f"{path}.path",
                "artifact path must match the expected release candidate path",
            )
        )
    for field in ("sha256", "kind", "downloadUrl"):
        if field in expected and actual.get(field) != expected.get(field):
            failures.append(
                failure(
                    "artifact_field_mismatch",
                    f"{path}.{field}",
                    f"artifact {field} must match the expected release candidate value",
                )
            )
    return failures


def expected_release_provenance(
    *,
    browser_product: dict[str, str],
    platform: dict[str, str],
    release_archive: dict[str, str],
    release_archive_manifest: dict[str, str],
    public_download_receipt: dict[str, str],
    browser_executable_archive_path: str,
    browser_app_metadata_archive_path: str,
    doe_runtime_archive_path: str,
    dawn_fallback_runtime_archive_path: str,
) -> dict[str, Any]:
    return {
        "browserProduct": browser_product,
        "platform": platform,
        "releaseArchive": release_archive,
        "releaseArchiveManifest": release_archive_manifest,
        "publicDownloadReceipt": public_download_receipt,
        "browserExecutableArchivePath": browser_executable_archive_path,
        "browserAppMetadataArchivePath": browser_app_metadata_archive_path,
        "doeRuntimeArchivePath": doe_runtime_archive_path,
        "dawnFallbackRuntimeArchivePath": dawn_fallback_runtime_archive_path,
    }


def check_product_and_platform(
    browser_product: dict[str, str],
    platform: dict[str, str],
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    expected_name = PRODUCT_DISPLAY_NAMES.get(browser_product.get("productId", ""))
    if browser_product.get("displayName") != expected_name:
        failures.append(
            failure(
                "browser_product_name_mismatch",
                "browserProduct.displayName",
                "browser product displayName must match productId",
            )
        )
    if browser_product.get("channel") != "release_candidate":
        failures.append(
            failure(
                "candidate_product_channel_required",
                "browserProduct.channel",
                "release-candidate provenance must use browserProduct.channel=release_candidate",
            )
        )
    if platform != INITIAL_CANDIDATE_PLATFORM:
        failures.append(
            failure(
                "candidate_platform_not_macos_arm64",
                "platform",
                "initial release-candidate provenance must target macOS arm64 zip",
            )
        )
    return failures


def check_release_archive_manifest(
    manifest: dict[str, Any],
    *,
    expected_archive: dict[str, str],
    expected_product: dict[str, str],
    expected_platform: dict[str, str],
    expected_package_inputs: dict[str, str] | None,
    browser_executable_archive_path: str,
    browser_app_metadata_archive_path: str,
    doe_runtime_archive_path: str,
    dawn_fallback_runtime_archive_path: str,
    root: Path,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    if manifest.get("artifactKind") != "browser_release_archive_manifest":
        failures.append(
            failure(
                "release_archive_manifest_wrong_kind",
                "releaseArchiveManifest.artifactKind",
                "release archive manifest artifactKind must be browser_release_archive_manifest",
            )
        )
    archive = manifest.get("archive")
    manifest_archive = {
        key: value for key, value in expected_archive.items() if key != "downloadUrl"
    }
    failures.extend(check_artifact_ref(archive, manifest_archive, "releaseArchiveManifest.archive", root))
    if isinstance(archive, dict):
        archive_path = resolve_path(str(expected_archive["path"]), root)
        if archive_path is not None and archive_path.is_file() and archive.get("byteLength") != archive_path.stat().st_size:
            failures.append(
                failure(
                    "release_archive_manifest_size_mismatch",
                    "releaseArchiveManifest.archive.byteLength",
                    "release archive manifest byteLength must match the archive file",
                )
            )
    failures.extend(
        check_equal(
            manifest.get("browserProduct"),
            expected_product,
            "releaseArchiveManifest.browserProduct",
            "release_archive_manifest_product_mismatch",
            "release archive manifest browserProduct must match release candidate product",
        )
    )
    failures.extend(
        check_equal(
            manifest.get("platform"),
            expected_platform,
            "releaseArchiveManifest.platform",
            "release_archive_manifest_platform_mismatch",
            "release archive manifest platform must match release candidate platform",
        )
    )
    if expected_package_inputs is not None:
        source_package_inputs = manifest.get("sourcePackageInputs")
        if not isinstance(source_package_inputs, dict):
            failures.append(
                failure(
                    "missing_release_archive_manifest_source_package_inputs",
                    "releaseArchiveManifest.sourcePackageInputs",
                    "release archive manifest must bind sourcePackageInputs when provenance binds packageInputs",
                )
            )
        else:
            for key in ("path", "sha256", "kind"):
                if source_package_inputs.get(key) != expected_package_inputs.get(key):
                    failures.append(
                        failure(
                            "release_archive_manifest_source_package_inputs_mismatch",
                            f"releaseArchiveManifest.sourcePackageInputs.{key}",
                            "release archive manifest sourcePackageInputs must match provenance packageInputs",
                        )
                    )
    members = manifest.get("members")
    if not isinstance(members, dict):
        return failures + [failure("missing_release_archive_members", "releaseArchiveManifest.members", "release archive manifest members are required")]
    expected_members = {
        "browserExecutable": browser_executable_archive_path,
        "appMetadata": browser_app_metadata_archive_path,
        "doeRuntime": doe_runtime_archive_path,
        "dawnFallbackRuntime": dawn_fallback_runtime_archive_path,
    }
    for name, expected_path in expected_members.items():
        member = members.get(name)
        if not isinstance(member, dict):
            failures.append(
                failure(
                    "missing_release_archive_member",
                    f"releaseArchiveManifest.members.{name}",
                    f"release archive manifest member is required: {name}",
                )
            )
            continue
        if member.get("archivePath") != expected_path:
            failures.append(
                failure(
                    "release_archive_member_path_mismatch",
                    f"releaseArchiveManifest.members.{name}.archivePath",
                    f"release archive manifest {name} path must match release candidate member path",
                )
            )
    return failures


def check_public_download_receipt(
    receipt: dict[str, Any],
    *,
    expected_archive: dict[str, str],
    expected_manifest: dict[str, str],
    expected_product: dict[str, str],
    expected_platform: dict[str, str],
    browser_executable_archive_path: str,
    browser_app_metadata_archive_path: str,
    doe_runtime_archive_path: str,
    dawn_fallback_runtime_archive_path: str,
    root: Path,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    if receipt.get("artifactKind") != "browser_public_download_receipt":
        failures.append(
            failure(
                "public_download_wrong_kind",
                "publicDownloadReceipt.artifactKind",
                "public download receipt artifactKind must be browser_public_download_receipt",
            )
        )
    expected_url = expected_archive.get("downloadUrl")
    if receipt.get("url") != expected_url:
        failures.append(
            failure(
                "public_download_url_mismatch",
                "publicDownloadReceipt.url",
                "public download receipt URL must match release archive download URL",
            )
        )
    if receipt.get("method") != "GET" or receipt.get("statusCode") != 200:
        failures.append(
            failure(
                "public_download_get_not_successful",
                "publicDownloadReceipt.statusCode",
                "public download receipt must prove a successful GET",
            )
        )
    if receipt.get("contentSha256") != expected_archive.get("sha256"):
        failures.append(
            failure(
                "public_download_hash_mismatch",
                "publicDownloadReceipt.contentSha256",
                "public download content hash must match release archive hash",
            )
        )
    archive_path = resolve_path(str(expected_archive["path"]), root)
    if archive_path is not None and archive_path.is_file() and receipt.get("contentLengthBytes") != archive_path.stat().st_size:
        failures.append(
            failure(
                "public_download_size_mismatch",
                "publicDownloadReceipt.contentLengthBytes",
                "public download content length must match release archive bytes",
            )
        )
    if not path_matches(receipt.get("releaseArchivePath"), expected_archive.get("path"), root):
        failures.append(
            failure(
                "public_download_archive_path_mismatch",
                "publicDownloadReceipt.releaseArchivePath",
                "public download receipt releaseArchivePath must match release archive path",
            )
        )
    if not path_matches(receipt.get("releaseArchiveManifestPath"), expected_manifest.get("path"), root):
        failures.append(
            failure(
                "public_download_manifest_path_mismatch",
                "publicDownloadReceipt.releaseArchiveManifestPath",
                "public download receipt releaseArchiveManifestPath must match release archive manifest path",
            )
        )
    if receipt.get("releaseArchiveManifestSha256") != expected_manifest.get("sha256"):
        failures.append(
            failure(
                "public_download_manifest_hash_mismatch",
                "publicDownloadReceipt.releaseArchiveManifestSha256",
                "public download receipt releaseArchiveManifestSha256 must match manifest hash",
            )
        )
    for field, expected in (
        ("browserProduct", expected_product),
        ("platform", expected_platform),
        ("browserExecutableArchivePath", browser_executable_archive_path),
        ("browserAppMetadataArchivePath", browser_app_metadata_archive_path),
        ("doeRuntimeArchivePath", doe_runtime_archive_path),
        ("dawnFallbackRuntimeArchivePath", dawn_fallback_runtime_archive_path),
    ):
        if receipt.get(field) != expected:
            failures.append(
                failure(
                    "public_download_provenance_mismatch",
                    f"publicDownloadReceipt.{field}",
                    f"public download receipt {field} must match release candidate provenance",
                )
            )
    return failures


def load_referenced_payload(
    artifact_payload: Any,
    *,
    label: str,
    root: Path,
) -> tuple[dict[str, Any] | None, list[dict[str, str]]]:
    if not isinstance(artifact_payload, dict):
        return None, [failure("invalid_artifact", label, "artifact reference must be an object")]
    path_text = artifact_payload.get("path")
    if not isinstance(path_text, str) or not path_text:
        return None, [failure("missing_artifact_path", f"{label}.path", "artifact path is required")]
    resolved = resolve_path(path_text, root)
    if resolved is None or not resolved.is_file():
        return None, [failure("artifact_file_missing", f"{label}.path", f"artifact file not found: {path_text}")]
    try:
        payload = json.loads(resolved.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        return None, [failure("invalid_artifact_payload", f"{label}.path", f"artifact payload is not valid JSON: {exc}")]
    if not isinstance(payload, dict):
        return None, [failure("invalid_artifact_payload", f"{label}.path", "artifact payload must be a JSON object")]
    return payload, []


def check_proof_surface(
    proof_surface: dict[str, Any],
    *,
    expected_provenance: dict[str, Any],
    root: Path,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    if proof_surface.get("artifactKind") != "browser_published_proof_surface":
        failures.append(
            failure(
                "proof_surface_wrong_kind",
                "proofSurface.artifactKind",
                "proof surface artifactKind must be browser_published_proof_surface",
            )
        )
    proof_page = proof_surface.get("proofPage")
    if not isinstance(proof_page, dict):
        return failures + [failure("missing_proof_page", "proofSurface.proofPage", "proof surface proofPage is required")]
    if proof_page.get("releaseProvenance") != expected_provenance:
        failures.append(
            failure(
                "proof_surface_release_provenance_mismatch",
                "proofSurface.proofPage.releaseProvenance",
                "proof page releaseProvenance must match release candidate provenance",
            )
        )
    diagnostic_payload, diagnostic_failures = load_referenced_payload(
        proof_page.get("diagnosticReceipt"),
        label="proofSurface.proofPage.diagnosticReceipt",
        root=root,
    )
    failures.extend(diagnostic_failures)
    if diagnostic_payload is not None and diagnostic_payload.get("releaseProvenance") != expected_provenance:
        failures.append(
            failure(
                "proof_page_receipt_release_provenance_mismatch",
                "proofSurface.proofPage.diagnosticReceipt.releaseProvenance",
                "proof page diagnostic receipt releaseProvenance must match release candidate provenance",
            )
        )
    return failures


def check_proof_surface_check(
    proof_surface_check: dict[str, Any],
    *,
    expected_proof_surface: dict[str, str],
    root: Path,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    if proof_surface_check.get("artifactKind") != "browser_published_proof_surface_check":
        failures.append(
            failure(
                "proof_surface_check_wrong_kind",
                "proofSurfaceCheck.artifactKind",
                "proof-surface checker report artifactKind must be browser_published_proof_surface_check",
            )
        )
    if proof_surface_check.get("status") != "pass":
        failures.append(
            failure(
                "proof_surface_check_not_pass",
                "proofSurfaceCheck.status",
                "proof-surface checker report must pass before release-candidate provenance can pass",
            )
        )
    if proof_surface_check.get("verifyFilesRootProvided") is not True:
        failures.append(
            failure(
                "proof_surface_check_without_file_verification",
                "proofSurfaceCheck.verifyFilesRootProvided",
                "proof-surface checker report must verify referenced files",
            )
        )
    if proof_surface_check.get("requirePublicUrls") is not True:
        failures.append(
            failure(
                "proof_surface_check_without_public_urls",
                "proofSurfaceCheck.requirePublicUrls",
                "proof-surface checker report must require public gallery URLs",
            )
        )
    if not path_matches(
        proof_surface_check.get("surfacePath"),
        expected_proof_surface.get("path"),
        root,
    ):
        failures.append(
            failure(
                "proof_surface_check_path_mismatch",
                "proofSurfaceCheck.surfacePath",
                "proof-surface checker report surfacePath must match proof surface path",
            )
        )
    if proof_surface_check.get("surfaceSha256") != expected_proof_surface.get("sha256"):
        failures.append(
            failure(
                "proof_surface_check_hash_mismatch",
                "proofSurfaceCheck.surfaceSha256",
                "proof-surface checker report surfaceSha256 must match proof surface hash",
            )
        )
    return failures


def check_browser_launch_receipt(
    receipt: dict[str, Any],
    *,
    expected_archive: dict[str, str],
    expected_manifest: dict[str, str],
    expected_proof_surface: dict[str, str],
    expected_product: dict[str, str],
    expected_platform: dict[str, str],
    browser_executable_archive_path: str,
    browser_app_metadata_archive_path: str,
    doe_runtime_archive_path: str,
    dawn_fallback_runtime_archive_path: str,
    root: Path,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    if receipt.get("artifactKind") != "browser_release_launch_receipt":
        failures.append(
            failure(
                "browser_launch_wrong_kind",
                "browserLaunchReceipt.artifactKind",
                "browser launch receipt artifactKind must be browser_release_launch_receipt",
            )
        )
    failures.extend(check_artifact_ref(receipt.get("releaseArchive"), expected_archive, "browserLaunchReceipt.releaseArchive", root))
    failures.extend(check_artifact_ref(receipt.get("releaseArchiveManifest"), expected_manifest, "browserLaunchReceipt.releaseArchiveManifest", root))
    failures.extend(check_artifact_ref(receipt.get("proofSurface"), expected_proof_surface, "browserLaunchReceipt.proofSurface", root))
    for field, expected in (
        ("browserProduct", expected_product),
        ("platform", expected_platform),
        ("browserExecutableArchivePath", browser_executable_archive_path),
        ("browserAppMetadataArchivePath", browser_app_metadata_archive_path),
        ("doeRuntimeArchivePath", doe_runtime_archive_path),
        ("dawnFallbackRuntimeArchivePath", dawn_fallback_runtime_archive_path),
    ):
        if receipt.get(field) != expected:
            failures.append(
                failure(
                    "browser_launch_provenance_mismatch",
                    f"browserLaunchReceipt.{field}",
                    f"browser launch receipt {field} must match release candidate provenance",
                )
            )
    for field, expected in (
        ("launchSource", "release_archive"),
        ("runtimeMode", "doe"),
        ("activeRuntime", "doe"),
        ("hiddenFallbackAllowed", False),
        ("webgpuAvailable", True),
    ):
        if receipt.get(field) != expected:
            failures.append(
                failure(
                    "browser_launch_runtime_state_mismatch",
                    f"browserLaunchReceipt.{field}",
                    f"browser launch receipt {field} must be {expected}",
                )
            )
    return failures


def build_report(
    *,
    release_archive: Path,
    release_archive_url: str,
    release_archive_manifest: Path,
    public_download_receipt: Path,
    proof_surface: Path,
    proof_surface_check: Path,
    browser_launch_receipt: Path,
    browser_product: dict[str, str],
    platform: dict[str, str],
    browser_executable_archive_path: str,
    browser_app_metadata_archive_path: str,
    doe_runtime_archive_path: str,
    dawn_fallback_runtime_archive_path: str,
    package_inputs: Path | None = None,
    package_input_failures: list[dict[str, str]] | None = None,
    verify_files_root: Path | None = None,
) -> dict[str, Any]:
    root = verify_files_root or REPO_ROOT
    release_archive_artifact = artifact(
        release_archive,
        "browser_release_archive",
        "release archive",
        download_url=release_archive_url,
    )
    release_archive_manifest_artifact = artifact(
        release_archive_manifest,
        "browser_release_archive_manifest",
        "release archive manifest",
    )
    public_download_receipt_artifact = artifact(
        public_download_receipt,
        "browser_public_download_receipt",
        "public download receipt",
    )
    proof_surface_artifact = artifact(
        proof_surface,
        "browser_published_proof_surface",
        "proof surface",
    )
    proof_surface_check_artifact = artifact(
        proof_surface_check,
        "browser_published_proof_surface_check",
        "proof surface checker report",
    )
    browser_launch_receipt_artifact = artifact(
        browser_launch_receipt,
        "browser_release_launch_receipt",
        "browser launch receipt",
    )
    package_inputs_artifact = (
        artifact(
            package_inputs,
            "browser_release_package_inputs_check",
            "browser release package inputs check",
        )
        if package_inputs is not None
        else None
    )
    expected_provenance = expected_release_provenance(
        browser_product=browser_product,
        platform=platform,
        release_archive=release_archive_artifact,
        release_archive_manifest=release_archive_manifest_artifact,
        public_download_receipt=public_download_receipt_artifact,
        browser_executable_archive_path=browser_executable_archive_path,
        browser_app_metadata_archive_path=browser_app_metadata_archive_path,
        doe_runtime_archive_path=doe_runtime_archive_path,
        dawn_fallback_runtime_archive_path=dawn_fallback_runtime_archive_path,
    )

    failures: list[dict[str, str]] = list(package_input_failures or [])
    if not is_public_https_url(release_archive_url):
        failures.append(
            failure(
                "release_archive_url_not_public",
                "releaseArchive.downloadUrl",
                "release archive URL must be public HTTPS",
            )
        )
    failures.extend(check_product_and_platform(browser_product, platform))
    failures.extend(
        check_release_archive_manifest(
            load_json_object(release_archive_manifest, "release archive manifest"),
            expected_archive=release_archive_artifact,
            expected_product=browser_product,
            expected_platform=platform,
            expected_package_inputs=package_inputs_artifact,
            browser_executable_archive_path=browser_executable_archive_path,
            browser_app_metadata_archive_path=browser_app_metadata_archive_path,
            doe_runtime_archive_path=doe_runtime_archive_path,
            dawn_fallback_runtime_archive_path=dawn_fallback_runtime_archive_path,
            root=root,
        )
    )
    failures.extend(
        check_public_download_receipt(
            load_json_object(public_download_receipt, "public download receipt"),
            expected_archive=release_archive_artifact,
            expected_manifest=release_archive_manifest_artifact,
            expected_product=browser_product,
            expected_platform=platform,
            browser_executable_archive_path=browser_executable_archive_path,
            browser_app_metadata_archive_path=browser_app_metadata_archive_path,
            doe_runtime_archive_path=doe_runtime_archive_path,
            dawn_fallback_runtime_archive_path=dawn_fallback_runtime_archive_path,
            root=root,
        )
    )
    failures.extend(
        check_proof_surface(
            load_json_object(proof_surface, "proof surface"),
            expected_provenance=expected_provenance,
            root=root,
        )
    )
    failures.extend(
        check_proof_surface_check(
            load_json_object(proof_surface_check, "proof surface checker report"),
            expected_proof_surface=proof_surface_artifact,
            root=root,
        )
    )
    failures.extend(
        check_browser_launch_receipt(
            load_json_object(browser_launch_receipt, "browser launch receipt"),
            expected_archive=release_archive_artifact,
            expected_manifest=release_archive_manifest_artifact,
            expected_proof_surface=proof_surface_artifact,
            expected_product=browser_product,
            expected_platform=platform,
            browser_executable_archive_path=browser_executable_archive_path,
            browser_app_metadata_archive_path=browser_app_metadata_archive_path,
            doe_runtime_archive_path=doe_runtime_archive_path,
            dawn_fallback_runtime_archive_path=dawn_fallback_runtime_archive_path,
            root=root,
        )
    )
    component_artifacts = {
        "releaseArchive": release_archive_artifact,
        "releaseArchiveManifest": release_archive_manifest_artifact,
        "publicDownloadReceipt": public_download_receipt_artifact,
        "proofSurface": proof_surface_artifact,
        "proofSurfaceCheck": proof_surface_check_artifact,
        "browserLaunchReceipt": browser_launch_receipt_artifact,
    }
    if package_inputs_artifact is not None:
        component_artifacts["packageInputs"] = package_inputs_artifact
    return {
        "schemaVersion": 1,
        "artifactKind": "browser_release_candidate_provenance_report",
        "status": "pass" if not failures else "fail",
        "releaseStatus": "release_candidate",
        "browserProduct": browser_product,
        "platform": platform,
        "expectedProvenance": expected_provenance,
        "componentArtifacts": component_artifacts,
        "failures": failures,
        "summary": {
            "failureCount": len(failures),
            "componentCount": len(component_artifacts),
        },
    }


def main() -> int:
    args = parse_args()
    root = Path(args.verify_files_root).resolve() if args.verify_files_root else REPO_ROOT
    try:
        package_inputs, package_inputs_path, package_input_failures = load_package_inputs_report(
            args.package_inputs,
            root,
        )
        browser_product, platform, members = candidate_identity(
            product_id=args.product_id,
            product_name=args.product_name,
            product_version=args.product_version,
            product_channel=args.product_channel,
            platform_os=args.platform_os,
            platform_arch=args.platform_arch,
            package_format=args.package_format,
            browser_executable_archive_path=args.browser_executable_archive_path,
            browser_app_metadata_archive_path=args.browser_app_metadata_archive_path,
            doe_runtime_archive_path=args.doe_runtime_archive_path,
            dawn_fallback_runtime_archive_path=args.dawn_fallback_runtime_archive_path,
            package_inputs=package_inputs,
        )
    except ValueError as exc:
        sys.stderr.write(f"check_browser_release_candidate_provenance: {exc}\n")
        return 1
    report = build_report(
        release_archive=Path(args.release_archive),
        release_archive_url=args.release_archive_url,
        release_archive_manifest=Path(args.release_archive_manifest),
        public_download_receipt=Path(args.public_download_receipt),
        proof_surface=Path(args.proof_surface),
        proof_surface_check=Path(args.proof_surface_check),
        browser_launch_receipt=Path(args.browser_launch_receipt),
        browser_product=browser_product,
        platform=platform,
        browser_executable_archive_path=members["browserExecutable"],
        browser_app_metadata_archive_path=members["appMetadata"],
        doe_runtime_archive_path=members["doeRuntime"],
        dawn_fallback_runtime_archive_path=members["dawnFallbackRuntime"],
        package_inputs=package_inputs_path,
        package_input_failures=package_input_failures,
        verify_files_root=root,
    )
    if args.out:
        out_path = Path(args.out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if args.emit_json or not args.out:
        print(json.dumps(report, indent=2))
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
