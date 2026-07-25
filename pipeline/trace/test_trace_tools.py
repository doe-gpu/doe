#!/usr/bin/env python3
"""Tests for trace replay validation and dispatch trace comparison.

Covers valid traces, hash chain breaks, missing fields, out-of-order
sequences, dispatch comparison, and empty traces.
Runs without network or GPU access.
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TRACE_DIR = Path(__file__).resolve().parent
REPLAY_SCRIPT = TRACE_DIR / "replay.py"
COMPARE_SCRIPT = TRACE_DIR / "compare_dispatch_traces.py"

from pipeline.trace import compare_dispatch_traces as compare_mod

REPLAY_SEED = "0x9e3779b97f4a7c15"


def _make_trace_row(
    seq: int,
    hash_val: str,
    previous_hash: str,
    *,
    module: str = "test_module",
    command: str = "test_cmd",
    timestamp_ns: int = 1000,
) -> dict:
    return {
        "traceVersion": 1,
        "module": module,
        "opCode": "dispatch",
        "seq": seq,
        "timestampMonoNs": timestamp_ns + seq * 100,
        "hash": hash_val,
        "previousHash": previous_hash,
        "command": command,
    }


def _make_trace_meta(
    row_count: int,
    seq_max: int,
    last_hash: str,
    last_prev_hash: str,
) -> dict:
    return {
        "traceVersion": 1,
        "module": "test_module",
        "seqMax": seq_max,
        "rowCount": row_count,
        "hash": last_hash,
        "previousHash": last_prev_hash,
    }


def _make_valid_trace(n_rows: int = 3) -> tuple[list[dict], dict]:
    """Build a valid trace with n_rows rows and matching meta."""
    rows = []
    prev = REPLAY_SEED
    for i in range(n_rows):
        h = f"0x{(i + 1) * 111:016x}"
        rows.append(_make_trace_row(i, h, prev))
        prev = h
    meta = _make_trace_meta(
        row_count=n_rows,
        seq_max=n_rows - 1 if n_rows > 0 else 0,
        last_hash=rows[-1]["hash"] if rows else REPLAY_SEED,
        last_prev_hash=rows[-1]["previousHash"] if rows else REPLAY_SEED,
    )
    return rows, meta


def _write_trace_files(
    tmpdir: Path,
    rows: list[dict],
    meta: dict,
) -> tuple[Path, Path]:
    jsonl_path = tmpdir / "trace.jsonl"
    meta_path = tmpdir / "trace-meta.json"
    jsonl_path.write_text(
        "\n".join(json.dumps(r) for r in rows) + ("\n" if rows else ""),
        encoding="utf-8",
    )
    meta_path.write_text(json.dumps(meta), encoding="utf-8")
    return jsonl_path, meta_path


def _run_replay(meta_path: Path, jsonl_path: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [
            sys.executable, str(REPLAY_SCRIPT),
            "--trace-meta", str(meta_path),
            "--trace-jsonl", str(jsonl_path),
        ],
        capture_output=True,
        text=True,
        timeout=30,
    )


class TestValidTrace(unittest.TestCase):
    """A minimal valid NDJSON trace should be accepted by replay.py."""

    def test_valid_three_rows(self):
        rows, meta = _make_valid_trace(3)
        with tempfile.TemporaryDirectory() as td:
            jsonl, mp = _write_trace_files(Path(td), rows, meta)
            result = _run_replay(mp, jsonl)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS", result.stdout)

    def test_valid_single_row(self):
        rows, meta = _make_valid_trace(1)
        with tempfile.TemporaryDirectory() as td:
            jsonl, mp = _write_trace_files(Path(td), rows, meta)
            result = _run_replay(mp, jsonl)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


class TestHashChainBreak(unittest.TestCase):
    """Modifying a row's hash should cause rejection."""

    def test_wrong_hash_in_middle(self):
        rows, meta = _make_valid_trace(3)
        # Break the chain: row 1 previousHash won't match row 0 hash
        rows[1]["previousHash"] = "0xdeadbeefdeadbeef"
        with tempfile.TemporaryDirectory() as td:
            jsonl, mp = _write_trace_files(Path(td), rows, meta)
            result = _run_replay(mp, jsonl)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("FAIL", result.stdout)

    def test_wrong_first_previous_hash(self):
        rows, meta = _make_valid_trace(2)
        # First row should have previousHash == REPLAY_SEED
        rows[0]["previousHash"] = "0xbadbadbadbadbad0"
        with tempfile.TemporaryDirectory() as td:
            jsonl, mp = _write_trace_files(Path(td), rows, meta)
            result = _run_replay(mp, jsonl)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("FAIL", result.stdout)


