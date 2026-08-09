from __future__ import annotations

import hashlib
import json
import tarfile
import tempfile
import unittest
from pathlib import Path

import bench.tools.bootstrap_zig as bootstrap_zig


class BootstrapZigTest(unittest.TestCase):
    def make_contract(self, root: Path) -> tuple[Path, Path]:
        source_root = root / "source" / "zig-x86_64-linux-0.15.2"
        source_root.mkdir(parents=True)
        zig = source_root / "zig"
        zig.write_text("#!/bin/sh\nprintf '0.15.2\\n'\n", encoding="utf-8")
        zig.chmod(0o755)
        archive = root / "zig.tar.xz"
        with tarfile.open(archive, "w:xz") as output:
            output.add(source_root, arcname=source_root.name)
        archive_bytes = archive.read_bytes()
        config = root / "toolchains.json"
        config.write_text(
            json.dumps(
                {
                    "toolchains": {
                        "zig": {
                            "version": "0.15.2",
                            "archives": {
                                "x86_64-linux": {
                                    "url": archive.as_uri(),
                                    "sha256": hashlib.sha256(archive_bytes).hexdigest(),
                                    "sizeBytes": len(archive_bytes),
                                }
                            },
                        }
                    }
                }
            ),
            encoding="utf-8",
        )
        return config, archive

    def test_install_verifies_extracts_and_is_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config, _ = self.make_contract(root)
            install_dir = root / "tooling" / "zig-0.15.2"

            first = bootstrap_zig.install(config, "x86_64-linux", install_dir)
            second = bootstrap_zig.install(config, "x86_64-linux", install_dir)

            self.assertEqual(first["status"], "installed")
            self.assertEqual(second["status"], "already-installed")
            self.assertEqual(
                bootstrap_zig.installed_version(install_dir / "zig"),
                "0.15.2",
            )

    def test_archive_hash_mismatch_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _, archive = self.make_contract(root)
            contract = {
                "sha256": "0" * 64,
                "sizeBytes": archive.stat().st_size,
            }

            with self.assertRaisesRegex(ValueError, "archive hash mismatch"):
                bootstrap_zig.verify_archive(archive, contract)

    def test_missing_platform_contract_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config, _ = self.make_contract(root)

            with self.assertRaisesRegex(ValueError, "no Zig archive"):
                bootstrap_zig.load_contract(config, "aarch64-linux")


if __name__ == "__main__":
    unittest.main()
