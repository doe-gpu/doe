#!/usr/bin/env python3
"""Build the independent fixed-sample Monte Carlo CPU reference artifact."""

from __future__ import annotations

import argparse
import hashlib
import shutil
import subprocess
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SOURCE_PATH = REPO_ROOT / "bench/oracles/monte_carlo_reference_v1.c"
DEFAULT_OUTPUT_PATH = REPO_ROOT / (
    "bench/oracles/data/"
    "monte_carlo_fixed_samples_131072paths_256samples_8bounces.f32le.bin"
)
EXPECTED_SHA256 = "f47066faec78e7459a09529f45ef9a09c1dd538e6688176599e545e915f78818"


def file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build_reference(*, compiler: str, output_path: Path) -> None:
    """Compile and run the standalone CPU model into ``output_path``."""
    compiler_path = shutil.which(compiler)
    if compiler_path is None:
        raise FileNotFoundError(f"C compiler not found: {compiler}")
    with tempfile.TemporaryDirectory(prefix="doe-monte-carlo-reference-") as raw:
        temporary_root = Path(raw)
        executable_path = temporary_root / "monte-carlo-reference"
        generated_path = temporary_root / "monte-carlo-reference.f32le.bin"
        subprocess.run(
            [
                compiler_path,
                "-std=c11",
                "-O3",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-ffp-contract=off",
                "-fno-fast-math",
                "-fopenmp",
                str(SOURCE_PATH),
                "-lm",
                "-o",
                str(executable_path),
            ],
            check=True,
        )
        subprocess.run([str(executable_path), str(generated_path)], check=True)
        generated_sha256 = file_sha256(generated_path)
        if EXPECTED_SHA256 and generated_sha256 != EXPECTED_SHA256:
            raise ValueError(
                "monte-carlo reference output changed: "
                f"expected {EXPECTED_SHA256}, received {generated_sha256}"
            )
        output_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(generated_path, output_path)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cc", default="cc", help="C compiler executable.")
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT_PATH,
        help="Generated little-endian float32 reference path.",
    )
    parser.add_argument(
        "--verify",
        action="store_true",
        help="Build independently and verify the existing output without replacing it.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.verify:
        if not EXPECTED_SHA256:
            raise ValueError("EXPECTED_SHA256 must be frozen before verification")
        if not args.output.exists():
            raise FileNotFoundError(f"reference output not found: {args.output}")
        with tempfile.TemporaryDirectory(prefix="doe-monte-carlo-verify-") as raw:
            generated_path = Path(raw) / args.output.name
            build_reference(compiler=args.cc, output_path=generated_path)
            if generated_path.read_bytes() != args.output.read_bytes():
                raise ValueError(
                    f"reference output is stale: regenerate {args.output}"
                )
    else:
        build_reference(compiler=args.cc, output_path=args.output)
    print(f"{file_sha256(args.output)}  {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