class TestMissingRequiredFields(unittest.TestCase):
    """A trace row without a required field should be rejected."""

    def _test_missing_field(self, field: str):
        rows, meta = _make_valid_trace(2)
        del rows[0][field]
        with tempfile.TemporaryDirectory() as td:
            jsonl, mp = _write_trace_files(Path(td), rows, meta)
            result = _run_replay(mp, jsonl)
            self.assertNotEqual(result.returncode, 0, f"field={field}")
            self.assertIn("FAIL", result.stdout, f"field={field}")

    def test_missing_traceVersion(self):
        self._test_missing_field("traceVersion")

    def test_missing_module(self):
        self._test_missing_field("module")

    def test_missing_opCode(self):
        self._test_missing_field("opCode")

    def test_missing_seq(self):
        self._test_missing_field("seq")

    def test_missing_hash(self):
        self._test_missing_field("hash")

    def test_missing_previousHash(self):
        self._test_missing_field("previousHash")

    def test_missing_command(self):
        self._test_missing_field("command")

    def test_missing_timestampMonoNs(self):
        self._test_missing_field("timestampMonoNs")

    def test_missing_meta_fields(self):
        rows, meta = _make_valid_trace(2)
        del meta["seqMax"]
        with tempfile.TemporaryDirectory() as td:
            jsonl, mp = _write_trace_files(Path(td), rows, meta)
            result = _run_replay(mp, jsonl)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("FAIL", result.stdout)


class TestOutOfOrderEvents(unittest.TestCase):
    """Events with non-monotonic sequence numbers should be rejected."""

    def test_non_monotonic_seq(self):
        rows, meta = _make_valid_trace(3)
        # Swap seq values of rows 1 and 2 so they are out of order
        rows[1]["seq"] = 2
        rows[2]["seq"] = 1
        with tempfile.TemporaryDirectory() as td:
            jsonl, mp = _write_trace_files(Path(td), rows, meta)
            result = _run_replay(mp, jsonl)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("FAIL", result.stdout)

    def test_duplicate_seq(self):
        rows, meta = _make_valid_trace(3)
        rows[2]["seq"] = 1  # duplicate of row 1
        with tempfile.TemporaryDirectory() as td:
            jsonl, mp = _write_trace_files(Path(td), rows, meta)
            result = _run_replay(mp, jsonl)
            self.assertNotEqual(result.returncode, 0)

    def test_gap_in_seq(self):
        rows, meta = _make_valid_trace(3)
        rows[1]["seq"] = 5  # gap: 0, 5, 2
        with tempfile.TemporaryDirectory() as td:
            jsonl, mp = _write_trace_files(Path(td), rows, meta)
            result = _run_replay(mp, jsonl)
            self.assertNotEqual(result.returncode, 0)


