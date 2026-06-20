#!/usr/bin/env python3
"""Sweep workgroup topologies on an f16-accumulation matmul kernel and map numeric divergence."""

from __future__ import annotations

import argparse
import collections
import copy
import datetime as dt
import hashlib
import json
import struct
import subprocess
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bench.lib.bench_utils import load_json
from bench.runners.run_determinism_probe import (
    RUNTIME_BIN,
    runtime_env,
)

DEFAULT_OUTPUT_ROOT = REPO_ROOT / "bench" / "out" / "workgroup-topology-sweep"
KERNEL_ROOT = REPO_ROOT / "bench" / "inference-pipeline" / "kernels"

WORKGROUP_VARIANTS = [
    {"id": "wg1", "size": 1, "kernel": "matmul_logits_f16accum_wg1.wgsl"},
    {"id": "wg64", "size": 64, "kernel": "matmul_logits_f16accum_wg64.wgsl"},
    {"id": "wg128", "size": 128, "kernel": "matmul_logits_f16accum_wg128.wgsl"},
    {"id": "wg256", "size": 256, "kernel": "matmul_logits_f16accum_wg256.wgsl"},
]

DEFAULT_PROFILE = {
    "vendor": "apple",
    "api": "metal",
    "family": "m3",
    "driver": "1.0.0",
}

BACKEND_LANE = "metal_doe_comparable"
QUEUE_WAIT_MODE = "process-events"
QUEUE_SYNC_MODE = "per-command"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--commands",
        required=True,
        help="Source command file JSON with f16accum matmul data.",
    )
    parser.add_argument(
        "--backend-lane",
        default=BACKEND_LANE,
        help="Backend lane for runtime invocation.",
    )
    parser.add_argument(
        "--runs",
        type=int,
        default=3,
        help="Repeat count per topology variant.",
    )
    parser.add_argument(
        "--timestamp",
        default=None,
        help="UTC timestamp label (default: current UTC time).",
    )
    parser.add_argument(
        "--output-root",
        default=str(DEFAULT_OUTPUT_ROOT),
        help="Output root for sweep artifacts.",
    )
    parser.add_argument("--vendor", default=None, help="Override profile vendor.")
    parser.add_argument("--api", default=None, help="Override profile api.")
    parser.add_argument("--family", default=None, help="Override profile family.")
    parser.add_argument("--driver", default=None, help="Override profile driver.")
    parser.add_argument(
        "--build",
        action="store_true",
        help="Build doe-zig-runtime before running.",
    )
    return parser.parse_args()


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def timestamp_label(raw: str | None) -> str:
    if raw:
        return raw
    return dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def resolve_repo_path(raw: str) -> Path:
    path = Path(raw)
    if path.is_absolute():
        return path
    return REPO_ROOT / path


def build_runtime() -> None:
    subprocess.run(
        ["zig", "build", "doe-zig-runtime"],
        cwd=REPO_ROOT / "runtime" / "zig",
        check=True,
        capture_output=True,
        text=True,
    )


def find_matmul_dispatch_index(commands: list[dict[str, Any]]) -> int | None:
    """Find the kernel_dispatch command index whose kernel looks like a matmul_logits kernel."""
    for index, command in enumerate(commands):
        kind = command.get("kind") or command.get("command") or ""
        if kind != "kernel_dispatch":
            continue
        kernel = command.get("kernel", "")
        if "matmul_logits" in kernel:
            return index
    return None


def find_sample_dispatch_index(commands: list[dict[str, Any]]) -> int | None:
    """Find the kernel_dispatch command for sample.wgsl."""
    for index, command in enumerate(commands):
        kind = command.get("kind") or command.get("command") or ""
        if kind != "kernel_dispatch":
            continue
        kernel = command.get("kernel", "")
        if kernel.endswith("sample.wgsl"):
            return index
    return None


