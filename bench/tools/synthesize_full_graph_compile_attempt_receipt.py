#!/usr/bin/env python3
"""Synthesize the 31B full-graph compile attempt receipt.

Mitigates "Full inference graph compile" from
docs/cerebras-model-ledgers.md (Remaining no-hardware evidence gaps).

The existing manifest-shape compile-attempt receipt
(`bench/out/r3-1-31b-manifest-compile-attempt/`) and the threshold
sweep (`bench/out/r3-1-31b-manifest-compile-sweep/`) test only the
transformer_layer_shape kernel. The steps-mode 31B host-plan
(`bench/out/r3-1-31b-manifest-fullgraph-compile-steps/host-plan.json`)
names the distinct compile targets and phase variants that make up the
manifest-shaped graph. A "full inference graph compile attempt" means:
materialize that steps-mode bundle root, attempt cslc on every emitted
target, and aggregate the per-target results.

This synthesizer reads the host-plan, enumerates compileTargets, and
emits a typed-blocker receipt that:
  - lists every compile target by name with its layout + pe_program
    paths (relative to the bundle compile root),
  - binds to the layer-block sweep's known threshold so reviewers can
    see which targets were expected to fail at manifest shape (those whose
    per-PE residency mirrors the layer-block kernel),
  - records actual cslc verdicts when the driver-result exists, and
    otherwise falls back to an explicit not-attempted preflight.

The receipt does not invent compile verdicts. When
`driver-result.json` is absent, every target stays `not_attempted`.
When it is present, each target mirrors the driver result exactly.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bench.tools._receipt_hash_guard import (  # noqa: E402
    ReceiptHashSpineError,
    enforce_receipt_hash_spine,
)
from bench.tools._lane_dtype_profile import (  # noqa: E402
    LaneDtypeProfileError,
    canonical_dtype_profile,
)


def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()
DEFAULT_HOSTPLAN = (
    REPO_ROOT
    / "bench/out/r3-1-31b-manifest-fullgraph-compile-steps/host-plan.json"
)
DEFAULT_DRIVER_RESULT = (
    REPO_ROOT
    / "bench/out/r3-1-31b-manifest-fullgraph-compile-steps/trace.json.driver-result.json"
)
DEFAULT_SWEEP_SUMMARY = (
    REPO_ROOT / "bench/out/r3-1-31b-manifest-compile-sweep/sweep-summary.json"
)
DEFAULT_OUT = (
    REPO_ROOT
    / "bench/out/r3-1-31b-full-graph-compile-attempt/receipt.json"
)
DEFAULT_BUNDLE_ROOT = (
    REPO_ROOT / "bench/out/r3-1-31b-manifest-fullgraph-compile-steps"
)

# WSE-3 per-PE budgets, mirroring runtime/zig/src/compiler/targets/wse3.zig:
# pe_working_memory_bytes (38 KB) + pe_persistent_pool_bytes (10 KB).
# `working` is the conservative upper bound the residency pass enforces
# for emitted-var residency; total includes the persistent pool that
# the SDK reserves for task-table / .data.hi / .filters overhead.
WSE3_PE_WORKING_BYTES = 38 * 1024
WSE3_PE_PERSISTENT_BYTES = 10 * 1024
WSE3_PE_TOTAL_BYTES = WSE3_PE_WORKING_BYTES + WSE3_PE_PERSISTENT_BYTES

ELEM_BYTES = {
    "f32": 4, "u32": 4, "i32": 4,
    "f16": 2, "u16": 2, "i16": 2,
    "u8": 1, "i8": 1,
}

_AS_CAST_INLINE = re.compile(r"@as\([a-z0-9_]+,\s*([^)]+)\)")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--host-plan", type=Path, default=DEFAULT_HOSTPLAN)
    p.add_argument("--driver-result", type=Path, default=DEFAULT_DRIVER_RESULT)
    p.add_argument(
        "--sweep-summary", type=Path, default=DEFAULT_SWEEP_SUMMARY
    )
    p.add_argument("--out", type=Path, default=DEFAULT_OUT)
    p.add_argument(
        "--bundle-root",
        type=Path,
        default=DEFAULT_BUNDLE_ROOT,
        help=(
            "Bundle root containing per-target compile/<name>/pe_program.metadata.json. "
            "Used to compute per-PE residency byte math for failed targets."
        ),
    )
    p.add_argument(
        "--manifest-size",
        type=int,
        default=4096,
        help=(
            "Sequence-size context to record for the manifest-shaped "
            "compile attempt."
        ),
    )
    p.add_argument(
        "--source-doppler-manifest",
        type=Path,
        default=None,
        help=(
            "Optional path to the source Doppler manifest.json. When set, "
            "the canonical dtypeProfile (weights/embeddings/lmHead/compute/"
            "variantTag) is read from manifest.quantizationInfo and embedded "
            "in the receipt under `dtypeProfile`. Required for af16 / "
            "non-af32 lane receipts so aggregators can split lanes "
            "post-hoc by dtypeProfile.variantTag."
        ),
    )
    return p.parse_args()


def rel(path: Path | str) -> str:
    path = Path(path)
    if path.is_absolute() and str(path).startswith(str(REPO_ROOT)):
        return str(path.relative_to(REPO_ROOT))
    return str(path)


def load_driver_targets(path: Path) -> dict[str, dict] | None:
    if not path.is_file():
        return None
    payload = json.loads(path.read_text(encoding="utf-8"))
    compile_section = payload.get("compile") if isinstance(payload, dict) else None
    if not isinstance(compile_section, dict):
        return None
    targets = compile_section.get("targets")
    if not isinstance(targets, list):
        return None
    out: dict[str, dict] = {}
    for target in targets:
        if not isinstance(target, dict):
            continue
        name = target.get("name")
        if isinstance(name, str) and name:
            out[name] = target
    return out


def compiled_output_path(bundle_root: Path, target_name: str) -> Path:
    return bundle_root / "compile" / "compiled" / target_name / "out.json"


def stale_stable_alias(name: str) -> str | None:
    if name.startswith("lm_head_prefill_width_tile_"):
        return name.replace(
            "lm_head_prefill_width_tile_",
            "lm_head_prefill_stable_width_tile_",
            1,
        )
    if name == "lm_head_prefill":
        return "lm_head_prefill_stable"
    return None


def resolve_size_expr(expr: str, scope: dict[str, int]) -> int | None:
    """Resolve a CSL sizeExpr against a scope of known integer values.

    Handles literals, single identifiers, `@as(u32, X)` casts, and
    simple `A * B * ...` products. Returns None when any sub-term is
    unresolved so the caller can defer the analysis instead of
    fabricating a number.
    """
    expr = expr.strip()
    # Strip inline @as(u32, X) casts wherever they appear; the inner
    # expression may include multiplication of multiple casts.
    prev = None
    while prev != expr:
        prev = expr
        expr = _AS_CAST_INLINE.sub(r"\1", expr).strip()
    try:
        return int(expr)
    except ValueError:
        pass
    if expr in scope:
        return scope[expr]
    if "*" in expr:
        product = 1
        for part in expr.split("*"):
            value = resolve_size_expr(part, scope)
            if value is None:
                return None
            product *= value
        return product
    return None


def build_resolution_scope(metadata: dict, params: dict[str, int]) -> dict[str, int]:
    scope: dict[str, int] = {k: int(v) for k, v in params.items()}
    for entry in metadata.get("compileTimeConstants", []) or []:
        if not isinstance(entry, dict):
            continue
        kind = entry.get("kind")
        name = entry.get("name")
        expr = entry.get("expr")
        if kind not in ("param", "const") or not name or not expr:
            continue
        if name in scope:
            continue
        value = resolve_size_expr(expr, scope)
        if value is not None:
            scope[name] = value
    return scope


def parse_linker_overlap(stderr_text: str) -> dict | None:
    overlap = re.search(
        r"section\s+(\.\w+)\s+virtual address range overlaps with\s+(\.\w+)",
        stderr_text,
    )
    bss_range = re.search(r"\.bss range is \[(0x[0-9a-fA-F]+),\s*(0x[0-9a-fA-F]+)\]", stderr_text)
    if not overlap and not bss_range:
        return None
    info: dict = {}
    if overlap:
        info["overlap"] = {
            "section": overlap.group(1),
            "overlapsWith": overlap.group(2),
        }
    if bss_range:
        lo = int(bss_range.group(1), 16)
        hi = int(bss_range.group(2), 16)
        info["bssRange"] = {
            "loHex": bss_range.group(1),
            "hiHex": bss_range.group(2),
            "spanBytes": hi - lo,
        }
    return info


def classify_redesign(
    target_name: str,
    var_bytes: list[dict],
    total_var_bytes: int,
    linker_info: dict | None,
) -> tuple[str, str]:
    is_kv = any(
        v["name"] in ("key_cache", "val_cache") and v["totalBytes"] >= 64 * 1024
        for v in var_bytes
    )
    if is_kv:
        return (
            "kv_cache_needs_slot_shard",
            "key_cache and val_cache are emitted at full kv_cache_len per PE. "
            "Redesign: shard kv_cache by position-slot stride (each PE owns "
            "ceil(max_seq_len / num_pes) slots × head_dim × 4 B); compute() "
            "no-ops when the decode position falls outside the local stride. "
            "Owning emitter: runtime/zig/src/compiler/tsir/emit_kernel_body.zig:emitCslKvWrite "
            "(plus symmetric emitCslKvRead).",
        )
    if "rmsnorm" in target_name and total_var_bytes > WSE3_PE_WORKING_BYTES:
        return (
            "rmsnorm_needs_fabric_reduce",
            "input/scale/output are each [hidden_size]f32 per PE; "
            "single-PE reduction algorithm. Redesign: shard hidden across "
            "PEs (each PE owns hidden_per_pe = ceil(hidden_size / width)), "
            "compute local sum_sq, allreduce_add across the PE row, broadcast "
            "inv_rms, apply locally. Owning emitter: "
            "runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_reduction.zig (NOT "
            "emit_kernel_body.zig — single-PE algorithm baked in).",
        )
    if "tiled" in target_name and total_var_bytes > WSE3_PE_WORKING_BYTES:
        return (
            "tiled_matmul_needs_smaller_per_pe_tiles",
            "Per-PE SUMMA tiles A_tile/B_tile/C_tile/A_buf/B_buf at "
            "Mt=Kt=Nt=64 sum to ~80 KB (5 × 64*64*4). Redesign: shrink "
            "the per-PE block size (e.g. Mt=Kt=Nt=32 → 5 × 4 KB = 20 KB), "
            "or fold A_buf/B_buf into A_tile/B_tile via a ping-pong "
            "single-buffer. The .bss/.filters overlap is downstream of "
            "the oversize .bss. Owning emitter/planner: "
            "runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_matmul.zig + "
            "runtime/zig/src/spatial/csl/csl_host_plan_tool.zig (block-size choice in "
            "the tiled_matmul compileParams branch).",
        )
    if linker_info and total_var_bytes <= WSE3_PE_WORKING_BYTES:
        return (
            "linker_section_overlap",
            "Emitted vars fit in the working budget; failure is .bss/.filters "
            "virtual-address overlap from collectives_2d/queue static "
            "reservations. Redesign: trim collectives_2d DSR/queue counts, "
            "or shrink imported module footprint. Owning emitter: "
            "runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_matmul.zig (layout-side "
            "@set_tile_code module imports).",
        )
    return (
        "unclassified_residency_overflow",
        f"Total var bytes {total_var_bytes} exceeds WSE-3 per-PE working "
        f"budget {WSE3_PE_WORKING_BYTES}. No taxonomy match yet — review "
        "stderr and pe_program.metadata.json by hand and add a typed "
        "redesign class to bench/tools/synthesize_full_graph_compile_attempt_receipt.py.",
    )


def compute_residency_analysis(
    target_name: str,
    bundle_root: Path,
    params: dict[str, int],
    stderr_path_rel: str | None,
) -> dict | None:
    metadata_path = bundle_root / "compile" / target_name / "pe_program.metadata.json"
    if not metadata_path.is_file():
        return None
    try:
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None

    scope = build_resolution_scope(metadata, params)
    var_bytes: list[dict] = []
    unresolved: list[str] = []
    total_bytes = 0
    for var in metadata.get("variables", []) or []:
        if not isinstance(var, dict):
            continue
        name = var.get("name", "")
        size_expr = var.get("sizeExpr", "")
        elem_type = var.get("elemType", "")
        elements = resolve_size_expr(size_expr, scope)
        elem_b = ELEM_BYTES.get(elem_type)
        if elements is None or elem_b is None:
            unresolved.append(name)
            continue
        total = elements * elem_b
        total_bytes += total
        var_bytes.append({
            "name": name,
            "sizeExpr": size_expr,
            "elements": elements,
            "elemType": elem_type,
            "elemBytes": elem_b,
            "totalBytes": total,
        })

    linker_info = None
    if stderr_path_rel:
        stderr_path = REPO_ROOT / stderr_path_rel
        if stderr_path.is_file():
            try:
                stderr_text = stderr_path.read_text(encoding="utf-8", errors="replace")
                linker_info = parse_linker_overlap(stderr_text)
            except OSError:
                linker_info = None

    redesign_class, redesign_detail = classify_redesign(
        target_name, var_bytes, total_bytes, linker_info
    )
    over_budget = total_bytes - WSE3_PE_WORKING_BYTES
    return {
        "perPeWorkingBudgetBytes": WSE3_PE_WORKING_BYTES,
        "perPeTotalBudgetBytes": WSE3_PE_TOTAL_BYTES,
        "totalVarBytes": total_bytes,
        "overWorkingBudgetBytes": over_budget,
        "fitsInWorkingBudget": over_budget <= 0,
        "varBytes": sorted(var_bytes, key=lambda v: -v["totalBytes"]),
        "unresolvedVars": unresolved,
        **({"linkerSectionAnalysis": linker_info} if linker_info else {}),
        "redesignClass": redesign_class,
        "redesignDetail": redesign_detail,
    }


def main() -> int:
    args = parse_args()
    if not args.host_plan.is_file():
        sys.stderr.write(
            f"synthesize_full_graph_compile_attempt_receipt: host-plan "
            f"{args.host_plan} not found\n"
        )
        return 2
    host_plan = json.loads(args.host_plan.read_text(encoding="utf-8"))
    compile_targets = host_plan.get("compileTargets") or []
    if not compile_targets:
        sys.stderr.write(
            "synthesize_full_graph_compile_attempt_receipt: host-plan "
            "has no compileTargets\n"
        )
        return 2
    driver_targets = load_driver_targets(args.driver_result)

    sweep_summary = None
    if args.sweep_summary.is_file():
        sweep_summary = json.loads(
            args.sweep_summary.read_text(encoding="utf-8")
        )

    target_records = []
    compiled_output_targets: list[str] = []
    stale_driver_aliases: list[dict] = []
    for target in compile_targets:
        if not isinstance(target, dict):
            continue
        name = str(target.get("name", "unknown"))
        driver_target = driver_targets.get(name) if driver_targets is not None else None
        alias_name = stale_stable_alias(name)
        alias_driver_target = (
            driver_targets.get(alias_name)
            if driver_target is None
            and alias_name is not None
            and driver_targets is not None
            else None
        )
        compiled_out = compiled_output_path(args.bundle_root, name)
        compile_verdict = "not_attempted"
        verdict_source = None
        failure_code = None
        stderr_path = None
        stdout_path = None
        command = None
        if isinstance(driver_target, dict):
            compile_verdict = str(driver_target.get("status", "unknown"))
            verdict_source = "driver_result"
            failure_code = driver_target.get("failureCode")
            stderr_path = driver_target.get("stderrPath")
            stdout_path = driver_target.get("stdoutPath")
            command = driver_target.get("command")
        elif compiled_out.is_file():
            compile_verdict = "succeeded"
            verdict_source = "compiled_output_artifact"
            compiled_output_targets.append(name)
            if isinstance(alias_driver_target, dict):
                stale_driver_aliases.append(
                    {
                        "currentTargetName": name,
                        "staleDriverTargetName": alias_driver_target.get("name"),
                        "staleDriverStatus": alias_driver_target.get("status"),
                    }
                )
        params_dict = target.get("compileParams") or {}
        residency = None
        if compile_verdict not in ("succeeded", "not_attempted"):
            residency = compute_residency_analysis(
                name,
                args.bundle_root,
                {k: int(v) for k, v in params_dict.items() if isinstance(v, (int, str)) and str(v).lstrip("-").isdigit()},
                stderr_path,
            )
        target_records.append(
            {
                "name": name,
                "layout": target.get("layout", ""),
                "peProgram": target.get("peProgram", ""),
                "compileVerdict": compile_verdict,
                **({"verdictSource": verdict_source} if verdict_source else {}),
                "compileSize": args.manifest_size,
                "compileParams": params_dict,
                **({"failureCode": failure_code} if failure_code else {}),
                **({"stderrPath": rel(stderr_path)} if stderr_path else {}),
                **({"stdoutPath": rel(stdout_path)} if stdout_path else {}),
                **({"command": command} if isinstance(command, list) else {}),
                **(
                    {
                        "compiledOutputPath": rel(compiled_out),
                        "compiledOutputSha256": _sha256_file(compiled_out),
                    }
                    if compiled_out.is_file()
                    else {}
                ),
                **({"residencyAnalysis": residency} if residency else {}),
            }
        )

    threshold_note = None
    if sweep_summary is not None:
        threshold = sweep_summary.get("threshold") or {}
        last_passing = threshold.get("lastPassing")
        first_failing = threshold.get("firstFailing")
        threshold_note = {
            "sourceSweepPath": str(
                args.sweep_summary.relative_to(REPO_ROOT)
                if args.sweep_summary.is_absolute()
                and str(args.sweep_summary).startswith(str(REPO_ROOT))
                else args.sweep_summary
            ),
            "lastPassingLayerBlockSize": last_passing,
            "firstFailingLayerBlockSize": first_failing,
            "implication": (
                f"transformer_layer_shape compiles up to size={last_passing} "
                f"and fails at size>={first_failing}. Compile targets that "
                f"share its per-PE residency profile may inherit the same "
                f"failure pattern at manifest shape. The receipt uses this "
                f"sweep as context only; per-target compileVerdict fields "
                f"are measured when driver-result is present."
            ),
        }

    attempted = driver_targets is not None or bool(compiled_output_targets)
    failed_targets = [
        target
        for target in target_records
        if target.get("compileVerdict") not in ("succeeded", "not_attempted")
    ]
    succeeded_targets = [
        target
        for target in target_records
        if target.get("compileVerdict") == "succeeded"
    ]
    target_count_label = str(len(target_records))

    redesign_summary: dict[str, list[str]] = {}
    for target in failed_targets:
        ra = target.get("residencyAnalysis")
        if not isinstance(ra, dict):
            continue
        cls = ra.get("redesignClass")
        if not isinstance(cls, str):
            continue
        redesign_summary.setdefault(cls, []).append(target["name"])
    source_driver_result = (
        rel(args.driver_result)
        if args.driver_result.is_file()
        else None
    )
    exact_driver_only = attempted and driver_targets is not None and not compiled_output_targets
    mixed_driver_and_output = attempted and bool(compiled_output_targets)

    host_plan_hash = _sha256_file(args.host_plan)
    dtype_profile: dict[str, str] | None = None
    if args.source_doppler_manifest is not None:
        if not args.source_doppler_manifest.is_file():
            sys.stderr.write(
                "synthesize_full_graph_compile_attempt_receipt: "
                f"--source-doppler-manifest {args.source_doppler_manifest} "
                "not found\n"
            )
            return 2
        try:
            source_manifest = json.loads(
                args.source_doppler_manifest.read_text(encoding="utf-8")
            )
        except json.JSONDecodeError as err:
            sys.stderr.write(
                "synthesize_full_graph_compile_attempt_receipt: "
                f"--source-doppler-manifest decode failed: {err}\n"
            )
            return 2
        try:
            dtype_profile = canonical_dtype_profile(
                source_manifest.get("quantizationInfo")
            )
        except LaneDtypeProfileError as err:
            sys.stderr.write(
                "synthesize_full_graph_compile_attempt_receipt: "
                f"source-doppler-manifest dtypeProfile rejected: {err}\n"
            )
            return 2
    receipt = {
        "schemaVersion": 1,
        "artifactKind": "doe_full_graph_compile_attempt_receipt",
        "modelId": host_plan.get("modelId")
        or (host_plan.get("contract") if isinstance(host_plan.get("contract"), str) else "unknown"),
        "target": host_plan.get("target", "wse3"),
        "manifestSize": args.manifest_size,
        "sourceHostPlan": rel(args.host_plan),
        "hostPlanPath": rel(args.host_plan),
        "hostPlanHash": host_plan_hash,
        "sourceDriverResult": source_driver_result,
        "layoutMaterialization": {
            "tool": "runtime/zig/zig-out/bin/doe-csl-host-plan-tool",
            "invocation": "--input runtime/zig/examples/execution-v1/gemma-4-31b-smoke.json --bundle-root bench/out/r3-1-31b-manifest-fullgraph-compile-steps --mode steps",
            "status": "succeeded",
        },
        "compileTargetCount": len(target_records),
        "compileAttempted": attempted,
        "compileSucceededCount": len(succeeded_targets),
        "compileFailedCount": len(failed_targets),
        "compileTargets": target_records,
        "compileEvidenceSources": {
            "driverResultPresent": driver_targets is not None,
            "compiledOutputArtifactTargets": compiled_output_targets,
            "staleDriverAliases": stale_driver_aliases,
            "interpretation": (
                "Driver-result rows are authoritative when they match the "
                "current host-plan target name. For renamed lm-head width "
                "tiles, existing clean compiled/<target>/out.json artifacts "
                "are cited as compile-output evidence and stale _stable "
                "driver rows are recorded only as historical aliases."
            ),
        },
        **({"redesignSummary": redesign_summary} if redesign_summary else {}),
        "thresholdNote": threshold_note,
        "blocker": {
            "class": (
                "manifest_shape_compile_targets_failed"
                if attempted and failed_targets
                else (
                    "none"
                    if attempted
                    else "full_graph_compile_loop_absent"
                )
            ),
            "detail": (
                (
                    "steps-mode layout materialization ran. Current host-plan "
                    "target verdicts are backed by exact driver-result rows "
                    "where available and by existing clean compiled-output "
                    "artifacts for renamed lm-head width tiles. Stale _stable "
                    "driver rows are recorded as historical aliases only."
                )
                if mixed_driver_and_output
                else (
                    "steps-mode layout materialization and cslc iteration "
                    "both ran. Failed targets now carry measured failureCode "
                    "values in compileTargets[]."
                )
                if exact_driver_only
                else (
                    "steps-mode layout materialization and compile-output "
                    "artifacts are present for current host-plan targets. "
                    "No driver-result rows were available."
                )
                if attempted
                else (
                    "steps-mode host-plan materialization is the expected "
                    "path, but driver-result.json is absent, so no measured "
                    "cslc verdicts are attached to this receipt."
                )
            ),
            "hostPlanToolFailure": {
                "tool": "runtime/zig/zig-out/bin/doe-csl-host-plan-tool",
                "invocation": "--input runtime/zig/examples/execution-v1/gemma-4-31b-smoke.json --bundle-root bench/out/r3-1-31b-manifest-fullgraph-compile-steps --mode steps",
                "exitClass": "none",
                "site": None,
                "implication": "The previous malformed-manifest preflight is closed for the steps-mode path; layout.csl and pe_program.csl files now materialize before cslc runs.",
            },
            "namedRunnerExtensions": [
                "(optional) bench/gates/full_graph_compile_attempt_gate.py: "
                "block release until the receipt has measured verdicts for "
                "every target and the accepted failure taxonomy is explicit.",
            ],
        },
        **({"dtypeProfile": dtype_profile} if dtype_profile is not None else {}),
        "claim": {
            "scope": (
                "31B steps-mode full-graph compile target inventory is "
                f"pinned. The receipt records {target_count_label} named "
                "targets, measured compile verdicts when present, and the "
                "layer-block threshold context."
            ),
            "notWhat": (
                "Not a hardware receipt. Not a manifest-shape inference "
                "success. A failed compile target is a typed blocker, not a "
                "runtime result."
            ),
            "summary": (
                f"31B steps-mode host-plan names {target_count_label} "
                "compile targets at manifest shape; cslc verdicts are "
                "attached when driver-result.json is present."
            ),
        },
    }

    try:
        enforce_receipt_hash_spine(receipt, repo_root=REPO_ROOT)
    except ReceiptHashSpineError as err:
        sys.stderr.write(
            "synthesize_full_graph_compile_attempt_receipt: receipt hash "
            f"spine rejected emit:\n  {err}\n"
        )
        return 2

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(
        json.dumps(receipt, indent=2) + "\n", encoding="utf-8"
    )
    print(
        f"wrote {args.out} (typed blocker, "
        f"compileTargetCount={len(target_records)}, "
        f"compileAttempted={attempted})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
