#!/usr/bin/env python3
"""Tests for browser release package input preflight reports."""

from __future__ import annotations

import hashlib
import json
import plistlib
import stat
import struct
import unittest
from pathlib import Path

import jsonschema

from bench.tools import check_browser_release_package_inputs as package_inputs


REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA = REPO_ROOT / "config" / "browser-release-package-inputs-check.schema.json"


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _write_file(path: Path, payload: bytes, mode: int = 0o644) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)
    path.chmod(mode)
    return path


def _validate(payload: dict) -> None:
    jsonschema.validate(payload, json.loads(SCHEMA.read_text(encoding="utf-8")))


def _macos_plist(*, display_name: str = "Fawn Doe", version: str = "0.0.0-sample") -> dict:
    return {
        "CFBundleName": display_name,
        "CFBundleDisplayName": display_name,
        "CFBundleIdentifier": "dev.doe.fawn-doe",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": version,
        "CFBundleExecutable": "Chromium",
        "CFBundlePackageType": "APPL",
    }


def _macho_payload(arch: str = "arm64") -> bytes:
    cpu_type = {
        "arm64": 0x0100000C,
        "x64": 0x01000007,
    }[arch]
    return struct.pack("<IiiIIIII", 0xFEEDFACF, cpu_type, 0, 2, 0, 0, 0, 0)


def _elf_x64_payload() -> bytes:
    payload = bytearray(64)
    payload[:6] = b"\x7fELF\x02\x01"
    payload[18:20] = struct.pack("<H", 0x3E)
    return bytes(payload)


def _write_canonical_args_gn(path: Path) -> Path:
    return _write_file(
        path,
        b"\n".join(
            [
                b"is_debug = false",
                b"is_official_build = true",
                b"dcheck_always_on = false",
                b"chrome_pgo_phase = 0",
                b"symbol_level = 0",
                b"blink_symbol_level = 0",
                b"v8_symbol_level = 0",
                b"is_chrome_for_testing = false",
                b"is_chrome_for_testing_branded = false",
                b"is_chrome_branded = false",
                b"use_clang_modules = false",
                b"dawn_enable_webgpu_on_webgpu = true",
                b"",
            ]
        ),
    )


def _write_linux_inputs(root: Path) -> dict[str, Path]:
    package_dir = root / "fawn-linux"
    return {
        "package_dir": package_dir,
        "browser": _write_file(package_dir / "chrome-wrapper", b"browser\n", 0o755),
        "doe_runtime": _write_file(root / "libwebgpu_doe.so", b"doe runtime\n"),
        "dawn_runtime": _write_file(root / "libdawn_native.so", b"dawn runtime\n"),
        "compiler": _write_file(root / "doe-zig-runtime", b"compiler\n", 0o755),
    }


def _write_linux_candidate_inputs(root: Path) -> dict[str, Path]:
    package_dir = root / "fawn-linux"
    _write_canonical_args_gn(root / "args.gn")
    policy = package_inputs.load_release_platform_policy()
    linux = next(row for row in policy["releasePlatforms"] if row["os"] == "linux")
    for member in linux["requiredPackageMembers"]:
        mode = 0o755 if member["executable"] else 0o644
        _write_file(package_dir / member["path"], b"support\n", mode)
    return {
        "package_dir": package_dir,
        "browser": _write_file(
            package_dir / "chrome-wrapper",
            _elf_x64_payload(),
            0o755,
        ),
        "doe_runtime": _write_file(
            root / "libwebgpu_doe.so",
            _elf_x64_payload(),
            0o755,
        ),
        "dawn_runtime": _write_file(
            root / "libdawn_native.so",
            _elf_x64_payload(),
            0o755,
        ),
        "compiler": _write_file(
            root / "doe-zig-runtime",
            _elf_x64_payload(),
            0o755,
        ),
    }


