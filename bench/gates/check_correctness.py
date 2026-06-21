#!/usr/bin/env python3
"""Correctness gate for quirk records and replay trace invariants."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
for _path_entry in (str(REPO_ROOT), str(BENCH_ROOT)):
    if _path_entry not in sys.path:
        sys.path.insert(0, _path_entry)

from bench.lib.bench_utils import load_json_object


PROOF_RANK = {
    "rejected": 0,
    "guarded": 1,
    "proven": 2,
}


def load_json(path: str) -> dict:
    return load_json_object(Path(path))


def parse_jsonl(path: Path) -> list[dict]:
    rows: list[dict] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        if not raw.strip():
            continue
        payload = json.loads(raw)
        if isinstance(payload, dict):
            rows.append(payload)
        else:
            raise ValueError(f"trace-jsonl row is not object: {path}")
    return rows


def parse_hex_u64(value: str) -> int:
    if value.startswith("0x") or value.startswith("0X"):
        value = value[2:]
    return int(value, 16)


def required_proof_level(verification_rules: dict, quirk: dict) -> str | None:
    mode = quirk.get("verificationMode")
    safety_class = quirk.get("safetyClass")

    mode_required = set(verification_rules.get("requireLeanForVerificationMode", []))
    mode_levels = verification_rules.get("requireProofLevelForVerificationMode", {})
    safety_levels = verification_rules.get("requireProofLevelForSafetyClass", {})

    required_levels: list[str] = []
    if mode in mode_required:
        level = mode_levels.get(mode)
        if level:
            required_levels.append(level)

    safety_level = safety_levels.get(safety_class)
    if safety_level:
        required_levels.append(safety_level)

    if not required_levels:
        return None

    return max(required_levels, key=lambda level: PROOF_RANK.get(level, -1))


def validate_trace_invariants(rows: list[dict], meta: dict[str, object]) -> list[str]:
    failures: list[str] = []

    expected_prev = 0x9e3779b97f4a7c15
    expected_seq = 0
    for idx, row in enumerate(rows):
        for required in [
            "traceVersion",
            "module",
            "opCode",
            "seq",
            "timestampMonoNs",
            "hash",
            "previousHash",
            "command",
        ]:
            if required not in row:
                failures.append(f"row[{idx}] missing {required}")
                return failures

        if not isinstance(row["seq"], int):
            failures.append(f"row[{idx}] seq is not int")
            return failures
        if row["seq"] != expected_seq:
            failures.append(f"row[{idx}] seq mismatch: expected {expected_seq}, got {row['seq']}")
            return failures
        expected_seq += 1

        try:
            prev = parse_hex_u64(str(row["previousHash"]))
            hsh = parse_hex_u64(str(row["hash"]))
        except (TypeError, ValueError):
            failures.append(f"row[{idx}] malformed hash format")
            return failures

        if prev != expected_prev:
            failures.append(
                f"row[{idx}] previousHash mismatch: expected 0x{expected_prev:x}, got {row['previousHash']}"
            )
            return failures
        expected_prev = hsh

    row_count = len(rows)
    if row_count != meta.get("rowCount"):
        failures.append(f"meta rowCount mismatch: expected {row_count}, got {meta.get('rowCount')}")
    if row_count > 0 and meta.get("seqMax") != row_count - 1:
        failures.append(f"meta seqMax mismatch: expected {row_count - 1}, got {meta.get('seqMax')}")
    if row_count == 0 and meta.get("seqMax") != 0:
        failures.append(f"meta seqMax mismatch for empty rows: expected 0, got {meta.get('seqMax')}")

    if row_count > 0:
        if str(meta.get("hash")) != str(rows[-1].get("hash")):
            failures.append("meta hash mismatch")

    return failures


def collect_report_samples(report: dict[str, object]) -> list[tuple[str, int, object, object]]:
    collected: list[tuple[str, int, object, object]] = []
    for workload in report.get("workloads", []) if isinstance(report, dict) else []:
        if not isinstance(workload, dict):
            continue
        workload_id = workload.get("id", "unknown")
        for side in ("baseline", "comparison"):
            side_payload = workload.get(side)
            if not isinstance(side_payload, dict):
                continue
            for idx, sample in enumerate(side_payload.get("commandSamples", [])):
                if not isinstance(sample, dict):
                    continue
                collected.append((str(workload_id), idx, sample.get("traceMetaPath"), sample.get("traceJsonlPath")))
    return collected


def validate_single_trace(trace_meta: str | None, trace_jsonl: str | None, *, skip_missing: bool) -> tuple[bool, list[str]]:
    if not trace_meta or not trace_jsonl:
        if skip_missing:
            return True, []
        return False, ["missing trace artifact path(s)"]

    meta_path = Path(trace_meta)
    jsonl_path = Path(trace_jsonl)
    if not meta_path.exists() or not jsonl_path.exists():
        if skip_missing:
            return True, []
        missing = "missing trace-meta" if not meta_path.exists() else "missing trace-jsonl"
        return False, [missing]

    try:
        meta = load_json(str(meta_path))
        rows = parse_jsonl(jsonl_path)
    except (OSError, json.JSONDecodeError, ValueError, UnicodeError) as exc:
        return False, [f"trace parse failed: {exc}"]

    failures = validate_trace_invariants(rows, meta)
    if failures:
        return False, failures
    return True, []


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--gates", default="config/gates.json")
    parser.add_argument("--quirk", default="examples/quirks/intel_gen12_temp_buffer.json")
    parser.add_argument("--trace-meta", default="")
    parser.add_argument("--trace-jsonl", default="")
    parser.add_argument("--report", default="")
    parser.add_argument("--skip-missing", action="store_true")
    args = parser.parse_args()

    gates = load_json(args.gates)
    quirk = load_json(args.quirk)

    verification_rules = gates["gates"]["verification"]
    proof_level = quirk.get("proofLevel")
    if proof_level not in PROOF_RANK:
        print(f"FAIL: invalid proofLevel={proof_level}")
        return 1

    required = required_proof_level(verification_rules, quirk)
    if required is not None and PROOF_RANK[proof_level] < PROOF_RANK[required]:
        print(
            "FAIL: proof obligation not met: "
            f"verificationMode={quirk.get('verificationMode')} "
            f"safetyClass={quirk.get('safetyClass')} "
            f"requires>={required}, got {proof_level}"
        )
        return 1

    correctness_rules = gates["gates"].get("correctness", {})
    require_replay = bool(correctness_rules.get("requireReplayDeterminism", False))
    require_invariant = bool(correctness_rules.get("requireInvariantPass", False))

    if require_replay:
        trace_failures: list[str] = []

        if args.report:
            report = load_json(args.report)
            for workload_id, sample_idx, meta_path, jsonl_path in collect_report_samples(report):
                ok, sample_failures = validate_single_trace(
                    None if not isinstance(meta_path, str) else meta_path,
                    None if not isinstance(jsonl_path, str) else jsonl_path,
                    skip_missing=args.skip_missing,
                )
                if not ok:
                    prefix = f"{workload_id}/{sample_idx}"
                    trace_failures.extend([f"{prefix}: {item}" for item in sample_failures])

        elif args.trace_meta and args.trace_jsonl:
            ok, sample_failures = validate_single_trace(args.trace_meta, args.trace_jsonl, skip_missing=args.skip_missing)
            if not ok:
                trace_failures.extend(sample_failures)

        elif not args.skip_missing:
            print("FAIL: no trace artifacts provided and no --report for correctness trace checks")
            return 1

        if trace_failures:
            print("FAIL: correctness trace checks")
            for failure in trace_failures:
                print(f"  {failure}")
            return 1

    if require_invariant and not (args.trace_meta and args.trace_jsonl) and not args.report:
        if not args.skip_missing:
            print("FAIL: invariant validation requires trace artifacts or report path")
            return 1

    print("PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
