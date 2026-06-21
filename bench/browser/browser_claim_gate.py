#!/usr/bin/env python3
"""Repeated-window claim gate for promoted browser diagnostics."""

from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
for _path_entry in (str(REPO_ROOT), str(BENCH_ROOT)):
    if _path_entry not in sys.path:
        sys.path.insert(0, _path_entry)


import argparse
import json
import math
import subprocess
import sys
from datetime import UTC, datetime
from pathlib import Path, PurePosixPath
from typing import Any

BENCH_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = Path(__file__).resolve().parents[2]
if str(BENCH_ROOT) not in sys.path:
    sys.path.insert(0, str(BENCH_ROOT))

from bench.lib import output_paths
from bench.lib.bench_utils import load_json_object as load_json
from bench.lib.config_validation import load_validated_config
from bench.tools import build_browser_claim_promotion_receipt
from bench.tools import check_browser_responsibility_map


def repo_root() -> Path:
    return REPO_ROOT


def utc_stamp() -> str:
    return datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")


def default_report_path(root: Path) -> Path:
    return root / "bench/out/browser-claim" / utc_stamp() / "browser_claim_report.json"


def default_artifact_root(root: Path) -> Path:
    return root / "browser/chromium/artifacts" / utc_stamp() / "browser-claim"


def safe_repo_path(path_text: str) -> bool:
    path = PurePosixPath(path_text)
    return bool(path_text) and not path.is_absolute() and ".." not in path.parts


def resolve_repo_path(root: Path, path_text: str) -> Path:
    return root.joinpath(*PurePosixPath(path_text).parts)


def chromium_patch_manifest_path_from_policy(
    policy: dict[str, Any],
    root: Path,
) -> tuple[Path | None, str | None]:
    try:
        manifest_path = policy["patchIsolation"]["patchManifestPath"]
    except (KeyError, TypeError):
        return None, "missing patchIsolation.patchManifestPath"
    if not isinstance(manifest_path, str) or not manifest_path:
        return None, "patchIsolation.patchManifestPath must be non-empty"
    if not safe_repo_path(manifest_path):
        return None, f"patchIsolation.patchManifestPath must be repo-relative: {manifest_path}"
    return resolve_repo_path(root, manifest_path), None


def parse_args() -> argparse.Namespace:
    root = repo_root()
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=str(root))
    parser.add_argument(
        "--policy",
        default=str(root / "config/browser-claim-policy.json"),
    )
    parser.add_argument(
        "--promotion-approvals",
        default=str(root / "browser/chromium/bench/workflows/browser-promotion-approvals.json"),
    )
    parser.add_argument(
        "--ownership",
        default=str(root / "config/browser-ownership.json"),
    )
    parser.add_argument(
        "--responsibility-map",
        default=str(root / "config/browser-responsibility-map.json"),
    )
    parser.add_argument(
        "--runtime-selector-policy",
        default=str(root / "config/browser-runtime-selector-policy.json"),
    )
    parser.add_argument(
        "--fork-maintenance-policy",
        default=str(root / "config/chromium-fork-maintenance-policy.json"),
    )
    parser.add_argument(
        "--capture-policy",
        default=str(root / "config/browser-capture-policy.json"),
    )
    parser.add_argument(
        "--window-count",
        type=int,
        default=0,
        help="Override the policy minWindows value.",
    )
    parser.add_argument(
        "--report",
        default="",
        help="Output JSON report path. Defaults to bench/out/browser-claim/<timestamp>/browser_claim_report.json",
    )
    parser.add_argument(
        "--promotion-receipt-out",
        default="",
        help="Output browser claim promotion receipt path. Defaults next to --report.",
    )
    parser.add_argument(
        "--artifact-root",
        default="",
        help="Artifact directory root for repeated browser windows.",
    )
    parser.add_argument(
        "--reuse-artifact-root",
        default="",
        help="Reuse an existing repeated-window artifact root instead of rerunning browser windows.",
    )
    parser.add_argument("--chrome", default="")
    parser.add_argument("--dawn-chrome", default="")
    parser.add_argument("--doe-chrome", default="")
    parser.add_argument("--doe-lib", default="")
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def stable_hash(payload: Any) -> str:
    encoded = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    import hashlib

    return hashlib.sha256(encoded).hexdigest()


