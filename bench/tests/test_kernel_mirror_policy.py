#!/usr/bin/env python3
"""Guards for WGSL kernels mirrored across active benchmark roots."""

from __future__ import annotations

import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]

MIRRORED_KERNELS = (
    (
        "bench/inference-pipeline/kernels/rmsnorm.wgsl",
        "bench/kernels/rmsnorm.wgsl",
    ),
    (
        "bench/inference-pipeline/kernels/rmsnorm_subgroup.wgsl",
        "bench/kernels/rmsnorm_subgroup.wgsl",
    ),
    (
        "bench/inference-pipeline/kernels/matmul_gemv_subgroup.wgsl",
        "bench/kernels/matmul_gemv_subgroup.wgsl",
    ),
)


class KernelMirrorPolicyTests(unittest.TestCase):
    def test_mirrored_kernel_roots_stay_byte_identical(self) -> None:
        for inference_path, backend_path in MIRRORED_KERNELS:
            with self.subTest(inference_path=inference_path, backend_path=backend_path):
                inference_kernel = REPO_ROOT / inference_path
                backend_kernel = REPO_ROOT / backend_path
                self.assertTrue(inference_kernel.exists(), msg=f"missing {inference_path}")
                self.assertTrue(backend_kernel.exists(), msg=f"missing {backend_path}")
                self.assertEqual(
                    inference_kernel.read_bytes(),
                    backend_kernel.read_bytes(),
                    msg=(
                        f"{inference_path} and {backend_path} are mirrored across "
                        "active kernel roots; update both or change the root contract"
                    ),
                )


if __name__ == "__main__":
    unittest.main()
