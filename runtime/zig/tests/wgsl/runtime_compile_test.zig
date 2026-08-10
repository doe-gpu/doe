const std = @import("std");
const runtime_compile = @import("../../src/compiler/wgsl/runtime/runtime_compile.zig");
const ir = @import("../../src/compiler/wgsl/ir/ir.zig");
const lean_proof = @import("../../src/verification/lean_proof.zig");
const emit_msl = @import("../../src/compiler/wgsl/emit/msl/emit_msl.zig");
const emit_spirv = @import("../../src/compiler/wgsl/emit/spirv/emit_spirv.zig");

const translateToMslForComputeRuntimeTimed = runtime_compile.translateToMslForComputeRuntimeTimed;
const translateToSpirvForVulkanComputeRuntime = runtime_compile.translateToSpirvForVulkanComputeRuntime;

test "timed compute runtime translation reports compiler phases" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = data[id.x] * 2.0;
        \\}
    ;
    var out: [emit_msl.MAX_OUTPUT]u8 = undefined;
    var result = try translateToMslForComputeRuntimeTimed(
        std.testing.allocator,
        source,
        &out,
        null,
        0,
    );
    defer result.info.deinit(std.testing.allocator);

    try std.testing.expect(result.len > 0);
    try std.testing.expect(result.phase_timings_ns.parse > 0);
    try std.testing.expect(result.phase_timings_ns.sema > 0);
    try std.testing.expect(result.phase_timings_ns.lower > 0);
    try std.testing.expect(result.phase_timings_ns.emit > 0);
    try std.testing.expect(result.phase_timings_ns.total >= result.phase_timings_ns.parse);
    try std.testing.expect(result.phase_timings_ns.total >= result.phase_timings_ns.emit);
}

test "compute runtime elides workgroup id storage clamp with dispatch precondition" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(workgroup_id) wid: vec3u) {
        \\    data[wid.x] = 1.0;
        \\}
    ;
    var out: [emit_msl.MAX_OUTPUT]u8 = undefined;
    var result = try translateToMslForComputeRuntimeTimed(
        std.testing.allocator,
        source,
        &out,
        null,
        0,
    );
    defer result.info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.info.dispatch_preconditions.len);
    const precondition = result.info.dispatch_preconditions[0];
    try std.testing.expectEqual(ir.DispatchPreconditionKind.workgroup_component, precondition.kind);
    try std.testing.expectEqual(@as(u8, 0), precondition.gid_axis);
    const msl = out[0..result.len];
    try std.testing.expect(std.mem.indexOf(u8, msl, "_doe_sizes") == null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "min(") == null);
}

test "compute runtime elides global id storage clamp with dispatch precondition" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = 1.0;
        \\}
    ;
    var out: [emit_msl.MAX_OUTPUT]u8 = undefined;
    var result = try translateToMslForComputeRuntimeTimed(
        std.testing.allocator,
        source,
        &out,
        null,
        0,
    );
    defer result.info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.info.dispatch_preconditions.len);
    const precondition = result.info.dispatch_preconditions[0];
    try std.testing.expectEqual(ir.DispatchPreconditionKind.gid_component, precondition.kind);
    try std.testing.expectEqual(@as(u8, 0), precondition.gid_axis);
    const msl = out[0..result.len];
    try std.testing.expect(std.mem.indexOf(u8, msl, "_doe_sizes") == null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "min(") == null);
}

