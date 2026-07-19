const std = @import("std");
const builtin = @import("builtin");
const model_profile = @import("model_profile.zig");
const backend_runtime = @import("backend/backend_runtime.zig");
const runtime_types = @import("backend/runtime_types.zig");

const Config = struct {
    iterations: u32 = 8,
    byte_count: usize = 2 * 1024 * 1024,
    inject_corruption: bool = false,
};

const Correctness = struct {
    oracleId: []const u8 = "metal/staged-write-exact-bytes-v2",
    expectedOutcomeSatisfied: bool,
    observedContentMatchesExpected: bool,
    mismatchedBytes: u64,
    firstMismatchByte: ?u64,
    deferredSubmitWaitNs: u64,
    everyFlushCompleted: bool,
};

const Timing = struct {
    class: []const u8 = "diagnostic",
    wallNs: u64,
    writeSetupNs: u64,
    flushNs: u64,
    captureNs: u64,
};

const Artifact = struct {
    schemaVersion: u32 = 1,
    artifactKind: []const u8 = "doe_correctness_benchmark",
    workloadId: []const u8 = "metal_staged_write_exact_bytes",
    backend: []const u8 = "apple-metal",
    status: []const u8,
    iterations: u32,
    bytesPerIteration: usize,
    totalBytes: u64,
    faultInjection: bool,
    performanceClaimEligible: bool = false,
    correctness: Correctness,
    timing: Timing,
};

fn deviceProfile() model_profile.DeviceProfile {
    return .{
        .vendor = "apple",
        .api = .metal,
        .device_family = "m3",
        .driver_version = .{ .major = 1, .minor = 0, .patch = 0 },
    };
}

fn parsePositive(comptime T: type, value: []const u8) !T {
    const parsed = try std.fmt.parseUnsigned(T, value, 10);
    if (parsed == 0) return error.InvalidArgument;
    return parsed;
}

fn parseArgs(allocator: std.mem.Allocator) !Config {
    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    var config = Config{};
    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--inject-corruption")) {
            config.inject_corruption = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--iterations")) {
            index += 1;
            if (index >= argv.len) return error.MissingArgument;
            config.iterations = try parsePositive(u32, argv[index]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--bytes")) {
            index += 1;
            if (index >= argv.len) return error.MissingArgument;
            config.byte_count = try parsePositive(usize, argv[index]);
            continue;
        }
        return error.UnknownArgument;
    }
    if (config.iterations > 128 or config.byte_count > 64 * 1024 * 1024) {
        return error.InvalidArgument;
    }
    return config;
}

fn fillExpected(bytes: []u8, iteration: u32) void {
    const iteration_salt: usize = @as(usize, iteration) *% 17;
    for (bytes, 0..) |*byte, index| {
        byte.* = @truncate((index *% 131) ^ (index >> 7) ^ iteration_salt ^ 0x5a);
    }
}

fn writeArtifact(artifact: Artifact) !void {
    var payload_writer: std.io.Writer.Allocating = .init(std.heap.page_allocator);
    defer payload_writer.deinit();
    try std.json.Stringify.value(
        artifact,
        .{ .whitespace = .indent_2 },
        &payload_writer.writer,
    );
    const payload = try payload_writer.toOwnedSlice();
    defer std.heap.page_allocator.free(payload);
    const stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.writeAll(payload);
    try stdout.writeByte('\n');
}

