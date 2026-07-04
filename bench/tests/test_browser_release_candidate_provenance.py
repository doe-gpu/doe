#!/usr/bin/env python3
"""Tests for browser release-candidate provenance preflight."""

from __future__ import annotations

import json
import plistlib
import sys
from pathlib import Path

import jsonschema

from bench.tools import check_browser_release_package_inputs as package_inputs_check
from bench.tools import check_browser_release_candidate_provenance as checker


REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA = REPO_ROOT / "config" / "browser-release-candidate-provenance-report.schema.json"
MEMBER_PATHS = {
    "browserExecutable": "Fawn.app/Contents/MacOS/Chromium",
    "appMetadata": "Fawn.app/Contents/Info.plist",
    "doeRuntime": "Fawn.app/Contents/Frameworks/libwebgpu_doe.so",
    "dawnFallbackRuntime": "Fawn.app/Contents/Frameworks/libdawn_native.so",
}
PRODUCT = {
    "productId": "fawn-doe",
    "displayName": "Fawn Doe",
    "version": "0.0.0-test",
    "channel": "release_candidate",
}
PLATFORM = {"os": "macos", "arch": "arm64", "packageFormat": "zip"}
DOWNLOAD_URL = "https://downloads.doe.dev/Fawn-Doe-macos-arm64.zip"


def _write_json(path: Path, payload: dict) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return path


def _write_file(path: Path, payload: bytes, mode: int = 0o644) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)
    path.chmod(mode)
    return path


def _macho_arm64_payload() -> bytes:
    return (
        b"\xcf\xfa\xed\xfe"
        + (0x0100000C).to_bytes(4, "little")
        + (0).to_bytes(4, "little") * 6
    )


def _artifact(path: Path, kind: str, *, download_url: str = "") -> dict[str, str]:
    payload = {
        "path": str(path),
        "sha256": checker.sha256_file(path),
        "kind": kind,
    }
    if download_url:
        payload["downloadUrl"] = download_url
    return payload


def _package_inputs_fixture(tmp_path: Path) -> tuple[Path, dict]:
    app_dir = tmp_path / "Fawn.app"
    _write_file(app_dir / "Contents" / "MacOS" / "Chromium", _macho_arm64_payload(), 0o755)
    plist_path = app_dir / "Contents" / "Info.plist"
    plist_path.parent.mkdir(parents=True, exist_ok=True)
    with plist_path.open("wb") as handle:
        plistlib.dump(
            {
                "CFBundleName": PRODUCT["displayName"],
                "CFBundleDisplayName": PRODUCT["displayName"],
                "CFBundleIdentifier": "dev.doe.fawn-doe",
                "CFBundleShortVersionString": PRODUCT["version"],
                "CFBundleVersion": PRODUCT["version"],
                "CFBundleExecutable": "Chromium",
                "CFBundlePackageType": "APPL",
            },
            handle,
        )
    doe_runtime = _write_file(tmp_path / "libwebgpu_doe.dylib", _macho_arm64_payload(), 0o755)
    dawn_runtime = _write_file(tmp_path / "libdawn_native.so", _macho_arm64_payload(), 0o755)
    shader_compiler = _write_file(tmp_path / "doe-zig-runtime", _macho_arm64_payload(), 0o755)
    report = package_inputs_check.build_report(
        package_dir=str(app_dir),
        package_root_name="Fawn.app",
        doe_runtime=str(doe_runtime),
        dawn_fallback_runtime=str(dawn_runtime),
        shader_compiler=str(shader_compiler),
        product_version=PRODUCT["version"],
        product_channel=PRODUCT["channel"],
        platform_os=PLATFORM["os"],
        platform_arch=PLATFORM["arch"],
        root=tmp_path,
    )
    report_path = _write_json(tmp_path / "browser-release-package-inputs.json", report)
    return report_path, report


