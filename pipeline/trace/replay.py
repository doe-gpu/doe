#!/usr/bin/env python3
"""Replay validator for trace artifact replay integrity.

Validates artifact presence, JSON parseability, and deterministic hash-chain fields.
"""

from __future__ import annotations

import argparse
import json
from typing import Any
from pathlib import Path


REPLAY_SEED = "0x9e3779b97f4a7c15"
SUPPORTED_OP_CODES = {"dispatch", "upload", "copy", "readback"}


def safe_int(value: Any, default: int = 0) -> int:
    if isinstance(value, bool):
        return default
    if isinstance(value, int):
        return value
    return default


def parse_hex_u64(value: Any) -> int:
    if not isinstance(value, str):
        raise ValueError("hash must be string")
    hex_value = value[2:] if value.lower().startswith("0x") else value
    return int(hex_value, 16)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--trace-bin", default="")
    parser.add_argument("--trace-meta", required=True)
    parser.add_argument("--trace-jsonl", default="")
    args = parser.parse_args()

    trace_bin = Path(args.trace_bin)
    trace_meta = Path(args.trace_meta)

    try:
        meta_payload = json.loads(trace_meta.read_text(encoding="utf-8")) if trace_meta.exists() else {}
    except json.JSONDecodeError as exc:
        print(f"FAIL: invalid trace meta json: {exc}")
        return 1

    if not isinstance(meta_payload, dict):
        print(f"FAIL: trace meta payload is not object: {trace_meta}")
        return 1

    if args.trace_jsonl:
        trace_jsonl = Path(args.trace_jsonl)
    else:
        print("FAIL: --trace-jsonl required for replay integrity check")
        return 1

    if args.trace_bin and not trace_bin.exists():
        print(f"FAIL: missing trace bin: {trace_bin}")
        return 1
    if not trace_meta.exists():
        print(f"FAIL: missing trace meta: {trace_meta}")
        return 1

    if not trace_jsonl.exists():
        print(f"FAIL: missing trace jsonl: {trace_jsonl}")
        return 1

    meta = meta_payload

    required = ["traceVersion", "seqMax", "rowCount", "hash", "previousHash"]
    missing = [k for k in required if k not in meta]
    if missing:
        print(f"FAIL: trace meta missing required fields: {missing}")
        return 1

    if meta.get("traceVersion") != 1:
        print(f"FAIL: unsupported traceVersion={meta.get('traceVersion')}")
        return 1

    row_count = safe_int(meta.get("rowCount"))
    seq_max = safe_int(meta.get("seqMax"))
    if row_count < 0 or seq_max < 0:
        print(f"FAIL: negative trace counters in meta: rowCount={row_count} seqMax={seq_max}")
        return 1

    rows = [line.strip() for line in trace_jsonl.read_text(encoding="utf-8").splitlines() if line.strip()]
    parsed_rows: list[dict[str, Any]] = []

    expected_previous = REPLAY_SEED
    expected_seq = 0
    for idx, raw in enumerate(rows):
        try:
            row = json.loads(raw)
        except json.JSONDecodeError as exc:
            print(f"FAIL: invalid trace jsonl row={idx}: {exc}")
            return 1

        if not isinstance(row, dict):
            print(f"FAIL: trace row={idx} is not object")
            return 1

        required_row_fields = [
            "traceVersion",
            "module",
            "opCode",
            "seq",
            "timestampMonoNs",
            "hash",
            "previousHash",
            "command",
        ]
        missing_row = [k for k in required_row_fields if k not in row]
        if missing_row:
            print(f"FAIL: trace row={idx} missing required fields: {missing_row}")
            return 1

        if row.get("traceVersion") != 1:
            print(f"FAIL: trace row={idx} unsupported traceVersion={row.get('traceVersion')}")
            return 1

        if not isinstance(row.get("module"), str) or not row.get("module"):
            print(f"FAIL: trace row={idx} invalid module")
            return 1

        if row.get("opCode") not in SUPPORTED_OP_CODES:
            print(f"FAIL: trace row={idx} unsupported opCode={row.get('opCode')}")
            return 1

        row_seq = row.get("seq")
        if not isinstance(row_seq, int):
            print(f"FAIL: trace row={idx} seq is not int")
            return 1
        if row_seq != expected_seq:
            print(f"FAIL: trace sequence mismatch at row={idx}: expected {expected_seq}, got {row_seq}")
            return 1

        if not isinstance(row.get("timestampMonoNs"), int) or row.get("timestampMonoNs") < 0:
            print(f"FAIL: trace row={idx} invalid timestampMonoNs={row.get('timestampMonoNs')}")
            return 1

        if str(row.get("hash")).lower() != str(row.get("hash")).strip().lower():
            print(f"FAIL: trace row={idx} hash is malformed: {row.get('hash')}")
            return 1
        if str(row.get("previousHash")).lower() != str(row.get("previousHash")).strip().lower():
            print(f"FAIL: trace row={idx} previousHash is malformed: {row.get('previousHash')}")
            return 1

        try:
            parsed_prev = parse_hex_u64(row["previousHash"])
        except ValueError:
            print(f"FAIL: trace row={idx} previousHash parse failure: {row.get('previousHash')}")
            return 1

        try:
            _ = parse_hex_u64(row["hash"])
        except ValueError:
            print(f"FAIL: trace row={idx} hash parse failure: {row.get('hash')}")
            return 1

        if row["previousHash"] != expected_previous and parsed_prev != parse_hex_u64(expected_previous):
            print(
                f"FAIL: trace hash chain broken at row={idx}: expected {expected_previous}, got {row['previousHash']}"
            )
            return 1

        expected_previous = str(row["hash"])
        expected_seq += 1
        parsed_rows.append(row)

    if parsed_rows:
        last_row = parsed_rows[-1]
        if row_count != len(parsed_rows):
            print(f"FAIL: trace meta rowCount mismatch: expected {len(parsed_rows)}, got {row_count}")
            return 1

        if not isinstance(last_row.get("seq"), int):
            print(f"FAIL: trace meta comparison missing integer last seq: {last_row.get('seq')}")
            return 1
        if meta.get("seqMax") != last_row.get("seq"):
            print(f"FAIL: trace meta seqMax mismatch: expected {last_row.get('seq')}, got {meta.get('seqMax')}")
            return 1

        if meta.get("hash") != last_row.get("hash"):
            print(
                f"FAIL: trace meta hash mismatch: expected {last_row.get('hash')}, got {meta.get('hash')}"
            )
            return 1

        if meta.get("previousHash") != last_row.get("previousHash"):
            print(
                f"FAIL: trace meta previousHash mismatch: expected {last_row.get('previousHash')}, got {meta.get('previousHash')}"
            )
            return 1

    else:
        if row_count != 0:
            print(f"FAIL: trace meta rowCount mismatch: expected 0, got {row_count}")
            return 1
        if seq_max != 0:
            print(f"FAIL: trace meta seqMax mismatch: expected 0, got {seq_max}")
            return 1

    print("PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
