// error_scope.zig — WebGPU error scope stack (pushErrorScope / popErrorScope).
//
// The spec defines a per-device LIFO stack of error scopes. Each scope captures
// errors matching its filter. When popped, the first captured error (or null) is
// returned asynchronously. Uncaptured errors go to the device's uncaptured-error
// callback.
//
// This implementation is intentionally synchronous: Doe executes all GPU work
// synchronously, so there are no deferred error deliveries to handle. The callback
// for popErrorScope is invoked immediately (inside popErrorScope), matching the
// behaviour of Doe's other "async" operations.
//
// Thread safety: all operations are protected by a Mutex. This is sufficient for
// single-device use from a single JS thread. If multi-threaded use is required, the
// caller must ensure the device outlives all concurrent operations.

const std = @import("std");
const abi_base = @import("../../core/abi/wgpu_handle_types.zig");

// ============================================================
// Constants
// ============================================================

const MAX_SCOPE_DEPTH: usize = 64;

// Error type discriminants matching the WebGPU spec and Dawn's C ABI encoding.
pub const ERROR_TYPE_NO_ERROR: u32 = 0x00000001;
pub const ERROR_TYPE_VALIDATION: u32 = 0x00000002;
pub const ERROR_TYPE_OUT_OF_MEMORY: u32 = 0x00000003;
pub const ERROR_TYPE_INTERNAL: u32 = 0x00000004;
pub const ERROR_TYPE_UNKNOWN: u32 = 0x00000005;

// Filter values matching WGPUErrorFilter in the C ABI.
pub const FILTER_VALIDATION: u32 = 0x00000001;
pub const FILTER_OUT_OF_MEMORY: u32 = 0x00000002;
pub const FILTER_INTERNAL: u32 = 0x00000003;

const MAX_ERROR_MSG: usize = 512;

// ============================================================
// Error record
// ============================================================

pub const ScopedError = struct {
    error_type: u32,
    // Fixed-size message storage avoids allocator dependency inside the scope stack.
    msg_buf: [MAX_ERROR_MSG]u8,
    msg_len: usize,

    pub fn message(self: *const ScopedError) []const u8 {
        return self.msg_buf[0..self.msg_len];
    }
};

fn make_error(error_type: u32, msg: []const u8) ScopedError {
    var e = ScopedError{
        .error_type = error_type,
        .msg_buf = std.mem.zeroes([MAX_ERROR_MSG]u8),
        .msg_len = 0,
    };
    const copy_len = @min(msg.len, MAX_ERROR_MSG);
    std.mem.copyForwards(u8, e.msg_buf[0..copy_len], msg[0..copy_len]);
    e.msg_len = copy_len;
    return e;
}

// ============================================================
// Scope entry
// ============================================================

const Scope = struct {
    filter: u32,
    // First captured error for this scope (null if none yet).
    captured: ?ScopedError,
};

// ============================================================
// popErrorScope callback type (matching wgpu.h WGPUPopErrorScopeCallback)
// ============================================================