def _candidate_fixture(
    tmp_path: Path,
    *,
    source_package_inputs: Path | None = None,
) -> dict[str, Path | dict[str, str]]:
    release_archive = tmp_path / "Fawn-Doe-macos-arm64.zip"
    release_archive.write_bytes(b"candidate browser archive\n")
    release_archive_artifact = _artifact(
        release_archive,
        "browser_release_archive",
        download_url=DOWNLOAD_URL,
    )
    manifest = {
        "schemaVersion": 1,
        "artifactKind": "browser_release_archive_manifest",
        "archive": {
            **release_archive_artifact,
            "byteLength": release_archive.stat().st_size,
        },
        "browserProduct": PRODUCT,
        "platform": PLATFORM,
        "appBundleName": "Fawn.app",
        "members": {
            name: {
                "archivePath": archive_path,
                "sha256": "0" * 64,
                "byteLength": 1,
                "executable": True,
            }
            for name, archive_path in MEMBER_PATHS.items()
        },
        "archiveMembers": [],
    }
    if source_package_inputs is not None:
        manifest["sourcePackageInputs"] = _artifact(
            source_package_inputs,
            "browser_release_package_inputs_check",
        )
    manifest["archiveMembers"] = list(manifest["members"].values())
    manifest_path = _write_json(tmp_path / "Fawn-Doe-macos-arm64.manifest.json", manifest)
    manifest_artifact = _artifact(manifest_path, "browser_release_archive_manifest")
    public_download = {
        "schemaVersion": 1,
        "artifactKind": "browser_public_download_receipt",
        "receiptId": "candidate-public-download",
        "url": DOWNLOAD_URL,
        "method": "GET",
        "statusCode": 200,
        "contentSha256": release_archive_artifact["sha256"],
        "contentLengthBytes": release_archive.stat().st_size,
        "releaseArchivePath": release_archive_artifact["path"],
        "releaseArchiveManifestPath": manifest_artifact["path"],
        "releaseArchiveManifestSha256": manifest_artifact["sha256"],
        "browserProduct": PRODUCT,
        "platform": PLATFORM,
        "browserExecutableArchivePath": MEMBER_PATHS["browserExecutable"],
        "browserAppMetadataArchivePath": MEMBER_PATHS["appMetadata"],
        "doeRuntimeArchivePath": MEMBER_PATHS["doeRuntime"],
        "dawnFallbackRuntimeArchivePath": MEMBER_PATHS["dawnFallbackRuntime"],
        "observedAt": "2026-07-01T00:00:00Z",
    }
    public_download_path = _write_json(tmp_path / "browser-public-download.json", public_download)
    public_download_artifact = _artifact(public_download_path, "browser_public_download_receipt")
    provenance = checker.expected_release_provenance(
        browser_product=PRODUCT,
        platform=PLATFORM,
        release_archive=release_archive_artifact,
        release_archive_manifest=manifest_artifact,
        public_download_receipt=public_download_artifact,
        browser_executable_archive_path=MEMBER_PATHS["browserExecutable"],
        browser_app_metadata_archive_path=MEMBER_PATHS["appMetadata"],
        doe_runtime_archive_path=MEMBER_PATHS["doeRuntime"],
        dawn_fallback_runtime_archive_path=MEMBER_PATHS["dawnFallbackRuntime"],
    )
    proof_receipt = {
        "schemaVersion": 1,
        "artifactKind": "browser_proof_page_receipt",
        "receiptId": "candidate-proof-page",
        "releaseProvenance": provenance,
    }
    proof_receipt_path = _write_json(tmp_path / "browser-proof-page-receipt.json", proof_receipt)
    proof_surface = {
        "schemaVersion": 1,
        "artifactKind": "browser_published_proof_surface",
        "surfaceId": "candidate-proof-surface",
        "proofPage": {
            "releaseProvenance": provenance,
            "diagnosticReceipt": _artifact(proof_receipt_path, "browser_proof_page_receipt"),
        },
    }
    proof_surface_path = _write_json(tmp_path / "browser-published-proof-surface.json", proof_surface)
    proof_surface_artifact = _artifact(proof_surface_path, "browser_published_proof_surface")
    proof_surface_check = {
        "schemaVersion": 1,
        "artifactKind": "browser_published_proof_surface_check",
        "surfacePath": proof_surface_artifact["path"],
        "surfaceSha256": proof_surface_artifact["sha256"],
        "verifyFilesRootProvided": True,
        "requirePublicUrls": True,
        "status": "pass",
        "failures": [],
    }
    proof_surface_check_path = _write_json(
        tmp_path / "browser-published-proof-surface-check.json",
        proof_surface_check,
    )
    launch_receipt = {
        "schemaVersion": 1,
        "artifactKind": "browser_release_launch_receipt",
        "receiptId": "candidate-launch",
        "launchSource": "release_archive",
        "browserProduct": PRODUCT,
        "platform": PLATFORM,
        "releaseArchive": release_archive_artifact,
        "releaseArchiveManifest": manifest_artifact,
        "proofSurface": proof_surface_artifact,
        "browserExecutableArchivePath": MEMBER_PATHS["browserExecutable"],
        "browserAppMetadataArchivePath": MEMBER_PATHS["appMetadata"],
        "doeRuntimeArchivePath": MEMBER_PATHS["doeRuntime"],
        "dawnFallbackRuntimeArchivePath": MEMBER_PATHS["dawnFallbackRuntime"],
        "runtimeMode": "doe",
        "activeRuntime": "doe",
        "activeBackend": "webgpu-doe",
        "hiddenFallbackAllowed": False,
        "webgpuAvailable": True,
    }
    launch_receipt_path = _write_json(tmp_path / "browser-release-launch-receipt.json", launch_receipt)
    return {
        "release_archive": release_archive,
        "release_archive_manifest": manifest_path,
        "public_download_receipt": public_download_path,
        "proof_surface": proof_surface_path,
        "proof_surface_check": proof_surface_check_path,
        "browser_launch_receipt": launch_receipt_path,
    }


