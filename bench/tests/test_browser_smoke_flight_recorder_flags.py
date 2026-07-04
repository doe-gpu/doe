#!/usr/bin/env python3
"""Tests for browser smoke flight-recorder CLI wiring."""

from __future__ import annotations

import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SMOKE_SCRIPT = REPO_ROOT / "browser" / "chromium" / "scripts" / "webgpu-playwright-smoke.mjs"
COMPONENTS = REPO_ROOT / "examples" / "browser-gpu-flight-recorder.sample.json"


def run_smoke_args(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["node", str(SMOKE_SCRIPT), *args],
        cwd=REPO_ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def test_smoke_help_lists_flight_recorder_options() -> None:
    result = run_smoke_args("--help")

    assert result.returncode == 0
    assert "--flight-recorder-components PATH" in result.stdout
    assert "--flight-recorder-out PATH" in result.stdout
    assert "--flight-recorder-mode dawn|doe" in result.stdout
    assert "--shader-links-out PATH" in result.stdout
    assert "--runtime-selector-profile-vendor VENDOR" in result.stdout
    assert "--runtime-selector-profile-api API" in result.stdout
    assert "--runtime-selector-profile-device-family DEVICE" in result.stdout
    assert "--runtime-selector-profile-driver DRIVER" in result.stdout
    assert "--pipeline-cache-receipts-out PATH" in result.stdout
    assert "--fallback-explanations-out PATH" in result.stdout
    assert "--cts-subset-out PATH" in result.stdout


def test_smoke_requires_flight_recorder_components_and_output_together() -> None:
    result = run_smoke_args(
        "--flight-recorder-components",
        str(COMPONENTS),
    )

    assert result.returncode == 1
    assert "--flight-recorder-components and --flight-recorder-out must be provided together" in result.stderr


def test_smoke_rejects_flight_recorder_mode_outside_run_mode_before_launch() -> None:
    result = run_smoke_args(
        "--mode",
        "dawn",
        "--flight-recorder-components",
        str(COMPONENTS),
        "--flight-recorder-out",
        "/tmp/browser-flight-recorder.json",
        "--flight-recorder-mode",
        "doe",
    )

    assert result.returncode == 1
    assert "--flight-recorder-mode doe is not included in --mode dawn" in result.stderr


def test_smoke_requires_shader_links_to_use_flight_recorder_output() -> None:
    result = run_smoke_args(
        "--shader-links-out",
        "/tmp/browser-shader-links.json",
    )

    assert result.returncode == 1
    assert "--shader-links-out requires --flight-recorder-out" in result.stderr


def test_smoke_requires_pipeline_cache_receipts_to_use_local_ai_output() -> None:
    result = run_smoke_args(
        "--pipeline-cache-receipts-out",
        "/tmp/browser-pipeline-cache-receipts.json",
    )

    assert result.returncode == 1
    assert "--pipeline-cache-receipts-out requires --local-ai-workloads-out" in result.stderr


def test_smoke_rejects_fallback_explanations_mode_outside_run_mode_before_launch() -> None:
    result = run_smoke_args(
        "--mode",
        "dawn",
        "--fallback-explanations-out",
        "/tmp/browser-fallback-explanations.json",
        "--fallback-explanations-mode",
        "doe",
    )

    assert result.returncode == 1
    assert "--fallback-explanations-mode doe is not included in --mode dawn" in result.stderr


def test_smoke_requires_cts_subset_to_run_both_modes() -> None:
    result = run_smoke_args(
        "--mode",
        "doe",
        "--cts-subset-out",
        "/tmp/browser-cts-subset.json",
    )

    assert result.returncode == 1
    assert "--cts-subset-out requires --mode both" in result.stderr
