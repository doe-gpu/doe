#!/usr/bin/env python3
"""Tests for the wgpu benchmark adapter fail-closed behavior."""

from __future__ import annotations

import importlib.util
import tempfile
from pathlib import Path
from types import SimpleNamespace


REPO_ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = REPO_ROOT / "bench" / "native-compare" / "wgpu_benchmark_adapter.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("wgpu_benchmark_adapter", MODULE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load module: {MODULE_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _args(root: Path, runner: str) -> SimpleNamespace:
    commands = root / "commands.json"
    commands.write_text("{}", encoding="utf-8")
    return SimpleNamespace(
        commands=str(commands),
        trace_meta=str(root / "trace-meta.json"),
        trace_jsonl=str(root / "trace.jsonl"),
        api="vulkan",
        wgpu_runner=runner,
    )


def _write_runner(path: Path, body: str) -> None:
    path.write_text("#!/usr/bin/env python3\n" + body, encoding="utf-8")
    path.chmod(path.stat().st_mode | 0o111)


def test_missing_default_runner_fails_without_mock_output() -> None:
    module = _load_module()

    try:
        module.resolve_runner("definitely-missing-wgpu-runner")
    except FileNotFoundError as exc:
        assert "Mock trace generation is disabled" in str(exc)
    else:
        raise AssertionError("missing runner should fail")


def test_build_runner_command_is_explicit() -> None:
    module = _load_module()
    args = SimpleNamespace(
        commands="commands.json",
        trace_meta="meta.json",
        trace_jsonl="trace.jsonl",
        api="metal",
    )

    assert module.build_runner_command(args, "/bin/wgpu-runner") == [
        "/bin/wgpu-runner",
        "--commands",
        "commands.json",
        "--trace-meta",
        "meta.json",
        "--trace-jsonl",
        "trace.jsonl",
        "--api",
        "metal",
    ]


def test_real_runner_outputs_pass() -> None:
    module = _load_module()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        runner = root / "runner.py"
        _write_runner(
            runner,
            """
import argparse
p = argparse.ArgumentParser()
p.add_argument('--commands')
p.add_argument('--trace-meta')
p.add_argument('--trace-jsonl')
p.add_argument('--api')
args = p.parse_args()
open(args.trace_meta, 'w', encoding='utf-8').write('{}')
open(args.trace_jsonl, 'w', encoding='utf-8').write('')
""",
        )

        assert module.run_adapter(_args(root, str(runner))) == 0


def test_runner_without_outputs_fails() -> None:
    module = _load_module()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        runner = root / "runner.py"
        _write_runner(runner, "raise SystemExit(0)\n")

        try:
            module.run_adapter(_args(root, str(runner)))
        except FileNotFoundError as exc:
            assert "did not emit required output" in str(exc)
        else:
            raise AssertionError("runner without outputs should fail")


def test_command_payload_must_exist() -> None:
    module = _load_module()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        missing = root / "missing.json"

        try:
            module.validate_input_paths(str(missing))
        except FileNotFoundError as exc:
            assert "commands payload does not exist" in str(exc)
        else:
            raise AssertionError("missing commands payload should fail")
