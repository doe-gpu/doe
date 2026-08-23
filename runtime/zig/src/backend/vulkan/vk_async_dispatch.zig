// Async diagnostics dispatch for the Vulkan backend.
//
// Sharded from mod.zig to keep the main backend file under the line budget.
// Handles all AsyncDiagnosticsMode variants including strict-mode probes
// for resource_table_immediates and pixel_local_storage.

const std = @import("std");
const model_gpu_types = @import("../../contracts/model/model_texture_value_types.zig");
const model_async_types = @import("../../contracts/model/model_async_types.zig");
const webgpu = @import("../../contracts/runtime_types.zig");
const backend_policy = @import("../backend_policy.zig");
const common_timing = @import("../common/timing.zig");

const PIPELINE_STRESS_KERNEL = "shader_compile_pipeline_stress.spv";

pub fn execute(
    runtime: anytype,
    allocator: std.mem.Allocator,
    setup_ns: u64,
    diagnostics: model_async_types.AsyncDiagnosticsCommand,
    upload_path_policy: backend_policy.UploadPathPolicy,
) !webgpu.NativeExecutionResult {
    const iterations = if (diagnostics.iterations > 0) diagnostics.iterations else 1;

    switch (diagnostics.mode) {
        .capability_introspection => {
            const encode_start = common_timing.now_ns();
            _ = runtime.adapter_ordinal_value;
            _ = runtime.queue_family_index_value_cache;
            _ = runtime.present_capable_value;
            const encode_ns = common_timing.ns_delta(common_timing.now_ns(), encode_start);
            return ok_result(setup_ns, encode_ns, 0, iterations);
        },
        .lifecycle_refcount => {
            const encode_ns = try runtime.lifecycle_probe(iterations);
            return ok_result(setup_ns, encode_ns, 0, iterations);
        },
        .pipeline_async => {
            const encode_ns = try runtime.pipeline_async_probe(allocator, PIPELINE_STRESS_KERNEL, iterations);
            return ok_result(setup_ns, encode_ns, 0, iterations);
        },
        .resource_table_immediates => return execute_resource_table_immediates(
            runtime,
            setup_ns,
            iterations,
            diagnostics.feature_policy,
            upload_path_policy,
        ),
        .pixel_local_storage => return execute_pixel_local_storage(
            runtime,
            setup_ns,
            iterations,
            diagnostics.feature_policy,
            diagnostics.target_format,
            upload_path_policy,
        ),
        .full => return execute_full(
            runtime,
            allocator,
            setup_ns,
            iterations,
            diagnostics.feature_policy,
            diagnostics.target_format,
            upload_path_policy,
        ),
    }
}

fn execute_resource_table_immediates(
    runtime: anytype,
    setup_ns: u64,
    iterations: u32,
    feature_policy: model_async_types.AsyncDiagnosticsFeaturePolicy,
    upload_path_policy: backend_policy.UploadPathPolicy,
) !webgpu.NativeExecutionResult {
    switch (feature_policy) {
        .strict => {
            const probe = try runtime.resource_table_immediates_probe(iterations);
            return ok_result(
                setup_ns +| probe.setup_ns,
                probe.encode_ns,
                probe.submit_wait_ns,
                iterations,
            );
        },
        .emulate_when_unavailable => {
            const encode_ns = try runtime.resource_table_immediates_emulation_probe(iterations, upload_path_policy);
            return ok_result(setup_ns, encode_ns, 0, iterations);
        },
    }
}

fn execute_pixel_local_storage(
    runtime: anytype,
    setup_ns: u64,
    iterations: u32,
    feature_policy: model_async_types.AsyncDiagnosticsFeaturePolicy,
    target_format: model_gpu_types.WGPUTextureFormat,
    upload_path_policy: backend_policy.UploadPathPolicy,
) !webgpu.NativeExecutionResult {
    switch (feature_policy) {
        .strict => {
            const probe = try runtime.pixel_local_storage_probe(iterations, target_format);
            return ok_result(
                setup_ns +| probe.setup_ns,
                probe.encode_ns,
                probe.submit_wait_ns,
                iterations,
            );
        },
        .emulate_when_unavailable => {
            const encode_ns = try runtime.pixel_local_storage_emulation_probe(iterations, upload_path_policy);
            return ok_result(setup_ns, encode_ns, 0, iterations);
        },
    }
}

fn execute_full(
    runtime: anytype,
    allocator: std.mem.Allocator,
    setup_ns: u64,
    iterations: u32,
    feature_policy: model_async_types.AsyncDiagnosticsFeaturePolicy,
    target_format: model_gpu_types.WGPUTextureFormat,
    upload_path_policy: backend_policy.UploadPathPolicy,
) !webgpu.NativeExecutionResult {
    const capability_ns = blk: {
        const encode_start = common_timing.now_ns();
        _ = runtime.adapter_ordinal_value;
        _ = runtime.queue_family_index_value_cache;
        _ = runtime.present_capable_value;
        break :blk common_timing.ns_delta(common_timing.now_ns(), encode_start);
    };
    var total_setup_ns = setup_ns;
    var encode_ns = capability_ns;
    var submit_wait_ns: u64 = 0;

    encode_ns +|= try runtime.pipeline_async_probe(allocator, PIPELINE_STRESS_KERNEL, iterations);
    encode_ns +|= try runtime.lifecycle_probe(iterations);

    switch (feature_policy) {
        .strict => {
            const rti = try runtime.resource_table_immediates_probe(iterations);
            total_setup_ns +|= rti.setup_ns;
            encode_ns +|= rti.encode_ns;
            submit_wait_ns +|= rti.submit_wait_ns;

            const pls = try runtime.pixel_local_storage_probe(iterations, target_format);
            total_setup_ns +|= pls.setup_ns;
            encode_ns +|= pls.encode_ns;
            submit_wait_ns +|= pls.submit_wait_ns;
        },
        .emulate_when_unavailable => {
            encode_ns +|= try runtime.resource_table_immediates_emulation_probe(iterations, upload_path_policy);
            encode_ns +|= try runtime.pixel_local_storage_emulation_probe(iterations, upload_path_policy);
        },
    }
    return ok_result(total_setup_ns, encode_ns, submit_wait_ns, iterations);
}

fn ok_result(setup_ns: u64, encode_ns: u64, submit_wait_ns_arg: u64, dispatch_count: u32) webgpu.NativeExecutionResult {
    return .{
        .status = .ok,
        .status_message = "",
        .setup_ns = setup_ns,
        .encode_ns = encode_ns,
        .submit_wait_ns = submit_wait_ns_arg,
        .dispatch_count = dispatch_count,
        .gpu_timestamp_ns = 0,
        .gpu_timestamp_attempted = false,
        .gpu_timestamp_valid = false,
    };
}
