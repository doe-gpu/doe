#!/usr/bin/env python3
"""Aggregate Gemma 4 31B + Qwen 3.6 27B pre-hardware parity evidence.

The receipt joins the r3-1-* and r3-2-* evidence trees (af32 + af16
lanes for both models) and gates the pre-hardware claim that every
model lane is bound to the same Doe CSL lowering surface. It is
intentionally stricter than a status summary: missing evidence, stale
host-plan hashes, compile failures, or version/hash skew all produce
``verdict=unbound``.

Each model record carries the canonical ``dtypeProfile`` sourced from
the lane's Doppler manifest ``quantizationInfo`` so receipt aggregators
downstream can split lanes by ``dtypeProfile.variantTag``. The joint
gate uses ``--require-lanes`` to control which lanes are mandatory;
af16 lanes are optional by default so the af32 joint gate remains
green while Track 1 / Track 2 land the af16 receipts.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bench.tools._lane_dtype_profile import (  # noqa: E402
    LaneDtypeProfileError,
    canonical_dtype_profile,
)

DOPPLER_REPO_ROOT = REPO_ROOT.parent / "doppler"

DEFAULT_OUT = REPO_ROOT / "bench/out/r3-cross-model-parity/receipt.json"

# Each lane points at the receipt paths the synthesizers produce for
# that lane. af32 lanes use legacy paths; af16 lanes use the
# `*-af16-*` suffix per `bench/tools/_lane_dtype_profile.receipt_path_lane_suffix`.
# `dopplerManifest` is read for `quantizationInfo` only — the receipt
# embeds the canonical dtypeProfile so consumers don't have to re-parse.
MODEL_DEFAULTS = {
    "gemma4_31b_af32": {
        "modelId": "gemma-4-31b-it-text-q4k-ehf16-af32",
        "modelFamily": "gemma4",
        "scale": "31B",
        "dopplerManifest": DOPPLER_REPO_ROOT / "models/local/gemma-4-31b-it-text-q4k-ehf16-af32/manifest.json",
        "compileReceipt": REPO_ROOT / "bench/out/r3-1-31b-full-graph-compile-attempt/receipt.json",
        "hostPlan": REPO_ROOT / "bench/out/r3-1-31b-manifest-fullgraph-compile-steps/host-plan.json",
        "compileRoot": REPO_ROOT / "bench/out/r3-1-31b-manifest-fullgraph-compile-steps/compile",
        "driverResult": REPO_ROOT / "bench/out/r3-1-31b-manifest-fullgraph-compile-steps/trace.json.driver-result.json",
        "budget": REPO_ROOT / "bench/out/r3-1-31b-manifest-simfabric-predicted-wallclock/budget.json",
        "frozenReferenceFixture": REPO_ROOT / "bench/fixtures/r3-1-31b-doppler-frozen/tsir-snapshots",
        "frozenReferenceValidation": REPO_ROOT / "bench/out/r3-1-31b-frozen-reference-validation/report.json",
        "perKernelSummary": REPO_ROOT / "bench/out/r3-1-31b-manifest-simfabric-per-kernel/summary.json",
    },
    "gemma4_31b_af16": {
        "modelId": "gemma-4-31b-it-text-q4k-ehf16-af16",
        "modelFamily": "gemma4",
        "scale": "31B",
        "dopplerManifest": DOPPLER_REPO_ROOT / "models/local/gemma-4-31b-it-text-q4k-ehf16-af16/manifest.json",
        "compileReceipt": REPO_ROOT / "bench/out/r3-1-31b-af16-full-graph-compile-attempt/receipt.json",
        "hostPlan": REPO_ROOT / "bench/out/r3-1-31b-af16-manifest-fullgraph-compile-steps/host-plan.json",
        "compileRoot": REPO_ROOT / "bench/out/r3-1-31b-af16-manifest-fullgraph-compile-steps/compile",
        "driverResult": REPO_ROOT / "bench/out/r3-1-31b-af16-manifest-fullgraph-compile-steps/trace.json.driver-result.json",
        "budget": REPO_ROOT / "bench/out/r3-1-31b-af16-manifest-simfabric-predicted-wallclock/budget.json",
        "frozenReferenceFixture": REPO_ROOT / "bench/fixtures/r3-1-31b-doppler-frozen-af16/tsir-snapshots",
        "frozenReferenceValidation": REPO_ROOT / "bench/out/r3-1-31b-af16-frozen-reference-validation/report.json",
        "perKernelSummary": REPO_ROOT / "bench/out/r3-1-31b-af16-manifest-simfabric-per-kernel/summary.json",
    },
    "qwen3_6_27b_af32": {
        "modelId": "qwen-3-6-27b-q4k-ehaf16",
        "modelFamily": "qwen3",
        "scale": "27B",
        "dopplerManifest": DOPPLER_REPO_ROOT / "models/local/qwen-3-6-27b-q4k-ehaf16/manifest.json",
        "compileReceipt": REPO_ROOT / "bench/out/r3-2-27b-full-graph-compile-attempt/receipt.json",
        "hostPlan": REPO_ROOT / "bench/out/r3-2-27b-manifest-fullgraph-compile-steps/host-plan.json",
        "compileRoot": REPO_ROOT / "bench/out/r3-2-27b-manifest-fullgraph-compile-steps/compile",
        "driverResult": REPO_ROOT / "bench/out/r3-2-27b-manifest-fullgraph-compile-steps/trace.json.driver-result.json",
        "budget": REPO_ROOT / "bench/out/r3-2-27b-manifest-simfabric-predicted-wallclock/budget.json",
        "frozenReferenceFixture": REPO_ROOT / "bench/fixtures/r3-2-27b-doppler-frozen",
        "frozenReferenceValidation": REPO_ROOT / "bench/out/r3-2-27b-frozen-reference-validation/report.json",
        "perKernelSummary": REPO_ROOT / "bench/out/r3-2-27b-manifest-simfabric-per-kernel/summary.json",
    },
    "qwen3_6_27b_af16": {
        "modelId": "qwen-3-6-27b-q4k-eaf16",
        "modelFamily": "qwen3",
        "scale": "27B",
        "dopplerManifest": DOPPLER_REPO_ROOT / "models/local/qwen-3-6-27b-q4k-eaf16/manifest.json",
        "compileReceipt": REPO_ROOT / "bench/out/r3-2-27b-af16-full-graph-compile-attempt/receipt.json",
        "hostPlan": REPO_ROOT / "bench/out/r3-2-27b-af16-manifest-fullgraph-compile-steps/host-plan.json",
        "compileRoot": REPO_ROOT / "bench/out/r3-2-27b-af16-manifest-fullgraph-compile-steps/compile",
        "driverResult": REPO_ROOT / "bench/out/r3-2-27b-af16-manifest-fullgraph-compile-steps/trace.json.driver-result.json",
        "budget": REPO_ROOT / "bench/out/r3-2-27b-af16-manifest-simfabric-predicted-wallclock/budget.json",
        "frozenReferenceFixture": REPO_ROOT / "bench/fixtures/r3-2-27b-doppler-frozen-af16",
        "frozenReferenceValidation": REPO_ROOT / "bench/out/r3-2-27b-af16-frozen-reference-validation/report.json",
        "perKernelSummary": REPO_ROOT / "bench/out/r3-2-27b-af16-manifest-simfabric-per-kernel/summary.json",
    },
}

# Default lanes that must bind for the joint gate to verdict=bound.
# af16 lanes are optional today: Track 1 has not yet captured the
# frozen references and Track 2 has not yet generated the af16
# compile receipts. Override with `--require-lanes` to enforce them
# once the receipts land.
DEFAULT_REQUIRED_LANES = ("gemma4_31b_af32", "qwen3_6_27b_af32")

SHARED_KERNELS = (
    ("gemv", "gemv", "gemv"),
    ("rmsnorm", "rmsnorm", "rmsnorm"),
    ("rope", "rope", "rope_partial"),
)
PER_KERNEL_FILES = ("layout.csl", "pe_program.csl", "pe_program.metadata.json")
_CSLC_EXEC_WRAPPER_RE = re.compile(
    r"^\s*exec\s+(?P<executable>\S+)\s+\"\$@\"(?P<extra_args>.*)$",
    re.MULTILINE,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument(
        "--allow-unbound",
        action="store_true",
        help="Write the receipt but exit 0 even when verdict=unbound.",
    )
    parser.add_argument(
        "--require-lanes",
        type=str,
        default=",".join(DEFAULT_REQUIRED_LANES),
        help=(
            "Comma-separated list of lane keys that must bind for "
            "verdict=bound. Lanes outside this list are reported in "
            "model_records but do not gate the joint verdict. Default "
            "covers af32 only; once af16 receipts land, pass "
            "`--require-lanes gemma4_31b_af32,gemma4_31b_af16,"
            "qwen3_6_27b_af32,qwen3_6_27b_af16` to enforce the full "
            "4-lane gate."
        ),
    )
    return parser.parse_args()


def _rel(path: Path | str | None) -> str | None:
    if path is None:
        return None
    p = Path(path)
    try:
        return str(p.resolve().relative_to(REPO_ROOT))
    except (ValueError, OSError):
        return str(path)


def _sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _sha256_file(path: Path) -> str | None:
    if not path.is_file():
        return None
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _resolve_cslc_wrapper(path: Path) -> dict[str, Any] | None:
    if not path.is_file() or path.suffix != ".sh":
        return None
    try:
        body = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None
    match = _CSLC_EXEC_WRAPPER_RE.search(body)
    if not match:
        return None
    resolved = Path(match.group("executable"))
    if not resolved.is_absolute():
        resolved = path.parent / resolved
    if not resolved.is_file():
        return None
    extra_args = match.group("extra_args").strip()
    return {
        "executable": str(resolved),
        "extraArgs": extra_args.split() if extra_args else [],
    }


def _load_json(path: Path, issues: list[str], label: str) -> dict[str, Any] | None:
    if not path.is_file():
        issues.append(f"{label}: missing {_rel(path)}")
        return None
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        issues.append(f"{label}: invalid JSON at {_rel(path)}: {exc}")
        return None
    if not isinstance(payload, dict):
        issues.append(f"{label}: expected JSON object at {_rel(path)}")
        return None
    return payload


def _git_head() -> str | None:
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "HEAD"],
            cwd=REPO_ROOT,
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def _parse_tsir_contract_version(schema_path: Path) -> int | None:
    if not schema_path.is_file():
        return None
    match = re.search(
        r"pub const CONTRACT_VERSION:\s*u32\s*=\s*(\d+);",
        schema_path.read_text(encoding="utf-8"),
    )
    return int(match.group(1)) if match else None


def _driver_targets(driver_result: dict[str, Any] | None) -> list[dict[str, Any]]:
    if not isinstance(driver_result, dict):
        return []
    compile_section = driver_result.get("compile")
    if not isinstance(compile_section, dict):
        return []
    targets = compile_section.get("targets")
    return [t for t in targets if isinstance(t, dict)] if isinstance(targets, list) else []


def _cslc_hash_from_driver(driver_path: Path, driver: dict[str, Any] | None) -> dict[str, Any]:
    targets = _driver_targets(driver)
    command = None
    for target in targets:
        raw_command = target.get("command")
        if isinstance(raw_command, list) and raw_command:
            command = raw_command
            break
    executable = str(command[0]) if command else None
    exe_path = Path(executable) if executable else None
    wrapper_hash = _sha256_file(exe_path) if exe_path is not None else None
    wrapper = _resolve_cslc_wrapper(exe_path) if exe_path is not None else None
    hash_executable = Path(wrapper["executable"]) if wrapper else exe_path
    executable_hash = (
        _sha256_file(hash_executable) if hash_executable is not None else None
    )
    fallback_hash = _sha256_bytes(
        json.dumps(
            {
                "driverResult": _rel(driver_path),
                "executable": str(hash_executable) if hash_executable else executable,
                "sdkMinVersionSource": "runtime/zig/src/compiler/wgsl/emit/csl/csl_spec.zig",
            },
            sort_keys=True,
        ).encode("utf-8")
    )
    record = {
        "driverResultPath": _rel(driver_path),
        "executable": str(hash_executable) if hash_executable else executable,
        "executableSha256": executable_hash,
        "toolchainHash": executable_hash or fallback_hash,
        "hashSource": (
            "cslc_wrapper_resolved_executable_sha256"
            if wrapper and executable_hash
            else "cslc_executable_sha256"
            if executable_hash
            else "driver_command_fallback"
        ),
    }
    if wrapper:
        record["wrapperExecutable"] = executable
        record["wrapperExecutableSha256"] = wrapper_hash
        record["wrapperExtraArgs"] = wrapper.get("extraArgs", [])
    return record


def _compile_receipt_summary(payload: dict[str, Any] | None, issues: list[str], label: str) -> dict[str, Any]:
    if payload is None:
        return {"bound": False}
    attempted = bool(payload.get("compileAttempted"))
    failed_count = int(payload.get("compileFailedCount") or 0)
    blocked_count = int(payload.get("compileBlockedCount") or 0)
    accepted_blocked_count = int(payload.get("compileAcceptedBlockedCount") or 0)
    succeeded_count = int(payload.get("compileSucceededCount") or 0)
    target_count = int(payload.get("compileTargetCount") or 0)
    blocker = payload.get("blocker")
    accepted_blockers = payload.get("acceptedCompileBlockers")
    if accepted_blockers is None:
        accepted_blockers = []
    if not isinstance(accepted_blockers, list):
        issues.append(f"{label}: acceptedCompileBlockers is not a list")
        accepted_blockers = []
    bound = attempted and failed_count == 0 and target_count > 0
    if not attempted:
        issues.append(f"{label}: compileAttempted is false")
    if failed_count != 0:
        issues.append(f"{label}: compileFailedCount={failed_count}")
    if accepted_blocked_count > blocked_count:
        issues.append(
            f"{label}: compileAcceptedBlockedCount exceeds compileBlockedCount"
        )
    if accepted_blocked_count != len(accepted_blockers):
        issues.append(
            f"{label}: acceptedCompileBlockers length does not match count"
        )
    if target_count <= 0:
        issues.append(f"{label}: compileTargetCount is empty")
    return {
        "artifactKind": payload.get("artifactKind"),
        "hostPlanHash": payload.get("hostPlanHash"),
        "compileAttempted": attempted,
        "compileTargetCount": target_count,
        "compileSucceededCount": succeeded_count,
        "compileBlockedCount": blocked_count,
        "compileAcceptedBlockedCount": accepted_blocked_count,
        "compileFailedCount": failed_count,
        "acceptedCompileBlockers": accepted_blockers,
        "blocker": blocker,
        "bound": bound,
    }


def _budget_summary(payload: dict[str, Any] | None, issues: list[str], label: str) -> dict[str, Any]:
    if payload is None:
        return {"bound": False}
    calibrated = bool(payload.get("calibrated"))
    grand = payload.get("grandPredictedCycles")
    issues_list = payload.get("issues") if isinstance(payload.get("issues"), list) else []
    bound = calibrated and isinstance(grand, int) and not issues_list
    if not calibrated:
        issues.append(f"{label}: simfabric budget is not calibrated")
    if not isinstance(grand, int):
        issues.append(f"{label}: grandPredictedCycles missing")
    if issues_list:
        issues.append(f"{label}: budget has issues: {issues_list}")
    return {
        "artifactKind": payload.get("artifactKind"),
        "hostPlanHash": payload.get("hostPlanHash"),
        "calibrated": calibrated,
        "grandPredictedCycles": grand,
        "phaseTotals": payload.get("phaseTotals"),
        "bound": bound,
    }


def _compare_kernel_files(
    gemma_root: Path,
    qwen_root: Path,
    logical_name: str,
    gemma_name: str,
    qwen_name: str,
    issues: list[str],
) -> dict[str, Any]:
    record: dict[str, Any] = {
        "logicalKernel": logical_name,
        "gemmaKernel": gemma_name,
        "qwenKernel": qwen_name,
        "artifacts": {},
    }
    match_all = True
    for filename in PER_KERNEL_FILES:
        gemma_path = gemma_root / gemma_name / filename
        qwen_path = qwen_root / qwen_name / filename
        gemma_hash = _sha256_file(gemma_path)
        qwen_hash = _sha256_file(qwen_path)
        match = gemma_hash is not None and gemma_hash == qwen_hash
        if not match:
            match_all = False
        record["artifacts"][filename] = {
            "gemmaSha256": gemma_hash,
            "qwenSha256": qwen_hash,
            "match": match,
        }
    record["match"] = match_all
    record["enforcement"] = (
        "observational: compile artifacts may differ because model compile "
        "params differ; invoker byte identity is enforced by "
        "runtime/zig/tests/wgsl/exec_v1_paired_gate_canary_test.zig"
    )
    return record


def _load_lane_dtype_profile(
    manifest_path: Path | None,
    issues: list[str],
    label: str,
) -> dict[str, str] | None:
    """Read `quantizationInfo` from the lane's Doppler manifest and
    return the canonical dtypeProfile. Missing manifest is recorded as
    a soft issue (the af16 Qwen sibling is uncommitted in Track 1 today)
    so the lane can still appear in the receipt with an absent profile.
    """
    if manifest_path is None or not Path(manifest_path).is_file():
        issues.append(f"{label}: doppler manifest missing at {_rel(manifest_path)}")
        return None
    try:
        manifest = json.loads(Path(manifest_path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        issues.append(f"{label}: doppler manifest unreadable: {exc}")
        return None
    try:
        return canonical_dtype_profile(manifest.get("quantizationInfo"))
    except LaneDtypeProfileError as err:
        issues.append(f"{label}: dtypeProfile rejected: {err}")
        return None


def _per_kernel_summary(
    payload: dict[str, Any] | None,
    issues: list[str],
    label: str,
) -> dict[str, Any]:
    """Project a manifest-shape per-kernel dispatch summary into the
    cross-model receipt. Missing summary becomes a soft `not_attempted`
    record so unattempted lanes don't break aggregation."""
    if payload is None:
        return {"verdict": "not_attempted", "kernelCount": 0, "blockedCount": 0, "boundCount": 0}
    totals = payload.get("totals") if isinstance(payload.get("totals"), dict) else {}
    kernels = payload.get("kernels") if isinstance(payload.get("kernels"), list) else []
    blockers = sorted({
        str(k.get("blocker"))
        for k in kernels
        if isinstance(k, dict) and k.get("blocker")
    })
    blocked_count = int(totals.get("blockedCount", 0))
    bound_count = int(totals.get("boundCount", 0))
    kernel_count = int(totals.get("kernelCount", len(kernels)))
    if kernel_count == 0:
        verdict = "not_attempted"
    elif blocked_count == 0 and bound_count == kernel_count:
        verdict = "bound"
    elif blocked_count > 0 and bound_count == 0:
        verdict = "blocked"
    else:
        verdict = "partial"
    return {
        "verdict": verdict,
        "kernelCount": kernel_count,
        "blockedCount": blocked_count,
        "boundCount": bound_count,
        "blockers": blockers,
        "hostPlanHash": payload.get("hostPlanHash"),
    }


