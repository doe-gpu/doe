const std = @import("std");
const es = @import("../../src/runtime/diagnostics/error_scope.zig");
const wgpu_types = @import("../../src/core/abi/wgpu_runtime_abi.zig");

// ============================================================
// Helpers
// ============================================================

// Tracks the most recent callback invocation for assertions.
const CallbackRecord = struct {
    error_type: u32 = 0,
    msg: ?[]const u8 = null,
    call_count: usize = 0,

    // Backing store for the message (copied from the callback's WGPUStringView).
    msg_buf: [512]u8 = undefined,
};

var g_cb_record: CallbackRecord = .{};

// Standalone callback that records results into g_cb_record.
fn record_callback(
    error_type: u32,
    msg_sv: wgpu_types.WGPUStringView,
    _: ?*anyopaque,
    _: ?*anyopaque,
) callconv(.c) void {
    g_cb_record.error_type = error_type;
    g_cb_record.call_count += 1;
    if (msg_sv.data) |data| {
        const len = msg_sv.length;
        @memcpy(g_cb_record.msg_buf[0..len], data[0..len]);
        g_cb_record.msg = g_cb_record.msg_buf[0..len];
    } else {
        g_cb_record.msg = null;
    }
}

fn make_cb_info() es.WGPUPopErrorScopeCallbackInfo {
    return .{
        .callback = &record_callback,
    };
}

fn reset_record() void {
    g_cb_record = .{};
}

// Uncaptured error callback tracker.
var g_uncaptured_record: CallbackRecord = .{};

fn uncaptured_callback(
    error_type: u32,
    msg_sv: wgpu_types.WGPUStringView,
    _: ?*anyopaque,
    _: ?*anyopaque,
) callconv(.c) void {
    g_uncaptured_record.error_type = error_type;
    g_uncaptured_record.call_count += 1;
    if (msg_sv.data) |data| {
        const len = msg_sv.length;
        @memcpy(g_uncaptured_record.msg_buf[0..len], data[0..len]);
        g_uncaptured_record.msg = g_uncaptured_record.msg_buf[0..len];
    } else {
        g_uncaptured_record.msg = null;
    }
}

fn reset_uncaptured() void {
    g_uncaptured_record = .{};
}

// ============================================================
// Push/pop scope lifecycle
// ============================================================

test "push and pop single validation scope with no errors reports no_error" {
    reset_record();
    var stack = es.ErrorScopeStack.init();

    stack.push(es.FILTER_VALIDATION);
    const ok = stack.pop(make_cb_info());

    try std.testing.expect(ok);
    try std.testing.expectEqual(@as(usize, 1), g_cb_record.call_count);
    try std.testing.expectEqual(es.ERROR_TYPE_NO_ERROR, g_cb_record.error_type);
}

test "push and pop oom scope with no errors reports no_error" {
    reset_record();
    var stack = es.ErrorScopeStack.init();

    stack.push(es.FILTER_OUT_OF_MEMORY);
    const ok = stack.pop(make_cb_info());

    try std.testing.expect(ok);
    try std.testing.expectEqual(es.ERROR_TYPE_NO_ERROR, g_cb_record.error_type);
}

test "push and pop internal scope with no errors reports no_error" {
    reset_record();
    var stack = es.ErrorScopeStack.init();

    stack.push(es.FILTER_INTERNAL);
    const ok = stack.pop(make_cb_info());

    try std.testing.expect(ok);
    try std.testing.expectEqual(es.ERROR_TYPE_NO_ERROR, g_cb_record.error_type);
}

// ============================================================
// Error capture within a scope
// ============================================================

test "validation error captured by validation scope" {
    reset_record();
    var stack = es.ErrorScopeStack.init();

    stack.push(es.FILTER_VALIDATION);
    stack.deliver(es.ERROR_TYPE_VALIDATION, "bad shader");
    const ok = stack.pop(make_cb_info());

    try std.testing.expect(ok);
    try std.testing.expectEqual(es.ERROR_TYPE_VALIDATION, g_cb_record.error_type);
    try std.testing.expectEqualStrings("bad shader", g_cb_record.msg.?);
}

test "oom error captured by oom scope" {
    reset_record();
    var stack = es.ErrorScopeStack.init();

    stack.push(es.FILTER_OUT_OF_MEMORY);
    stack.deliver(es.ERROR_TYPE_OUT_OF_MEMORY, "buffer alloc failed");
    const ok = stack.pop(make_cb_info());

    try std.testing.expect(ok);
    try std.testing.expectEqual(es.ERROR_TYPE_OUT_OF_MEMORY, g_cb_record.error_type);
    try std.testing.expectEqualStrings("buffer alloc failed", g_cb_record.msg.?);
}