class TestDispatchTraceComparison(unittest.TestCase):
    """compare_dispatch_traces semantic parity checks."""

    def _make_dispatch_row(self, seq: int, command: str = "cmd_a", **extra) -> dict:
        row = {
            "seq": seq,
            "command": command,
            "kernel": "kern_a",
            "matched": "quirk_a",
            "scope": "alignment",
            "safetyClass": "moderate",
            "verificationMode": "guard_only",
            "proofLevel": "guarded",
            "requiresLean": False,
            "blocking": False,
            "score": 10,
            "matched_count": 1,
            "action": "toggle",
            "toggle": "FooToggle",
        }
        row.update(extra)
        return row

    def test_identical_traces_pass(self):
        baseline = [self._make_dispatch_row(0), self._make_dispatch_row(1)]
        comparison = [self._make_dispatch_row(0), self._make_dispatch_row(1)]
        errors = compare_mod.validate_sequences(baseline, comparison)
        self.assertEqual(errors, [])

    def test_different_command_fails(self):
        baseline = [self._make_dispatch_row(0, command="cmd_a")]
        comparison = [self._make_dispatch_row(0, command="cmd_b")]
        errors = compare_mod.validate_sequences(baseline, comparison)
        self.assertTrue(len(errors) > 0)

    def test_different_length_fails(self):
        baseline = [self._make_dispatch_row(0)]
        comparison = [self._make_dispatch_row(0), self._make_dispatch_row(1)]
        errors = compare_mod.validate_sequences(baseline, comparison)
        self.assertTrue(any("entry_count" in e for e in errors))

    def test_different_scope_fails(self):
        baseline = [self._make_dispatch_row(0, scope="alignment")]
        comparison = [self._make_dispatch_row(0, scope="memory")]
        errors = compare_mod.validate_sequences(baseline, comparison)
        self.assertTrue(len(errors) > 0)

    def test_pick_fields_filters_extra(self):
        row = self._make_dispatch_row(0)
        row["extraField"] = "should_be_ignored"
        picked = compare_mod.pick_fields(row)
        self.assertNotIn("extraField", picked)
        self.assertIn("seq", picked)
        self.assertIn("command", picked)

    def test_comparison_via_script(self):
        baseline = [self._make_dispatch_row(i) for i in range(3)]
        comparison = [self._make_dispatch_row(i) for i in range(3)]
        with tempfile.TemporaryDirectory() as td:
            lp = Path(td) / "baseline.jsonl"
            rp = Path(td) / "comparison.jsonl"
            lp.write_text("\n".join(json.dumps(r) for r in baseline), encoding="utf-8")
            rp.write_text("\n".join(json.dumps(r) for r in comparison), encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(COMPARE_SCRIPT), "--baseline", str(lp), "--comparison", str(rp)],
                capture_output=True, text=True, timeout=30,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS", result.stdout)

    def test_comparison_via_script_fails_on_diff(self):
        baseline = [self._make_dispatch_row(0, command="cmd_a")]
        comparison = [self._make_dispatch_row(0, command="cmd_b")]
        with tempfile.TemporaryDirectory() as td:
            lp = Path(td) / "baseline.jsonl"
            rp = Path(td) / "comparison.jsonl"
            lp.write_text(json.dumps(baseline[0]), encoding="utf-8")
            rp.write_text(json.dumps(comparison[0]), encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(COMPARE_SCRIPT), "--baseline", str(lp), "--comparison", str(rp)],
                capture_output=True, text=True, timeout=30,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("FAIL", result.stdout)

    def test_read_ndjson_skips_blank_lines(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "test.jsonl"
            p.write_text('{"seq": 0}\n\n{"seq": 1}\n\n', encoding="utf-8")
            rows = compare_mod.read_ndjson(p)
            self.assertEqual(len(rows), 2)


class TestEmptyTrace(unittest.TestCase):
    """Empty trace file should be handled gracefully."""

    def test_empty_jsonl_with_matching_meta(self):
        meta = {
            "traceVersion": 1,
            "module": "test_module",
            "seqMax": 0,
            "rowCount": 0,
            "hash": REPLAY_SEED,
            "previousHash": REPLAY_SEED,
        }
        with tempfile.TemporaryDirectory() as td:
            jsonl = Path(td) / "trace.jsonl"
            mp = Path(td) / "trace-meta.json"
            jsonl.write_text("", encoding="utf-8")
            mp.write_text(json.dumps(meta), encoding="utf-8")
            result = _run_replay(mp, jsonl)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS", result.stdout)

    def test_empty_jsonl_with_nonzero_rowcount_fails(self):
        meta = {
            "traceVersion": 1,
            "module": "test_module",
            "seqMax": 0,
            "rowCount": 5,
            "hash": REPLAY_SEED,
            "previousHash": REPLAY_SEED,
        }
        with tempfile.TemporaryDirectory() as td:
            jsonl = Path(td) / "trace.jsonl"
            mp = Path(td) / "trace-meta.json"
            jsonl.write_text("", encoding="utf-8")
            mp.write_text(json.dumps(meta), encoding="utf-8")
            result = _run_replay(mp, jsonl)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("FAIL", result.stdout)

    def test_missing_jsonl_file_fails(self):
        meta = {
            "traceVersion": 1,
            "module": "test_module",
            "seqMax": 0,
            "rowCount": 0,
            "hash": REPLAY_SEED,
            "previousHash": REPLAY_SEED,
        }
        with tempfile.TemporaryDirectory() as td:
            mp = Path(td) / "trace-meta.json"
            mp.write_text(json.dumps(meta), encoding="utf-8")
            nonexistent = Path(td) / "missing.jsonl"
            result = _run_replay(mp, nonexistent)
            self.assertNotEqual(result.returncode, 0)

    def test_malformed_json_in_jsonl_fails(self):
        rows, meta = _make_valid_trace(2)
        with tempfile.TemporaryDirectory() as td:
            jsonl = Path(td) / "trace.jsonl"
            mp = Path(td) / "trace-meta.json"
            jsonl.write_text("{bad json\n" + json.dumps(rows[1]), encoding="utf-8")
            mp.write_text(json.dumps(meta), encoding="utf-8")
            result = _run_replay(mp, jsonl)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("FAIL", result.stdout)

    def test_wrong_trace_version_fails(self):
        rows, meta = _make_valid_trace(1)
        rows[0]["traceVersion"] = 99
        with tempfile.TemporaryDirectory() as td:
            jsonl, mp = _write_trace_files(Path(td), rows, meta)
            result = _run_replay(mp, jsonl)
            self.assertNotEqual(result.returncode, 0)

    def test_wrong_opcode_fails(self):
        rows, meta = _make_valid_trace(1)
        rows[0]["opCode"] = "submit"
        with tempfile.TemporaryDirectory() as td:
            jsonl, mp = _write_trace_files(Path(td), rows, meta)
            result = _run_replay(mp, jsonl)
            self.assertNotEqual(result.returncode, 0)

    def test_package_step_opcodes_pass(self):
        rows, meta = _make_valid_trace(4)
        for row, op_code in zip(rows, ["upload", "dispatch", "copy", "readback"]):
            row["opCode"] = op_code
        with tempfile.TemporaryDirectory() as td:
            jsonl, mp = _write_trace_files(Path(td), rows, meta)
            result = _run_replay(mp, jsonl)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_meta_hash_mismatch_fails(self):
        rows, meta = _make_valid_trace(2)
        meta["hash"] = "0xffffffffffffffff"
        with tempfile.TemporaryDirectory() as td:
            jsonl, mp = _write_trace_files(Path(td), rows, meta)
            result = _run_replay(mp, jsonl)
            self.assertNotEqual(result.returncode, 0)

    def test_meta_seq_max_mismatch_fails(self):
        rows, meta = _make_valid_trace(2)
        meta["seqMax"] = 999
        with tempfile.TemporaryDirectory() as td:
            jsonl, mp = _write_trace_files(Path(td), rows, meta)
            result = _run_replay(mp, jsonl)
            self.assertNotEqual(result.returncode, 0)


class TestMetaValidation(unittest.TestCase):
    """Validate trace-meta specific checks."""

    def test_missing_trace_meta_file_fails(self):
        with tempfile.TemporaryDirectory() as td:
            jsonl = Path(td) / "trace.jsonl"
            jsonl.write_text("", encoding="utf-8")
            nonexistent = Path(td) / "missing-meta.json"
            result = _run_replay(nonexistent, jsonl)
            self.assertNotEqual(result.returncode, 0)

    def test_non_object_meta_fails(self):
        with tempfile.TemporaryDirectory() as td:
            jsonl = Path(td) / "trace.jsonl"
            mp = Path(td) / "trace-meta.json"
            jsonl.write_text("", encoding="utf-8")
            mp.write_text('"just a string"', encoding="utf-8")
            result = _run_replay(mp, jsonl)
            self.assertNotEqual(result.returncode, 0)

    def test_negative_row_count_fails(self):
        meta = {
            "traceVersion": 1,
            "module": "test_module",
            "seqMax": 0,
            "rowCount": -1,
            "hash": REPLAY_SEED,
            "previousHash": REPLAY_SEED,
        }
        with tempfile.TemporaryDirectory() as td:
            jsonl = Path(td) / "trace.jsonl"
            mp = Path(td) / "trace-meta.json"
            jsonl.write_text("", encoding="utf-8")
            mp.write_text(json.dumps(meta), encoding="utf-8")
            result = _run_replay(mp, jsonl)
            self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
