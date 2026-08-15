#!/usr/bin/env python3
"""Tests for the browser release archive packer."""

from __future__ import annotations

import hashlib
import json
import os
import plistlib
import stat
import struct
import subprocess
import sys
import unittest
import zipfile
from pathlib import Path

import jsonschema

from bench.tools import check_browser_release_package_inputs as package_inputs_check
from bench.tools import check_browser_release_artifact_bundle as bundle_check


REPO_ROOT = Path(__file__).resolve().parents[2]
PACKER = REPO_ROOT / "browser" / "chromium" / "scripts" / "package-browser-release-archive.py"
SCHEMA = REPO_ROOT / "config" / "browser-release-archive-manifest.schema.json"


def _sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _write_app_fixture(root: Path) -> tuple[Path, Path, Path]:
    app_dir = root / "Fawn.app"
    macos_dir = app_dir / "Contents" / "MacOS"
    frameworks_dir = app_dir / "Contents" / "Frameworks"
    macos_dir.mkdir(parents=True)
    frameworks_dir.mkdir(parents=True)
    browser = macos_dir / "Chromium"
    browser.write_bytes(b"browser executable\n")
    browser.chmod(0o755)
    plist = {
        "CFBundleDisplayName": "Fawn Doe",
        "CFBundleExecutable": "Chromium",
        "CFBundleIdentifier": "dev.doe.fawn-doe",
        "CFBundleName": "Fawn Doe",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.0.0-test",
        "CFBundleVersion": "0.0.0-test",
    }
    with (app_dir / "Contents" / "Info.plist").open("wb") as handle:
        plistlib.dump(plist, handle)
    stale_doe = frameworks_dir / "libwebgpu_doe.so"
    stale_doe.write_bytes(b"stale doe runtime\n")
    stale_dawn = frameworks_dir / "libdawn_native.so"
    stale_dawn.write_bytes(b"stale dawn runtime\n")
    doe_runtime = root / "libwebgpu_doe.so"
    doe_runtime.write_bytes(b"packaged doe runtime\n")
    dawn_runtime = root / "libdawn_native.so"
    dawn_runtime.write_bytes(b"packaged dawn runtime\n")
    return app_dir, doe_runtime, dawn_runtime


def _write_linux_fixture(root: Path) -> tuple[Path, Path, Path]:
    package_dir = root / "fawn-linux"
    package_dir.mkdir()
    browser = package_dir / "chrome-wrapper"
    browser.write_bytes(b"linux browser executable\n")
    browser.chmod(0o755)
    stale_dawn = package_dir / "libdawn_native.so"
    stale_dawn.write_bytes(b"stale linux dawn runtime\n")
    doe_runtime = root / "libwebgpu_doe.so"
    doe_runtime.write_bytes(b"linux packaged doe runtime\n")
    dawn_runtime = root / "libdawn_native.so"
    dawn_runtime.write_bytes(b"linux packaged dawn runtime\n")
    return package_dir, doe_runtime, dawn_runtime


def _elf_x64_payload() -> bytes:
    payload = bytearray(64)
    payload[:6] = b"\x7fELF\x02\x01"
    payload[18:20] = struct.pack("<H", 0x3E)
    return bytes(payload)