test "compute runtime elides local invocation loop storage clamp with dispatch precondition" {
    const source =
        \\const K_WORKGROUP_SIZE: u32 = 256u;
        \\const K_WORKGROUP_ARRAY_SIZE: u32 = 2048u;
        \\const K_LOOP_LENGTH: u32 = K_WORKGROUP_ARRAY_SIZE / K_WORKGROUP_SIZE;
        \\@group(0) @binding(0) var<storage, read_write> dst: array<f32>;
        \\var<workgroup> wg: array<f32, K_WORKGROUP_ARRAY_SIZE>;
        \\@compute @workgroup_size(K_WORKGROUP_SIZE, 1, 1)
        \\fn main(@builtin(local_invocation_id) local_id: vec3u) {
        \\    for (var k: u32 = 0u; k < K_LOOP_LENGTH; k = k + 1u) {
        \\        let index: u32 = K_LOOP_LENGTH * local_id.x + k;
        \\        dst[index] = wg[index];
        \\    }
        \\}
    ;
    var out: [emit_msl.MAX_OUTPUT]u8 = undefined;
    var result = try translateToMslForComputeRuntimeTimed(
        std.testing.allocator,
        source,
        &out,
        null,
        0,
    );
    defer result.info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.info.dispatch_preconditions.len);
    const precondition = result.info.dispatch_preconditions[0];
    try std.testing.expectEqual(ir.DispatchPreconditionKind.local_invocation_component, precondition.kind);
    try std.testing.expectEqual(@as(u8, 0), precondition.gid_axis);
    try std.testing.expectEqual(@as(u64, 8), precondition.element_multiplier);
    try std.testing.expectEqual(@as(u64, 8), precondition.loop_limit);
    try std.testing.expectEqual(@as(u64, 1), precondition.loop_limit_multiplier);
    try std.testing.expect(!result.info.needs_sizes_buf);
    const msl = out[0..result.len];
    try std.testing.expect(std.mem.indexOf(u8, msl, "_doe_sizes") == null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "min(") == null);
}

test "compute runtime emits zero for unwritten workgroup reads" {
    const source =
        \\const K_WORKGROUP_SIZE: u32 = 256u;
        \\const K_WORKGROUP_ARRAY_SIZE: u32 = 2048u;
        \\const K_LOOP_LENGTH: u32 = K_WORKGROUP_ARRAY_SIZE / K_WORKGROUP_SIZE;
        \\@group(0) @binding(0) var<storage, read_write> dst: array<f32>;
        \\var<workgroup> wg: array<f32, K_WORKGROUP_ARRAY_SIZE>;
        \\@compute @workgroup_size(K_WORKGROUP_SIZE, 1, 1)
        \\fn main(@builtin(local_invocation_id) local_id: vec3u) {
        \\    for (var k: u32 = 0u; k < K_LOOP_LENGTH; k = k + 1u) {
        \\        let index: u32 = K_LOOP_LENGTH * local_id.x + k;
        \\        dst[index] = wg[index];
        \\    }
        \\}
    ;
    var out: [emit_msl.MAX_OUTPUT]u8 = undefined;
    var result = try translateToMslForComputeRuntimeTimed(
        std.testing.allocator,
        source,
        &out,
        null,
        0,
    );
    defer result.info.deinit(std.testing.allocator);

    try std.testing.expect(!result.info.needs_sizes_buf);
    const msl = out[0..result.len];
    try std.testing.expect(std.mem.indexOf(u8, msl, "threadgroup float wg") == null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "wg[") == null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "= 0.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "_doe_sizes") == null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "min(") == null);
}

test "compute runtime preserves written workgroup storage" {
    const source =
        \\const K_WORKGROUP_SIZE: u32 = 256u;
        \\const K_WORKGROUP_ARRAY_SIZE: u32 = 2048u;
        \\const K_LOOP_LENGTH: u32 = K_WORKGROUP_ARRAY_SIZE / K_WORKGROUP_SIZE;
        \\@group(0) @binding(0) var<storage, read_write> dst: array<f32>;
        \\var<workgroup> wg: array<f32, K_WORKGROUP_ARRAY_SIZE>;
        \\@compute @workgroup_size(K_WORKGROUP_SIZE, 1, 1)
        \\fn main(@builtin(local_invocation_id) local_id: vec3u) {
        \\    for (var k: u32 = 0u; k < K_LOOP_LENGTH; k = k + 1u) {
        \\        let index: u32 = K_LOOP_LENGTH * local_id.x + k;
        \\        wg[index] = f32(index);
        \\        dst[index] = wg[index];
        \\    }
        \\}
    ;
    var out: [emit_msl.MAX_OUTPUT]u8 = undefined;
    var result = try translateToMslForComputeRuntimeTimed(
        std.testing.allocator,
        source,
        &out,
        null,
        0,
    );
    defer result.info.deinit(std.testing.allocator);

    const msl = out[0..result.len];
    try std.testing.expect(std.mem.indexOf(u8, msl, "threadgroup float wg") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "wg[") != null);
}

