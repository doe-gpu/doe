from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
SUPERSET_RUNNER = REPO_ROOT / "browser/chromium/scripts/run-browser-benchmark-superset.py"
LANE_PATHS = REPO_ROOT / "browser/chromium/scripts/lane-paths.sh"
BUILD_RELEASE_EXTERNAL = REPO_ROOT / "browser/chromium/scripts/build-release-external.sh"
RUN_CONSUMER_BENCH = REPO_ROOT / "browser/chromium/scripts/run-consumer-bench.sh"
RUN_FAWN_RUNTIME_BENCH = REPO_ROOT / "browser/chromium/scripts/run-fawn-runtime-bench.sh"
RUN_WITH_LANE_DEFAULTS = REPO_ROOT / "browser/chromium/scripts/run-with-lane-defaults.sh"
SYNC_RELEASE_ARTIFACTS_LOCAL = (
    REPO_ROOT / "browser/chromium/scripts/sync-release-artifacts-local.sh"
)
JS_RUNNERS = (
    REPO_ROOT / "browser/chromium/scripts/webgpu-playwright-smoke.mjs",
    REPO_ROOT / "browser/chromium/scripts/webgpu-playwright-layered-bench.mjs",
    REPO_ROOT / "browser/chromium/scripts/webgpu-playwright-ort-bench.mjs",
)