def _build_report(paths: dict[str, Path | dict[str, str]]) -> dict:
    return checker.build_report(
        release_archive=paths["release_archive"],
        release_archive_url=DOWNLOAD_URL,
        release_archive_manifest=paths["release_archive_manifest"],
        public_download_receipt=paths["public_download_receipt"],
        proof_surface=paths["proof_surface"],
        proof_surface_check=paths["proof_surface_check"],
        browser_launch_receipt=paths["browser_launch_receipt"],
        browser_product=PRODUCT,
        platform=PLATFORM,
        browser_executable_archive_path=MEMBER_PATHS["browserExecutable"],
        browser_app_metadata_archive_path=MEMBER_PATHS["appMetadata"],
        doe_runtime_archive_path=MEMBER_PATHS["doeRuntime"],
        dawn_fallback_runtime_archive_path=MEMBER_PATHS["dawnFallbackRuntime"],
        verify_files_root=tmp_root(paths),
    )


def tmp_root(paths: dict[str, Path | dict[str, str]]) -> Path:
    return Path(paths["release_archive"]).parent


def test_browser_release_candidate_provenance_passes(tmp_path: Path) -> None:
    report = _build_report(_candidate_fixture(tmp_path))
    assert report["status"] == "pass"
    assert report["failures"] == []


def test_browser_release_candidate_provenance_rejects_diagnostic_proof_surface(tmp_path: Path) -> None:
    paths = _candidate_fixture(tmp_path)
    proof_surface_path = paths["proof_surface"]
    proof_surface = json.loads(Path(proof_surface_path).read_text(encoding="utf-8"))
    proof_surface["proofPage"]["releaseProvenance"]["browserProduct"]["channel"] = "diagnostic"
    _write_json(Path(proof_surface_path), proof_surface)

    report = _build_report(paths)
    assert report["status"] == "fail"
    assert any(
        item["code"] == "proof_surface_release_provenance_mismatch"
        for item in report["failures"]
    )


def test_browser_release_candidate_provenance_rejects_stale_proof_surface_check(tmp_path: Path) -> None:
    paths = _candidate_fixture(tmp_path)
    proof_surface_check_path = Path(paths["proof_surface_check"])
    proof_surface_check = json.loads(proof_surface_check_path.read_text(encoding="utf-8"))
    proof_surface_check["surfaceSha256"] = "0" * 64
    _write_json(proof_surface_check_path, proof_surface_check)

    report = _build_report(paths)

    assert report["status"] == "fail"
    assert any(
        item["code"] == "proof_surface_check_hash_mismatch"
        for item in report["failures"]
    )


