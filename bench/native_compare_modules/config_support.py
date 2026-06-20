"""Config and workload helpers for the compare lane."""

from __future__ import annotations

import argparse
import json
import shlex
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Sequence

from native_compare_modules.reporting import parse_int

DEFAULT_WORKLOADS_PATH = "bench/workloads/specialized/workloads.generic.json"
DEFAULT_BASELINE_NAME = "doe"
DEFAULT_COMPARISON_NAME = "dawn"
DEFAULT_BASELINE_EXECUTOR_ID = ""
DEFAULT_COMPARISON_EXECUTOR_ID = ""
DEFAULT_BASELINE_COMMAND_TEMPLATE = (
    "runtime/zig/zig-out/bin/doe-zig-runtime "
    "--commands {commands} --quirks {quirks} "
    "--vendor {vendor} --api {api} --family {family} --driver {driver} "
    "--trace --trace-jsonl {trace_jsonl} --trace-meta {trace_meta} {extra_args}"
)
DEFAULT_ITERATIONS = 3
DEFAULT_WARMUP = 1
DEFAULT_OUT_PATH = "bench/out/dawn-vs-doe.json"
DEFAULT_WORKSPACE_PATH = "bench/out/runtime-comparisons"
DEFAULT_WORKLOAD_FILTER = ""
DEFAULT_WORKLOAD_COHORT = "all"
DEFAULT_COMPARABILITY_MODE = "strict"
DEFAULT_REQUIRED_TIMING_CLASS = "operation"
DEFAULT_RESOURCE_PROBE = "none"
DEFAULT_RESOURCE_SAMPLE_MS = 100
DEFAULT_RESOURCE_SAMPLE_TARGET_COUNT = 0
DEFAULT_WORKLOAD_COOLDOWN_MS = 0
DEFAULT_CLAIMABILITY_MODE = "off"
DEFAULT_CLAIM_MIN_TIMED_SAMPLES = 0
DEFAULT_BENCHMARK_POLICY_PATH = ""
DEFAULT_BENCHMARK_POLICY_CANDIDATES = (
    "config/benchmark-methodology-thresholds.json",
)
VALID_COMPARABILITY_MODES = {"strict", "warn", "off"}
VALID_REQUIRED_TIMING_CLASSES = {"any", "operation", "process-wall"}
VALID_RESOURCE_PROBES = {"none", "rocm-smi"}
VALID_CLAIMABILITY_MODES = {"off", "local", "release"}
VALID_UPLOAD_BUFFER_USAGES = {"copy-dst-copy-src", "copy-dst"}
VALID_WORKLOAD_COHORTS = {"all", "comparability-candidates", "doe-advantage"}
VALID_DIRECTIONAL_REASONS = {
    "dawn_limit",
    "dawn_missing_contract",
    "dawn_no_execution",
    "different_compiler_codebases",
    "different_runtime_stacks_random_weights",
    "implementation_gap",
    "path_asymmetry",
    "host_instability",
    "methodology_gap",
    "timing_scope_audit_pending",
    "other",
}
NON_APPLES_TO_APPLES_DOMAINS = {
    "pipeline-async",
    "p1-capability",
    "p1-resource-table",
    "p1-capability-macro",
    "p2-lifecycle",
    "p2-lifecycle-macro",
    "p0-resource",
    "p0-compute",
    "p0-render",
    "surface",
}
FAWN_UPLOAD_RUNTIME_SOURCE_PATHS = (
    Path("runtime/zig/src/main.zig"),
    Path("runtime/zig/src/execution.zig"),
    Path("runtime/zig/src/wgpu_commands.zig"),
    Path("runtime/zig/src/webgpu_ffi.zig"),
)
NATIVE_EXECUTION_OPERATION_TIMING_SOURCES = {
    "doe-execution-total-ns",
    "doe-execution-workload-total-ns",
    "doe-execution-dispatch-window-ns",
    "doe-execution-encode-ns",
    "doe-execution-gpu-timestamp-ns",
}
KNOWN_GPU_BACKENDS = {"vulkan", "metal", "d3d12", "webgpu"}
GPU_BACKEND_ALIASES = {
    "dx12": "d3d12",
    "direct3d12": "d3d12",
}
HOST_ALLOWED_GPU_BACKENDS = {
    "darwin": {"metal", "webgpu"},
    "linux": {"vulkan", "webgpu"},
    "windows": {"vulkan", "d3d12", "webgpu"},
}

