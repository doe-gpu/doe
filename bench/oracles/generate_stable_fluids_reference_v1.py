#!/usr/bin/env python3
"""Build the independent stable-fluids CPU reference artifact."""

from __future__ import annotations

import argparse
import hashlib
import shutil
import subprocess
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SOURCE_PATH = REPO_ROOT / "bench/oracles/stable_fluids_reference_v1.c"
DEFAULT_OUTPUT_PATH = REPO_ROOT / (
    "bench/oracles/data/"
    "stable_fluids_multistage_256grid_18pressure_4steps.f32le.bin"
)
EXPECTED_SHA256 = "0f173a647dcc8235045e7fa74f4a2da99a6c290cf5e0092498a3e2c582c5a1a3"


def file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build_reference(*, compiler: str, output_path: Path) -> None:
    """Compile and run the standalone CPU model into ``output_path``."""
    compiler_path = shutil.which(compiler)
    if compiler_path is None:
        raise FileNotFoundError(f"C compiler not found: {compiler}")
    with tempfile.TemporaryDirectory(prefix="doe-stable-fluids-reference-") as raw:
        temporary_root = Path(raw)
        executable_path = temporary_root / "stable-fluids-reference"
        generated_path = temporary_root / "stable-fluids-reference.f32le.bin"
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
                str(SOURCE_PATH),
                "-o",
                str(executable_path),
            ],
            check=True,
        )
        subprocess.run([str(executable_path), str(generated_path)], check=True)
        generated_sha256 = file_sha256(generated_path)
        if generated_sha256 != EXPECTED_SHA256:
            raise ValueError(
                "stable-fluids reference output changed: "
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
        if not args.output.exists():
            raise FileNotFoundError(f"reference output not found: {args.output}")
        with tempfile.TemporaryDirectory(prefix="doe-stable-fluids-verify-") as raw:
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
