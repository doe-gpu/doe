"""Executor-id registry for benchmark runners.

Keeps executor identity explicit in config while preserving command-template
compatibility for the existing compare stack.
"""

from __future__ import annotations

from dataclasses import dataclass


_DOE_RUNTIME_PREFIX = (
    "env DYLD_LIBRARY_PATH=bench/vendor/dawn/out/Release:$DYLD_LIBRARY_PATH "
    "runtime/zig/zig-out/bin/doe-zig-runtime --commands {commands} --quirks {quirks} "
    "--vendor {vendor} --api {api} --family {family} --driver {driver} "
    "--backend native --execute --trace --queue-sync-mode {queue_sync_mode} "
    "--upload-buffer-usage {upload_buffer_usage} --upload-submit-every {upload_submit_every} "
    "--trace-jsonl {trace_jsonl} --trace-meta {trace_meta} --gpu-timestamp-mode off "
    "--kernel-root bench/kernels {extra_args}"
)

_DOE_PLAN_PREFIX = (
    "env DYLD_LIBRARY_PATH=bench/vendor/dawn/out/Release:$DYLD_LIBRARY_PATH "
    "runtime/zig/zig-out/bin/doe-plan-executor --plan {plan} "
    "--trace-jsonl {trace_jsonl} --trace-meta {trace_meta} --workload {workload} "
    "--vendor {vendor} --api {api} --family {family} --driver {driver} "
    "--queue-sync-mode {queue_sync_mode} --upload-buffer-usage {upload_buffer_usage} "
    "--upload-submit-every {upload_submit_every} --gpu-timestamp-mode off {extra_args}"
)

_DAWN_DIRECT_PREFIX = (
    "env DYLD_LIBRARY_PATH=bench/vendor/dawn/out/Release:$DYLD_LIBRARY_PATH "
    "runtime/zig/zig-out/bin/webgpu-plan-executor --plan {plan} "
    "--trace-jsonl {trace_jsonl} --trace-meta {trace_meta} --workload {workload}"
)

_APPLE_WEBKIT_DIRECT_PREFIX = (
    "env DYLD_LIBRARY_PATH=bench/vendor/webkit-webgpu/out/shim:$DYLD_LIBRARY_PATH "
    "runtime/zig/zig-out/bin/webgpu-plan-executor --plan {plan} "
    "--trace-jsonl {trace_jsonl} --trace-meta {trace_meta} --workload {workload} "
    "--backend-id webkit_direct_metal"
)

_WEBKIT_RUNTIME_PREFIX = (
    "env DYLD_LIBRARY_PATH=bench/vendor/webkit-webgpu/out/shim:bench/vendor/dawn/out/Release:$DYLD_LIBRARY_PATH "
    "runtime/zig/zig-out/bin/doe-zig-runtime --commands {commands} --quirks {quirks} "
    "--vendor {vendor} --api {api} --family {family} --driver {driver} "
    "--backend native --execute --trace --queue-sync-mode {queue_sync_mode} "
    "--upload-buffer-usage {upload_buffer_usage} --upload-submit-every {upload_submit_every} "
    "--trace-jsonl {trace_jsonl} --trace-meta {trace_meta} --gpu-timestamp-mode off "
    "--kernel-root bench/kernels {extra_args}"
)


@dataclass(frozen=True)
class ExecutorSpec:
    executor_id: str
    command_template: str
    execution_boundary: str


_NODE_WEBGPU_PACKAGE_PREPARED_TEMPLATE = (
    "node bench/executors/run-node-webgpu-plan.js "
    "--provider node-webgpu --prepared-session --plan {plan} --trace-jsonl {trace_jsonl} "
    "--trace-meta {trace_meta} --workload {workload} "
    "--command-repeat {command_repeat}"
)

_DOE_NODE_WEBGPU_PREPARED_TEMPLATE = (
    "node bench/executors/run-node-webgpu-plan.js "
    "--provider doe --prepared-session --plan {plan} --trace-jsonl {trace_jsonl} "
    "--trace-meta {trace_meta} --workload {workload} "
    "--command-repeat {command_repeat}"
)