@dataclass(frozen=True)
class Workload:
    id: str
    name: str
    description: str
    domain: str
    comparability_notes: str
    commands_path: str
    quirks_path: str
    vendor: str
    api: str
    family: str
    driver: str
    extra_args: list[str]
    baseline_command_repeat: int
    comparison_command_repeat: int
    baseline_ignore_first_ops: int
    comparison_ignore_first_ops: int
    baseline_upload_buffer_usage: str
    comparison_upload_buffer_usage: str
    baseline_upload_submit_every: int
    comparison_upload_submit_every: int
    dawn_filter: str
    comparable: bool
    benchmark_class: str
    directional_reason: str
    allow_baseline_no_execution: bool
    include_by_default: bool
    baseline_timing_divisor: float
    comparison_timing_divisor: float
    timing_normalization_note: str
    async_diagnostics_mode: str
    comparability_candidate: bool
    comparability_candidate_tier: str
    comparability_candidate_notes: str
    path_asymmetry: bool
    path_asymmetry_note: str
    strict_normalization_unit: str
    cohorts: list[str] = field(default_factory=lambda: ["exploration"])
    claim_eligible: bool = True
    runner_type: str = "zig-runtime"
    ir_path: str = ""
    plan_path: str = ""
    # compilation runner fields
    shader_path: str = ""
    compilation_target: str = ""

    def to_spec_and_configs(
        self,
        baseline_product: str = "doe",
        comparison_product: str = "dawn",
    ) -> tuple:
        """Split workload contract into WorkloadSpec + per-product configs.

        Returns (WorkloadSpec, dict[str, ProductRunConfig]).
        """
        from native_compare_modules.workload_spec import ProductRunConfig, WorkloadSpec

        spec = WorkloadSpec(
            id=self.id,
            name=self.name,
            description=self.description,
            domain=self.domain,
            commands_path=self.commands_path,
            quirks_path=self.quirks_path,
            vendor=self.vendor,
            api=self.api,
            family=self.family,
            driver=self.driver,
            extra_args=list(self.extra_args),
            comparable=self.comparable,
            benchmark_class=self.benchmark_class,
            comparability_notes=self.comparability_notes,
            directional_reason=self.directional_reason,
            path_asymmetry=self.path_asymmetry,
            path_asymmetry_note=self.path_asymmetry_note,
            strict_normalization_unit=self.strict_normalization_unit,
            include_by_default=self.include_by_default,
            comparability_candidate_enabled=self.comparability_candidate,
            comparability_candidate_tier=self.comparability_candidate_tier,
            comparability_candidate_notes=self.comparability_candidate_notes,
            cohorts=list(self.cohorts),
            claim_eligible=self.claim_eligible,
            runner_type=self.runner_type,
            ir_path=self.ir_path,
            plan_path=self.plan_path,
            shader_path=self.shader_path,
            compilation_target=self.compilation_target,
            async_diagnostics_mode=self.async_diagnostics_mode,
        )
        configs = {
            baseline_product: ProductRunConfig(
                product=baseline_product,
                command_repeat=self.baseline_command_repeat,
                ignore_first_ops=self.baseline_ignore_first_ops,
                upload_buffer_usage=self.baseline_upload_buffer_usage,
                upload_submit_every=self.baseline_upload_submit_every,
                timing_divisor=self.baseline_timing_divisor,
                allow_no_execution=self.allow_baseline_no_execution,
                dawn_filter=self.dawn_filter if baseline_product == "dawn" else "",
                timing_normalization_note=self.timing_normalization_note,
            ),
            comparison_product: ProductRunConfig(
                product=comparison_product,
                command_repeat=self.comparison_command_repeat,
                ignore_first_ops=self.comparison_ignore_first_ops,
                upload_buffer_usage=self.comparison_upload_buffer_usage,
                upload_submit_every=self.comparison_upload_submit_every,
                timing_divisor=self.comparison_timing_divisor,
                allow_no_execution=False,
                dawn_filter=self.dawn_filter if comparison_product == "dawn" else "",
                timing_normalization_note=self.timing_normalization_note,
            ),
        }
        return spec, configs


@dataclass(frozen=True)
class BenchmarkMethodologyPolicy:
    source_path: str
    min_dispatch_window_ns_without_encode: int
    min_dispatch_window_coverage_percent_without_encode: float
    local_claim_min_timed_samples: int
    release_claim_min_timed_samples: int
    comparability_min_timed_samples: int
    min_operation_wall_coverage_ratio: float
    max_operation_wall_coverage_asymmetry_ratio: float
    suspicious_speedup_ratio: float
    min_row_timing_floor_ns: int = 0
    smoke_comparability_min_timed_samples: int = 0