test "internal error captured by internal scope" {
    reset_record();
    var stack = es.ErrorScopeStack.init();

    stack.push(es.FILTER_INTERNAL);
    stack.deliver(es.ERROR_TYPE_INTERNAL, "driver crash");
    const ok = stack.pop(make_cb_info());

    try std.testing.expect(ok);
    try std.testing.expectEqual(es.ERROR_TYPE_INTERNAL, g_cb_record.error_type);
    try std.testing.expectEqualStrings("driver crash", g_cb_record.msg.?);
}

test "only the first error is captured per scope" {
    reset_record();
    var stack = es.ErrorScopeStack.init();

    stack.push(es.FILTER_VALIDATION);
    stack.deliver(es.ERROR_TYPE_VALIDATION, "first");
    stack.deliver(es.ERROR_TYPE_VALIDATION, "second");
    const ok = stack.pop(make_cb_info());

    try std.testing.expect(ok);
    try std.testing.expectEqual(es.ERROR_TYPE_VALIDATION, g_cb_record.error_type);
    try std.testing.expectEqualStrings("first", g_cb_record.msg.?);
}

// ============================================================
// Error type filtering
// ============================================================

test "validation scope does not capture oom error" {
    reset_record();
    reset_uncaptured();
    var stack = es.ErrorScopeStack.init();
    stack.set_uncaptured_handler(&uncaptured_callback, null, null);

    stack.push(es.FILTER_VALIDATION);
    stack.deliver(es.ERROR_TYPE_OUT_OF_MEMORY, "oom goes uncaptured");
    const ok = stack.pop(make_cb_info());

    try std.testing.expect(ok);
    // Scope should report no error since oom doesn't match validation filter.
    try std.testing.expectEqual(es.ERROR_TYPE_NO_ERROR, g_cb_record.error_type);
    // The uncaptured handler should have received the error.
    try std.testing.expectEqual(@as(usize, 1), g_uncaptured_record.call_count);
    try std.testing.expectEqual(es.ERROR_TYPE_OUT_OF_MEMORY, g_uncaptured_record.error_type);
}

test "oom scope does not capture validation error" {
    reset_record();
    reset_uncaptured();
    var stack = es.ErrorScopeStack.init();
    stack.set_uncaptured_handler(&uncaptured_callback, null, null);

    stack.push(es.FILTER_OUT_OF_MEMORY);
    stack.deliver(es.ERROR_TYPE_VALIDATION, "validation goes uncaptured");
    const ok = stack.pop(make_cb_info());

    try std.testing.expect(ok);
    try std.testing.expectEqual(es.ERROR_TYPE_NO_ERROR, g_cb_record.error_type);
    try std.testing.expectEqual(@as(usize, 1), g_uncaptured_record.call_count);
    try std.testing.expectEqual(es.ERROR_TYPE_VALIDATION, g_uncaptured_record.error_type);
}

test "internal scope does not capture validation error" {
    reset_record();
    reset_uncaptured();
    var stack = es.ErrorScopeStack.init();
    stack.set_uncaptured_handler(&uncaptured_callback, null, null);

    stack.push(es.FILTER_INTERNAL);
    stack.deliver(es.ERROR_TYPE_VALIDATION, "wrong filter");
    const ok = stack.pop(make_cb_info());

    try std.testing.expect(ok);
    try std.testing.expectEqual(es.ERROR_TYPE_NO_ERROR, g_cb_record.error_type);
    try std.testing.expectEqual(@as(usize, 1), g_uncaptured_record.call_count);
}

// ============================================================
// Nested scopes: inner captures don't leak to outer
// ============================================================

test "inner scope captures error; outer scope sees no error" {
    reset_record();
    var stack = es.ErrorScopeStack.init();

    // Push outer (validation), then inner (validation).
    stack.push(es.FILTER_VALIDATION);
    stack.push(es.FILTER_VALIDATION);

    // Deliver error — inner scope (LIFO top) captures it.
    stack.deliver(es.ERROR_TYPE_VALIDATION, "caught by inner");

    // Pop inner — should have the error.
    reset_record();
    const ok_inner = stack.pop(make_cb_info());
    try std.testing.expect(ok_inner);
    try std.testing.expectEqual(es.ERROR_TYPE_VALIDATION, g_cb_record.error_type);
    try std.testing.expectEqualStrings("caught by inner", g_cb_record.msg.?);

    // Pop outer — should have no error (inner already captured it).
    reset_record();
    const ok_outer = stack.pop(make_cb_info());
    try std.testing.expect(ok_outer);
    try std.testing.expectEqual(es.ERROR_TYPE_NO_ERROR, g_cb_record.error_type);
}

