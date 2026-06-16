#!/usr/bin/env python3
"""INT4PLE af16 HostPlan streaming-runner front door.

This runner owns the operational contract for real af16 prefill/decode
through generated HostPlan/CSL. Gemma 4 31B is the default lane; other lanes
may pass explicit model, manifest, config, and claim fields. It performs the
source-derivable front-door work and delegates the session-scoped runtime
contract to ``gemma4_31b_af16_session_runtime``:

  - resolve the af16 Doppler manifest through its weightsRef primary;
  - validate shard presence and declared sizes without copying weight bytes;
  - expand the execution-v1 smoke config into prefill/decode dispatch plans;
  - bind the af16 HostPlan compile artifacts and per-kernel summary;
  - write the source-graph inventory used by the inference evidence gate;
  - emit a trace with the remaining named blockers.

It does not invent model output. ``status=output_ready`` requires the
session runtime to produce a real token/logit/KV transcript.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any

_REPO_ROOT = Path(__file__).resolve().parents[3]
_RUNNER_DIR = Path(__file__).resolve().parent
for _entry in (_REPO_ROOT, _RUNNER_DIR):
    if str(_entry) not in sys.path:
        sys.path.insert(0, str(_entry))

from gemma4_31b_af16_hostplan_common import (
    CHAIN_STEP_ADAPTER,
    CS_PYTHON,
    DEFAULT_CLAIM_NOT_WHAT,
    DEFAULT_CLAIM_SCOPE,
    DEFAULT_CLAIM_SUMMARY,
    DEFAULT_COMPILE_ROOT,
    DEFAULT_HOST_PLAN,
    DEFAULT_OUT,
    DEFAULT_PER_KERNEL_SUMMARY,
    DEFAULT_REFRESH_OUT_DIR,
    DEFAULT_RUNTIME_CONFIG,
    DEFAULT_SESSION_OUT_DIR,
    DEFAULT_SIMULATOR_PLAN,
    DEFAULT_SMOKE_CONFIG,
    DEFAULT_SOURCE_GRAPH_INVENTORY,
    DEFAULT_SOURCE_MANIFEST,
    LANE_KEY,
    MANIFEST_KERNEL_PROBE_RUNNER,
    MODEL_ID,
    REPO_ROOT,
    SESSION_ARTIFACT_PREFIX,
    TRACE_ARTIFACT_KIND,
    load_json,
    rel,
    resolve,
    sha256_file,
    sha256_json,
)
from bench.tools._inference_evidence_gate import (  # noqa: E402
    evaluate_inference_evidence_gate,
    session_runtime_evidence_is_complete,
)
from gemma4_31b_af16_hostplan_planning import (  # noqa: E402
    build_dispatch_plan,
    build_weight_staging_plan,
    expand_layer_weight_key,
    infer_weight_key_for_step,
    is_architecture_disabled_per_layer_input_weight,
    is_dense_lm_head_step,
    is_linear_attention_absent_v_projection,
    is_linear_attention_session_state_key,
    is_linear_attention_weight_key,
    is_model_level_decode_step,
    is_model_level_prefill_step,
    is_q4k_lm_head_step,
    is_self_attention_weight_key,
    layer_index_from_weight_key,
    linear_attention_layers_from_tensors,
    per_layer_input_block_enabled,
    phase_steps,
    resolve_required_weight,
    resolve_weight_root,
    self_attention_layers_from_tensors,
    tensor_candidates_for_key,
    tensor_exists,
)
from gemma4_31b_af16_session_runtime import (  # noqa: E402
    DEFAULT_LAUNCH_TIMEOUT_SECONDS,
    build_real_session_runtime,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source-doppler-manifest",
        type=Path,
        default=DEFAULT_SOURCE_MANIFEST,
    )
    parser.add_argument("--expected-model-id", default=MODEL_ID)
    parser.add_argument("--lane-key", default=LANE_KEY)
    parser.add_argument("--trace-artifact-kind", default=TRACE_ARTIFACT_KIND)
    parser.add_argument("--session-artifact-prefix", default=SESSION_ARTIFACT_PREFIX)
    parser.add_argument("--claim-scope", default=DEFAULT_CLAIM_SCOPE)
    parser.add_argument("--claim-not-what", default=DEFAULT_CLAIM_NOT_WHAT)
    parser.add_argument("--claim-summary", default=DEFAULT_CLAIM_SUMMARY)
    parser.add_argument("--smoke-config", type=Path, default=DEFAULT_SMOKE_CONFIG)
    parser.add_argument("--host-plan", type=Path, default=DEFAULT_HOST_PLAN)
    parser.add_argument("--simulator-plan", type=Path, default=DEFAULT_SIMULATOR_PLAN)
    parser.add_argument("--runtime-config", type=Path, default=DEFAULT_RUNTIME_CONFIG)
    parser.add_argument("--compile-root", type=Path, default=DEFAULT_COMPILE_ROOT)
    parser.add_argument(
        "--per-kernel-summary",
        type=Path,
        default=DEFAULT_PER_KERNEL_SUMMARY,
    )
    parser.add_argument("--prefill-token-count", type=int, default=2)
    parser.add_argument("--decode-token-count", type=int, default=2)
    parser.add_argument(
        "--prompt-token-id",
        type=int,
        action="append",
        default=[],
        help="Token id to place in the real-session prompt input. Repeatable.",
    )
    parser.add_argument("--cmaddr", default="")
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--refresh-per-kernel", action="store_true")
    parser.add_argument(
        "--refresh-jobs",
        type=int,
        default=1,
        help="Worker count passed to manifest_kernel_probe_runner.py.",
    )
    parser.add_argument(
        "--refresh-resume",
        action="store_true",
        help="Reuse existing non-dry-run per-kernel receipts on refresh.",
    )
    parser.add_argument(
        "--refresh-schedule",
        choices=["host-plan", "heavy-first"],
        default="host-plan",
        help="Per-kernel refresh launch order.",
    )
    parser.add_argument(
        "--refresh-timeout-seconds",
        type=int,
        default=1800,
        help=(
            "Per-kernel subprocess timeout passed to the refresh runner. "
            "Wide-output kernels use the HostPlan D2H region contract so "
            "timeouts remain fail-closed diagnostics rather than claim logic."
        ),
    )
    parser.add_argument(
        "--refresh-out-dir",
        type=Path,
        default=DEFAULT_REFRESH_OUT_DIR,
    )
    parser.add_argument(
        "--session-out-dir",
        type=Path,
        default=DEFAULT_SESSION_OUT_DIR,
    )
    parser.add_argument(
        "--source-graph-inventory",
        type=Path,
        default=None,
        help=(
            "Source execution-v1 kernel inventory artifact consumed by the "
            "inference evidence gate. Defaults next to --host-plan."
        ),
    )
    parser.add_argument(
        "--stop-after-launch",
        type=int,
        default=-1,
        help="Stop the real session after persisting this launch index.",
    )
    parser.add_argument(
        "--launch-timeout-seconds",
        type=int,
        default=DEFAULT_LAUNCH_TIMEOUT_SECONDS,
        help="Per HostPlan launch-step subprocess timeout. Use 0 to disable.",
    )
    parser.add_argument(
        "--session-lm-head-dispatch-mode",
        choices=["monolithic", "dense_gemv_width_tiled_session"],
        default="monolithic",
        help="Execution mode for real-session lm-head launches.",
    )
    parser.add_argument(
        "--session-lm-head-tile-width",
        type=int,
        default=120,
        help="Hidden-width tile for dense_gemv_width_tiled_session.",
    )
    parser.add_argument(
        "--session-lm-head-tile-jobs",
        type=int,
        default=1,
        help="Parallel tile subprocess count for dense_gemv_width_tiled_session.",
    )
    parser.add_argument(
        "--session-embed-roi-jobs",
        type=int,
        default=1,
        help="Parallel jobs for independent real-session embed/PLE ROI launches.",
    )
    parser.add_argument(
        "--session-embed-roi-hidden-per-pe",
        type=int,
        default=0,
        help=(
            "Override hidden elements per PE for real-session embed ROI "
            "launches; 0 uses the HostPlan compile parameter."
        ),
    )
    parser.add_argument(
        "--session-prefill-q4k-gemv-jobs",
        type=int,
        default=1,
        help="Parallel adapter workers for real-session prefill Q4K GEMV launches.",
    )
    parser.add_argument(
        "--session-prefill-q4k-gemv-output-pe-rows",
        type=int,
        default=1,
        help="Output PE rows per real-session prefill Q4K GEMV launch tile.",
    )
    parser.add_argument(
        "--session-prefill-q4k-gemv-adapter-step-budget",
        type=int,
        default=1,
        help=(
            "Maximum Q4K GEMV tile steps per SDK adapter process. "
            "Use 1 to isolate simulator state between tile launches."
        ),
    )
    parser.add_argument(
        "--session-ple-proj-dispatch-mode",
        choices=["monolithic_summa", "compact_summa_session"],
        default="monolithic_summa",
        help="Execution mode for real-session PLE projection launches.",
    )
    parser.add_argument(
        "--session-attention-prefill-dispatch-mode",
        choices=["hostplan_static", "compact_width_session"],
        default="hostplan_static",
        help="Execution mode for real-session prefill attention launches.",
    )
    parser.add_argument(
        "--session-lm-head-batch-runtime",
        action="store_true",
        help="Run session lm-head tiles through the batched SDK adapter.",
    )
    parser.add_argument(
        "--session-lm-head-batch-runtime-step-budget",
        type=int,
        default=16,
        help="Tile step group size for session lm-head batched runtime.",
    )
    parser.add_argument(
        "--session-lm-head-tile-dispatch-budget",
        type=int,
        default=0,
        help="Stop session lm-head tile dispatch after this many fresh tiles; 0 means unbounded.",
    )
    parser.add_argument(
        "--checkpoint-dir",
        type=Path,
        default=None,
        help="Persist per-launch HostPlan checkpoints under this directory.",
    )
    parser.add_argument(
        "--resume-from-checkpoint",
        type=Path,
        default=None,
        help="Resume from a previously persisted HostPlan checkpoint.",
    )
    parser.add_argument(
        "--ignore-checkpoint",
        action="store_true",
        help="Run from launch 0 even when --resume-from-checkpoint is set.",
    )
    parser.add_argument(
        "--allow-checkpoint-runner-drift",
        action="store_true",
        help=(
            "Allow resume when only the checkpoint runnerVersion field drifted. "
            "Manifest/config/compile-target identity and buffer hashes still validate."
        ),
    )
    parser.add_argument(
        "--allow-checkpoint-canonicalization-drift",
        action="store_true",
        help=(
            "Allow resume across the tiled_31b prefill_q4k_gemv "
            "canonicalization boundary. Only hostplanSha256 and compile-target "
            "hashes for the same target set may drift; buffer hashes still validate."
        ),
    )
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    return parser.parse_args()


def source_graph_inventory_path(args: argparse.Namespace) -> Path:
    raw_path = getattr(args, "source_graph_inventory", None)
    if raw_path is not None:
        return raw_path
    host_plan = resolve(args.host_plan)
    if host_plan == resolve(DEFAULT_HOST_PLAN):
        return DEFAULT_SOURCE_GRAPH_INVENTORY
    return host_plan.parent / "source-graph-inventory.json"


def _unique_kernel_keys(steps: list[dict[str, Any]]) -> list[str]:
    seen: set[str] = set()
    kernels: list[str] = []
    for step in steps:
        kernel = str(step.get("kernelKey") or "")
        if kernel and kernel not in seen:
            seen.add(kernel)
            kernels.append(kernel)
    return kernels


def _phase_tail(steps: list[dict[str, Any]], phase: str) -> list[str]:
    phase_steps = [
        step for step in steps
        if isinstance(step, dict) and step.get("phase") == phase
    ]
    return [
        str(step.get("kernelKey") or "")
        for step in phase_steps[-3:]
        if step.get("kernelKey")
    ]


def build_source_graph_inventory(
    *,
    smoke_config_path: Path,
    host_plan_path: Path,
    model_layer_count: int,
) -> dict[str, Any]:
    smoke = load_json(smoke_config_path)
    steps = [
        step for step in smoke.get("steps") or []
        if isinstance(step, dict)
    ]
    required_kernels = _unique_kernel_keys(steps)
    payload = {
        "schemaVersion": 1,
        "artifactKind": "execution_v1_source_graph_inventory",
        "source": rel(smoke_config_path),
        "sourceSha256": sha256_file(smoke_config_path),
        "hostPlanPath": rel(host_plan_path),
        "modelLayerCount": model_layer_count,
        "requiredKernels": required_kernels,
        "prefillTail": _phase_tail(steps, "prefill"),
        "decodeTail": _phase_tail(steps, "decode"),
    }
    payload["sourceGraphSha256"] = sha256_json({
        "steps": steps,
        "requiredKernels": required_kernels,
    })
    return payload


def write_source_graph_inventory(
    *,
    path: Path,
    smoke_config_path: Path,
    host_plan_path: Path,
    model_layer_count: int,
) -> dict[str, Any]:
    payload = build_source_graph_inventory(
        smoke_config_path=smoke_config_path,
        host_plan_path=host_plan_path,
        model_layer_count=model_layer_count,
    )
    out = resolve(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return {
        "path": rel(out),
        "sha256": sha256_file(out),
        "requiredKernels": payload["requiredKernels"],
        "prefillTail": payload["prefillTail"],
        "decodeTail": payload["decodeTail"],
    }


def build_per_kernel_refresh_command(
    *,
    host_plan: Path,
    compile_root: Path,
    out_dir: Path,
    cmaddr: str,
    jobs: int,
    resume: bool,
    schedule: str,
    timeout_seconds: int,
) -> list[str]:
    return [
        sys.executable,
        rel(MANIFEST_KERNEL_PROBE_RUNNER),
        "--host-plan", rel(host_plan),
        "--compile-root", rel(compile_root / "compiled"),
        "--source-root", rel(compile_root),
        "--out-dir", rel(out_dir),
        "--cs-python", rel(CS_PYTHON),
        "--adapter", rel(CHAIN_STEP_ADAPTER),
        "--jobs", str(jobs),
        "--schedule", schedule,
        "--timeout-seconds", str(timeout_seconds),
        *([] if not resume else ["--resume"]),
        *([] if not cmaddr else ["--cmaddr", cmaddr]),
    ]


def sdk_preflight() -> dict[str, Any]:
    if not CS_PYTHON.is_file():
        return {
            "status": "blocked",
            "class": "cs_python_unavailable",
            "detail": f"cs_python wrapper absent at {rel(CS_PYTHON)}",
        }
    proc = subprocess.run(
        [
            str(CS_PYTHON),
            "-c",
            "import cerebras.sdk.runtime.sdkruntimepybind as r; print('ok')",
        ],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    return {
        "status": "ready" if proc.returncode == 0 else "blocked",
        "class": "" if proc.returncode == 0 else "sdk_python_import_failed",
        "returncode": proc.returncode,
        "stdoutTail": proc.stdout.splitlines()[-20:],
        "stderrTail": proc.stderr.splitlines()[-20:],
    }


def maybe_refresh_per_kernel(args: argparse.Namespace) -> dict[str, Any]:
    command = build_per_kernel_refresh_command(
        host_plan=args.host_plan,
        compile_root=args.compile_root,
        out_dir=args.refresh_out_dir,
        cmaddr=args.cmaddr,
        jobs=args.refresh_jobs,
        resume=args.refresh_resume,
        schedule=args.refresh_schedule,
        timeout_seconds=args.refresh_timeout_seconds,
    )
    if not args.refresh_per_kernel:
        return {
            "requested": False,
            "command": command,
            "status": "not_requested",
        }
    preflight = sdk_preflight()
    if preflight["status"] != "ready":
        return {
            "requested": True,
            "command": command,
            "status": "blocked",
            "blocker": preflight,
        }
    proc = subprocess.run(
        command,
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    return {
        "requested": True,
        "command": command,
        "status": "completed" if proc.returncode == 0 else "blocked",
        "returncode": proc.returncode,
        "stdoutTail": proc.stdout.splitlines()[-20:],
        "stderrTail": proc.stderr.splitlines()[-20:],
    }


def per_kernel_summary_block(summary_path: Path) -> dict[str, Any]:
    if not resolve(summary_path).is_file():
        return {
            "path": rel(summary_path),
            "present": False,
            "totals": {},
            "blockedKernels": [],
            "blockerCounts": {},
            "staleDryRunOnly": False,
        }
    summary = load_json(summary_path)
    kernels = summary.get("kernels") or []
    blocked = [
        k
        for k in kernels
        if isinstance(k, dict) and k.get("verdict") != "bound"
    ]
    blocker_counts: dict[str, int] = {}
    for kernel in blocked:
        blocker = str(kernel.get("blocker") or "unknown")
        blocker_counts[blocker] = blocker_counts.get(blocker, 0) + 1
    return {
        "path": rel(summary_path),
        "present": True,
        "sha256": sha256_file(summary_path),
        "totals": summary.get("totals") or {},
        "blockedKernels": [k.get("kernel") for k in blocked],
        "blockerCounts": blocker_counts,
        "staleDryRunOnly": bool(blocked) and set(blocker_counts) == {"dry_run"},
    }

def build_blockers(
    *,
    weight_plan: dict[str, Any],
    per_kernel: dict[str, Any],
    refresh: dict[str, Any],
    real_session: dict[str, Any],
    execute: bool,
    requested_decode_steps: int | None = None,
) -> list[dict[str, Any]]:
    blockers: list[dict[str, Any]] = []
    session_evidence_ready = session_runtime_evidence_is_complete(
        real_session,
        requested_decode_steps=requested_decode_steps,
    )
    if (
        not weight_plan["weightRootPresent"]
        or weight_plan["missingShards"]
        or weight_plan["sizeMismatches"]
    ):
        blockers.append({
            "class": "weight_pack_not_stageable",
            "detail": (
                "The af16 weightsRef primary is not fully present by declared "
                "shard files and sizes."
            ),
        })
    if weight_plan["unresolvedWeightKeys"]:
        blockers.append({
            "class": "weight_symbol_mapping_incomplete",
            "detail": (
                "Some execution-v1 weightsKey entries do not resolve to a "
                "manifest tensor or sidecar f32 slice."
            ),
            "unresolvedWeightKeys": weight_plan["unresolvedWeightKeys"][:20],
        })
    refresh_requested = bool(refresh.get("requested"))
    refresh_blocked = refresh_requested and refresh.get("status") == "blocked"
    stale_dry_run_only = bool(per_kernel.get("staleDryRunOnly"))
    if (
        per_kernel.get("blockedKernels")
        and not (session_evidence_ready or (refresh_blocked and stale_dry_run_only))
    ):
        blockers.append({
            "class": "manifest_kernel_dispatch_not_bound",
            "detail": (
                "The current manifest-shape per-kernel summary still contains "
                "non-bound kernel verdicts."
            ),
            "blockedKernelCount": len(per_kernel["blockedKernels"]),
        })
    if refresh.get("requested") and refresh.get("status") == "blocked":
        refresh_blocker = refresh.get("blocker") or {}
        blockers.append({
            "class": refresh_blocker.get("class")
            or "per_kernel_refresh_blocked",
            "detail": (
                "The af16 per-kernel refresh command could not run to bound "
                "receipts on this host."
            ),
        })
    if real_session.get("status") == "blocked":
        blockers.append({
            "class": "real_session_runtime_blocked",
            "detail": (
                "The real prefill/decode session runtime contract could not "
                "produce a token/logit/KV transcript on this run."
            ),
            "blockers": real_session.get("blockers", [])[:20],
        })
    elif real_session.get("status") == "checkpoint_stopped":
        blockers.append({
            "class": "execution_stopped_at_checkpoint",
            "detail": (
                "The real session runtime stopped at the requested launch "
                "checkpoint before token/logit/KV transcript completion."
            ),
            "blockers": real_session.get("blockers", [])[:20],
        })
    if not execute:
        blockers.append({
            "class": "execution_not_requested",
            "detail": (
                "The runner emitted the session plan and staging checks "
                "without launching SDK dispatch."
            ),
        })
    return blockers


def source_graph_kernels_from_inventory(path: Path) -> list[str] | None:
    resolved = resolve(path)
    if not resolved.is_file():
        return None
    payload = load_json(resolved)
    kernels = payload.get("requiredKernels")
    if not isinstance(kernels, list):
        return None
    return [str(kernel) for kernel in kernels if str(kernel)]


def gate_blockers(
    host_plan_path: Path,
    per_kernel_summary_path: Path,
    source_graph_inventory: Path,
    *,
    real_session_runtime: dict[str, Any] | None = None,
    requested_decode_steps: int | None = None,
) -> list[dict[str, Any]]:
    host_plan = load_json(host_plan_path)
    per_kernel = (
        load_json(per_kernel_summary_path)
        if resolve(per_kernel_summary_path).is_file()
        else None
    )
    result = evaluate_inference_evidence_gate(
        host_plan=host_plan,
        per_kernel_summary=per_kernel,
        source_graph_kernels=source_graph_kernels_from_inventory(
            source_graph_inventory
        ),
        real_session_runtime=real_session_runtime,
        requested_decode_steps=requested_decode_steps,
    )
    if result.eligible:
        return []
    return [
        {
            "class": f"inference_evidence_gate.{reason.code}",
            "detail": reason.detail,
        }
        for reason in result.reasons
    ]


def build_trace(args: argparse.Namespace) -> dict[str, Any]:
    expected_model_id = str(
        getattr(args, "expected_model_id", MODEL_ID) or MODEL_ID
    )
    lane_key = str(getattr(args, "lane_key", LANE_KEY) or LANE_KEY)
    trace_artifact_kind = str(
        getattr(args, "trace_artifact_kind", TRACE_ARTIFACT_KIND)
        or TRACE_ARTIFACT_KIND
    )
    weight_plan = build_weight_staging_plan(
        manifest_path=args.source_doppler_manifest,
        smoke_config_path=args.smoke_config,
        expected_model_id=expected_model_id,
        lane_key=lane_key,
    )
    dispatch_plan = build_dispatch_plan(
        smoke_config_path=args.smoke_config,
        host_plan_path=args.host_plan,
        prefill_token_count=args.prefill_token_count,
        decode_token_count=args.decode_token_count,
        model_layer_count=int(weight_plan.get("modelLayerCount") or 0),
        linear_attention_layers=list(
            weight_plan.get("linearAttentionLayers") or []
        ),
        self_attention_layers=list(
            weight_plan.get("selfAttentionLayers") or []
        ),
    )
    source_inventory_path = source_graph_inventory_path(args)
    source_inventory = write_source_graph_inventory(
        path=source_inventory_path,
        smoke_config_path=args.smoke_config,
        host_plan_path=args.host_plan,
        model_layer_count=int(weight_plan.get("modelLayerCount") or 0),
    )
    refresh = maybe_refresh_per_kernel(args)
    per_kernel = per_kernel_summary_block(args.per_kernel_summary)
    real_session = build_real_session_runtime(args, dispatch_plan, weight_plan)
    blockers = build_blockers(
        weight_plan=weight_plan,
        per_kernel=per_kernel,
        refresh=refresh,
        real_session=real_session,
        execute=args.execute,
        requested_decode_steps=int(args.decode_token_count),
    )
    blockers.extend(
        gate_blockers(
            args.host_plan,
            args.per_kernel_summary,
            source_inventory_path,
            real_session_runtime=real_session,
            requested_decode_steps=int(args.decode_token_count),
        )
    )
    return {
        "schemaVersion": 1,
        "artifactKind": trace_artifact_kind,
        "modelId": expected_model_id,
        "laneKey": lane_key,
        "cslDtypeContract": weight_plan["cslDtypeContract"],
        "executionTarget": "system" if args.cmaddr else "simfabric",
        "requestedExecution": {
            "prefillTokenCount": args.prefill_token_count,
            "decodeTokenCount": args.decode_token_count,
            "execute": bool(args.execute),
        },
        "weightStaging": weight_plan,
        "dispatchPlan": dispatch_plan,
        "sourceGraphInventory": source_inventory,
        "perKernelRefresh": refresh,
        "perKernelEvidence": per_kernel,
        "realSessionRuntime": real_session,
        "status": "blocked" if blockers else "output_ready",
        "blockers": blockers,
        "claim": {
            "scope": str(getattr(args, "claim_scope", DEFAULT_CLAIM_SCOPE)),
            "notWhat": str(
                getattr(args, "claim_not_what", DEFAULT_CLAIM_NOT_WHAT)
            ),
            "summary": str(
                getattr(args, "claim_summary", DEFAULT_CLAIM_SUMMARY)
            ),
        },
    }


def main() -> int:
    args = parse_args()
    trace = build_trace(args)
    out = resolve(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(trace, indent=2) + "\n", encoding="utf-8")
    print(
        f"wrote {rel(out)} status={trace['status']} "
        f"blockers={len(trace['blockers'])}"
    )
    return 0 if trace["status"] == "output_ready" else 1


if __name__ == "__main__":
    sys.exit(main())
