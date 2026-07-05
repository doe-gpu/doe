"""Compilation-surface runners for isolated and paired benchmark flows."""

from __future__ import annotations

import json
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any, Callable

from native_compare_modules import reporting as reporting_mod
from native_compare_modules.reporting import median_sample, subtract_baseline_ms

VALID_COMPILATION_TARGETS = {"msl", "hlsl", "spirv"}
TINT_FORMAT_MAP = {"msl": "msl", "hlsl": "hlsl", "spirv": "spv"}
_TINT_STARTUP_BASELINE_CACHE: dict[tuple[str, str, int, int], list[float]] = {}
_TINT_STARTUP_BASELINE_WGSL = """@compute @workgroup_size(1)
fn main() {}
"""

ParseCompilationNdjsonFn = Callable[[Path, str], dict[str, Any]]
TintCompileSamplesFn = Callable[[Path, Path, str, int, int], list[float]]
TintStartupBaselineSamplesFn = Callable[[Path, str, int, int], list[float]]


def _parse_compilation_ndjson(path: Path, shader_name: str) -> dict[str, Any]:
    if not path.exists():
        return {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if (
            record.get("kind") == "compilation_bench"
            and record.get("shader") == shader_name
        ):
            return record
    return {}


def _tint_compile_samples(
    tint_bin: Path,
    shader_path: Path,
    target: str,
    iterations: int,
    warmup: int,
) -> list[float]:
    tint_format = TINT_FORMAT_MAP.get(target, target)
    total_runs = warmup + iterations
    samples: list[float] = []
    for run_index in range(total_runs):
        start = time.perf_counter()
        proc = subprocess.run(
            [str(tint_bin), f"--format={tint_format}", str(shader_path)],
            capture_output=True,
            check=False,
        )
        elapsed_ms = (time.perf_counter() - start) * 1000.0
        if proc.returncode != 0:
            raise RuntimeError(
                f"tint compilation failed for {shader_path.name}: "
                f"{proc.stderr.decode('utf-8', errors='replace')[:300]}"
            )
        if run_index >= warmup:
            samples.append(elapsed_ms)
    return samples


def _tint_startup_baseline_samples(
    tint_bin: Path,
    target: str,
    iterations: int,
    warmup: int,
) -> list[float]:
    cache_key = (str(tint_bin), target, iterations, warmup)
    cached = _TINT_STARTUP_BASELINE_CACHE.get(cache_key)
    if cached is not None:
        return list(cached)
    with tempfile.TemporaryDirectory(prefix="doe-tint-startup-") as tmpdir:
        shader_path = Path(tmpdir) / "startup-baseline.wgsl"
        shader_path.write_text(_TINT_STARTUP_BASELINE_WGSL, encoding="utf-8")
        samples = _tint_compile_samples(
            tint_bin,
            shader_path,
            target,
            iterations,
            warmup,
        )
    _TINT_STARTUP_BASELINE_CACHE[cache_key] = list(samples)
    return list(samples)


def _shader_tier(shader_path: Path) -> str:
    normalized = str(shader_path).replace("\\", "/")
    if "/bench/inference-pipeline/kernels/" in normalized:
        return "inference"
    return "external"


def _validate_target(workload: Any, target: str) -> None:
    if target not in VALID_COMPILATION_TARGETS:
        raise ValueError(
            f"invalid compilation target {target!r} for workload {workload.id}: "
            f"expected one of {sorted(VALID_COMPILATION_TARGETS)}"
        )


def _doe_compilation_result(
    *,
    workload: Any,
    iterations: int,
    warmup: int,
    out_dir: Path,
    doe_compilation_bin: str,
    parse_compilation_ndjson: ParseCompilationNdjsonFn = _parse_compilation_ndjson,
) -> dict[str, Any]:
    shader_path = Path(workload.shader_path)
    shader_name = workload.id
    target = workload.compilation_target or "msl"
    _validate_target(workload, target)
    doe_out = out_dir / "doe.compilation.ndjson"
    doe_bin_path = Path(doe_compilation_bin)
    if not doe_bin_path.exists():
        raise RuntimeError(
            f"Doe compilation binary not found: {doe_compilation_bin}. "
            "Build with: cd runtime/zig && zig build bench-compilation"
        )
    doe_cmd = [
        str(doe_bin_path),
        "--target",
        target,
        "--iterations",
        str(iterations),
        "--warmup",
        str(warmup),
        "--shader-path",
        str(shader_path),
        "--shader-name",
        shader_name,
        "--shader-tier",
        _shader_tier(shader_path),
        "--out",
        str(doe_out),
    ]
    subprocess.run(doe_cmd, check=True)
    doe_record = parse_compilation_ndjson(doe_out, shader_name)
    doe_p50_ms = float(doe_record.get("p50_ns", 0)) / 1_000_000.0
    doe_trace_meta = {
        "runnerType": "compilation",
        "compiler": "doe_wgsl",
        "shader": shader_name,
        "target": target,
        "p50_ns": doe_record.get("p50_ns", 0),
        "p95_ns": doe_record.get("p95_ns", 0),
        "p99_ns": doe_record.get("p99_ns", 0),
        "bytesOut": doe_record.get("bytesOut", 0),
        "executionDispatchCount": 1,
        "executionRowCount": 1,
        "executionSuccessCount": 1,
    }
    meta_path = out_dir / "doe.meta.json"
    meta_path.write_text(
        json.dumps(doe_trace_meta, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    return {
        "commandSamples": [],
        "stats": reporting_mod.format_stats([doe_p50_ms]),
        "timingsMs": [doe_p50_ms],
        "lastMeta": doe_trace_meta,
        "timingSources": ["compilation-bench-in-process"],
        "timingClasses": ["operation"],
    }


def _tint_compilation_result(
    *,
    workload: Any,
    iterations: int,
    warmup: int,
    out_dir: Path,
    tint_bin: str,
    tint_compile_samples: TintCompileSamplesFn = _tint_compile_samples,
    tint_startup_baseline_samples: TintStartupBaselineSamplesFn = _tint_startup_baseline_samples,
) -> dict[str, Any]:
    shader_path = Path(workload.shader_path)
    shader_name = workload.id
    target = workload.compilation_target or "msl"
    _validate_target(workload, target)
    tint_bin_path = Path(tint_bin)
    if not tint_bin_path.exists():
        raise RuntimeError(
            f"Tint binary not found: {tint_bin}. "
            "Build Dawn in Release mode and place tint at the configured path."
        )
    tint_samples = tint_compile_samples(
        tint_bin_path,
        shader_path,
        target,
        iterations,
        warmup,
    )
    startup_baseline_samples = tint_startup_baseline_samples(
        tint_bin_path,
        target,
        iterations,
        warmup,
    )
    startup_baseline_stats = reporting_mod.format_stats(startup_baseline_samples)
    startup_baseline_p50_ms = median_sample(startup_baseline_samples)
    startup_corrected_samples = subtract_baseline_ms(
        tint_samples,
        startup_baseline_p50_ms,
    )
    startup_corrected_stats = reporting_mod.format_stats(startup_corrected_samples)
    tint_trace_meta = {
        "runnerType": "compilation",
        "compiler": "tint",
        "shader": shader_name,
        "target": target,
        "timingNote": (
            "process-level timing includes tint startup overhead; "
            "compare report publishes raw process-wall stats plus a "
            "startup-corrected view that subtracts the trivial-shader "
            "baseline p50 from each raw sample"
        ),
        "executionDispatchCount": 1,
        "executionRowCount": 1,
        "executionSuccessCount": 1,
    }
    meta_path = out_dir / "tint.meta.json"
    meta_path.write_text(
        json.dumps(tint_trace_meta, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    return {
        "commandSamples": [],
        "stats": reporting_mod.format_stats(tint_samples),
        "timingsMs": tint_samples,
        "lastMeta": tint_trace_meta,
        "timingSources": ["compilation-process-wall"],
        "timingClasses": ["process-wall"],
        "startupBaselineStatsMs": startup_baseline_stats,
        "startupCorrectionMethod": "subtract-trivial-shader-baseline-p50",
        "startupCorrectedStatsMs": startup_corrected_stats,
    }


def _compilation_product_kind(product: str) -> str:
    normalized = product.strip().lower()
    if "doe" in normalized:
        return "doe"
    if "tint" in normalized or "dawn" in normalized:
        return "tint"
    raise ValueError(
        f"unsupported compilation product {product!r}: "
        "expected a Doe or Tint/Dawn product label"
    )


def run_compilation_product_workload(
    *,
    product: str,
    workload: Any,
    iterations: int,
    warmup: int,
    out_dir: Path,
    doe_compilation_bin: str,
    tint_bin: str,
    parse_compilation_ndjson: ParseCompilationNdjsonFn = _parse_compilation_ndjson,
    tint_compile_samples: TintCompileSamplesFn = _tint_compile_samples,
    tint_startup_baseline_samples: TintStartupBaselineSamplesFn = _tint_startup_baseline_samples,
) -> dict[str, Any]:
    out_dir.mkdir(parents=True, exist_ok=True)
    product_kind = _compilation_product_kind(product)
    if product_kind == "doe":
        return _doe_compilation_result(
            workload=workload,
            iterations=iterations,
            warmup=warmup,
            out_dir=out_dir,
            doe_compilation_bin=doe_compilation_bin,
            parse_compilation_ndjson=parse_compilation_ndjson,
        )
    return _tint_compilation_result(
        workload=workload,
        iterations=iterations,
        warmup=warmup,
        out_dir=out_dir,
        tint_bin=tint_bin,
        tint_compile_samples=tint_compile_samples,
        tint_startup_baseline_samples=tint_startup_baseline_samples,
    )


def run_compilation_workload(
    workload: Any,
    iterations: int,
    warmup: int,
    out_dir: Path,
    doe_compilation_bin: str,
    tint_bin: str,
    *,
    parse_compilation_ndjson: ParseCompilationNdjsonFn = _parse_compilation_ndjson,
    tint_compile_samples: TintCompileSamplesFn = _tint_compile_samples,
    tint_startup_baseline_samples: TintStartupBaselineSamplesFn = _tint_startup_baseline_samples,
) -> dict[str, Any]:
    out_dir.mkdir(parents=True, exist_ok=True)
    return {
        "baseline": run_compilation_product_workload(
            product="doe",
            workload=workload,
            iterations=iterations,
            warmup=warmup,
            out_dir=out_dir / "baseline",
            doe_compilation_bin=doe_compilation_bin,
            tint_bin=tint_bin,
            parse_compilation_ndjson=parse_compilation_ndjson,
            tint_compile_samples=tint_compile_samples,
            tint_startup_baseline_samples=tint_startup_baseline_samples,
        ),
        "comparison": run_compilation_product_workload(
            product="tint",
            workload=workload,
            iterations=iterations,
            warmup=warmup,
            out_dir=out_dir / "comparison",
            doe_compilation_bin=doe_compilation_bin,
            tint_bin=tint_bin,
            parse_compilation_ndjson=parse_compilation_ndjson,
            tint_compile_samples=tint_compile_samples,
            tint_startup_baseline_samples=tint_startup_baseline_samples,
        ),
    }