test "nested scopes with different filters route correctly" {
    reset_record();
    var stack = es.ErrorScopeStack.init();

    // Outer: oom filter. Inner: validation filter.
    stack.push(es.FILTER_OUT_OF_MEMORY);
    stack.push(es.FILTER_VALIDATION);

    // Deliver an oom error — inner (validation) won't match, outer (oom) will.
    stack.deliver(es.ERROR_TYPE_OUT_OF_MEMORY, "oom for outer");

    // Pop inner — no error (filter didn't match).
    reset_record();
    const ok_inner = stack.pop(make_cb_info());
    try std.testing.expect(ok_inner);
    try std.testing.expectEqual(es.ERROR_TYPE_NO_ERROR, g_cb_record.error_type);

    // Pop outer — should have the oom error.
    reset_record();
    const ok_outer = stack.pop(make_cb_info());
    try std.testing.expect(ok_outer);
    try std.testing.expectEqual(es.ERROR_TYPE_OUT_OF_MEMORY, g_cb_record.error_type);
    try std.testing.expectEqualStrings("oom for outer", g_cb_record.msg.?);
}

test "deeply nested scopes only capture in the innermost matching scope" {
    reset_record();
    var stack = es.ErrorScopeStack.init();

    // Three validation scopes, outermost to innermost.
    stack.push(es.FILTER_VALIDATION); // depth 0
    stack.push(es.FILTER_VALIDATION); // depth 1
    stack.push(es.FILTER_VALIDATION); // depth 2 (innermost)

    stack.deliver(es.ERROR_TYPE_VALIDATION, "deepest captures");

    // Pop depth 2 — has the error.
    reset_record();
    _ = stack.pop(make_cb_info());
    try std.testing.expectEqual(es.ERROR_TYPE_VALIDATION, g_cb_record.error_type);
    try std.testing.expectEqualStrings("deepest captures", g_cb_record.msg.?);

    // Pop depth 1 — no error.
    reset_record();
    _ = stack.pop(make_cb_info());
    try std.testing.expectEqual(es.ERROR_TYPE_NO_ERROR, g_cb_record.error_type);

    // Pop depth 0 — no error.
    reset_record();
    _ = stack.pop(make_cb_info());
    try std.testing.expectEqual(es.ERROR_TYPE_NO_ERROR, g_cb_record.error_type);
}

test "each scope in a nested stack captures its own error independently" {
    reset_record();
    var stack = es.ErrorScopeStack.init();

    stack.push(es.FILTER_OUT_OF_MEMORY);
    stack.push(es.FILTER_VALIDATION);

    // Deliver validation error — captured by inner.
    stack.deliver(es.ERROR_TYPE_VALIDATION, "inner val");
    // Deliver oom error — inner doesn't match, captured by outer.
    stack.deliver(es.ERROR_TYPE_OUT_OF_MEMORY, "outer oom");

    // Pop inner — validation error.
    reset_record();
    _ = stack.pop(make_cb_info());
    try std.testing.expectEqual(es.ERROR_TYPE_VALIDATION, g_cb_record.error_type);
    try std.testing.expectEqualStrings("inner val", g_cb_record.msg.?);

    // Pop outer — oom error.
    reset_record();
    _ = stack.pop(make_cb_info());
    try std.testing.expectEqual(es.ERROR_TYPE_OUT_OF_MEMORY, g_cb_record.error_type);
    try std.testing.expectEqualStrings("outer oom", g_cb_record.msg.?);
}

// ============================================================
// Pop on empty stack
// ============================================================

test "pop on empty stack returns false" {
    var stack = es.ErrorScopeStack.init();
    reset_record();

    const ok = stack.pop(make_cb_info());

    try std.testing.expect(!ok);
    // Callback should not have been invoked.
    try std.testing.expectEqual(@as(usize, 0), g_cb_record.call_count);
}

test "pop after all scopes consumed returns false" {
    var stack = es.ErrorScopeStack.init();
    reset_record();

    stack.push(es.FILTER_VALIDATION);
    _ = stack.pop(make_cb_info());

    // Stack is now empty again.
    reset_record();
    const ok = stack.pop(make_cb_info());
    try std.testing.expect(!ok);
    try std.testing.expectEqual(@as(usize, 0), g_cb_record.call_count);
}