test "compute runtime lowers single invocation scalar workgroup storage to thread local" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data : array<u32, 1>;
        \\var<workgroup> wg_data : u32;
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    wg_data = data[0];
        \\    workgroupBarrier();
        \\    data[0] = wg_data;
        \\}
    ;
    var out: [emit_msl.MAX_OUTPUT]u8 = undefined;
    var result = try translateToMslForComputeRuntimeTimed(
        std.testing.allocator,
        source,
        &out,
        null,
        0,
    );
    defer result.info.deinit(std.testing.allocator);

    const msl = out[0..result.len];
    try std.testing.expect(std.mem.indexOf(u8, msl, "threadgroup uint wg_data") == null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "uint wg_data;") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "threadgroup_barrier") == null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "(void)0") != null);
}

test "compute runtime preserves single invocation workgroup arrays" {
    const source =
        \\const kBufferSize : u32 = 1024u;
        \\@group(0) @binding(0) var<storage, read_write> data : array<u32, kBufferSize>;
        \\var<workgroup> wg_data : array<u32, kBufferSize>;
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    for (var i : u32 = 0u; i < kBufferSize; i = i + 1u) {
        \\        wg_data[i] = data[i];
        \\    }
        \\    data[0] = wg_data[0];
        \\}
    ;
    var out: [emit_msl.MAX_OUTPUT]u8 = undefined;
    var result = try translateToMslForComputeRuntimeTimed(
        std.testing.allocator,
        source,
        &out,
        null,
        0,
    );
    defer result.info.deinit(std.testing.allocator);

    const msl = out[0..result.len];
    try std.testing.expect(std.mem.indexOf(u8, msl, "threadgroup uint wg_data[1024];") != null);
}

test "compute runtime elides bitmasked workgroup array clamp" {
    const source =
        \\const kBufferSize : u32 = 1024u;
        \\const kBufferMask : u32 = kBufferSize - 1u;
        \\@group(0) @binding(0) var<storage, read_write> inout_data : array<u32, kBufferSize>;
        \\var<workgroup> wg_data : array<u32, kBufferSize>;
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    var accum : u32 = inout_data[0];
        \\    for (var i : u32 = 0u; i < kBufferSize; i = i + 1u) {
        \\        wg_data[i] = inout_data[i];
        \\    }
        \\    for (var i : u32 = 0u; i < 1000000u; i = i + 1u) {
        \\        let idx = (i + accum) & kBufferMask;
        \\        accum = (accum ^ wg_data[idx]) + 123u;
        \\    }
        \\    inout_data[0] = accum;
        \\}
    ;
    var out: [emit_msl.MAX_OUTPUT]u8 = undefined;
    var result = try translateToMslForComputeRuntimeTimed(
        std.testing.allocator,
        source,
        &out,
        null,
        0,
    );
    defer result.info.deinit(std.testing.allocator);

    const msl = out[0..result.len];
    try std.testing.expect(std.mem.indexOf(u8, msl, "threadgroup uint wg_data[1024];") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "wg_data[min(") == null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "wg_data[idx]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "inout_data[min(") == null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "inout_data[i]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "inout_data[uint(0)]") != null or
        std.mem.indexOf(u8, msl, "inout_data[0]") != null);
}