def _frozen_reference_summary(
    payload: dict[str, Any] | None,
    issues: list[str],
    label: str,
) -> dict[str, Any]:
    if payload is None:
        return {"verdict": "not_attempted", "bound": False}
    return {
        "verdict": payload.get("verdict", "unknown"),
        "bound": bool(payload.get("bound")),
        "fixtureDigestCited": payload.get("fixtureDigestCited"),
        "laneKeyExpected": payload.get("laneKeyExpected"),
        "dtypeProfile": payload.get("dtypeProfile"),
    }


def build_receipt(required_lanes: tuple[str, ...] = DEFAULT_REQUIRED_LANES) -> dict[str, Any]:
    issues: list[str] = []
    required_set = set(required_lanes)
    unknown_required = required_set - set(MODEL_DEFAULTS.keys())
    if unknown_required:
        issues.append(f"unknown required lanes: {sorted(unknown_required)}")
    git_head = _git_head()
    if git_head is None:
        issues.append("unable to resolve Doe git HEAD")

    op_to_spec_path = REPO_ROOT / "runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_exec_v1.zig"
    tsir_schema_path = REPO_ROOT / "runtime/zig/src/compiler/tsir/schema.zig"
    csl_spec_path = REPO_ROOT / "runtime/zig/src/compiler/wgsl/emit/csl/csl_spec.zig"
    toolchains_path = REPO_ROOT / "config/toolchains.json"

    versions = {
        "doeGpuCommit": git_head,
        "runtimeZigCommit": git_head,
        "opToSpecTableVersion": _sha256_file(op_to_spec_path),
        "opToSpecTablePath": _rel(op_to_spec_path),
        "tsirSchemaVersion": _parse_tsir_contract_version(tsir_schema_path),
        "tsirSchemaSha256": _sha256_file(tsir_schema_path),
        "tsirSchemaPath": _rel(tsir_schema_path),
        "cslSpecSha256": _sha256_file(csl_spec_path),
        "toolchainsSha256": _sha256_file(toolchains_path),
    }
    for key, value in versions.items():
        if value is None and key.endswith(("Version", "Commit", "Sha256")):
            issues.append(f"version field {key} is unresolved")

    model_records: dict[str, Any] = {}
    toolchain_hashes: dict[str, str] = {}
    for model_key, cfg in MODEL_DEFAULTS.items():
        model_issues: list[str] = []
        is_required = model_key in required_set
        # Soft-loaders for missing receipts: required lanes promote
        # missing artifacts to top-level issues; optional lanes (af16
        # today) keep the issues local so the joint gate stays scoped.
        local_issues: list[str] = model_issues if is_required else []
        compile_receipt = _load_json(cfg["compileReceipt"], local_issues, f"{model_key}.compileReceipt")
        host_plan = _load_json(cfg["hostPlan"], local_issues, f"{model_key}.hostPlan")
        driver_result = _load_json(cfg["driverResult"], local_issues, f"{model_key}.driverResult")
        budget = _load_json(cfg["budget"], local_issues, f"{model_key}.budget")
        per_kernel = _load_json(cfg.get("perKernelSummary"), local_issues, f"{model_key}.perKernelSummary") if cfg.get("perKernelSummary") else None
        frozen_validation = _load_json(cfg.get("frozenReferenceValidation"), local_issues, f"{model_key}.frozenReferenceValidation") if cfg.get("frozenReferenceValidation") else None

        dtype_profile = _load_lane_dtype_profile(
            cfg.get("dopplerManifest"),
            local_issues,
            f"{model_key}.dopplerManifest",
        )

        compile_summary = _compile_receipt_summary(compile_receipt, local_issues, model_key)
        budget_record = _budget_summary(budget, local_issues, model_key)
        host_plan_hash = _sha256_file(cfg["hostPlan"]) if Path(cfg["hostPlan"]).is_file() else None
        if compile_summary.get("bound") and compile_summary.get("hostPlanHash") != host_plan_hash:
            local_issues.append(
                f"{model_key}: compile receipt hostPlanHash does not match host-plan file"
            )
        if budget_record.get("bound") and budget_record.get("hostPlanHash") != host_plan_hash:
            local_issues.append(
                f"{model_key}: budget hostPlanHash does not match host-plan file"
            )

        cslc_record = _cslc_hash_from_driver(cfg["driverResult"], driver_result) if driver_result else {"toolchainHash": None, "hashSource": "absent"}
        toolchain_hash = cslc_record.get("toolchainHash")
        if is_required and toolchain_hash:
            toolchain_hashes[model_key] = str(toolchain_hash)

        per_kernel_summary = _per_kernel_summary(per_kernel, local_issues, f"{model_key}.perKernel")
        frozen_summary = _frozen_reference_summary(frozen_validation, local_issues, f"{model_key}.frozenReference")

        targets = host_plan.get("compileTargets") if isinstance(host_plan, dict) else []
        record_bound = not local_issues
        if not is_required and not Path(cfg["compileReceipt"]).is_file():
            # Optional lane with no receipts yet — explicit not_attempted
            # rather than a list of missing-file issues.
            local_issues = [f"{model_key}: lane not yet attempted (optional af16 lane)"]
            record_bound = False
        model_records[model_key] = {
            "modelId": cfg["modelId"],
            "modelFamily": cfg.get("modelFamily"),
            "scale": cfg.get("scale"),
            "dtypeProfile": dtype_profile,
            "isRequiredForJointGate": is_required,
            "dopplerManifestPath": _rel(cfg.get("dopplerManifest")),
            "compileReceiptPath": _rel(cfg["compileReceipt"]),
            "hostPlanPath": _rel(cfg["hostPlan"]),
            "hostPlanSha256": host_plan_hash,
            "compileRoot": _rel(cfg["compileRoot"]),
            "compileTargetNames": [
                str(t.get("name"))
                for t in targets
                if isinstance(t, dict) and isinstance(t.get("name"), str)
            ],
            "compileReceipt": compile_summary,
            "simfabricBudget": budget_record,
            "cslcToolchain": cslc_record,
            "perKernelSummary": per_kernel_summary,
            "frozenReference": frozen_summary,
            "issues": local_issues,
            "bound": record_bound,
        }
        if is_required:
            issues.extend(local_issues)

    required_toolchain_set = {h for h in toolchain_hashes.values() if h}
    if len(required_toolchain_set) > 1:
        issues.append(f"cslc toolchain hash mismatch across required lanes: {toolchain_hashes}")

    shared_kernel_records = [
        _compare_kernel_files(
            MODEL_DEFAULTS["gemma4_31b_af32"]["compileRoot"],
            MODEL_DEFAULTS["qwen3_6_27b_af32"]["compileRoot"],
            logical,
            gemma_name,
            qwen_name,
            issues,
        )
        for logical, gemma_name, qwen_name in SHARED_KERNELS
    ]

    verdict = "bound" if not issues else "unbound"
    return {
        "schemaVersion": 2,
        "artifactKind": "doe_cross_model_parity_receipt",
        "receiptClass": "r3_gemma4_31b_qwen3_6_27b_prehardware_joint_gate",
        "verdict": verdict,
        "issues": issues,
        "versions": versions,
        "requiredLanes": list(required_lanes),
        "sharedCslcToolchainHash": next(iter(required_toolchain_set), None),
        "models": model_records,
        "sharedKernelArtifactComparison": shared_kernel_records,
        "claim": {
            "scope": (
                "Pre-hardware joint gate for the four Gemma 4 31B + Qwen 3.6 27B "
                "lanes (af32 + af16 each). Bound means every lane in `requiredLanes` "
                "has its r3 evidence tree present, host-plan hashes match compile + "
                "simfabric-budget receipts, cslc toolchain identity is shared across "
                "required lanes, Doe runtime/TSIR/opToSpec versions are shared, and "
                "shared-kernel invoker byte identity is pinned by the paired-gate "
                "canary. Each lane carries the canonical dtypeProfile sourced from "
                "its Doppler manifest's quantizationInfo."
            ),
            "notWhat": (
                "Not a Cerebras hardware receipt and not a performance claim. "
                "Optional lanes (af16 today) appear in `models` for tracking but "
                "do not gate the joint verdict unless added to --require-lanes. "
                "Hardware parity, TTFT, prefill tok/s, decode tok/s, and cost/token "
                "remain gated on governed WSE receipts."
            ),
        },
    }


def main() -> int:
    args = parse_args()
    required_lanes = tuple(
        s.strip() for s in args.require_lanes.split(",") if s.strip()
    )
    receipt = build_receipt(required_lanes=required_lanes)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    bound_lane_count = sum(
        1 for r in receipt["models"].values() if r.get("bound")
    )
    print(
        f"wrote {_rel(args.out)} verdict={receipt['verdict']} "
        f"issues={len(receipt['issues'])} "
        f"laneBound={bound_lane_count}/{len(receipt['models'])}"
    )
    if receipt["verdict"] == "bound" or args.allow_unbound:
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
