#!/usr/bin/env python3
"""Tests for final browser release-candidate bundle assembly."""

from __future__ import annotations

import json
import plistlib
import sys
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path
from typing import Any

import jsonschema

from bench.tools import check_browser_release_artifact_bundle as bundle_check
from bench.tools import check_browser_release_candidate_finalizer as finalizer_check
from bench.tools import check_browser_release_candidate_provenance as provenance_check
from bench.tools import check_browser_release_package_inputs as package_inputs_check
from bench.tools import build_browser_release_artifact_bundle as bundle_builder
from bench.tools import finalize_browser_release_candidate_bundle as finalizer
from bench.tests.test_browser_release_artifact_bundle import (
    DEFAULT_APP_METADATA_ARCHIVE_PATH,
    DEFAULT_BROWSER_ARCHIVE_PATH,
    DEFAULT_BROWSER_PRODUCT,
    DEFAULT_DAWN_RUNTIME_ARCHIVE_PATH,
    DEFAULT_DOE_RUNTIME_ARCHIVE_PATH,
    _macho_payload,
    _release_bundle_inputs,
)


DOWNLOAD_URL = "https://downloads.doe.dev/Fawn-Doe-macos-arm64.zip"
PLATFORM = {"os": "macos", "arch": "arm64", "packageFormat": "zip"}
SCHEMA = Path(__file__).resolve().parents[2] / "config" / "browser-release-candidate-finalizer.schema.json"
CHECK_SCHEMA = Path(__file__).resolve().parents[2] / "config" / "browser-release-candidate-finalizer-check.schema.json"


def _candidate_product() -> dict[str, str]:
    return {**DEFAULT_BROWSER_PRODUCT, "channel": "release_candidate"}


def _write_json(path: Path, payload: dict[str, Any]) -> Path:
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return path


def _write_package_file(path: Path, payload: bytes, mode: int = 0o644) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)
    path.chmod(mode)
    return path