def rewrite_commands_for_variant(
    commands: list[dict[str, Any]],
    variant: dict[str, Any],
    matmul_index: int,
) -> list[dict[str, Any]]:
    """Rewrite command list to use a different matmul kernel variant."""
    rewritten = copy.deepcopy(commands)
    dispatch = rewritten[matmul_index]
    dispatch["kernel"] = variant["kernel"]

    # Annotate for traceability
    dispatch["semanticOpId"] = "matmul.logits"
    dispatch["semanticStage"] = "workgroup_topology_sweep"
    dispatch["semanticPhase"] = "logits"
    dispatch["semanticExecutionPlanHash"] = f"wg-sweep-{variant['id']}"

    # Find output buffer handle from binding 3 (storage output)
    output_handle = None
    output_size = None
    for binding in dispatch.get("bindings", []):
        if binding.get("binding") == 3:
            output_handle = binding.get("resource_handle", binding.get("resourceHandle"))
            output_size = binding.get("buffer_size", binding.get("bufferSize"))
            break

    if output_handle is not None and output_size is not None:
        dispatch["captureBufferHandle"] = output_handle
        dispatch["captureOffset"] = 0
        dispatch["captureSize"] = output_size

    # Also annotate the sample dispatch if present
    sample_index = find_sample_dispatch_index(rewritten)
    if sample_index is not None:
        sample_cmd = rewritten[sample_index]
        sample_cmd["semanticOpId"] = "sample.token"
        sample_cmd["semanticStage"] = "workgroup_topology_sweep"
        sample_cmd["semanticPhase"] = "sample_token"
        sample_cmd["semanticExecutionPlanHash"] = f"wg-sweep-{variant['id']}"
        # Find output token buffer (binding 2)
        for binding in sample_cmd.get("bindings", []):
            if binding.get("binding") == 2:
                token_handle = binding.get("resource_handle", binding.get("resourceHandle"))
                token_size = binding.get("buffer_size", binding.get("bufferSize"))
                if token_handle is not None and token_size is not None:
                    sample_cmd["captureBufferHandle"] = token_handle
                    sample_cmd["captureOffset"] = 0
                    sample_cmd["captureSize"] = token_size
                    sample_cmd["decode"] = "u32le"
                break

    return rewritten