// ============================================================
// Pop with null callback
// ============================================================

test "pop with null callback returns true but does not crash" {
    var stack = es.ErrorScopeStack.init();

    stack.push(es.FILTER_VALIDATION);
    stack.deliver(es.ERROR_TYPE_VALIDATION, "ignored");

    const ok = stack.pop(.{ .callback = null });
    try std.testing.expect(ok);
}

// ============================================================
// Uncaptured error routing
// ============================================================

test "error with no matching scope fires uncaptured callback" {
    reset_uncaptured();
    var stack = es.ErrorScopeStack.init();
    stack.set_uncaptured_handler(&uncaptured_callback, null, null);

    // No scopes pushed — everything goes to uncaptured.
    stack.deliver(es.ERROR_TYPE_VALIDATION, "orphan error");

    try std.testing.expectEqual(@as(usize, 1), g_uncaptured_record.call_count);
    try std.testing.expectEqual(es.ERROR_TYPE_VALIDATION, g_uncaptured_record.error_type);
    try std.testing.expectEqualStrings("orphan error", g_uncaptured_record.msg.?);
}

test "error with no matching scope and no uncaptured handler is silently dropped" {
    var stack = es.ErrorScopeStack.init();
    // No handler set, no scopes pushed — should not crash.
    stack.deliver(es.ERROR_TYPE_INTERNAL, "silent drop");
}

// ============================================================
// ScopedError message through deliver/pop round-trip
// ============================================================

test "delivered message is faithfully round-tripped through pop" {
    reset_record();
    var stack = es.ErrorScopeStack.init();

    stack.push(es.FILTER_VALIDATION);
    stack.deliver(es.ERROR_TYPE_VALIDATION, "exact message content 12345");
    _ = stack.pop(make_cb_info());

    try std.testing.expectEqualStrings("exact message content 12345", g_cb_record.msg.?);
}

test "long message is truncated at 512 bytes through deliver/pop" {
    reset_record();
    var stack = es.ErrorScopeStack.init();

    // Build a message longer than 512 bytes.
    const long_msg = "x" ** 600;
    stack.push(es.FILTER_VALIDATION);
    stack.deliver(es.ERROR_TYPE_VALIDATION, long_msg);
    _ = stack.pop(make_cb_info());

    try std.testing.expectEqual(@as(usize, 512), g_cb_record.msg.?.len);
}

test "empty message is delivered correctly" {
    reset_record();
    var stack = es.ErrorScopeStack.init();

    stack.push(es.FILTER_INTERNAL);
    stack.deliver(es.ERROR_TYPE_INTERNAL, "");
    _ = stack.pop(make_cb_info());

    try std.testing.expectEqual(es.ERROR_TYPE_INTERNAL, g_cb_record.error_type);
    // With an empty message, the callback should receive a valid string view with length 0.
    // The data pointer may point to the error's buffer (not null) but length is 0.
    if (g_cb_record.msg) |msg| {
        try std.testing.expectEqual(@as(usize, 0), msg.len);
    }
}

// ============================================================
// ScopedError direct construction
// ============================================================

test "ScopedError.message returns correct slice" {
    var err = es.ScopedError{
        .error_type = es.ERROR_TYPE_VALIDATION,
        .msg_buf = std.mem.zeroes([512]u8),
        .msg_len = 0,
    };
    const text = "test message";
    @memcpy(err.msg_buf[0..text.len], text);
    err.msg_len = text.len;

    try std.testing.expectEqualStrings("test message", err.message());
    try std.testing.expectEqual(es.ERROR_TYPE_VALIDATION, err.error_type);
}

test "ScopedError.message returns empty slice for zero-length message" {
    const err = es.ScopedError{
        .error_type = es.ERROR_TYPE_OUT_OF_MEMORY,
        .msg_buf = std.mem.zeroes([512]u8),
        .msg_len = 0,
    };
    try std.testing.expectEqual(@as(usize, 0), err.msg_len);
    try std.testing.expectEqualStrings("", err.message());
}

// ============================================================
// zig_error_to_type mapping
// ============================================================

test "zig_error_to_type maps OutOfMemory to ERROR_TYPE_OUT_OF_MEMORY" {
    try std.testing.expectEqual(es.ERROR_TYPE_OUT_OF_MEMORY, es.zig_error_to_type(error.OutOfMemory));
}

