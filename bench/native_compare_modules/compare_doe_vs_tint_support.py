"""Support helpers for compare_doe_vs_tint_compilation.py."""

from __future__ import annotations

import argparse
import datetime
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from bench.lib.adhoc_claim_gating import (
    CLAIM_REPORT_SCHEMA_VERSION,
    DELTA_PERCENT_CONVENTION,
    ClaimPolicy,
    DeltaPercentiles,
    aggregate_claim_status,
    gate_workload_claim,
)
from bench.lib.hash_utils import file_sha256
from bench.native_compare_modules.reporting import (
    format_stats,
    subtract_baseline_ms,
)


REPO_ROOT = Path(__file__).resolve().parents[2]
TARGET_MAP = {"msl": "msl", "spirv": "spv", "hlsl": "hlsl"}
TINT_BENCHMARK_TARGET_MAP = {"msl": "GenerateMSL", "spirv": "GenerateSPIRV", "hlsl": "GenerateHLSL"}
DEFAULT_TINT_WARM_MIN_TIME = "0.01s"
DEFAULT_TINT_WARM_REPETITIONS = 9
CLAIMABLE_REQUIRED_PHASES = ("parse", "sema", "lower", "emit", "total")
_TINT_STARTUP_BASELINE_WGSL = """@compute @workgroup_size(1)
fn main() {}
"""