def percentile(values: list[float], ratio: float) -> float:
    ordered = sorted(values)
    rank = max(1, math.ceil(ratio * len(ordered)))
    return ordered[rank - 1]


def summarize_values(values: list[float]) -> dict[str, Any]:
    return {
        "sampleCount": len(values),
        "minMs": min(values),
        "maxMs": max(values),
        "p50Ms": percentile(values, 0.50),
        "p95Ms": percentile(values, 0.95),
        "p99Ms": percentile(values, 0.99),
    }


def percent_delta(baseline: float | None, comparison: float | None) -> float | None:
    if baseline is None or comparison is None or baseline <= 0.0:
        return None
    return ((baseline - comparison) / baseline) * 100.0


def parse_policy(path: Path) -> dict[str, Any]:
    payload = load_validated_config(path)
    if payload.get("schemaVersion") != 1:
        raise ValueError("browser claim policy schemaVersion must be 1")
    mode = payload.get("mode")
    if mode not in {"local", "release"}:
        raise ValueError("browser claim policy mode must be local or release")
    min_windows = payload.get("minWindows")
    if not isinstance(min_windows, int) or min_windows <= 0:
        raise ValueError("browser claim policy minWindows must be > 0")
    required_percentiles = payload.get("requiredPositivePercentiles")
    if not isinstance(required_percentiles, list) or not required_percentiles:
        raise ValueError("browser claim policy requiredPositivePercentiles must be non-empty")
    require_modes = payload.get("requireModes")
    if not isinstance(require_modes, list) or sorted(require_modes) != ["dawn", "doe"]:
        raise ValueError("browser claim policy requireModes must be ['dawn', 'doe']")
    require_claim_scopes = payload.get("requireClaimScopes")
    if not isinstance(require_claim_scopes, list) or not require_claim_scopes:
        raise ValueError("browser claim policy requireClaimScopes must be non-empty")
    expected_rows = payload.get("expectedStrictCandidateRows")
    if not isinstance(expected_rows, int) or expected_rows <= 0:
        raise ValueError("browser claim policy expectedStrictCandidateRows must be > 0")
    max_flake = payload.get("maxFlakePercent")
    if not isinstance(max_flake, (int, float)) or max_flake < 0:
        raise ValueError("browser claim policy maxFlakePercent must be >= 0")
    return payload


def responsibility_map_failures(path: Path, root: Path) -> list[str]:
    payload = load_json(path)
    return [
        f"responsibility-map:{item['code']}: {item['path']}: {item['message']}"
        for item in check_browser_responsibility_map.check_responsibility_map(payload, root)
    ]


