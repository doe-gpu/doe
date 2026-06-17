const std = @import("std");
const execution = @import("../execution.zig");
const main_usage = @import("../main_usage.zig");
const quirk = @import("../quirk/mod.zig");
const trace = @import("../trace.zig");

pub const RunOptions = struct {
    quirks_path: ?[]const u8 = null,
    commands_path: ?[]const u8 = null,
    quirk_mode: quirk.QuirkMode = .trace,
    profile_vendor: []const u8 = "intel",
    profile_api: []const u8 = "vulkan",
    profile_family: ?[]const u8 = "gen12",
    profile_driver: []const u8 = "31.0.101",
    emit_trace: bool = false,
    emit_trace_jsonl: ?[]const u8 = null,
    emit_normalized: bool = false,
    trace_meta_path: ?[]const u8 = null,
    numeric_stability_policy_path: ?[]const u8 = null,
    numeric_stability_execution_profile_id: ?[]const u8 = null,
    replay_path: ?[]const u8 = null,
    execute: bool = false,
    backend_mode: execution.BackendMode = .trace,
    backend_lane_value: ?[]const u8 = null,
    kernel_root: ?[]const u8 = null,
    // When true, skip Apple Metal MTLBinaryArchive cache initialization at
    // backend startup. Use for fair-cold Doe-vs-Dawn comparisons of cached
    // kernels (the Dawn delegate path has no equivalent cache; see
    // runtime/zig/src/backend/metal/metal_native_runtime.zig:380-402 and
    // bench/lib/metal_pipeline_cache_manifest.py for context).
    no_pipeline_cache: bool = false,
    /// Optional override for the pipeline-cache directory. Empty slice means
    /// "no disk-backed persistence"; runtime stays in-memory for the process.
    /// Respected on platforms where Doe operates a persistent pipeline cache
    /// (Vulkan today; Metal's MTLBinaryArchive has its own path).
    pipeline_cache_dir: []const u8 = "",
    command_repeat: u32 = 1,
    upload_buffer_usage_mode: execution.UploadBufferUsageMode = .copy_dst_copy_src,
    upload_submit_every: u32 = 1,
    gpu_timestamp_mode: execution.GpuTimestampMode = .auto,
    queue_wait_mode: execution.QueueWaitMode = .process_events,
    webgpu_ffi_queue_wait_timeout_ns: u64 = execution.DEFAULT_WEBGPU_FFI_QUEUE_WAIT_TIMEOUT_NS,
    queue_sync_mode: execution.QueueSyncMode = .per_command,
};

pub const ParseOutcome = union(enum) {
    run: RunOptions,
    exit_requested,
};

fn printUsage(stdout: anytype) !void {
    try main_usage.printUsage(stdout);
}

const OPTIONS_WITH_VALUE = [_][]const u8{
    "--quirks",
    "--commands",
    "--command-repeat",
    "--quirk-mode",
    "--vendor",
    "--api",
    "--family",
    "--driver",
    "--trace-jsonl",
    "--trace-meta",
    "--numeric-stability-policy",
    "--numeric-stability-execution-profile",
    "--kernel-root",
    "--backend",
    "--backend-lane",
    "--upload-buffer-usage",
    "--upload-submit-every",
    "--gpu-timestamp-mode",
    "--queue-wait-mode",
    "--webgpu-ffi-queue-wait-timeout-ns",
    "--queue-sync-mode",
    "--pipeline-cache-dir",
    "--replay",
};

fn optionExpectsValue(option: []const u8) bool {
    for (OPTIONS_WITH_VALUE) |name| {
        if (std.mem.eql(u8, option, name)) return true;
    }
    return false;
}

