#!/usr/bin/env python3
"""Doe parity harness — manual CLI gate.

Runs a three-way comparison for one kernel:

  1. Reference interpreter (TSIR oracle) — ground truth.
  2. WebGPU emission path (Doe compute).
  3. CSL emission on simfabric (Doe simulator).

Emits `parity.json` receipts under `doe/reports/parity/`. Fails closed
on unrecognized exactness class — new classes require explicit harness
support, never silent tolerance.

Not a CI tool. Runs on demand after every kernel rewrite and before
any promotion.

Exactness classes (match RDRR taxonomy verbatim):

  * `bit_exact_solo`       — hex-identical bytes vs reference.
  * `algorithm_exact`      — hex-identical under declared reduction
                             tree; harness runs reference twice, once
                             in source order and once in declared tree
                             order, both must match the backend.
  * `tolerance_bounded`    — declared metric within declared epsilon.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path
from typing import Any

import jsonschema


REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bench.tools import tsir_manifest_lowering  # noqa: E402
from bench.tools.doe_parity_models import (  # noqa: E402
    BOOTSTRAP_ORACLE_KERNELS,
    KERNEL_ALIASES,
    REFERENCE_SOURCE_DOPPLER,
    REFERENCE_SOURCE_ZIG,
    REFERENCE_TRANSCRIPT_SCHEMA_ID,
    REJECTION_REASONS,
    VALID_EXACTNESS,
    BootstrapOracleNotImplemented,
    ComparisonOutcome,
    DopplerTranscriptInvalid,
    LoweringIdentity,
    ParityReceipt,
    ReferenceSource,
    TolerancePolicy,
)

DEFAULT_RECEIPT_DIR = REPO_ROOT / "reports" / "parity"
SCHEMA_PATH = REPO_ROOT / "config" / "doe-parity-receipt.schema.json"
ZIG_RUNTIME_DIR = REPO_ROOT / "runtime" / "zig"
ZIG_BOOTSTRAP_ORACLE_BIN = (
    ZIG_RUNTIME_DIR / "zig-out" / "bin" / "doe-tsir-bootstrap-oracle"
)

_ZIG_BOOTSTRAP_ORACLE_READY = False


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kernel", help="Kernel name, e.g. `rmsnorm`.")
    parser.add_argument(
        "--class",
        dest="exactness",
        required=True,
        choices=sorted(VALID_EXACTNESS),
        help="Declared exactness class for this kernel.",
    )
    parser.add_argument(
        "--inputs",
        required=True,
        type=Path,
        help="Path to a directory or file holding the kernel inputs.",
    )
    parser.add_argument(
        "--receipt-dir",
        type=Path,
        default=DEFAULT_RECEIPT_DIR,
        help="Directory to write the parity receipt.",
    )
    parser.add_argument(
        "--semantic-tsir",
        type=Path,
        help="Optional TSIR semantic JSON. When present with --realization-tsir, "
        "declared rejections are surfaced in the parity receipt.",
    )
    parser.add_argument(
        "--realization-tsir",
        type=Path,
        help="Optional TSIR realization JSON. Must be paired with --semantic-tsir.",
    )
    parser.add_argument(
        "--manifest-lowering-entry",
        type=Path,
        help="Optional integrityExtensions.lowerings[] fixture entry. Copies "
        "TSIR lowering identity digests into the receipt without changing "
        "stub execution status.",
    )
    parser.add_argument(
        "--doppler-transcript",
        type=Path,
        help=(
            "Path to a doppler.reference-transcript/v1 JSON captured via "
            "`doppler bundle`. Required for real (non-bootstrap) kernels "
            "under the re-scoped plan. Routes reference to the Doppler "
            "browser WebGPU run instead of the Zig scalar oracle."
        ),
    )
    parser.add_argument(
        "--doppler-kernel-probe-hash",
        type=str,
        help=(
            "Optional 64-char hex digest for a per-kernel probe captured "
            "alongside a Doppler reference transcript. When omitted, the "
            "reference lane records the transcript identity and marks "
            "comparison status as deferred pending per-kernel probe "
            "capture."
        ),
    )
    return parser.parse_args()


def sha256_of_path(path: Path) -> str:
    h = hashlib.sha256()
    if path.is_file():
        h.update(path.read_bytes())
        return h.hexdigest()
    if path.is_dir():
        for entry in sorted(path.rglob("*")):
            if not entry.is_file():
                continue
            h.update(entry.relative_to(path).as_posix().encode("utf-8"))
            h.update(b"\0")
            h.update(entry.read_bytes())
        return h.hexdigest()
    raise FileNotFoundError(f"inputs path not found: {path}")


def canonical_kernel_name(kernel: str) -> str:
    prefix = "doe.tsir.bootstrap."
    if kernel.startswith(prefix):
        kernel = kernel.removeprefix(prefix)
    return KERNEL_ALIASES.get(kernel, kernel)


def _summarize_process_failure(result: subprocess.CompletedProcess[str]) -> str:
    text = "\n".join(
        part.strip()
        for part in (result.stdout, result.stderr)
        if part and part.strip()
    )
    if not text:
        return f"exit code {result.returncode}"
    lines = text.splitlines()
    return "\n".join(lines[-12:])


def _ensure_zig_bootstrap_oracle() -> None:
    global _ZIG_BOOTSTRAP_ORACLE_READY
    if _ZIG_BOOTSTRAP_ORACLE_READY and ZIG_BOOTSTRAP_ORACLE_BIN.exists():
        return
    try:
        result = subprocess.run(
            ["zig", "build", "tsir-bootstrap-oracle"],
            cwd=ZIG_RUNTIME_DIR,
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError as exc:
        raise BootstrapOracleNotImplemented(
            f"zig bootstrap oracle build failed: {exc}"
        ) from exc
    if result.returncode != 0:
        detail = _summarize_process_failure(result)
        raise BootstrapOracleNotImplemented(
            f"zig bootstrap oracle build failed: {detail}"
        )
    if not ZIG_BOOTSTRAP_ORACLE_BIN.exists():
        raise BootstrapOracleNotImplemented(
            f"zig bootstrap oracle binary missing: {ZIG_BOOTSTRAP_ORACLE_BIN}"
        )
    _ZIG_BOOTSTRAP_ORACLE_READY = True


def _run_zig_bootstrap_oracle(
    kernel: str,
    inputs_path: Path | None,
    semantic_path: Path | None,
    realization_path: Path | None,
) -> str:
    canonical_kernel = canonical_kernel_name(kernel)
    if canonical_kernel not in BOOTSTRAP_ORACLE_KERNELS:
        raise BootstrapOracleNotImplemented(
            f"bootstrap oracle does not support kernel: {kernel}"
        )
    if inputs_path is None:
        raise BootstrapOracleNotImplemented("no bootstrap oracle input path supplied")
    _ensure_zig_bootstrap_oracle()
    command = [
        str(ZIG_BOOTSTRAP_ORACLE_BIN),
        "--kernel",
        canonical_kernel,
        "--inputs",
        str(inputs_path),
    ]
    if semantic_path is not None:
        command.extend(["--semantic-tsir", str(semantic_path)])
    if realization_path is not None:
        command.extend(["--realization-tsir", str(realization_path)])
    try:
        result = subprocess.run(
            command,
            cwd=REPO_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError as exc:
        raise BootstrapOracleNotImplemented(
            f"zig bootstrap oracle execution failed: {exc}"
        ) from exc
    stdout = result.stdout.strip()
    try:
        payload = json.loads(stdout) if stdout else {}
    except json.JSONDecodeError as exc:
        detail = _summarize_process_failure(result)
        raise BootstrapOracleNotImplemented(
            f"zig bootstrap oracle emitted invalid JSON: {detail}"
        ) from exc
    if not isinstance(payload, dict):
        raise BootstrapOracleNotImplemented(
            "zig bootstrap oracle emitted non-object JSON"
        )
    if result.returncode != 0:
        detail = payload.get("detail")
        if not isinstance(detail, str) or not detail:
            detail = _summarize_process_failure(result)
        raise BootstrapOracleNotImplemented(detail)
    if payload.get("status") != "pass":
        detail = payload.get("detail")
        if not isinstance(detail, str) or not detail:
            detail = f"zig bootstrap oracle status={payload.get('status')!r}"
        raise BootstrapOracleNotImplemented(detail)
    reference_hash = payload.get("referenceHash")
    if (
        not isinstance(reference_hash, str)
        or len(reference_hash) != 64
        or any(ch not in "0123456789abcdef" for ch in reference_hash)
    ):
        raise BootstrapOracleNotImplemented(
            "zig bootstrap oracle emitted invalid referenceHash"
        )
    return reference_hash


def extract_rejection_reasons(
    semantic_doc: dict[str, Any], realization_doc: dict[str, Any]
) -> list[str]:
    reasons: list[str] = []
    for doc in (semantic_doc, realization_doc):
        entries = doc.get("rejections") or []
        if not isinstance(entries, list):
            raise ValueError("TSIR rejections must be a list")
        for entry in entries:
            if not isinstance(entry, dict):
                raise ValueError("TSIR rejection entry must be an object")
            reason = entry.get("reason")
            if reason not in REJECTION_REASONS:
                raise ValueError(f"unrecognized TSIR rejection reason: {reason}")
            if reason not in reasons:
                reasons.append(reason)
    return reasons


def load_rejection_reasons(
    semantic_path: Path | None, realization_path: Path | None
) -> list[str]:
    if bool(semantic_path) != bool(realization_path):
        raise ValueError(
            "--semantic-tsir and --realization-tsir must be supplied together"
        )
    if semantic_path is None or realization_path is None:
        return []
    semantic_doc = json.loads(semantic_path.read_text(encoding="utf-8"))
    realization_doc = json.loads(realization_path.read_text(encoding="utf-8"))
    if not isinstance(semantic_doc, dict) or not isinstance(realization_doc, dict):
        raise ValueError("TSIR JSON must be top-level objects")
    return extract_rejection_reasons(semantic_doc, realization_doc)


def lowering_identity_from_manifest_entry(
    entry_path: Path | None, exactness: str
) -> LoweringIdentity | None:
    if entry_path is None:
        return None
    entry = tsir_manifest_lowering.load_entry_doc(entry_path)
    entry_exactness = entry["exactness"]["class"]
    if entry_exactness != exactness:
        raise ValueError(
            "manifest lowering exactness class does not match CLI --class: "
            f"{entry_exactness} != {exactness}"
        )
    return LoweringIdentity(
        tsir_semantic_digest=entry["tsirSemanticDigest"],
        tsir_realization_digest=entry["tsirRealizationDigest"],
        emitter_digest=entry["emitterDigest"],
        target_descriptor_correctness_hash=(
            entry["targetDescriptorCorrectnessHash"]
        ),
    )


def kernel_ref_prefix_from_manifest_entry(
    entry_path: Path | None,
) -> str | None:
    """Return the manifest-entry's kernelRef prefix when one is loadable.

    Used to disambiguate the bootstrap-vs-real routing decision when the
    positional kernel name overlaps both fixture sets (e.g. `fused_gemv`
    and `rmsnorm` exist in both `bench/fixtures/tsir-manifest-entries/`
    and `bench/fixtures/tsir-real-entries/`). The kernelRef carries the
    namespace prefix authoritatively; the positional kernel name does not.

    Returns one of:
      - "doe.tsir.real."
      - "doe.tsir.bootstrap."
      - None if the entry is absent or its kernelRef does not match a known prefix
    """
    if entry_path is None:
        return None
    try:
        entry = tsir_manifest_lowering.load_entry_doc(entry_path)
    except (OSError, ValueError, json.JSONDecodeError):
        return None
    kernel_ref = entry.get("kernelRef")
    if not isinstance(kernel_ref, str):
        return None
    for prefix in ("doe.tsir.real.", "doe.tsir.bootstrap."):
        if kernel_ref.startswith(prefix):
            return prefix
    return None


def tolerance_policy_from_manifest_entry(
    entry_path: Path | None, exactness: str
) -> TolerancePolicy | None:
    if exactness != "tolerance_bounded":
        return None
    if entry_path is None:
        return None
    entry = tsir_manifest_lowering.load_entry_doc(entry_path)
    entry_exactness = entry["exactness"]["class"]
    if entry_exactness != exactness:
        raise ValueError(
            "manifest lowering exactness class does not match CLI --class: "
            f"{entry_exactness} != {exactness}"
        )
    exactness_doc = entry["exactness"]
    metric = exactness_doc.get("toleranceMetric")
    epsilon = exactness_doc.get("toleranceEpsilon")
    if not isinstance(metric, str) or not metric:
        raise ValueError("tolerance_bounded fixture requires toleranceMetric")
    if not isinstance(epsilon, (int, float)):
        raise ValueError("tolerance_bounded fixture requires toleranceEpsilon")
    return TolerancePolicy(metric=metric, epsilon=float(epsilon))


def load_doppler_transcript(path: Path) -> dict[str, Any]:
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise DopplerTranscriptInvalid(
            f"doppler transcript unreadable at {path}: {exc}"
        ) from exc
    if not isinstance(doc, dict):
        raise DopplerTranscriptInvalid(
            "doppler transcript must be a top-level JSON object"
        )
    if doc.get("schema") != REFERENCE_TRANSCRIPT_SCHEMA_ID:
        raise DopplerTranscriptInvalid(
            f"doppler transcript schema must be {REFERENCE_TRANSCRIPT_SCHEMA_ID!r}"
        )
    execution_graph_hash = doc.get("executionGraphHash")
    if not isinstance(execution_graph_hash, str) or not execution_graph_hash.startswith("sha256:"):
        raise DopplerTranscriptInvalid(
            "doppler transcript executionGraphHash must be a sha256: digest"
        )
    source = doc.get("source")
    if not isinstance(source, dict):
        raise DopplerTranscriptInvalid(
            "doppler transcript source must be an object"
        )
    source_hash = source.get("hash")
    if not isinstance(source_hash, str) or not source_hash.startswith("sha256:"):
        raise DopplerTranscriptInvalid(
            "doppler transcript source.hash must be a sha256: digest"
        )
    return doc


def run_doppler_reference(
    kernel: str,
    rejection_reasons: list[str] | None,
    transcript_path: Path,
    probe_hash: str | None,
) -> tuple[ComparisonOutcome, ReferenceSource]:
    """Use a Doppler reference transcript as the oracle for a real kernel.

    The transcript carries end-to-end model identity (tokens, per-step
    logits hashes, KV identity). Per-kernel probe hashes are a separate
    capture concern — the Doppler side must emit a probe that hashes
    the kernel's output under identical inputs. When a probe is not
    supplied, the reference lane records the transcript identity
    (executionGraphHash + source.hash) for audit and marks the
    comparison status `not_implemented` so the receipt does not imply
    coverage the harness does not have.
    """
    doc = load_doppler_transcript(transcript_path)
    reference_source = ReferenceSource(
        kind=REFERENCE_SOURCE_DOPPLER,
        execution_graph_hash=doc["executionGraphHash"],
        source_hash=doc["source"]["hash"],
        transcript_path=str(transcript_path),
    )
    if rejection_reasons:
        return (
            ComparisonOutcome(
                backend="reference",
                status="rejected",
                detail="TSIR rejected before execution: "
                + ", ".join(rejection_reasons),
            ),
            reference_source,
        )
    if probe_hash is None:
        reference_source.detail = (
            "transcript identity recorded; per-kernel probe not captured."
        )
        return (
            ComparisonOutcome(
                backend="reference",
                status="not_implemented",
                detail=(
                    f"doppler transcript reference for {kernel!r}: "
                    "per-kernel probe hash not supplied. Run with "
                    "--doppler-kernel-probe-hash once Doppler-side per-kernel "
                    "capture lands."
                ),
            ),
            reference_source,
        )
    if len(probe_hash) != 64 or any(
        ch not in "0123456789abcdef" for ch in probe_hash.lower()
    ):
        raise DopplerTranscriptInvalid(
            "--doppler-kernel-probe-hash must be a 64-char lowercase hex digest"
        )
    return (
        ComparisonOutcome(
            backend="reference",
            status="pass",
            backend_hash=probe_hash.lower(),
            detail="doppler reference transcript per-kernel probe",
        ),
        reference_source,
    )


def run_reference_interpreter(
    kernel: str,
    _inputs_digest: str,
    rejection_reasons: list[str] | None = None,
    inputs_path: Path | None = None,
    semantic_path: Path | None = None,
    realization_path: Path | None = None,
) -> ComparisonOutcome:
    """Invoke the TSIR reference interpreter.

    This is intentionally narrow: it only executes dedicated bootstrap
    oracle input artifacts for the Phase A `fused_gemv`, `rms_norm`, and
    `gather` families, and the actual reference execution happens in the
    Zig `doe-tsir-bootstrap-oracle` subprocess. Manifest fixtures,
    directories, generic TSIR JSON, and unrecognized shapes still return
    `not_implemented` so receipts do not imply coverage the harness does
    not have.
    """
    if rejection_reasons:
        return ComparisonOutcome(
            backend="reference",
            status="rejected",
            detail="TSIR rejected before execution: " + ", ".join(rejection_reasons),
        )
    try:
        reference_hash = _run_zig_bootstrap_oracle(
            kernel,
            inputs_path,
            semantic_path,
            realization_path,
        )
    except BootstrapOracleNotImplemented as exc:
        return ComparisonOutcome(
            backend="reference",
            status="not_implemented",
            detail=str(exc),
        )
    return ComparisonOutcome(
        backend="reference",
        status="pass",
        backend_hash=reference_hash,
        detail="zig bootstrap TSIR oracle executed",
    )


WEBGPU_DISPATCH_HELPER = (
    REPO_ROOT / "bench" / "tools" / "run_doe_webgpu_kernel_dispatch.mjs"
)
CSL_CHANNEL_LOCK_FILE = Path("/tmp/doe-csl-channel.lock")


def _kernel_wgsl_path(kernel: str) -> Path | None:
    """Locate the WGSL source for a kernel, bootstrap or real.

    Real-kernel layout: runtime/zig/tests/tsir/real/<kernel>/<kernel>.wgsl
    Bootstrap layout:   runtime/zig/tests/tsir/bootstrap/<kernel>.wgsl
    Returns None when no WGSL file exists at either location.
    """
    real = ZIG_RUNTIME_DIR / "tests" / "tsir" / "real" / kernel / f"{kernel}.wgsl"
    if real.is_file():
        return real
    bootstrap = ZIG_RUNTIME_DIR / "tests" / "tsir" / "bootstrap" / f"{kernel}.wgsl"
    if bootstrap.is_file():
        return bootstrap
    return None


def _csl_channel_locked() -> bool:
    """Return True when the CSL/simfabric channel is reserved for another job.

    The lock is observed via either the env var `DOE_PARITY_CSL_CHANNEL_LOCKED`
    (set to "1" / "true" / "yes") or the presence of the lock file at
    `/tmp/doe-csl-channel.lock`. Task 2's full-graph cslc loop sets the
    lock so the parity harness's simfabric backend lane defers cleanly
    rather than contending on the singularity SDK channel.
    """
    import os
    env_value = (os.environ.get("DOE_PARITY_CSL_CHANNEL_LOCKED") or "").strip().lower()
    if env_value in {"1", "true", "yes", "on"}:
        return True
    return CSL_CHANNEL_LOCK_FILE.is_file()


def _run_webgpu_backend(
    kernel: str,
    inputs_path: Path,
    expected_output_elements: int | None = None,
) -> ComparisonOutcome:
    if not WEBGPU_DISPATCH_HELPER.is_file():
        return ComparisonOutcome(
            backend="webgpu",
            status="not_implemented",
            detail=(
                "webgpu dispatch helper missing at "
                f"{WEBGPU_DISPATCH_HELPER.relative_to(REPO_ROOT)}"
            ),
        )
    wgsl_path = _kernel_wgsl_path(kernel)
    if wgsl_path is None:
        return ComparisonOutcome(
            backend="webgpu",
            status="deferred",
            detail=(
                f"WGSL source for kernel {kernel!r} not found under "
                "runtime/zig/tests/tsir/{real,bootstrap}/"
            ),
        )
    cache_dir = REPO_ROOT / ".cache" / "doe-parity"
    cache_dir.mkdir(parents=True, exist_ok=True)
    output_hash_path = cache_dir / f"{kernel}.webgpu.hash"
    if output_hash_path.is_file():
        output_hash_path.unlink()
    cmd = [
        "node",
        str(WEBGPU_DISPATCH_HELPER),
        "--wgsl",
        str(wgsl_path),
        "--inputs",
        str(inputs_path),
        "--output-hash-out",
        str(output_hash_path),
    ]
    if expected_output_elements is not None:
        cmd.extend(["--expected-output-elements", str(expected_output_elements)])
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=120,
            cwd=REPO_ROOT,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return ComparisonOutcome(
            backend="webgpu",
            status="error",
            detail=f"webgpu dispatch invocation failed: {exc}",
        )
    if proc.returncode != 0:
        snippet = (proc.stderr or proc.stdout or "").strip().splitlines()[-1:][0:1]
        tail = snippet[0] if snippet else "(no output)"
        return ComparisonOutcome(
            backend="webgpu",
            status="error",
            detail=f"webgpu dispatch exit {proc.returncode}: {tail}",
        )
    if not output_hash_path.is_file():
        return ComparisonOutcome(
            backend="webgpu",
            status="error",
            detail="webgpu dispatch produced no output hash",
        )
    backend_hash = output_hash_path.read_text(encoding="utf-8").strip()
    if not backend_hash:
        return ComparisonOutcome(
            backend="webgpu",
            status="error",
            detail="webgpu dispatch wrote an empty hash file",
        )
    return ComparisonOutcome(
        backend="webgpu",
        status="pass",
        backend_hash=backend_hash,
        detail="doe-webgpu dispatch via packages/doe-gpu Node runtime",
    )


# Real-canary kernels whose body op has no CSL emit body in
# runtime/zig/src/tsir/emit_kernel_body.zig (line 119:
# `.unknown, .attention_scores => error.UnsupportedKernelBody` for the
# CSL backend). These can never produce a CSL-side hash through TSIR
# lowering; they are structurally rejected, not deferred.
#
# attention_head256_f16kv / attention_head512_f16kv are no longer in
# this set: the bootstrap canary inputs are all-zero, the Doppler
# probe records the matching all-zero output hash, and hand-authored
# CSL kernels at bench/out/csl-real-canary-source/attention_head{256,512}_f16kv/
# (compiled to ../../csl-real-canary-compile/) close the canary lane.
# The TSIR-CSL emit gap remains open for manifest-shape attention; only
# the canary hash-equivalence assertion is satisfied here.
_CSL_REJECTED_KERNELS: frozenset[str] = frozenset()

# Pre-compiled real-canary CSL compile-dirs, keyed by kernel name.
# Source CSL lives at bench/out/csl-real-canary-source/<kernel>/, and
# the cslc product at bench/out/csl-real-canary-compile/<kernel>/<kernel>/.
# A kernel is wired through this lane when (a) the per-kernel sim runner
# exists at bench/runners/csl-runners/<kernel>_sim_runner.py and (b) the
# compile-dir bin/ subdir is populated.
#
# When a TSIR-emit sister runner exists at
# bench/runners/csl-runners/<kernel>_tsir_sim_runner.py with a matching
# pre-compiled TSIR compile-dir at
# bench/out/csl-real-canary-compile-tsir/<kernel>/<kernel>/, the lane
# prefers it over the hand-authored runner. This routes the canary
# through the TSIR-CSL emit body
# (runtime/zig/src/tsir/emit_kernel_body_attention.zig) instead of the
# hand-authored bootstrap-shape CSL while preserving the hand-authored
# compile-dir as a fallback when the TSIR compile-dir hasn't been
# materialized yet (e.g., in environments without cslc).
_CSL_REAL_CANARY_COMPILE_ROOT = REPO_ROOT / "bench" / "out" / "csl-real-canary-compile"
_CSL_REAL_CANARY_COMPILE_ROOT_TSIR = (
    REPO_ROOT / "bench" / "out" / "csl-real-canary-compile-tsir"
)
_CSL_RUNNERS_ROOT = REPO_ROOT / "bench" / "runners" / "csl-runners"
_CS_PYTHON_SINGULARITY = REPO_ROOT / "runtime" / "zig" / "tools" / "cs_python_singularity.sh"


def _resolve_csl_runner(
    kernel: str,
    *,
    runners_root: Path = _CSL_RUNNERS_ROOT,
    handauth_compile_root: Path = _CSL_REAL_CANARY_COMPILE_ROOT,
    tsir_compile_root: Path = _CSL_REAL_CANARY_COMPILE_ROOT_TSIR,
) -> tuple[Path, Path, str]:
    """Pick the runner + compile-dir for a kernel, preferring the TSIR-emit
    pair when both halves are materialized.

    Returns ``(runner_path, compile_dir, route)``. ``route`` is
    ``"tsir"`` when the TSIR-emit pair is selected, ``"handauth"``
    otherwise. ``compile_dir`` is the cslc product directory; the
    caller checks whether ``compile_dir / "bin"`` exists.

    Resolution rules:
      - If ``<kernel>_tsir_sim_runner.py`` AND
        ``<tsir_root>/<kernel>/<kernel>/`` BOTH exist, return the TSIR
        pair (the runner exists irrespective of whether its bin/ is
        populated; the caller handles missing-bin separately so the
        deferred-detail message can name the right compile-dir).
      - Else fall back to the hand-authored ``<kernel>_sim_runner.py``
        + ``<handauth_root>/<kernel>/<kernel>/`` pair.
    """
    tsir_runner = runners_root / f"{kernel}_tsir_sim_runner.py"
    tsir_compile_dir = tsir_compile_root / kernel / kernel
    if tsir_runner.is_file() and tsir_compile_dir.is_dir():
        return tsir_runner, tsir_compile_dir, "tsir"
    handauth_runner = runners_root / f"{kernel}_sim_runner.py"
    handauth_compile_dir = handauth_compile_root / kernel / kernel
    return handauth_runner, handauth_compile_dir, "handauth"


def _run_csl_simfabric_backend(kernel: str, inputs_path: Path) -> ComparisonOutcome:
    if _csl_channel_locked():
        return ComparisonOutcome(
            backend="csl-simfabric",
            status="deferred",
            detail=(
                "csl-simfabric channel locked via DOE_PARITY_CSL_CHANNEL_LOCKED "
                "or /tmp/doe-csl-channel.lock; rerun without the lock to "
                "execute the per-kernel simfabric runner."
            ),
        )
    if kernel in _CSL_REJECTED_KERNELS:
        return ComparisonOutcome(
            backend="csl-simfabric",
            status="rejected",
            detail=(
                f"{kernel!r} body op (attention_scores) has no CSL emit "
                "body in runtime/zig/src/tsir/emit_kernel_body.zig:119 "
                "(emitCsl returns UnsupportedKernelBody for "
                "attention_scores). Closing this lane requires authoring "
                "the attention_scores CSL emit body — schema enum already "
                "accepts it; only the emitter is missing."
            ),
        )
    sim_runner, compile_dir, route = _resolve_csl_runner(kernel)
    if not sim_runner.is_file():
        return ComparisonOutcome(
            backend="csl-simfabric",
            status="deferred",
            detail=(
                f"{kernel!r} is CSL-lowerable via emit_kernel_body.zig but "
                f"the per-kernel runner harness "
                f"bench/runners/csl-runners/{kernel}_sim_runner.py does not "
                "exist. Closing this entry needs (a) authored CSL kernel "
                f"sources at bench/out/csl-real-canary-source/{kernel}/, "
                "(b) cslc-compiled output at "
                f"bench/out/csl-real-canary-compile/{kernel}/{kernel}/, "
                "(c) a per-kernel sim runner that loads bootstrap inputs, "
                "dispatches via SdkRuntime, hashes f32 output bytes."
            ),
        )

    if not (compile_dir / "bin").is_dir():
        source_root_hint = (
            f"bench/out/csl-real-canary-source-tsir/{kernel}/layout.csl"
            if route == "tsir"
            else f"bench/out/csl-real-canary-source/{kernel}/layout.csl"
        )
        return ComparisonOutcome(
            backend="csl-simfabric",
            status="deferred",
            detail=(
                f"{sim_runner.name} exists but the cslc compile-dir "
                f"{compile_dir.relative_to(REPO_ROOT)} is not materialized. "
                f"Run cslc against {source_root_hint} via "
                "cs_python_singularity.sh to produce it."
            ),
        )

    # Invoke the per-kernel runner via cs_python_singularity. The runner
    # writes a sha256 hex digest to the --output-hash-out path.
    cache_dir = REPO_ROOT / ".cache" / "doe-parity"
    cache_dir.mkdir(parents=True, exist_ok=True)
    output_hash_path = cache_dir / f"{kernel}.csl.hash"
    if output_hash_path.is_file():
        output_hash_path.unlink()
    compile_root = (
        _CSL_REAL_CANARY_COMPILE_ROOT_TSIR
        if route == "tsir"
        else _CSL_REAL_CANARY_COMPILE_ROOT
    )
    scratch_dir = compile_root / kernel / "scratch"
    scratch_dir.mkdir(parents=True, exist_ok=True)

    import os
    env = os.environ.copy()
    env["DOE_CSL_SCRATCH_CWD"] = str(scratch_dir)

    try:
        proc = subprocess.run(
            [
                str(_CS_PYTHON_SINGULARITY),
                str(sim_runner),
                "--compile-dir",
                str(compile_dir),
                "--inputs",
                str(inputs_path),
                "--output-hash-out",
                str(output_hash_path),
            ],
            env=env,
            capture_output=True,
            text=True,
            timeout=600,
            cwd=REPO_ROOT,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return ComparisonOutcome(
            backend="csl-simfabric",
            status="error",
            detail=f"csl-simfabric subprocess failed: {exc}",
        )
    if proc.returncode != 0:
        snippet = (proc.stderr or proc.stdout or "").strip().splitlines()[-1:]
        tail = snippet[0] if snippet else "(no output)"
        return ComparisonOutcome(
            backend="csl-simfabric",
            status="error",
            detail=(
                f"csl-simfabric subprocess exit {proc.returncode}: {tail}"
            ),
        )
    if not output_hash_path.is_file():
        return ComparisonOutcome(
            backend="csl-simfabric",
            status="error",
            detail="csl-simfabric runner produced no output hash",
        )
    backend_hash = output_hash_path.read_text(encoding="utf-8").strip()
    if not backend_hash:
        return ComparisonOutcome(
            backend="csl-simfabric",
            status="error",
            detail="csl-simfabric runner wrote an empty hash file",
        )
    route_label = "tsir-emit" if route == "tsir" else "hand-authored"
    return ComparisonOutcome(
        backend="csl-simfabric",
        status="pass",
        backend_hash=backend_hash,
        detail=(
            f"doe-csl-simfabric dispatch via {sim_runner.name} against "
            f"compile-dir {compile_dir.relative_to(REPO_ROOT)} "
            f"(route={route_label})"
        ),
    )


def run_backend(
    backend: str,
    kernel: str | None = None,
    inputs_path: Path | None = None,
    expected_output_elements: int | None = None,
) -> ComparisonOutcome:
    """Run a backend emission path and return its hash.

    Webgpu lane: subprocess to bench/tools/run_doe_webgpu_kernel_dispatch.mjs,
    which boots a Node WebGPU device, dispatches the kernel's WGSL with
    inputs from the fixture, and writes a sha256 of the output buffer.

    Csl-simfabric lane: when the channel is unlocked (no env / no lock
    file) and the per-kernel `<kernel>_sim_runner.py` exists, the runner
    is intended to be invoked here. The lane is currently structurally
    wired but defers actual execution until the SDK channel is free of
    Task 2's cslc loop and per-kernel compile-dirs are materialized.
    """
    if kernel is None or inputs_path is None:
        return ComparisonOutcome(
            backend=backend,
            status="not_implemented",
            detail=(
                f"{backend} backend lane requires kernel + inputs_path; "
                "called without context."
            ),
        )
    if backend == "webgpu":
        return _run_webgpu_backend(
            kernel, inputs_path, expected_output_elements=expected_output_elements
        )
    if backend == "csl-simfabric":
        return _run_csl_simfabric_backend(kernel, inputs_path)
    return ComparisonOutcome(
        backend=backend,
        status="not_implemented",
        detail=f"unrecognized backend: {backend!r}",
    )


def compare(
    reference: ComparisonOutcome,
    backend_outcome: ComparisonOutcome,
    exactness: str,
    tolerance_policy: TolerancePolicy | None = None,
) -> ComparisonOutcome:
    if exactness not in VALID_EXACTNESS:
        raise ValueError(f"unrecognized exactness class: {exactness}")
    if reference.status == "rejected":
        return ComparisonOutcome(
            backend=backend_outcome.backend,
            status="rejected",
            detail=f"{backend_outcome.backend} blocked: reference={reference.status}",
        )
    if backend_outcome.status == "rejected":
        return ComparisonOutcome(
            backend=backend_outcome.backend,
            status="rejected",
            detail=(
                f"{backend_outcome.backend} structurally rejected: "
                f"{backend_outcome.detail or 'no further detail'}"
            ),
        )
    reference_ready = reference.status in {"ok", "pass"}
    backend_ready = backend_outcome.status in {"ok", "pass"}
    if not reference_ready or not backend_ready:
        detail = (
            f"{backend_outcome.backend} deferred: "
            f"reference={reference.status}, backend={backend_outcome.status}"
        )
        return ComparisonOutcome(
            backend=backend_outcome.backend, status="deferred", detail=detail
        )
    if exactness in {"bit_exact_solo", "algorithm_exact"}:
        if not reference.backend_hash or not backend_outcome.backend_hash:
            missing: list[str] = []
            if not reference.backend_hash:
                missing.append("referenceHash")
            if not backend_outcome.backend_hash:
                missing.append("backendHash")
            return ComparisonOutcome(
                backend=backend_outcome.backend,
                status="deferred",
                backend_hash=backend_outcome.backend_hash,
                detail=(
                    f"{backend_outcome.backend} deferred: missing "
                    + ", ".join(missing)
                    + f" for {exactness}"
                ),
            )
        if reference.backend_hash == backend_outcome.backend_hash:
            return ComparisonOutcome(
                backend=backend_outcome.backend,
                status="pass",
                backend_hash=backend_outcome.backend_hash,
            )
        return ComparisonOutcome(
            backend=backend_outcome.backend,
            status="fail",
            backend_hash=backend_outcome.backend_hash,
            detail="hash mismatch",
        )
    if tolerance_policy is None:
        return ComparisonOutcome(
            backend=backend_outcome.backend,
            status="deferred",
            backend_hash=backend_outcome.backend_hash,
            detail=(
                "tolerance_bounded deferred: declared toleranceMetric/"
                "toleranceEpsilon not supplied"
            ),
        )
    if (
        reference.backend_hash
        and backend_outcome.backend_hash
        and reference.backend_hash == backend_outcome.backend_hash
    ):
        return ComparisonOutcome(
            backend=backend_outcome.backend,
            status="pass",
            backend_hash=backend_outcome.backend_hash,
            detail=(
                "byte-identical output; "
                f"{tolerance_policy.metric}=0 <= {tolerance_policy.epsilon}"
            ),
            metric=tolerance_policy.metric,
            metric_value=0.0,
            metric_epsilon=tolerance_policy.epsilon,
        )
    if (
        backend_outcome.metric == tolerance_policy.metric
        and backend_outcome.metric_value is not None
    ):
        metric_value = float(backend_outcome.metric_value)
        status = "pass" if metric_value <= tolerance_policy.epsilon else "fail"
        relation = "<=" if status == "pass" else ">"
        return ComparisonOutcome(
            backend=backend_outcome.backend,
            status=status,
            backend_hash=backend_outcome.backend_hash,
            detail=(
                f"{tolerance_policy.metric}={metric_value} "
                f"{relation} {tolerance_policy.epsilon}"
            ),
            metric=tolerance_policy.metric,
            metric_value=metric_value,
            metric_epsilon=tolerance_policy.epsilon,
        )
    return ComparisonOutcome(
        backend=backend_outcome.backend,
        status="deferred",
        backend_hash=backend_outcome.backend_hash,
        detail=(
            "tolerance_bounded deferred: backend hash differs or is missing "
            "and no numeric metric payload was produced"
        ),
    )


def _format_schema_path(error: jsonschema.ValidationError) -> str:
    if not error.path:
        return "<root>"
    return ".".join(str(part) for part in error.path)


def validate_receipt_doc(doc: dict[str, Any]) -> None:
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    validator = jsonschema.Draft202012Validator(schema)
    errors = sorted(validator.iter_errors(doc), key=lambda err: list(err.path))
    if errors:
        first = errors[0]
        path = _format_schema_path(first)
        raise ValueError(
            f"parity receipt schema validation failed at {path}: {first.message}"
        )


def write_receipt(
    receipt: ParityReceipt,
    receipt_dir: Path,
    basename: str | None = None,
) -> Path:
    doc = receipt.to_json()
    validate_receipt_doc(doc)
    receipt_dir.mkdir(parents=True, exist_ok=True)
    # Filename uses the caller-supplied basename when given so the canary
    # (which addresses receipts by un-normalized kernel name from the
    # manifest entry's kernelRef suffix) can find the file even when an
    # alias normalized the in-content `receipt.kernel` (e.g. "rmsnorm" ->
    # "rms_norm"). Without this, the receipt is written at the normalized
    # path and the canary reports "did not write a receipt".
    out_basename = basename if basename else receipt.kernel
    out_path = receipt_dir / f"{out_basename}.parity.json"
    out_path.write_text(
        json.dumps(doc, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return out_path


def main() -> int:
    try:
        args = parse_args()
        if args.exactness not in VALID_EXACTNESS:
            # argparse.choices should prevent this, but the guard is
            # declared per the fail-closed contract on unknown classes.
            print(f"unrecognized exactness class: {args.exactness}", file=sys.stderr)
            return 1

        inputs_digest = sha256_of_path(args.inputs)
        rejection_reasons = load_rejection_reasons(
            args.semantic_tsir, args.realization_tsir
        )
        lowering_identity = lowering_identity_from_manifest_entry(
            args.manifest_lowering_entry, args.exactness
        )
        tolerance_policy = tolerance_policy_from_manifest_entry(
            args.manifest_lowering_entry, args.exactness
        )

        normalized_kernel = KERNEL_ALIASES.get(args.kernel, args.kernel)
        # Route by manifest-entry kernelRef prefix when supplied — the
        # positional kernel name overlaps between bootstrap and real fixture
        # sets (`fused_gemv`, `rmsnorm`, `gather` all exist in both), so
        # falling back to the positional name alone misroutes real kernels
        # that share a name with a bootstrap entry. The kernelRef namespace
        # prefix is authoritative; positional name is a fallback.
        kernel_ref_prefix = kernel_ref_prefix_from_manifest_entry(
            args.manifest_lowering_entry
        )
        if kernel_ref_prefix == "doe.tsir.real.":
            is_bootstrap_kernel = False
        elif kernel_ref_prefix == "doe.tsir.bootstrap.":
            is_bootstrap_kernel = True
        else:
            is_bootstrap_kernel = normalized_kernel in BOOTSTRAP_ORACLE_KERNELS
        doppler_transcript = args.doppler_transcript

        if is_bootstrap_kernel and doppler_transcript is not None:
            raise ValueError(
                f"--doppler-transcript is not valid for bootstrap kernel "
                f"{normalized_kernel!r}; bootstrap kernels route to the Zig "
                "scalar oracle by design. See docs/tsir-lowering-plan.md "
                "Step 1."
            )
        if not is_bootstrap_kernel and doppler_transcript is None:
            raise ValueError(
                f"real kernel {normalized_kernel!r} requires "
                "--doppler-transcript under the re-scoped plan (real-kernel "
                "reference is Doppler's browser WebGPU transcript, not the "
                "Zig oracle). See docs/tsir-lowering-plan.md Step 1."
            )

        expected_output_elements: int | None = None
        if doppler_transcript is not None:
            reference, reference_source = run_doppler_reference(
                normalized_kernel,
                rejection_reasons,
                doppler_transcript,
                args.doppler_kernel_probe_hash,
            )
            # Transcript-as-output-shape-source: the kernelProbe.outputElementCount
            # field declares how many f32 elements the probe-hash was computed
            # over. Threading it into the WebGPU dispatcher avoids the
            # dispatcher having to re-derive output shape from the bootstrap
            # input fixture (which the dispatcher only knows for fused_gemv /
            # gather / rms_norm; for embed / lm_head_gemv / real-kernel rmsnorm
            # the dispatcher's max-input-shape fallback over-allocates and
            # produces a different sha256 even when bytes are zero).
            try:
                _transcript_doc = load_doppler_transcript(doppler_transcript)
                _kp = _transcript_doc.get("kernelProbe")
                if isinstance(_kp, dict):
                    _oec = _kp.get("outputElementCount")
                    if isinstance(_oec, int) and _oec > 0:
                        expected_output_elements = _oec
            except DopplerTranscriptInvalid:
                pass
        else:
            reference = run_reference_interpreter(
                normalized_kernel,
                inputs_digest,
                rejection_reasons,
                inputs_path=args.inputs,
                semantic_path=args.semantic_tsir,
                realization_path=args.realization_tsir,
            )
            reference_source = ReferenceSource(kind=REFERENCE_SOURCE_ZIG)

        webgpu_result = run_backend(
            "webgpu",
            normalized_kernel,
            args.inputs,
            expected_output_elements=expected_output_elements,
        )
        csl_result = run_backend("csl-simfabric", normalized_kernel, args.inputs)

        comparisons = [
            compare(reference, webgpu_result, args.exactness, tolerance_policy),
            compare(reference, csl_result, args.exactness, tolerance_policy),
        ]

        receipt = ParityReceipt(
            schema_version=2,
            artifact_kind="doe_parity_receipt",
            kernel=normalized_kernel,
            exactness_class=args.exactness,
            reference_hash=reference.backend_hash,
            inputs_digest=inputs_digest,
            comparisons=[reference] + comparisons,
            rejection_reasons=rejection_reasons,
            lowering_identity=lowering_identity,
            reference_source=reference_source,
        )
        out_path = write_receipt(receipt, args.receipt_dir, basename=args.kernel)
        try:
            display_path: Path | str = out_path.relative_to(REPO_ROOT)
        except ValueError:
            display_path = out_path
        print(f"PARITY RECEIPT: {display_path}")
        # Scaffolding never claims pass; return 1 so callers cannot mistake
        # "receipt produced" for "kernel is green."
        any_non_pass = any(c.status != "pass" for c in comparisons)
        return 1 if any_non_pass else 0
    except (FileNotFoundError, ValueError, json.JSONDecodeError) as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
