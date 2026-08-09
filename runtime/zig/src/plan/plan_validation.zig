const std = @import("std");
const dawn_plan_types = @import("dawn_plan_types.zig");

pub const CommandCounts = struct {
    command_count: u32,
    buffer_write_count: u32,
    buffer_load_count: u32,
    dispatch_count: u32,
};

pub fn countCommands(plan: dawn_plan_types.Plan) CommandCounts {
    var counts = CommandCounts{
        .command_count = @intCast(plan.commands.len),
        .buffer_write_count = 0,
        .buffer_load_count = 0,
        .dispatch_count = 0,
    };
    for (plan.commands) |command| {
        switch (command) {
            .buffer_write => counts.buffer_write_count += 1,
            .buffer_load => counts.buffer_load_count += 1,
            .kernel_dispatch => counts.dispatch_count += 1,
        }
    }
    return counts;
}

pub fn validateCounts(plan: dawn_plan_types.Plan) !void {
    const actual = countCommands(plan);
    if (actual.command_count != plan.command_count or
        actual.buffer_write_count != plan.buffer_write_count or
        actual.buffer_load_count != plan.buffer_load_count or
        actual.dispatch_count != plan.dispatch_count)
    {
        return error.InvalidPlan;
    }
}

test "plan count validation accepts matching structural work" {
    const commands = [_]dawn_plan_types.Command{
        .{ .buffer_write = .{
            .handle = 1,
            .offset = 0,
            .buffer_size = 4,
            .data = &.{1},
        } },
        .{ .kernel_dispatch = .{
            .kernel = "kernel",
            .entry_point = "main",
            .x = 1,
            .y = 1,
            .z = 1,
            .initialize_buffers_on_create = false,
            .bindings = &.{},
        } },
    };
    const plan = testPlan(&commands, 2, 1, 0, 1);
    try validateCounts(plan);
}

test "plan count validation rejects a mismatched dispatch count" {
    const commands = [_]dawn_plan_types.Command{
        .{ .kernel_dispatch = .{
            .kernel = "kernel",
            .entry_point = "main",
            .x = 1,
            .y = 1,
            .z = 1,
            .initialize_buffers_on_create = false,
            .bindings = &.{},
        } },
    };
    const plan = testPlan(&commands, 1, 0, 0, 0);
    try std.testing.expectError(error.InvalidPlan, validateCounts(plan));
}

fn testPlan(
    commands: []const dawn_plan_types.Command,
    command_count: u32,
    buffer_write_count: u32,
    buffer_load_count: u32,
    dispatch_count: u32,
) dawn_plan_types.Plan {
    return .{
        .schema_version = 1,
        .plan_kind = "test",
        .workload_id = "test",
        .ir_path = "test",
        .ir_scenario = "test",
        .description = null,
        .plan_path = null,
        .commands_path = null,
        .command_count = command_count,
        .buffer_write_count = buffer_write_count,
        .buffer_load_count = buffer_load_count,
        .dispatch_count = dispatch_count,
        .source_ir_sha256 = "test",
        .compatibility_commands_sha256 = "test",
        .plan_sha256 = "test",
        .commands = commands,
    };
}
