const std = @import("std");
const backend_policy = @import("../../src/backend/backend_policy.zig");
const webgpu = @import("../../src/compat/webgpu_ffi.zig");
const native_runtime = @import("../../src/backend/vulkan/native_runtime.zig");
const compute_program = @import("../../src/backend/vulkan/vk_compute_program.zig");
const resources = @import("../../src/backend/vulkan/vk_resources.zig");
const shared = @import("../../src/backend/vulkan/vk_shared_pipeline.zig");
const compiler = @import("../../src/compiler/wgsl/mod.zig");
const compute = @import("../../src/contracts/model/model_compute_types.zig");
const binding_types = @import("../../src/contracts/model/model_binding_value_types.zig");
const vk = @import("../../src/backend/vulkan/vk_constants.zig");

const REUSE_SHADER =
    \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
    \\@compute @workgroup_size(1) fn main(@builtin(global_invocation_id) id: vec3u) {
    \\    if (id.x < arrayLength(&data)) { data[id.x] = data[id.x] + id.x + 7u; }
    \\}
;
const REUSE_BUFFER_BYTES = 4 * @sizeOf(u32);
const DEVICE_LOCAL_FAILURE_BYTES = 64 * 1024;

test "Vulkan buffer publication failure cannot leave an unowned initialization command" {
    var rt = native_runtime.NativeVulkanRuntime.init(std.testing.allocator, null) catch |err| switch (err) {
        error.UnsupportedFeature => return error.SkipZigTest,
        else => return err,
    };
    defer rt.deinit();
    const binding = compute.KernelBinding{
        .binding = 0,
        .resource_kind = .buffer,
        .resource_handle = 301,
        .buffer_size = DEVICE_LOCAL_FAILURE_BYTES,
        .buffer_type = binding_types.WGPUBufferBindingType_Storage,
    };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    rt.allocator = failing.allocator();
    defer rt.allocator = std.testing.allocator;
    try std.testing.expectError(error.OutOfMemory, resources.ensure_compute_buffer_for_binding(&rt, binding, true));
    try std.testing.expectEqual(@as(usize, 0), rt.compute_buffers.count());
    try std.testing.expect(!rt.streaming_copy_active);

    rt.allocator = std.testing.allocator;
    const created = try resources.ensure_compute_buffer_for_binding(&rt, binding, true);
    try std.testing.expectEqual(resources.ComputeBufferMemoryKind.device_local, created.buffer.memory_kind);
    _ = try rt.flush_queue();
    const initialized = try resources.capture_compute_buffer(&rt, std.testing.allocator, created.buffer, 0, REUSE_BUFFER_BYTES);
    defer std.testing.allocator.free(initialized);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** REUSE_BUFFER_BYTES), initialized);
    const replacement = try resources.ensure_compute_buffer(&rt, binding.resource_handle, DEVICE_LOCAL_FAILURE_BYTES * 2, true);
    try std.testing.expect(replacement.buffer != created.buffer.buffer);
    try std.testing.expectEqual(replacement.buffer, rt.compute_buffers.get(binding.resource_handle).?.buffer);
    _ = try rt.flush_queue();
    const resized = try resources.capture_compute_buffer(&rt, std.testing.allocator, replacement, 0, REUSE_BUFFER_BYTES);
    defer std.testing.allocator.free(resized);
    try std.testing.expectEqualSlices(u8, initialized, resized);
}

fn prepare_reuse_program(rt: *native_runtime.NativeVulkanRuntime, words: []const u32, bindings: []const compute.KernelBinding, workgroups: u32) !compute_program.ComputeProgram {
    for (bindings) |binding| _ = try resources.ensure_compute_buffer_for_binding(rt, binding, true);
    var program = compute_program.ComputeProgram{};
    errdefer program.deinit(rt);
    try program.begin(rt);
    try rt.set_compute_shader_spirv(words, "main", bindings, true);
    try rt.record_prepared_dispatch_replay_on(program.command_buffer, workgroups, 1, 1);
    try program.finish(rt);
    return program;
}

fn expect_reuse_output(rt: *native_runtime.NativeVulkanRuntime, id: u64, expected: []const u32) !void {
    _ = try rt.flush_queue();
    const bytes = try resources.capture_compute_buffer(rt, std.testing.allocator, rt.compute_buffers.get(id).?, 0, REUSE_BUFFER_BYTES);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expected), bytes);
}