def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--config",
        default="",
        help=(
            "JSON config for benchmark run. When provided, missing CLI fields are "
            "loaded from config (for example baseline/comparison command templates)."
        ),
    )
    parser.add_argument("--workloads", default=DEFAULT_WORKLOADS_PATH)
    parser.add_argument("--boundary", default="")
    parser.add_argument("--runtime-host", default="")
    parser.add_argument("--temperature", default="")
    parser.add_argument("--comparison-view", default="")
    parser.add_argument("--provider-set", default="")
    parser.add_argument("--baseline-provider-id", default="")
    parser.add_argument("--comparison-provider-id", default="")
    parser.add_argument(
        "--baseline-name",
        default=DEFAULT_BASELINE_NAME,
    )
    parser.add_argument(
        "--baseline-executor-id",
        default=DEFAULT_BASELINE_EXECUTOR_ID,
        help="Optional explicit executor id for the baseline side.",
    )
    parser.add_argument(
        "--comparison-name",
        default=DEFAULT_COMPARISON_NAME,
    )
    parser.add_argument(
        "--comparison-executor-id",
        default=DEFAULT_COMPARISON_EXECUTOR_ID,
        help="Optional explicit executor id for the comparison side.",
    )
    parser.add_argument(
        "--baseline-command-template",
        default=DEFAULT_BASELINE_COMMAND_TEMPLATE,
        help=(
            "Python format template. Supported keys: commands, quirks, vendor, api, family, "
            "driver, workload, dawn_filter, trace_jsonl, trace_meta, extra_args"
        ),
    )
    parser.add_argument(
        "--comparison-command-template",
        default="",
        help=(
            "Comparison command template using the same placeholders as "
            "--baseline-command-template. "
            "Must target the same workload semantics."
        ),
    )
    parser.add_argument("--iterations", type=int, default=DEFAULT_ITERATIONS)
    parser.add_argument("--warmup", type=int, default=DEFAULT_WARMUP)
    parser.add_argument("--out", default=DEFAULT_OUT_PATH)
    parser.add_argument(
        "--workspace",
        default=DEFAULT_WORKSPACE_PATH,
        help="Directory for per-run pipeline/trace/meta artifacts",
    )
    parser.add_argument(
        "--workload-filter",
        default=DEFAULT_WORKLOAD_FILTER,
        help="Comma-separated workload IDs to include",
    )
    parser.add_argument(
        "--workload-cohort",
        choices=("all", "comparability-candidates", "doe-advantage"),
        default=DEFAULT_WORKLOAD_COHORT,
        help=(
            "Optional workload cohort selector. "
            "'comparability-candidates' keeps workloads marked "
            "comparabilityCandidate.enabled=true. "
            "'doe-advantage' keeps directional workloads for governed "
            "Doe-vs-Dawn non-claim evidence."
        ),
    )
    parser.add_argument(
        "--include-extended-workloads",
        action="store_true",
        help="Legacy fallback: include workloads marked with default=false when selector is not used.",
    )
    parser.add_argument(
        "--include-noncomparable-workloads",
        action="store_true",
        help="Legacy fallback: include workloads marked as non-comparable when selector is not used.",
    )
    parser.add_argument(
        "--comparability",
        choices=("strict", "warn", "off"),
        default=DEFAULT_COMPARABILITY_MODE,
        help="How to handle non-comparable timing sources between baseline/comparison runs.",
    )
    parser.add_argument(
        "--require-timing-class",
        choices=("any", "operation", "process-wall"),
        default=DEFAULT_REQUIRED_TIMING_CLASS,
        help="Required timing class for both participants to consider a workload comparable.",
    )
    parser.add_argument(
        "--allow-baseline-no-execution",
        action="store_true",
        help="Allow baseline samples without explicit execution evidence in trace-meta.",
    )
    parser.add_argument(
        "--resource-probe",
        choices=("none", "rocm-smi"),
        default=DEFAULT_RESOURCE_PROBE,
        help=(
            "Optional resource probe applied equally to both participants. "
            "'rocm-smi' samples global VRAM usage via rocm-smi --showmeminfo vram --json."
        ),
    )
    parser.add_argument(
        "--resource-sample-ms",
        type=int,
        default=DEFAULT_RESOURCE_SAMPLE_MS,
        help="Sampling interval in milliseconds for process/resource probes (>=1).",
    )
    parser.add_argument(
        "--resource-sample-target-count",
        type=int,
        default=DEFAULT_RESOURCE_SAMPLE_TARGET_COUNT,
        help=(
            "Fixed probe sample target per run for strict N-vs-N resource comparability. "
            "When >0, each run records exactly this many samples; short runs are padded, "
            "and long runs are marked truncated."
        ),
    )
    parser.add_argument(
        "--workload-cooldown-ms",
        type=int,
        default=DEFAULT_WORKLOAD_COOLDOWN_MS,
        help=(
            "Optional host settling delay between workloads in milliseconds (>=0). "
            "Applies equally between baseline/comparison workload pairs and the next workload."
        ),
    )
    parser.add_argument(
        "--claimability",
        choices=("off", "local", "release"),
        default=DEFAULT_CLAIMABILITY_MODE,
        help=(
            "Enable reliability checks for claimable faster/slower statements. "
            "local: require min samples + positive p50/p95. "
            "release: require min samples + positive p50/p95/p99."
        ),
    )
    parser.add_argument(
        "--claim-min-timed-samples",
        type=int,
        default=DEFAULT_CLAIM_MIN_TIMED_SAMPLES,
        help=(
            "Minimum timed samples required per participant for claimability checks. "
            "When 0, defaults by claimability mode (local=7, release=15)."
        ),
    )
    parser.add_argument(
        "--benchmark-policy",
        default=DEFAULT_BENCHMARK_POLICY_PATH,
        help=(
            "Benchmark methodology threshold config. "
            "Defaults to config/benchmark-methodology-thresholds.json."
        ),
    )
    parser.add_argument(
        "--timestamp",
        default="",
        help=(
            "UTC suffix for artifact paths (YYYYMMDDTHHMMSSZ). "
            "Defaults to current UTC time when --timestamp-output is enabled."
        ),
    )
    parser.add_argument(
        "--timestamp-output",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Stamp report/workspace artifact paths with a UTC timestamp suffix.",
    )
    parser.add_argument("--emit-shell", action="store_true", help="Print resolved commands instead of running")
    return parser.parse_args(argv)


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def get_nested(payload: dict[str, Any], path: str) -> Any:
    cursor: Any = payload
    for segment in path.split("."):
        if not isinstance(cursor, dict):
            return None
        if segment not in cursor:
            return None
        cursor = cursor[segment]
    return cursor