def repo_relative(path):
    try:
        return str(Path(path).resolve().relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def command_version(command, fallback):
    try:
        proc = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return fallback
    if proc.returncode != 0:
        return fallback
    text = "\n".join(part.strip() for part in (proc.stdout, proc.stderr) if part.strip())
    return text.splitlines()[0].strip() if text else fallback


def git_revision():
    try:
        proc = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=REPO_ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        return proc.stdout.strip()
    except subprocess.CalledProcessError:
        return "unknown"


def normalize_schema_target(target):
    if target == "spv":
        return "spirv"
    if target == "spirv":
        return "spirv"
    if target in {"msl", "hlsl", "dxil"}:
        return target
    return target


def infer_shader_stage(shader_path):
    try:
        source = Path(shader_path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return "mixed"
    stages = []
    for marker, stage in (
        ("@compute", "compute"),
        ("@vertex", "vertex"),
        ("@fragment", "fragment"),
    ):
        if marker in source:
            stages.append(stage)
    return stages[0] if len(stages) == 1 else "mixed"


def _run_tint_samples(tint_bin, tint_format, shader_path, total_runs, warmup):
    samples = []
    for i in range(total_runs):
        start = time.perf_counter_ns()
        proc = subprocess.run(
            [str(tint_bin), f"--format={tint_format}", shader_path],
            capture_output=True,
        )
        elapsed = time.perf_counter_ns() - start

        if proc.returncode != 0:
            raise RuntimeError(proc.stderr.decode()[:200])

        if i >= warmup:
            samples.append(elapsed)
    return samples


def ns_stats(samples):
    if not samples:
        return {
            "p50_ns": 0,
            "p95_ns": 0,
            "p99_ns": 0,
            "min_ns": 0,
            "max_ns": 0,
            "mean_ns": 0,
            "iterations": 0,
        }

    ordered = sorted(int(sample) for sample in samples)

    def percentile(p):
        index = int((len(ordered) - 1) * p)
        return ordered[index]

    return {
        "p50_ns": percentile(0.50),
        "p95_ns": percentile(0.95),
        "p99_ns": percentile(0.99),
        "min_ns": ordered[0],
        "max_ns": ordered[-1],
        "mean_ns": sum(ordered) // len(ordered),
        "iterations": len(ordered),
    }


def duration_to_ns(value, unit):
    if value is None:
        return None
    scale = {
        "ns": 1.0,
        "us": 1_000.0,
        "ms": 1_000_000.0,
        "s": 1_000_000_000.0,
    }.get(unit)
    if scale is None:
        return None
    return int(float(value) * scale)


def measure_tint_startup_baseline(tint_bin, tint_format, iterations, warmup, dry_run):
    total_runs = iterations + warmup
    if dry_run:
        print(f"[dry-run] tint startup-baseline --format={tint_format} x{total_runs}")
        return {"p50_ns": 0, "p95_ns": 0, "p99_ns": 0, "min_ns": 0, "max_ns": 0, "mean_ns": 0, "iterations": 0}

    with tempfile.TemporaryDirectory(prefix="doe-tint-startup-") as tmpdir:
        shader_path = Path(tmpdir) / "startup-baseline.wgsl"
        shader_path.write_text(_TINT_STARTUP_BASELINE_WGSL, encoding="utf-8")
        samples = _run_tint_samples(tint_bin, tint_format, str(shader_path), total_runs, warmup)
    stats_ms = format_stats([sample / 1_000_000.0 for sample in samples])
    return {
        "p50_ns": int(stats_ms["p50Ms"] * 1_000_000.0),
        "p95_ns": int(stats_ms["p95Ms"] * 1_000_000.0),
        "p99_ns": int(stats_ms["p99Ms"] * 1_000_000.0),
        "min_ns": int(stats_ms["minMs"] * 1_000_000.0),
        "max_ns": int(stats_ms["maxMs"] * 1_000_000.0),
        "mean_ns": int(stats_ms["meanMs"] * 1_000_000.0),
        "iterations": int(stats_ms["count"]),
    }


def run_tint_bench(cfg, shaders, target, iterations, warmup, dry_run):
    """Time Tint compilation for each shader in the corpus."""
    tint_bin = REPO_ROOT / cfg["comparison"]["binaryPath"]
    tint_format = TARGET_MAP.get(target, target)

    if not tint_bin.exists() and not dry_run:
        print(f"error: Tint binary not found: {tint_bin}", file=sys.stderr)
        print(
            "  Build Dawn in Release mode, then copy tint binary to the configured path.",
            file=sys.stderr,
        )
        sys.exit(1)

    results = {}
    total_runs = iterations + warmup
    startup_baseline = measure_tint_startup_baseline(
        tint_bin,
        tint_format,
        iterations,
        warmup,
        dry_run,
    )
    startup_baseline_p50_ns = startup_baseline.get("p50_ns", 0)
    tint_warm_results = run_tint_warm_bench(cfg, shaders, target, dry_run)

    for shader in shaders:
        if dry_run:
            print(f"[dry-run] tint --format={tint_format} {shader['path']} x{total_runs}")
            results[shader["name"]] = {
                "p50_ns": 0,
                "p95_ns": 0,
                "p99_ns": 0,
                "startupBaseline": startup_baseline,
                "startupCorrected": {"p50_ns": 0, "p95_ns": 0, "p99_ns": 0},
                "warm": tint_warm_results.get(shader["name"], {"p50_ns": 0, "p95_ns": 0, "p99_ns": 0}),
            }
            continue

        try:
            samples = _run_tint_samples(
                tint_bin,
                tint_format,
                shader["path"],
                total_runs,
                warmup,
            )
        except RuntimeError as exc:
            print(
                f"  warning: tint failed on {shader['name']}: {str(exc)[:200]}",
                file=sys.stderr,
            )
            samples = []

        if not samples:
            print(f"  skipping {shader['name']}: no successful timed samples", file=sys.stderr)
            continue

        samples.sort()
        corrected_samples = subtract_baseline_ms(
            [sample / 1_000_000.0 for sample in samples],
            startup_baseline_p50_ns / 1_000_000.0,
        )
        corrected_stats_ms = format_stats(corrected_samples)
        n = len(samples)
        results[shader["name"]] = {
            "p50_ns": samples[n // 2],
            "p95_ns": samples[int(n * 0.95)],
            "p99_ns": samples[min(int(n * 0.99), n - 1)],
            "min_ns": samples[0],
            "max_ns": samples[-1],
            "mean_ns": sum(samples) // n,
            "iterations": n,
            "timingNote": "process-level timing includes tint startup overhead",
            "startupBaseline": startup_baseline,
            "startupCorrected": {
                "p50_ns": int(corrected_stats_ms["p50Ms"] * 1_000_000.0),
                "p95_ns": int(corrected_stats_ms["p95Ms"] * 1_000_000.0),
                "p99_ns": int(corrected_stats_ms["p99Ms"] * 1_000_000.0),
                "timingNote": "raw tint process-wall samples with the trivial-shader baseline p50 subtracted",
            },
            "warm": tint_warm_results.get(shader["name"], {}),
        }

    return results


def run_tint_warm_bench(cfg, shaders, target, dry_run):
    warm_binary_path = cfg["comparison"].get("warmBinaryPath")
    if not warm_binary_path:
        return {}

    benchmark_prefix = TINT_BENCHMARK_TARGET_MAP.get(target)
    if benchmark_prefix is None:
        print(f"error: Tint warm benchmark target is unsupported for {target}", file=sys.stderr)
        sys.exit(1)

    warm_bin = REPO_ROOT / warm_binary_path
    if not warm_bin.exists() and not dry_run:
        print(f"error: Tint warm benchmark binary not found: {warm_bin}", file=sys.stderr)
        print("  Build with: ninja -C bench/vendor/dawn/out/Release tint_benchmark", file=sys.stderr)
        sys.exit(1)

    repetitions = int(cfg["run"].get("warmRepetitions", DEFAULT_TINT_WARM_REPETITIONS))
    min_time = cfg["run"].get("warmMinTime", DEFAULT_TINT_WARM_MIN_TIME)

    if dry_run:
        for shader in shaders:
            benchmark_name = preferred_tint_warm_benchmark_name(shader)
            command = build_tint_warm_command(
                warm_bin,
                benchmark_prefix,
                benchmark_name,
                min_time,
                repetitions,
            )
            print(f"[dry-run] {' '.join(command)}")
        return {
            shader["name"]: {
                "p50_ns": 0,
                "p95_ns": 0,
                "p99_ns": 0,
                "timingNote": "in-process tint_benchmark real_time samples",
            }
            for shader in shaders
        }

    results = {}
    for shader in shaders:
        benchmark_name = preferred_tint_warm_benchmark_name(shader)
        command = build_tint_warm_command(
            warm_bin,
            benchmark_prefix,
            benchmark_name,
            min_time,
            repetitions,
        )
        proc = subprocess.run(command, check=False, capture_output=True, text=True)
        if proc.returncode != 0:
            diagnostic = (proc.stderr or proc.stdout or "tint_benchmark failed").strip()
            print(
                f"  warning: tint_benchmark failed on {shader['name']}: {diagnostic[:200]}",
                file=sys.stderr,
            )
            continue
        try:
            payload = parse_google_benchmark_json(proc.stdout)
        except ValueError as exc:
            print(
                f"  warning: tint_benchmark JSON parse failed on {shader['name']}: {exc}",
                file=sys.stderr,
            )
            continue

        aliases = tint_warm_benchmark_aliases(shader)
        samples = []
        for benchmark in payload.get("benchmarks", []):
            if benchmark.get("run_type") != "iteration":
                continue
            name = benchmark.get("name", "")
            if not name.startswith(f"{benchmark_prefix}/"):
                continue
            short_name = name.split("/", 1)[1]
            if short_name not in aliases:
                continue
            sample_ns = duration_to_ns(benchmark.get("real_time"), benchmark.get("time_unit"))
            if sample_ns is not None:
                samples.append(sample_ns)
        if not samples:
            continue
        result = ns_stats(samples)
        result["timingNote"] = "in-process tint_benchmark real_time samples"
        results[shader["name"]] = result
    return results


def build_tint_warm_command(warm_bin, benchmark_prefix, benchmark_name, min_time, repetitions):
    return [
        str(warm_bin),
        f"--benchmark_filter=^{benchmark_prefix}/{google_benchmark_filter_literal(benchmark_name)}$",
        f"--benchmark_min_time={min_time}",
        f"--benchmark_repetitions={repetitions}",
        "--benchmark_report_aggregates_only=false",
        "--benchmark_format=json",
    ]


def google_benchmark_filter_literal(value):
    special = set(".+*?^$()[]{}|\\")
    return "".join(f"\\{char}" if char in special else char for char in str(value))


def parse_google_benchmark_json(text):
    start = text.find("{")
    if start < 0:
        raise ValueError("missing JSON object")
    return json.loads(text[start:])


def preferred_tint_warm_benchmark_name(shader):
    benchmark_name = str(shader.get("benchmarkName", "")).strip()
    if benchmark_name:
        return benchmark_name
    workload_id = str(shader.get("workloadId", "")).strip()
    if workload_id:
        return f"{workload_id}.wgsl"
    path_name = Path(str(shader.get("path", ""))).name
    return path_name or str(shader["name"])


def tint_warm_benchmark_aliases(shader):
    aliases = {
        str(shader.get("name", "")).strip(),
        str(shader.get("benchmarkName", "")).strip(),
    }
    path_name = Path(str(shader.get("path", ""))).name
    if path_name:
        aliases.add(path_name)
    workload_id = str(shader.get("workloadId", "")).strip()
    if workload_id:
        aliases.add(workload_id)
        aliases.add(f"{workload_id}.wgsl")
    return {alias for alias in aliases if alias}


def build_tint_warm_alias_map(shaders):
    alias_to_shader = {}
    collisions = {}
    for shader in shaders:
        shader_name = shader["name"]
        for alias in tint_warm_benchmark_aliases(shader):
            existing = alias_to_shader.get(alias)
            if existing and existing != shader_name:
                collisions.setdefault(alias, {existing}).add(shader_name)
                continue
            alias_to_shader[alias] = shader_name
    if collisions:
        details = ", ".join(
            f"{alias}: {sorted(names)}" for alias, names in sorted(collisions.items())
        )
        raise RuntimeError(f"ambiguous Tint warm benchmark aliases: {details}")
    return alias_to_shader


def build_claim_report(
    *,
    cfg,
    shaders,
    target,
    records,
    calibration,
    claim_mode,
):
    """Build a claim-report alongside the comparison ndjson."""
    policy = ClaimPolicy.for_mode(claim_mode)
    required_pcts = [f"warm.{pct}" for pct in policy.required_positive_percentiles]
    timer_overhead_ns = int(calibration.get("timerOverheadP50Ns", 0)) if calibration else 0
    workloads = []

    for record in records:
        if record.get("status") != "compared":
            workloads.append(
                {
                    "shader": record.get("shader"),
                    "claimable": False,
                    "reasons": [f"row not compared: {record.get('reason', record.get('status'))}"],
                    "requiredPositivePercentiles": required_pcts,
                }
            )
            continue

        comparison = record.get("comparison", {})
        baseline = record.get("baseline", {})
        warm = comparison.get("warm", {})
        warm_iterations = int(warm.get("iterations", 0) or 0)
        comparison_iterations = int(comparison.get("iterations", 0) or 0)
        baseline_iterations = int(
            baseline.get("iterations") or cfg["run"].get("iterations", 0) or 0
        )
        warm_delta = record.get("warmDeltaPercent", {})
        smallest_measurement_candidates = [
            value for value in (baseline.get("p50_ns"), warm.get("p50_ns")) if value
        ]
        smallest_measurement_p50_ns = (
            int(min(smallest_measurement_candidates))
            if smallest_measurement_candidates
            else None
        )
        delta_percent = DeltaPercentiles(
            p50=warm_delta.get("p50"),
            p95=warm_delta.get("p95"),
            p99=warm_delta.get("p99"),
        )
        gate = gate_workload_claim(
            shader=str(record.get("shader", "")),
            baseline_sample_count=baseline_iterations,
            comparison_sample_count=comparison_iterations or warm_iterations,
            warm_comparison_sample_count=warm_iterations,
            delta_percent=delta_percent,
            policy=policy,
            timer_overhead_p50_ns=timer_overhead_ns or None,
            smallest_measurement_p50_ns=smallest_measurement_p50_ns,
            extra_details={
                "requiredPositivePercentiles": required_pcts,
                "warmDeltaPercent": warm_delta,
                "warmIterations": warm_iterations,
                "doeP50Ns": baseline.get("p50_ns"),
                "tintWarmP50Ns": warm.get("p50_ns"),
            },
        )
        if not warm or not warm_iterations:
            gate["reasons"].insert(0, "no warm in-process Tint samples (config lacks warmBinaryPath)")
            gate["claimable"] = False
        workloads.append(gate)

    claim_status, claim_pass, aggregate_reasons = aggregate_claim_status(workloads)

    doe_bin_path = REPO_ROOT / cfg["baseline"]["binaryPath"]
    tint_bin_path = REPO_ROOT / cfg["comparison"]["binaryPath"]
    warm_bin_path = (
        REPO_ROOT / cfg["comparison"].get("warmBinaryPath")
        if cfg["comparison"].get("warmBinaryPath")
        else None
    )
    claim_policy = policy.to_dict(timer_overhead_p50_ns=timer_overhead_ns)
    claim_policy["requiredPositivePercentiles"] = required_pcts
    claim_policy["deltaPercentConvention"] = DELTA_PERCENT_CONVENTION

    return {
        "schemaVersion": CLAIM_REPORT_SCHEMA_VERSION,
        "artifactKind": "claim-report",
        "generatedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "claimMode": claim_mode,
        "claimPolicy": claim_policy,
        "compareConfigPath": str(cfg.get("_configPath", "")),
        "target": target,
        "binaryProvenance": {
            "doe": {
                "path": str(doe_bin_path),
                "sha256": file_sha256(doe_bin_path) if doe_bin_path.exists() else "",
            },
            "tint": {
                "path": str(tint_bin_path),
                "sha256": file_sha256(tint_bin_path) if tint_bin_path.exists() else "",
            },
            "tintWarm": {
                "path": str(warm_bin_path) if warm_bin_path else "",
                "sha256": (
                    file_sha256(warm_bin_path)
                    if warm_bin_path and warm_bin_path.exists()
                    else ""
                ),
            },
        },
        "timingScopeSymmetry": {
            "doe": "std.time.Timer per-translation in-process",
            "tintWarm": "Google Benchmark real_time per-iteration in-process (tint_benchmark)",
            "equivalent": True,
            "notes": (
                "both sides measure per-iteration in-process compile cost; "
                "Doe per-iteration timer overhead is reported in claimPolicy."
                "timerOverheadP50Ns and gated by claimPolicy.timerOverheadBudgetPercent"
            ),
        },
        "comparisonStatus": "comparable",
        "claimStatus": claim_status,
        "pass": claim_pass,
        "reasons": aggregate_reasons,
        "workloads": workloads,
    }


def build_toolchain_info(cfg, args):
    doe_emit_path = REPO_ROOT / args.doe_emit_binary
    tint_path = REPO_ROOT / cfg["comparison"]["binaryPath"]
    tint_warm_path = (
        REPO_ROOT / cfg["comparison"].get("warmBinaryPath")
        if cfg["comparison"].get("warmBinaryPath")
        else None
    )
    revision = git_revision()
    return {
        "doe": {
            "name": "doe-wgsl",
            "version": command_version([str(doe_emit_path), "--version"], revision)
            if doe_emit_path.is_file()
            else "missing",
            "command": [repo_relative(doe_emit_path), "--emit-msl"],
            "sourceRevision": revision,
            "artifactPath": repo_relative(doe_emit_path) if doe_emit_path.exists() else "",
            "artifactSha256": file_sha256(doe_emit_path) if doe_emit_path.is_file() else None,
        },
        "tint": {
            "name": "tint",
            "version": command_version([str(tint_path), "--version"], "dawn-vendor")
            if tint_path.is_file()
            else "missing",
            "command": [repo_relative(tint_path), "--format=msl"],
            "sourceRevision": "dawn-vendor",
            "artifactPath": repo_relative(tint_path) if tint_path.exists() else "",
            "artifactSha256": file_sha256(tint_path) if tint_path.is_file() else None,
        },
        "tintWarm": {
            "name": "tint-benchmark",
            "version": "dawn-vendor" if tint_warm_path and tint_warm_path.is_file() else "missing",
            "command": (
                [repo_relative(tint_warm_path), "--benchmark_format=json"]
                if tint_warm_path
                else ["tint_benchmark"]
            ),
            "sourceRevision": "dawn-vendor",
            "artifactPath": (
                repo_relative(tint_warm_path)
                if tint_warm_path and tint_warm_path.exists()
                else ""
            ),
            "artifactSha256": (
                file_sha256(tint_warm_path)
                if tint_warm_path and tint_warm_path.is_file()
                else None
            ),
        },
    }


def build_claimability(record, claim_workload, comparable):
    delta = {}
    if record:
        delta = record.get("warmDeltaPercent") or record.get("deltaPercent") or {}
    claim_reasons = []
    if not comparable:
        claim_reasons.append("row is not comparable")
    if not record or record.get("status") != "compared":
        claim_reasons.append(f"row not compared: {record.get('reason', 'missing record') if record else 'missing record'}")
    if not record or not record.get("comparison", {}).get("warm", {}).get("p50_ns"):
        claim_reasons.append("missing in-process Tint warm timing evidence")
    if claim_workload:
        claim_reasons.extend(str(reason) for reason in claim_workload.get("reasons", []))
        if not claim_workload.get("claimable"):
            claim_reasons.append("legacy claim gate did not mark the row claimable")
    else:
        claim_reasons.append("missing claim gate workload result")

    deduped_reasons = []
    for reason in claim_reasons:
        if reason and reason not in deduped_reasons:
            deduped_reasons.append(reason)

    if comparable and claim_workload and claim_workload.get("claimable") and not deduped_reasons:
        return {
            "status": "claimable",
            "reasons": [],
            "deltaPercent": {
                "p50": delta.get("p50"),
                "p95": delta.get("p95"),
                "p99": delta.get("p99"),
            },
        }
    return {
        "status": "diagnostic",
        "reasons": deduped_reasons or ["row is diagnostic"],
        "deltaPercent": {
            "p50": delta.get("p50"),
            "p95": delta.get("p95"),
            "p99": delta.get("p99"),
        },
    }


def missing_phase_timings(result, required_phases):
    if result.get("status") != "ok":
        return []
    timings = result.get("phaseTimingsNs")
    if not isinstance(timings, dict):
        return list(required_phases)
    missing = []
    for phase in required_phases:
        value = timings.get(phase)
        if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
            missing.append(phase)
    return missing


def build_row_comparability(record, doe_result, tint_result, required_phases=None):
    required_phases = tuple(required_phases or ("total",))
    reasons = []
    if not record or record.get("status") != "compared":
        reasons.append(f"row not compared: {record.get('reason', 'missing record') if record else 'missing record'}")
    if doe_result.get("status") != "ok":
        reasons.append(f"doe evidence status: {doe_result.get('diagnosticCode') or doe_result.get('status')}")
    if tint_result.get("status") != "ok":
        reasons.append(f"tint evidence status: {tint_result.get('diagnosticCode') or tint_result.get('status')}")
    if record and not record.get("comparison", {}).get("warm", {}).get("p50_ns"):
        reasons.append("missing in-process Tint warm timing evidence")
    for phase in missing_phase_timings(doe_result, required_phases):
        reasons.append(f"doe missing phase timing: {phase}")
    for phase in missing_phase_timings(tint_result, required_phases):
        reasons.append(f"tint missing phase timing: {phase}")

    deduped_reasons = []
    for reason in reasons:
        if reason and reason not in deduped_reasons:
            deduped_reasons.append(reason)
    if not deduped_reasons:
        return {"status": "comparable", "reasons": []}
    return {"status": "diagnostic", "reasons": deduped_reasons}


def required_tool_gaps(cfg):
    gaps = []
    checks = [
        ("doe", REPO_ROOT / cfg["baseline"]["binaryPath"], "missing_doe_bench_binary"),
        ("tint", REPO_ROOT / cfg["comparison"]["binaryPath"], "missing_tint_binary"),
    ]
    warm_binary_path = cfg["comparison"].get("warmBinaryPath")
    if warm_binary_path:
        checks.append(("tintWarm", REPO_ROOT / warm_binary_path, "missing_tint_warm_binary"))
    for name, path, code in checks:
        if not path.is_file():
            gaps.append({"name": name, "path": str(path), "code": code})
    return gaps


def source_gaps_for_config(cfg):
    gaps = []
    script_path = cfg.get("tintBenchmarkInputsScriptPath")
    if script_path:
        path = REPO_ROOT / script_path
        if not path.is_file():
            gaps.append(
                {
                    "name": "tintBenchmarkInputsScript",
                    "path": str(path),
                    "code": "missing_tint_benchmark_input_script",
                }
            )
    return gaps


def evidence_args_for_target(args, target, targets):
    if not args.evidence_out or len(targets) == 1:
        return args
    cloned = argparse.Namespace(**vars(args))
    evidence_out = Path(args.evidence_out)
    cloned.evidence_out = str(evidence_out.with_name(f"{evidence_out.stem}.{target}{evidence_out.suffix}"))
    return cloned
