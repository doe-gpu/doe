#!/usr/bin/env python3
"""Tests for staged browser release-candidate provenance artifacts."""

from __future__ import annotations

import json
import plistlib
from argparse import Namespace
from pathlib import Path, PurePosixPath

from bench.tools import build_browser_proof_page_receipt as proof_page_builder
from bench.tools import build_browser_published_proof_surface as proof_surface_builder
from bench.tools import check_browser_release_package_inputs as package_inputs_check
from bench.tools import check_browser_release_candidate_provenance as provenance_check
from bench.tools import stage_browser_release_candidate_provenance as stage


REPO_ROOT = Path(__file__).resolve().parents[2]
SURFACE_TEMPLATE = REPO_ROOT / "examples" / "browser-published-proof-surface.sample.json"
PRODUCT = {
    "productId": "fawn-doe",
    "displayName": "Fawn Doe",
    "version": "0.0.0-stage",
    "channel": "release_candidate",
}
PLATFORM = {"os": "macos", "arch": "arm64", "packageFormat": "zip"}
MEMBERS = {
    "browserExecutable": "Fawn.app/Contents/MacOS/Chromium",
    "appMetadata": "Fawn.app/Contents/Info.plist",
    "doeRuntime": "Fawn.app/Contents/Frameworks/libwebgpu_doe.so",
    "dawnFallbackRuntime": "Fawn.app/Contents/Frameworks/libdawn_native.so",
}
DOWNLOAD_URL = "https://downloads.doe.dev/Fawn-Doe-macos-arm64.zip"


def _rooted_path(root: Path, path_text: str) -> Path:
    return root.joinpath(*PurePosixPath(path_text).parts)


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