fn run(allocator: std.mem.Allocator, config: Config) !u8 {
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;

    var runtime = try backend_runtime.BackendRuntime.init(
        allocator,
        deviceProfile(),
        null,
        .metal_doe_comparable,
    );
    defer runtime.deinit();

    runtime.set_upload_behavior(.copy_dst, 1);
    runtime.set_queue_sync_mode(.deferred);

    var wall_timer = try std.time.Timer.start();
    var write_setup_ns: u64 = 0;
    var flush_ns: u64 = 0;
    var capture_ns: u64 = 0;
    var deferred_submit_wait_ns: u64 = 0;
    var mismatched_bytes: u64 = 0;
    var first_mismatch_byte: ?u64 = null;
    var every_flush_completed = true;

    for (0..config.iterations) |iteration_raw| {
        const iteration: u32 = @intCast(iteration_raw);
        const handle: u64 = 4101 + iteration;
        const expected = try allocator.alloc(u8, config.byte_count);
        defer allocator.free(expected);
        fillExpected(expected, iteration);

        const write_result = try runtime.execute_buffer_write_bytes(
            handle,
            0,
            config.byte_count,
            expected,
        );
        if (write_result.status != runtime_types.NativeExecutionStatus.ok) {
            return error.WriteFailed;
        }
        write_setup_ns +|= write_result.setup_ns;
        deferred_submit_wait_ns +|= write_result.submit_wait_ns;
        const completed_flush_ns = try runtime.flush_queue();
        flush_ns +|= completed_flush_ns;
        every_flush_completed = every_flush_completed and completed_flush_ns > 0;

        if (config.inject_corruption and iteration == 0) {
            var corrupt = [_]u8{expected[0] ^ 0xff};
            const corrupt_result = try runtime.execute_buffer_write_bytes(
                handle,
                0,
                config.byte_count,
                corrupt[0..],
            );
            if (corrupt_result.status != runtime_types.NativeExecutionStatus.ok) {
                return error.WriteFailed;
            }
            write_setup_ns +|= corrupt_result.setup_ns;
            deferred_submit_wait_ns +|= corrupt_result.submit_wait_ns;
            const corrupt_flush_ns = try runtime.flush_queue();
            flush_ns +|= corrupt_flush_ns;
            every_flush_completed = every_flush_completed and corrupt_flush_ns > 0;
        }

        var capture_timer = try std.time.Timer.start();
        const actual = try runtime.capture_buffer(allocator, handle, 0, config.byte_count);
        capture_ns +|= capture_timer.read();
        defer allocator.free(actual);

        for (expected, actual, 0..) |expected_byte, actual_byte, byte_index| {
            if (expected_byte == actual_byte) continue;
            mismatched_bytes +|= 1;
            if (first_mismatch_byte == null) {
                first_mismatch_byte = @as(u64, iteration) * config.byte_count + byte_index;
            }
        }
    }

    const observed_matches = mismatched_bytes == 0;
    const content_outcome_satisfied = if (config.inject_corruption)
        !observed_matches
    else
        observed_matches;
    const outcome_satisfied = content_outcome_satisfied and
        deferred_submit_wait_ns == 0 and every_flush_completed;
    const artifact = Artifact{
        .status = if (outcome_satisfied)
            (if (config.inject_corruption) "oracle_rejected_corruption" else "pass")
        else
            "fail",
        .iterations = config.iterations,
        .bytesPerIteration = config.byte_count,
        .totalBytes = @as(u64, config.iterations) * config.byte_count,
        .faultInjection = config.inject_corruption,
        .correctness = .{
            .expectedOutcomeSatisfied = outcome_satisfied,
            .observedContentMatchesExpected = observed_matches,
            .mismatchedBytes = mismatched_bytes,
            .firstMismatchByte = first_mismatch_byte,
            .deferredSubmitWaitNs = deferred_submit_wait_ns,
            .everyFlushCompleted = every_flush_completed,
        },
        .timing = .{
            .wallNs = wall_timer.read(),
            .writeSetupNs = write_setup_ns,
            .flushNs = flush_ns,
            .captureNs = capture_ns,
        },
    };
    try writeArtifact(artifact);

    if (!outcome_satisfied) return 3;
    return if (config.inject_corruption) 2 else 0;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const exit_code = try run(gpa.allocator(), try parseArgs(gpa.allocator()));
    if (exit_code != 0) std.process.exit(exit_code);
}