def decode_f32_buffer(path: Path) -> list[float]:
    payload = path.read_bytes()
    if len(payload) % 4 != 0:
        raise ValueError(f"expected 4-byte aligned payload, got {len(payload)} bytes from {path}")
    if not payload:
        return []
    return list(struct.unpack("<" + "f" * (len(payload) // 4), payload))


def decode_u32le(path: Path) -> int:
    payload = path.read_bytes()
    if len(payload) != 4:
        raise ValueError(f"expected 4-byte payload for u32le, got {len(payload)} bytes from {path}")
    return struct.unpack("<I", payload)[0]


def run_variant(
    *,
    variant: dict[str, Any],
    commands: list[dict[str, Any]],
    matmul_index: int,
    output_dir: Path,
    backend_lane: str,
    run_count: int,
) -> dict[str, Any]:
    """Run one workgroup topology variant through the runtime."""
    variant_id = variant["id"]
    variant_dir = output_dir / variant_id
    variant_dir.mkdir(parents=True, exist_ok=True)

    rewritten = rewrite_commands_for_variant(commands, variant, matmul_index)
    commands_path = variant_dir / f"{variant_id}.commands.json"
    commands_bytes = (json.dumps(rewritten, indent=2) + "\n").encode("utf-8")
    commands_path.write_bytes(commands_bytes)

    runs: list[dict[str, Any]] = []
    for run_index in range(run_count):
        trace_meta_path = variant_dir / f"run{run_index:03d}.meta.json"
        trace_jsonl_path = variant_dir / f"run{run_index:03d}.trace.jsonl"

        cmd = [
            str(RUNTIME_BIN),
            "--commands",
            str(commands_path),
            "--quirk-mode",
            "trace",
            "--vendor",
            DEFAULT_PROFILE["vendor"],
            "--api",
            DEFAULT_PROFILE["api"],
            "--family",
            DEFAULT_PROFILE["family"],
            "--driver",
            DEFAULT_PROFILE["driver"],
            "--backend",
            "native",
            "--backend-lane",
            backend_lane,
            "--execute",
            "--trace",
            "--trace-jsonl",
            str(trace_jsonl_path),
            "--trace-meta",
            str(trace_meta_path),
            "--kernel-root",
            str(KERNEL_ROOT),
            "--queue-wait-mode",
            QUEUE_WAIT_MODE,
            "--queue-sync-mode",
            QUEUE_SYNC_MODE,
            "--gpu-timestamp-mode",
            "off",
        ]

        completed = subprocess.run(
            cmd,
            cwd=REPO_ROOT,
            env=runtime_env(backend_lane),
            capture_output=True,
            text=True,
            check=False,
        )
        if completed.returncode != 0:
            raise RuntimeError(
                f"{variant_id} run {run_index} failed with code {completed.returncode}\n"
                f"stdout:\n{completed.stdout}\n\nstderr:\n{completed.stderr}"
            )

        meta = load_json(trace_meta_path)
        manifest_path_raw = meta.get("operatorRecordManifestPath")
        if not manifest_path_raw:
            raise RuntimeError(f"{variant_id} run {run_index} did not emit operatorRecordManifestPath")

        manifest_path = resolve_repo_path(manifest_path_raw)
        manifest = load_json(manifest_path)
        if not isinstance(manifest, list):
            raise RuntimeError(f"{variant_id} run {run_index} operator manifest must be a list")

        run_result: dict[str, Any] = {
            "runIndex": run_index,
            "traceMetaPath": str(trace_meta_path),
            "traceJsonlPath": str(trace_jsonl_path),
            "operatorManifestPath": str(manifest_path),
        }

        # Extract logits and token captures from manifest
        for row in manifest:
            semantic_op_id = row.get("semanticOpId")
            capture_info = row.get("capture", {})
            if not semantic_op_id or capture_info.get("status") != "ok":
                continue
            capture_path = resolve_repo_path(capture_info["path"])
            if semantic_op_id == "matmul.logits":
                logits = decode_f32_buffer(capture_path)
                run_result["logits"] = logits
                run_result["logitsSha256"] = sha256_bytes(capture_path.read_bytes())
                run_result["logitsCapturePath"] = str(capture_path)
            elif semantic_op_id == "sample.token":
                token = decode_u32le(capture_path)
                run_result["sampledToken"] = token
                run_result["tokenSha256"] = sha256_bytes(capture_path.read_bytes())

        runs.append(run_result)

    # Summarize across runs
    logits_digests = [r.get("logitsSha256") for r in runs if r.get("logitsSha256")]
    digest_counts = dict(collections.Counter(logits_digests))
    sampled_tokens = [r.get("sampledToken") for r in runs if r.get("sampledToken") is not None]
    token_counts = dict(collections.Counter(sampled_tokens))

    # Use the first run's logits as the representative value
    representative_logits = runs[0].get("logits", []) if runs else []
    representative_token = runs[0].get("sampledToken") if runs else None

    return {
        "variantId": variant_id,
        "workgroupSize": variant["size"],
        "kernel": variant["kernel"],
        "runCount": run_count,
        "commandsPath": str(commands_path),
        "stableAcrossRuns": len(digest_counts) == 1,
        "logitsDigestCounts": digest_counts,
        "tokenCounts": token_counts,
        "representativeLogits": representative_logits,
        "representativeToken": representative_token,
        "runs": [
            {
                "runIndex": r["runIndex"],
                "traceMetaPath": r["traceMetaPath"],
                "logitsSha256": r.get("logitsSha256"),
                "sampledToken": r.get("sampledToken"),
            }
            for r in runs
        ],
    }


def compare_variants(variant_results: list[dict[str, Any]]) -> dict[str, Any]:
    """Compare logits and tokens across all topology variants."""
    n = len(variant_results)
    if n < 2:
        return {"pairCount": 0, "flips": [], "divergences": []}

    flips: list[dict[str, Any]] = []
    divergences: list[dict[str, Any]] = []

    for i in range(n):
        for j in range(i + 1, n):
            va = variant_results[i]
            vb = variant_results[j]
            la = va["representativeLogits"]
            lb = vb["representativeLogits"]
            ta = va["representativeToken"]
            tb = vb["representativeToken"]

            if not la or not lb:
                continue

            # Token flip check
            token_flipped = ta is not None and tb is not None and ta != tb
            if token_flipped:
                flips.append({
                    "variantA": va["variantId"],
                    "variantB": vb["variantId"],
                    "workgroupSizeA": va["workgroupSize"],
                    "workgroupSizeB": vb["workgroupSize"],
                    "tokenA": ta,
                    "tokenB": tb,
                })

            # Per-logit divergence
            if len(la) == len(lb):
                row_divergences: list[dict[str, Any]] = []
                for row_index in range(len(la)):
                    if la[row_index] != lb[row_index]:
                        row_divergences.append({
                            "rowIndex": row_index,
                            "logitA": la[row_index],
                            "logitB": lb[row_index],
                            "delta": abs(la[row_index] - lb[row_index]),
                        })
                if row_divergences:
                    divergences.append({
                        "variantA": va["variantId"],
                        "variantB": vb["variantId"],
                        "workgroupSizeA": va["workgroupSize"],
                        "workgroupSizeB": vb["workgroupSize"],
                        "divergentRows": row_divergences,
                        "tokenFlipped": token_flipped,
                    })

    return {
        "pairCount": n * (n - 1) // 2,
        "flips": flips,
        "divergences": divergences,
    }


def build_topology_map(variant_results: list[dict[str, Any]]) -> dict[str, Any]:
    """Build a concise topology-to-result mapping for the summary."""
    entries: dict[str, Any] = {}
    for vr in variant_results:
        entries[vr["variantId"]] = {
            "workgroupSize": vr["workgroupSize"],
            "logits": vr["representativeLogits"],
            "sampledToken": vr["representativeToken"],
            "stableAcrossRuns": vr["stableAcrossRuns"],
        }
    return entries


def main() -> int:
    args = parse_args()

    if args.build:
        build_runtime()
    if not RUNTIME_BIN.exists():
        print(f"runtime binary missing: {RUNTIME_BIN}", file=sys.stderr)
        return 1

    commands_path = resolve_repo_path(args.commands)
    commands = load_json(commands_path)
    if not isinstance(commands, list):
        print(f"commands file must contain a JSON array: {commands_path}", file=sys.stderr)
        return 1

    matmul_index = find_matmul_dispatch_index(commands)
    if matmul_index is None:
        print(f"no matmul_logits kernel dispatch found in {commands_path}", file=sys.stderr)
        return 1

    if args.vendor:
        DEFAULT_PROFILE["vendor"] = args.vendor
    if args.api:
        DEFAULT_PROFILE["api"] = args.api
    if args.family:
        DEFAULT_PROFILE["family"] = args.family
    if args.driver:
        DEFAULT_PROFILE["driver"] = args.driver

    stamp = timestamp_label(args.timestamp)
    output_dir = resolve_repo_path(args.output_root) / stamp
    output_dir.mkdir(parents=True, exist_ok=True)

    source_sha256 = sha256_bytes(commands_path.read_bytes())

    print(f"Workgroup topology sweep: {len(WORKGROUP_VARIANTS)} variants, {args.runs} runs each", file=sys.stderr)
    print(f"Source commands: {commands_path}", file=sys.stderr)
    print(f"Output: {output_dir}", file=sys.stderr)

    variant_results: list[dict[str, Any]] = []
    for variant in WORKGROUP_VARIANTS:
        print(f"  Running {variant['id']} (workgroup_size={variant['size']})...", file=sys.stderr)
        result = run_variant(
            variant=variant,
            commands=commands,
            matmul_index=matmul_index,
            output_dir=output_dir,
            backend_lane=args.backend_lane,
            run_count=args.runs,
        )
        variant_results.append(result)
        logits_str = ", ".join(f"{v:.6f}" for v in result["representativeLogits"][:8])
        print(f"    logits=[{logits_str}...] token={result['representativeToken']}", file=sys.stderr)

    comparison = compare_variants(variant_results)
    topology_map = build_topology_map(variant_results)

    report = {
        "schemaVersion": 1,
        "tool": "run_workgroup_topology_sweep",
        "timestamp": stamp,
        "sourceCommandsPath": str(commands_path),
        "sourceCommandsSha256": source_sha256,
        "backendLane": args.backend_lane,
        "runsPerVariant": args.runs,
        "variants": variant_results,
        "comparison": comparison,
        "topologyMap": topology_map,
        "summary": {
            "variantCount": len(variant_results),
            "allVariantsStable": all(vr["stableAcrossRuns"] for vr in variant_results),
            "tokenFlipCount": len(comparison["flips"]),
            "logitDivergenceCount": len(comparison["divergences"]),
            "flippedPairs": [
                {
                    "a": f["variantA"],
                    "b": f["variantB"],
                    "tokenA": f["tokenA"],
                    "tokenB": f["tokenB"],
                }
                for f in comparison["flips"]
            ],
        },
    }

    report_path = output_dir / "workgroup-topology-sweep.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"\nReport: {report_path}", file=sys.stderr)

    # Print summary to stdout
    summary = report["summary"]
    print(json.dumps({
        "reportPath": str(report_path),
        "variantCount": summary["variantCount"],
        "allVariantsStable": summary["allVariantsStable"],
        "tokenFlipCount": summary["tokenFlipCount"],
        "logitDivergenceCount": summary["logitDivergenceCount"],
        "flippedPairs": summary["flippedPairs"],
    }, indent=2))

    return 0


if __name__ == "__main__":
    sys.exit(main())