pub fn parseArgs(argv: [][:0]u8, stdout: anytype) !ParseOutcome {
    var options = RunOptions{};
    var i: usize = 1;
    while (i < argv.len) {
        if (std.mem.eql(u8, argv[i], "--quirks") and i + 1 < argv.len) {
            i += 1;
            options.quirks_path = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--commands") and i + 1 < argv.len) {
            i += 1;
            options.commands_path = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--quirk-mode") and i + 1 < argv.len) {
            i += 1;
            if (quirk.QuirkMode.parse(argv[i])) |mode| {
                options.quirk_mode = mode;
            } else {
                try trace.writef(stdout, "invalid --quirk-mode value: {s} (expected off|trace|active)\n", .{argv[i]});
                return .exit_requested;
            }
        } else if (std.mem.eql(u8, argv[i], "--vendor") and i + 1 < argv.len) {
            i += 1;
            options.profile_vendor = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--api") and i + 1 < argv.len) {
            i += 1;
            options.profile_api = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--family") and i + 1 < argv.len) {
            i += 1;
            options.profile_family = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--driver") and i + 1 < argv.len) {
            i += 1;
            options.profile_driver = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--trace")) {
            options.emit_trace = true;
        } else if (std.mem.eql(u8, argv[i], "--trace-jsonl") and i + 1 < argv.len) {
            i += 1;
            options.emit_trace_jsonl = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--emit-normalized")) {
            options.emit_normalized = true;
        } else if (std.mem.eql(u8, argv[i], "--trace-meta") and i + 1 < argv.len) {
            i += 1;
            options.trace_meta_path = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--numeric-stability-policy") and i + 1 < argv.len) {
            i += 1;
            options.numeric_stability_policy_path = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--numeric-stability-execution-profile") and i + 1 < argv.len) {
            i += 1;
            options.numeric_stability_execution_profile_id = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--kernel-root") and i + 1 < argv.len) {
            i += 1;
            options.kernel_root = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--backend") and i + 1 < argv.len) {
            i += 1;
            if (execution.parseBackend(argv[i])) |mode| {
                options.backend_mode = mode;
            } else {
                try trace.writef(stdout, "invalid --backend value: {s}\n", .{argv[i]});
                return .exit_requested;
            }
        } else if (std.mem.eql(u8, argv[i], "--backend-lane") and i + 1 < argv.len) {
            i += 1;
            options.backend_lane_value = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--command-repeat") and i + 1 < argv.len) {
            i += 1;
            const parsed = std.fmt.parseInt(u32, argv[i], 10) catch {
                try trace.writef(stdout, "invalid --command-repeat value: {s}\n", .{argv[i]});
                return .exit_requested;
            };
            if (parsed == 0) {
                try trace.writef(stdout, "invalid --command-repeat value: must be >= 1\n", .{});
                return .exit_requested;
            }
            options.command_repeat = parsed;
        } else if (std.mem.eql(u8, argv[i], "--upload-buffer-usage") and i + 1 < argv.len) {
            i += 1;
            if (execution.parseUploadBufferUsage(argv[i])) |mode| {
                options.upload_buffer_usage_mode = mode;
            } else {
                try trace.writef(
                    stdout,
                    "invalid --upload-buffer-usage value: {s} (expected copy-dst-copy-src|copy-dst)\n",
                    .{argv[i]},
                );
                return .exit_requested;
            }
        } else if (std.mem.eql(u8, argv[i], "--upload-submit-every") and i + 1 < argv.len) {
            i += 1;
            const parsed = std.fmt.parseInt(u32, argv[i], 10) catch {
                try trace.writef(stdout, "invalid --upload-submit-every value: {s}\n", .{argv[i]});
                return .exit_requested;
            };
            if (parsed == 0) {
                try trace.writef(stdout, "invalid --upload-submit-every value: must be >= 1\n", .{});
                return .exit_requested;
            }
            options.upload_submit_every = parsed;
        } else if (std.mem.eql(u8, argv[i], "--gpu-timestamp-mode") and i + 1 < argv.len) {
            i += 1;
            if (execution.parseGpuTimestampMode(argv[i])) |mode| {
                options.gpu_timestamp_mode = mode;
            } else {
                try trace.writef(
                    stdout,
                    "invalid --gpu-timestamp-mode value: {s} (expected auto|off|require)\n",
                    .{argv[i]},
                );
                return .exit_requested;
            }
        } else if (std.mem.eql(u8, argv[i], "--queue-wait-mode") and i + 1 < argv.len) {
            i += 1;
            if (execution.parseQueueWaitMode(argv[i])) |mode| {
                options.queue_wait_mode = mode;
            } else {
                try trace.writef(
                    stdout,
                    "invalid --queue-wait-mode value: {s} (expected process-events|wait-any)\n",
                    .{argv[i]},
                );
                return .exit_requested;
            }
        } else if (std.mem.eql(u8, argv[i], "--webgpu-ffi-queue-wait-timeout-ns") and i + 1 < argv.len) {
            i += 1;
            const parsed = std.fmt.parseUnsigned(u64, argv[i], 10) catch {
                try trace.writef(stdout, "invalid --webgpu-ffi-queue-wait-timeout-ns value: {s}\n", .{argv[i]});
                return .exit_requested;
            };
            if (parsed == 0) {
                try trace.writef(stdout, "invalid --webgpu-ffi-queue-wait-timeout-ns value: must be >= 1\n", .{});
                return .exit_requested;
            }
            options.webgpu_ffi_queue_wait_timeout_ns = parsed;
        } else if (std.mem.eql(u8, argv[i], "--queue-sync-mode") and i + 1 < argv.len) {
            i += 1;
            if (execution.parseQueueSyncMode(argv[i])) |mode| {
                options.queue_sync_mode = mode;
            } else {
                try trace.writef(
                    stdout,
                    "invalid --queue-sync-mode value: {s} (expected per-command|deferred)\n",
                    .{argv[i]},
                );
                return .exit_requested;
            }
        } else if (std.mem.eql(u8, argv[i], "--execute")) {
            options.execute = true;
        } else if (std.mem.eql(u8, argv[i], "--no-pipeline-cache")) {
            options.no_pipeline_cache = true;
        } else if (std.mem.eql(u8, argv[i], "--pipeline-cache-dir") and i + 1 < argv.len) {
            i += 1;
            options.pipeline_cache_dir = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--replay") and i + 1 < argv.len) {
            i += 1;
            options.replay_path = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--help")) {
            try printUsage(stdout);
            return .exit_requested;
        } else if (optionExpectsValue(argv[i])) {
            try trace.writef(stdout, "missing value for option: {s}\n", .{argv[i]});
            try printUsage(stdout);
            return .exit_requested;
        } else if (std.mem.startsWith(u8, argv[i], "--")) {
            try trace.writef(stdout, "unknown option: {s}\n", .{argv[i]});
            try printUsage(stdout);
            return .exit_requested;
        } else {
            try trace.writef(stdout, "unexpected positional argument: {s}\n", .{argv[i]});
            try printUsage(stdout);
            return .exit_requested;
        }
        i += 1;
    }
    return .{ .run = options };
}