_DOE_NODE_WEBGPU_PREPARED_NO_DISPATCH_PREWARM_TEMPLATE = (
    "node bench/executors/run-node-webgpu-plan.js "
    "--provider doe --prepared-session --skip-dispatch-prewarm "
    "--plan {plan} --trace-jsonl {trace_jsonl} "
    "--trace-meta {trace_meta} --workload {workload} "
    "--command-repeat {command_repeat}"
)

_DOE_NODE_NATIVE_DIRECT_PREPARED_TEMPLATE = (
    "node bench/executors/run-node-webgpu-plan.js "
    "--provider doe-direct --prepared-session --plan {plan} "
    "--trace-jsonl {trace_jsonl} --trace-meta {trace_meta} "
    "--workload {workload} --command-repeat {command_repeat}"
)

_BUN_WEBGPU_PACKAGE_PREPARED_TEMPLATE = (
    "bun bench/executors/run-bun-webgpu-plan.js "
    "--provider bun-webgpu --prepared-session --plan {plan} --trace-jsonl {trace_jsonl} "
    "--trace-meta {trace_meta} --workload {workload} "
    "--command-repeat {command_repeat}"
)

_DOE_BUN_PACKAGE_PREPARED_TEMPLATE = (
    "bun bench/executors/run-bun-webgpu-plan.js "
    "--provider doe --prepared-session --plan {plan} --trace-jsonl {trace_jsonl} "
    "--trace-meta {trace_meta} --workload {workload} "
    "--command-repeat {command_repeat}"
)

_DOE_BUN_PACKAGE_FFI_PREPARED_TEMPLATE = (
    "bun bench/executors/run-bun-webgpu-plan.js "
    "--provider doe-ffi --prepared-session --plan {plan} --trace-jsonl {trace_jsonl} "
    "--trace-meta {trace_meta} --workload {workload} "
    "--command-repeat {command_repeat}"
)

_DENO_WEBGPU_PACKAGE_PREPARED_TEMPLATE = (
    "npx --yes deno run --unstable-webgpu --allow-all "
    "bench/executors/run-deno-webgpu-plan.js "
    "--provider deno-webgpu --prepared-session --plan {plan} "
    "--trace-jsonl {trace_jsonl} --trace-meta {trace_meta} --workload {workload} "
    "--command-repeat {command_repeat}"
)

_DOE_DENO_PACKAGE_PREPARED_TEMPLATE = (
    "npx --yes deno run --unstable-webgpu --allow-all "
    "bench/executors/run-deno-webgpu-plan.js "
    "--provider doe --prepared-session --plan {plan} --trace-jsonl {trace_jsonl} "
    "--trace-meta {trace_meta} --workload {workload} "
    "--command-repeat {command_repeat}"
)

def _resident_buffer_load_template(command_template: str) -> str:
    return f"{command_template} --resident-buffer-loads"


def _vulkan_pipeline_cache_template(command_template: str) -> str:
    return f"env DOE_PIPELINE_CACHE_DIR={{pipeline_cache_dir}} {command_template}"