def runtime_selector_policy_failures(path: Path, root: Path) -> list[str]:
    checker = root / "browser/chromium/scripts/check-browser-runtime-selector-policy.py"
    result = subprocess.run(
        [sys.executable, str(checker), "--policy", str(path)],
        cwd=root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode == 0:
        return []
    output = "\n".join(part for part in (result.stdout.strip(), result.stderr.strip()) if part)
    return [f"runtime-selector-policy: {output or 'check failed'}"]


def fork_maintenance_policy_failures(path: Path, root: Path) -> list[str]:
    checker = root / "bench/tools/check_chromium_fork_maintenance_policy.py"
    result = subprocess.run(
        [sys.executable, str(checker), "--policy", str(path), "--root", str(root)],
        cwd=root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode == 0:
        return []
    output = "\n".join(part for part in (result.stdout.strip(), result.stderr.strip()) if part)
    return [f"fork-maintenance-policy: {output or 'check failed'}"]


def chromium_patch_manifest_failures(policy_path: Path, root: Path) -> list[str]:
    try:
        policy = load_json(policy_path)
        manifest_path, error = chromium_patch_manifest_path_from_policy(policy, root)
        if error is not None or manifest_path is None:
            return [f"chromium-patch-manifest: failed to resolve manifest path: {error}"]
    except (KeyError, TypeError, ValueError, OSError, json.JSONDecodeError) as exc:
        return [f"chromium-patch-manifest: failed to resolve manifest path: {exc}"]
    checker = root / "bench/tools/check_chromium_patch_manifest.py"
    result = subprocess.run(
        [
            sys.executable,
            str(checker),
            "--manifest",
            str(manifest_path),
            "--policy",
            str(policy_path),
            "--root",
            str(root),
        ],
        cwd=root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode == 0:
        return []
    output = "\n".join(part for part in (result.stdout.strip(), result.stderr.strip()) if part)
    return [f"chromium-patch-manifest: {output or 'check failed'}"]


def capture_policy_failures(path: Path, root: Path) -> list[str]:
    checker = root / "bench/tools/check_browser_capture_policy.py"
    result = subprocess.run(
        [sys.executable, str(checker), "--policy", str(path)],
        cwd=root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode == 0:
        return []
    output = "\n".join(part for part in (result.stdout.strip(), result.stderr.strip()) if part)
    return [f"capture-policy: {output or 'check failed'}"]


def extract_claim_rows(report_payload: dict[str, Any], required_claim_scopes: set[str]) -> dict[str, dict[str, Any]]:
    rows = report_payload.get("l1", {}).get("rows", [])
    if not isinstance(rows, list):
        raise ValueError("layered report missing l1.rows")
    claim_rows: dict[str, dict[str, Any]] = {}
    for row in rows:
        if not isinstance(row, dict):
            continue
        workload_id = row.get("sourceWorkloadId")
        if not isinstance(workload_id, str) or not workload_id:
            continue
        if row.get("comparabilityExpectation") != "strict":
            continue
        if row.get("claimScope") not in required_claim_scopes:
            continue
        if row.get("requiredStatus") != "ok":
            continue
        claim_rows[workload_id] = row
    return claim_rows


def metric_number(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    return None


def metric_ms(metrics: dict[str, Any]) -> float | None:
    us_per_op = metric_number(metrics.get("usPerOp"))
    if us_per_op is not None and us_per_op > 0.0:
        return us_per_op / 1000.0
    us_per_frame = metric_number(metrics.get("usPerFrame"))
    if us_per_frame is not None and us_per_frame > 0.0:
        return us_per_frame / 1000.0
    us_per_submit = metric_number(metrics.get("usPerSubmit"))
    if us_per_submit is not None and us_per_submit > 0.0:
        return us_per_submit / 1000.0
    ms_per_pipeline = metric_number(metrics.get("msPerPipeline"))
    if ms_per_pipeline is not None and ms_per_pipeline > 0.0:
        return ms_per_pipeline
    ms_per_resize = metric_number(metrics.get("msPerResize"))
    if ms_per_resize is not None and ms_per_resize > 0.0:
        return ms_per_resize
    elapsed_ms = metric_number(metrics.get("elapsedMs"))
    if elapsed_ms is None or elapsed_ms <= 0.0:
        return None
    divisor = None
    for counter_key in ("iterations", "submitCount", "resizeCount", "pipelineCount"):
        counter = metrics.get(counter_key)
        if isinstance(counter, int) and counter > 0:
            divisor = counter
            break
    if divisor is None:
        return elapsed_ms
    return elapsed_ms / divisor


def run_window(
    root: Path,
    window_index: int,
    windows_dir: Path,
    artifacts_root: Path,
    args: argparse.Namespace,
) -> dict[str, Any]:
    gate_script = root / "bench/browser/browser_gate.py"
    gate_report = windows_dir / f"window-{window_index:02d}.browser_gate.json"
    window_artifacts = artifacts_root / f"window-{window_index:02d}"
    command = [
        sys.executable,
        str(gate_script),
        "--root",
        str(root),
        "--promotion-approvals",
        str(Path(args.promotion_approvals).resolve()),
        "--ownership",
        str(Path(args.ownership).resolve()),
        "--responsibility-map",
        str(Path(args.responsibility_map).resolve()),
        "--runtime-selector-policy",
        str(Path(args.runtime_selector_policy).resolve()),
        "--fork-maintenance-policy",
        str(Path(args.fork_maintenance_policy).resolve()),
        "--capture-policy",
        str(Path(args.capture_policy).resolve()),
        "--artifact-root",
        str(window_artifacts),
        "--report",
        str(gate_report),
    ]
    if args.chrome:
        command.extend(["--chrome", args.chrome])
    if args.dawn_chrome:
        command.extend(["--dawn-chrome", args.dawn_chrome])
    if args.doe_chrome:
        command.extend(["--doe-chrome", args.doe_chrome])
    if args.doe_lib:
        command.extend(["--doe-lib", args.doe_lib])
    subprocess.run(command, cwd=root, check=True)
    gate_payload = load_json(gate_report)
    if gate_payload.get("ok") is not True:
        raise RuntimeError(f"browser_gate failed for window-{window_index:02d}")
    return gate_payload


def reuse_window_artifacts(window_dir: Path) -> dict[str, str]:
    candidates = {
        "smokeReport": window_dir / "dawn-vs-doe.browser.playwright-smoke.diagnostic.json",
        "ctsSubsetReport": window_dir / "browser-cts-subset.json",
        "recoveryParityReport": window_dir / "browser-recovery-parity.json",
        "canvasWebgpuFusionReport": window_dir / "browser-canvas-webgpu-fusion.json",
        "mediaPathProbeReport": window_dir / "browser-media-path-probe.json",
        "gpuSchedulerReport": window_dir / "browser-gpu-scheduler.json",
        "webgpuEffectExperimentReport": window_dir / "browser-webgpu-effect-experiment.json",
        "flightRecorderReport": window_dir / "browser-gpu-flight-recorder.json",
        "flightReplayReport": window_dir / "browser-gpu-flight-replay.json",
        "shaderLinksReport": window_dir / "browser-shader-links.json",
        "localAiWorkloadsReport": window_dir / "browser-local-ai-workloads.json",
        "pipelineCacheReceiptsReport": window_dir / "browser-pipeline-cache-receipts.json",
        "fallbackExplanationsReport": window_dir / "browser-fallback-explanations.json",
        "layeredReport": window_dir / "dawn-vs-doe.browser-layered.superset.diagnostic.json",
        "summaryReport": window_dir / "dawn-vs-doe.browser-layered.superset.summary.json",
        "checkReport": window_dir / "dawn-vs-doe.browser-layered.superset.check.json",
    }
    return {
        key: str(path)
        for key, path in candidates.items()
        if path.exists()
    }


def main() -> int:
    args = parse_args()
    root = Path(args.root).resolve()
    policy_path = Path(args.policy).resolve()
    policy = parse_policy(policy_path)
    report_path = Path(args.report).resolve() if args.report else default_report_path(root)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    promotion_receipt_path = (
        Path(args.promotion_receipt_out).resolve()
        if args.promotion_receipt_out
        else Path(f"{report_path.with_suffix('')}.promotion-receipt.json")
    )
    promotion_receipt_path.parent.mkdir(parents=True, exist_ok=True)
    artifacts_root = Path(args.artifact_root).resolve() if args.artifact_root else default_artifact_root(root)
    artifacts_root.mkdir(parents=True, exist_ok=True)
    windows_dir = report_path.parent / "windows"
    windows_dir.mkdir(parents=True, exist_ok=True)

    requested_windows = args.window_count if args.window_count > 0 else int(policy["minWindows"])
    if requested_windows < int(policy["minWindows"]):
        print(
            "FAIL: --window-count must be >= policy minWindows "
            f"({policy['minWindows']})"
        )
        return 1

    failures: list[str] = []
    responsibility_map_path = Path(args.responsibility_map).resolve()
    runtime_selector_policy_path = Path(args.runtime_selector_policy).resolve()
    fork_maintenance_policy_path = Path(args.fork_maintenance_policy).resolve()
    try:
        fork_maintenance_policy = load_json(fork_maintenance_policy_path)
        maybe_chromium_patch_manifest_path, patch_manifest_error = (
            chromium_patch_manifest_path_from_policy(fork_maintenance_policy, root)
        )
        chromium_patch_manifest_path = (
            maybe_chromium_patch_manifest_path
            if maybe_chromium_patch_manifest_path is not None
            else root / "config/chromium-patch-manifest.json"
        )
    except (KeyError, TypeError, ValueError, OSError, json.JSONDecodeError):
        patch_manifest_error = None
        chromium_patch_manifest_path = root / "config/chromium-patch-manifest.json"
    capture_policy_path = Path(args.capture_policy).resolve()
    failures.extend(responsibility_map_failures(responsibility_map_path, root))
    failures.extend(runtime_selector_policy_failures(runtime_selector_policy_path, root))
    failures.extend(fork_maintenance_policy_failures(fork_maintenance_policy_path, root))
    if patch_manifest_error is not None:
        failures.append(f"chromium-patch-manifest: failed to resolve manifest path: {patch_manifest_error}")
    else:
        failures.extend(chromium_patch_manifest_failures(fork_maintenance_policy_path, root))
    failures.extend(capture_policy_failures(capture_policy_path, root))
    per_window_rows: list[dict[str, Any]] = []
    claim_scope_rows: dict[str, dict[str, Any]] = {}
    required_claim_scopes = set(policy["requireClaimScopes"])

    if args.reuse_artifact_root:
        reuse_root = Path(args.reuse_artifact_root).resolve()
        window_dirs = sorted(path for path in reuse_root.iterdir() if path.is_dir() and path.name.startswith("window-"))
        if args.window_count > 0 and len(window_dirs) != requested_windows:
            failures.append(
                f"reuse artifact root has {len(window_dirs)} windows, expected {requested_windows}"
            )
        requested_windows = len(window_dirs)
        artifacts_root = reuse_root
        for window_dir in window_dirs:
            window_index = int(window_dir.name.split("-")[-1])
            layered_path = window_dir / "dawn-vs-doe.browser-layered.superset.diagnostic.json"
            summary_path = window_dir / "dawn-vs-doe.browser-layered.superset.summary.json"
            check_path = window_dir / "dawn-vs-doe.browser-layered.superset.check.json"
            smoke_path = window_dir / "dawn-vs-doe.browser.playwright-smoke.diagnostic.json"
            artifact_map = reuse_window_artifacts(window_dir)
            layered_report = load_json(layered_path)
            summary_report = load_json(summary_path)
            check_report = load_json(check_path)
            gate_payload = {
                "artifacts": artifact_map,
                "hashes": {
                    key: stable_hash(load_json(Path(path)))
                    for key, path in artifact_map.items()
                },
            }
            if not smoke_path.exists():
                failures.append(f"{window_dir.name}: smoke report missing")
            current_rows = extract_claim_rows(layered_report, required_claim_scopes)
            if len(current_rows) != int(policy["expectedStrictCandidateRows"]):
                failures.append(
                    f"{window_dir.name}: expected "
                    f"{policy['expectedStrictCandidateRows']} strict candidate rows, found {len(current_rows)}"
                )
            if not claim_scope_rows:
                claim_scope_rows = current_rows
            elif set(current_rows) != set(claim_scope_rows):
                failures.append(f"{window_dir.name}: strict candidate row set drift")

            browser_evidence = layered_report.get("browserEnvironmentEvidence", {})
            per_window_rows.append(
                {
                    "window": window_index,
                    "gateReport": "",
                    "smokeReport": str(smoke_path),
                    "layeredReport": str(layered_path),
                    "summaryReport": str(summary_path),
                    "checkReport": str(check_path),
                    "artifacts": gate_payload["artifacts"],
                    "hashes": gate_payload["hashes"],
                    "browserEnvironmentEvidence": browser_evidence,
                }
            )
    else:
        for window_index in range(1, requested_windows + 1):
            gate_payload = run_window(root, window_index, windows_dir, artifacts_root, args)
            layered_report = load_json(Path(gate_payload["artifacts"]["layeredReport"]))
            summary_report = load_json(Path(gate_payload["artifacts"]["summaryReport"]))
            check_report = load_json(Path(gate_payload["artifacts"]["checkReport"]))

            if summary_report.get("benchmarkClass") != "directional":
                failures.append(f"window-{window_index:02d}: summary benchmarkClass drift")
            run_payload = summary_report.get("run", {})
            if policy["requireStrictRun"] and run_payload.get("strictRun") is not True:
                failures.append(f"window-{window_index:02d}: strictRun must be true")
            if policy["requireHeadless"] and layered_report.get("headless") is not True:
                failures.append(f"window-{window_index:02d}: headless must be true")
            browser_evidence = layered_report.get("browserEnvironmentEvidence", {})
            if (
                not policy["allowDataUrlFallback"]
                and isinstance(browser_evidence, dict)
                and browser_evidence.get("dataUrlFallbackEnabled") is not False
            ):
                failures.append(f"window-{window_index:02d}: data URL fallback must be disabled")
            if policy["promotionApprovalsRequired"] and check_report.get("promotionChecked") is not True:
                failures.append(f"window-{window_index:02d}: promotionChecked must be true")

            current_rows = extract_claim_rows(layered_report, required_claim_scopes)
            if len(current_rows) != int(policy["expectedStrictCandidateRows"]):
                failures.append(
                    f"window-{window_index:02d}: expected "
                    f"{policy['expectedStrictCandidateRows']} strict candidate rows, found {len(current_rows)}"
                )
            if not claim_scope_rows:
                claim_scope_rows = current_rows
            elif set(current_rows) != set(claim_scope_rows):
                failures.append(f"window-{window_index:02d}: strict candidate row set drift")

            per_window_rows.append(
                {
                    "window": window_index,
                    "gateReport": str((windows_dir / f"window-{window_index:02d}.browser_gate.json").resolve()),
                    "smokeReport": gate_payload["artifacts"]["smokeReport"],
                    "layeredReport": gate_payload["artifacts"]["layeredReport"],
                    "summaryReport": gate_payload["artifacts"]["summaryReport"],
                    "checkReport": gate_payload["artifacts"]["checkReport"],
                    "artifacts": gate_payload["artifacts"],
                    "hashes": gate_payload["hashes"],
                    "browserEnvironmentEvidence": browser_evidence,
                }
            )

    workload_rows: list[dict[str, Any]] = []
    claimable_count = 0
    comparable_count = 0

    for workload_id in sorted(claim_scope_rows):
        row_template = claim_scope_rows[workload_id]
        dawn_values: list[float] = []
        doe_values: list[float] = []
        observed_iterations: list[int] = []
        reasons: list[str] = []

        for window_index in range(1, requested_windows + 1):
            layered_path = Path(per_window_rows[window_index - 1]["layeredReport"])
            layered_report = load_json(layered_path)
            row = extract_claim_rows(layered_report, required_claim_scopes).get(workload_id)
            if not isinstance(row, dict):
                reasons.append(f"window-{window_index:02d}: workload missing")
                continue
            runtimes = row.get("runtimes", {})
            if not isinstance(runtimes, dict):
                reasons.append(f"window-{window_index:02d}: runtimes missing")
                continue
            for mode, bucket in (("dawn", dawn_values), ("doe", doe_values)):
                runtime_payload = runtimes.get(mode)
                if not isinstance(runtime_payload, dict):
                    reasons.append(f"window-{window_index:02d}: {mode} runtime payload missing")
                    continue
                if runtime_payload.get("status") != "ok":
                    reasons.append(f"window-{window_index:02d}: {mode} status={runtime_payload.get('status')}")
                    continue
                metrics = runtime_payload.get("metrics", {})
                if not isinstance(metrics, dict):
                    reasons.append(f"window-{window_index:02d}: {mode} metrics missing")
                    continue
                timing_ms = metric_ms(metrics)
                iterations = metrics.get("iterations")
                if timing_ms is None or timing_ms <= 0.0:
                    reasons.append(f"window-{window_index:02d}: {mode} timing metric must be > 0")
                    continue
                if isinstance(iterations, int) and iterations > 0:
                    observed_iterations.append(iterations)
                bucket.append(timing_ms)

        if len(set(observed_iterations)) > 1:
            reasons.append("iteration count drift across windows or modes")

        comparable = len(dawn_values) == requested_windows and len(doe_values) == requested_windows and not reasons
        if comparable:
            comparable_count += 1

        dawn_stats = summarize_values(dawn_values) if dawn_values else {}
        doe_stats = summarize_values(doe_values) if doe_values else {}
        delta_percent = {
            "p50Percent": percent_delta(metric_number(dawn_stats.get("p50Ms")), metric_number(doe_stats.get("p50Ms"))),
            "p95Percent": percent_delta(metric_number(dawn_stats.get("p95Ms")), metric_number(doe_stats.get("p95Ms"))),
            "p99Percent": percent_delta(metric_number(dawn_stats.get("p99Ms")), metric_number(doe_stats.get("p99Ms"))),
        }

        flake_percent = 0.0
        if comparable and metric_number(dawn_stats.get("p50Ms")) and metric_number(doe_stats.get("p50Ms")):
            positive_windows = 0
            for baseline, comparison in zip(dawn_values, doe_values):
                if (
                    percent_delta(baseline, comparison) is not None
                    and percent_delta(baseline, comparison) > 0.0
                ):
                    positive_windows += 1
            flake_percent = (1.0 - (positive_windows / requested_windows)) * 100.0
            if flake_percent > float(policy["maxFlakePercent"]):
                reasons.append(
                    f"flakePercent={flake_percent:.2f} exceeds policy maxFlakePercent={policy['maxFlakePercent']:.2f}"
                )

        claimable = comparable and len(dawn_values) >= int(policy["minWindows"])
        if claimable:
            for percentile_key in policy["requiredPositivePercentiles"]:
                value = metric_number(delta_percent.get(percentile_key))
                if value is None or value <= 0.0:
                    reasons.append(f"{percentile_key} must be > 0")
                    claimable = False
            if flake_percent > float(policy["maxFlakePercent"]):
                claimable = False

        if claimable:
            claimable_count += 1

        workload_rows.append(
            {
                "id": workload_id,
                "name": row_template.get("sourceWorkloadName", workload_id),
                "domain": row_template.get("domain", ""),
                "scenarioTemplate": row_template.get("scenarioTemplate", ""),
                "claimScope": row_template.get("claimScope", ""),
                "comparabilityExpectation": row_template.get("comparabilityExpectation", ""),
                "comparisonStatus": "comparable" if comparable else "diagnostic",
                "claimability": {
                    "claimable": claimable,
                    "reasons": reasons,
                    "windowCount": requested_windows,
                    "flakePercent": flake_percent,
                },
                "deltaPercent": delta_percent,
                "baseline": {
                    "runtime": "dawn",
                    "timingSources": ["browser-performance-now"],
                    "stats": dawn_stats,
                    "samplesMs": dawn_values,
                },
                "comparison": {
                    "runtime": "doe",
                    "timingSources": ["browser-performance-now"],
                    "stats": doe_stats,
                    "samplesMs": doe_values,
                },
            }
        )

    comparison_status = "comparable" if comparable_count == len(workload_rows) and not failures else "diagnostic"
    claim_status = "claimable" if claimable_count == len(workload_rows) and comparison_status == "comparable" else "diagnostic"
    ok = not failures and comparison_status == "comparable" and claim_status == "claimable"

    payload = {
        "schemaVersion": 1,
        "laneId": "browser_claim_local",
        "reportKind": "browser-claim-report",
        "generatedAt": datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "benchmarkClass": "comparable",
        "comparisonStatus": comparison_status,
        "claimStatus": claim_status,
        "timingClass": "scenario",
        "timingSource": "browser-performance-now",
        "claimabilityPolicy": {
            "mode": policy["mode"],
            "minTimedSamples": policy["minWindows"],
            "requiredPositivePercentiles": policy["requiredPositivePercentiles"],
            "maxFlakePercent": policy["maxFlakePercent"],
        },
        "policyPath": str(policy_path),
        "responsibilityMapPath": str(responsibility_map_path),
        "runtimeSelectorPolicyPath": str(runtime_selector_policy_path),
        "forkMaintenancePolicyPath": str(fork_maintenance_policy_path),
        "chromiumPatchManifestPath": str(chromium_patch_manifest_path),
        "capturePolicyPath": str(capture_policy_path),
        "promotionApprovalsPath": str(Path(args.promotion_approvals).resolve()),
        "ownershipPath": str(Path(args.ownership).resolve()),
        "windowCount": requested_windows,
        "windows": per_window_rows,
        "claimabilitySummary": {
            "workloadCount": len(workload_rows),
            "comparableCount": comparable_count,
            "claimableCount": claimable_count,
        },
        "workloads": workload_rows,
        "failures": failures,
    }
    report_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

    tail_health = {
        "schemaVersion": 1,
        "generatedAt": payload["generatedAt"],
        "reportPath": str(report_path),
        "requiredPositivePercentiles": policy["requiredPositivePercentiles"],
        "rows": [
            {
                "workloadId": row["id"],
                "comparisonStatus": row["comparisonStatus"],
                "claimable": row["claimability"]["claimable"],
                "flakePercent": row["claimability"]["flakePercent"],
                "deltaPercent": row["deltaPercent"],
            }
            for row in workload_rows
        ],
    }
    tail_health_path = Path(f"{report_path.with_suffix('')}.tail-health.json")
    tail_health_path.write_text(json.dumps(tail_health, indent=2) + "\n", encoding="utf-8")

    gate_result = {
        "ok": ok,
        "generatedAt": payload["generatedAt"],
        "comparisonStatus": comparison_status,
        "claimStatus": claim_status,
        "windowCount": requested_windows,
        "workloadCount": len(workload_rows),
        "claimableCount": claimable_count,
        "comparableCount": comparable_count,
        "reportPath": str(report_path),
        "failures": failures + [
            f"{row['id']}: {'; '.join(row['claimability']['reasons'])}"
            for row in workload_rows
            if row["claimability"]["reasons"]
        ],
    }
    gate_result_path = Path(f"{report_path.with_suffix('')}.claim-gate-result.json")
    gate_result_path.write_text(json.dumps(gate_result, indent=2) + "\n", encoding="utf-8")

    promotion_receipt = build_browser_claim_promotion_receipt.build_receipt(
        [report_path],
        claim_policy_path=policy_path,
        receipt_id=f"browser-claim-promotion:{report_path.stem}",
    )
    promotion_receipt_path.write_text(
        json.dumps(promotion_receipt, indent=2) + "\n",
        encoding="utf-8",
    )

    manifest = {
        "schemaVersion": 1,
        "generatedAt": payload["generatedAt"],
        "reportPath": str(report_path),
        "gateResultPath": str(gate_result_path),
        "tailHealthPath": str(tail_health_path),
        "promotionReceiptPath": str(promotion_receipt_path),
        "artifactsRoot": str(artifacts_root),
        "windowReports": [row["gateReport"] for row in per_window_rows],
    }
    manifest_path = Path(f"{report_path.with_suffix('')}.manifest.json")
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    output_paths.write_run_manifest_for_outputs(
        [report_path, gate_result_path, tail_health_path, promotion_receipt_path, manifest_path],
        {
            "runType": "browser-claim-gate",
            "fullRun": True,
            "claimGateRan": True,
            "browserGateRan": True,
            "windowCount": requested_windows,
            "status": "pass" if ok else "fail",
            "reportPath": str(report_path),
            "promotionReceiptPath": str(promotion_receipt_path),
        },
    )

    if args.emit_json or True:
        print(json.dumps(gate_result, indent=2))

    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
