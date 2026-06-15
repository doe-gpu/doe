"""Shared scaffolding for plan-executor regression tests.

Used by test_dawn_native_plan_executor, test_doe_direct_plan_executor, and
test_webgpu_plan_executor. Handles the zig build + subprocess + trace
artifact read pattern that all three tests share.
"""

from __future__ import annotations

import json
import subprocess
import unittest
from pathlib import Path
from typing import Any, Sequence


REPO_ROOT = Path(__file__).resolve().parents[2]
RUNTIME_DIR = REPO_ROOT / "runtime" / "zig"
PLAN_PATH = (
    REPO_ROOT / "bench" / "plans" / "generated" / "inference_gemma3_270m_prefill_32tok.plan.json"
)
EXPECTED_PLAN_SHA256 = "0d3316fab695566c11da52e44bdfcbaa366d082c8d9449802f32dd423a23b981"
DEFAULT_WORKLOAD = "inference_gemma3_270m_prefill_32tok"


def build_target(target: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["zig", "build", target],
        cwd=RUNTIME_DIR,
        capture_output=True,
        text=True,
        check=False,
    )


def build_target_or_skip_on_missing_dawn_header(target: str) -> None:
    """Build a target; skip the test if the local Chromium checkout is missing."""
    result = build_target(target)
    if result.returncode == 0:
        return
    if "dawn/webgpu.h" in result.stderr and "file not found" in result.stderr:
        raise unittest.SkipTest(
            f"{target} build prerequisite missing: local Chromium header"
            " checkout does not provide dawn/webgpu.h"
        )
    raise AssertionError(result.stderr)


def executor_bin(name: str) -> Path:
    return RUNTIME_DIR / "zig-out" / "bin" / name


def run_plan_executor(
    bin_path: Path,
    *,
    tmpdir: Path,
    workload: str = DEFAULT_WORKLOAD,
    dry_run: bool = True,
    plan_path: Path = PLAN_PATH,
    extra_args: Sequence[str] = (),
) -> subprocess.CompletedProcess[str]:
    args: list[str] = [
        str(bin_path),
        "--plan",
        str(plan_path),
        "--trace-meta",
        str(tmpdir / "trace-meta.json"),
        "--trace-jsonl",
        str(tmpdir / "trace.jsonl"),
        "--workload",
        workload,
    ]
    args.extend(extra_args)
    if dry_run:
        args.append("--dry-run")
    return subprocess.run(args, cwd=REPO_ROOT, capture_output=True, text=True, check=False)


def read_trace_artifacts(tmpdir: Path) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    meta = json.loads((tmpdir / "trace-meta.json").read_text(encoding="utf-8"))
    rows = [
        json.loads(line)
        for line in (tmpdir / "trace.jsonl").read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    return meta, rows
