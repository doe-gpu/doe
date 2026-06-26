#!/usr/bin/env python3
"""Run the browser ORT Playwright surface as a bench executor."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
SCENARIO_KIND = "vendor-browser-benchmark-scenario"
SCENARIO_SCHEMA_VERSION = 1
BENCHMARK_LANE = "browser-ort-webgpu-compare"
BROWSER_ORT_TIMED_MEAN_SOURCE = "browser-ort-timed-mean-ms"


def _default_script_path() -> Path:
    return REPO_ROOT / "browser" / "chromium" / "scripts" / "webgpu-playwright-ort-bench.mjs"


def _resolve_from_scenario_dir(base_dir: Path, value: str, field_name: str) -> Path:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{field_name} must be a non-empty string")
    raw = value.strip()
    path = Path(raw)
    if path.is_absolute():
        return path
    return (base_dir / path).resolve()


def _resolve_optional_path(base_dir: Path, value: Any) -> str:
    if not isinstance(value, str) or not value.strip():
        return ""
    return str(_resolve_from_scenario_dir(base_dir, value, "scenario path"))


def _ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def _write_json(path: Path, payload: dict[str, Any]) -> None:
    _ensure_parent(path)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def _write_ndjson(path: Path, rows: list[dict[str, Any]]) -> None:
    _ensure_parent(path)
    body = "\n".join(json.dumps(row) for row in rows)
    path.write_text(body + ("\n" if body else ""), encoding="utf-8")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--scenario", required=True)
    parser.add_argument("--trace-meta", required=True)
    parser.add_argument("--trace-jsonl", required=True)
    parser.add_argument("--workload", required=True)
    parser.add_argument("--mode", required=True, choices=["dawn", "doe"])
    return parser.parse_args(argv)


def load_scenario(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, list) or len(payload) != 1:
        raise ValueError(f"browser ORT scenario {path} must be a JSON array with exactly one entry")
    scenario = payload[0]
    if not isinstance(scenario, dict):
        raise ValueError(f"browser ORT scenario {path} must contain an object entry")
    if scenario.get("kind") != SCENARIO_KIND:
        raise ValueError(f"scenario.kind must be {SCENARIO_KIND}")
    if scenario.get("schemaVersion") != SCENARIO_SCHEMA_VERSION:
        raise ValueError(f"scenario.schemaVersion must be {SCENARIO_SCHEMA_VERSION}")

    scenario_dir = path.resolve().parent
    scenario_id = scenario.get("scenarioId")
    if not isinstance(scenario_id, str) or not scenario_id.strip():
        raise ValueError("scenario.scenarioId must be a non-empty string")
    task = scenario.get("task")
    if not isinstance(task, str) or not task.strip():
        raise ValueError("scenario.task must be a non-empty string")
    timed_iters = scenario.get("timedIters", 5)
    warmup_iters = scenario.get("warmupIters", 2)
    if not isinstance(timed_iters, int) or timed_iters < 1:
        raise ValueError("scenario.timedIters must be an integer >= 1")
    if not isinstance(warmup_iters, int) or warmup_iters < 1:
        raise ValueError("scenario.warmupIters must be an integer >= 1")

    script_path = (
        _resolve_from_scenario_dir(scenario_dir, scenario["scriptPath"], "scenario.scriptPath")
        if isinstance(scenario.get("scriptPath"), str) and scenario["scriptPath"].strip()
        else _default_script_path()
    )

    return {
        "scenarioPath": str(path.resolve()),
        "scenarioId": scenario_id.strip(),
        "task": task.strip(),
        "timedIters": timed_iters,
        "warmupIters": warmup_iters,
        "headless": bool(scenario.get("headless", True)),
        "webgpuPreferredLayout": str(scenario.get("webgpuPreferredLayout", "") or "").strip(),
        "scriptPath": str(script_path),
        "chromePath": _resolve_optional_path(scenario_dir, scenario.get("chromePath")),
        "doeLibPath": _resolve_optional_path(scenario_dir, scenario.get("doeLibPath")),
    }


def _mode_report(payload: dict[str, Any], mode: str) -> dict[str, Any]:
    reports = payload.get("modeResults")
    if not isinstance(reports, list):
        raise ValueError("browser ORT report missing modeResults")
    for entry in reports:
        if isinstance(entry, dict) and entry.get("mode") == mode:
            return entry
    raise ValueError(f"browser ORT report missing requested mode {mode!r}")


def _nonnegative_int(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int) and value >= 0:
        return value
    return None


def _nonnegative_float(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)) and value >= 0:
        return float(value)
    return None


def _number_list(value: Any) -> list[float]:
    if not isinstance(value, list):
        return []
    samples: list[float] = []
    for entry in value:
        parsed = _nonnegative_float(entry)
        if parsed is not None:
            samples.append(parsed)
    return samples


def _percentile(samples: list[float], fraction: float) -> float:
    ordered = sorted(samples)
    if not ordered:
        return 0.0
    index = min(len(ordered) - 1, max(0, int((len(ordered) - 1) * fraction)))
    return ordered[index]


def _stats(samples: list[float]) -> dict[str, float | int]:
    if not samples:
        return {
            "count": 0,
            "min": 0.0,
            "max": 0.0,
            "median": 0.0,
            "p95": 0.0,
            "p99": 0.0,
            "mean": 0.0,
            "stdev": 0.0,
        }
    mean = sum(samples) / len(samples)
    variance = sum((sample - mean) ** 2 for sample in samples) / len(samples)
    return {
        "count": len(samples),
        "min": min(samples),
        "max": max(samples),
        "median": _percentile(samples, 0.5),
        "p95": _percentile(samples, 0.95),
        "p99": _percentile(samples, 0.99),
        "mean": mean,
        "stdev": variance**0.5,
    }


def _trace_meta(
    *,
    workload_id: str,
    scenario: dict[str, Any],
    mode: str,
    mode_report: dict[str, Any],
    report: dict[str, Any],
) -> dict[str, Any]:
    timed_mean_ms = mode_report.get("timedMeanMs")
    timing_ms = timed_mean_ms if isinstance(timed_mean_ms, (int, float)) else mode_report.get("elapsedMs")
    suite_wall_ms = mode_report.get("elapsedMs")
    samples_ms = _number_list(mode_report.get("timedIterationsMs"))
    if not samples_ms:
        fallback_timing_ms = _nonnegative_float(timing_ms)
        if fallback_timing_ms is not None:
            samples_ms = [fallback_timing_ms]
    trace_meta = {
        "traceMetaVersion": 1,
        "runtimeHost": "browser",
        "benchmarkLane": BENCHMARK_LANE,
        "workloadId": workload_id,
        "workload": workload_id,
        "canonicalWorkloadId": workload_id,
        "scenarioId": scenario["scenarioId"],
        "executionBackend": f"browser_ort_webgpu_{mode}",
        "executionLabel": f"Chromium Playwright ORT WebGPU {mode}",
        "executionProvider": mode,
        "executionProviderName": mode,
        "processWallMs": suite_wall_ms,
        "browserOrtTimedMeanMs": timing_ms,
        "browserOrtTimedIterationsMs": samples_ms,
        "timingMs": timing_ms,
        "timingSource": BROWSER_ORT_TIMED_MEAN_SOURCE,
        "adapterInfo": mode_report.get("adapterSummary"),
        "adapterRequestOptions": mode_report.get("adapterRequestOptions"),
        "browserOrtSessionOptions": mode_report.get("ortSessionOptions"),
        "executionRowCount": 1,
        "executionSuccessCount": 1 if mode_report.get("success") else 0,
        "executionErrorCount": 0 if mode_report.get("success") else 1,
        "executionSkippedCount": 0,
        "executionUnsupportedCount": 0,
        "browserTask": scenario["task"],
        "browserTaskConfig": report.get("taskConfig"),
        "timingClass": "operation",
        "browserVersion": mode_report.get("browserVersion"),
        "phaseTimingsMs": {
            "pipelineLoadMs": mode_report.get("pipelineLoadMs"),
            "timedMeanMs": mode_report.get("timedMeanMs"),
            "timedP50Ms": mode_report.get("timedP50Ms"),
            "timedP95Ms": mode_report.get("timedP95Ms"),
        },
        "suiteWallMs": mode_report.get("elapsedMs"),
        "resultSummary": mode_report.get("outputSummary"),
        "browserLaunchArgs": mode_report.get("launchArgs"),
        "samplesMs": samples_ms,
        "stats": _stats(samples_ms),
    }
    dispatch_count = _nonnegative_int(mode_report.get("webgpuDispatchCount"))
    if dispatch_count is not None:
        trace_meta["executionDispatchCount"] = dispatch_count
    elif mode_report.get("success") is not True:
        trace_meta["executionDispatchCount"] = 0
    submit_count = _nonnegative_int(mode_report.get("webgpuQueueSubmitCount"))
    if submit_count is not None:
        trace_meta["executionSubmitCount"] = submit_count
    elif mode_report.get("success") is not True:
        trace_meta["executionSubmitCount"] = 0
    for source_key, trace_key in (
        ("webgpuBufferGetMappedRangeCount", "browserWebgpuBufferGetMappedRangeCount"),
        ("webgpuBufferMapAsyncCount", "browserWebgpuBufferMapAsyncCount"),
        ("webgpuBufferUnmapCount", "browserWebgpuBufferUnmapCount"),
        ("webgpuDispatchWorkgroups", "browserWebgpuDispatchWorkgroups"),
        ("webgpuDispatchWorkgroupsIndirect", "browserWebgpuDispatchWorkgroupsIndirect"),
        ("webgpuQueueOnSubmittedWorkDoneCount", "browserWebgpuQueueOnSubmittedWorkDoneCount"),
        ("webgpuQueueSubmitCount", "browserWebgpuQueueSubmitCount"),
    ):
        value = _nonnegative_int(mode_report.get(source_key))
        if value is not None:
            trace_meta[trace_key] = value
    if isinstance(mode_report.get("webgpuCounterPatches"), dict):
        trace_meta["browserWebgpuCounterPatches"] = mode_report["webgpuCounterPatches"]
    return trace_meta


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    scenario_path = Path(args.scenario)
    trace_meta_path = Path(args.trace_meta)
    trace_jsonl_path = Path(args.trace_jsonl)
    scenario = load_scenario(scenario_path)

    with tempfile.TemporaryDirectory(prefix="doe-browser-ort-bench-") as tmpdir:
        report_path = Path(tmpdir) / "browser-ort-report.json"
        command = [
            "node",
            scenario["scriptPath"],
            "--mode",
            args.mode,
            "--task",
            scenario["task"],
            "--headless",
            "true" if scenario["headless"] else "false",
            "--timed-iters",
            str(scenario["timedIters"]),
            "--warmup-iters",
            str(scenario["warmupIters"]),
            "--out",
            str(report_path),
        ]
        if scenario["chromePath"]:
            command.extend(["--chrome", scenario["chromePath"]])
        if scenario["doeLibPath"]:
            command.extend(["--doe-lib", scenario["doeLibPath"]])
        if scenario["webgpuPreferredLayout"]:
            command.extend(["--webgpu-preferred-layout", scenario["webgpuPreferredLayout"]])

        proc = subprocess.run(
            command,
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )

        report = json.loads(report_path.read_text(encoding="utf-8")) if report_path.exists() else {}

    if proc.returncode != 0:
        error_message = proc.stderr.strip() or f"browser ORT executor failed with rc={proc.returncode}"
        trace_meta = {
            "traceMetaVersion": 1,
            "runtimeHost": "browser",
            "benchmarkLane": BENCHMARK_LANE,
            "workloadId": args.workload,
            "scenarioId": scenario["scenarioId"],
            "executionBackend": f"browser_ort_webgpu_{args.mode}",
            "executionLabel": f"Chromium Playwright ORT WebGPU {args.mode}",
            "executionProvider": args.mode,
            "executionProviderName": args.mode,
            "processWallMs": 0,
            "timingMs": 0,
            "timingSource": "wall-time",
            "adapterInfo": None,
            "executionRowCount": 0,
            "executionSuccessCount": 0,
            "executionErrorCount": 1,
            "executionSkippedCount": 0,
            "executionUnsupportedCount": 0,
            "executionDispatchCount": 0,
            "executionSubmitCount": 0,
            "browserTask": scenario["task"],
            "terminalFailureCaptured": True,
            "failureMessage": error_message,
        }
        rows = [
            {
                "traceFormat": "vendor-browser-benchmark-v1",
                "status": "error",
                "executionBackend": f"browser_ort_webgpu_{args.mode}",
                "workloadId": args.workload,
                "scenarioId": scenario["scenarioId"],
                "processWallMs": 0,
                "errorMessage": error_message,
            }
        ]
        _write_json(trace_meta_path, trace_meta)
        _write_ndjson(trace_jsonl_path, rows)
        print(error_message, file=sys.stderr)
        return 1

    mode_report = _mode_report(report, args.mode)
    if mode_report.get("success") is not True:
        error_message = str(mode_report.get("error", "")).strip() or f"browser ORT {args.mode} mode reported failure"
        trace_meta = _trace_meta(
            workload_id=args.workload,
            scenario=scenario,
            mode=args.mode,
            mode_report=mode_report,
            report=report,
        )
        trace_meta["executionSuccessCount"] = 0
        trace_meta["executionErrorCount"] = 1
        trace_meta["terminalFailureCaptured"] = True
        trace_meta["failureMessage"] = error_message
        rows = [
            {
                "traceFormat": "vendor-browser-benchmark-v1",
                "status": "error",
                "executionBackend": f"browser_ort_webgpu_{args.mode}",
                "workloadId": args.workload,
                "scenarioId": scenario["scenarioId"],
                "processWallMs": mode_report.get("elapsedMs", 0),
                "timingMs": trace_meta["timingMs"],
                "timingSource": trace_meta["timingSource"],
                "errorMessage": error_message,
            }
        ]
        _write_json(trace_meta_path, trace_meta)
        _write_ndjson(trace_jsonl_path, rows)
        print(error_message, file=sys.stderr)
        return 1

    trace_meta = _trace_meta(
        workload_id=args.workload,
        scenario=scenario,
        mode=args.mode,
        mode_report=mode_report,
        report=report,
    )
    rows = [
        {
                "traceFormat": "vendor-browser-benchmark-v1",
                "status": "success",
                "executionBackend": f"browser_ort_webgpu_{args.mode}",
                "workloadId": args.workload,
                "scenarioId": scenario["scenarioId"],
                "processWallMs": trace_meta["processWallMs"],
                "timingMs": trace_meta["timingMs"],
                "timingSource": trace_meta["timingSource"],
                "phaseTimingsMs": trace_meta["phaseTimingsMs"],
                "resultSummary": mode_report.get("outputSummary"),
            }
    ]
    _write_json(trace_meta_path, trace_meta)
    _write_ndjson(trace_jsonl_path, rows)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