def test_browser_release_candidate_provenance_rejects_failing_proof_surface_check(tmp_path: Path) -> None:
    paths = _candidate_fixture(tmp_path)
    proof_surface_check_path = Path(paths["proof_surface_check"])
    proof_surface_check = json.loads(proof_surface_check_path.read_text(encoding="utf-8"))
    proof_surface_check["status"] = "fail"
    proof_surface_check["failures"] = [
        {
            "code": "invalid_gallery_page_url",
            "path": "galleryPages[0].url",
            "message": "release proof gallery page URL must be public HTTPS",
        }
    ]
    _write_json(proof_surface_check_path, proof_surface_check)

    report = _build_report(paths)

    assert report["status"] == "fail"
    assert any(
        item["code"] == "proof_surface_check_not_pass"
        for item in report["failures"]
    )


def test_browser_release_candidate_provenance_cli_writes_report(tmp_path: Path) -> None:
    paths = _candidate_fixture(tmp_path)
    out_path = tmp_path / "candidate-provenance-report.json"
    argv = [
        "check_browser_release_candidate_provenance.py",
        "--release-archive",
        str(paths["release_archive"]),
        "--release-archive-url",
        DOWNLOAD_URL,
        "--release-archive-manifest",
        str(paths["release_archive_manifest"]),
        "--public-download-receipt",
        str(paths["public_download_receipt"]),
        "--proof-surface",
        str(paths["proof_surface"]),
        "--proof-surface-check",
        str(paths["proof_surface_check"]),
        "--browser-launch-receipt",
        str(paths["browser_launch_receipt"]),
        "--product-version",
        PRODUCT["version"],
        "--browser-executable-archive-path",
        MEMBER_PATHS["browserExecutable"],
        "--browser-app-metadata-archive-path",
        MEMBER_PATHS["appMetadata"],
        "--doe-runtime-archive-path",
        MEMBER_PATHS["doeRuntime"],
        "--dawn-fallback-runtime-archive-path",
        MEMBER_PATHS["dawnFallbackRuntime"],
        "--verify-files-root",
        str(tmp_path),
        "--out",
        str(out_path),
    ]
    old_argv = sys.argv
    try:
        sys.argv = argv
        assert checker.main() == 0
    finally:
        sys.argv = old_argv
    payload = json.loads(out_path.read_text(encoding="utf-8"))
    jsonschema.validate(payload, json.loads(SCHEMA.read_text(encoding="utf-8")))
    assert payload["status"] == "pass"


def test_browser_release_candidate_provenance_cli_derives_from_package_inputs(tmp_path: Path) -> None:
    package_inputs_path, package_report = _package_inputs_fixture(tmp_path)
    paths = _candidate_fixture(tmp_path, source_package_inputs=package_inputs_path)
    assert package_report["status"] == "pass"
    assert package_report["releaseCandidateEligible"] is True
    out_path = tmp_path / "candidate-provenance-report.json"
    argv = [
        "check_browser_release_candidate_provenance.py",
        "--release-archive",
        str(paths["release_archive"]),
        "--release-archive-url",
        DOWNLOAD_URL,
        "--release-archive-manifest",
        str(paths["release_archive_manifest"]),
        "--public-download-receipt",
        str(paths["public_download_receipt"]),
        "--proof-surface",
        str(paths["proof_surface"]),
        "--proof-surface-check",
        str(paths["proof_surface_check"]),
        "--browser-launch-receipt",
        str(paths["browser_launch_receipt"]),
        "--package-inputs",
        str(package_inputs_path),
        "--verify-files-root",
        str(tmp_path),
        "--out",
        str(out_path),
    ]
    old_argv = sys.argv
    try:
        sys.argv = argv
        assert checker.main() == 0
    finally:
        sys.argv = old_argv

    payload = json.loads(out_path.read_text(encoding="utf-8"))
    jsonschema.validate(payload, json.loads(SCHEMA.read_text(encoding="utf-8")))
    assert payload["status"] == "pass"
    assert payload["browserProduct"] == package_report["browserProduct"]
    assert payload["platform"] == package_report["platform"]
    assert payload["expectedProvenance"]["browserExecutableArchivePath"] == package_report["inputs"]["browserExecutable"]["archivePath"]
    assert payload["expectedProvenance"]["browserAppMetadataArchivePath"] == package_report["inputs"]["appMetadata"]["archivePath"]
    assert payload["expectedProvenance"]["doeRuntimeArchivePath"] == package_report["inputs"]["doeRuntime"]["archivePath"]
    assert payload["expectedProvenance"]["dawnFallbackRuntimeArchivePath"] == package_report["inputs"]["dawnFallbackRuntime"]["archivePath"]
    assert payload["componentArtifacts"]["packageInputs"]["path"] == str(package_inputs_path)
    assert payload["componentArtifacts"]["packageInputs"]["sha256"] == checker.sha256_file(package_inputs_path)
    assert payload["componentArtifacts"]["packageInputs"]["kind"] == "browser_release_package_inputs_check"
    assert payload["summary"]["componentCount"] == 7


