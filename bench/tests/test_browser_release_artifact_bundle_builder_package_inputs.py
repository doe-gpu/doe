#!/usr/bin/env python3
"""Tests for release bundle builder package-input binding."""

from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path

from bench.tools import check_browser_release_artifact_bundle as bundle_check
from bench.tools import check_browser_release_package_inputs as package_inputs


REPO_ROOT = Path(__file__).resolve().parents[2]
PACKER = REPO_ROOT / "browser" / "chromium" / "scripts" / "package-browser-release-archive.py"
BUILDER = REPO_ROOT / "bench" / "tools" / "build_browser_release_artifact_bundle.py"


def _write_file(path: Path, payload: bytes, mode: int = 0o644) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)
    path.chmod(mode)
    return path


class BrowserReleaseArtifactBundleBuilderPackageInputsTests(unittest.TestCase):
    def test_builder_derives_release_identity_from_package_inputs(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory(dir=REPO_ROOT) as temp_dir:
            root = Path(temp_dir)
            package_dir = root / "fawn-linux"
            _write_file(package_dir / "chrome-wrapper", b"linux browser\n", 0o755)
            doe_runtime = _write_file(root / "libwebgpu_doe.so", b"doe runtime\n", 0o755)
            dawn_runtime = _write_file(root / "libdawn_native.so", b"dawn runtime\n", 0o755)
            compiler = _write_file(root / "doe-zig-runtime", b"compiler\n", 0o755)
            package_inputs_path = root / "browser-release-package-inputs.json"
            archive = root / "Fawn-Doe-linux-x64.zip"
            manifest = root / "Fawn-Doe-linux-x64.manifest.json"
            bundle = root / "browser-release-bundle.json"

            report = package_inputs.build_report(
                package_dir=str(package_dir),
                package_root_name="Fawn-Doe-linux-x64",
                doe_runtime=str(doe_runtime),
                dawn_fallback_runtime=str(dawn_runtime),
                shader_compiler=str(compiler),
                product_version="0.0.0-test",
                root=REPO_ROOT,
            )
            package_inputs_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

            subprocess.run(
                [
                    sys.executable,
                    str(PACKER),
                    "--package-inputs",
                    str(package_inputs_path),
                    "--package-inputs-root",
                    str(REPO_ROOT),
                    "--out",
                    str(archive),
                    "--manifest-out",
                    str(manifest),
                ],
                cwd=REPO_ROOT,
                check=True,
            )
            subprocess.run(
                [
                    sys.executable,
                    str(BUILDER),
                    "--bundle-id",
                    "browser-release-package-inputs-test",
                    "--release-status",
                    "diagnostic",
                    "--release-archive",
                    str(archive),
                    "--release-archive-manifest",
                    str(manifest),
                    "--package-inputs",
                    str(package_inputs_path),
                    "--claim-report",
                    "examples/browser-claim-report.sample.json",
                    "--promotion-receipt",
                    "examples/browser-claim-promotion-receipt.sample.json",
                    "--verify-files-root",
                    ".",
                    "--out",
                    str(bundle),
                ],
                cwd=REPO_ROOT,
                check=True,
            )

            payload = json.loads(bundle.read_text(encoding="utf-8"))

            self.assertEqual(
                payload["packageInputs"]["path"],
                str(package_inputs_path.relative_to(REPO_ROOT)),
            )
            self.assertEqual(
                payload["packageInputs"]["sha256"],
                package_inputs.sha256_file(package_inputs_path),
            )
            self.assertEqual(
                payload["packageInputs"]["kind"],
                "browser_release_package_inputs_check",
            )
            self.assertEqual(bundle_check.check_bundle(payload, verify_files_root=REPO_ROOT), [])
            self.assertEqual(payload["browserProduct"], report["browserProduct"])
            self.assertEqual(payload["platform"], report["platform"])
            self.assertEqual(
                payload["browserExecutableArchivePath"],
                "Fawn-Doe-linux-x64/chrome-wrapper",
            )
            self.assertEqual(
                payload["browserAppMetadataArchivePath"],
                "Fawn-Doe-linux-x64/browser-product.json",
            )
            self.assertEqual(
                payload["doeRuntimeArchivePath"],
                "Fawn-Doe-linux-x64/libwebgpu_doe.so",
            )
            self.assertEqual(
                payload["dawnFallbackRuntimeArchivePath"],
                "Fawn-Doe-linux-x64/libdawn_native.so",
            )
            self.assertEqual(
                payload["browserBinary"]["path"],
                report["inputs"]["browserExecutable"]["path"],
            )
            self.assertEqual(
                payload["doeRuntime"]["path"],
                report["inputs"]["doeRuntime"]["path"],
            )
            self.assertEqual(
                payload["dawnFallbackRuntime"]["path"],
                report["inputs"]["dawnFallbackRuntime"]["path"],
            )
            self.assertEqual(
                payload["shaderCompiler"]["path"],
                report["inputs"]["shaderCompiler"]["path"],
            )

    def test_builder_rejects_failing_package_inputs(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory(dir=REPO_ROOT) as temp_dir:
            root = Path(temp_dir)
            package_inputs_path = root / "browser-release-package-inputs.json"
            payload = {
                "schemaVersion": 1,
                "artifactKind": "browser_release_package_inputs_check",
                "status": "fail",
                "inputs": {},
            }
            package_inputs_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

            result = subprocess.run(
                [
                    sys.executable,
                    str(BUILDER),
                    "--bundle-id",
                    "browser-release-package-inputs-test",
                    "--release-status",
                    "diagnostic",
                    "--package-inputs",
                    str(package_inputs_path),
                    "--claim-report",
                    "examples/browser-claim-report.sample.json",
                    "--promotion-receipt",
                    "examples/browser-claim-promotion-receipt.sample.json",
                    "--out",
                    str(root / "browser-release-bundle.json"),
                ],
                cwd=REPO_ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "package inputs report must pass before building a release bundle",
                result.stderr,
            )

    def test_builder_rejects_package_inputs_archive_path_mismatch(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory(dir=REPO_ROOT) as temp_dir:
            root = Path(temp_dir)
            package_dir = root / "fawn-linux"
            _write_file(package_dir / "chrome-wrapper", b"linux browser\n", 0o755)
            doe_runtime = _write_file(root / "libwebgpu_doe.so", b"doe runtime\n", 0o755)
            dawn_runtime = _write_file(root / "libdawn_native.so", b"dawn runtime\n", 0o755)
            compiler = _write_file(root / "doe-zig-runtime", b"compiler\n", 0o755)
            package_inputs_path = root / "browser-release-package-inputs.json"
            report = package_inputs.build_report(
                package_dir=str(package_dir),
                package_root_name="Fawn-Doe-linux-x64",
                doe_runtime=str(doe_runtime),
                dawn_fallback_runtime=str(dawn_runtime),
                shader_compiler=str(compiler),
                product_version="0.0.0-test",
                root=REPO_ROOT,
            )
            package_inputs_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

            result = subprocess.run(
                [
                    sys.executable,
                    str(BUILDER),
                    "--bundle-id",
                    "browser-release-package-inputs-test",
                    "--release-status",
                    "diagnostic",
                    "--package-inputs",
                    str(package_inputs_path),
                    "--doe-runtime-archive-path",
                    "Fawn-Doe-linux-x64/wrong-libwebgpu_doe.so",
                    "--claim-report",
                    "examples/browser-claim-report.sample.json",
                    "--promotion-receipt",
                    "examples/browser-claim-promotion-receipt.sample.json",
                    "--out",
                    str(root / "browser-release-bundle.json"),
                ],
                cwd=REPO_ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "--doe-runtime-archive-path must match --package-inputs",
                result.stderr,
            )


if __name__ == "__main__":
    unittest.main()
