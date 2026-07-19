const std = @import("std");
const model_commands = @import("../../contracts/model/model_commands.zig");
const runtime_types = @import("../runtime_types.zig");

const model = struct {
    pub const Command = model_commands.Command;
    pub const CommandKind = model_commands.CommandKind;
};

const NativeExecutionResult = runtime_types.NativeExecutionResult;

pub fn selectedCommandSubmitCount(command: model.Command, result: NativeExecutionResult) ?u32 {
    return selectedKindSubmitCount(std.meta.activeTag(command), result);
}

pub fn selectedKindSubmitCount(kind: model.CommandKind, result: NativeExecutionResult) ?u32 {
    if (result.status != .ok) return null;
    return switch (kind) {
        .dispatch,
        .dispatch_indirect,
        .kernel_dispatch,
        => if (result.dispatch_count > 0) 1 else 0,

        .upload,
        .buffer_write,
        .copy_buffer_to_texture,
        => 1,

        .render_draw,
        .draw_indirect,
        .draw_indexed_indirect,
        .render_pass,
        => if (result.dispatch_count > 0) 1 else 0,

        .surface_present,
        => if (result.submit_wait_ns > 0) 1 else 0,

        .barrier,
        .sampler_create,
        .sampler_destroy,
        .texture_write,
        .texture_query,
        .texture_destroy,
        .surface_create,
        .surface_capabilities,
        .surface_configure,
        .surface_acquire,
        .surface_unconfigure,
        .surface_release,
        .async_diagnostics,
        .map_async,
        => 0,
    };
}

const testing = std.testing;

test "selected submit count ignores barrier waits" {
    const result = NativeExecutionResult{
        .status = .ok,
        .status_message = "",
        .submit_wait_ns = 100,
    };
    try testing.expectEqual(@as(?u32, 0), selectedKindSubmitCount(.barrier, result));
}

test "selected submit count reports logical copy and upload work" {
    const result = NativeExecutionResult{
        .status = .ok,
        .status_message = "",
    };
    try testing.expectEqual(@as(?u32, 1), selectedKindSubmitCount(.copy_buffer_to_texture, result));
    try testing.expectEqual(@as(?u32, 1), selectedKindSubmitCount(.upload, result));
    try testing.expectEqual(@as(?u32, 1), selectedKindSubmitCount(.buffer_write, result));
}

test "selected submit count requires dispatch or draw work" {
    const no_work = NativeExecutionResult{
        .status = .ok,
        .status_message = "",
    };
    const work = NativeExecutionResult{
        .status = .ok,
        .status_message = "",
        .dispatch_count = 1,
    };
    try testing.expectEqual(@as(?u32, 0), selectedKindSubmitCount(.dispatch, no_work));
    try testing.expectEqual(@as(?u32, 1), selectedKindSubmitCount(.dispatch, work));
    try testing.expectEqual(@as(?u32, 0), selectedKindSubmitCount(.render_draw, no_work));
    try testing.expectEqual(@as(?u32, 1), selectedKindSubmitCount(.render_draw, work));
}

test "selected submit count does not claim failed commands" {
    const result = NativeExecutionResult{
        .status = .@"error",
        .status_message = "boom",
    };
    try testing.expectEqual(@as(?u32, null), selectedKindSubmitCount(.copy_buffer_to_texture, result));
}