def test_browser_release_candidate_provenance_rejects_package_input_manifest_drift(tmp_path: Path) -> None:
    package_inputs_path, package_report = _package_inputs_fixture(tmp_path)
    paths = _candidate_fixture(tmp_path)
    assert package_report["status"] == "pass"
    report = checker.build_report(
        release_archive=paths["release_archive"],
        release_archive_url=DOWNLOAD_URL,
        release_archive_manifest=paths["release_archive_manifest"],
        public_download_receipt=paths["public_download_receipt"],
        proof_surface=paths["proof_surface"],
        proof_surface_check=paths["proof_surface_check"],
        browser_launch_receipt=paths["browser_launch_receipt"],
        browser_product=package_report["browserProduct"],
        platform=package_report["platform"],
        browser_executable_archive_path=package_report["inputs"]["browserExecutable"]["archivePath"],
        browser_app_metadata_archive_path=package_report["inputs"]["appMetadata"]["archivePath"],
        doe_runtime_archive_path=package_report["inputs"]["doeRuntime"]["archivePath"],
        dawn_fallback_runtime_archive_path=package_report["inputs"]["dawnFallbackRuntime"]["archivePath"],
        package_inputs=package_inputs_path,
        verify_files_root=tmp_path,
    )

    assert report["status"] == "fail"
    assert any(
        item["code"] == "missing_release_archive_manifest_source_package_inputs"
        for item in report["failures"]
    )


def test_browser_release_candidate_provenance_rejects_dirty_package_inputs(tmp_path: Path) -> None:
    package_inputs_path, package_report = _package_inputs_fixture(tmp_path)
    package_report["failures"] = [
        {"code": "stale_failure", "path": "status", "message": "stale failure"}
    ]
    package_report["releaseCandidateBlockers"] = [
        {
            "code": "stale_blocker",
            "path": "releaseCandidateEligible",
            "message": "stale blocker",
        }
    ]
    package_report["summary"]["packageable"] = False
    _write_json(package_inputs_path, package_report)

    loaded_package_inputs, loaded_path, load_failures = checker.load_package_inputs_report(
        str(package_inputs_path),
        tmp_path,
    )
    assert loaded_package_inputs == package_report
    assert loaded_path == package_inputs_path
    assert {
        "code": "package_inputs_release_candidate_blockers_present",
        "path": "packageInputs.releaseCandidateBlockers",
        "message": "package inputs report must carry no release-candidate blockers",
    } in load_failures

    failures = checker.package_inputs_candidate_failures(package_report)
    assert {
        "code": "package_inputs_release_candidate_blockers_present",
        "path": "packageInputs.releaseCandidateBlockers",
        "message": "package inputs report must carry no release-candidate blockers",
    } in failures
    assert {
        "code": "package_inputs_failures_present",
        "path": "packageInputs.failures",
        "message": "passing package inputs report must carry no failures",
    } in failures
    assert {
        "code": "package_inputs_summary_not_packageable",
        "path": "packageInputs.summary.packageable",
        "message": "passing package inputs report summary.packageable must be true",
    } in failures


