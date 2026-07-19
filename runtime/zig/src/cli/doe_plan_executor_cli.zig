const std = @import("std");
const execution = @import("../runtime/execution.zig");
const doe_plan_executor = @import("../plan/doe_plan_executor.zig");

const Allocator = std.mem.Allocator;

pub const RunOptions = doe_plan_executor.RunOptions;
pub const CliRunFn = *const fn (Allocator, RunOptions) anyerror!void;

const OPTIONS_WITH_VALUE = [_][]const u8{
    "--plan",
    "--trace-meta",
    "--trace-jsonl",
    "--workload",
    "--vendor",
    "--api",
    "--family",
    "--driver",
    "--kernel-root",
    "--backend-lane",
    "--gpu-timestamp-mode",
    "--queue-wait-mode",
    "--queue-sync-mode",
    "--upload-buffer-usage",
    "--upload-submit-every",
};

fn optionExpectsValue(option: []const u8) bool {
    for (OPTIONS_WITH_VALUE) |name| {
        if (std.mem.eql(u8, option, name)) return true;
    }
    return false;
}

fn parseArgs(allocator: Allocator) !RunOptions {
    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    var options = RunOptions{
        .plan_path = "",
        .trace_meta_path = "",
        .trace_jsonl_path = "",
        .workload_id = "",
    };

    var idx: usize = 1;
    while (idx < argv.len) : (idx += 1) {
        const arg = argv[idx];
        if (std.mem.eql(u8, arg, "--dry-run")) {
            options.dry_run = true;
            continue;
        }
        if (!optionExpectsValue(arg)) return error.InvalidCommandLine;
        if (idx + 1 >= argv.len) return error.InvalidCommandLine;
        idx += 1;
        const value = argv[idx];
        if (std.mem.eql(u8, arg, "--plan")) {
            options.plan_path = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--trace-meta")) {
            options.trace_meta_path = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--trace-jsonl")) {
            options.trace_jsonl_path = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--workload")) {
            options.workload_id = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--vendor")) {
            options.vendor = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--api")) {
            options.api = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--family")) {
            options.family = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--driver")) {
            options.driver = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--kernel-root")) {
            options.kernel_root = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--backend-lane")) {
            options.backend_lane = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--gpu-timestamp-mode")) {
            options.gpu_timestamp_mode = execution.parseGpuTimestampMode(value) orelse return error.InvalidCommandLine;
        } else if (std.mem.eql(u8, arg, "--queue-wait-mode")) {
            options.queue_wait_mode = execution.parseQueueWaitMode(value) orelse return error.InvalidCommandLine;
        } else if (std.mem.eql(u8, arg, "--queue-sync-mode")) {
            options.queue_sync_mode = execution.parseQueueSyncMode(value) orelse return error.InvalidCommandLine;
        } else if (std.mem.eql(u8, arg, "--upload-buffer-usage")) {
            options.upload_buffer_usage_mode = execution.parseUploadBufferUsage(value) orelse return error.InvalidCommandLine;
        } else if (std.mem.eql(u8, arg, "--upload-submit-every")) {
            options.upload_submit_every = std.fmt.parseUnsigned(u32, value, 10) catch return error.InvalidCommandLine;
            if (options.upload_submit_every == 0) return error.InvalidCommandLine;
        }
    }

    if (options.plan_path.len == 0 or options.trace_meta_path.len == 0 or options.trace_jsonl_path.len == 0 or options.workload_id.len == 0) {
        return error.MissingField;
    }
    return options;
}

pub fn runCli(run_fn: CliRunFn) !void {
    const allocator = std.heap.page_allocator;
    const options = try parseArgs(allocator);
    try run_fn(allocator, options);
}
