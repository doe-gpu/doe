#!/usr/bin/env python3
"""CPU reference oracle for the governed workgroup recurrence kernels."""

from __future__ import annotations

import argparse
import hashlib
import struct


U32_MASK = (1 << 32) - 1


def expected_output(
    *,
    dispatch_count: int,
    workgroup_count: int = 1024,
    workgroup_size: int = 256,
) -> bytes:
    if dispatch_count <= 0 or workgroup_count <= 0 or workgroup_size <= 0:
        raise ValueError("dispatch and workgroup counts must be positive")
    if workgroup_size & (workgroup_size - 1):
        raise ValueError("workgroup_size must be a power of two")

    output = bytearray(workgroup_count * workgroup_size * 4)
    local_mask = workgroup_size - 1
    for group in range(workgroup_count):
        group_base = group * workgroup_size
        state = 0
        for _ in range(dispatch_count):
            accum = state
            for index in range(workgroup_size):
                local_index = (index + accum) & local_mask
                accum = (state + group_base + local_index) & U32_MASK
            state = accum
        encoded = struct.pack("<I", state)
        start = group_base * 4
        output[start : start + workgroup_size * 4] = encoded * workgroup_size
    return bytes(output)


def expected_sha256(*, dispatch_count: int) -> str:
    return hashlib.sha256(expected_output(dispatch_count=dispatch_count)).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dispatch-count", type=int, required=True)
    args = parser.parse_args()
    print(expected_sha256(dispatch_count=args.dispatch_count))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
