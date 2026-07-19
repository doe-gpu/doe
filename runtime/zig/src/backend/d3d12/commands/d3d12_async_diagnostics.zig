const std = @import("std");
const model_async_types = @import("../../../contracts/model/model_async_types.zig");
const common_timing = @import("../../common/timing.zig");
const bridge = @import("../d3d12_bridge_decls.zig");

pub const AsyncDiagnosticsMetrics = struct {
    setup_ns: u64 = 0,
    encode_ns: u64 = 0,
};

pub fn execute_async_diagnostics(
    device: ?*anyopaque,
    cmd: model_async_types.AsyncDiagnosticsCommand,
) !AsyncDiagnosticsMetrics {
    const iterations = if (cmd.iterations == 0) @as(u32, 1) else cmd.iterations;

    switch (cmd.mode) {
        .pipeline_async => return execute_pipeline_async(device, cmd.target_format, iterations),
        .capability_introspection => return execute_capability_introspection(iterations),
        .resource_table_immediates => return execute_resource_table_immediates(iterations),
        .lifecycle_refcount => return execute_lifecycle_refcount(device, iterations),
        .pixel_local_storage => return execute_pixel_local_storage(iterations),
        .full => return execute_full(device, cmd.target_format, iterations),
    }
}

fn execute_pipeline_async(device: ?*anyopaque, target_format: u32, iterations: u32) !AsyncDiagnosticsMetrics {
    const setup_start = common_timing.now_ns();
    const root_sig = bridge.c.d3d12_bridge_device_create_root_signature_empty(device) orelse return error.InvalidState;
    defer bridge.c.d3d12_bridge_release(root_sig);
    const setup_ns = common_timing.ns_delta(common_timing.now_ns(), setup_start);

    const encode_start = common_timing.now_ns();
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        const vs = noop_vs_bytecode();
        const ps = noop_ps_bytecode();
        const pso = bridge.c.d3d12_bridge_device_create_graphics_pipeline(device, root_sig, vs.ptr, vs.len, ps.ptr, ps.len, target_format) orelse return error.ShaderCompileFailed;
        bridge.c.d3d12_bridge_release(pso);
    }
    const encode_ns = common_timing.ns_delta(common_timing.now_ns(), encode_start);
    return .{ .setup_ns = setup_ns, .encode_ns = encode_ns };
}

fn execute_capability_introspection(iterations: u32) !AsyncDiagnosticsMetrics {
    const encode_start = common_timing.now_ns();
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        std.mem.doNotOptimizeAway(i);
    }
    return .{ .encode_ns = common_timing.ns_delta(common_timing.now_ns(), encode_start) };
}

fn execute_resource_table_immediates(iterations: u32) !AsyncDiagnosticsMetrics {
    const encode_start = common_timing.now_ns();
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        std.mem.doNotOptimizeAway(i);
    }
    return .{ .encode_ns = common_timing.ns_delta(common_timing.now_ns(), encode_start) };
}

fn execute_lifecycle_refcount(device: ?*anyopaque, iterations: u32) !AsyncDiagnosticsMetrics {
    const encode_start = common_timing.now_ns();
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        const root_sig = bridge.c.d3d12_bridge_device_create_root_signature_empty(device) orelse return error.InvalidState;
        bridge.c.d3d12_bridge_release(root_sig);
    }
    return .{ .encode_ns = common_timing.ns_delta(common_timing.now_ns(), encode_start) };
}

fn execute_pixel_local_storage(iterations: u32) !AsyncDiagnosticsMetrics {
    const encode_start = common_timing.now_ns();
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        std.mem.doNotOptimizeAway(i);
    }
    return .{ .encode_ns = common_timing.ns_delta(common_timing.now_ns(), encode_start) };
}

fn execute_full(device: ?*anyopaque, target_format: u32, iterations: u32) !AsyncDiagnosticsMetrics {
    var total_setup: u64 = 0;
    var total_encode: u64 = 0;

    const m1 = try execute_pipeline_async(device, target_format, iterations);
    total_setup +|= m1.setup_ns;
    total_encode +|= m1.encode_ns;

    const m2 = try execute_capability_introspection(iterations);
    total_encode +|= m2.encode_ns;

    const m3 = try execute_resource_table_immediates(iterations);
    total_encode +|= m3.encode_ns;

    const m4 = try execute_lifecycle_refcount(device, iterations);
    total_encode +|= m4.encode_ns;

    const m5 = try execute_pixel_local_storage(iterations);
    total_encode +|= m5.encode_ns;

    return .{ .setup_ns = total_setup, .encode_ns = total_encode };
}

fn noop_vs_bytecode() []const u8 {
    const bytecode = [_]u8{
        0x44, 0x58, 0x42, 0x43, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
        0x50, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x24, 0x00, 0x00, 0x00,
        0x53, 0x48, 0x45, 0x58, 0x24, 0x00, 0x00, 0x00, 0x50, 0x00, 0x01, 0x00,
        0x03, 0x00, 0x00, 0x00, 0x65, 0x00, 0x00, 0x03, 0xF2, 0x20, 0x10, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x36, 0x00, 0x00, 0x08, 0xF2, 0x20, 0x10, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x02, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x3F,
        0x3E, 0x00, 0x00, 0x01,
    };
    return &bytecode;
}

fn noop_ps_bytecode() []const u8 {
    const bytecode = [_]u8{
        0x44, 0x58, 0x42, 0x43, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
        0x50, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x24, 0x00, 0x00, 0x00,
        0x53, 0x48, 0x45, 0x58, 0x24, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00,
        0x03, 0x00, 0x00, 0x00, 0x65, 0x00, 0x00, 0x03, 0xF2, 0x20, 0x10, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x36, 0x00, 0x00, 0x08, 0xF2, 0x20, 0x10, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x02, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x3F,
        0x3E, 0x00, 0x00, 0x01,
    };
    return &bytecode;
}
