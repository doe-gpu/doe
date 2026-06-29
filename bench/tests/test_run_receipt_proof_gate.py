#!/usr/bin/env python3
"""Tests for run_receipt_proof_gate.py.

Covers field completeness failures, manifest/shard hash verification,
replay_class enforcement, and PASS path.
Runs without network or GPU access.
"""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
GATE_SCRIPT = REPO_ROOT / 'bench' / 'gates' / 'run_receipt_proof_gate.py'
SAMPLE_RECEIPT = REPO_ROOT / 'examples' / 'doe-run-receipt-v1.sample.json'

_VALID = json.loads(SAMPLE_RECEIPT.read_text(encoding='utf-8'))


def _run_gate(receipt_dict: dict, *, manifest_path: str = '', shards_dir: str = '') -> tuple[int, str]:
    with tempfile.NamedTemporaryFile(suffix='.json', mode='w', delete=False) as f:
        json.dump(receipt_dict, f)
        tmp = f.name
    cmd = [sys.executable, str(GATE_SCRIPT), '--receipt', tmp]
    if manifest_path:
        cmd += ['--manifest', manifest_path]
    if shards_dir:
        cmd += ['--shards-dir', shards_dir]
    result = subprocess.run(cmd, capture_output=True, text=True)
    return result.returncode, result.stdout + result.stderr


class TestRunReceiptProofGate(unittest.TestCase):

    def test_valid_sample_passes(self) -> None:
        rc, out = _run_gate(_VALID)
        self.assertEqual(rc, 0, out)
        self.assertIn('PASS', out)

    def test_missing_required_field_fails(self) -> None:
        bad = {k: v for k, v in _VALID.items() if k != 'kernel_path'}
        rc, out = _run_gate(bad)
        self.assertEqual(rc, 1)
        self.assertIn('kernel_path', out)

    def test_null_required_field_fails(self) -> None:
        bad = {**_VALID, 'dtype_policy': None}
        rc, out = _run_gate(bad)
        self.assertEqual(rc, 1)
        self.assertIn('dtype_policy', out)

    def test_wrong_receipt_version_fails(self) -> None:
        bad = {**_VALID, 'receipt_version': 'doe.receipt.v0.9'}
        rc, out = _run_gate(bad)
        self.assertEqual(rc, 1)
        self.assertIn('receipt_version', out)

    def test_invalid_replay_class_fails(self) -> None:
        bad = {**_VALID, 'replay_class': 'approximate'}
        rc, out = _run_gate(bad)
        self.assertEqual(rc, 1)
        self.assertIn('replay_class', out)

    def test_invalid_backend_fails(self) -> None:
        bad = {**_VALID, 'backend': 'CUDA'}
        rc, out = _run_gate(bad)
        self.assertEqual(rc, 1)
        self.assertIn('backend', out)

    def test_missing_device_descriptor_field_fails(self) -> None:
        bad = {**_VALID, 'device_descriptor': {'device_name': 'test', 'driver_version': 'x'}}
        rc, out = _run_gate(bad)
        self.assertEqual(rc, 1)
        self.assertIn('api_feature_level', out)

    def test_manifest_hash_pass(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            mpath = Path(tmpdir) / 'manifest.json'
            content = '{"model": "gemma"}'
            mpath.write_text(content, encoding='utf-8')
            h = 'sha256:' + hashlib.sha256(content.encode()).hexdigest()
            receipt = {**_VALID, 'manifest_hash': h}
            rc, out = _run_gate(receipt, manifest_path=str(mpath))
            self.assertEqual(rc, 0, out)

    def test_manifest_hash_mismatch_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            mpath = Path(tmpdir) / 'manifest.json'
            mpath.write_text('{"model": "gemma"}', encoding='utf-8')
            receipt = {**_VALID, 'manifest_hash': 'sha256:' + '0' * 64}
            rc, out = _run_gate(receipt, manifest_path=str(mpath))
            self.assertEqual(rc, 1)
            self.assertIn('manifest hash mismatch', out)

    def test_shard_hash_pass(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            shard_data = b'\x01\x02\x03\x04'
            shard_file = Path(tmpdir) / 'layers_0_down_proj.kron'
            shard_file.write_bytes(shard_data)
            h = 'sha256:' + hashlib.sha256(shard_data).hexdigest()
            receipt = {**_VALID, 'shard_hashes': {'layers_0_down_proj.kron': h}}
            rc, out = _run_gate(receipt, shards_dir=tmpdir)
            self.assertEqual(rc, 0, out)

    def test_shard_hash_mismatch_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            shard_file = Path(tmpdir) / 'layers_0_down_proj.kron'
            shard_file.write_bytes(b'\xff')
            receipt = {**_VALID, 'shard_hashes': {'layers_0_down_proj.kron': 'sha256:' + 'a' * 64}}
            rc, out = _run_gate(receipt, shards_dir=tmpdir)
            self.assertEqual(rc, 1)
            self.assertIn('shard hash mismatch', out)

    def test_missing_shard_file_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            receipt = {**_VALID, 'shard_hashes': {'missing_shard.kron': 'sha256:' + 'b' * 64}}
            rc, out = _run_gate(receipt, shards_dir=tmpdir)
            self.assertEqual(rc, 1)
            self.assertIn('missing_shard.kron', out)


if __name__ == '__main__':
    unittest.main()
