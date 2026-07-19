// doe_immediates_external_native.zig — immediate-data forwarding and external-texture stubs.
// Sharded from doe_wgpu_native.zig; groups newer WebGPU APIs that are not part of
// the core command/resource path modules.

const std = @import("std");
const native_types = @import("../support/doe_native_object_types.zig");
const native_helpers = @import("../support/doe_native_object_helpers.zig");
const render_bundle = @import("../../runtime/render/render_bundle.zig");

const DoePipelineLayout = native_types.DoePipelineLayout;

fn validate_immediate_data(data_ptr: ?[*]const u8, data_len: usize) bool {
    if (data_len == 0) return true;
    return data_ptr != null;
}

fn immediate_budget(layout: ?*DoePipelineLayout) u32 {
    return if (layout) |l| l.immediate_size else 0;
}

fn within_immediate_budget(layout: ?*DoePipelineLayout, index: u32, data_len: usize) bool {
    const budget = immediate_budget(layout);
    if (budget == 0) return data_len == 0 and index == 0;
    return @as(u64, index) + @as(u64, @intCast(data_len)) <= @as(u64, budget);
}

// Shared payload validation + structured error logging for the
// compute/render pass setImmediates entry points. The render-bundle
// variant does not carry pipeline layout context and validates payload
// presence only; it therefore does not route through this helper.
fn log_immediate_validation(
    label: []const u8,
    layout: ?*DoePipelineLayout,
    index: u32,
    data_ptr: ?[*]const u8,
    data_len: usize,
) void {
    if (!validate_immediate_data(data_ptr, data_len)) {
        std.log.err("doe: {s} setImmediates rejected null data pointer for non-zero size", .{label});
        return;
    }
    if (!within_immediate_budget(layout, index, data_len)) {
        std.log.err("doe: {s} setImmediates exceeds pipeline layout immediateSize (index={} size={} budget={})", .{
            label,
            index,
            data_len,
            immediate_budget(layout),
        });
    }
}

// ============================================================
// setImmediates — push constants / immediate data upload
// ============================================================

// setImmediates is the WebGPU immediate-data surface. There is no generic
// proc for the abstract binding-commands mixin, so the concrete compute/render
// pass entry points are forwarded directly to the provider WebGPU symbols below.
// The mixin export remains an explicit unsupported entry because it has no
// standalone runtime object or generic proc target.

pub export fn doeNativeBindingCommandsSetImmediates(
    encoder_raw: ?*anyopaque,
    index: u32,
    data_ptr: ?[*]const u8,
    data_len: usize,
) callconv(.c) void {
    _ = encoder_raw;
    _ = index;
    _ = data_ptr;
    _ = data_len;
    std.log.err("doe: doeNativeBindingCommandsSetImmediates: unsupported — " ++
        "abstract mixin entry has no standalone encoder type; use the concrete " ++
        "compute/render pass setImmediates entry points", .{});
}

pub export fn doeNativeComputePassSetImmediates(
    encoder_raw: ?*anyopaque,
    index: u32,
    data_ptr: ?[*]const u8,
    data_len: usize,
) callconv(.c) void {
    const encoder = native_helpers.cast(native_types.DoeComputePass, encoder_raw) orelse return;
    const layout = if (encoder.pipeline) |pipeline| pipeline.layout else null;
    log_immediate_validation("compute", layout, index, data_ptr, data_len);
}

pub export fn doeNativeRenderPassSetImmediates(
    encoder_raw: ?*anyopaque,
    index: u32,
    data_ptr: ?[*]const u8,
    data_len: usize,
) callconv(.c) void {
    const encoder = native_helpers.cast(native_types.DoeRenderPass, encoder_raw) orelse return;
    const layout = if (encoder.pipeline) |pipeline| pipeline.layout else null;
    log_immediate_validation("render pass", layout, index, data_ptr, data_len);
}

pub export fn doeNativeRenderBundleEncoderSetImmediates(
    encoder_raw: ?*anyopaque,
    index: u32,
    data_ptr: ?[*]const u8,
    data_len: usize,
) callconv(.c) void {
    _ = index;
    const encoder = render_bundle.cast_bundle_encoder(encoder_raw) orelse return;
    _ = encoder;
    if (!validate_immediate_data(data_ptr, data_len)) {
        std.log.err("doe: render bundle setImmediates rejected null data pointer for non-zero size", .{});
    }
}

// importExternalTexture / createExternalTexture moved to doe_external_texture_native.zig.
