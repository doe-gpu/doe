from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path

import bench.tools.bootstrap_dawn as bootstrap_dawn
from bench.tools.bootstrap_dawn import ensure_repo


def _run(cmd: list[str], cwd: Path) -> None:
    subprocess.run(cmd, cwd=cwd, check=True, capture_output=True, text=True)


class TestBootstrapDawnRepoSetup(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.origin = self.root / "origin"
        self.origin.mkdir()
        _run(["git", "init", "-b", "main"], self.origin)
        _run(["git", "config", "user.email", "doe@example.invalid"], self.origin)
        _run(["git", "config", "user.name", "Doe Bench"], self.origin)
        (self.origin / "README.md").write_text("origin\n", encoding="utf-8")
        _run(["git", "add", "README.md"], self.origin)
        _run(["git", "commit", "-m", "seed"], self.origin)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_existing_non_git_source_dir_requires_explicit_init(self) -> None:
        source = self.root / "dawn"
        source.mkdir()

        with self.assertRaisesRegex(RuntimeError, "--init-existing-source-dir"):
            ensure_repo(source, str(self.origin), "main", skip_fetch=False)

    def test_init_existing_source_dir_preserves_build_outputs(self) -> None:
        source = self.root / "dawn"
        release = source / "out" / "Release"
        release.mkdir(parents=True)
        sentinel = release / "libwebgpu_dawn.dylib"
        sentinel.write_text("delegate\n", encoding="utf-8")

        ensure_repo(
            source,
            str(self.origin),
            "main",
            skip_fetch=False,
            init_existing_source_dir=True,
            fetch_depth=1,
        )

        self.assertTrue((source / ".git").is_dir())
        self.assertEqual((source / "README.md").read_text(encoding="utf-8"), "origin\n")
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "delegate\n")


class TestBootstrapDawnGnSetup(unittest.TestCase):
    def test_find_binaries_maps_shared_target_to_platform_library(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            build_dir = Path(tmpdir)
            if bootstrap_dawn.os.name == "nt":
                library = build_dir / "webgpu_dawn.dll"
            elif bootstrap_dawn.sys.platform == "darwin":
                library = build_dir / "libwebgpu_dawn.dylib"
            else:
                library = build_dir / "libwebgpu_dawn.so"
            library.write_bytes(b"dawn")

            binaries = bootstrap_dawn.find_binaries(
                build_dir,
                ["webgpu_dawn_shared"],
            )

            self.assertEqual(binaries["webgpu_dawn_shared"], str(library))

    def test_sync_repairs_fetch_helper_checkout_without_origin(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            source = Path(tmpdir) / "dawn"
            dependency = source / "third_party" / "example"
            dependency.mkdir(parents=True)
            _run(["git", "init"], dependency)
            fetch_head = dependency / ".git" / "FETCH_HEAD"
            fetch_head.write_text(
                "0123456789abcdef\t\t'0123456789abcdef' of https://example.invalid/repo\n",
                encoding="utf-8",
            )

            repaired = bootstrap_dawn.repair_originless_dependency_remotes(source)

            self.assertEqual(repaired, [dependency])
            remote = subprocess.run(
                ["git", "-C", str(dependency), "remote", "get-url", "origin"],
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertEqual(remote.stdout.strip(), "https://example.invalid/repo")

    def test_gn_configure_requires_full_gclient_dependency_tree(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            source = Path(tmpdir) / "dawn"
            source.mkdir()

            with self.assertRaisesRegex(RuntimeError, "--sync-deps"):
                bootstrap_dawn.configure_build_gn(
                    source,
                    source / "out" / "Release",
                    "Release",
                    "is_debug=false",
                    None,
                    False,
                )

    def test_depot_tools_wrapper_runs_sibling_bootstrap(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            depot_tools = Path(tmpdir) / "depot_tools"
            depot_tools.mkdir()
            gn = depot_tools / "gn"
            gn.write_text("#!/bin/sh\n", encoding="utf-8")
            ensure_bootstrap = depot_tools / "ensure_bootstrap"
            ensure_bootstrap.write_text("#!/bin/sh\n", encoding="utf-8")
            calls = []
            original_run = bootstrap_dawn.run

            def fake_run(
                cmd: list[str],
                *,
                cwd: Path | None = None,
                env: dict[str, str] | None = None,
            ) -> None:
                calls.append((cmd, cwd, env))

            try:
                bootstrap_dawn.run = fake_run
                bootstrapped = bootstrap_dawn.maybe_bootstrap_depot_tools(
                    str(gn),
                    "gn.py: Unable to find gn in your $PATH",
                )
            finally:
                bootstrap_dawn.run = original_run

            self.assertTrue(bootstrapped)
            expected = ensure_bootstrap.resolve()
            self.assertEqual(calls, [([str(expected)], expected.parent, None)])

    def test_sync_dawn_deps_writes_standalone_gclient(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            source = Path(tmpdir) / "dawn"
            scripts = source / "scripts"
            scripts.mkdir(parents=True)
            (scripts / "standalone.gclient").write_text(
                "solutions = []\n",
                encoding="utf-8",
            )
            depot_tools = Path(tmpdir) / "depot_tools"
            depot_tools.mkdir()
            gclient = depot_tools / "gclient"
            gclient.write_text("#!/bin/sh\n", encoding="utf-8")
            calls = []
            original_run = bootstrap_dawn.run

            def fake_run(
                cmd: list[str],
                *,
                cwd: Path | None = None,
                env: dict[str, str] | None = None,
            ) -> None:
                calls.append((cmd, cwd, env))

            try:
                bootstrap_dawn.run = fake_run
                bootstrap_dawn.sync_dawn_deps(
                    source,
                    None,
                    depot_tools,
                    no_history=True,
                )
            finally:
                bootstrap_dawn.run = original_run

            self.assertEqual(
                (source / ".gclient").read_text(encoding="utf-8"),
                "solutions = []\n",
            )
            self.assertEqual(calls[0][0], [str(gclient), "sync", "--no-history"])
            self.assertEqual(calls[0][1], source)
            self.assertIn(str(depot_tools), calls[0][2]["PATH"])


if __name__ == "__main__":
    unittest.main()
