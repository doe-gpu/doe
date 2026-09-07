// doe_render_pass_controls_native.zig — RenderPassEncoder control method C-ABI exports.
// Implements: setViewport, setScissorRect, setBlendConstant, setStencilReference,
//             pushDebugGroup, popDebugGroup, insertDebugMarker.
//
// These WebGPU-facing exports receive a logical DoeRenderPass. Dynamic state is
// recorded with each draw and applied later to the backend command encoder.

const recording = @import("../command/doe_command_recording.zig");
const helpers = @import("../support/doe_native_object_helpers.zig");
const objects = @import("../support/doe_native_object_types.zig");

fn validatePass(raw: ?*anyopaque) void {
    const pass = helpers.cast(objects.DoeRenderPass, raw) orelse return;
    _ = recording.requirePass(pass.enc, @intFromPtr(pass));
}

extern fn doeNativeRenderPassRecordViewportState(
    pass_raw: ?*anyopaque,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    min_depth: f64,
    max_depth: f64,
) callconv(.c) void;
extern fn doeNativeRenderPassRecordScissorState(
    pass_raw: ?*anyopaque,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
) callconv(.c) void;
extern fn doeNativeRenderPassRecordBlendConstantState(
    pass_raw: ?*anyopaque,
    r: f64,
    g: f64,
    b: f64,
    a: f64,
) callconv(.c) void;
extern fn doeNativeRenderPassRecordStencilReferenceState(
    pass_raw: ?*anyopaque,
    reference: u32,
) callconv(.c) void;

// ============================================================
// setViewport
// ============================================================

pub export fn doeNativeRenderPassSetViewport(
    encoder_raw: ?*anyopaque,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    min_depth: f64,
    max_depth: f64,
) callconv(.c) void {
    doeNativeRenderPassRecordViewportState(
        encoder_raw,
        x,
        y,
        width,
        height,
        min_depth,
        max_depth,
    );
}

// ============================================================
// setScissorRect
// ============================================================

pub export fn doeNativeRenderPassSetScissorRect(
    encoder_raw: ?*anyopaque,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
) callconv(.c) void {
    doeNativeRenderPassRecordScissorState(encoder_raw, x, y, width, height);
}

// ============================================================
// setBlendConstant — color is {r,g,b,a} f64 components
// ============================================================

pub export fn doeNativeRenderPassSetBlendConstant(
    encoder_raw: ?*anyopaque,
    r: f64,
    g: f64,
    b: f64,
    a: f64,
) callconv(.c) void {
    doeNativeRenderPassRecordBlendConstantState(encoder_raw, r, g, b, a);
}

// ============================================================
// setStencilReference
// ============================================================

pub export fn doeNativeRenderPassSetStencilReference(
    encoder_raw: ?*anyopaque,
    reference: u32,
) callconv(.c) void {
    doeNativeRenderPassRecordStencilReferenceState(encoder_raw, reference);
}

// ============================================================
// pushDebugGroup — label_ptr / label_len: UTF-8 byte span
// ============================================================

pub export fn doeNativeRenderPassPushDebugGroup(
    encoder_raw: ?*anyopaque,
    label_ptr: ?[*]const u8,
    label_len: usize,
) callconv(.c) void {
    // Debug labels do not affect execution and the logical pass does not own a
    // backend encoder until queue submission.
    validatePass(encoder_raw);
    _ = label_ptr;
    _ = label_len;
}

// ============================================================
// popDebugGroup
// ============================================================

pub export fn doeNativeRenderPassPopDebugGroup(
    encoder_raw: ?*anyopaque,
) callconv(.c) void {
    validatePass(encoder_raw);
}

// ============================================================
// insertDebugMarker — label_ptr / label_len: UTF-8 byte span
// ============================================================

pub export fn doeNativeRenderPassInsertDebugMarker(
    encoder_raw: ?*anyopaque,
    label_ptr: ?[*]const u8,
    label_len: usize,
) callconv(.c) void {
    validatePass(encoder_raw);
    _ = label_ptr;
    _ = label_len;
}
