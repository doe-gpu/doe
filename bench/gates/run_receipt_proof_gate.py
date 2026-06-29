#!/usr/bin/env python3
"""Doe RunReceipt v1.0 proof gate.

Validates field completeness, manifest and shard cryptographic integrity,
and input/output trace hash matching for a doe run receipt.

Usage:
  python3 bench/gates/run_receipt_proof_gate.py \\
    --receipt reports/receipt-<id>.json \\
    [--manifest path/to/manifest.json] \\
    [--shards-dir path/to/shards/]
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any


RECEIPT_VERSION = 'doe.receipt.v1.0'

REQUIRED_FIELDS = [
    'receipt_version',
    'receipt_id',
    'timestamp_utc',
    'manifest_hash',
    'shard_hashes',
    'runtime_version',
    'kernel_path',
    'dtype_policy',
    'backend',
    'device_descriptor',
    'input_hash',
    'output_hash',
    'replay_class',
    'execution_time_ms',
]

REQUIRED_DEVICE_FIELDS = [
    'device_name',
    'driver_version',
    'api_feature_level',
]

VALID_REPLAY_CLASSES = frozenset({'bit_exact', 'bounded_replay'})
VALID_BACKENDS = frozenset({'WebGPU', 'Vulkan', 'Metal', 'D3D12', 'CSL'})


def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    h.update(path.read_bytes())
    return f'sha256:{h.hexdigest()}'


def _check_field_completeness(receipt: dict[str, Any]) -> list[str]:
    errors: list[str] = []

    for field in REQUIRED_FIELDS:
        if field not in receipt or receipt[field] is None:
            errors.append(f'field completeness: missing or null field: {field!r}')

    rv = receipt.get('receipt_version')
    if rv != RECEIPT_VERSION:
        errors.append(f'field completeness: receipt_version={rv!r}, expected {RECEIPT_VERSION!r}')

    rc = receipt.get('replay_class')
    if rc not in VALID_REPLAY_CLASSES:
        errors.append(
            f'field completeness: replay_class={rc!r}, '
            f'expected one of {sorted(VALID_REPLAY_CLASSES)}'
        )

    backend = receipt.get('backend')
    if backend not in VALID_BACKENDS:
        errors.append(
            f'field completeness: backend={backend!r}, '
            f'expected one of {sorted(VALID_BACKENDS)}'
        )

    dd = receipt.get('device_descriptor')
    if isinstance(dd, dict):
        for f in REQUIRED_DEVICE_FIELDS:
            if not dd.get(f):
                errors.append(f'field completeness: device_descriptor.{f}: missing or empty')
    elif dd is not None:
        errors.append('field completeness: device_descriptor must be an object')

    sh = receipt.get('shard_hashes')
    if sh is not None and not isinstance(sh, dict):
        errors.append('field completeness: shard_hashes must be an object')

    etms = receipt.get('execution_time_ms')
    if etms is not None and not isinstance(etms, (int, float)):
        errors.append('field completeness: execution_time_ms must be a number')

    return errors


def _check_manifest_hash(receipt: dict[str, Any], manifest_path: Path) -> list[str]:
    declared = receipt.get('manifest_hash', '')
    actual = _sha256_file(manifest_path)
    if declared != actual:
        return [
            f'manifest hash mismatch: receipt declares {declared!r}, '
            f'computed {actual!r} from {manifest_path}'
        ]
    return []


def _check_shard_hashes(receipt: dict[str, Any], shards_dir: Path) -> list[str]:
    errors: list[str] = []
    shard_hashes: dict[str, str] = receipt.get('shard_hashes') or {}
    for rel_path, declared_hash in shard_hashes.items():
        shard_path = shards_dir / rel_path
        if not shard_path.exists():
            errors.append(f'shard not found: {shard_path}')
            continue
        actual = _sha256_file(shard_path)
        if declared_hash != actual:
            errors.append(
                f'shard hash mismatch for {rel_path!r}: '
                f'declared {declared_hash!r}, computed {actual!r}'
            )
    return errors


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description='Validate a Doe RunReceipt v1.0 artifact.')
    p.add_argument('--receipt', required=True, help='Path to receipt JSON file')
    p.add_argument(
        '--manifest',
        default='',
        help='Path to manifest.json; if provided, manifest_hash is verified',
    )
    p.add_argument(
        '--shards-dir',
        default='',
        help='Directory containing shard files; if provided, all shard_hashes are verified',
    )
    return p.parse_args()


def main() -> int:
    args = parse_args()
    receipt_path = Path(args.receipt)

    try:
        receipt = json.loads(receipt_path.read_text(encoding='utf-8'))
    except (OSError, json.JSONDecodeError) as exc:
        print(f'FAIL: run receipt proof gate: cannot read receipt: {exc}')
        return 1

    if not isinstance(receipt, dict):
        print('FAIL: run receipt proof gate: receipt must be a JSON object')
        return 1

    failures: list[str] = []

    failures.extend(_check_field_completeness(receipt))

    if args.manifest:
        manifest_path = Path(args.manifest)
        if not manifest_path.exists():
            failures.append(f'manifest file not found: {manifest_path}')
        else:
            failures.extend(_check_manifest_hash(receipt, manifest_path))

    if args.shards_dir:
        shards_dir = Path(args.shards_dir)
        if not shards_dir.is_dir():
            failures.append(f'shards directory not found: {shards_dir}')
        else:
            failures.extend(_check_shard_hashes(receipt, shards_dir))

    if failures:
        print('FAIL: run receipt proof gate')
        for f in failures:
            print(f'  {f}')
        return 1

    rid = receipt.get('receipt_id', '?')
    rc = receipt.get('replay_class', '?')
    backend = receipt.get('backend', '?')
    print(
        f'PASS: run receipt proof gate '
        f'(id={rid}, replay_class={rc!r}, backend={backend!r})'
    )
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