def first_config_value(payload: dict[str, Any], candidates: list[str]) -> Any:
    for candidate in candidates:
        value = get_nested(payload, candidate)
        if value is not None:
            return value
    return None


def as_str(value: Any, *, field: str) -> str:
    if not isinstance(value, str):
        raise ValueError(f"invalid config value for {field}: expected string")
    return value


def as_int(value: Any, *, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError(f"invalid config value for {field}: expected integer")
    return value


def as_float(value: Any, *, field: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"invalid config value for {field}: expected number")
    return float(value)


def as_bool(value: Any, *, field: str) -> bool:
    if not isinstance(value, bool):
        raise ValueError(f"invalid config value for {field}: expected boolean")
    return value


def resolve_benchmark_policy_path(explicit_path: str) -> Path:
    if explicit_path:
        candidate = Path(explicit_path)
        if candidate.exists():
            return candidate
        raise ValueError(f"missing benchmark policy config: {candidate}")

    for raw in DEFAULT_BENCHMARK_POLICY_CANDIDATES:
        candidate = Path(raw)
        if candidate.exists():
            return candidate
    raise ValueError(
        "missing benchmark policy config; checked "
        f"{', '.join(DEFAULT_BENCHMARK_POLICY_CANDIDATES)}"
    )


def load_benchmark_methodology_policy(explicit_path: str) -> BenchmarkMethodologyPolicy:
    path = resolve_benchmark_policy_path(explicit_path)
    payload = load_json(path)
    if not isinstance(payload, dict):
        raise ValueError(f"invalid benchmark policy config: expected object in {path}")

    dispatch_ns = as_int(
        first_config_value(payload, ["timingSelection.minDispatchWindowNsWithoutEncode"]),
        field="timingSelection.minDispatchWindowNsWithoutEncode",
    )
    dispatch_coverage = as_float(
        first_config_value(
            payload,
            ["timingSelection.minDispatchWindowCoveragePercentWithoutEncode"],
        ),
        field="timingSelection.minDispatchWindowCoveragePercentWithoutEncode",
    )
    local_min_samples = as_int(
        first_config_value(payload, ["claimabilityDefaults.localMinTimedSamples"]),
        field="claimabilityDefaults.localMinTimedSamples",
    )
    release_min_samples = as_int(
        first_config_value(payload, ["claimabilityDefaults.releaseMinTimedSamples"]),
        field="claimabilityDefaults.releaseMinTimedSamples",
    )
    comparability_min_samples = as_int(
        first_config_value(payload, ["comparabilityDefaults.minTimedSamples"]),
        field="comparabilityDefaults.minTimedSamples",
    )
    smoke_min_samples = as_int(
        first_config_value(payload, ["comparabilityDefaults.smokeMinTimedSamples"]),
        field="comparabilityDefaults.smokeMinTimedSamples",
    )
    min_operation_wall_coverage_ratio = as_float(
        first_config_value(payload, ["timingScopeSanity.minOperationWallCoverageRatio"]),
        field="timingScopeSanity.minOperationWallCoverageRatio",
    )
    max_operation_wall_coverage_asymmetry_ratio = as_float(
        first_config_value(
            payload,
            ["timingScopeSanity.maxOperationWallCoverageAsymmetryRatio"],
        ),
        field="timingScopeSanity.maxOperationWallCoverageAsymmetryRatio",
    )

    min_row_timing_floor_ns_raw = first_config_value(
        payload, ["timingScopeSanity.minRowTimingFloorNs"]
    )
    min_row_timing_floor_ns = (
        as_int(min_row_timing_floor_ns_raw, field="timingScopeSanity.minRowTimingFloorNs")
        if min_row_timing_floor_ns_raw is not None
        else 0
    )
    suspicious_speedup_ratio = as_float(
        first_config_value(payload, ["reliability.suspiciousSpeedupRatio"]),
        field="reliability.suspiciousSpeedupRatio",
    )

    if dispatch_ns < 0:
        raise ValueError("timingSelection.minDispatchWindowNsWithoutEncode must be >= 0")
    if dispatch_coverage < 0.0:
        raise ValueError(
            "timingSelection.minDispatchWindowCoveragePercentWithoutEncode must be >= 0"
        )
    if local_min_samples < 0:
        raise ValueError("claimabilityDefaults.localMinTimedSamples must be >= 0")
    if release_min_samples < 0:
        raise ValueError("claimabilityDefaults.releaseMinTimedSamples must be >= 0")
    if comparability_min_samples < 0:
        raise ValueError("comparabilityDefaults.minTimedSamples must be >= 0")
    if smoke_min_samples < 0:
        raise ValueError("comparabilityDefaults.smokeMinTimedSamples must be >= 0")
    if smoke_min_samples > comparability_min_samples:
        raise ValueError(
            "comparabilityDefaults.smokeMinTimedSamples must be <= "
            "comparabilityDefaults.minTimedSamples"
        )
    if min_operation_wall_coverage_ratio < 0.0:
        raise ValueError("timingScopeSanity.minOperationWallCoverageRatio must be >= 0")
    if max_operation_wall_coverage_asymmetry_ratio < 1.0:
        raise ValueError(
            "timingScopeSanity.maxOperationWallCoverageAsymmetryRatio must be >= 1"
        )
    if min_row_timing_floor_ns < 0:
        raise ValueError("timingScopeSanity.minRowTimingFloorNs must be >= 0")
    if suspicious_speedup_ratio < 1.0:
        raise ValueError("reliability.suspiciousSpeedupRatio must be >= 1")

    return BenchmarkMethodologyPolicy(
        source_path=str(path),
        min_dispatch_window_ns_without_encode=dispatch_ns,
        min_dispatch_window_coverage_percent_without_encode=dispatch_coverage,
        local_claim_min_timed_samples=local_min_samples,
        release_claim_min_timed_samples=release_min_samples,
        comparability_min_timed_samples=comparability_min_samples,
        min_operation_wall_coverage_ratio=min_operation_wall_coverage_ratio,
        max_operation_wall_coverage_asymmetry_ratio=max_operation_wall_coverage_asymmetry_ratio,
        suspicious_speedup_ratio=suspicious_speedup_ratio,
        min_row_timing_floor_ns=min_row_timing_floor_ns,
        smoke_comparability_min_timed_samples=smoke_min_samples,
    )


def safe_int(value: Any, default: int = 0) -> int:
    if isinstance(value, bool):
        return default
    if isinstance(value, int):
        return value
    return default


def percent_delta(baseline: float, comparison: float) -> float:
    if baseline <= 0.0:
        return 0.0
    return ((comparison / baseline) - 1.0) * 100.0


def parse_extra_args(value: Any, *, workload_id: str) -> list[str]:
    if isinstance(value, list):
        args: list[str] = []
        for index, item in enumerate(value):
            if not isinstance(item, str):
                raise ValueError(
                    f"invalid workload {workload_id}: extraArgs[{index}] must be a string"
                )
            text = item.strip()
            if text:
                args.append(text)
        return args

    if isinstance(value, str):
        text = value.strip()
        if not text:
            return []
        return shlex.split(text)

    raise ValueError(
        f"invalid workload {workload_id}: extraArgs must be a string or string[]"
    )


def parse_comparability_candidate(
    value: Any,
    *,
    workload_id: str,
) -> tuple[bool, str, str]:
    if value is None:
        return False, "", ""
    if not isinstance(value, dict):
        raise ValueError(
            f"invalid workload {workload_id}: comparabilityCandidate must be an object"
        )
    enabled = value.get("enabled", False)
    if not isinstance(enabled, bool):
        raise ValueError(
            f"invalid workload {workload_id}: comparabilityCandidate.enabled must be boolean"
        )
    raw_tier = value.get("tier", "")
    raw_notes = value.get("notes", "")
    if not isinstance(raw_tier, str):
        raise ValueError(
            f"invalid workload {workload_id}: comparabilityCandidate.tier must be string"
        )
    if not isinstance(raw_notes, str):
        raise ValueError(
            f"invalid workload {workload_id}: comparabilityCandidate.notes must be string"
        )
    tier = raw_tier.strip()
    notes = raw_notes.strip()
    if enabled and not tier:
        raise ValueError(
            f"invalid workload {workload_id}: comparabilityCandidate.enabled=true requires non-empty comparabilityCandidate.tier"
        )
    return enabled, tier, notes


def infer_directional_reason(
    *,
    comparability_notes: str,
    path_asymmetry: bool,
) -> str:
    notes = comparability_notes.strip().lower()
    if path_asymmetry:
        return "path_asymmetry"
    if "maxstoragebufferbindingsize" in notes:
        return "dawn_limit"
    if "does not execute this workload" in notes or "0 dispatches, 0 encode" in notes:
        return "dawn_no_execution"
    if (
        "nearest proxy" in notes
        or "not strict apples-to-apples" in notes
        or "does not expose a matching" in notes
        or "diagnostic and excluded" in notes
        or "parity path" in notes
        or "parity lane" in notes
        or "filter autodiscover has no" in notes
    ):
        return "dawn_missing_contract"
    if (
        "host lane for now" in notes
        or "execution errors" in notes
        or "waittimedout" in notes
        or "intermittent timeout" in notes
    ):
        return "host_instability"
    if "timing" in notes and "directional" in notes:
        return "methodology_gap"
    return "other"


def parse_directional_reason(
    value: Any,
    *,
    workload_id: str,
    benchmark_class: str,
    comparability_notes: str,
    path_asymmetry: bool,
) -> str:
    if value is None:
        return (
            infer_directional_reason(
                comparability_notes=comparability_notes,
                path_asymmetry=path_asymmetry,
            )
            if benchmark_class == "directional"
            else ""
        )
    if not isinstance(value, str):
        raise ValueError(
            f"invalid workload {workload_id}: directionalReason must be a string"
        )
    reason = value.strip().lower()
    if not reason:
        return (
            infer_directional_reason(
                comparability_notes=comparability_notes,
                path_asymmetry=path_asymmetry,
            )
            if benchmark_class == "directional"
            else ""
        )
    if benchmark_class != "directional":
        raise ValueError(
            f"invalid workload {workload_id}: directionalReason requires benchmarkClass=directional"
        )
    if reason not in VALID_DIRECTIONAL_REASONS:
        raise ValueError(
            f"invalid workload {workload_id}: directionalReason must be one of "
            f"{sorted(VALID_DIRECTIONAL_REASONS)}"
        )
    return reason


def resolve_selector(
    selector_config: dict[str, Any],
    workloads: list[Workload],
) -> list[Workload]:
    """Filter workloads using a selector config object.

    Selector fields:
      cohorts         -- workload must have at least one matching cohort tag
      benchmarkClass  -- comparable or directional
      comparability   -- legacy alias mapping comparable/non_comparable to comparable bool
      claimEligibleOnly -- if true, only workloads with claim_eligible=true
      domains         -- if non-empty, workload domain must be in list
      ids             -- if non-empty, workload ID must be in list
      excludeIds      -- exclude these IDs
    """
    cohort_filter = selector_config.get("cohorts", selector_config.get("suite", []))
    benchmark_class_filter = selector_config.get("benchmarkClass", [])
    comparability_filter = selector_config.get("comparability", [])
    claim_eligible_only = selector_config.get("claimEligibleOnly", False)
    domain_filter = selector_config.get("domains", [])
    id_filter = selector_config.get("ids", [])
    exclude_ids = set(selector_config.get("excludeIds", []))

    result: list[Workload] = []
    for workload in workloads:
        if exclude_ids and workload.id in exclude_ids:
            continue
        if id_filter:
            if workload.id not in id_filter:
                continue
        if cohort_filter:
            if not any(tag in cohort_filter for tag in workload.cohorts):
                continue
        if benchmark_class_filter and workload.benchmark_class not in benchmark_class_filter:
            continue
        if comparability_filter:
            workload_comparability = "comparable" if workload.comparable else "non_comparable"
            if workload_comparability not in comparability_filter:
                continue
        if claim_eligible_only and not workload.claim_eligible:
            continue
        if domain_filter:
            if workload.domain not in domain_filter:
                continue
        result.append(workload)
    return result


def load_workloads(
    path: Path,
    workload_filter: str,
    include_noncomparable: bool,
    include_extended: bool,
    workload_cohort: str,
    selector: dict[str, Any] | None = None,
) -> list[Workload]:
    if workload_cohort not in VALID_WORKLOAD_COHORTS:
        raise ValueError(
            f"invalid workload cohort {workload_cohort!r}: expected one of {sorted(VALID_WORKLOAD_COHORTS)}"
        )
    cfg = load_json(path)
    if not isinstance(cfg, dict):
        raise ValueError(f"invalid workload file: expected top-level object at {path}")
    raw_workloads = cfg.get("workloads", [])
    selected = {w.strip() for w in workload_filter.split(",") if w.strip()} if workload_filter else set()
    if workload_filter and not selected:
        raise ValueError(f"invalid workload filter: {workload_filter}")
    result: list[Workload] = []
    for item in raw_workloads:
        if not isinstance(item, dict):
            raise ValueError(f"invalid workload entry in {path}: expected object")
        workload_id = str(item.get("id", "")).strip()
        if not workload_id:
            raise ValueError(f"invalid workload entry in {path}: missing id")
        (
            comparability_candidate,
            comparability_candidate_tier,
            comparability_candidate_notes,
        ) = parse_comparability_candidate(
            item.get("comparabilityCandidate"),
            workload_id=workload_id,
        )
        apples_to_apples_vetted = bool(item.get("applesToApplesVetted", False))
        workload_domain = str(item.get("domain", "uncategorized")).strip().lower()
        baseline_command_repeat = parse_int(item.get("baselineCommandRepeat")) or 1
        comparison_command_repeat_raw = parse_int(item.get("comparisonCommandRepeat"))
        comparison_command_repeat = (
            baseline_command_repeat
            if comparison_command_repeat_raw is None and workload_domain == "upload"
            else (1 if comparison_command_repeat_raw is None else int(comparison_command_repeat_raw or 0))
        )
        baseline_ignore_first_ops = parse_int(item.get("baselineIgnoreFirstOps")) or 0
        comparison_ignore_first_ops_raw = parse_int(item.get("comparisonIgnoreFirstOps"))
        comparison_ignore_first_ops = (
            baseline_ignore_first_ops
            if comparison_ignore_first_ops_raw is None and workload_domain == "upload"
            else (0 if comparison_ignore_first_ops_raw is None else int(comparison_ignore_first_ops_raw or 0))
        )
        baseline_timing_divisor = float(item.get("baselineTimingDivisor", 1.0))
        baseline_upload_buffer_usage = str(
            item.get("baselineUploadBufferUsage", "copy-dst-copy-src")
        )
        baseline_upload_submit_every_raw = parse_int(item.get("baselineUploadSubmitEvery"))
        baseline_upload_submit_every = (
            1
            if baseline_upload_submit_every_raw is None
            else int(baseline_upload_submit_every_raw or 0)
        )
        comparison_upload_submit_every_raw = parse_int(item.get("comparisonUploadSubmitEvery"))
        comparable = bool(item.get("comparable", False))
        path_asymmetry = bool(item.get("pathAsymmetry", False))
        benchmark_class_raw = item.get("benchmarkClass")
        if benchmark_class_raw is None:
            benchmark_class = "comparable" if comparable else "directional"
        else:
            benchmark_class = str(benchmark_class_raw).strip().lower()
        if benchmark_class not in {"comparable", "directional"}:
            raise ValueError(
                f"invalid workload {workload_id}: benchmarkClass must be one of "
                "['comparable', 'directional']"
            )
        if benchmark_class == "comparable" and not comparable:
            raise ValueError(
                f"invalid workload {workload_id}: benchmarkClass=comparable requires comparable=true"
            )
        if benchmark_class == "directional" and comparable:
            raise ValueError(
                f"invalid workload {workload_id}: benchmarkClass=directional requires comparable=false"
            )
        directional_reason = parse_directional_reason(
            item.get("directionalReason"),
            workload_id=workload_id,
            benchmark_class=benchmark_class,
            comparability_notes=str(item.get("comparabilityNotes", "")),
            path_asymmetry=path_asymmetry,
        )
        workload = Workload(
            id=workload_id,
            name=item.get("name", workload_id),
            description=item.get("description", ""),
            domain=item.get("domain", "uncategorized"),
            comparability_notes=item.get("comparabilityNotes", ""),
            commands_path=item.get("commandsPath", ""),
            ir_path=item.get("irPath", ""),
            plan_path=item.get("planPath", ""),
            quirks_path=item.get("quirksPath", ""),
            vendor=item.get("vendor", "intel"),
            api=item.get("api", "vulkan"),
            family=item.get("family", "gen12"),
            driver=item.get("driver", "31.0.101"),
            extra_args=parse_extra_args(item.get("extraArgs", []), workload_id=workload_id),
            baseline_command_repeat=baseline_command_repeat,
            comparison_command_repeat=comparison_command_repeat,
            baseline_ignore_first_ops=baseline_ignore_first_ops,
            comparison_ignore_first_ops=comparison_ignore_first_ops,
            baseline_upload_buffer_usage=baseline_upload_buffer_usage,
            comparison_upload_buffer_usage=str(
                item.get("comparisonUploadBufferUsage", baseline_upload_buffer_usage)
            ),
            baseline_upload_submit_every=baseline_upload_submit_every,
            comparison_upload_submit_every=(
                baseline_upload_submit_every
                if comparison_upload_submit_every_raw is None
                else int(comparison_upload_submit_every_raw or 0)
            ),
            dawn_filter=item.get("dawnFilter", ""),
            comparable=comparable,
            benchmark_class=benchmark_class,
            directional_reason=directional_reason,
            allow_baseline_no_execution=bool(item.get("allowBaselineNoExecution", False)),
            include_by_default=bool(item.get("default", True)),
            baseline_timing_divisor=baseline_timing_divisor,
            comparison_timing_divisor=float(item.get("comparisonTimingDivisor", 1.0)),
            timing_normalization_note=item.get("timingNormalizationNote", ""),
            async_diagnostics_mode=str(item.get("asyncDiagnosticsMode", "")).strip(),
            comparability_candidate=comparability_candidate,
            comparability_candidate_tier=comparability_candidate_tier,
            comparability_candidate_notes=comparability_candidate_notes,
            path_asymmetry=path_asymmetry,
            path_asymmetry_note=str(item.get("pathAsymmetryNote", "")),
            strict_normalization_unit=str(item.get("strictNormalizationUnit", "")).strip().lower(),
            cohorts=item.get("cohorts", item.get("suiteTags", ["exploration"])),
            claim_eligible=bool(item.get("claimEligible", True)),
            runner_type=str(item.get("runnerType", "zig-runtime")).strip(),
            shader_path=str(item.get("shaderPath", "")),
            compilation_target=str(item.get("compilationTarget", "")),
        )
        if workload.runner_type not in {"zig-runtime", "compilation"}:
            raise ValueError(
                f"invalid workload {workload.id}: runnerType must be one of "
                "['zig-runtime', 'compilation']"
            )
        if workload.runner_type == "compilation" and not workload.shader_path:
            raise ValueError(
                f"invalid workload {workload.id}: runnerType=compilation requires shaderPath"
            )
        if workload.strict_normalization_unit not in {"", "command", "dispatch", "cycle"}:
            raise ValueError(
                f"invalid workload {workload.id}: strictNormalizationUnit must be one of "
                "['command', 'dispatch', 'cycle'] when present"
            )
        if workload.baseline_timing_divisor <= 0.0:
            raise ValueError(
                f"invalid workload {workload.id}: baselineTimingDivisor must be > 0"
            )
        if workload.comparison_timing_divisor <= 0.0:
            raise ValueError(
                f"invalid workload {workload.id}: comparisonTimingDivisor must be > 0"
            )
        if workload.baseline_command_repeat < 1:
            raise ValueError(
                f"invalid workload {workload.id}: baselineCommandRepeat must be >= 1"
            )
        if workload.comparison_command_repeat < 1:
            raise ValueError(
                f"invalid workload {workload.id}: comparisonCommandRepeat must be >= 1"
            )
        if workload.baseline_ignore_first_ops < 0:
            raise ValueError(
                f"invalid workload {workload.id}: baselineIgnoreFirstOps must be >= 0"
            )
        if workload.comparison_ignore_first_ops < 0:
            raise ValueError(
                f"invalid workload {workload.id}: comparisonIgnoreFirstOps must be >= 0"
            )
        if workload.baseline_upload_buffer_usage not in VALID_UPLOAD_BUFFER_USAGES:
            raise ValueError(
                f"invalid workload {workload.id}: baselineUploadBufferUsage must be one of "
                f"{sorted(VALID_UPLOAD_BUFFER_USAGES)}"
            )
        if workload.comparison_upload_buffer_usage not in VALID_UPLOAD_BUFFER_USAGES:
            raise ValueError(
                f"invalid workload {workload.id}: comparisonUploadBufferUsage must be one of "
                f"{sorted(VALID_UPLOAD_BUFFER_USAGES)}"
            )
        if workload.baseline_upload_submit_every < 1:
            raise ValueError(
                f"invalid workload {workload.id}: baselineUploadSubmitEvery must be >= 1"
            )
        if workload.comparison_upload_submit_every < 1:
            raise ValueError(
                f"invalid workload {workload.id}: comparisonUploadSubmitEvery must be >= 1"
            )
        if workload.comparable and workload_domain == "upload":
            required_upload_contract_fields = (
                "comparisonCommandRepeat",
                "comparisonIgnoreFirstOps",
                "comparisonUploadBufferUsage",
                "comparisonUploadSubmitEvery",
                "comparisonTimingDivisor",
            )
            missing_upload_contract_fields = [
                field for field in required_upload_contract_fields if field not in item
            ]
            if missing_upload_contract_fields:
                raise ValueError(
                    f"invalid workload {workload.id}: comparable upload workloads must "
                    "declare explicit comparison-side normalization fields; missing "
                    + ", ".join(missing_upload_contract_fields)
                )
        if (
            workload.comparable
            and workload.domain in NON_APPLES_TO_APPLES_DOMAINS
            and (not apples_to_apples_vetted)
        ):
            raise ValueError(
                f"invalid workload {workload.id}: domain={workload.domain} must be "
                "directional (comparable=false) unless applesToApplesVetted=true"
            )
        description_lower = workload.description.strip().lower()
        notes_lower = workload.comparability_notes.strip().lower()
        if workload.comparable and description_lower.startswith("directional "):
            raise ValueError(
                f"invalid workload {workload.id}: comparable=true conflicts with "
                "directional description; mark comparable=false or provide an apples-to-apples description"
            )
        if workload.comparable and "closest draw-call throughput proxy" in notes_lower:
            raise ValueError(
                f"invalid workload {workload.id}: comparable=true conflicts with proxy mapping note "
                "(closest draw-call throughput proxy); mark comparable=false"
            )
        if workload.comparability_candidate and workload.comparable:
            raise ValueError(
                f"invalid workload {workload.id}: comparabilityCandidate.enabled=true "
                "requires comparable=false until parity promotion is complete"
            )
        result.append(workload)

    if selector is not None:
        selector_result = resolve_selector(selector, result)
        if not selected:
            return selector_result
        return [workload for workload in selector_result if workload.id in selected]

    filtered: list[Workload] = []
    for workload in result:
        if selected and workload.id not in selected:
            continue
        if not selected and (not include_extended) and (not workload.include_by_default):
            continue
        if workload_cohort == "comparability-candidates" and (not workload.comparability_candidate):
            continue
        if workload_cohort == "doe-advantage" and workload.benchmark_class != "directional":
            continue
        if (not include_noncomparable) and (not workload.comparable):
            continue
        filtered.append(workload)

    return filtered