// callback(type, message, userdata1, userdata2)
pub const PopErrorScopeCallback = *const fn (
    error_type: u32,
    msg: abi_base.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void;

// WGPUPopErrorScopeCallbackInfo2 — flat struct matching Dawn C ABI.
pub const WGPUPopErrorScopeCallbackInfo = extern struct {
    next_in_chain: ?*anyopaque = null,
    mode: u32 = 0,
    callback: ?PopErrorScopeCallback = null,
    userdata1: ?*anyopaque = null,
    userdata2: ?*anyopaque = null,
};

// ============================================================
// Uncaptured error callback type
// ============================================================

pub const UncapturedErrorCallback = *const fn (
    error_type: u32,
    msg: abi_base.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void;

// ============================================================
// ErrorScopeStack — one per DoeDevice
// ============================================================

pub const ErrorScopeStack = struct {
    mutex: std.Thread.Mutex,
    scopes: [MAX_SCOPE_DEPTH]Scope,
    depth: usize,
    // Optional uncaptured-error callback (set by device.onuncapturederror).
    uncaptured_cb: ?UncapturedErrorCallback,
    uncaptured_ud1: ?*anyopaque,
    uncaptured_ud2: ?*anyopaque,

    pub fn init() ErrorScopeStack {
        return .{
            .mutex = .{},
            .scopes = undefined,
            .depth = 0,
            .uncaptured_cb = null,
            .uncaptured_ud1 = null,
            .uncaptured_ud2 = null,
        };
    }

    // Push a new scope with the given filter.
    pub fn push(self: *ErrorScopeStack, filter: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.depth >= MAX_SCOPE_DEPTH) {
            // Exceeding MAX_SCOPE_DEPTH is a programming error; treat as internal error.
            return;
        }
        self.scopes[self.depth] = .{ .filter = filter, .captured = null };
        self.depth += 1;
    }

    // Pop the top scope. Calls `cb_info.callback` synchronously with the result.
    // Returns false if the stack is empty (invalid call).
    pub fn pop(self: *ErrorScopeStack, cb_info: WGPUPopErrorScopeCallbackInfo) bool {
        self.mutex.lock();
        if (self.depth == 0) {
            self.mutex.unlock();
            return false;
        }
        self.depth -= 1;
        const scope = self.scopes[self.depth];
        self.mutex.unlock();

        const cb = cb_info.callback orelse return true;
        if (scope.captured) |err| {
            const sv = abi_base.WGPUStringView{
                .data = &err.msg_buf,
                .length = err.msg_len,
            };
            cb(err.error_type, sv, cb_info.userdata1, cb_info.userdata2);
        } else {
            cb(ERROR_TYPE_NO_ERROR, .{ .data = null, .length = 0 }, cb_info.userdata1, cb_info.userdata2);
        }
        return true;
    }

    // Deliver an error. Captured by the first scope whose filter matches; otherwise
    // routed to the uncaptured-error callback.
    pub fn deliver(self: *ErrorScopeStack, error_type: u32, msg: []const u8) void {
        self.mutex.lock();
        // Search LIFO for a matching scope.
        var i: usize = self.depth;
        while (i > 0) {
            i -= 1;
            const scope = &self.scopes[i];
            if (filter_matches(scope.filter, error_type)) {
                // Capture only the first error per scope.
                if (scope.captured == null) {
                    scope.captured = make_error(error_type, msg);
                }
                self.mutex.unlock();
                return;
            }
        }
        // No matching scope — fire uncaptured callback.
        const cb = self.uncaptured_cb;
        const ud1 = self.uncaptured_ud1;
        const ud2 = self.uncaptured_ud2;
        self.mutex.unlock();

        if (cb) |f| {
            var buf: [MAX_ERROR_MSG]u8 = std.mem.zeroes([MAX_ERROR_MSG]u8);
            const copy_len = @min(msg.len, MAX_ERROR_MSG);
            std.mem.copyForwards(u8, buf[0..copy_len], msg[0..copy_len]);
            f(error_type, .{ .data = &buf, .length = copy_len }, ud1, ud2);
        }
    }

    pub fn set_uncaptured_handler(
        self: *ErrorScopeStack,
        cb: ?UncapturedErrorCallback,
        ud1: ?*anyopaque,
        ud2: ?*anyopaque,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.uncaptured_cb = cb;
        self.uncaptured_ud1 = ud1;
        self.uncaptured_ud2 = ud2;
    }
};

fn filter_matches(filter: u32, error_type: u32) bool {
    return switch (filter) {
        FILTER_VALIDATION => error_type == ERROR_TYPE_VALIDATION,
        FILTER_OUT_OF_MEMORY => error_type == ERROR_TYPE_OUT_OF_MEMORY,
        FILTER_INTERNAL => error_type == ERROR_TYPE_INTERNAL,
        // Filter value 0 or unknown: catch all non-no-error.
        else => error_type != ERROR_TYPE_NO_ERROR,
    };
}

// ============================================================
// Convenience: map Zig errors to WebGPU error types
// ============================================================

pub fn zig_error_to_type(err: anyerror) u32 {
    return switch (err) {
        error.OutOfMemory => ERROR_TYPE_OUT_OF_MEMORY,
        error.InvalidArgument,
        error.InvalidState,
        error.ShaderCompileFailed,
        error.ShaderToolchainUnavailable,
        => ERROR_TYPE_VALIDATION,
        else => ERROR_TYPE_INTERNAL,
    };
}