fn acquire_with_allocation_failures(allocator: std.mem.Allocator, rt: *native_runtime.NativeVulkanRuntime, layouts: []const vk.VkDescriptorSetLayout, request: shared.Request) !void {
    var registry = shared.Registry{};
    defer registry.deinit(allocator);
    const entry = try registry.acquire(allocator, rt.device, 0, layouts, request, false);
    registry.release(allocator, rt.device, entry);
    try std.testing.expectEqual(@as(usize, 0), registry.entries.items.len);
}

test "Vulkan prepared programs share live pipelines and keep private descriptors after creator teardown" {
    var rt = native_runtime.NativeVulkanRuntime.init(std.testing.allocator, null) catch |err| switch (err) {
        error.UnsupportedFeature => return error.SkipZigTest,
        else => return err,
    };
    defer rt.deinit();
    var output: [compiler.MAX_SPIRV_OUTPUT]u8 align(@alignOf(u32)) = undefined;
    const length = try compiler.translateToSpirv(std.testing.allocator, REUSE_SHADER, &output);
    const words = std.mem.bytesAsSlice(u32, output[0..length]);
    var bindings = [_]compute.KernelBinding{.{ .binding = 0, .resource_kind = .buffer, .resource_handle = 101, .buffer_size = REUSE_BUFFER_BYTES, .buffer_type = binding_types.WGPUBufferBindingType_Storage }};
    var first = try prepare_reuse_program(&rt, words, &bindings, 2);
    defer first.deinit(&rt);
    bindings[0].resource_handle = 102;
    var second = try prepare_reuse_program(&rt, words, &bindings, 4);
    defer second.deinit(&rt);
    const first_pipeline = first.owned.active.shared_pipeline.?;
    const second_pipeline = second.owned.active.shared_pipeline.?;
    const share = @import("build_options").vulkan_share_live_compute_pipelines;
    try std.testing.expectEqual(share, first_pipeline == second_pipeline);
    try std.testing.expectEqual(share, first_pipeline.handle == second_pipeline.handle);
    try std.testing.expect(first.owned.active.descriptor_pool != second.owned.active.descriptor_pool);
    try std.testing.expect(first.owned.active.pipeline_layout != second.owned.active.pipeline_layout);
    try std.testing.expect(first.owned.active.pipeline_layout != second_pipeline.creation_layout);

    var request = shared.Request{ .words = words, .entry_point = "main", .bindings = &bindings, .required_subgroup_size = second_pipeline.required_subgroup_size };
    try std.testing.expect(try second_pipeline.matches(request));
    request.entry_point = "another_entry";
    try std.testing.expect(!try second_pipeline.matches(request));
    request.entry_point = "main";
    request.required_subgroup_size = if (request.required_subgroup_size == null) 32 else null;
    try std.testing.expect(!try second_pipeline.matches(request));
    request.required_subgroup_size = second_pipeline.required_subgroup_size;
    bindings[0].buffer_type = binding_types.WGPUBufferBindingType_Uniform;
    try std.testing.expect(!try second_pipeline.matches(request));
    bindings[0].buffer_type = binding_types.WGPUBufferBindingType_Storage;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, acquire_with_allocation_failures, .{ &rt, second.owned.active.descriptor_set_layouts[0..second.owned.active.descriptor_set_count], request });

    try first.submit(&rt);
    try expect_reuse_output(&rt, 101, &.{ 7, 8, 0, 0 });
    first.deinit(&rt);
    try std.testing.expectEqual(@as(usize, 1), second_pipeline.references);
    try second.submit(&rt);
    try expect_reuse_output(&rt, 102, &.{ 7, 8, 9, 10 });

    var failed = compute_program.ComputeProgram{};
    try failed.begin(&rt);
    try std.testing.expectError(error.InvalidArgument, rt.set_compute_shader_spirv(words, "missing_entry", &bindings, false));
    failed.deinit(&rt);
    try std.testing.expectEqual(@as(usize, 1), second_pipeline.references);
    try second.submit(&rt);
    try expect_reuse_output(&rt, 102, &.{ 14, 16, 18, 20 });

    var extended_bindings = [_]compute.KernelBinding{
        bindings[0],
        .{ .binding = 1, .resource_kind = .buffer, .resource_handle = 103, .buffer_size = REUSE_BUFFER_BYTES, .buffer_type = binding_types.WGPUBufferBindingType_Uniform },
    };
    var extended = try prepare_reuse_program(&rt, words, &extended_bindings, 4);
    defer extended.deinit(&rt);
    try std.testing.expect(extended.owned.active.shared_pipeline.? != second_pipeline);
    extended.deinit(&rt);

    var changed_output: [compiler.MAX_SPIRV_OUTPUT]u8 align(@alignOf(u32)) = undefined;
    const changed_source = try std.mem.replaceOwned(u8, std.testing.allocator, REUSE_SHADER, "7u", "11u");
    defer std.testing.allocator.free(changed_source);
    const changed_length = try compiler.translateToSpirv(std.testing.allocator, changed_source, &changed_output);
    const changed_words = std.mem.bytesAsSlice(u32, changed_output[0..changed_length]);
    var changed = try prepare_reuse_program(&rt, changed_words, &bindings, 4);
    defer changed.deinit(&rt);
    try std.testing.expect(changed.owned.active.shared_pipeline.? != second_pipeline);
    try changed.submit(&rt);
    try expect_reuse_output(&rt, 102, &.{ 25, 28, 31, 34 });
    changed.deinit(&rt);
    try second.submit(&rt);
    try expect_reuse_output(&rt, 102, &.{ 32, 36, 40, 44 });

    var other_device = try native_runtime.NativeVulkanRuntime.init(std.testing.allocator, null);
    defer other_device.deinit();
    var foreign = try prepare_reuse_program(&other_device, words, &bindings, 4);
    defer foreign.deinit(&other_device);
    try std.testing.expect(foreign.owned.active.shared_pipeline.? != second_pipeline);
    try foreign.submit(&other_device);
    try expect_reuse_output(&other_device, 102, &.{ 7, 8, 9, 10 });

    second.deinit(&rt);
    try std.testing.expectEqual(@as(usize, 0), rt.shared_pipelines.entries.items.len);
}