test "zig_error_to_type maps validation errors to ERROR_TYPE_VALIDATION" {
    try std.testing.expectEqual(es.ERROR_TYPE_VALIDATION, es.zig_error_to_type(error.InvalidArgument));
    try std.testing.expectEqual(es.ERROR_TYPE_VALIDATION, es.zig_error_to_type(error.InvalidState));
    try std.testing.expectEqual(es.ERROR_TYPE_VALIDATION, es.zig_error_to_type(error.ShaderCompileFailed));
    try std.testing.expectEqual(es.ERROR_TYPE_VALIDATION, es.zig_error_to_type(error.ShaderToolchainUnavailable));
}

test "zig_error_to_type maps unknown errors to ERROR_TYPE_INTERNAL" {
    try std.testing.expectEqual(es.ERROR_TYPE_INTERNAL, es.zig_error_to_type(error.Unexpected));
}

// ============================================================
// Constants
// ============================================================

test "error type constants match WebGPU spec values" {
    try std.testing.expectEqual(@as(u32, 0x00000001), es.ERROR_TYPE_NO_ERROR);
    try std.testing.expectEqual(@as(u32, 0x00000002), es.ERROR_TYPE_VALIDATION);
    try std.testing.expectEqual(@as(u32, 0x00000003), es.ERROR_TYPE_OUT_OF_MEMORY);
    try std.testing.expectEqual(@as(u32, 0x00000004), es.ERROR_TYPE_INTERNAL);
    try std.testing.expectEqual(@as(u32, 0x00000005), es.ERROR_TYPE_UNKNOWN);
}

test "filter constants match WGPUErrorFilter values" {
    try std.testing.expectEqual(@as(u32, 0x00000001), es.FILTER_VALIDATION);
    try std.testing.expectEqual(@as(u32, 0x00000002), es.FILTER_OUT_OF_MEMORY);
    try std.testing.expectEqual(@as(u32, 0x00000003), es.FILTER_INTERNAL);
}

// ============================================================
// Max scope depth
// ============================================================

test "push beyond max depth is silently ignored" {
    var stack = es.ErrorScopeStack.init();

    // Push 64 scopes (the max).
    for (0..64) |_| {
        stack.push(es.FILTER_VALIDATION);
    }

    // 65th push should be silently dropped.
    stack.push(es.FILTER_VALIDATION);

    // Depth should still be 64 — verify by popping exactly 64 times.
    var pop_count: usize = 0;
    while (stack.pop(.{ .callback = null })) {
        pop_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 64), pop_count);
}

// ============================================================
// set_uncaptured_handler
// ============================================================

test "set_uncaptured_handler replaces previous handler" {
    reset_uncaptured();
    var stack = es.ErrorScopeStack.init();

    stack.set_uncaptured_handler(&uncaptured_callback, null, null);
    stack.deliver(es.ERROR_TYPE_VALIDATION, "first handler");
    try std.testing.expectEqual(@as(usize, 1), g_uncaptured_record.call_count);

    // Replace handler with null — subsequent errors should be silently dropped.
    stack.set_uncaptured_handler(null, null, null);
    stack.deliver(es.ERROR_TYPE_VALIDATION, "dropped");
    // Call count should not increase.
    try std.testing.expectEqual(@as(usize, 1), g_uncaptured_record.call_count);
}

// ============================================================
// ErrorScopeStack.init
// ============================================================

test "init produces stack with zero depth and no handler" {
    const stack = es.ErrorScopeStack.init();
    try std.testing.expectEqual(@as(usize, 0), stack.depth);
    try std.testing.expect(stack.uncaptured_cb == null);
    try std.testing.expect(stack.uncaptured_ud1 == null);
    try std.testing.expect(stack.uncaptured_ud2 == null);
}

// ============================================================
// Multiple push/pop cycles reuse stack slots
// ============================================================

test "stack can be reused after full push/pop cycle" {
    reset_record();
    var stack = es.ErrorScopeStack.init();

    // First cycle.
    stack.push(es.FILTER_VALIDATION);
    stack.deliver(es.ERROR_TYPE_VALIDATION, "cycle 1");
    _ = stack.pop(make_cb_info());
    try std.testing.expectEqualStrings("cycle 1", g_cb_record.msg.?);

    // Second cycle — same stack, fresh scope.
    reset_record();
    stack.push(es.FILTER_OUT_OF_MEMORY);
    stack.deliver(es.ERROR_TYPE_OUT_OF_MEMORY, "cycle 2");
    _ = stack.pop(make_cb_info());
    try std.testing.expectEqual(es.ERROR_TYPE_OUT_OF_MEMORY, g_cb_record.error_type);
    try std.testing.expectEqualStrings("cycle 2", g_cb_record.msg.?);
}
