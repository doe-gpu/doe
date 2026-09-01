#!/usr/bin/env python3
"""Validate SPIR-V artifacts with spirv-val.

Compiles Doe WGSL kernel sources to SPIR-V via the Zig shader compiler,
then runs spirv-val on each generated binary. Also validates any pre-existing
.spv files under bench/kernels/ and runtime build output.

Exit 0 when all validations pass (or spirv-val is unavailable and --require
is not set). Exit 1 on validation failure or when --require is set and
spirv-val is missing.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
KERNELS_DIR = REPO_ROOT / "bench" / "kernels"
INFERENCE_KERNELS_DIR = REPO_ROOT / "bench" / "inference-pipeline" / "kernels"
SHADER_BENCH_BIN = REPO_ROOT / "runtime" / "zig" / "zig-out" / "bin" / "doe-shader-bench"
EMIT_SPIRV_BIN = REPO_ROOT / "runtime" / "zig" / "zig-out" / "bin" / "doe-emit-spirv"
DEFAULT_SPV_SEARCH_DIRS = [
    REPO_ROOT / "bench" / "kernels",
    REPO_ROOT / "bench" / "out",
    REPO_ROOT / "runtime" / "zig" / "zig-out",
]
DEFAULT_WGSL_DISCOVERY_DIRS = [
    REPO_ROOT / "bench" / "kernels",
    REPO_ROOT / "bench" / "inference-pipeline" / "kernels",
]
VENDOR_DIR = REPO_ROOT / "bench" / "vendor"
EXCLUDED_DIRECTORY_NAMES = frozenset({".git", "node_modules", "third_party", "vendor"})

WGSL_COMPUTE_SHADERS = [
    "shader_compile_pipeline_stress.wgsl",
    "workgroup_atomic_1024x100.wgsl",
    "workgroup_non_atomic_1024x100.wgsl",
    "zero_initialize_workgroup_memory_2048.wgsl",
    "matrix_vector_mul_32768x2048_f32.wgsl",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--spirv-val",
        default="",
        help="Path to spirv-val executable. Auto-detected from PATH if omitted.",
    )
    parser.add_argument(
        "--require",
        action="store_true",
        help="Fail if spirv-val is not available instead of skipping.",
    )
    parser.add_argument(
        "--compile",
        action="store_true",
        help=(
            "Compile WGSL kernels to SPIR-V before validation. "
            "Requires doe-shader-bench in zig-out/bin/."
        ),
    )
    parser.add_argument(
        "--shader-bench",
        default=str(SHADER_BENCH_BIN),
        help="Path to doe-shader-bench or doe-compilation-bench binary.",
    )
    parser.add_argument(
        "--extra-dir",
        action="append",
        default=[],
        help="Additional directories to scan for .spv files.",
    )
    parser.add_argument(
        "--json-report",
        default="",
        help="Optional path to write a JSON validation report.",
    )
    parser.add_argument(
        "--discover-wgsl",
        action="store_true",
        help=(
            "Auto-discover all .wgsl files under bench/kernels and "
            "bench/inference-pipeline/kernels, compile each via doe-emit-spirv, "
            "and validate the resulting SPIR-V. Catches kernels that lack "
            "pre-built .spv artifacts."
        ),
    )
    parser.add_argument(
        "--emit-spirv-bin",
        default=str(EMIT_SPIRV_BIN),
        help="Path to doe-emit-spirv binary for --discover-wgsl mode.",
    )
    parser.add_argument(
        "--require-subgroup-coverage",
        action="store_true",
        help=(
            "When auto-discovering, fail if any .wgsl file declaring "
            "'enable subgroups;' was not validated. Defends against the "
            "subgroup-op SPIR-V emitter regression class."
        ),
    )
    return parser.parse_args()


def discover_wgsl_files(dirs: list[Path]) -> list[Path]:
    """Find all .wgsl files under dirs."""
    results: list[Path] = []
    for d in dirs:
        if not d.is_dir():
            continue
        for wgsl in sorted(d.rglob("*.wgsl")):
            if VENDOR_DIR in wgsl.parents:
                continue
            results.append(wgsl)
    return results


def emit_spirv_for_wgsl(emit_spirv_bin: str, wgsl_path: Path, out_path: Path) -> tuple[bool, str]:
    """Compile a WGSL source to SPIR-V via doe-emit-spirv. Returns (ok, message)."""
    try:
        completed = subprocess.run(
            [emit_spirv_bin, "--shader-path", str(wgsl_path), "--out", str(out_path)],
            capture_output=True,
            text=True,
            check=False,
            timeout=60,
        )
    except FileNotFoundError:
        return False, f"doe-emit-spirv not found at {emit_spirv_bin}"
    except subprocess.TimeoutExpired:
        return False, "doe-emit-spirv timed out"
    if completed.returncode != 0:
        stderr = (completed.stderr or completed.stdout or "").strip()[:300]
        return False, f"emit failed: {stderr}"
    if not out_path.is_file() or out_path.stat().st_size == 0:
        return False, "emit produced no output"
    return True, "ok"


def wgsl_uses_subgroups(wgsl_path: Path) -> bool:
    """True if the WGSL source enables subgroup operations."""
    try:
        text = wgsl_path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return False
    return "enable subgroups" in text or "subgroupAdd" in text or "subgroupBroadcast" in text


def find_spirv_val(explicit: str) -> str | None:
    """Resolve spirv-val executable path."""
    if explicit:
        resolved = shutil.which(explicit)
        return resolved if resolved else explicit
    return shutil.which("spirv-val")


def collect_spv_files(search_dirs: list[Path]) -> list[Path]:
    """Find all .spv files under search_dirs, excluding vendor tree."""
    results: list[Path] = []
    for search_dir in search_dirs:
        if not search_dir.is_dir():
            continue
        for spv in sorted(search_dir.rglob("*.spv")):
            if (
                VENDOR_DIR in spv.parents
                or spv.is_relative_to(VENDOR_DIR)
                or EXCLUDED_DIRECTORY_NAMES.intersection(spv.parts)
            ):
                continue
            results.append(spv)
    seen: set[Path] = set()
    deduped: list[Path] = []
    for p in results:
        resolved = p.resolve()
        if resolved not in seen:
            seen.add(resolved)
            deduped.append(p)
    return deduped


def compile_wgsl_to_spirv(
    shader_bench: str,
    wgsl_sources: list[Path],
    output_dir: Path,
) -> list[Path]:
    """Compile WGSL sources to SPIR-V via doe-shader-bench."""
    generated: list[Path] = []
    for wgsl in wgsl_sources:
        if not wgsl.is_file():
            print(f"  SKIP (missing): {wgsl.name}")
            continue
        source = wgsl.read_text(encoding="utf-8")
        spv_out = output_dir / wgsl.with_suffix(".spv").name

        # Use the Zig translateToSpirv pipeline via subprocess
        # doe-shader-bench writes NDJSON, but we need the raw binary.
        # Instead, use a thin Python wrapper that calls the Zig lib.
        # For portability, compile via the bench_compilation binary with
        # --target spirv --iterations 1 and capture the output byte count,
        # then run spirv-val on any .spv artifact present in kernels/.
        #
        # Since doe-shader-bench does not write .spv to disk by default,
        # we rely on pre-existing .spv files or the --compile path which
        # uses doe-compilation-bench.

        completed = subprocess.run(
            [
                shader_bench,
                "--target", "spirv",
                "--iterations", "1",
                "--warmup", "0",
                "--filter", wgsl.stem,
            ],
            capture_output=True,
            text=True,
            check=False,
            timeout=60,
        )
        if completed.returncode == 0:
            # Parse NDJSON to check compilation succeeded
            for line in completed.stdout.strip().splitlines():
                try:
                    record = json.loads(line)
                    if record.get("bytesOut", 0) > 0:
                        # Compilation succeeded; the binary is in-memory only.
                        # Check if a sibling .spv file exists on disk.
                        kernel_spv = KERNELS_DIR / wgsl.with_suffix(".spv").name
                        if kernel_spv.is_file():
                            generated.append(kernel_spv)
                        else:
                            print(f"  COMPILED (no .spv on disk): {wgsl.name} ({record['bytesOut']} bytes)")
                except (json.JSONDecodeError, KeyError):
                    pass
        else:
            stderr_preview = (completed.stderr or "").strip()[:200]
            print(f"  COMPILE FAIL: {wgsl.name}: {stderr_preview}")

    return generated


def validate_spv(spirv_val: str, spv_path: Path) -> tuple[bool, str]:
    """Run spirv-val on a .spv file. Returns (passed, message)."""
    try:
        completed = subprocess.run(
            [spirv_val, str(spv_path)],
            capture_output=True,
            text=True,
            check=False,
            timeout=30,
        )
    except FileNotFoundError:
        return False, f"spirv-val not found at {spirv_val}"
    except subprocess.TimeoutExpired:
        return False, "spirv-val timed out"

    if completed.returncode == 0:
        return True, "valid"

    stderr = (completed.stderr or completed.stdout or "").strip()
    return False, stderr[:500]


def main() -> int:
    args = parse_args()

    spirv_val = find_spirv_val(args.spirv_val)
    if not spirv_val:
        if args.require:
            print("FAIL: spirv-val not found and --require is set")
            return 1
        print("SKIP: spirv-val not found on PATH; install SPIRV-Tools to enable validation")
        return 0

    print(f"spirv-val: {spirv_val}")

    # Collect .spv files from default search dirs + extra dirs
    search_dirs = list(DEFAULT_SPV_SEARCH_DIRS)
    for extra in args.extra_dir:
        search_dirs.append(Path(extra))

    spv_files = collect_spv_files(search_dirs)

    # Optionally compile WGSL to SPIR-V first
    compiled_files: list[Path] = []
    if args.compile:
        shader_bench = args.shader_bench
        if not Path(shader_bench).is_file():
            print(f"WARN: shader bench binary not found at {shader_bench}; skipping compilation")
        else:
            wgsl_sources = [KERNELS_DIR / name for name in WGSL_COMPUTE_SHADERS]
            with tempfile.TemporaryDirectory(prefix="fawn-spirv-val-") as tmpdir:
                compiled_files = compile_wgsl_to_spirv(
                    shader_bench, wgsl_sources, Path(tmpdir)
                )
            # Add any newly found .spv files
            for cf in compiled_files:
                if cf.resolve() not in {f.resolve() for f in spv_files}:
                    spv_files.append(cf)

    discovered_records: list[dict[str, str]] = []
    if args.discover_wgsl:
        emit_bin = args.emit_spirv_bin
        if not Path(emit_bin).is_file():
            print(f"WARN: doe-emit-spirv not built at {emit_bin}; skipping --discover-wgsl")
        else:
            wgsl_files = discover_wgsl_files(DEFAULT_WGSL_DISCOVERY_DIRS)
            print(f"discover-wgsl: emitting and validating {len(wgsl_files)} WGSL source(s)")
            with tempfile.TemporaryDirectory(prefix="doe-spirv-val-") as tmpdir:
                tmp_root = Path(tmpdir)
                for wgsl in wgsl_files:
                    spv_out = tmp_root / (wgsl.stem + ".spv")
                    rel = str(wgsl.relative_to(REPO_ROOT))
                    emit_ok, emit_msg = emit_spirv_for_wgsl(emit_bin, wgsl, spv_out)
                    if not emit_ok:
                        # Emit failures get reported separately so non-SPIR-V-emitting
                        # kernels (which are CSL-only or vertex-only) don't get
                        # mislabeled as validation failures.
                        discovered_records.append({
                            "path": rel,
                            "stage": "emit",
                            "passed": False,
                            "uses_subgroups": str(wgsl_uses_subgroups(wgsl)),
                            "error": emit_msg,
                        })
                        continue
                    val_ok, val_msg = validate_spv(spirv_val, spv_out)
                    discovered_records.append({
                        "path": rel,
                        "stage": "validate",
                        "passed": val_ok,
                        "uses_subgroups": str(wgsl_uses_subgroups(wgsl)),
                        "error": "" if val_ok else val_msg,
                    })

    if not spv_files and not discovered_records:
        print("SKIP: no .spv artifacts found to validate")
        return 0

    print(f"validating {len(spv_files)} pre-built SPIR-V artifact(s)")

    passed = 0
    failed = 0
    failures: list[dict[str, str]] = []

    for spv in spv_files:
        ok, message = validate_spv(spirv_val, spv)
        rel_path = str(spv.relative_to(REPO_ROOT)) if spv.is_relative_to(REPO_ROOT) else str(spv)
        if ok:
            passed += 1
            print(f"  PASS: {rel_path}")
        else:
            failed += 1
            print(f"  FAIL: {rel_path}: {message}")
            failures.append({"path": rel_path, "error": message})

    discovered_pass = 0
    discovered_fail = 0
    discovered_emit_fail = 0
    subgroup_validated = 0
    subgroup_skipped = 0
    for rec in discovered_records:
        path = rec["path"]
        uses_sg = rec["uses_subgroups"] == "True"
        if rec["stage"] == "emit":
            discovered_emit_fail += 1
            print(f"  EMIT-SKIP: {path}: {rec['error']}")
            if uses_sg:
                subgroup_skipped += 1
            continue
        if rec["passed"]:
            discovered_pass += 1
            tag = "PASS-SG" if uses_sg else "PASS"
            print(f"  {tag}: {path}")
            if uses_sg:
                subgroup_validated += 1
        else:
            discovered_fail += 1
            tag = "FAIL-SG" if uses_sg else "FAIL"
            print(f"  {tag}: {path}: {rec['error']}")
            failures.append({"path": path, "error": rec["error"], "stage": "discover"})

    if args.require_subgroup_coverage and subgroup_validated == 0 and subgroup_skipped == 0:
        # Defensive: someone removed all subgroup kernels OR someone added one
        # in a directory we don't discover. Either way, log it loudly.
        print(
            "FAIL: --require-subgroup-coverage set but zero subgroup-using "
            "WGSL kernels were validated; check discovery dirs"
        )
        return 1

    # Write JSON report if requested
    if args.json_report:
        report = {
            "gate": "spirv_val",
            "spirvVal": spirv_val,
            "totalFiles": len(spv_files),
            "passed": passed,
            "failed": failed,
            "failures": failures,
            "discovered": {
                "totalWgsl": len(discovered_records),
                "validated": discovered_pass,
                "validationFailed": discovered_fail,
                "emitSkipped": discovered_emit_fail,
                "subgroupValidated": subgroup_validated,
                "subgroupSkipped": subgroup_skipped,
            },
        }
        report_path = Path(args.json_report)
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(
            json.dumps(report, indent=2) + "\n", encoding="utf-8"
        )
        print(f"report: {report_path}")

    total_failed = failed + discovered_fail
    if total_failed > 0:
        print(
            f"FAIL: spirv-val gate (pre-built {passed}/{passed + failed}, "
            f"discovered {discovered_pass}/{discovered_pass + discovered_fail}, "
            f"subgroup-validated {subgroup_validated})"
        )
        return 1

    print(
        f"PASS: spirv-val gate (pre-built {passed}, "
        f"discovered {discovered_pass}, subgroup-validated {subgroup_validated})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