def _copy_repo_file(root: Path, relative_path: str) -> Path:
    out_path = _rooted_path(root, relative_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_bytes((REPO_ROOT / relative_path).read_bytes())
    return out_path


def _resolved_comparison(root: Path, comparison: dict) -> dict:
    row = json.loads(json.dumps(comparison))
    row["runner"]["pageArtifactPath"] = str(
        _rooted_path(root, row["runner"]["pageArtifactPath"])
    )
    for key in ("comparisonArtifact", "dawnReceipt", "doeReceipt"):
        row[key]["path"] = str(_rooted_path(root, row[key]["path"]))
    return row


def _copy_surface_template_references(root: Path) -> None:
    template = json.loads(SURFACE_TEMPLATE.read_text(encoding="utf-8"))
    for row in template["proofPage"]["receiptPayloads"]:
        _copy_repo_file(root, row["path"])
    resolved_comparisons = [
        _resolved_comparison(root, row)
        for row in template["comparisonReceipts"]
    ]
    comparison_fragments = [
        fragment
        for row in resolved_comparisons
        for fragment in proof_surface_builder.comparison_visibility_fragments(row)
    ]
    for row in template["comparisonReceipts"]:
        _copy_repo_file(root, row["comparisonArtifact"]["path"])
        _copy_repo_file(root, row["dawnReceipt"]["path"])
        _copy_repo_file(root, row["doeReceipt"]["path"])
    for row in template["galleryPages"]:
        gallery_path = _copy_repo_file(root, row["artifact"]["path"])
        receipt_artifact_paths = [
            str(_rooted_path(root, artifact["path"]))
            for artifact in row["receiptArtifacts"]
        ]
        for artifact in row["receiptArtifacts"]:
            _copy_repo_file(root, artifact["path"])
        gallery_path.write_text(
            gallery_path.read_text(encoding="utf-8")
            + "\n".join(
                f"<p>{fragment}</p>"
                for fragment in receipt_artifact_paths + comparison_fragments
            )
            + "\n",
            encoding="utf-8",
        )
        receipt_path = _copy_repo_file(root, row["publicReceipt"]["path"])
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["galleryArtifactPath"] = str(gallery_path)
        receipt["contentSha256"] = provenance_check.sha256_file(gallery_path)
        receipt["contentLengthBytes"] = gallery_path.stat().st_size
        receipt["receiptArtifactPaths"] = receipt_artifact_paths
        _write_json(receipt_path, receipt)


def _candidate_inputs(
    tmp_path: Path,
    *,
    source_package_inputs: Path | None = None,
) -> tuple[Path, Path, Path, dict]:
    release_archive = tmp_path / "Fawn-Doe-macos-arm64.zip"
    release_archive.write_bytes(b"candidate release archive\n")
    archive_hash = provenance_check.sha256_file(release_archive)
    manifest = {
        "schemaVersion": 1,
        "artifactKind": "browser_release_archive_manifest",
        "archive": {
            "path": str(release_archive),
            "sha256": archive_hash,
            "byteLength": release_archive.stat().st_size,
            "kind": "browser_release_archive",
        },
        "browserProduct": PRODUCT,
        "platform": PLATFORM,
        "appBundleName": "Fawn.app",
        "members": {
            name: {
                "archivePath": archive_path,
                "sha256": "1" * 64,
                "byteLength": 1,
                "executable": True,
            }
            for name, archive_path in MEMBERS.items()
        },
        "archiveMembers": [],
    }
    if source_package_inputs is not None:
        manifest["sourcePackageInputs"] = {
            "path": str(source_package_inputs),
            "sha256": provenance_check.sha256_file(source_package_inputs),
            "kind": "browser_release_package_inputs_check",
        }
    manifest["archiveMembers"] = list(manifest["members"].values())
    manifest_path = _write_json(tmp_path / "Fawn-Doe-macos-arm64.manifest.json", manifest)
    public_receipt = {
        "schemaVersion": 1,
        "artifactKind": "browser_public_download_receipt",
        "receiptId": "candidate-public-download",
        "url": DOWNLOAD_URL,
        "method": "GET",
        "statusCode": 200,
        "contentSha256": archive_hash,
        "contentLengthBytes": release_archive.stat().st_size,
        "releaseArchivePath": str(release_archive),
        "releaseArchiveManifestPath": str(manifest_path),
        "releaseArchiveManifestSha256": provenance_check.sha256_file(manifest_path),
        "browserProduct": PRODUCT,
        "platform": PLATFORM,
        "browserExecutableArchivePath": MEMBERS["browserExecutable"],
        "browserAppMetadataArchivePath": MEMBERS["appMetadata"],
        "doeRuntimeArchivePath": MEMBERS["doeRuntime"],
        "dawnFallbackRuntimeArchivePath": MEMBERS["dawnFallbackRuntime"],
        "observedAt": "2026-07-01T00:00:00Z",
    }
    public_receipt_path = _write_json(tmp_path / "browser-public-download.json", public_receipt)
    release_provenance = proof_page_builder.build_release_provenance(
        release_archive=release_archive,
        release_archive_url=DOWNLOAD_URL,
        release_archive_manifest=manifest_path,
        public_download_receipt=public_receipt_path,
        browser_product=PRODUCT,
        platform=PLATFORM,
        browser_executable_archive_path=MEMBERS["browserExecutable"],
        browser_app_metadata_archive_path=MEMBERS["appMetadata"],
        doe_runtime_archive_path=MEMBERS["doeRuntime"],
        dawn_fallback_runtime_archive_path=MEMBERS["dawnFallbackRuntime"],
    )
    return release_archive, manifest_path, public_receipt_path, release_provenance


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


def _proof_page(
    tmp_path: Path,
    release_provenance: dict,
    *,
    compiler_path: str = "runtime/zig/zig-out/bin/doe-zig-runtime",
) -> Path:
    template = json.loads(SURFACE_TEMPLATE.read_text(encoding="utf-8"))
    diagnostics = {
        "activeRuntime": "doe",
        "activeBackend": "webgpu-doe",
        "webgpuAvailable": True,
        "compilerPath": compiler_path,
        "tsirStatus": "available",
        "hostPlanStatus": "not_applicable",
        "cslStatus": "not_applicable",
        "fallbackPolicyState": "hidden_fallback_disabled",
    }
    fragments: list[str] = []
    for value in diagnostics.values():
        if isinstance(value, bool):
            fragments.append("true" if value else "false")
        elif isinstance(value, str):
            fragments.append(value)
    fragments.extend(proof_surface_builder.release_provenance_fragments(release_provenance))
    fragments.extend(template["proofPage"]["recentReceiptIds"])
    fragments.extend(row["path"] for row in template["proofPage"]["receiptPayloads"])
    fragments.extend(
        str(_rooted_path(tmp_path, row["path"]))
        for row in template["proofPage"]["receiptPayloads"]
    )
    for comparison in template["comparisonReceipts"]:
        fragments.extend(proof_surface_builder.comparison_visibility_fragments(comparison))
        fragments.extend(
            proof_surface_builder.comparison_visibility_fragments(
                _resolved_comparison(tmp_path, comparison)
            )
        )
    proof_page = tmp_path / "about-doe-candidate.html"
    proof_page.write_text(
        "<!doctype html>\n<meta charset=\"utf-8\">\n"
        + "\n".join(f"<p>{fragment}</p>" for fragment in fragments)
        + "\n",
        encoding="utf-8",
    )
    return proof_page


def _args(tmp_path: Path, release_archive: Path, manifest: Path, public_receipt: Path, proof_page: Path) -> Namespace:
    return Namespace(
        surface_template=str(SURFACE_TEMPLATE),
        release_archive=str(release_archive),
        release_archive_url=DOWNLOAD_URL,
        release_archive_manifest=str(manifest),
        public_download_receipt=str(public_receipt),
        proof_page_artifact=str(proof_page),
        proof_page_url="about:doe",
        proof_page_receipt_id="candidate-proof-page",
        browser_launch_receipt_id="candidate-launch",
        package_inputs="",
        product_id=PRODUCT["productId"],
        product_name=PRODUCT["displayName"],
        product_version=PRODUCT["version"],
        product_channel=PRODUCT["channel"],
        platform_os=PLATFORM["os"],
        platform_arch=PLATFORM["arch"],
        package_format=PLATFORM["packageFormat"],
        browser_executable_archive_path=MEMBERS["browserExecutable"],
        browser_app_metadata_archive_path=MEMBERS["appMetadata"],
        doe_runtime_archive_path=MEMBERS["doeRuntime"],
        dawn_fallback_runtime_archive_path=MEMBERS["dawnFallbackRuntime"],
        active_backend="webgpu-doe",
        compiler_path="runtime/zig/zig-out/bin/doe-zig-runtime",
        tsir_status="available",
        host_plan_status="not_applicable",
        csl_status="not_applicable",
        gallery_category="compute",
        surface_id="candidate-proof-surface",
        capture_policy_path="",
        runtime_identity_path="",
        observed_at="2026-07-01T00:00:00Z",
        proof_page_receipt_out=str(tmp_path / "browser-proof-page-receipt.json"),
        proof_surface_out=str(tmp_path / "browser-published-proof-surface.json"),
        proof_surface_check_out=str(tmp_path / "browser-published-proof-surface-check.json"),
        browser_launch_receipt_out=str(tmp_path / "browser-release-launch-receipt.json"),
        provenance_report_out=str(tmp_path / "browser-release-candidate-provenance.json"),
        verify_files_root=str(tmp_path),
        emit_json=False,
    )


def test_stage_browser_release_candidate_provenance_outputs_pass(tmp_path: Path) -> None:
    package_inputs_path, package_report = _package_inputs_fixture(tmp_path)
    release_archive, manifest, public_receipt, provenance = _candidate_inputs(
        tmp_path,
        source_package_inputs=package_inputs_path,
    )
    _copy_surface_template_references(tmp_path)
    proof_page = _proof_page(
        tmp_path,
        provenance,
        compiler_path=package_report["inputs"]["shaderCompiler"]["path"],
    )
    args = _args(tmp_path, release_archive, manifest, public_receipt, proof_page)
    args.package_inputs = str(package_inputs_path)
    args.compiler_path = ""

    summary = stage.build_stage(args)

    assert summary["status"] == "pass"
    proof_surface_check = json.loads((tmp_path / "browser-published-proof-surface-check.json").read_text(encoding="utf-8"))
    assert proof_surface_check["status"] == "pass"
    assert proof_surface_check["verifyFilesRootProvided"] is True
    assert proof_surface_check["requirePublicUrls"] is True
    report = json.loads((tmp_path / "browser-release-candidate-provenance.json").read_text(encoding="utf-8"))
    assert report["status"] == "pass"
    assert report["componentArtifacts"]["packageInputs"]["path"] == str(package_inputs_path)
    assert report["componentArtifacts"]["proofSurfaceCheck"]["path"] == str(
        tmp_path / "browser-published-proof-surface-check.json"
    )
    proof_surface = json.loads((tmp_path / "browser-published-proof-surface.json").read_text(encoding="utf-8"))
    assert proof_surface["proofPage"]["releaseProvenance"]["browserProduct"]["channel"] == "release_candidate"
    launch = json.loads((tmp_path / "browser-release-launch-receipt.json").read_text(encoding="utf-8"))
    assert launch["browserProduct"]["channel"] == "release_candidate"


def test_comparison_entries_use_proof_surface_paths_under_repo_root() -> None:
    template = json.loads(SURFACE_TEMPLATE.read_text(encoding="utf-8"))
    comparison = template["comparisonReceipts"][0]

    entries = stage.comparison_entries_from_surface(template, REPO_ROOT)

    assert entries[0]["pageArtifactPath"] == comparison["runner"]["pageArtifactPath"]
    assert entries[0]["comparisonArtifact"] == str(REPO_ROOT / comparison["comparisonArtifact"]["path"])
    assert entries[0]["dawnReceipt"] == str(REPO_ROOT / comparison["dawnReceipt"]["path"])
    assert entries[0]["doeReceipt"] == str(REPO_ROOT / comparison["doeReceipt"]["path"])


def test_stage_browser_release_candidate_provenance_requires_package_inputs(tmp_path: Path) -> None:
    release_archive, manifest, public_receipt, provenance = _candidate_inputs(tmp_path)
    _copy_surface_template_references(tmp_path)
    proof_page = _proof_page(tmp_path, provenance)
    args = _args(tmp_path, release_archive, manifest, public_receipt, proof_page)

    try:
        stage.build_stage(args)
    except ValueError as exc:
        assert "requires --package-inputs" in str(exc)
    else:
        raise AssertionError("expected missing package inputs to fail")


def test_stage_browser_release_candidate_provenance_rejects_compiler_path_drift(tmp_path: Path) -> None:
    package_inputs_path, package_report = _package_inputs_fixture(tmp_path)
    release_archive, manifest, public_receipt, provenance = _candidate_inputs(
        tmp_path,
        source_package_inputs=package_inputs_path,
    )
    _copy_surface_template_references(tmp_path)
    proof_page = _proof_page(
        tmp_path,
        provenance,
        compiler_path=package_report["inputs"]["shaderCompiler"]["path"],
    )
    args = _args(tmp_path, release_archive, manifest, public_receipt, proof_page)
    args.package_inputs = str(package_inputs_path)
    args.compiler_path = "other-doe-zig-runtime"

    try:
        stage.build_stage(args)
    except ValueError as exc:
        assert "--compiler-path must match package inputs role shaderCompiler" in str(exc)
    else:
        raise AssertionError("expected compiler path drift to fail")


def test_stage_browser_release_candidate_provenance_derives_package_inputs(tmp_path: Path) -> None:
    package_inputs_path, package_report = _package_inputs_fixture(tmp_path)
    release_archive, manifest, public_receipt, provenance = _candidate_inputs(
        tmp_path,
        source_package_inputs=package_inputs_path,
    )
    assert package_report["status"] == "pass"
    assert package_report["releaseCandidateEligible"] is True
    _copy_surface_template_references(tmp_path)
    proof_page = _proof_page(
        tmp_path,
        provenance,
        compiler_path=package_report["inputs"]["shaderCompiler"]["path"],
    )
    args = _args(tmp_path, release_archive, manifest, public_receipt, proof_page)
    args.package_inputs = str(package_inputs_path)
    args.product_version = ""
    args.browser_executable_archive_path = ""
    args.browser_app_metadata_archive_path = ""
    args.doe_runtime_archive_path = ""
    args.dawn_fallback_runtime_archive_path = ""
    args.compiler_path = ""

    summary = stage.build_stage(args)

    assert summary["status"] == "pass"
    proof_receipt = json.loads((tmp_path / "browser-proof-page-receipt.json").read_text(encoding="utf-8"))
    assert proof_receipt["diagnostics"]["compilerPath"] == package_report["inputs"]["shaderCompiler"]["path"]
    assert proof_receipt["releaseProvenance"]["browserProduct"] == package_report["browserProduct"]
    assert proof_receipt["releaseProvenance"]["platform"] == package_report["platform"]
    assert proof_receipt["releaseProvenance"]["browserExecutableArchivePath"] == package_report["inputs"]["browserExecutable"]["archivePath"]
    assert proof_receipt["releaseProvenance"]["browserAppMetadataArchivePath"] == package_report["inputs"]["appMetadata"]["archivePath"]
    assert proof_receipt["releaseProvenance"]["doeRuntimeArchivePath"] == package_report["inputs"]["doeRuntime"]["archivePath"]
    assert proof_receipt["releaseProvenance"]["dawnFallbackRuntimeArchivePath"] == package_report["inputs"]["dawnFallbackRuntime"]["archivePath"]
    report = json.loads((tmp_path / "browser-release-candidate-provenance.json").read_text(encoding="utf-8"))
    assert report["status"] == "pass"
    assert report["componentArtifacts"]["packageInputs"]["path"] == str(package_inputs_path)
    assert report["componentArtifacts"]["packageInputs"]["sha256"] == provenance_check.sha256_file(package_inputs_path)
    assert report["summary"]["componentCount"] == 7


def test_stage_browser_release_candidate_provenance_rejects_dirty_package_inputs(tmp_path: Path) -> None:
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
    release_archive, manifest, public_receipt, provenance = _candidate_inputs(
        tmp_path,
        source_package_inputs=package_inputs_path,
    )
    _copy_surface_template_references(tmp_path)
    proof_page = _proof_page(
        tmp_path,
        provenance,
        compiler_path=package_report["inputs"]["shaderCompiler"]["path"],
    )
    args = _args(tmp_path, release_archive, manifest, public_receipt, proof_page)
    args.package_inputs = str(package_inputs_path)

    try:
        stage.build_stage(args)
    except ValueError as exc:
        assert "release-candidate blockers" in str(exc)
    else:
        raise AssertionError("expected dirty package inputs to fail")
