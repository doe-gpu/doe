#!/usr/bin/env python3
"""Tests for browser release archive manifest binding."""

from __future__ import annotations

import hashlib
import json
import unittest
import warnings
import zipfile
from pathlib import Path

from bench.tests import test_browser_release_artifact_bundle as fixtures
from bench.tools import build_browser_release_artifact_bundle as builder
from bench.tools import browser_release_archive_manifest as archive_manifest_check
from bench.tools import check_browser_release_artifact_bundle as bundle_check


def _resolve_under(root: Path, path_text: str) -> Path:
    path = Path(path_text)
    if path.is_absolute():
        return path
    return root / path


def _copy_zip_info(info: zipfile.ZipInfo) -> zipfile.ZipInfo:
    copied = zipfile.ZipInfo(info.filename, info.date_time)
    copied.compress_type = info.compress_type
    copied.external_attr = info.external_attr
    return copied


def _set_member_source_path(manifest: dict, role: str, source_path: str) -> None:
    member = manifest["members"][role]
    member["sourcePath"] = source_path
    archive_path = member["archivePath"]
    for row in manifest["archiveMembers"]:
        if row["archivePath"] == archive_path:
            row["sourcePath"] = source_path


def _package_inputs_from_manifest(manifest: dict) -> dict:
    def row(role: str, kind: str) -> dict:
        member = manifest["members"][role]
        return {
            "kind": kind,
            "path": member.get("sourcePath", f"inputs/{role}"),
            "archivePath": member["archivePath"],
            "exists": True,
            "generated": False,
            "sha256": member["sha256"],
            "byteLength": member["byteLength"],
            "executable": member["executable"],
        }

    return {
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
            "browserExecutable": row("browserExecutable", "browser_binary"),
            "appMetadata": row("appMetadata", "browser_app_metadata"),
            "doeRuntime": row("doeRuntime", "doe_runtime"),
            "dawnFallbackRuntime": row("dawnFallbackRuntime", "dawn_fallback_runtime"),
            "shaderCompiler": {
                "kind": "shader_compiler",
                "path": "inputs/shaderCompiler",
                "exists": True,
                "generated": False,
                "sha256": hashlib.sha256(b"compiler").hexdigest(),
                "byteLength": len(b"compiler"),
                "executable": True,
            },
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


class BrowserReleaseArchiveManifestBindingTests(unittest.TestCase):
    def test_release_candidate_requires_archive_manifest(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            payload = fixtures._build_test_bundle(root, release_status="release_candidate")
            del payload["releaseArchiveManifest"]

            self.assertIn(
                {
                    "code": "missing_release_archive_manifest",
                    "path": "releaseArchiveManifest",
                    "message": "release candidates must hash-bind a release archive manifest",
                },
                bundle_check.check_bundle(payload, verify_files_root=root),
            )

    def test_archive_manifest_member_hash_must_match_bundle(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            payload = fixtures._build_test_bundle(root, release_status="release_candidate")
            manifest_path = root / payload["releaseArchiveManifest"]["path"]
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["members"]["doeRuntime"]["sha256"] = "0" * 64
            manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
            payload["releaseArchiveManifest"]["sha256"] = builder.sha256_file(manifest_path)

            failures = bundle_check.check_bundle(payload, verify_files_root=root)

            self.assertTrue(
                any(
                    item["code"] == "release_archive_manifest_member_hash_mismatch"
                    and item["path"] == "releaseArchiveManifest.members.doeRuntime.sha256"
                    for item in failures
                )
            )

    def test_archive_manifest_must_match_zip_member_metadata(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            payload = fixtures._build_test_bundle(root, release_status="release_candidate")
            manifest_path = root / payload["releaseArchiveManifest"]["path"]
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["archiveMembers"][0]["byteLength"] += 1
            manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
            payload["releaseArchiveManifest"]["sha256"] = builder.sha256_file(manifest_path)

            self.assertTrue(
                any(
                    item["code"] == "release_archive_manifest_member_zip_mismatch"
                    for item in bundle_check.check_bundle(payload, verify_files_root=root)
                )
            )

    def test_archive_manifest_rejects_duplicate_archive_member_paths(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            payload = fixtures._build_test_bundle(root, release_status="release_candidate")
            manifest_path = root / payload["releaseArchiveManifest"]["path"]
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["archiveMembers"].append(dict(manifest["archiveMembers"][0]))
            duplicate_index = len(manifest["archiveMembers"]) - 1
            manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
            payload["releaseArchiveManifest"]["sha256"] = builder.sha256_file(manifest_path)

            self.assertTrue(
                any(
                    item["code"] == "release_archive_manifest_archive_member_duplicate"
                    and item["path"]
                    == f"releaseArchiveManifest.archiveMembers[{duplicate_index}].archivePath"
                    for item in archive_manifest_check.check_release_archive_manifest_artifact(
                        payload,
                        root,
                        require_release_candidate=True,
                    )
                )
            )

    def test_archive_manifest_rejects_duplicate_zip_member_paths(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            payload = fixtures._build_test_bundle(root, release_status="release_candidate")
            archive_path = _resolve_under(root, payload["releaseArchive"]["path"])
            manifest_path = _resolve_under(root, payload["releaseArchiveManifest"]["path"])
            with zipfile.ZipFile(archive_path) as archive:
                entries = [
                    (info, archive.read(info))
                    for info in archive.infolist()
                    if not info.is_dir()
                ]
            duplicate_info, duplicate_payload = entries[0]
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                with zipfile.ZipFile(archive_path, "w") as archive:
                    for info, data in entries:
                        archive.writestr(_copy_zip_info(info), data)
                    archive.writestr(_copy_zip_info(duplicate_info), duplicate_payload)

            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["archive"]["sha256"] = builder.sha256_file(archive_path)
            manifest["archive"]["byteLength"] = archive_path.stat().st_size
            manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
            payload["releaseArchive"]["sha256"] = builder.sha256_file(archive_path)
            payload["releaseArchiveManifest"]["sha256"] = builder.sha256_file(manifest_path)

            self.assertTrue(
                any(
                    item["code"] == "release_archive_zip_member_duplicate"
                    and duplicate_info.filename in item["message"]
                    for item in archive_manifest_check.check_release_archive_manifest_artifact(
                        payload,
                        root,
                        require_release_candidate=True,
                    )
                )
            )

    def test_archive_manifest_source_package_inputs_must_match_members(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            payload = fixtures._build_test_bundle(root, release_status="release_candidate")
            manifest_path = _resolve_under(root, payload["releaseArchiveManifest"]["path"])
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            for role in ("browserExecutable", "appMetadata", "doeRuntime", "dawnFallbackRuntime"):
                _set_member_source_path(manifest, role, f"inputs/{role}")
            package_inputs = _package_inputs_from_manifest(manifest)
            package_inputs_path = root / "browser-release-package-inputs.json"
            package_inputs_path.write_text(
                json.dumps(package_inputs, indent=2) + "\n",
                encoding="utf-8",
            )
            manifest["sourcePackageInputs"] = {
                "path": str(package_inputs_path),
                "sha256": builder.sha256_file(package_inputs_path),
                "kind": "browser_release_package_inputs_check",
            }
            manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
            payload["releaseArchiveManifest"]["sha256"] = builder.sha256_file(manifest_path)

            self.assertEqual(
                archive_manifest_check.check_release_archive_manifest_artifact(
                    payload,
                    root,
                    require_release_candidate=True,
                ),
                [],
            )

            package_inputs["inputs"]["doeRuntime"]["sha256"] = "0" * 64
            package_inputs_path.write_text(
                json.dumps(package_inputs, indent=2) + "\n",
                encoding="utf-8",
            )
            manifest["sourcePackageInputs"]["sha256"] = builder.sha256_file(package_inputs_path)
            manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
            payload["releaseArchiveManifest"]["sha256"] = builder.sha256_file(manifest_path)

            self.assertTrue(
                any(
                    item["code"] == "source_package_inputs_member_sha256_mismatch"
                    and item["path"]
                    == "releaseArchiveManifest.sourcePackageInputs.inputs.doeRuntime.sha256"
                    for item in archive_manifest_check.check_release_archive_manifest_artifact(
                        payload,
                        root,
                        require_release_candidate=True,
                    )
                )
            )

    def test_archive_manifest_source_package_inputs_must_match_member_source_path(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            payload = fixtures._build_test_bundle(root, release_status="release_candidate")
            manifest_path = _resolve_under(root, payload["releaseArchiveManifest"]["path"])
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            package_inputs = _package_inputs_from_manifest(manifest)
            package_inputs_path = root / "browser-release-package-inputs.json"
            package_inputs_path.write_text(
                json.dumps(package_inputs, indent=2) + "\n",
                encoding="utf-8",
            )
            manifest["sourcePackageInputs"] = {
                "path": str(package_inputs_path),
                "sha256": builder.sha256_file(package_inputs_path),
                "kind": "browser_release_package_inputs_check",
            }
            _set_member_source_path(manifest, "doeRuntime", "other/libwebgpu_doe.dylib")
            manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
            payload["releaseArchiveManifest"]["sha256"] = builder.sha256_file(manifest_path)

            self.assertIn(
                {
                    "code": "source_package_inputs_member_source_path_mismatch",
                    "path": "releaseArchiveManifest.members.doeRuntime.sourcePath",
                    "message": (
                        "archive manifest member doeRuntime.sourcePath must match "
                        "source package inputs path"
                    ),
                },
                archive_manifest_check.check_release_archive_manifest_artifact(
                    payload,
                    root,
                    require_release_candidate=True,
                ),
            )

    def test_archive_manifest_rejects_non_candidate_source_package_inputs(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            payload = fixtures._build_test_bundle(root, release_status="release_candidate")
            manifest_path = _resolve_under(root, payload["releaseArchiveManifest"]["path"])
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            for role in ("browserExecutable", "appMetadata", "doeRuntime", "dawnFallbackRuntime"):
                _set_member_source_path(manifest, role, f"inputs/{role}")
            package_inputs = _package_inputs_from_manifest(manifest)
            package_inputs["releaseCandidateEligible"] = False
            package_inputs["evidenceMode"] = "diagnostic"
            package_inputs["releaseCandidateBlockers"] = [
                {
                    "code": "initial_macos_arm64_release_required",
                    "path": "platform",
                    "message": "initial browser release artifact must be macOS arm64 zip",
                }
            ]
            package_inputs_path = root / "browser-release-package-inputs.json"
            package_inputs_path.write_text(
                json.dumps(package_inputs, indent=2) + "\n",
                encoding="utf-8",
            )
            manifest["sourcePackageInputs"] = {
                "path": str(package_inputs_path),
                "sha256": builder.sha256_file(package_inputs_path),
                "kind": "browser_release_package_inputs_check",
            }
            manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
            payload["releaseArchiveManifest"]["sha256"] = builder.sha256_file(manifest_path)

            failures = archive_manifest_check.check_release_archive_manifest_artifact(
                payload,
                root,
                require_release_candidate=True,
            )
            self.assertIn(
                {
                    "code": "source_package_inputs_not_release_candidate_eligible",
                    "path": "releaseArchiveManifest.sourcePackageInputs.releaseCandidateEligible",
                    "message": (
                        "release-candidate archive manifests require "
                        "release-candidate eligible package inputs"
                    ),
                },
                failures,
            )
            self.assertIn(
                {
                    "code": "source_package_inputs_not_release_candidate_evidence",
                    "path": "releaseArchiveManifest.sourcePackageInputs.evidenceMode",
                    "message": (
                        "release-candidate archive manifests require package "
                        "inputs evidenceMode=release_candidate"
                    ),
                },
                failures,
            )
            self.assertIn(
                {
                    "code": "source_package_inputs_release_candidate_blockers_present",
                    "path": "releaseArchiveManifest.sourcePackageInputs.releaseCandidateBlockers",
                    "message": (
                        "release-candidate source package inputs must carry no "
                        "release-candidate blockers"
                    ),
                },
                failures,
            )


if __name__ == "__main__":
    unittest.main()