test "vulkan mapped fast upload path stays bounded when shortcuts are allowed" {
    try std.testing.expect(native_runtime.upload_uses_fast_path(.allow_mapped_shortcuts, .copy_dst, 1024));
    try std.testing.expect(native_runtime.upload_uses_fast_path(.allow_mapped_shortcuts, .copy_dst, 1024 * 1024));
    try std.testing.expect(!native_runtime.upload_uses_fast_path(.allow_mapped_shortcuts, .copy_dst, 1024 * 1024 + 1));
    try std.testing.expect(!native_runtime.upload_uses_fast_path(.allow_mapped_shortcuts, .copy_dst_copy_src, 1024));
    try std.testing.expect(!native_runtime.upload_uses_fast_path(.allow_mapped_shortcuts, webgpu.UploadBufferUsageMode.copy_dst_copy_src, 1024 * 1024));
}

test "vulkan large copy-dst uploads use direct mapped path when shortcuts are allowed" {
    try std.testing.expect(native_runtime.upload_uses_direct_path(.allow_mapped_shortcuts, .copy_dst, 1024 * 1024 + 1));
    try std.testing.expect(native_runtime.upload_uses_direct_path(.allow_mapped_shortcuts, .copy_dst, 1024 * 1024 * 1024));
    try std.testing.expect(native_runtime.upload_uses_direct_path(.allow_mapped_shortcuts, .copy_dst, 4 * 1024 * 1024 * 1024));
    try std.testing.expect(!native_runtime.upload_uses_direct_path(.allow_mapped_shortcuts, .copy_dst, 1024 * 1024));
    try std.testing.expect(!native_runtime.upload_uses_direct_path(.allow_mapped_shortcuts, .copy_dst_copy_src, 4 * 1024 * 1024));
}

test "strict Vulkan upload policy allows fast_mapped for small, forces staged for large" {
    const strict_policy = backend_policy.UploadPathPolicy.staged_copy_only;
    // Small host-visible buffers use fast_mapped (direct memcpy) to match
    // Dawn's WriteBuffer behavior (CLAUDE.md rules 7/10/11).
    try std.testing.expect(native_runtime.upload_uses_fast_path(strict_policy, .copy_dst, 1024));
    // Large buffers still use staged copy under strict policy.
    try std.testing.expect(!native_runtime.upload_uses_direct_path(strict_policy, .copy_dst, 1024 * 1024 + 1));
    try std.testing.expect(!native_runtime.upload_uses_direct_path(strict_policy, .copy_dst, 4 * 1024 * 1024 * 1024));
    try std.testing.expect(!native_runtime.upload_uses_direct_path(strict_policy, .copy_dst_copy_src, 4 * 1024 * 1024));
}
