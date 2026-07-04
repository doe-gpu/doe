#!/usr/bin/env python3
"""Validate browser release archive manifest artifacts."""

from __future__ import annotations

import hashlib
import json
import stat
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any


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


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def artifact_field(payload: dict[str, Any], field: str, key: str) -> Any:
    artifact = payload.get(field)
    return artifact.get(key) if isinstance(artifact, dict) else None


def load_manifest(
    artifact: dict[str, Any],
    verify_files_root: Path | None,
) -> tuple[dict[str, Any] | None, list[dict[str, str]]]:
    failures: list[dict[str, str]] = []
    artifact_path = artifact.get("path")
    artifact_hash = artifact.get("sha256")
    if not isinstance(artifact_path, str) or not artifact_path:
        failures.append(failure("missing_release_archive_manifest_path", "releaseArchiveManifest.path", "release archive manifest path is required"))
    if not isinstance(artifact_hash, str) or len(artifact_hash) != 64:
        failures.append(failure("missing_release_archive_manifest_hash", "releaseArchiveManifest.sha256", "release archive manifest sha256 is required"))
    if artifact.get("kind") != "browser_release_archive_manifest":
        failures.append(failure("wrong_release_archive_manifest_kind", "releaseArchiveManifest.kind", "release archive manifest kind must be browser_release_archive_manifest"))
    if failures or verify_files_root is None:
        return None, failures
    resolved = resolve_artifact_path(artifact_path, verify_files_root)
    if resolved is None:
        return None, [failure("unsafe_release_archive_manifest_path", "releaseArchiveManifest.path", f"release archive manifest path must resolve under verify-files-root: {artifact_path}")]
    if not resolved.is_file():
        return None, [failure("release_archive_manifest_file_missing", "releaseArchiveManifest.path", f"release archive manifest file not found: {artifact_path}")]
    actual_hash = sha256_file(resolved)
    if actual_hash != artifact_hash:
        failures.append(failure("release_archive_manifest_hash_mismatch", "releaseArchiveManifest.sha256", f"expected {actual_hash} for {artifact_path}"))
    try:
        payload = json.loads(resolved.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        return None, failures + [failure("invalid_release_archive_manifest_payload", "releaseArchiveManifest.path", f"release archive manifest is not valid JSON: {exc}")]
    if not isinstance(payload, dict):
        return None, failures + [failure("invalid_release_archive_manifest_payload", "releaseArchiveManifest.path", "release archive manifest payload must be a JSON object")]
    return payload, failures


def check_manifest_identity(manifest: dict[str, Any], payload: dict[str, Any]) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    if manifest.get("schemaVersion") != 1:
        failures.append(failure("invalid_release_archive_manifest_schema_version", "releaseArchiveManifest.schemaVersion", "release archive manifest schemaVersion must be 1"))
    if manifest.get("artifactKind") != "browser_release_archive_manifest":
        failures.append(failure("invalid_release_archive_manifest_artifact_kind", "releaseArchiveManifest.artifactKind", "release archive manifest artifactKind must be browser_release_archive_manifest"))
    archive = manifest.get("archive")
    if not isinstance(archive, dict):
        failures.append(failure("missing_release_archive_manifest_archive", "releaseArchiveManifest.archive", "release archive manifest archive must be object"))
    else:
        for key in ("path", "sha256", "kind"):
            expected = artifact_field(payload, "releaseArchive", key)
            if archive.get(key) != expected:
                failures.append(failure("release_archive_manifest_archive_mismatch", f"releaseArchiveManifest.archive.{key}", "release archive manifest archive must match releaseArchive"))
        release_archive_path = artifact_field(payload, "releaseArchive", "path")
        if isinstance(release_archive_path, str) and isinstance(archive.get("byteLength"), int):
            pass
    if manifest.get("browserProduct") != payload.get("browserProduct"):
        failures.append(failure("release_archive_manifest_product_mismatch", "releaseArchiveManifest.browserProduct", "release archive manifest browserProduct must match release bundle browserProduct"))
    if manifest.get("platform") != payload.get("platform"):
        failures.append(failure("release_archive_manifest_platform_mismatch", "releaseArchiveManifest.platform", "release archive manifest platform must match release bundle platform"))
    return failures


def load_source_package_inputs(
    artifact: dict[str, Any],
    verify_files_root: Path | None,
) -> tuple[dict[str, Any] | None, list[dict[str, str]]]:
    failures: list[dict[str, str]] = []
    artifact_path = artifact.get("path")
    artifact_hash = artifact.get("sha256")
    if artifact.get("kind") != "browser_release_package_inputs_check":
        failures.append(
            failure(
                "wrong_source_package_inputs_kind",
                "releaseArchiveManifest.sourcePackageInputs.kind",
                "sourcePackageInputs kind must be browser_release_package_inputs_check",
            )
        )
    if not isinstance(artifact_path, str) or not artifact_path:
        failures.append(
            failure(
                "missing_source_package_inputs_path",
                "releaseArchiveManifest.sourcePackageInputs.path",
                "sourcePackageInputs path is required",
            )
        )
    if not isinstance(artifact_hash, str) or len(artifact_hash) != 64:
        failures.append(
            failure(
                "missing_source_package_inputs_hash",
                "releaseArchiveManifest.sourcePackageInputs.sha256",
                "sourcePackageInputs sha256 is required",
            )
        )
    if failures or verify_files_root is None:
        return None, failures
    resolved = resolve_artifact_path(artifact_path, verify_files_root)
    if resolved is None:
        return None, [
            failure(
                "unsafe_source_package_inputs_path",
                "releaseArchiveManifest.sourcePackageInputs.path",
                f"sourcePackageInputs path must resolve under verify-files-root: {artifact_path}",
            )
        ]
    if not resolved.is_file():
        return None, [
            failure(
                "source_package_inputs_file_missing",
                "releaseArchiveManifest.sourcePackageInputs.path",
                f"sourcePackageInputs file not found: {artifact_path}",
            )
        ]
    actual_hash = sha256_file(resolved)
    if actual_hash != artifact_hash:
        failures.append(
            failure(
                "source_package_inputs_hash_mismatch",
                "releaseArchiveManifest.sourcePackageInputs.sha256",
                f"expected {actual_hash} for {artifact_path}",
            )
        )
    try:
        payload = json.loads(resolved.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        return None, failures + [
            failure(
                "invalid_source_package_inputs_payload",
                "releaseArchiveManifest.sourcePackageInputs.path",
                f"sourcePackageInputs is not valid JSON: {exc}",
            )
        ]
    if not isinstance(payload, dict):
        return None, failures + [
            failure(
                "invalid_source_package_inputs_payload",
                "releaseArchiveManifest.sourcePackageInputs.path",
                "sourcePackageInputs payload must be a JSON object",
            )
        ]
    return payload, failures


def check_source_package_inputs(
    manifest: dict[str, Any],
    verify_files_root: Path | None,
    *,
    require_release_candidate: bool = False,
) -> list[dict[str, str]]:
    artifact = manifest.get("sourcePackageInputs")
    if artifact is None:
        return []
    if not isinstance(artifact, dict):
        return [
            failure(
                "invalid_source_package_inputs_artifact",
                "releaseArchiveManifest.sourcePackageInputs",
                "sourcePackageInputs must be an artifact object",
            )
        ]
    package_inputs, failures = load_source_package_inputs(artifact, verify_files_root)
    if package_inputs is None:
        return failures
    if package_inputs.get("artifactKind") != "browser_release_package_inputs_check":
        failures.append(
            failure(
                "invalid_source_package_inputs_artifact_kind",
                "releaseArchiveManifest.sourcePackageInputs.artifactKind",
                "source package inputs artifactKind must be browser_release_package_inputs_check",
            )
        )
    if package_inputs.get("status") != "pass":
        failures.append(
            failure(
                "source_package_inputs_not_passing",
                "releaseArchiveManifest.sourcePackageInputs.status",
                "source package inputs must pass before archive packaging",
            )
        )
    if require_release_candidate:
        if package_inputs.get("releaseCandidateEligible") is not True:
            failures.append(
                failure(
                    "source_package_inputs_not_release_candidate_eligible",
                    "releaseArchiveManifest.sourcePackageInputs.releaseCandidateEligible",
                    "release-candidate archive manifests require release-candidate eligible package inputs",
                )
            )
        if package_inputs.get("evidenceMode") != "release_candidate":
            failures.append(
                failure(
                    "source_package_inputs_not_release_candidate_evidence",
                    "releaseArchiveManifest.sourcePackageInputs.evidenceMode",
                    "release-candidate archive manifests require package inputs evidenceMode=release_candidate",
                )
            )
        if package_inputs.get("releaseCandidateBlockers") != []:
            failures.append(
                failure(
                    "source_package_inputs_release_candidate_blockers_present",
                    "releaseArchiveManifest.sourcePackageInputs.releaseCandidateBlockers",
                    "release-candidate source package inputs must carry no release-candidate blockers",
                )
            )
        if package_inputs.get("failures") != []:
            failures.append(
                failure(
                    "source_package_inputs_failures_present",
                    "releaseArchiveManifest.sourcePackageInputs.failures",
                    "passing source package inputs must carry no failures",
                )
            )
        summary = package_inputs.get("summary")
        if not isinstance(summary, dict) or summary.get("packageable") is not True:
            failures.append(
                failure(
                    "source_package_inputs_summary_not_packageable",
                    "releaseArchiveManifest.sourcePackageInputs.summary.packageable",
                    "passing source package inputs summary.packageable must be true",
                )
            )
    if package_inputs.get("browserProduct") != manifest.get("browserProduct"):
        failures.append(
            failure(
                "source_package_inputs_product_mismatch",
                "releaseArchiveManifest.sourcePackageInputs.browserProduct",
                "source package inputs browserProduct must match release archive manifest",
            )
        )
    if package_inputs.get("platform") != manifest.get("platform"):
        failures.append(
            failure(
                "source_package_inputs_platform_mismatch",
                "releaseArchiveManifest.sourcePackageInputs.platform",
                "source package inputs platform must match release archive manifest",
            )
        )
    inputs = package_inputs.get("inputs")
    members = manifest.get("members")
    if not isinstance(inputs, dict):
        failures.append(
            failure(
                "missing_source_package_inputs_inputs",
                "releaseArchiveManifest.sourcePackageInputs.inputs",
                "source package inputs must carry inputs object",
            )
        )
        return failures
    if not isinstance(members, dict):
        return failures
    for role in ("browserExecutable", "appMetadata", "doeRuntime", "dawnFallbackRuntime"):
        row = inputs.get(role)
        member = members.get(role)
        if not isinstance(row, dict):
            failures.append(
                failure(
                    "missing_source_package_inputs_row",
                    f"releaseArchiveManifest.sourcePackageInputs.inputs.{role}",
                    f"source package inputs missing row: {role}",
                )
            )
            continue
        if not isinstance(member, dict):
            continue
        for key in ("archivePath", "sha256"):
            if row.get(key) != member.get(key):
                failures.append(
                    failure(
                        f"source_package_inputs_member_{key.lower()}_mismatch",
                        f"releaseArchiveManifest.sourcePackageInputs.inputs.{role}.{key}",
                        f"source package inputs {role}.{key} must match archive manifest member",
                    )
                )
        if row.get("generated") is True:
            continue
        expected_source_path = row.get("path")
        member_source_path = member.get("sourcePath")
        if not isinstance(member_source_path, str) or not member_source_path:
            failures.append(
                failure(
                    "source_package_inputs_member_source_path_missing",
                    f"releaseArchiveManifest.members.{role}.sourcePath",
                    f"archive manifest member {role}.sourcePath must be present for package-input sourced members",
                )
            )
        elif not isinstance(expected_source_path, str) or not source_paths_match(
            member_source_path,
            expected_source_path,
            verify_files_root,
        ):
            failures.append(
                failure(
                    "source_package_inputs_member_source_path_mismatch",
                    f"releaseArchiveManifest.members.{role}.sourcePath",
                    f"archive manifest member {role}.sourcePath must match source package inputs path",
                )
            )
    return failures


def source_paths_match(
    left: str,
    right: str,
    verify_files_root: Path | None,
) -> bool:
    if left == right:
        return True
    if verify_files_root is None:
        return False
    left_resolved = resolve_artifact_path(left, verify_files_root)
    right_resolved = resolve_artifact_path(right, verify_files_root)
    return (
        left_resolved is not None
        and right_resolved is not None
        and left_resolved == right_resolved
    )


def member_by_path(manifest: dict[str, Any]) -> dict[str, dict[str, Any]]:
    members = manifest.get("archiveMembers")
    if not isinstance(members, list):
        return {}
    return {
        row["archivePath"]: row
        for row in members
        if isinstance(row, dict) and isinstance(row.get("archivePath"), str)
    }


def check_archive_members_unique(manifest: dict[str, Any]) -> list[dict[str, str]]:
    members = manifest.get("archiveMembers")
    if not isinstance(members, list):
        return []
    failures: list[dict[str, str]] = []
    seen: set[str] = set()
    for index, row in enumerate(members):
        if not isinstance(row, dict) or not isinstance(row.get("archivePath"), str):
            continue
        archive_path = row["archivePath"]
        if archive_path in seen:
            failures.append(
                failure(
                    "release_archive_manifest_archive_member_duplicate",
                    f"releaseArchiveManifest.archiveMembers[{index}].archivePath",
                    f"release archive manifest archiveMembers repeats archivePath: {archive_path}",
                )
            )
        seen.add(archive_path)
    return failures


def check_required_member(
    manifest: dict[str, Any],
    payload: dict[str, Any],
    *,
    manifest_member_key: str,
    bundle_member_field: str,
    bundle_artifact_field: str,
    require_executable: bool,
    require_hash_match: bool,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    members = manifest.get("members")
    manifest_member = members.get(manifest_member_key) if isinstance(members, dict) else None
    expected_path = payload.get(bundle_member_field)
    expected_hash = artifact_field(payload, bundle_artifact_field, "sha256")
    path = f"releaseArchiveManifest.members.{manifest_member_key}"
    if not isinstance(manifest_member, dict):
        return [failure("missing_release_archive_manifest_member", path, f"release archive manifest member is required: {manifest_member_key}")]
    if manifest_member.get("archivePath") != expected_path:
        failures.append(failure("release_archive_manifest_member_path_mismatch", f"{path}.archivePath", f"release archive manifest {manifest_member_key} archivePath must match {bundle_member_field}"))
    if require_hash_match and manifest_member.get("sha256") != expected_hash:
        failures.append(failure("release_archive_manifest_member_hash_mismatch", f"{path}.sha256", f"release archive manifest {manifest_member_key} sha256 must match {bundle_artifact_field}.sha256"))
    if require_executable and manifest_member.get("executable") is not True:
        failures.append(failure("release_archive_manifest_member_not_executable", f"{path}.executable", f"release archive manifest {manifest_member_key} must be executable"))
    indexed_member = member_by_path(manifest).get(manifest_member.get("archivePath"))
    if indexed_member != manifest_member:
        failures.append(failure("release_archive_manifest_member_not_indexed", path, f"release archive manifest archiveMembers must include {manifest_member_key}"))
    return failures


def zip_member_records(
    archive_path: Path,
) -> tuple[dict[str, dict[str, Any]], list[dict[str, str]]] | None:
    if not archive_path.is_file() or not zipfile.is_zipfile(archive_path):
        return None
    records: dict[str, dict[str, Any]] = {}
    failures: list[dict[str, str]] = []
    with zipfile.ZipFile(archive_path) as archive:
        for info in archive.infolist():
            if info.is_dir():
                continue
            if info.filename in records:
                failures.append(
                    failure(
                        "release_archive_zip_member_duplicate",
                        "releaseArchive.path",
                        f"release archive zip repeats member path: {info.filename}",
                    )
                )
                continue
            mode = (info.external_attr >> 16) & 0o777
            data = archive.read(info)
            records[info.filename] = {
                "archivePath": info.filename,
                "sha256": hashlib.sha256(data).hexdigest(),
                "byteLength": len(data),
                "executable": bool(mode & stat.S_IXUSR),
            }
    return records, failures


def check_zip_matches_manifest(
    manifest: dict[str, Any],
    payload: dict[str, Any],
    verify_files_root: Path | None,
) -> list[dict[str, str]]:
    if verify_files_root is None:
        return []
    archive_path = artifact_field(payload, "releaseArchive", "path")
    if not isinstance(archive_path, str):
        return []
    resolved_archive = resolve_artifact_path(archive_path, verify_files_root)
    if resolved_archive is None:
        return []
    if isinstance(manifest.get("archive"), dict):
        byte_length = manifest["archive"].get("byteLength")
        if isinstance(byte_length, int) and resolved_archive.is_file() and byte_length != resolved_archive.stat().st_size:
            return [failure("release_archive_manifest_archive_length_mismatch", "releaseArchiveManifest.archive.byteLength", "release archive manifest archive byteLength must match releaseArchive size")]
    record_result = zip_member_records(resolved_archive)
    if record_result is None:
        return []
    records, failures = record_result
    for manifest_path, manifest_member in member_by_path(manifest).items():
        actual = records.get(manifest_path)
        if actual is None:
            failures.append(failure("release_archive_manifest_member_missing_from_zip", "releaseArchiveManifest.archiveMembers", f"manifest member is missing from releaseArchive zip: {manifest_path}"))
        elif any(actual.get(key) != manifest_member.get(key) for key in ("sha256", "byteLength", "executable")):
            failures.append(failure("release_archive_manifest_member_zip_mismatch", "releaseArchiveManifest.archiveMembers", f"manifest member metadata must match releaseArchive zip member: {manifest_path}"))
    return failures


def check_release_archive_manifest_artifact(
    payload: dict[str, Any],
    verify_files_root: Path | None,
    *,
    require_release_candidate: bool,
) -> list[dict[str, str]]:
    artifact = payload.get("releaseArchiveManifest")
    candidate_required = require_release_candidate or payload.get("releaseStatus") == "release_candidate"
    if artifact is None:
        if not candidate_required:
            return []
        return [failure("missing_release_archive_manifest", "releaseArchiveManifest", "release candidates must hash-bind a release archive manifest")]
    if not isinstance(artifact, dict):
        return [failure("invalid_release_archive_manifest_artifact", "releaseArchiveManifest", "releaseArchiveManifest must be object")]
    manifest, failures = load_manifest(artifact, verify_files_root)
    if manifest is None:
        return failures
    failures.extend(check_manifest_identity(manifest, payload))
    failures.extend(
        check_source_package_inputs(
            manifest,
            verify_files_root,
            require_release_candidate=candidate_required,
        )
    )
    failures.extend(check_archive_members_unique(manifest))
    for kwargs in (
        {"manifest_member_key": "browserExecutable", "bundle_member_field": "browserExecutableArchivePath", "bundle_artifact_field": "browserBinary", "require_executable": True},
        {"manifest_member_key": "appMetadata", "bundle_member_field": "browserAppMetadataArchivePath", "bundle_artifact_field": "releaseArchiveManifest", "require_executable": False},
        {"manifest_member_key": "doeRuntime", "bundle_member_field": "doeRuntimeArchivePath", "bundle_artifact_field": "doeRuntime", "require_executable": False},
        {"manifest_member_key": "dawnFallbackRuntime", "bundle_member_field": "dawnFallbackRuntimeArchivePath", "bundle_artifact_field": "dawnFallbackRuntime", "require_executable": False},
    ):
        if kwargs["manifest_member_key"] == "appMetadata":
            failures.extend(check_app_metadata_member(manifest, payload))
        else:
            failures.extend(
                check_required_member(
                    manifest,
                    payload,
                    require_hash_match=candidate_required,
                    **kwargs,
                )
            )
    failures.extend(check_zip_matches_manifest(manifest, payload, verify_files_root))
    return failures


def check_app_metadata_member(manifest: dict[str, Any], payload: dict[str, Any]) -> list[dict[str, str]]:
    members = manifest.get("members")
    manifest_member = members.get("appMetadata") if isinstance(members, dict) else None
    path = "releaseArchiveManifest.members.appMetadata"
    if not isinstance(manifest_member, dict):
        return [failure("missing_release_archive_manifest_member", path, "release archive manifest member is required: appMetadata")]
    failures: list[dict[str, str]] = []
    if manifest_member.get("archivePath") != payload.get("browserAppMetadataArchivePath"):
        failures.append(failure("release_archive_manifest_member_path_mismatch", f"{path}.archivePath", "release archive manifest appMetadata archivePath must match browserAppMetadataArchivePath"))
    indexed_member = member_by_path(manifest).get(manifest_member.get("archivePath"))
    if indexed_member != manifest_member:
        failures.append(failure("release_archive_manifest_member_not_indexed", path, "release archive manifest archiveMembers must include appMetadata"))
    return failures