test "vulkan compute runtime elides global id storage clamp with dispatch precondition" {
    const source =
        \\@group(0) @binding(0) var<storage, read> input_values: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> output_values: array<f32>;
        \\@compute @workgroup_size(256)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    output_values[id.x] = input_values[id.x] * 2.0;
        \\}
    ;
    var out: [emit_spirv.MAX_OUTPUT]u8 = undefined;
    var result = try translateToSpirvForVulkanComputeRuntime(
        std.testing.allocator,
        source,
        &out,
    );
    defer result.info.deinit(std.testing.allocator);

    var gid_preconditions: usize = 0;
    for (result.info.dispatch_preconditions) |precondition| {
        if (precondition.kind != .gid_component) continue;
        try std.testing.expectEqual(@as(u8, 0), precondition.gid_axis);
        gid_preconditions += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), gid_preconditions);
}

test "vulkan compute runtime elides uniform product guarded storage clamp" {
    const source =
        \\struct Dims {
        \\    M: u32,
        \\    K: u32,
        \\    N: u32,
        \\    _pad: u32,
        \\}
        \\@group(0) @binding(2) var<storage, read_write> c: array<f32>;
        \\@group(0) @binding(3) var<uniform> dims: Dims;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(workgroup_id) wid: vec3u) {
        \\    let row = wid.y * 16u;
        \\    let col = wid.x * 16u;
        \\    if (row + 1u < dims.M && col + 1u < dims.N) {
        \\        c[((row + 1u) * dims.N + col) + 1u] = 1.0;
        \\    }
        \\}
    ;
    var out: [emit_spirv.MAX_OUTPUT]u8 = undefined;
    var result = try translateToSpirvForVulkanComputeRuntime(
        std.testing.allocator,
        source,
        &out,
    );
    defer result.info.deinit(std.testing.allocator);

    var saw_c_extent = false;
    for (result.info.dispatch_preconditions) |precondition| {
        if (precondition.kind != .uniform_extent) continue;
        if (precondition.storage_binding.binding != 2) continue;
        try std.testing.expectEqual(@as(u32, 3), precondition.uniform_binding.binding);
        try std.testing.expectEqual(@as(u32, 0), precondition.uniform_u32_offsets[0]);
        try std.testing.expectEqual(@as(u32, 8), precondition.uniform_u32_offsets[1]);
        try std.testing.expectEqual(@as(u8, 2), precondition.uniform_u32_count);
        saw_c_extent = true;
    }
    try std.testing.expect(saw_c_extent);
}

test "compute runtime elides uniform guarded GEMV storage clamps" {
    const source =
        \\struct Uniforms {
        \\    rows: u32,
        \\    cols: u32,
        \\    _pad0: u32,
        \\    _pad1: u32,
        \\}
        \\@group(0) @binding(0) var<uniform> u: Uniforms;
        \\@group(0) @binding(1) var<storage, read> matrix: array<f32>;
        \\@group(0) @binding(2) var<storage, read> vector: array<f32>;
        \\@group(0) @binding(3) var<storage, read_write> output: array<f32>;
        \\var<workgroup> partial_sums: array<f32, 64>;
        \\fn partial(row: u32, lane: u32) -> f32 {
        \\    let base = row * u.cols;
        \\    let vec_cols = u.cols & ~3u;
        \\    var c = lane * 4u;
        \\    var acc = 0.0;
        \\    loop {
        \\        if (c >= vec_cols) { break; }
        \\        acc = acc + matrix[base + c] + matrix[base + c + 1u] + vector[c + 2u] + vector[c + 3u];
        \\        c = c + 256u;
        \\    }
        \\    c = vec_cols + lane;
        \\    loop {
        \\        if (c >= u.cols) { break; }
        \\        acc = acc + matrix[base + c] * vector[c];
        \\        c = c + 64u;
        \\    }
        \\    return acc;
        \\}
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(workgroup_id) wid: vec3u, @builtin(local_invocation_id) lid: vec3u) {
        \\    let row = wid.x;
        \\    if (row >= u.rows) { return; }
        \\    let lane = lid.x;
        \\    partial_sums[lane] = partial(row, lane);
        \\    workgroupBarrier();
        \\    if (lane == 0u) { output[row] = partial_sums[0]; }
        \\}
    ;
    var out: [emit_msl.MAX_OUTPUT]u8 = undefined;
    var result = try translateToMslForComputeRuntimeTimed(
        std.testing.allocator,
        source,
        &out,
        null,
        0,
    );
    defer result.info.deinit(std.testing.allocator);

    var saw_uniform_extent = false;
    for (result.info.dispatch_preconditions) |precondition| {
        if (precondition.kind == .uniform_extent) saw_uniform_extent = true;
    }
    try std.testing.expect(saw_uniform_extent);
    const msl = out[0..result.len];
    try std.testing.expect(!result.info.needs_sizes_buf);
    try std.testing.expect(std.mem.indexOf(u8, msl, "_doe_sizes") == null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "min(") == null);
}