def _write_macos_candidate_inputs(root: Path) -> dict[str, Path]:
    app_dir = root / "Fawn.app"
    _write_canonical_args_gn(root / "args.gn")
    browser = app_dir / "Contents" / "MacOS" / "Chromium"
    _write_file(browser, _macho_payload(), 0o755)
    plist_path = app_dir / "Contents" / "Info.plist"
    plist_path.parent.mkdir(parents=True, exist_ok=True)
    with plist_path.open("wb") as handle:
        plistlib.dump(_macos_plist(), handle)
    return {
        "package_dir": app_dir,
        "browser": browser,
        "plist": plist_path,
        "doe_runtime": _write_file(root / "libwebgpu_doe.so", _macho_payload(), 0o755),
        "dawn_runtime": _write_file(root / "libdawn_native.so", _macho_payload(), 0o755),
        "compiler": _write_file(root / "doe-zig-runtime", _macho_payload(), 0o755),
    }


class BrowserReleasePackageInputsTests(unittest.TestCase):
    def test_linux_release_candidate_is_eligible_with_complete_support(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            paths = _write_linux_candidate_inputs(root)

            report = package_inputs.build_report(
                package_dir=str(paths["package_dir"]),
                package_root_name="Fawn-Doe-linux-x64",
                doe_runtime=str(paths["doe_runtime"]),
                dawn_fallback_runtime=str(paths["dawn_runtime"]),
                shader_compiler=str(paths["compiler"]),
                product_channel="release_candidate",
                platform_os="linux",
                platform_arch="x64",
                root=root,
            )

            _validate(report)
            self.assertEqual(report["status"], "pass")
            self.assertTrue(report["releaseCandidateEligible"])
            self.assertEqual(report["releaseCandidateBlockers"], [])
            self.assertEqual(report["evidenceMode"], "release_candidate")

    def test_linux_release_candidate_reports_missing_launch_support(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            paths = _write_linux_candidate_inputs(root)
            (paths["package_dir"] / "icudtl.dat").unlink()

            report = package_inputs.build_report(
                package_dir=str(paths["package_dir"]),
                package_root_name="Fawn-Doe-linux-x64",
                doe_runtime=str(paths["doe_runtime"]),
                dawn_fallback_runtime=str(paths["dawn_runtime"]),
                shader_compiler=str(paths["compiler"]),
                product_channel="release_candidate",
                platform_os="linux",
                platform_arch="x64",
                root=root,
            )

            _validate(report)
            self.assertEqual(report["status"], "pass")
            self.assertFalse(report["releaseCandidateEligible"])
            self.assertIn(
                {
                    "code": "browser_release_support_member_missing",
                    "path": "packageDir/icudtl.dat",
                    "message": "release package must include icudtl.dat",
                },
                report["releaseCandidateBlockers"],
            )

    def test_linux_report_passes_with_generated_metadata(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            package_dir = root / "fawn-linux"
            browser = _write_file(package_dir / "chrome-wrapper", b"browser\n", 0o755)
            _write_file(package_dir / "libdawn_native.so", b"stale dawn\n", 0o755)
            doe_runtime = _write_file(root / "libwebgpu_doe.so", b"doe runtime\n", 0o755)
            dawn_runtime = _write_file(root / "libdawn_native.so", b"dawn runtime\n", 0o755)
            compiler = _write_file(root / "doe-zig-runtime", _macho_payload(), 0o755)

            report = package_inputs.build_report(
                package_dir=str(package_dir),
                package_root_name="Fawn-Doe-linux-x64",
                doe_runtime=str(doe_runtime),
                dawn_fallback_runtime=str(dawn_runtime),
                shader_compiler=str(compiler),
                root=root,
            )

            _validate(report)
            self.assertEqual(report["status"], "pass")
            self.assertEqual(report["evidenceMode"], "diagnostic")
            self.assertFalse(report["releaseCandidateEligible"])
            self.assertEqual(report["summary"]["metadataSource"], "generated")
            self.assertEqual(
                report["inputs"]["browserExecutable"]["sha256"],
                _sha256(b"browser\n"),
            )
            self.assertEqual(report["inputs"]["browserExecutable"]["detectedFormat"], "unknown")
            self.assertEqual(
                report["inputs"]["browserExecutable"]["archivePath"],
                "Fawn-Doe-linux-x64/chrome-wrapper",
            )
            self.assertEqual(
                report["inputs"]["appMetadata"]["archivePath"],
                "Fawn-Doe-linux-x64/browser-product.json",
            )
            self.assertTrue(report["inputs"]["appMetadata"]["generated"])
            self.assertEqual(report["inputs"]["appMetadata"]["detectedFormat"], "json")
            self.assertEqual(
                report["inputs"]["doeRuntime"]["sha256"],
                _sha256(b"doe runtime\n"),
            )
            self.assertEqual(
                report["inputs"]["dawnFallbackRuntime"]["sha256"],
                _sha256(b"dawn runtime\n"),
            )
            self.assertEqual(len(report["overwrittenPackageMembers"]), 1)
            self.assertFalse(report["overwrittenPackageMembers"][0]["matchesInput"])
            self.assertEqual(report["overwrittenPackageMembers"][0]["role"], "dawnFallbackRuntime")
            self.assertEqual(browser.stat().st_mode & stat.S_IXUSR, stat.S_IXUSR)

    def test_macos_release_candidate_inputs_are_eligible(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            app_dir = root / "Fawn.app"
            _write_canonical_args_gn(root / "args.gn")
            browser = app_dir / "Contents" / "MacOS" / "Chromium"
            _write_file(browser, _macho_payload(), 0o755)
            plist_path = app_dir / "Contents" / "Info.plist"
            plist_path.parent.mkdir(parents=True, exist_ok=True)
            with plist_path.open("wb") as handle:
                plistlib.dump(_macos_plist(), handle)
            doe_runtime = _write_file(root / "libwebgpu_doe.so", _macho_payload(), 0o755)
            dawn_runtime = _write_file(root / "libdawn_native.so", _macho_payload(), 0o755)
            compiler = _write_file(root / "doe-zig-runtime", _macho_payload(), 0o755)

            report = package_inputs.build_report(
                package_dir=str(app_dir),
                package_root_name="Fawn.app",
                doe_runtime=str(doe_runtime),
                dawn_fallback_runtime=str(dawn_runtime),
                shader_compiler=str(compiler),
                product_channel="release_candidate",
                platform_os="macos",
                platform_arch="arm64",
                root=root,
            )

            _validate(report)
            self.assertEqual(report["status"], "pass")
            self.assertEqual(report["evidenceMode"], "release_candidate")
            self.assertTrue(report["releaseCandidateEligible"])
            self.assertEqual(report["releaseCandidateBlockers"], [])
            self.assertTrue(report["buildProfile"]["releaseProfileMatched"])
            self.assertEqual(report["summary"]["metadataSource"], "package")
            self.assertEqual(
                report["inputs"]["appMetadata"]["archivePath"],
                "Fawn.app/Contents/Info.plist",
            )
            self.assertEqual(report["inputs"]["browserExecutable"]["detectedFormat"], "macho")
            self.assertEqual(report["inputs"]["browserExecutable"]["detectedArchitectures"], ["arm64"])

    def test_macos_release_candidate_requires_build_profile(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            app_dir = root / "Fawn.app"
            browser = app_dir / "Contents" / "MacOS" / "Chromium"
            _write_file(browser, _macho_payload(), 0o755)
            plist_path = app_dir / "Contents" / "Info.plist"
            plist_path.parent.mkdir(parents=True, exist_ok=True)
            with plist_path.open("wb") as handle:
                plistlib.dump(_macos_plist(), handle)
            doe_runtime = _write_file(root / "libwebgpu_doe.so", _macho_payload(), 0o755)
            dawn_runtime = _write_file(root / "libdawn_native.so", _macho_payload(), 0o755)
            compiler = _write_file(root / "doe-zig-runtime", _macho_payload(), 0o755)

            report = package_inputs.build_report(
                package_dir=str(app_dir),
                package_root_name="Fawn.app",
                doe_runtime=str(doe_runtime),
                dawn_fallback_runtime=str(dawn_runtime),
                shader_compiler=str(compiler),
                product_channel="release_candidate",
                platform_os="macos",
                platform_arch="arm64",
                root=root,
            )

            _validate(report)
            self.assertEqual(report["status"], "pass")
            self.assertFalse(report["buildProfile"]["available"])
            self.assertFalse(report["releaseCandidateEligible"])
            self.assertIn(
                {
                    "code": "browser_release_build_profile_missing",
                    "path": "buildProfile.argsGn.path",
                    "message": (
                        "release-candidate browser inputs must include args.gn "
                        "build profile evidence"
                    ),
                },
                report["releaseCandidateBlockers"],
            )

    def test_macos_release_candidate_rejects_weak_build_profile(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            paths = _write_macos_candidate_inputs(root)
            (root / "args.gn").write_text(
                "\n".join(
                    [
                        "is_debug = false",
                        "is_official_build = false",
                        "dcheck_always_on = true",
                        "chrome_pgo_phase = 0",
                        "symbol_level = 0",
                        "blink_symbol_level = 0",
                        "v8_symbol_level = 0",
        "is_chrome_for_testing = false",
        "is_chrome_for_testing_branded = false",
        "is_chrome_branded = false",
        "use_clang_modules = false",
        "dawn_enable_webgpu_on_webgpu = true",
        "",
    ]
                ),
                encoding="utf-8",
            )

            report = package_inputs.build_report(
                package_dir=str(paths["package_dir"]),
                package_root_name="Fawn.app",
                doe_runtime=str(paths["doe_runtime"]),
                dawn_fallback_runtime=str(paths["dawn_runtime"]),
                shader_compiler=str(paths["compiler"]),
                product_channel="release_candidate",
                platform_os="macos",
                platform_arch="arm64",
                root=root,
            )

            _validate(report)
            self.assertEqual(report["status"], "pass")
            self.assertFalse(report["buildProfile"]["releaseProfileMatched"])
            self.assertFalse(report["releaseCandidateEligible"])
            blockers = {
                (row["code"], row["path"])
                for row in report["releaseCandidateBlockers"]
            }
            self.assertIn(
                (
                    "browser_release_build_profile_mismatch",
                    "buildProfile.args.is_official_build",
                ),
                blockers,
            )
            self.assertIn(
                (
                    "browser_release_build_profile_mismatch",
                    "buildProfile.args.dcheck_always_on",
                ),
                blockers,
            )

    def test_schema_rejects_inconsistent_release_candidate_eligibility(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            paths = _write_macos_candidate_inputs(root)

            report = package_inputs.build_report(
                package_dir=str(paths["package_dir"]),
                package_root_name="Fawn.app",
                doe_runtime=str(paths["doe_runtime"]),
                dawn_fallback_runtime=str(paths["dawn_runtime"]),
                shader_compiler=str(paths["compiler"]),
                product_channel="release_candidate",
                platform_os="macos",
                platform_arch="arm64",
                root=root,
            )

            _validate(report)

            mutations = [
                ("status", "fail"),
                ("evidenceMode", "diagnostic"),
                ("releaseCandidateBlockers", [{"code": "x", "path": "x", "message": "x"}]),
                ("failures", [{"code": "x", "path": "x", "message": "x"}]),
            ]
            for field, value in mutations:
                mutated = json.loads(json.dumps(report))
                mutated[field] = value
                with self.assertRaises(jsonschema.ValidationError, msg=field):
                    _validate(mutated)

            mutated = json.loads(json.dumps(report))
            mutated["platform"]["os"] = "linux"
            with self.assertRaises(jsonschema.ValidationError):
                _validate(mutated)

            mutated = json.loads(json.dumps(report))
            mutated["inputs"]["browserExecutable"]["detectedArchitectures"] = ["x64"]
            with self.assertRaises(jsonschema.ValidationError):
                _validate(mutated)

            mutated = json.loads(json.dumps(report))
            mutated["inputs"]["appMetadata"]["detectedFormat"] = "json"
            with self.assertRaises(jsonschema.ValidationError):
                _validate(mutated)

    def test_macos_release_candidate_rejects_non_macho_inputs(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            app_dir = root / "Fawn.app"
            browser = app_dir / "Contents" / "MacOS" / "Chromium"
            _write_file(browser, b"#!/bin/sh\n", 0o755)
            plist_path = app_dir / "Contents" / "Info.plist"
            plist_path.parent.mkdir(parents=True, exist_ok=True)
            with plist_path.open("wb") as handle:
                plistlib.dump(_macos_plist(), handle)
            doe_runtime = _write_file(root / "libwebgpu_doe.so", b"\x7fELF\x02\x01" + b"\0" * 12 + b"\xb7\0", 0o755)
            dawn_runtime = _write_file(root / "libdawn_native.so", _macho_payload("x64"), 0o755)
            compiler = _write_file(root / "doe-zig-runtime", b"compiler\n", 0o755)

            report = package_inputs.build_report(
                package_dir=str(app_dir),
                package_root_name="Fawn.app",
                doe_runtime=str(doe_runtime),
                dawn_fallback_runtime=str(dawn_runtime),
                shader_compiler=str(compiler),
                product_channel="release_candidate",
                platform_os="macos",
                platform_arch="arm64",
                root=root,
            )

            _validate(report)
            self.assertEqual(report["status"], "fail")
            self.assertFalse(report["releaseCandidateEligible"])
            codes = {row["code"] for row in report["failures"]}
            self.assertIn("macos_binary_format_mismatch", codes)
            self.assertIn("macos_binary_arch_mismatch", codes)

    def test_macos_release_candidate_rejects_metadata_identity_drift(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            app_dir = root / "Fawn.app"
            browser = app_dir / "Contents" / "MacOS" / "Chromium"
            _write_file(browser, _macho_payload(), 0o755)
            plist_path = app_dir / "Contents" / "Info.plist"
            plist_path.parent.mkdir(parents=True, exist_ok=True)
            with plist_path.open("wb") as handle:
                plistlib.dump(_macos_plist(display_name="Other Browser"), handle)
            doe_runtime = _write_file(root / "libwebgpu_doe.so", _macho_payload(), 0o755)
            dawn_runtime = _write_file(root / "libdawn_native.so", _macho_payload(), 0o755)
            compiler = _write_file(root / "doe-zig-runtime", b"compiler\n", 0o755)

            report = package_inputs.build_report(
                package_dir=str(app_dir),
                package_root_name="Fawn.app",
                doe_runtime=str(doe_runtime),
                dawn_fallback_runtime=str(dawn_runtime),
                shader_compiler=str(compiler),
                product_channel="release_candidate",
                platform_os="macos",
                platform_arch="arm64",
                root=root,
            )

            _validate(report)
            self.assertEqual(report["status"], "fail")
            self.assertFalse(report["releaseCandidateEligible"])
            self.assertIn(
                {
                    "code": "macos_app_metadata_product_mismatch",
                    "path": "inputs.appMetadata.CFBundleName",
                    "message": "app metadata CFBundleName must match browserProduct.displayName",
                },
                report["failures"],
            )

    def test_macos_release_candidate_rejects_package_root_drift(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            app_dir = root / "Fawn.app"
            browser = app_dir / "Contents" / "MacOS" / "Chromium"
            _write_file(browser, _macho_payload(), 0o755)
            plist_path = app_dir / "Contents" / "Info.plist"
            plist_path.parent.mkdir(parents=True, exist_ok=True)
            with plist_path.open("wb") as handle:
                plistlib.dump(_macos_plist(), handle)
            doe_runtime = _write_file(root / "libwebgpu_doe.so", _macho_payload(), 0o755)
            dawn_runtime = _write_file(root / "libdawn_native.so", _macho_payload(), 0o755)
            compiler = _write_file(root / "doe-zig-runtime", b"compiler\n", 0o755)

            report = package_inputs.build_report(
                package_dir=str(app_dir),
                package_root_name="Fawn-Doe-macos-arm64",
                doe_runtime=str(doe_runtime),
                dawn_fallback_runtime=str(dawn_runtime),
                shader_compiler=str(compiler),
                product_channel="release_candidate",
                platform_os="macos",
                platform_arch="arm64",
                root=root,
            )

            _validate(report)
            self.assertEqual(report["status"], "fail")
            self.assertIn(
                {
                    "code": "invalid_macos_package_root_name",
                    "path": "packageRootName",
                    "message": "macOS packageRootName must name a .app bundle",
                },
                report["failures"],
            )
            self.assertIn(
                {
                    "code": "macos_package_root_name_mismatch",
                    "path": "packageRootName",
                    "message": "macOS packageRootName must match package-dir bundle name",
                },
                report["failures"],
            )

    def test_non_executable_browser_and_compiler_fail(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            package_dir = root / "fawn-linux"
            _write_file(package_dir / "chrome-wrapper", b"browser\n", 0o644)
            doe_runtime = _write_file(root / "libwebgpu_doe.so", b"doe runtime\n")
            dawn_runtime = _write_file(root / "libdawn_native.so", b"dawn runtime\n")
            compiler = _write_file(root / "doe-zig-runtime", b"compiler\n", 0o644)

            report = package_inputs.build_report(
                package_dir=str(package_dir),
                package_root_name="Fawn-Doe-linux-x64",
                doe_runtime=str(doe_runtime),
                dawn_fallback_runtime=str(dawn_runtime),
                shader_compiler=str(compiler),
                root=root,
            )

            _validate(report)
            self.assertEqual(report["status"], "fail")
            codes = {row["code"] for row in report["failures"]}
            self.assertEqual(codes, {"non_executable_input_file"})

    def test_rejects_unsafe_explicit_doe_runtime_archive_path(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            package_dir = root / "fawn-linux"
            _write_file(package_dir / "chrome-wrapper", b"browser\n", 0o755)
            doe_runtime = _write_file(root / "libwebgpu_doe.so", b"doe runtime\n", 0o755)
            dawn_runtime = _write_file(root / "libdawn_native.so", b"dawn runtime\n", 0o755)
            compiler = _write_file(root / "doe-zig-runtime", b"compiler\n", 0o755)

            report = package_inputs.build_report(
                package_dir=str(package_dir),
                package_root_name="Fawn-Doe-linux-x64",
                doe_runtime=str(doe_runtime),
                dawn_fallback_runtime=str(dawn_runtime),
                shader_compiler=str(compiler),
                doe_runtime_archive_path="Fawn-Doe-linux-x64/./libwebgpu_doe.so",
                root=root,
            )

            _validate(report)
            self.assertEqual(report["status"], "fail")
            self.assertIn(
                {
                    "code": "invalid_archive_member_path",
                    "path": "inputs.doeRuntime.archivePath",
                    "message": (
                        "archive member path must be relative and normalized: "
                        "Fawn-Doe-linux-x64/./libwebgpu_doe.so"
                    ),
                },
                report["failures"],
            )

    def test_rejects_unsafe_browser_executable_package_path(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            package_dir = root / "fawn-linux"
            _write_file(package_dir / "chrome-wrapper", b"browser\n", 0o755)
            doe_runtime = _write_file(root / "libwebgpu_doe.so", b"doe runtime\n", 0o755)
            dawn_runtime = _write_file(root / "libdawn_native.so", b"dawn runtime\n", 0o755)
            compiler = _write_file(root / "doe-zig-runtime", b"compiler\n", 0o755)

            report = package_inputs.build_report(
                package_dir=str(package_dir),
                package_root_name="Fawn-Doe-linux-x64",
                browser_executable_package_path="./chrome-wrapper",
                doe_runtime=str(doe_runtime),
                dawn_fallback_runtime=str(dawn_runtime),
                shader_compiler=str(compiler),
                root=root,
            )

            _validate(report)
            self.assertEqual(report["status"], "fail")
            self.assertIn(
                {
                    "code": "invalid_archive_member_path",
                    "path": "inputs.browserExecutable.archivePath",
                    "message": (
                        "archive member path must be relative and normalized: "
                        "Fawn-Doe-linux-x64/./chrome-wrapper"
                    ),
                },
                report["failures"],
            )

    def test_rejects_unsafe_app_metadata_package_path(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            package_dir = root / "fawn-linux"
            _write_file(package_dir / "chrome-wrapper", b"browser\n", 0o755)
            doe_runtime = _write_file(root / "libwebgpu_doe.so", b"doe runtime\n", 0o755)
            dawn_runtime = _write_file(root / "libdawn_native.so", b"dawn runtime\n", 0o755)
            compiler = _write_file(root / "doe-zig-runtime", b"compiler\n", 0o755)

            report = package_inputs.build_report(
                package_dir=str(package_dir),
                package_root_name="Fawn-Doe-linux-x64",
                browser_app_metadata_package_path="./browser-product.json",
                doe_runtime=str(doe_runtime),
                dawn_fallback_runtime=str(dawn_runtime),
                shader_compiler=str(compiler),
                root=root,
            )

            _validate(report)
            self.assertEqual(report["status"], "fail")
            self.assertIn(
                {
                    "code": "invalid_archive_member_path",
                    "path": "inputs.appMetadata.archivePath",
                    "message": (
                        "archive member path must be relative and normalized: "
                        "Fawn-Doe-linux-x64/./browser-product.json"
                    ),
                },
                report["failures"],
            )

    def test_rejects_unsafe_explicit_dawn_runtime_archive_path(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            package_dir = root / "fawn-linux"
            _write_file(package_dir / "chrome-wrapper", b"browser\n", 0o755)
            doe_runtime = _write_file(root / "libwebgpu_doe.so", b"doe runtime\n", 0o755)
            dawn_runtime = _write_file(root / "libdawn_native.so", b"dawn runtime\n", 0o755)
            compiler = _write_file(root / "doe-zig-runtime", b"compiler\n", 0o755)

            report = package_inputs.build_report(
                package_dir=str(package_dir),
                package_root_name="Fawn-Doe-linux-x64",
                doe_runtime=str(doe_runtime),
                dawn_fallback_runtime=str(dawn_runtime),
                shader_compiler=str(compiler),
                dawn_fallback_runtime_archive_path="Fawn-Doe-linux-x64//libdawn_native.so",
                root=root,
            )

            _validate(report)
            self.assertEqual(report["status"], "fail")
            self.assertIn(
                {
                    "code": "invalid_archive_member_path",
                    "path": "inputs.dawnFallbackRuntime.archivePath",
                    "message": (
                        "archive member path must be relative and normalized: "
                        "Fawn-Doe-linux-x64//libdawn_native.so"
                    ),
                },
                report["failures"],
            )

    def test_product_identity_mismatch_fails(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            package_dir = root / "fawn-linux"
            _write_file(package_dir / "chrome-wrapper", b"browser\n", 0o755)
            doe_runtime = _write_file(root / "libwebgpu_doe.so", b"doe runtime\n")
            dawn_runtime = _write_file(root / "libdawn_native.so", b"dawn runtime\n")
            compiler = _write_file(root / "doe-zig-runtime", b"compiler\n", 0o755)

            report = package_inputs.build_report(
                package_dir=str(package_dir),
                package_root_name="Fawn-Doe-linux-x64",
                doe_runtime=str(doe_runtime),
                dawn_fallback_runtime=str(dawn_runtime),
                shader_compiler=str(compiler),
                product_id="doe-browser",
                product_name="Fawn Doe",
                root=root,
            )

            _validate(report)
            self.assertIn(
                {
                    "code": "product_identity_mismatch",
                    "path": "browserProduct.displayName",
                    "message": "product-name must be 'Doe Browser' for product-id 'doe-browser'",
                },
                report["failures"],
            )

    def test_empty_product_version_fails_with_schema_valid_report(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            package_dir = root / "fawn-linux"
            _write_file(package_dir / "chrome-wrapper", b"browser\n", 0o755)
            doe_runtime = _write_file(root / "libwebgpu_doe.so", b"doe runtime\n")
            dawn_runtime = _write_file(root / "libdawn_native.so", b"dawn runtime\n")
            compiler = _write_file(root / "doe-zig-runtime", b"compiler\n", 0o755)

            report = package_inputs.build_report(
                package_dir=str(package_dir),
                package_root_name="Fawn-Doe-linux-x64",
                doe_runtime=str(doe_runtime),
                dawn_fallback_runtime=str(dawn_runtime),
                shader_compiler=str(compiler),
                product_version="",
                root=root,
            )

            _validate(report)
            self.assertEqual(report["status"], "fail")
            self.assertIn(
                {
                    "code": "missing_product_version",
                    "path": "browserProduct.version",
                    "message": "product-version is required",
                },
                report["failures"],
            )

    def test_invalid_product_channel_fails_with_schema_valid_report(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            package_dir = root / "fawn-linux"
            _write_file(package_dir / "chrome-wrapper", b"browser\n", 0o755)
            doe_runtime = _write_file(root / "libwebgpu_doe.so", b"doe runtime\n")
            dawn_runtime = _write_file(root / "libdawn_native.so", b"dawn runtime\n")
            compiler = _write_file(root / "doe-zig-runtime", b"compiler\n", 0o755)

            report = package_inputs.build_report(
                package_dir=str(package_dir),
                package_root_name="Fawn-Doe-linux-x64",
                doe_runtime=str(doe_runtime),
                dawn_fallback_runtime=str(dawn_runtime),
                shader_compiler=str(compiler),
                product_channel="preview",
                root=root,
            )

            _validate(report)
            self.assertEqual(report["status"], "fail")
            self.assertIn(
                {
                    "code": "invalid_product_channel",
                    "path": "browserProduct.channel",
                    "message": (
                        "product-channel must be diagnostic, release_candidate, "
                        "or release"
                    ),
                },
                report["failures"],
            )

    def test_invalid_product_id_fails_with_schema_valid_report(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            package_dir = root / "fawn-linux"
            _write_file(package_dir / "chrome-wrapper", b"browser\n", 0o755)
            doe_runtime = _write_file(root / "libwebgpu_doe.so", b"doe runtime\n")
            dawn_runtime = _write_file(root / "libdawn_native.so", b"dawn runtime\n")
            compiler = _write_file(root / "doe-zig-runtime", b"compiler\n", 0o755)

            report = package_inputs.build_report(
                package_dir=str(package_dir),
                package_root_name="Fawn-Doe-linux-x64",
                doe_runtime=str(doe_runtime),
                dawn_fallback_runtime=str(dawn_runtime),
                shader_compiler=str(compiler),
                product_id="fawn-preview",
                product_name="Fawn Doe",
                root=root,
            )

            _validate(report)
            self.assertEqual(report["status"], "fail")
            self.assertIn(
                {
                    "code": "invalid_product_id",
                    "path": "browserProduct.productId",
                    "message": "product-id must be doe-browser or fawn-doe",
                },
                report["failures"],
            )

    def test_invalid_platform_os_fails_with_schema_valid_report(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            paths = _write_linux_inputs(root)

            report = package_inputs.build_report(
                package_dir=str(paths["package_dir"]),
                package_root_name="Fawn-Doe-linux-x64",
                doe_runtime=str(paths["doe_runtime"]),
                dawn_fallback_runtime=str(paths["dawn_runtime"]),
                shader_compiler=str(paths["compiler"]),
                platform_os="windows",
                root=root,
            )

            _validate(report)
            self.assertEqual(report["status"], "fail")
            self.assertIn(
                {
                    "code": "invalid_platform_os",
                    "path": "platform.os",
                    "message": "platform-os must be macos or linux",
                },
                report["failures"],
            )

    def test_invalid_platform_arch_fails_with_schema_valid_report(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            paths = _write_linux_inputs(root)

            report = package_inputs.build_report(
                package_dir=str(paths["package_dir"]),
                package_root_name="Fawn-Doe-linux-x64",
                doe_runtime=str(paths["doe_runtime"]),
                dawn_fallback_runtime=str(paths["dawn_runtime"]),
                shader_compiler=str(paths["compiler"]),
                platform_arch="ppc64",
                root=root,
            )

            _validate(report)
            self.assertEqual(report["status"], "fail")
            self.assertIn(
                {
                    "code": "invalid_platform_arch",
                    "path": "platform.arch",
                    "message": "platform-arch must be arm64 or x64",
                },
                report["failures"],
            )


if __name__ == "__main__":
    unittest.main()
