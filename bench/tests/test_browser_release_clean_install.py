#!/usr/bin/env python3
"""Tests for isolated Fawn release archive verification."""

from __future__ import annotations

import hashlib
import json
import stat
import tempfile
import unittest
import zipfile
from pathlib import Path

import jsonschema

from bench.tools import check_browser_release_clean_install as clean_install


REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA = REPO_ROOT / "config" / "browser-release-clean-install-check.schema.json"
SUPPORT_MEMBERS = (
    ("chrome_100_percent.pak", False),
    ("chrome_200_percent.pak", False),
    ("chrome_crashpad_handler", True),
    ("chrome_sandbox", True),
    ("icudtl.dat", False),
    ("locales/en-US.pak", False),
    ("resources.pak", False),
    ("v8_context_snapshot.bin", False),
)


def _zip_info(path: str, executable: bool) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(path)
    info.create_system = 3
    info.external_attr = ((stat.S_IFREG | (0o755 if executable else 0o644)) << 16)
    return info


def _write_fixture(root: Path, *, browser_exit: int = 0, unsafe_member: bool = False) -> dict[str, Path]:
    archive_path = root / "Fawn-Doe-linux-x64.zip"
    manifest_path = root / "Fawn-Doe-linux-x64.manifest.json"
    policy_path = root / "platform-policy.json"
    package_root = "Fawn-Doe-linux-x64"
    browser_bytes = f"#!/bin/sh\nprintf 'Fawn fixture\\n'\nexit {browser_exit}\n".encode()
    source_rows = [
        ("browser-product.json", b"{}\n", False, "appMetadata"),
        ("chrome", browser_bytes, True, "browserExecutable"),
        ("libdawn_native.so", b"dawn\n", True, "dawnFallbackRuntime"),
        ("libwebgpu_doe.so", b"doe\n", True, "doeRuntime"),
        *((path, f"support:{path}\n".encode(), executable, None) for path, executable in SUPPORT_MEMBERS),
    ]
    records = []
    roles = {}
    with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for relative_path, data, executable, role in source_rows:
            archive_path_text = f"{package_root}/{relative_path}"
            archive.writestr(_zip_info(archive_path_text, executable), data)
            row = {
                "archivePath": archive_path_text,
                "sha256": hashlib.sha256(data).hexdigest(),
                "byteLength": len(data),
                "executable": executable,
            }
            records.append(row)
            if role is not None:
                roles[role] = dict(row)
        if unsafe_member:
            archive.writestr(_zip_info("../escape", False), b"escape")
    product = {
        "productId": "fawn-doe",
        "displayName": "Fawn Doe",
        "version": "0.0.0-test",
        "channel": "release_candidate",
    }
    platform = {"os": "linux", "arch": "x64", "packageFormat": "zip"}
    manifest = {
        "schemaVersion": 1,
        "artifactKind": "browser_release_archive_manifest",
        "archive": {
            "path": str(archive_path),
            "sha256": clean_install.sha256_file(archive_path),
            "byteLength": archive_path.stat().st_size,
            "kind": "browser_release_archive",
        },
        "browserProduct": product,
        "platform": platform,
        "appBundleName": package_root,
        "members": roles,
        "archiveMembers": records,
    }
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    policy_path.write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "policyId": "browser-release/platform-package-test",
                "releasePlatforms": [
                    {
                        **platform,
                        "requiredPackageMembers": [
                            {"path": path, "executable": executable}
                            for path, executable in SUPPORT_MEMBERS
                        ],
                    }
                ],
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    return {"archive": archive_path, "manifest": manifest_path, "policy": policy_path}


def _process(exit_code: int = 0) -> dict:
    return {
        "attempted": True,
        "exitCode": exit_code,
        "timedOut": False,
        "durationMs": 1,
        "stdout": "Fawn fixture\n" if exit_code == 0 else "",
        "stderr": "" if exit_code == 0 else "launch failure",
    }