test "compute runtime elides uniform guarded gid storage clamps" {
    const source =
        \\struct Params {
        \\    count: u32,
        \\    _pad0: u32,
        \\    _pad1: u32,
        \\    _pad2: u32,
        \\}
        \\@group(0) @binding(0) var<uniform> params: Params;
        \\@group(0) @binding(1) var<storage, read> input_values: array<f32>;
        \\@group(0) @binding(2) var<storage, read_write> output_values: array<f32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    let index = gid.x;
        \\    if (index >= params.count) { return; }
        \\    output_values[index] = (input_values[index] * 1.5) + 0.25;
        \\}
    ;
    var out: [emit_msl.MAX_OUTPUT]u8 = undefined;
    var result = try translateToMslForComputeRuntimeTimed(
        std.testing.allocator,
        source,
        &out,
        null,
        0,
    );
    defer result.info.deinit(std.testing.allocator);

    const proof_backed = lean_proof.boundsProven(.gid_1d_storage_buffer);
    var precondition_count: usize = 0;
    var saw_input = false;
    var saw_output = false;
    for (result.info.dispatch_preconditions) |precondition| {
        if (proof_backed) {
            if (precondition.kind != .gid_component) continue;
            try std.testing.expectEqual(@as(u8, 0), precondition.gid_axis);
            try std.testing.expectEqual(@as(u64, 1), precondition.element_multiplier);
        } else {
            if (precondition.kind != .uniform_extent) continue;
            try std.testing.expectEqual(@as(u32, 0), precondition.uniform_binding.group);
            try std.testing.expectEqual(@as(u32, 0), precondition.uniform_binding.binding);
            try std.testing.expectEqual(@as(u32, 0), precondition.uniform_u32_offsets[0]);
            try std.testing.expectEqual(@as(u8, 1), precondition.uniform_u32_count);
        }
        try std.testing.expectEqual(@as(u32, 0), precondition.storage_binding.group);
        switch (precondition.storage_binding.binding) {
            1 => saw_input = true,
            2 => saw_output = true,
            else => return error.TestUnexpectedResult,
        }
        precondition_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), precondition_count);
    try std.testing.expect(saw_input);
    try std.testing.expect(saw_output);

    const msl = out[0..result.len];
    try std.testing.expect(!result.info.needs_sizes_buf);
    try std.testing.expect(std.mem.indexOf(u8, msl, "_doe_sizes") == null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "min(") == null);
}

test "compute runtime emits Metal max total threads from workgroup size" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\@compute @workgroup_size(8, 4, 2)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    data[gid.x] = gid.y + gid.z;
        \\}
    ;
    var out: [emit_msl.MAX_OUTPUT]u8 = undefined;
    var result = try translateToMslForComputeRuntimeTimed(
        std.testing.allocator,
        source,
        &out,
        null,
        0,
    );
    defer result.info.deinit(std.testing.allocator);

    const msl = out[0..result.len];
    try std.testing.expect(std.mem.indexOf(u8, msl, "[[max_total_threads_per_threadgroup(64)]]") != null);
}