def test_browser_release_candidate_provenance_cli_keeps_dirty_package_input_identity(tmp_path: Path) -> None:
    package_inputs_path, package_report = _package_inputs_fixture(tmp_path)
    paths = _candidate_fixture(tmp_path, source_package_inputs=package_inputs_path)
    package_report["browserProduct"] = {
        **package_report["browserProduct"],
        "channel": "diagnostic",
    }
    package_report["platform"] = {
        "os": "linux",
        "arch": "x64",
        "packageFormat": "zip",
    }
    package_report["releaseCandidateEligible"] = False
    package_report["evidenceMode"] = "diagnostic"
    package_report["releaseCandidateBlockers"] = [
        {
            "code": "initial_macos_arm64_release_required",
            "path": "platform",
            "message": "initial browser release artifact must be macOS arm64 zip",
        }
    ]
    _write_json(package_inputs_path, package_report)

    out_path = tmp_path / "candidate-provenance-report.json"
    argv = [
        "check_browser_release_candidate_provenance.py",
        "--release-archive",
        str(paths["release_archive"]),
        "--release-archive-url",
        DOWNLOAD_URL,
        "--release-archive-manifest",
        str(paths["release_archive_manifest"]),
        "--public-download-receipt",
        str(paths["public_download_receipt"]),
        "--proof-surface",
        str(paths["proof_surface"]),
        "--proof-surface-check",
        str(paths["proof_surface_check"]),
        "--browser-launch-receipt",
        str(paths["browser_launch_receipt"]),
        "--package-inputs",
        str(package_inputs_path),
        "--verify-files-root",
        str(tmp_path),
        "--out",
        str(out_path),
    ]
    old_argv = sys.argv
    try:
        sys.argv = argv
        assert checker.main() == 1
    finally:
        sys.argv = old_argv

    payload = json.loads(out_path.read_text(encoding="utf-8"))
    jsonschema.validate(payload, json.loads(SCHEMA.read_text(encoding="utf-8")))
    assert payload["status"] == "fail"
    assert payload["browserProduct"] == package_report["browserProduct"]
    assert payload["platform"] == package_report["platform"]
    assert (
        payload["expectedProvenance"]["browserExecutableArchivePath"]
        == package_report["inputs"]["browserExecutable"]["archivePath"]
    )
    failure_codes = {item["code"] for item in payload["failures"]}
    assert "package_inputs_not_release_candidate_eligible" in failure_codes
    assert "candidate_platform_not_macos_arm64" in failure_codes


def test_browser_release_candidate_provenance_rejects_stale_package_input_binary_identity(tmp_path: Path) -> None:
    package_inputs_path, package_report = _package_inputs_fixture(tmp_path)
    for role in ("browserExecutable", "doeRuntime", "dawnFallbackRuntime", "shaderCompiler"):
        package_report["inputs"][role].pop("detectedFormat", None)
        package_report["inputs"][role].pop("detectedArchitectures", None)
    _write_json(package_inputs_path, package_report)

    loaded_package_inputs, loaded_path, load_failures = checker.load_package_inputs_report(
        str(package_inputs_path),
        tmp_path,
    )

    assert loaded_package_inputs == package_report
    assert loaded_path == package_inputs_path
    failure_codes = [item["code"] for item in load_failures]
    assert failure_codes.count("package_inputs_macos_binary_format_mismatch") == 4
    assert failure_codes.count("package_inputs_macos_binary_arch_mismatch") == 4
    assert {
        "code": "package_inputs_macos_binary_format_mismatch",
        "path": "packageInputs.inputs.browserExecutable.detectedFormat",
        "message": "release-candidate package inputs browserExecutable must be Mach-O for macOS",
    } in load_failures
    assert {
        "code": "package_inputs_macos_binary_format_mismatch",
        "path": "packageInputs.inputs.shaderCompiler.detectedFormat",
        "message": "release-candidate package inputs shaderCompiler must be Mach-O for macOS",
    } in load_failures
