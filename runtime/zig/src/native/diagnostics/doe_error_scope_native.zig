// doe_error_scope_native.zig — C ABI exports for WebGPU error scopes.
// pushErrorScope / popErrorScope / onUncapturedError, all wired to the
// per-device ErrorScopeStack.
//
// Integration with DoeDevice: the ErrorScopeStack is stored inline on DoeDevice
// (added in this change). All operations that can generate errors call
// error_scope.deliver() so the correct scope captures them.

const abi_base = @import("../../core/abi/wgpu_handle_types.zig");
const native_types = @import("../support/doe_native_object_types.zig");
const native_helpers = @import("../support/doe_native_object_helpers.zig");
const err_scope = @import("../../runtime/diagnostics/error_scope.zig");

const cast = native_helpers.cast;
const DoeDevice = native_types.DoeDevice;

// ============================================================
// C ABI: pushErrorScope
// ============================================================

pub export fn doeNativeDevicePushErrorScope(
    dev_raw: ?*anyopaque,
    filter: u32,
) callconv(.c) void {
    const dev = cast(DoeDevice, dev_raw) orelse return;
    dev.error_scopes.push(filter);
}

// ============================================================
// C ABI: popErrorScope
// ============================================================

// WGPUPopErrorScopeCallbackInfo2 — matches Dawn C ABI for the 2-userdata variant.
pub const WGPUPopErrorScopeCallbackInfo2 = extern struct {
    next_in_chain: ?*anyopaque = null,
    mode: u32 = 0,
    callback: ?err_scope.PopErrorScopeCallback = null,
    userdata1: ?*anyopaque = null,
    userdata2: ?*anyopaque = null,
};

pub export fn doeNativeDevicePopErrorScope(
    dev_raw: ?*anyopaque,
    cb_info: WGPUPopErrorScopeCallbackInfo2,
) callconv(.c) abi_base.WGPUFuture {
    const dev = cast(DoeDevice, dev_raw) orelse {
        // Invalid device — deliver an internal error via callback if provided.
        if (cb_info.callback) |cb| {
            cb(err_scope.ERROR_TYPE_INTERNAL, .{ .data = null, .length = 0 }, cb_info.userdata1, cb_info.userdata2);
        }
        return .{ .id = 5 };
    };

    const info = err_scope.WGPUPopErrorScopeCallbackInfo{
        .callback = cb_info.callback,
        .userdata1 = cb_info.userdata1,
        .userdata2 = cb_info.userdata2,
    };
    _ = dev.error_scopes.pop(info);
    return .{ .id = 5 };
}

pub export fn doeNativeDevicePopErrorScopeFlat(
    dev_raw: ?*anyopaque,
    callback: ?err_scope.PopErrorScopeCallback,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) abi_base.WGPUFuture {
    return doeNativeDevicePopErrorScope(dev_raw, .{
        .next_in_chain = null,
        .mode = 0,
        .callback = callback,
        .userdata1 = userdata1,
        .userdata2 = userdata2,
    });
}

// ============================================================
// C ABI: setUncapturedErrorCallback
// ============================================================

// Matches WGPUUncapturedErrorCallbackInfo from wgpu_runtime_abi.zig but we take the
// raw function pointer directly for the common single-callback case used by doe_napi.c.

pub export fn doeNativeDeviceSetUncapturedErrorCallback(
    dev_raw: ?*anyopaque,
    callback: ?err_scope.UncapturedErrorCallback,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    const dev = cast(DoeDevice, dev_raw) orelse return;
    dev.error_scopes.set_uncaptured_handler(callback, userdata1, userdata2);
}

// ============================================================
// C ABI: inject validation / OOM / internal errors (used by Doe internals)
// ============================================================

// Deliver a validation error to the current device's error scope stack.
// Called by C-side code (e.g., doe_napi.c) when a WebGPU operation fails validation.
pub export fn doeNativeDeviceInjectError(
    dev_raw: ?*anyopaque,
    error_type: u32,
    msg_ptr: ?[*]const u8,
    msg_len: usize,
) callconv(.c) void {
    const dev = cast(DoeDevice, dev_raw) orelse return;
    const msg: []const u8 = if (msg_ptr) |p| p[0..msg_len] else "";
    dev.error_scopes.deliver(error_type, msg);
}