def _write_macos_plist(path: Path, *, version: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as handle:
        plistlib.dump(
            {
                "CFBundleName": "Fawn Doe",
                "CFBundleDisplayName": "Fawn Doe",
                "CFBundleIdentifier": "dev.doe.fawn-doe",
                "CFBundleShortVersionString": version,
                "CFBundleVersion": version,
                "CFBundleExecutable": "Chromium",
                "CFBundlePackageType": "APPL",
            },
            handle,
        )
    return path


def _write_package_inputs_report(
    tmp_path: Path,
    paths: dict[str, Any],
    *,
    product_channel: str = "release_candidate",
) -> tuple[Path, dict[str, Any]]:
    paths["shader_compiler"].chmod(0o755)
    app_dir = tmp_path / "Fawn.app"
    _write_package_file(
        app_dir / "Contents" / "MacOS" / "Chromium",
        _macho_payload(),
        0o755,
    )
    _write_macos_plist(
        app_dir / "Contents" / "Info.plist",
        version=_candidate_product()["version"],
    )
    report = package_inputs_check.build_report(
        package_dir=str(app_dir),
        package_root_name="Fawn.app",
        doe_runtime=str(paths["doe_runtime"]),
        dawn_fallback_runtime=str(paths["dawn_fallback_runtime"]),
        shader_compiler=str(paths["shader_compiler"]),
        product_version=_candidate_product()["version"],
        product_channel=product_channel,
        platform_os="macos",
        platform_arch="arm64",
        root=tmp_path,
    )
    report_path = tmp_path / "browser-release-package-inputs.json"
    _write_json(report_path, report)
    return report_path, report


def _write_provenance_report(
    tmp_path: Path,
    paths: dict[str, Any],
) -> tuple[Path, dict[str, Any]]:
    package_inputs = paths.get("package_inputs")
    report = provenance_check.build_report(
        release_archive=paths["release_archive"],
        release_archive_url=DOWNLOAD_URL,
        release_archive_manifest=paths["release_archive_manifest"],
        public_download_receipt=paths["public_download_receipt"],
        proof_surface=paths["proof_surface"],
        proof_surface_check=paths["proof_surface_check"],
        browser_launch_receipt=paths["browser_launch_receipt"],
        browser_product=_candidate_product(),
        platform=PLATFORM,
        browser_executable_archive_path=DEFAULT_BROWSER_ARCHIVE_PATH,
        browser_app_metadata_archive_path=DEFAULT_APP_METADATA_ARCHIVE_PATH,
        doe_runtime_archive_path=DEFAULT_DOE_RUNTIME_ARCHIVE_PATH,
        dawn_fallback_runtime_archive_path=DEFAULT_DAWN_RUNTIME_ARCHIVE_PATH,
        package_inputs=package_inputs if isinstance(package_inputs, Path) else None,
        verify_files_root=tmp_path,
    )
    report_path = tmp_path / "browser-release-candidate-provenance.json"
    _write_json(report_path, report)
    return report_path, report


def _finalizer_args(
    tmp_path: Path,
    paths: dict[str, Any],
    provenance_report: Path,
) -> Namespace:
    return Namespace(
        bundle_id="test-bundle",
        provenance_report=str(provenance_report),
        release_archive=str(paths["release_archive"]),
        release_archive_url=DOWNLOAD_URL,
        release_archive_manifest=str(paths["release_archive_manifest"]),
        public_download_receipt=str(paths["public_download_receipt"]),
        proof_surface=str(paths["proof_surface"]),
        proof_surface_check=str(paths["proof_surface_check"]),
        browser_launch_receipt=str(paths["browser_launch_receipt"]),
        chromium_source_checkout=str(paths["chromium_source_checkout"]),
        runtime_identity=str(tmp_path / "examples/browser-runtime-identity.selector.sample.json"),
        runtime_frontier_bundle_out=str(tmp_path / "generated-runtime-frontier-bundle.json"),
        package_inputs=str(paths["package_inputs"]),
        browser_binary=str(paths["browser_binary"]),
        doe_runtime=str(paths["doe_runtime"]),
        dawn_fallback_runtime=str(paths["dawn_fallback_runtime"]),
        shader_compiler=str(paths["shader_compiler"]),
        claim_report=[str(path) for path in paths["claim_reports"]],
        promotion_receipt=[str(path) for path in paths["promotion_receipts"]],
        contract=[str(path) for path in paths["contracts"]],
        policy=[str(path) for path in paths["policies"]],
        product_id=_candidate_product()["productId"],
        product_name=_candidate_product()["displayName"],
        product_version=_candidate_product()["version"],
        browser_executable_archive_path=DEFAULT_BROWSER_ARCHIVE_PATH,
        browser_app_metadata_archive_path=DEFAULT_APP_METADATA_ARCHIVE_PATH,
        doe_runtime_archive_path=DEFAULT_DOE_RUNTIME_ARCHIVE_PATH,
        dawn_fallback_runtime_archive_path=DEFAULT_DAWN_RUNTIME_ARCHIVE_PATH,
        verify_files_root=str(tmp_path),
        out=str(tmp_path / "release-bundle.json"),
        report_out=str(tmp_path / "browser-release-candidate-finalizer.json"),
        emit_json=False,
    )


class BrowserReleaseCandidateFinalizerTests(unittest.TestCase):
    def test_outputs_verified_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            paths = _release_bundle_inputs(tmp_path, release_status="release_candidate")
            provenance_path, report = _write_provenance_report(tmp_path, paths)
            self.assertEqual(report["status"], "pass")

            report["componentArtifacts"]["releaseArchive"]["path"] = paths["release_archive"].name
            _write_json(provenance_path, report)

            args = _finalizer_args(tmp_path, paths, provenance_path)
            final_bundle, frontier_report, summary = finalizer.build_final_bundle(args)

            self.assertEqual(summary["status"], "pass")
            self.assertEqual(frontier_report["claimabilityStatus"], "claimable")
            self.assertEqual(frontier_report["claimBlockers"], [])
            self.assertTrue(Path(args.out).is_file())
            self.assertTrue(Path(args.runtime_frontier_bundle_out).is_file())
            self.assertEqual(
                json.loads(Path(args.out).read_text(encoding="utf-8")),
                final_bundle,
            )
            self.assertEqual(
                bundle_check.check_bundle(
                    final_bundle,
                    verify_files_root=tmp_path,
                    require_release_candidate=True,
                    bundle_path=Path(args.out).name,
                ),
                [],
            )

    def test_outputs_verified_bundle_from_package_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            paths = _release_bundle_inputs(tmp_path, release_status="release_candidate")
            provenance_path, report = _write_provenance_report(tmp_path, paths)
            self.assertEqual(report["status"], "pass")
            package_inputs_path = paths["package_inputs"]
            package_report = json.loads(
                package_inputs_path.read_text(encoding="utf-8")
            )
            self.assertEqual(package_report["status"], "pass")
            self.assertTrue(package_report["releaseCandidateEligible"])

            args = _finalizer_args(tmp_path, paths, provenance_path)
            args.package_inputs = str(package_inputs_path)
            args.browser_binary = ""
            args.doe_runtime = ""
            args.dawn_fallback_runtime = ""
            args.shader_compiler = ""
            args.product_version = ""
            args.browser_executable_archive_path = ""
            args.browser_app_metadata_archive_path = ""
            args.doe_runtime_archive_path = ""
            args.dawn_fallback_runtime_archive_path = ""

            final_bundle, frontier_report, summary = finalizer.build_final_bundle(args)

            self.assertEqual(summary["status"], "pass")
            jsonschema.validate(summary, json.loads(SCHEMA.read_text(encoding="utf-8")))
            self.assertEqual(frontier_report["claimabilityStatus"], "claimable")
            self.assertEqual(
                summary["summary"]["releaseBundleIdentitySha256"],
                bundle_check.release_bundle_identity_sha256(final_bundle),
            )
            self.assertEqual(
                summary["inputs"]["packageInputs"]["path"],
                str(package_inputs_path),
            )
            self.assertEqual(
                summary["inputs"]["packageInputs"]["sha256"],
                bundle_builder.sha256_file(package_inputs_path),
            )
            self.assertEqual(
                summary["inputs"]["packageInputs"]["kind"],
                "browser_release_package_inputs_check",
            )
            self.assertEqual(
                summary["inputs"]["provenanceReport"]["path"],
                str(provenance_path),
            )
            self.assertEqual(
                summary["inputs"]["provenanceReport"]["sha256"],
                bundle_builder.sha256_file(provenance_path),
            )
            self.assertEqual(
                summary["inputs"]["provenanceReport"]["kind"],
                "browser_release_candidate_provenance_report",
            )
            self.assertEqual(
                final_bundle["browserProduct"],
                package_report["browserProduct"],
            )
            self.assertEqual(final_bundle["platform"], package_report["platform"])
            self.assertEqual(
                final_bundle["browserExecutableArchivePath"],
                package_report["inputs"]["browserExecutable"]["archivePath"],
            )
            self.assertEqual(
                final_bundle["browserAppMetadataArchivePath"],
                package_report["inputs"]["appMetadata"]["archivePath"],
            )
            self.assertEqual(
                final_bundle["doeRuntimeArchivePath"],
                package_report["inputs"]["doeRuntime"]["archivePath"],
            )
            self.assertEqual(
                final_bundle["dawnFallbackRuntimeArchivePath"],
                package_report["inputs"]["dawnFallbackRuntime"]["archivePath"],
            )
            self.assertEqual(
                final_bundle["browserBinary"]["path"],
                str(tmp_path / package_report["inputs"]["browserExecutable"]["path"]),
            )
            self.assertEqual(
                final_bundle["doeRuntime"]["path"],
                str(tmp_path / package_report["inputs"]["doeRuntime"]["path"]),
            )
            self.assertEqual(
                final_bundle["dawnFallbackRuntime"]["path"],
                str(tmp_path / package_report["inputs"]["dawnFallbackRuntime"]["path"]),
            )
            self.assertEqual(
                final_bundle["shaderCompiler"]["path"],
                str(tmp_path / package_report["inputs"]["shaderCompiler"]["path"]),
            )
            self.assertEqual(
                bundle_check.check_bundle(
                    final_bundle,
                    verify_files_root=tmp_path,
                    require_release_candidate=True,
                    bundle_path=Path(args.out).name,
                ),
                [],
            )
            self.assertEqual(
                finalizer_check.check_report(
                    summary,
                    verify_files_root=tmp_path,
                    require_pass=True,
                ),
                [],
            )

    def test_rejects_diagnostic_package_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            paths = _release_bundle_inputs(tmp_path, release_status="release_candidate")
            provenance_path, report = _write_provenance_report(tmp_path, paths)
            self.assertEqual(report["status"], "pass")
            package_inputs_path, package_report = _write_package_inputs_report(
                tmp_path,
                paths,
                product_channel="diagnostic",
            )
            self.assertEqual(package_report["status"], "pass")
            self.assertFalse(package_report["releaseCandidateEligible"])

            args = _finalizer_args(tmp_path, paths, provenance_path)
            args.package_inputs = str(package_inputs_path)
            args.browser_binary = ""
            args.doe_runtime = ""
            args.dawn_fallback_runtime = ""
            args.shader_compiler = ""
            args.product_version = ""
            args.browser_executable_archive_path = ""
            args.browser_app_metadata_archive_path = ""
            args.doe_runtime_archive_path = ""
            args.dawn_fallback_runtime_archive_path = ""

            final_bundle, frontier_report, summary = finalizer.build_final_bundle(args)

            self.assertEqual(final_bundle, {})
            self.assertEqual(frontier_report, {})
            self.assertEqual(summary["status"], "fail")
            self.assertEqual(summary["phase"], "package_inputs_preflight")
            jsonschema.validate(summary, json.loads(SCHEMA.read_text(encoding="utf-8")))
            self.assertTrue(
                any(
                    item["code"] == "package_inputs_not_release_candidate_eligible"
                    for item in summary["failures"]
                ),
                summary["failures"],
            )

    def test_rejects_dirty_passing_package_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            paths = _release_bundle_inputs(tmp_path, release_status="release_candidate")
            provenance_path, report = _write_provenance_report(tmp_path, paths)
            self.assertEqual(report["status"], "pass")
            package_inputs_path = paths["package_inputs"]
            package_report = json.loads(
                package_inputs_path.read_text(encoding="utf-8")
            )
            package_report["failures"] = [
                {
                    "code": "stale_failure",
                    "path": "status",
                    "message": "stale failure",
                }
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

            args = _finalizer_args(tmp_path, paths, provenance_path)
            args.browser_binary = ""
            args.doe_runtime = ""
            args.dawn_fallback_runtime = ""
            args.shader_compiler = ""
            args.product_version = ""
            args.browser_executable_archive_path = ""
            args.browser_app_metadata_archive_path = ""
            args.doe_runtime_archive_path = ""
            args.dawn_fallback_runtime_archive_path = ""

            final_bundle, frontier_report, summary = finalizer.build_final_bundle(args)

            self.assertEqual(final_bundle, {})
            self.assertEqual(frontier_report, {})
            self.assertEqual(summary["status"], "fail")
            self.assertEqual(summary["phase"], "package_inputs_preflight")
            self.assertIn(
                {
                    "code": "package_inputs_release_candidate_blockers_present",
                    "path": "packageInputs.releaseCandidateBlockers",
                    "message": (
                        "package inputs must carry no release-candidate blockers "
                        "before final bundle assembly"
                    ),
                },
                summary["failures"],
            )
            self.assertIn(
                {
                    "code": "package_inputs_failures_present",
                    "path": "packageInputs.failures",
                    "message": (
                        "package inputs must carry no failures before final "
                        "bundle assembly"
                    ),
                },
                summary["failures"],
            )
            self.assertIn(
                {
                    "code": "package_inputs_summary_not_packageable",
                    "path": "packageInputs.summary.packageable",
                    "message": (
                        "package inputs summary.packageable must be true before "
                        "final bundle assembly"
                    ),
                },
                summary["failures"],
            )
            jsonschema.validate(summary, json.loads(SCHEMA.read_text(encoding="utf-8")))

    def test_rejects_stale_package_input_binary_identity(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            paths = _release_bundle_inputs(tmp_path, release_status="release_candidate")
            provenance_path, report = _write_provenance_report(tmp_path, paths)
            self.assertEqual(report["status"], "pass")
            package_inputs_path = paths["package_inputs"]
            package_report = json.loads(
                package_inputs_path.read_text(encoding="utf-8")
            )
            for role in ("browserExecutable", "doeRuntime", "dawnFallbackRuntime", "shaderCompiler"):
                package_report["inputs"][role].pop("detectedFormat", None)
                package_report["inputs"][role].pop("detectedArchitectures", None)
            _write_json(package_inputs_path, package_report)

            args = _finalizer_args(tmp_path, paths, provenance_path)
            args.browser_binary = ""
            args.doe_runtime = ""
            args.dawn_fallback_runtime = ""
            args.shader_compiler = ""
            args.product_version = ""
            args.browser_executable_archive_path = ""
            args.browser_app_metadata_archive_path = ""
            args.doe_runtime_archive_path = ""
            args.dawn_fallback_runtime_archive_path = ""

            final_bundle, frontier_report, summary = finalizer.build_final_bundle(args)

            self.assertEqual(final_bundle, {})
            self.assertEqual(frontier_report, {})
            self.assertEqual(summary["status"], "fail")
            self.assertEqual(summary["phase"], "package_inputs_preflight")
            failure_codes = [item["code"] for item in summary["failures"]]
            self.assertEqual(
                failure_codes.count("package_inputs_macos_binary_format_mismatch"),
                4,
            )
            self.assertEqual(
                failure_codes.count("package_inputs_macos_binary_arch_mismatch"),
                4,
            )
            self.assertIn(
                {
                    "code": "package_inputs_macos_binary_format_mismatch",
                    "path": "packageInputs.inputs.browserExecutable.detectedFormat",
                    "message": (
                        "release-candidate package inputs browserExecutable "
                        "must be Mach-O for macOS"
                    ),
                },
                summary["failures"],
            )
            self.assertIn(
                {
                    "code": "package_inputs_macos_binary_format_mismatch",
                    "path": "packageInputs.inputs.shaderCompiler.detectedFormat",
                    "message": (
                        "release-candidate package inputs shaderCompiler "
                        "must be Mach-O for macOS"
                    ),
                },
                summary["failures"],
            )
            jsonschema.validate(summary, json.loads(SCHEMA.read_text(encoding="utf-8")))

    def test_stops_on_failed_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            paths = _release_bundle_inputs(tmp_path, release_status="release_candidate")
            provenance_path, report = _write_provenance_report(tmp_path, paths)
            report["status"] = "fail"
            report["failures"] = [
                {
                    "code": "release_archive_manifest_product_mismatch",
                    "path": "releaseArchiveManifest.browserProduct",
                    "message": "fixture drift",
                }
            ]
            _write_json(provenance_path, report)

            args = _finalizer_args(tmp_path, paths, provenance_path)
            final_bundle, frontier_report, summary = finalizer.build_final_bundle(args)

            self.assertEqual(final_bundle, {})
            self.assertEqual(frontier_report, {})
            self.assertEqual(summary["status"], "fail")
            self.assertEqual(summary["phase"], "provenance_preflight")
            self.assertTrue(
                any(
                    item["code"] == "provenance_report_not_pass"
                    for item in summary["failures"]
                )
            )
            self.assertFalse(Path(args.out).exists())
            self.assertFalse(Path(args.runtime_frontier_bundle_out).exists())

    def test_cli_writes_finalizer_report(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            paths = _release_bundle_inputs(tmp_path, release_status="release_candidate")
            provenance_path, report = _write_provenance_report(tmp_path, paths)
            self.assertEqual(report["status"], "pass")
            report_path = tmp_path / "browser-release-candidate-finalizer.json"
            out_path = tmp_path / "release-bundle.json"
            frontier_path = tmp_path / "generated-runtime-frontier-bundle.json"
            argv = [
                "finalize_browser_release_candidate_bundle.py",
                "--bundle-id",
                "test-bundle",
                "--provenance-report",
                str(provenance_path),
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
                "--chromium-source-checkout",
                str(paths["chromium_source_checkout"]),
                "--runtime-identity",
                str(tmp_path / "examples/browser-runtime-identity.selector.sample.json"),
                "--runtime-frontier-bundle-out",
                str(frontier_path),
                "--package-inputs",
                str(paths["package_inputs"]),
                "--browser-binary",
                str(paths["browser_binary"]),
                "--doe-runtime",
                str(paths["doe_runtime"]),
                "--dawn-fallback-runtime",
                str(paths["dawn_fallback_runtime"]),
                "--shader-compiler",
                str(paths["shader_compiler"]),
                "--claim-report",
                str(paths["claim_reports"][0]),
                "--promotion-receipt",
                str(paths["promotion_receipts"][0]),
                "--contract",
                str(paths["contracts"][0]),
                "--product-version",
                _candidate_product()["version"],
                "--browser-executable-archive-path",
                DEFAULT_BROWSER_ARCHIVE_PATH,
                "--browser-app-metadata-archive-path",
                DEFAULT_APP_METADATA_ARCHIVE_PATH,
                "--doe-runtime-archive-path",
                DEFAULT_DOE_RUNTIME_ARCHIVE_PATH,
                "--dawn-fallback-runtime-archive-path",
                DEFAULT_DAWN_RUNTIME_ARCHIVE_PATH,
                "--verify-files-root",
                str(tmp_path),
                "--out",
                str(out_path),
                "--report-out",
                str(report_path),
            ]
            for policy in paths["policies"]:
                argv.extend(["--policy", str(policy)])

            old_argv = sys.argv
            try:
                sys.argv = argv
                self.assertEqual(finalizer.main(), 0)
            finally:
                sys.argv = old_argv

            self.assertTrue(out_path.is_file())
            self.assertTrue(frontier_path.is_file())
            payload = json.loads(report_path.read_text(encoding="utf-8"))
            jsonschema.validate(payload, json.loads(SCHEMA.read_text(encoding="utf-8")))
            self.assertEqual(payload["artifactKind"], "browser_release_candidate_finalizer")
            self.assertEqual(payload["status"], "pass")
            self.assertEqual(payload["outputs"]["releaseArtifactBundle"]["path"], str(out_path))
            self.assertEqual(
                payload["outputs"]["releaseArtifactBundle"]["sha256"],
                bundle_builder.sha256_file(out_path),
            )
            self.assertEqual(
                payload["outputs"]["releaseArtifactBundle"]["kind"],
                "browser_release_artifact_bundle",
            )
            self.assertEqual(payload["outputs"]["runtimeFrontierBundle"]["path"], str(frontier_path))
            self.assertEqual(
                payload["outputs"]["runtimeFrontierBundle"]["sha256"],
                bundle_builder.sha256_file(frontier_path),
            )
            self.assertEqual(
                payload["outputs"]["runtimeFrontierBundle"]["kind"],
                "browser_runtime_frontier_bundle",
            )
            self.assertEqual(
                finalizer_check.check_report(
                    payload,
                    verify_files_root=tmp_path,
                    require_pass=True,
                ),
                [],
            )

    def test_checker_cli_writes_passing_report_bindings(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            paths = _release_bundle_inputs(tmp_path, release_status="release_candidate")
            provenance_path, report = _write_provenance_report(tmp_path, paths)
            self.assertEqual(report["status"], "pass")

            args = _finalizer_args(tmp_path, paths, provenance_path)
            _final_bundle, _frontier_report, summary = finalizer.build_final_bundle(args)
            self.assertEqual(summary["status"], "pass")
            report_path = Path(args.report_out)
            _write_json(report_path, summary)
            check_path = tmp_path / "browser-release-candidate-finalizer-check.json"

            old_argv = sys.argv
            try:
                sys.argv = [
                    "check_browser_release_candidate_finalizer.py",
                    "--report",
                    str(report_path),
                    "--verify-files-root",
                    str(tmp_path),
                    "--require-pass",
                    "--out",
                    str(check_path),
                ]
                self.assertEqual(finalizer_check.main(), 0)
            finally:
                sys.argv = old_argv

            payload = json.loads(check_path.read_text(encoding="utf-8"))
            jsonschema.validate(
                payload,
                json.loads(CHECK_SCHEMA.read_text(encoding="utf-8")),
            )
            self.assertEqual(payload["status"], "pass")
            self.assertEqual(payload["finalizerStatus"], "pass")
            self.assertEqual(payload["outputs"], summary["outputs"])
            self.assertEqual(payload["inputs"], summary["inputs"])

    def test_checker_rejects_tampered_output_hash(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            paths = _release_bundle_inputs(tmp_path, release_status="release_candidate")
            provenance_path, report = _write_provenance_report(tmp_path, paths)
            self.assertEqual(report["status"], "pass")

            args = _finalizer_args(tmp_path, paths, provenance_path)
            _final_bundle, _frontier_report, summary = finalizer.build_final_bundle(args)
            self.assertEqual(summary["status"], "pass")

            summary["outputs"]["releaseArtifactBundle"]["sha256"] = "0" * 64
            failures = finalizer_check.check_report(
                summary,
                verify_files_root=tmp_path,
                require_pass=True,
            )

            self.assertTrue(
                any(item["code"] == "artifact_hash_mismatch" for item in failures),
                failures,
            )

    def test_checker_rejects_tampered_release_identity_summary(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            paths = _release_bundle_inputs(tmp_path, release_status="release_candidate")
            provenance_path, report = _write_provenance_report(tmp_path, paths)
            self.assertEqual(report["status"], "pass")

            args = _finalizer_args(tmp_path, paths, provenance_path)
            _final_bundle, _frontier_report, summary = finalizer.build_final_bundle(args)
            self.assertEqual(summary["status"], "pass")

            summary["summary"]["releaseBundleIdentitySha256"] = "0" * 64
            failures = finalizer_check.check_report(
                summary,
                verify_files_root=tmp_path,
                require_pass=True,
            )

            self.assertTrue(
                any(
                    item["code"] == "finalizer_summary_release_identity_mismatch"
                    for item in failures
                ),
                failures,
            )

    def test_checker_requires_pass_when_requested(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            paths = _release_bundle_inputs(tmp_path, release_status="release_candidate")
            provenance_path, report = _write_provenance_report(tmp_path, paths)
            report["status"] = "fail"
            report["failures"] = [
                {
                    "code": "release_archive_manifest_product_mismatch",
                    "path": "releaseArchiveManifest.browserProduct",
                    "message": "fixture drift",
                }
            ]
            _write_json(provenance_path, report)

            args = _finalizer_args(tmp_path, paths, provenance_path)
            _final_bundle, _frontier_report, summary = finalizer.build_final_bundle(args)
            self.assertEqual(summary["status"], "fail")

            failures = finalizer_check.check_report(summary, require_pass=True)

            self.assertTrue(
                any(item["code"] == "finalizer_report_not_pass" for item in failures),
                failures,
            )

    def test_checker_cli_writes_report(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            finalizer_report = tmp_path / "browser-release-candidate-finalizer.json"
            check_report = tmp_path / "browser-release-candidate-finalizer-check.json"
            _write_json(
                finalizer_report,
                {
                    "schemaVersion": 1,
                    "artifactKind": "browser_release_candidate_finalizer",
                    "status": "fail",
                    "phase": "provenance_preflight",
                    "failures": [
                        {
                            "code": "provenance_report_not_pass",
                            "path": "provenanceReport.status",
                            "message": "release-candidate provenance report must pass",
                        }
                    ],
                },
            )

            old_argv = sys.argv
            try:
                sys.argv = [
                    "check_browser_release_candidate_finalizer.py",
                    "--report",
                    str(finalizer_report),
                    "--out",
                    str(check_report),
                ]
                self.assertEqual(finalizer_check.main(), 0)
            finally:
                sys.argv = old_argv

            payload = json.loads(check_report.read_text(encoding="utf-8"))
            jsonschema.validate(
                payload,
                json.loads(CHECK_SCHEMA.read_text(encoding="utf-8")),
            )
            self.assertEqual(payload["artifactKind"], "browser_release_candidate_finalizer_check")
            self.assertEqual(payload["status"], "pass")
            self.assertEqual(payload["finalizerStatus"], "fail")
            self.assertEqual(payload["finalizerReportPath"], str(finalizer_report))
            self.assertEqual(
                payload["finalizerReportSha256"],
                bundle_builder.sha256_file(finalizer_report),
            )
            self.assertFalse(payload["verifyFilesRootProvided"])
            self.assertFalse(payload["requirePass"])

    def test_checker_rejects_malformed_failed_report_failures(self) -> None:
        failures = finalizer_check.check_report(
            {
                "schemaVersion": 1,
                "artifactKind": "browser_release_candidate_finalizer",
                "status": "fail",
                "phase": "provenance_preflight",
                "failures": [
                    {"code": "Bad-Code", "path": "", "message": ""},
                    "not-an-object",
                ],
            }
        )

        self.assertTrue(
            any(item["code"] == "invalid_finalizer_failure" for item in failures),
            failures,
        )

    def test_checker_rejects_failed_report_outputs(self) -> None:
        failures = finalizer_check.check_report(
            {
                "schemaVersion": 1,
                "artifactKind": "browser_release_candidate_finalizer",
                "status": "fail",
                "phase": "provenance_preflight",
                "outputs": {},
                "failures": [
                    {
                        "code": "provenance_report_not_pass",
                        "path": "provenanceReport.status",
                        "message": "release-candidate provenance report must pass",
                    }
                ],
            }
        )

        self.assertTrue(
            any(item["code"] == "failed_finalizer_has_outputs" for item in failures),
            failures,
        )

    def test_checker_rejects_passing_report_with_failure_fields(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            paths = _release_bundle_inputs(tmp_path, release_status="release_candidate")
            provenance_path, report = _write_provenance_report(tmp_path, paths)
            self.assertEqual(report["status"], "pass")

            args = _finalizer_args(tmp_path, paths, provenance_path)
            _final_bundle, _frontier_report, summary = finalizer.build_final_bundle(args)
            self.assertEqual(summary["status"], "pass")

            summary["phase"] = "release_bundle_verification"
            summary["failures"] = [
                {
                    "code": "release_bundle_verification_failed",
                    "path": "outputs.releaseArtifactBundle",
                    "message": "fixture drift",
                }
            ]

            failures = finalizer_check.check_report(
                summary,
                verify_files_root=tmp_path,
                require_pass=True,
            )

            self.assertTrue(
                any(item["code"] == "pass_finalizer_has_phase" for item in failures),
                failures,
            )
            self.assertTrue(
                any(item["code"] == "pass_finalizer_has_failures" for item in failures),
                failures,
            )

    def test_checker_rejects_passing_report_without_package_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            paths = _release_bundle_inputs(tmp_path, release_status="release_candidate")
            provenance_path, report = _write_provenance_report(tmp_path, paths)
            self.assertEqual(report["status"], "pass")

            args = _finalizer_args(tmp_path, paths, provenance_path)
            _final_bundle, _frontier_report, summary = finalizer.build_final_bundle(args)
            self.assertEqual(summary["status"], "pass")
            jsonschema.validate(summary, json.loads(SCHEMA.read_text(encoding="utf-8")))

            del summary["inputs"]
            failures = finalizer_check.check_report(
                summary,
                verify_files_root=tmp_path,
                require_pass=True,
            )

            self.assertTrue(
                any(item["code"] == "missing_finalizer_inputs" for item in failures),
                failures,
            )
            with self.assertRaises(jsonschema.ValidationError):
                jsonschema.validate(summary, json.loads(SCHEMA.read_text(encoding="utf-8")))

    def test_checker_rejects_passing_report_without_provenance_input(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            paths = _release_bundle_inputs(tmp_path, release_status="release_candidate")
            provenance_path, report = _write_provenance_report(tmp_path, paths)
            self.assertEqual(report["status"], "pass")

            args = _finalizer_args(tmp_path, paths, provenance_path)
            _final_bundle, _frontier_report, summary = finalizer.build_final_bundle(args)
            self.assertEqual(summary["status"], "pass")
            jsonschema.validate(summary, json.loads(SCHEMA.read_text(encoding="utf-8")))

            del summary["inputs"]["provenanceReport"]
            failures = finalizer_check.check_report(
                summary,
                verify_files_root=tmp_path,
                require_pass=True,
            )

            self.assertTrue(
                any(item["code"] == "missing_finalizer_provenance_report" for item in failures),
                failures,
            )
            with self.assertRaises(jsonschema.ValidationError):
                jsonschema.validate(summary, json.loads(SCHEMA.read_text(encoding="utf-8")))

    def test_checker_rejects_provenance_input_component_drift(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            paths = _release_bundle_inputs(tmp_path, release_status="release_candidate")
            provenance_path, report = _write_provenance_report(tmp_path, paths)
            self.assertEqual(report["status"], "pass")

            args = _finalizer_args(tmp_path, paths, provenance_path)
            _final_bundle, _frontier_report, summary = finalizer.build_final_bundle(args)
            self.assertEqual(summary["status"], "pass")
            provenance_payload = json.loads(provenance_path.read_text(encoding="utf-8"))
            provenance_payload["componentArtifacts"]["packageInputs"]["sha256"] = "0" * 64
            _write_json(provenance_path, provenance_payload)
            summary["inputs"]["provenanceReport"]["sha256"] = bundle_builder.sha256_file(
                provenance_path
            )

            failures = finalizer_check.check_report(
                summary,
                verify_files_root=tmp_path,
                require_pass=True,
            )

            self.assertTrue(
                any(
                    item["code"] == "provenance_report_component_mismatch"
                    and item["path"]
                    == "inputs.provenanceReport.componentArtifacts.packageInputs"
                    for item in failures
                ),
                failures,
            )

    def test_checker_rejects_dirty_package_inputs_binding(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            paths = _release_bundle_inputs(tmp_path, release_status="release_candidate")
            provenance_path, report = _write_provenance_report(tmp_path, paths)
            self.assertEqual(report["status"], "pass")

            args = _finalizer_args(tmp_path, paths, provenance_path)
            _final_bundle, _frontier_report, summary = finalizer.build_final_bundle(args)
            self.assertEqual(summary["status"], "pass")
            package_inputs_path = tmp_path / summary["inputs"]["packageInputs"]["path"]
            package_report = json.loads(package_inputs_path.read_text(encoding="utf-8"))
            package_report["failures"] = [
                {
                    "code": "stale_failure",
                    "path": "status",
                    "message": "stale failure",
                }
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
            summary["inputs"]["packageInputs"]["sha256"] = bundle_builder.sha256_file(
                package_inputs_path
            )

            failures = finalizer_check.check_report(
                summary,
                verify_files_root=tmp_path,
                require_pass=True,
            )

            self.assertTrue(
                any(
                    item["code"] == "package_inputs_release_candidate_blockers_present"
                    for item in failures
                ),
                failures,
            )
            self.assertTrue(
                any(item["code"] == "package_inputs_failures_present" for item in failures),
                failures,
            )
            self.assertTrue(
                any(
                    item["code"] == "package_inputs_summary_not_packageable"
                    for item in failures
                ),
                failures,
            )

    def test_checker_rejects_stale_package_input_binary_identity(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            paths = _release_bundle_inputs(tmp_path, release_status="release_candidate")
            package_inputs_path = paths["package_inputs"]
            package_report = json.loads(package_inputs_path.read_text(encoding="utf-8"))
            release_payload = {
                "browserProduct": package_report["browserProduct"],
                "platform": package_report["platform"],
                "browserExecutableArchivePath": DEFAULT_BROWSER_ARCHIVE_PATH,
                "browserAppMetadataArchivePath": DEFAULT_APP_METADATA_ARCHIVE_PATH,
                "doeRuntimeArchivePath": DEFAULT_DOE_RUNTIME_ARCHIVE_PATH,
                "dawnFallbackRuntimeArchivePath": DEFAULT_DAWN_RUNTIME_ARCHIVE_PATH,
                "browserBinary": {
                    "path": package_report["inputs"]["browserExecutable"]["path"],
                    "sha256": package_report["inputs"]["browserExecutable"]["sha256"],
                },
                "doeRuntime": {
                    "path": package_report["inputs"]["doeRuntime"]["path"],
                    "sha256": package_report["inputs"]["doeRuntime"]["sha256"],
                },
                "dawnFallbackRuntime": {
                    "path": package_report["inputs"]["dawnFallbackRuntime"]["path"],
                    "sha256": package_report["inputs"]["dawnFallbackRuntime"]["sha256"],
                },
                "shaderCompiler": {
                    "path": package_report["inputs"]["shaderCompiler"]["path"],
                    "sha256": package_report["inputs"]["shaderCompiler"]["sha256"],
                },
            }
            for role in ("browserExecutable", "doeRuntime", "dawnFallbackRuntime", "shaderCompiler"):
                package_report["inputs"][role].pop("detectedFormat", None)
                package_report["inputs"][role].pop("detectedArchitectures", None)

            failures = finalizer_check.check_package_inputs_binding(
                package_report,
                release_payload,
                tmp_path,
            )
            failure_codes = [item["code"] for item in failures]

            self.assertEqual(
                failure_codes.count("package_inputs_macos_binary_format_mismatch"),
                4,
            )
            self.assertEqual(
                failure_codes.count("package_inputs_macos_binary_arch_mismatch"),
                4,
            )
            self.assertIn(
                {
                    "code": "package_inputs_macos_binary_format_mismatch",
                    "path": "inputs.packageInputs.inputs.browserExecutable.detectedFormat",
                    "message": (
                        "release-candidate package inputs browserExecutable "
                        "must be Mach-O for macOS"
                    ),
                },
                failures,
            )
            self.assertIn(
                {
                    "code": "package_inputs_macos_binary_format_mismatch",
                    "path": "inputs.packageInputs.inputs.shaderCompiler.detectedFormat",
                    "message": (
                        "release-candidate package inputs shaderCompiler "
                        "must be Mach-O for macOS"
                    ),
                },
                failures,
            )

    def test_checker_report_schema_requires_failures_on_fail(self) -> None:
        schema = json.loads(CHECK_SCHEMA.read_text(encoding="utf-8"))
        payload = {
            "schemaVersion": 1,
            "artifactKind": "browser_release_candidate_finalizer_check",
            "status": "fail",
            "finalizerStatus": "fail",
            "finalizerReportPath": "examples/browser-release-candidate-finalizer.sample.json",
            "finalizerReportSha256": "a6b1602c767ab71167ab162cc5678f1f2ae4a15a0dcb8ba9458f372e87336fc2",
            "verifyFilesRootProvided": False,
            "requirePass": True,
            "failures": [
                {
                    "code": "finalizer_report_not_pass",
                    "path": "status",
                    "message": "browser release-candidate finalizer report must pass",
                }
            ],
        }
        jsonschema.validate(payload, schema)

        payload["failures"] = []
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(payload, schema)


if __name__ == "__main__":
    unittest.main()
