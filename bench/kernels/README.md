bench/kernels is the default kernel root for backend and runtime comparison
lanes. Native compare configs, runtime backend defaults, and several focused
command fixtures resolve bare kernel names from this directory.

bench/inference-pipeline/kernels is the model inference kernel root. Package
inference workloads and IR-backed executor lanes resolve their kernels from
that directory.

The two roots intentionally mirror a small compatibility set while those lookup
contracts remain separate:

- rmsnorm.wgsl
- rmsnorm_subgroup.wgsl
- matmul_gemv_subgroup.wgsl

Keep mirrored files byte-identical unless both root contracts are updated in
the same change. bench/tests/test_kernel_mirror_policy.py guards this.