def _load_superset_runner() -> Any:
    spec = importlib.util.spec_from_file_location("run_browser_benchmark_superset", SUPERSET_RUNNER)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load module: {SUPERSET_RUNNER}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class BrowserDoeLibDefaultTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = _load_superset_runner()

    def test_python_superset_runner_prefers_full_webgpu_library(self) -> None:
        old_root = self.module.REPO_ROOT
        old_env = os.environ.pop("FAWN_DOE_LIB", None)
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                root = Path(tmpdir)
                lib_dir = root / "runtime/zig/zig-out/lib"
                lib_dir.mkdir(parents=True)
                preferred_ext = self.module.host_doe_lib_extension()
                full = lib_dir / f"libwebgpu_doe_full.{preferred_ext}"
                compute = lib_dir / f"libwebgpu_doe.{preferred_ext}"
                full.write_text("", encoding="utf-8")
                compute.write_text("", encoding="utf-8")
                self.module.REPO_ROOT = root

                self.assertEqual(self.module.default_doe_lib(), full)
        finally:
            self.module.REPO_ROOT = old_root
            if old_env is not None:
                os.environ["FAWN_DOE_LIB"] = old_env

    def test_python_superset_runner_selects_host_workload_contract(self) -> None:
        metal_workloads, metal_manifest = self.module.host_benchmark_defaults("darwin")
        vulkan_workloads, vulkan_manifest = self.module.host_benchmark_defaults("linux")

        self.assertEqual(
            metal_workloads,
            self.module.REPO_ROOT
            / "bench/workloads/specialized/workloads.apple.metal.superset.json",
        )
        self.assertEqual(
            metal_manifest,
            self.module.REPO_ROOT
            / "browser/chromium/bench/generated/browser_projection_manifest.apple.metal.json",
        )
        self.assertEqual(
            vulkan_workloads,
            self.module.REPO_ROOT
            / "bench/workloads/specialized/workloads.amd.vulkan.superset.json",
        )
        self.assertEqual(
            vulkan_manifest,
            self.module.REPO_ROOT
            / "browser/chromium/bench/generated/browser_projection_manifest.json",
        )

    def test_build_release_external_uses_end_user_optimized_gn_profile(self) -> None:
        text = BUILD_RELEASE_EXTERNAL.read_text(encoding="utf-8")

        self.assertIn("is_debug=false", text)
        self.assertIn("LOCAL_RELEASE_GN_ARGS", text)
        self.assertIn("OFFICIAL_RELEASE_GN_ARGS", text)
        self.assertIn('FAWN_CHROMIUM_RELEASE_PROFILE:-official', text)
        self.assertIn("is_official_build=false", text)
        self.assertIn("is_official_build=true", text)
        self.assertIn("dcheck_always_on=false", text)
        self.assertIn("chrome_pgo_phase=0", text)
        self.assertIn("symbol_level=0", text)
        self.assertIn("blink_symbol_level=0", text)
        self.assertIn("v8_symbol_level=0", text)
        self.assertIn("use_clang_modules=false", text)
        self.assertIn("FAWN_CHROMIUM_LOCAL_JOBS", text)
        self.assertIn("invalid FAWN_CHROMIUM_LOCAL_JOBS", text)

    def test_sync_release_artifacts_preserves_release_args_evidence(self) -> None:
        self.assertIn(
            'sync_entry "args.gn"',
            SYNC_RELEASE_ARTIFACTS_LOCAL.read_text(encoding="utf-8"),
        )
        self.assertIn(
            'sync_entry "fawn-release-build.json"',
            SYNC_RELEASE_ARTIFACTS_LOCAL.read_text(encoding="utf-8"),
        )

    def test_python_superset_runner_formats_score_with_both_sides_and_delta(self) -> None:
        line = self.module.format_score_line(
            {
                "overall": {
                    "baselineMode": "chrome",
                    "comparisonMode": "fawn",
                    "baselineScore": 55.799,
                    "comparisonScore": 44.2,
                    "comparisonDeltaPercent": -20.787,
                    "rowCount": 75,
                },
                "categoryBalancedOverall": {"comparisonDeltaPercent": -27.108},
            }
        )

        self.assertIn("chrome=55.80", line)
        self.assertIn("fawn=44.20", line)
        self.assertIn("delta=-20.79%", line)
        self.assertIn("category-balanced-delta=-27.11%", line)
        self.assertIn("rows=75", line)

    def test_python_superset_runner_classifies_browser_release_paths(self) -> None:
        self.assertEqual(
            self.module.browser_release_class(
                "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
            ),
            "stock_chrome_release",
        )
        self.assertEqual(
            self.module.browser_release_class("/Volumes/MACOS/fawn-browser/src/out/fawn_release/chrome"),
            "fawn_release",
        )
        self.assertEqual(
            self.module.browser_release_class("/Volumes/MACOS/fawn-browser/src/out/fawn_debug/chrome"),
            "fawn_debug",
        )

    def test_python_superset_runner_rejects_debug_browser_when_release_required(self) -> None:
        completed = subprocess.run(
            [
                sys.executable,
                str(SUPERSET_RUNNER),
                "--mode",
                "both",
                "--dawn-chrome",
                "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                "--doe-chrome",
                "/Volumes/MACOS/fawn-browser/src/out/fawn_debug/chrome",
                "--require-browser-release-class",
                "--dry-run",
            ],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertEqual(completed.returncode, 2)
        self.assertIn("browser release-class check failed", completed.stdout)
        self.assertIn("class=fawn_debug", completed.stdout)

    def test_python_superset_runner_rejects_fawn_release_without_args_when_required(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            chrome = root / "out/fawn_release/chrome"
            chrome.parent.mkdir(parents=True)
            chrome.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
            chrome.chmod(0o755)
            completed = subprocess.run(
                [
                    sys.executable,
                    str(SUPERSET_RUNNER),
                    "--mode",
                    "doe",
                    "--doe-chrome",
                    str(chrome),
                    "--require-browser-release-class",
                    "--dry-run",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )

        self.assertEqual(completed.returncode, 2)
        self.assertIn("missing release args evidence", completed.stdout)

    def test_python_superset_runner_rejects_fawn_release_debug_args_when_required(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            out_dir = root / "out/fawn_release"
            out_dir.mkdir(parents=True)
            chrome = out_dir / "chrome"
            chrome.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
            chrome.chmod(0o755)
            (out_dir / "args.gn").write_text(
                "is_debug = true\n"
                "is_official_build = false\n",
                encoding="utf-8",
            )
            completed = subprocess.run(
                [
                    sys.executable,
                    str(SUPERSET_RUNNER),
                    "--mode",
                    "doe",
                    "--doe-chrome",
                    str(chrome),
                    "--require-browser-release-class",
                    "--dry-run",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )

        self.assertEqual(completed.returncode, 2)
        self.assertIn("args mismatch", completed.stdout)
        self.assertIn("is_debug=true expected false", completed.stdout)

    def test_python_superset_runner_accepts_local_release_args_when_required(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            out_dir = root / "out/fawn_release"
            out_dir.mkdir(parents=True)
            chrome = out_dir / "chrome"
            chrome.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
            chrome.chmod(0o755)
            (out_dir / "args.gn").write_text(
                "\n".join(
                    [
                        "is_debug = false",
                        "is_official_build = false",
                        "dcheck_always_on = false",
                        "chrome_pgo_phase = 0",
                        "symbol_level = 0",
                        "blink_symbol_level = 0",
                        "v8_symbol_level = 0",
                        "is_chrome_for_testing = false",
                        "is_chrome_for_testing_branded = false",
                        "is_chrome_branded = false",
                        "use_clang_modules = false",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            args_hash = self.module.hashlib.sha256(
                (out_dir / "args.gn").read_text(encoding="utf-8").encode("utf-8")
            ).hexdigest()
            (out_dir / "fawn-release-build.json").write_text(
                json.dumps(
                    {
                        "target": "chrome",
                        "releaseProfile": "local",
                        "argsSha256": args_hash,
                    }
                ),
                encoding="utf-8",
            )
            completed = subprocess.run(
                [
                    sys.executable,
                    str(SUPERSET_RUNNER),
                    "--mode",
                    "doe",
                    "--doe-chrome",
                    str(chrome),
                    "--require-browser-release-class",
                    "--required-fawn-release-profile",
                    "local",
                    "--skip-run",
                    "--dry-run",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )

        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)

    def test_python_superset_runner_rejects_fawn_release_without_build_stamp(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            out_dir = root / "out/fawn_release"
            out_dir.mkdir(parents=True)
            chrome = out_dir / "chrome"
            chrome.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
            chrome.chmod(0o755)
            (out_dir / "args.gn").write_text(
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
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            completed = subprocess.run(
                [
                    sys.executable,
                    str(SUPERSET_RUNNER),
                    "--mode",
                    "doe",
                    "--doe-chrome",
                    str(chrome),
                    "--require-browser-release-class",
                    "--skip-run",
                    "--dry-run",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )

        self.assertEqual(completed.returncode, 2)
        self.assertIn("missing release build stamp", completed.stdout)

    def test_consumer_and_runtime_wrappers_require_release_class(self) -> None:
        self.assertIn(
            "--require-browser-release-class",
            RUN_CONSUMER_BENCH.read_text(encoding="utf-8"),
        )
        self.assertIn(
            'FAWN_CONSUMER_REQUIRED_FAWN_RELEASE_PROFILE:-official',
            RUN_CONSUMER_BENCH.read_text(encoding="utf-8"),
        )
        self.assertIn(
            '--required-fawn-release-profile "${required_fawn_release_profile}"',
            RUN_CONSUMER_BENCH.read_text(encoding="utf-8"),
        )
        self.assertIn(
            "--require-browser-release-class",
            RUN_FAWN_RUNTIME_BENCH.read_text(encoding="utf-8"),
        )
        self.assertIn(
            "--required-fawn-release-profile any",
            RUN_FAWN_RUNTIME_BENCH.read_text(encoding="utf-8"),
        )
        self.assertIn(
            "--mode-schedule paired-balanced",
            RUN_FAWN_RUNTIME_BENCH.read_text(encoding="utf-8"),
        )
        self.assertIn(
            "--strict-run",
            RUN_FAWN_RUNTIME_BENCH.read_text(encoding="utf-8"),
        )
        lane_defaults = RUN_WITH_LANE_DEFAULTS.read_text(encoding="utf-8")
        self.assertIn('FAWN_BACKEND_LANE="vulkan_doe_app"', lane_defaults)
        self.assertIn('FAWN_BACKEND_LANE="metal_doe_app"', lane_defaults)
        self.assertIn('FAWN_BACKEND_LANE="d3d12_doe_app"', lane_defaults)

    def test_shell_lane_candidates_prefer_full_webgpu_library(self) -> None:
        proc = subprocess.run(
            [
                "bash",
                "-c",
                f"source {LANE_PATHS}; fawn_default_doe_lib_candidates | head -1",
            ],
            check=True,
            capture_output=True,
            text=True,
        )

        self.assertIn("libwebgpu_doe_full.", proc.stdout.strip())

    def test_shell_lane_candidates_prefer_real_app_binary_before_launcher(self) -> None:
        proc = subprocess.run(
            [
                "bash",
                "-c",
                f"source {LANE_PATHS}; fawn_default_chrome_candidates | sed -n '2,3p'",
            ],
            check=True,
            capture_output=True,
            text=True,
        )

        lines = proc.stdout.strip().splitlines()
        self.assertGreaterEqual(len(lines), 2)
        self.assertTrue(lines[0].endswith("Fawn.app/Contents/MacOS/Chromium-real"))
        self.assertTrue(lines[1].endswith("Fawn.app/Contents/MacOS/Chromium"))

    def test_python_superset_runner_prefers_real_app_binary_before_launcher(self) -> None:
        old_root = self.module.REPO_ROOT
        old_env = os.environ.pop("FAWN_CHROME_BIN", None)
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                root = Path(tmpdir)
                app_dir = root / "browser/chromium/out/fawn_release_local/Fawn.app/Contents/MacOS"
                app_dir.mkdir(parents=True)
                launcher = app_dir / "Chromium"
                real = app_dir / "Chromium-real"
                launcher.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
                real.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
                launcher.chmod(0o755)
                real.chmod(0o755)
                self.module.REPO_ROOT = root

                self.assertEqual(self.module.default_chrome_binary(), real)
        finally:
            self.module.REPO_ROOT = old_root
            if old_env is not None:
                os.environ["FAWN_CHROME_BIN"] = old_env

    def test_playwright_runners_prefer_full_webgpu_library(self) -> None:
        for path in JS_RUNNERS:
            text = path.read_text(encoding="utf-8")
            full_index = text.index("libwebgpu_doe_full")
            compute_index = text.index("libwebgpu_doe.")
            self.assertLess(full_index, compute_index, str(path))

    def test_playwright_runners_prefer_real_app_binary_before_launcher(self) -> None:
        for path in JS_RUNNERS:
            text = path.read_text(encoding="utf-8")
            real_index = text.index('"Fawn.app/Contents/MacOS/Chromium-real"')
            launcher_index = text.index('"Fawn.app/Contents/MacOS/Chromium"')
            self.assertLess(real_index, launcher_index, str(path))

    def test_python_superset_runner_accepts_auto_without_doe_lib_dry_run(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            missing_lib = Path(tmpdir) / "missing-libwebgpu_doe_full.so"
            completed = subprocess.run(
                [
                    sys.executable,
                    str(SUPERSET_RUNNER),
                    "--mode",
                    "auto",
                    "--doe-lib",
                    str(missing_lib),
                    "--dry-run",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("--mode auto", completed.stdout)

    def test_python_superset_runner_forwards_layered_iteration_knobs(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            chrome = root / "chrome"
            doe_lib = root / "libwebgpu_doe_full.dylib"
            chrome.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
            chrome.chmod(0o755)
            doe_lib.write_text("", encoding="utf-8")
            completed = subprocess.run(
                [
                    sys.executable,
                    str(SUPERSET_RUNNER),
                    "--chrome",
                    str(chrome),
                    "--doe-lib",
                    str(doe_lib),
                    "--iters-upload",
                    "7",
                    "--iters-dispatch",
                    "8",
                    "--iters-render",
                    "9",
                    "--iters-pipeline",
                    "10",
                    "--iters-async-pipeline",
                    "11",
                    "--iters-workflow",
                    "12",
                    "--iters-texture",
                    "13",
                    "--mode-schedule",
                    "paired-balanced",
                    "--mode-schedule-repetitions",
                    "3",
                    "--dry-run",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("--iters-upload 7", completed.stdout)
        self.assertIn("--iters-workflow 12", completed.stdout)
        self.assertIn("--iters-texture 13", completed.stdout)
        self.assertIn("--mode-schedule-repetitions 3", completed.stdout)

    def test_shell_bench_wrapper_accepts_auto_without_doe_lib_dry_run(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            chrome = root / "chrome"
            missing_lib = root / "missing-libwebgpu_doe_full.so"
            chrome.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
            chrome.chmod(0o755)
            completed = subprocess.run(
                [
                    "bash",
                    str(REPO_ROOT / "browser/chromium/scripts/run-with-lane-defaults.sh"),
                    "bench",
                    "--mode",
                    "auto",
                    "--chrome",
                    str(chrome),
                    "--doe-lib",
                    str(missing_lib),
                    "--dry-run",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("--mode auto", completed.stdout)


if __name__ == "__main__":
    unittest.main()
