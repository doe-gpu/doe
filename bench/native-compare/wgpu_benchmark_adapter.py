#!/usr/bin/env python3
"""Adapter entrypoint for real wgpu benchmark runner integration."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="wgpu benchmark adapter for Doe workloads")
    parser.add_argument("--commands", required=True, help="Path to Doe JSON commands payload")
    parser.add_argument("--trace-meta", required=True, help="Output path for trace metadata")
    parser.add_argument("--trace-jsonl", required=True, help="Output path for Chrome tracing format")
    parser.add_argument(
        "--api",
        default="vulkan",
        choices=["vulkan", "metal", "dx12"],
        help="WebGPU backend API",
    )
    parser.add_argument(
        "--wgpu-runner",
        default="wgpu-runner",
        help="Path or PATH-resolved name of the real wgpu execution harness",
    )
    return parser.parse_args()


def resolve_runner(runner: str) -> str:
    if not runner.strip():
        raise ValueError("--wgpu-runner must be non-empty")
    runner_path = Path(runner)
    if runner_path.is_absolute() or runner_path.parent != Path("."):
        if not runner_path.exists():
            raise FileNotFoundError(f"wgpu runner does not exist: {runner}")
        if not runner_path.is_file():
            raise ValueError(f"wgpu runner is not a file: {runner}")
        return str(runner_path)
    resolved = shutil.which(runner)
    if resolved is None:
        raise FileNotFoundError(
            f"wgpu runner not found on PATH: {runner}. "
            "Mock trace generation is disabled; provide a real runner."
        )
    return resolved


def validate_input_paths(commands_path: str) -> None:
    commands = Path(commands_path)
    if not commands.exists():
        raise FileNotFoundError(f"commands payload does not exist: {commands_path}")
    if not commands.is_file():
        raise ValueError(f"commands payload is not a file: {commands_path}")


def build_runner_command(args: argparse.Namespace, runner_path: str) -> list[str]:
    return [
        runner_path,
        "--commands",
        args.commands,
        "--trace-meta",
        args.trace_meta,
        "--trace-jsonl",
        args.trace_jsonl,
        "--api",
        args.api,
    ]


def require_runner_outputs(trace_meta: str, trace_jsonl: str) -> None:
    missing = [
        path
        for path in (Path(trace_meta), Path(trace_jsonl))
        if not path.exists() or not path.is_file()
    ]
    if missing:
        joined = ", ".join(str(path) for path in missing)
        raise FileNotFoundError(f"wgpu runner did not emit required output file(s): {joined}")


def run_adapter(args: argparse.Namespace) -> int:
    validate_input_paths(args.commands)
    runner_path = resolve_runner(args.wgpu_runner)
    Path(args.trace_meta).parent.mkdir(parents=True, exist_ok=True)
    Path(args.trace_jsonl).parent.mkdir(parents=True, exist_ok=True)
    command = build_runner_command(args, runner_path)
    result = subprocess.run(command, check=False)
    if result.returncode != 0:
        return result.returncode
    require_runner_outputs(args.trace_meta, args.trace_jsonl)
    return 0


def main() -> int:
    try:
        return run_adapter(parse_args())
    except (OSError, ValueError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