class BrowserReleaseCleanInstallTests(unittest.TestCase):
    def _build(self, root: Path, paths: dict[str, Path], **kwargs) -> dict:
        return clean_install.build_check(
            archive_path=paths["archive"],
            manifest_path=paths["manifest"],
            policy_path=paths["policy"],
            verification_level=kwargs.get("verification_level", "launch_probe"),
            smoke_script=kwargs.get("smoke_script", root / "smoke.mjs"),
            smoke_out=kwargs.get("smoke_out", root / "smoke.json"),
            timeout_seconds=5,
            run_command=kwargs.get("run_command", clean_install.default_run_command),
        )

    def test_launch_probe_uses_fresh_archive_only(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            payload = self._build(root, _write_fixture(root))

            self.assertEqual("pass", payload["status"])
            self.assertTrue(payload["launchProbe"]["attempted"])
            self.assertEqual(0, payload["extraction"]["borrowedMemberCount"])
            self.assertFalse(payload["releaseCandidateEligible"])
            jsonschema.validate(payload, json.loads(SCHEMA.read_text(encoding="utf-8")))

    def test_webgpu_smoke_binds_extracted_runtime_hashes(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            paths = _write_fixture(root)
            smoke_script = root / "smoke.mjs"
            smoke_out = root / "smoke.json"
            smoke_script.write_text("// injected fixture\n", encoding="utf-8")

            def runner(command: list[str], _timeout: int) -> dict:
                if command[0] != "node":
                    return _process()
                browser_path = Path(command[command.index("--chrome") + 1])
                doe_path = Path(command[command.index("--doe-lib") + 1])
                browser_hash = clean_install.sha256_file(browser_path)
                doe_hash = clean_install.sha256_file(doe_path)
                mode_results = []
                for mode in ("dawn", "doe"):
                    identity = {
                        "browserExecutablePath": str(browser_path),
                        "browserExecutableSha256": browser_hash,
                        "dawnRuntimePath": str(browser_path),
                        "dawnRuntimeSha256": browser_hash,
                        "doeLibPath": str(doe_path) if mode == "doe" else None,
                        "doeLibSha256": doe_hash if mode == "doe" else None,
                    }
                    mode_results.append(
                        {
                            "mode": mode,
                            "webgpuAvailable": True,
                            "runtimeSelection": {
                                "selectedRuntime": mode,
                                "forcedMode": mode,
                                "fallbackApplied": False,
                                "hiddenFallbackAllowed": False,
                                "artifactIdentity": identity,
                            },
                            "activeRuntimeProof": {"matchesRequestedMode": True},
                        }
                    )
                smoke_out.write_text(
                    json.dumps(
                        {
                            "schemaVersion": 2,
                            "reportKind": "chromium-webgpu-playwright-smoke",
                            "mode": "both",
                            "chromePath": str(browser_path),
                            "modeResults": mode_results,
                        }
                    )
                    + "\n",
                    encoding="utf-8",
                )
                return _process()

            payload = self._build(
                root,
                paths,
                verification_level="webgpu_smoke",
                smoke_script=smoke_script,
                smoke_out=smoke_out,
                run_command=runner,
            )

            self.assertEqual("pass", payload["status"])
            self.assertTrue(payload["releaseCandidateEligible"])
            self.assertEqual("chromium-webgpu-playwright-smoke", payload["webgpuSmoke"]["report"]["kind"])
            jsonschema.validate(payload, json.loads(SCHEMA.read_text(encoding="utf-8")))

    def test_unsafe_archive_member_blocks_extraction(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            payload = self._build(root, _write_fixture(root, unsafe_member=True))

            self.assertEqual("fail", payload["status"])
            self.assertFalse(payload["launchProbe"]["attempted"])
            self.assertIn("unsafe_archive_member_path", {row["code"] for row in payload["failures"]})

    def test_launch_failure_is_retained(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            payload = self._build(root, _write_fixture(root, browser_exit=9))

            self.assertEqual("fail", payload["status"])
            self.assertEqual(9, payload["launchProbe"]["exitCode"])
            self.assertIn("browser_launch_probe_failed", {row["code"] for row in payload["failures"]})


if __name__ == "__main__":
    unittest.main()