def _write_linux_candidate_fixture(root: Path) -> tuple[Path, Path, Path, Path]:
    package_dir = root / "fawn-linux"
    policy = package_inputs_check.load_release_platform_policy()
    linux = next(row for row in policy["releasePlatforms"] if row["os"] == "linux")
    for member in linux["requiredPackageMembers"]:
        source = package_dir / member["path"]
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_bytes(b"support\n")
        source.chmod(0o755 if member["executable"] else 0o644)
    browser = _write_executable(package_dir / "chrome-wrapper", _elf_x64_payload())
    doe_runtime = _write_executable(root / "libwebgpu_doe.so", _elf_x64_payload())
    dawn_runtime = _write_executable(root / "libdawn_native.so", _elf_x64_payload())
    compiler = _write_executable(root / "doe-zig-runtime", _elf_x64_payload())
    args = root / "args.gn"
    args.write_text(
        "\n".join(
            [
                "is_debug = false",
                "is_official_build = true",
                "dcheck_always_on = false",
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
    return package_dir, doe_runtime, dawn_runtime, compiler


def _write_executable(path: Path, payload: bytes) -> Path:
    path.write_bytes(payload)
    path.chmod(0o755)
    return path


class PackageBrowserReleaseArchiveTests(unittest.TestCase):
    def test_linux_release_candidate_requires_complete_eligible_preflight(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            package_dir, doe_runtime, dawn_runtime, compiler = (
                _write_linux_candidate_fixture(root)
            )
            (package_dir / "icudtl.dat").unlink()
            package_inputs = package_inputs_check.build_report(
                package_dir=str(package_dir),
                package_root_name="Fawn-Doe-linux-x64",
                doe_runtime=str(doe_runtime),
                dawn_fallback_runtime=str(dawn_runtime),
                shader_compiler=str(compiler),
                product_version="0.0.0-test",
                product_channel="release_candidate",
                platform_os="linux",
                platform_arch="x64",
                root=root,
            )
            package_inputs_path = root / "browser-release-package-inputs.json"
            package_inputs_path.write_text(
                json.dumps(package_inputs, indent=2) + "\n",
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    sys.executable,
                    str(PACKER),
                    "--package-inputs",
                    str(package_inputs_path),
                    "--package-inputs-root",
                    str(root),
                    "--out",
                    str(root / "Fawn-Doe-linux-x64.zip"),
                    "--manifest-out",
                    str(root / "Fawn-Doe-linux-x64.manifest.json"),
                ],
                cwd=REPO_ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "release-candidate packaging requires eligible --package-inputs",
                result.stderr,
            )

    def test_linux_release_candidate_packages_complete_preflight(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            package_dir, doe_runtime, dawn_runtime, compiler = (
                _write_linux_candidate_fixture(root)
            )
            package_inputs = package_inputs_check.build_report(
                package_dir=str(package_dir),
                package_root_name="Fawn-Doe-linux-x64",
                doe_runtime=str(doe_runtime),
                dawn_fallback_runtime=str(dawn_runtime),
                shader_compiler=str(compiler),
                product_version="0.0.0-test",
                product_channel="release_candidate",
                platform_os="linux",
                platform_arch="x64",
                root=root,
            )
            self.assertTrue(package_inputs["releaseCandidateEligible"])
            package_inputs_path = root / "browser-release-package-inputs.json"
            package_inputs_path.write_text(
                json.dumps(package_inputs, indent=2) + "\n",
                encoding="utf-8",
            )
            archive = root / "Fawn-Doe-linux-x64.zip"

            subprocess.run(
                [
                    sys.executable,
                    str(PACKER),
                    "--package-inputs",
                    str(package_inputs_path),
                    "--package-inputs-root",
                    str(root),
                    "--out",
                    str(archive),
                    "--manifest-out",
                    str(root / "Fawn-Doe-linux-x64.manifest.json"),
                ],
                cwd=REPO_ROOT,
                check=True,
            )

            with zipfile.ZipFile(archive) as package:
                for relative_path in (
                    "chrome_crashpad_handler",
                    "icudtl.dat",
                    "v8_context_snapshot.bin",
                ):
                    self.assertIn(
                        f"Fawn-Doe-linux-x64/{relative_path}",
                        package.namelist(),
                    )

    def test_packer_emits_deterministic_archive_manifest(self) -> None:
        with self.subTest("package"):
            import tempfile

            with tempfile.TemporaryDirectory() as temp_dir:
                root = Path(temp_dir)
                app_dir, doe_runtime, dawn_runtime = _write_app_fixture(root)
                archive = root / "Fawn-Doe-macos-arm64.zip"
                manifest = root / "Fawn-Doe-macos-arm64.manifest.json"

                subprocess.run(
                    [
                        sys.executable,
                        str(PACKER),
                        "--app-dir",
                        str(app_dir),
                        "--out",
                        str(archive),
                        "--manifest-out",
                        str(manifest),
                        "--doe-runtime",
                        str(doe_runtime),
                        "--dawn-fallback-runtime",
                        str(dawn_runtime),
                        "--product-version",
                        "0.0.0-test",
                        "--product-channel",
                        "release_candidate",
                        "--platform-arch",
                        "arm64",
                    ],
                    cwd=REPO_ROOT,
                    check=True,
                )

                payload = json.loads(manifest.read_text(encoding="utf-8"))
                jsonschema.validate(payload, json.loads(SCHEMA.read_text(encoding="utf-8")))
                self.assertEqual(payload["archive"]["sha256"], hashlib.sha256(archive.read_bytes()).hexdigest())
                self.assertEqual(payload["browserProduct"]["channel"], "release_candidate")
                self.assertEqual(payload["platform"], {"os": "macos", "arch": "arm64", "packageFormat": "zip"})
                self.assertEqual(
                    payload["members"]["doeRuntime"]["sha256"],
                    _sha256_bytes(b"packaged doe runtime\n"),
                )
                self.assertEqual(
                    payload["members"]["dawnFallbackRuntime"]["sha256"],
                    _sha256_bytes(b"packaged dawn runtime\n"),
                )

                with zipfile.ZipFile(archive) as package:
                    self.assertEqual(
                        package.read("Fawn.app/Contents/Frameworks/libwebgpu_doe.so"),
                        b"packaged doe runtime\n",
                    )
                    self.assertEqual(
                        package.read("Fawn.app/Contents/Frameworks/libdawn_native.so"),
                        b"packaged dawn runtime\n",
                    )
                    browser_info = package.getinfo("Fawn.app/Contents/MacOS/Chromium")
                    mode = (browser_info.external_attr >> 16) & 0o777
                    self.assertTrue(mode & stat.S_IXUSR)
                    for info in package.infolist():
                        self.assertEqual(info.date_time, (1980, 1, 1, 0, 0, 0))

    def test_packer_derives_release_archive_from_package_inputs(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            package_dir, doe_runtime, dawn_runtime = _write_linux_fixture(root)
            shader_compiler = _write_executable(root / "doe-zig-runtime", b"compiler\n")
            package_inputs = package_inputs_check.build_report(
                package_dir=str(package_dir),
                package_root_name="Fawn-Doe-linux-x64",
                doe_runtime=str(doe_runtime),
                dawn_fallback_runtime=str(dawn_runtime),
                shader_compiler=str(shader_compiler),
                product_version="0.0.0-test",
                product_channel="diagnostic",
                platform_os="linux",
                platform_arch="x64",
                root=root,
            )
            package_inputs_path = root / "browser-release-package-inputs.json"
            package_inputs_path.write_text(
                json.dumps(package_inputs, indent=2) + "\n",
                encoding="utf-8",
            )
            archive = root / "Fawn-Doe-linux-x64.zip"
            manifest = root / "Fawn-Doe-linux-x64.manifest.json"

            subprocess.run(
                [
                    sys.executable,
                    str(PACKER),
                    "--package-inputs",
                    str(package_inputs_path),
                    "--package-inputs-root",
                    str(root),
                    "--out",
                    str(archive),
                    "--manifest-out",
                    str(manifest),
                ],
                cwd=REPO_ROOT,
                check=True,
            )

            payload = json.loads(manifest.read_text(encoding="utf-8"))
            jsonschema.validate(payload, json.loads(SCHEMA.read_text(encoding="utf-8")))
            self.assertEqual(
                payload["sourcePackageInputs"],
                {
                    "path": str(package_inputs_path),
                    "sha256": hashlib.sha256(package_inputs_path.read_bytes()).hexdigest(),
                    "kind": "browser_release_package_inputs_check",
                },
            )
            self.assertEqual(payload["browserProduct"], package_inputs["browserProduct"])
            self.assertEqual(payload["platform"], package_inputs["platform"])
            self.assertEqual(
                payload["members"]["browserExecutable"]["archivePath"],
                package_inputs["inputs"]["browserExecutable"]["archivePath"],
            )
            self.assertEqual(
                payload["members"]["appMetadata"]["archivePath"],
                package_inputs["inputs"]["appMetadata"]["archivePath"],
            )
            self.assertEqual(
                payload["members"]["doeRuntime"]["archivePath"],
                package_inputs["inputs"]["doeRuntime"]["archivePath"],
            )
            self.assertEqual(
                payload["members"]["dawnFallbackRuntime"]["archivePath"],
                package_inputs["inputs"]["dawnFallbackRuntime"]["archivePath"],
            )
            self.assertEqual(
                payload["members"]["doeRuntime"]["sha256"],
                package_inputs["inputs"]["doeRuntime"]["sha256"],
            )
            self.assertEqual(
                payload["members"]["dawnFallbackRuntime"]["sha256"],
                package_inputs["inputs"]["dawnFallbackRuntime"]["sha256"],
            )

    def test_packer_rejects_package_inputs_mismatch(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            package_dir, doe_runtime, dawn_runtime = _write_linux_fixture(root)
            shader_compiler = _write_executable(root / "doe-zig-runtime", b"compiler\n")
            package_inputs = package_inputs_check.build_report(
                package_dir=str(package_dir),
                package_root_name="Fawn-Doe-linux-x64",
                doe_runtime=str(doe_runtime),
                dawn_fallback_runtime=str(dawn_runtime),
                shader_compiler=str(shader_compiler),
                product_version="0.0.0-test",
                product_channel="diagnostic",
                platform_os="linux",
                platform_arch="x64",
                root=root,
            )
            package_inputs_path = root / "browser-release-package-inputs.json"
            package_inputs_path.write_text(
                json.dumps(package_inputs, indent=2) + "\n",
                encoding="utf-8",
            )
            archive = root / "Fawn-Doe-linux-x64.zip"
            manifest = root / "Fawn-Doe-linux-x64.manifest.json"

            result = subprocess.run(
                [
                    sys.executable,
                    str(PACKER),
                    "--package-inputs",
                    str(package_inputs_path),
                    "--package-inputs-root",
                    str(root),
                    "--doe-runtime-archive-path",
                    "Fawn-Doe-linux-x64/wrong-libwebgpu_doe.so",
                    "--out",
                    str(archive),
                    "--manifest-out",
                    str(manifest),
                ],
                cwd=REPO_ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("--doe-runtime-archive-path must match --package-inputs", result.stderr)

    def test_packer_emits_linux_archive_with_generated_metadata(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            package_dir, doe_runtime, dawn_runtime = _write_linux_fixture(root)
            archive = root / "Fawn-Doe-linux-x64.zip"
            manifest = root / "Fawn-Doe-linux-x64.manifest.json"

            subprocess.run(
                [
                    sys.executable,
                    str(PACKER),
                    "--package-dir",
                    str(package_dir),
                    "--package-root-name",
                    "Fawn-Doe-linux-x64",
                    "--out",
                    str(archive),
                    "--manifest-out",
                    str(manifest),
                    "--doe-runtime",
                    str(doe_runtime),
                    "--dawn-fallback-runtime",
                    str(dawn_runtime),
                    "--product-version",
                    "0.0.0-test",
                    "--product-channel",
                    "diagnostic",
                    "--platform-os",
                    "linux",
                    "--platform-arch",
                    "x64",
                ],
                cwd=REPO_ROOT,
                check=True,
            )

            payload = json.loads(manifest.read_text(encoding="utf-8"))
            jsonschema.validate(payload, json.loads(SCHEMA.read_text(encoding="utf-8")))
            self.assertEqual(payload["appBundleName"], "Fawn-Doe-linux-x64")
            self.assertEqual(payload["platform"], {"os": "linux", "arch": "x64", "packageFormat": "zip"})
            self.assertEqual(
                payload["members"]["browserExecutable"]["archivePath"],
                "Fawn-Doe-linux-x64/chrome-wrapper",
            )
            self.assertEqual(
                payload["members"]["appMetadata"]["archivePath"],
                "Fawn-Doe-linux-x64/browser-product.json",
            )
            self.assertEqual(
                payload["members"]["doeRuntime"]["sha256"],
                _sha256_bytes(b"linux packaged doe runtime\n"),
            )
            self.assertEqual(
                payload["members"]["dawnFallbackRuntime"]["sha256"],
                _sha256_bytes(b"linux packaged dawn runtime\n"),
            )

            with zipfile.ZipFile(archive) as package:
                metadata = json.loads(package.read("Fawn-Doe-linux-x64/browser-product.json"))
                self.assertEqual(metadata["browserProduct"], payload["browserProduct"])
                self.assertEqual(metadata["platform"], payload["platform"])
                self.assertEqual(
                    metadata["browserExecutableArchivePath"],
                    "Fawn-Doe-linux-x64/chrome-wrapper",
                )
                self.assertEqual(
                    package.read("Fawn-Doe-linux-x64/libwebgpu_doe.so"),
                    b"linux packaged doe runtime\n",
                )
                self.assertEqual(
                    package.read("Fawn-Doe-linux-x64/libdawn_native.so"),
                    b"linux packaged dawn runtime\n",
                )

            release_bundle = {
                "releaseStatus": "diagnostic",
                "browserProduct": payload["browserProduct"],
                "platform": payload["platform"],
                "releaseArchive": {
                    "path": str(archive),
                    "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
                    "kind": "browser_release_archive",
                },
                "releaseArchiveManifest": {
                    "path": str(manifest),
                    "sha256": hashlib.sha256(manifest.read_bytes()).hexdigest(),
                    "kind": "browser_release_archive_manifest",
                },
                "browserExecutableArchivePath": "Fawn-Doe-linux-x64/chrome-wrapper",
                "browserAppMetadataArchivePath": "Fawn-Doe-linux-x64/browser-product.json",
                "doeRuntimeArchivePath": "Fawn-Doe-linux-x64/libwebgpu_doe.so",
                "dawnFallbackRuntimeArchivePath": "Fawn-Doe-linux-x64/libdawn_native.so",
                "browserBinary": {
                    "path": str(package_dir / "chrome-wrapper"),
                    "sha256": _sha256_bytes(b"linux browser executable\n"),
                    "kind": "browser_binary",
                },
                "doeRuntime": {
                    "path": str(doe_runtime),
                    "sha256": _sha256_bytes(b"linux packaged doe runtime\n"),
                    "kind": "doe_runtime",
                },
                "dawnFallbackRuntime": {
                    "path": str(dawn_runtime),
                    "sha256": _sha256_bytes(b"linux packaged dawn runtime\n"),
                    "kind": "dawn_fallback_runtime",
                },
            }
            self.assertEqual(
                bundle_check.check_release_archive_surface(
                    release_bundle,
                    root,
                    require_release_candidate=False,
                ),
                [],
            )
            self.assertEqual(
                bundle_check.check_release_archive_manifest_artifact(
                    release_bundle,
                    root,
                    require_release_candidate=False,
                ),
                [],
            )

    def test_packer_required_members_only_excludes_extra_package_files(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            package_dir, doe_runtime, dawn_runtime = _write_linux_fixture(root)
            (package_dir / "unrelated-build-output.bin").write_bytes(b"not release evidence\n")
            archive = root / "Fawn-Doe-linux-x64.zip"
            manifest = root / "Fawn-Doe-linux-x64.manifest.json"

            subprocess.run(
                [
                    sys.executable,
                    str(PACKER),
                    "--package-dir",
                    str(package_dir),
                    "--package-root-name",
                    "Fawn-Doe-linux-x64",
                    "--out",
                    str(archive),
                    "--manifest-out",
                    str(manifest),
                    "--doe-runtime",
                    str(doe_runtime),
                    "--dawn-fallback-runtime",
                    str(dawn_runtime),
                    "--product-version",
                    "0.0.0-test",
                    "--product-channel",
                    "diagnostic",
                    "--platform-os",
                    "linux",
                    "--platform-arch",
                    "x64",
                    "--required-members-only",
                ],
                cwd=REPO_ROOT,
                check=True,
            )

            payload = json.loads(manifest.read_text(encoding="utf-8"))
            member_paths = {
                member["archivePath"]
                for member in payload["archiveMembers"]
            }
            self.assertEqual(
                member_paths,
                {
                    "Fawn-Doe-linux-x64/chrome-wrapper",
                    "Fawn-Doe-linux-x64/browser-product.json",
                    "Fawn-Doe-linux-x64/libwebgpu_doe.so",
                    "Fawn-Doe-linux-x64/libdawn_native.so",
                },
            )
            with zipfile.ZipFile(archive) as package:
                self.assertNotIn(
                    "Fawn-Doe-linux-x64/unrelated-build-output.bin",
                    package.namelist(),
                )

    def test_packer_rejects_required_members_only_for_release_candidate(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            package_dir, doe_runtime, dawn_runtime = _write_linux_fixture(root)
            archive = root / "Fawn-Doe-linux-x64.zip"
            manifest = root / "Fawn-Doe-linux-x64.manifest.json"

            result = subprocess.run(
                [
                    sys.executable,
                    str(PACKER),
                    "--package-dir",
                    str(package_dir),
                    "--package-root-name",
                    "Fawn-Doe-linux-x64",
                    "--out",
                    str(archive),
                    "--manifest-out",
                    str(manifest),
                    "--doe-runtime",
                    str(doe_runtime),
                    "--dawn-fallback-runtime",
                    str(dawn_runtime),
                    "--product-version",
                    "0.0.0-test",
                    "--product-channel",
                    "release_candidate",
                    "--platform-os",
                    "linux",
                    "--platform-arch",
                    "x64",
                    "--required-members-only",
                ],
                cwd=REPO_ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "--required-members-only is restricted to diagnostic product channels",
                result.stderr,
            )
            self.assertFalse(archive.exists())
            self.assertFalse(manifest.exists())

    def test_packer_rejects_absolute_runtime_member_paths(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            app_dir, doe_runtime, dawn_runtime = _write_app_fixture(root)
            archive = root / "Fawn-Doe-macos-arm64.zip"
            manifest = root / "Fawn-Doe-macos-arm64.manifest.json"

            result = subprocess.run(
                [
                    sys.executable,
                    str(PACKER),
                    "--app-dir",
                    str(app_dir),
                    "--out",
                    str(archive),
                    "--manifest-out",
                    str(manifest),
                    "--doe-runtime",
                    str(doe_runtime),
                    "--dawn-fallback-runtime",
                    str(dawn_runtime),
                    "--doe-runtime-archive-path",
                    os.path.join(os.sep, "tmp", "libwebgpu_doe.so"),
                    "--product-version",
                    "0.0.0-test",
                    "--platform-arch",
                    "arm64",
                ],
                cwd=REPO_ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("archive member path must be relative", result.stderr)

    def test_packer_rejects_duplicate_required_archive_member_paths(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            app_dir, doe_runtime, dawn_runtime = _write_app_fixture(root)
            archive = root / "Fawn-Doe-macos-arm64.zip"
            manifest = root / "Fawn-Doe-macos-arm64.manifest.json"

            result = subprocess.run(
                [
                    sys.executable,
                    str(PACKER),
                    "--app-dir",
                    str(app_dir),
                    "--out",
                    str(archive),
                    "--manifest-out",
                    str(manifest),
                    "--doe-runtime",
                    str(doe_runtime),
                    "--dawn-fallback-runtime",
                    str(dawn_runtime),
                    "--dawn-fallback-runtime-archive-path",
                    "Fawn.app/Contents/Frameworks/libwebgpu_doe.so",
                    "--product-version",
                    "0.0.0-test",
                    "--platform-arch",
                    "arm64",
                ],
                cwd=REPO_ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "dawnFallbackRuntime archive path duplicates doeRuntime",
                result.stderr,
            )
            self.assertFalse(archive.exists())
            self.assertFalse(manifest.exists())

    def test_packer_rejects_product_identity_mismatch(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            app_dir, doe_runtime, dawn_runtime = _write_app_fixture(root)
            archive = root / "Fawn-Doe-macos-arm64.zip"
            manifest = root / "Fawn-Doe-macos-arm64.manifest.json"

            result = subprocess.run(
                [
                    sys.executable,
                    str(PACKER),
                    "--app-dir",
                    str(app_dir),
                    "--out",
                    str(archive),
                    "--manifest-out",
                    str(manifest),
                    "--doe-runtime",
                    str(doe_runtime),
                    "--dawn-fallback-runtime",
                    str(dawn_runtime),
                    "--product-id",
                    "doe-browser",
                    "--product-name",
                    "Fawn Doe",
                    "--product-version",
                    "0.0.0-test",
                    "--platform-arch",
                    "arm64",
                ],
                cwd=REPO_ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "product-name must be 'Doe Browser' for product-id 'doe-browser'",
                result.stderr,
            )

    def test_packer_rejects_non_executable_browser_binary(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            app_dir, doe_runtime, dawn_runtime = _write_app_fixture(root)
            browser = app_dir / "Contents" / "MacOS" / "Chromium"
            browser.chmod(0o644)
            archive = root / "Fawn-Doe-macos-arm64.zip"
            manifest = root / "Fawn-Doe-macos-arm64.manifest.json"

            result = subprocess.run(
                [
                    sys.executable,
                    str(PACKER),
                    "--app-dir",
                    str(app_dir),
                    "--out",
                    str(archive),
                    "--manifest-out",
                    str(manifest),
                    "--doe-runtime",
                    str(doe_runtime),
                    "--dawn-fallback-runtime",
                    str(dawn_runtime),
                    "--product-version",
                    "0.0.0-test",
                    "--platform-arch",
                    "arm64",
                ],
                cwd=REPO_ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("browser executable inside package must be executable", result.stderr)


if __name__ == "__main__":
    unittest.main()