_REGISTRY: dict[str, ExecutorSpec] = {
    "doe_direct_metal": ExecutorSpec(
        executor_id="doe_direct_metal",
        command_template=_DOE_RUNTIME_PREFIX.replace(
            "--backend native --execute",
            "--backend native --backend-lane metal_doe_comparable --execute --no-pipeline-cache",
        ),
        execution_boundary="commands",
    ),
    "doe_direct_metal_cache": ExecutorSpec(
        executor_id="doe_direct_metal_cache",
        command_template=_DOE_RUNTIME_PREFIX.replace(
            "--backend native --execute",
            "--backend native --backend-lane metal_doe_comparable --execute",
        ),
        execution_boundary="commands",
    ),
    "doe_direct_vulkan": ExecutorSpec(
        executor_id="doe_direct_vulkan",
        command_template=_DOE_RUNTIME_PREFIX.replace(
            "--backend native --execute",
            "--backend native --backend-lane vulkan_doe_comparable --execute",
        ),
        execution_boundary="commands",
    ),
    "doe_direct_d3d12": ExecutorSpec(
        executor_id="doe_direct_d3d12",
        command_template=_DOE_RUNTIME_PREFIX.replace(
            "--backend native --execute",
            "--backend native --backend-lane d3d12_doe_comparable --execute",
        ),
        execution_boundary="commands",
    ),
    "doe_direct_plan_metal": ExecutorSpec(
        executor_id="doe_direct_plan_metal",
        command_template=_DOE_PLAN_PREFIX + " --backend-lane metal_doe_comparable",
        execution_boundary="plan",
    ),
    "doe_direct_plan_vulkan": ExecutorSpec(
        executor_id="doe_direct_plan_vulkan",
        command_template=_DOE_PLAN_PREFIX + " --backend-lane vulkan_doe_comparable",
        execution_boundary="plan",
    ),
    "dawn_delegate_metal": ExecutorSpec(
        executor_id="dawn_delegate_metal",
        command_template=_DOE_RUNTIME_PREFIX.replace(
            "--backend native --execute",
            "--backend native --backend-lane metal_dawn_release --execute --no-pipeline-cache",
        ),
        execution_boundary="commands",
    ),
    "dawn_delegate_metal_cache": ExecutorSpec(
        executor_id="dawn_delegate_metal_cache",
        command_template=_DOE_RUNTIME_PREFIX.replace(
            "--backend native --execute",
            "--backend native --backend-lane metal_dawn_release --execute",
        ),
        execution_boundary="commands",
    ),
    # Fair-cold lanes: --no-pipeline-cache disables Doe's MTLBinaryArchive at
    # backend init so a Doe-vs-Dawn comparison on cache-asymmetric kernels
    # measures runtime engineering, not pre-built archive savings. Dawn-side
    # template carries the same flag for command symmetry; the flag is a no-op
    # there because Dawn's Metal backend doesn't open Doe's archive. Pair these
    # two executors when comparing workloads listed in
    # bench/kernels/doe_pipeline_archive.manifest. See
    # docs/status/2026-04.md "Apple Metal pipeline-cache asymmetry" entry and
    # CLAUDE.md non-negotiable #7.
    "doe_direct_metal_no_cache": ExecutorSpec(
        executor_id="doe_direct_metal_no_cache",
        command_template=(
            _DOE_RUNTIME_PREFIX.replace(
                "--backend native --execute",
                "--backend native --backend-lane metal_doe_comparable --execute --no-pipeline-cache",
            )
        ),
        execution_boundary="commands",
    ),
    "dawn_delegate_metal_no_cache": ExecutorSpec(
        executor_id="dawn_delegate_metal_no_cache",
        command_template=(
            _DOE_RUNTIME_PREFIX.replace(
                "--backend native --execute",
                "--backend native --backend-lane metal_dawn_release --execute --no-pipeline-cache",
            )
        ),
        execution_boundary="commands",
    ),
    "webkit_delegate_metal": ExecutorSpec(
        executor_id="webkit_delegate_metal",
        command_template=_WEBKIT_RUNTIME_PREFIX.replace(
            "--backend native --execute",
            "--backend native --backend-lane metal_webkit_comparable --execute",
        ),
        execution_boundary="commands",
    ),
    "dawn_delegate_vulkan": ExecutorSpec(
        executor_id="dawn_delegate_vulkan",
        command_template=_DOE_RUNTIME_PREFIX.replace(
            "--backend native --execute",
            "--backend native --backend-lane vulkan_dawn_release --execute",
        ),
        execution_boundary="commands",
    ),
    "dawn_delegate_plan_vulkan": ExecutorSpec(
        executor_id="dawn_delegate_plan_vulkan",
        command_template=_DOE_PLAN_PREFIX + " --backend-lane vulkan_dawn_release",
        execution_boundary="plan",
    ),
    "dawn_delegate_d3d12": ExecutorSpec(
        executor_id="dawn_delegate_d3d12",
        command_template=_DOE_RUNTIME_PREFIX.replace(
            "--backend native --execute",
            "--backend native --backend-lane d3d12_dawn_release --execute",
        ),
        execution_boundary="commands",
    ),
    "dawn_direct_metal": ExecutorSpec(
        executor_id="dawn_direct_metal",
        command_template=_DAWN_DIRECT_PREFIX,
        execution_boundary="plan",
    ),
    "webkit_webgpu_native_metal": ExecutorSpec(
        executor_id="webkit_webgpu_native_metal",
        command_template=_APPLE_WEBKIT_DIRECT_PREFIX,
        execution_boundary="plan",
    ),
    "ort_native_doe_ep": ExecutorSpec(
        executor_id="ort_native_doe_ep",
        command_template=(
            "python3 bench/executors/run-native-ort-ep-bench.py "
            "--scenario {commands} --trace-jsonl {trace_jsonl} "
            "--trace-meta {trace_meta} --workload {workload}"
        ),
        execution_boundary="commands",
    ),
    "ort_native_webgpu_incumbent": ExecutorSpec(
        executor_id="ort_native_webgpu_incumbent",
        command_template=(
            "python3 bench/executors/run-native-ort-incumbent-bench.py "
            "--scenario {commands} --trace-jsonl {trace_jsonl} "
            "--trace-meta {trace_meta} --workload {workload}"
        ),
        execution_boundary="commands",
    ),
    "node_webgpu_package": ExecutorSpec(
        executor_id="node_webgpu_package",
        command_template=(
            "node bench/executors/run-node-webgpu-plan.js "
            "--provider node-webgpu --plan {plan} --trace-jsonl {trace_jsonl} "
            "--trace-meta {trace_meta} --workload {workload}"
        ),
        execution_boundary="plan",
    ),
    "doe_node_webgpu": ExecutorSpec(
        executor_id="doe_node_webgpu",
        command_template=(
            "node bench/executors/run-node-webgpu-plan.js "
            "--provider doe --plan {plan} --trace-jsonl {trace_jsonl} "
            "--trace-meta {trace_meta} --workload {workload}"
        ),
        execution_boundary="plan",
    ),
    "doe_node_native_direct": ExecutorSpec(
        executor_id="doe_node_native_direct",
        command_template=(
            "node bench/executors/run-node-webgpu-plan.js "
            "--provider doe-direct --plan {plan} --trace-jsonl {trace_jsonl} "
            "--trace-meta {trace_meta} --workload {workload}"
        ),
        execution_boundary="plan",
    ),
    "node_webgpu_package_prepared": ExecutorSpec(
        executor_id="node_webgpu_package_prepared",
        command_template=_NODE_WEBGPU_PACKAGE_PREPARED_TEMPLATE,
        execution_boundary="plan",
    ),
    "node_webgpu_package_prepared_resident_buffer_loads": ExecutorSpec(
        executor_id="node_webgpu_package_prepared_resident_buffer_loads",
        command_template=_resident_buffer_load_template(
            _NODE_WEBGPU_PACKAGE_PREPARED_TEMPLATE
        ),
        execution_boundary="plan",
    ),
    "doe_node_webgpu_prepared": ExecutorSpec(
        executor_id="doe_node_webgpu_prepared",
        command_template=_DOE_NODE_WEBGPU_PREPARED_TEMPLATE,
        execution_boundary="plan",
    ),
    "doe_node_webgpu_prepared_no_dispatch_prewarm": ExecutorSpec(
        executor_id="doe_node_webgpu_prepared_no_dispatch_prewarm",
        command_template=_DOE_NODE_WEBGPU_PREPARED_NO_DISPATCH_PREWARM_TEMPLATE,
        execution_boundary="plan",
    ),
    "doe_node_webgpu_prepared_resident_buffer_loads": ExecutorSpec(
        executor_id="doe_node_webgpu_prepared_resident_buffer_loads",
        command_template=_resident_buffer_load_template(
            _DOE_NODE_WEBGPU_PREPARED_TEMPLATE
        ),
        execution_boundary="plan",
    ),
    "doe_node_webgpu_prepared_resident_buffer_loads_vulkan_cache": ExecutorSpec(
        executor_id="doe_node_webgpu_prepared_resident_buffer_loads_vulkan_cache",
        command_template=_vulkan_pipeline_cache_template(
            _resident_buffer_load_template(_DOE_NODE_WEBGPU_PREPARED_TEMPLATE)
        ),
        execution_boundary="plan",
    ),
    "doe_node_native_direct_prepared": ExecutorSpec(
        executor_id="doe_node_native_direct_prepared",
        command_template=_DOE_NODE_NATIVE_DIRECT_PREPARED_TEMPLATE,
        execution_boundary="plan",
    ),
    "doe_node_native_direct_prepared_resident_buffer_loads": ExecutorSpec(
        executor_id="doe_node_native_direct_prepared_resident_buffer_loads",
        command_template=_resident_buffer_load_template(
            _DOE_NODE_NATIVE_DIRECT_PREPARED_TEMPLATE
        ),
        execution_boundary="plan",
    ),
    "bun_webgpu_package": ExecutorSpec(
        executor_id="bun_webgpu_package",
        command_template=(
            "bun bench/executors/run-bun-webgpu-plan.js "
            "--provider bun-webgpu --plan {plan} --trace-jsonl {trace_jsonl} "
            "--trace-meta {trace_meta} --workload {workload}"
        ),
        execution_boundary="plan",
    ),
    "doe_bun_package": ExecutorSpec(
        executor_id="doe_bun_package",
        command_template=(
            "bun bench/executors/run-bun-webgpu-plan.js "
            "--provider doe --plan {plan} --trace-jsonl {trace_jsonl} "
            "--trace-meta {trace_meta} --workload {workload}"
        ),
        execution_boundary="plan",
    ),
    "doe_bun_package_ffi": ExecutorSpec(
        executor_id="doe_bun_package_ffi",
        command_template=(
            "bun bench/executors/run-bun-webgpu-plan.js "
            "--provider doe-ffi --plan {plan} --trace-jsonl {trace_jsonl} "
            "--trace-meta {trace_meta} --workload {workload}"
        ),
        execution_boundary="plan",
    ),
    "deno_webgpu_package": ExecutorSpec(
        executor_id="deno_webgpu_package",
        command_template=(
            "npx --yes deno run --unstable-webgpu --allow-all "
            "bench/executors/run-deno-webgpu-plan.js "
            "--provider deno-webgpu --plan {plan} --trace-jsonl {trace_jsonl} "
            "--trace-meta {trace_meta} --workload {workload}"
        ),
        execution_boundary="plan",
    ),
    "doe_deno_package": ExecutorSpec(
        executor_id="doe_deno_package",
        command_template=(
            "npx --yes deno run --unstable-webgpu --allow-all "
            "bench/executors/run-deno-webgpu-plan.js "
            "--provider doe --plan {plan} --trace-jsonl {trace_jsonl} "
            "--trace-meta {trace_meta} --workload {workload}"
        ),
        execution_boundary="plan",
    ),
    "deno_webgpu_package_prepared": ExecutorSpec(
        executor_id="deno_webgpu_package_prepared",
        command_template=_DENO_WEBGPU_PACKAGE_PREPARED_TEMPLATE,
        execution_boundary="plan",
    ),
    "doe_deno_package_prepared": ExecutorSpec(
        executor_id="doe_deno_package_prepared",
        command_template=_DOE_DENO_PACKAGE_PREPARED_TEMPLATE,
        execution_boundary="plan",
    ),
    "bun_webgpu_package_prepared": ExecutorSpec(
        executor_id="bun_webgpu_package_prepared",
        command_template=_BUN_WEBGPU_PACKAGE_PREPARED_TEMPLATE,
        execution_boundary="plan",
    ),
    "bun_webgpu_package_prepared_resident_buffer_loads": ExecutorSpec(
        executor_id="bun_webgpu_package_prepared_resident_buffer_loads",
        command_template=_resident_buffer_load_template(
            _BUN_WEBGPU_PACKAGE_PREPARED_TEMPLATE
        ),
        execution_boundary="plan",
    ),
    "doe_bun_package_prepared": ExecutorSpec(
        executor_id="doe_bun_package_prepared",
        command_template=_DOE_BUN_PACKAGE_PREPARED_TEMPLATE,
        execution_boundary="plan",
    ),
    "doe_bun_package_ffi_prepared": ExecutorSpec(
        executor_id="doe_bun_package_ffi_prepared",
        command_template=_DOE_BUN_PACKAGE_FFI_PREPARED_TEMPLATE,
        execution_boundary="plan",
    ),
    "doe_bun_package_prepared_resident_buffer_loads": ExecutorSpec(
        executor_id="doe_bun_package_prepared_resident_buffer_loads",
        command_template=_resident_buffer_load_template(
            _DOE_BUN_PACKAGE_PREPARED_TEMPLATE
        ),
        execution_boundary="plan",
    ),
    "doe_bun_package_prepared_resident_buffer_loads_vulkan_cache": ExecutorSpec(
        executor_id="doe_bun_package_prepared_resident_buffer_loads_vulkan_cache",
        command_template=_vulkan_pipeline_cache_template(
            _resident_buffer_load_template(_DOE_BUN_PACKAGE_PREPARED_TEMPLATE)
        ),
        execution_boundary="plan",
    ),
    "doe_bun_package_ffi_prepared_resident_buffer_loads": ExecutorSpec(
        executor_id="doe_bun_package_ffi_prepared_resident_buffer_loads",
        command_template=_resident_buffer_load_template(
            _DOE_BUN_PACKAGE_FFI_PREPARED_TEMPLATE
        ),
        execution_boundary="plan",
    ),
    'tjs_ort_node_doe': ExecutorSpec(
        executor_id='tjs_ort_node_doe',
        command_template=(
            'node bench/executors/run-node-tjs-ort-webgpu.js '
            '--provider doe '
            '--scenario {commands} --trace-jsonl {trace_jsonl} '
            '--trace-meta {trace_meta} --workload {workload}'
        ),
        execution_boundary='commands',
    ),
    'tjs_ort_node_webgpu_package': ExecutorSpec(
        executor_id='tjs_ort_node_webgpu_package',
        command_template=(
            'node bench/executors/run-node-tjs-ort-webgpu.js '
            '--provider node-webgpu '
            '--scenario {commands} --trace-jsonl {trace_jsonl} '
            '--trace-meta {trace_meta} --workload {workload}'
        ),
        execution_boundary='commands',
    ),
    'tjs_ort_bun_doe': ExecutorSpec(
        executor_id='tjs_ort_bun_doe',
        command_template=(
            'bun bench/executors/run-bun-tjs-ort-webgpu.js '
            '--provider doe '
            '--scenario {commands} --trace-jsonl {trace_jsonl} '
            '--trace-meta {trace_meta} --workload {workload}'
        ),
        execution_boundary='commands',
    ),
    'tjs_ort_bun_webgpu_package': ExecutorSpec(
        executor_id='tjs_ort_bun_webgpu_package',
        command_template=(
            'bun bench/executors/run-bun-tjs-ort-webgpu.js '
            '--provider bun-webgpu '
            '--scenario {commands} --trace-jsonl {trace_jsonl} '
            '--trace-meta {trace_meta} --workload {workload}'
        ),
        execution_boundary='commands',
    ),
    "browser_ort_webgpu_dawn": ExecutorSpec(
        executor_id="browser_ort_webgpu_dawn",
        command_template=(
            "python3 bench/executors/run-browser-ort-bench.py "
            "--mode dawn --scenario {commands} --trace-jsonl {trace_jsonl} "
            "--trace-meta {trace_meta} --workload {workload}"
        ),
        execution_boundary="commands",
    ),
    "browser_ort_webgpu_doe": ExecutorSpec(
        executor_id="browser_ort_webgpu_doe",
        command_template=(
            "python3 bench/executors/run-browser-ort-bench.py "
            "--mode doe --scenario {commands} --trace-jsonl {trace_jsonl} "
            "--trace-meta {trace_meta} --workload {workload}"
        ),
        execution_boundary="commands",
    ),
    'doppler_node_doe': ExecutorSpec(
        executor_id='doppler_node_doe',
        command_template=(
            'node bench/executors/run-node-doppler-ort-bench.js '
            '--scenario {commands} --trace-jsonl {trace_jsonl} '
            '--trace-meta {trace_meta} --workload {workload}'
        ),
        execution_boundary='commands',
    ),
}


def resolve_executor_command_template(executor_id: str) -> str:
    normalized = executor_id.strip()
    if not normalized:
        return ""
    try:
        return _REGISTRY[normalized].command_template
    except KeyError as exc:
        known = ", ".join(sorted(_REGISTRY))
        raise ValueError(
            f"unknown executor id {executor_id!r}; expected one of [{known}]"
        ) from exc


def resolve_executor_boundary(executor_id: str) -> str:
    normalized = executor_id.strip()
    if not normalized:
        return ""
    try:
        return _REGISTRY[normalized].execution_boundary
    except KeyError as exc:
        known = ", ".join(sorted(_REGISTRY))
        raise ValueError(
            f"unknown executor id {executor_id!r}; expected one of [{known}]"
        ) from exc
