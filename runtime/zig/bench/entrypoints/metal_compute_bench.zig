const std = @import("std");
const builtin = @import("builtin");
const doe = @import("doe");
const model_profile = doe.contracts.model.profile();
const model_commands = doe.contracts.model.commands();
const model_compute_types = doe.contracts.model.computeTypes();
const execution = doe.runtime.execution();

const KERNEL_ROOT = "../../bench/kernels";
const KERNEL_NAME = "concurrent_execution_runsingle_u32";
const BUFFER_HANDLE_BASE: u64 = 7201;
const WORD_COUNT: usize = 1024;
const WORD_COUNT_U32: u32 = 1024;
const ITERATION_COUNT: u32 = 1_000_000;
const BUFFER_BYTES: u64 = WORD_COUNT * @sizeOf(u32);

const Config = struct {
    iterations: u32 = 3,
    inject_corruption: bool = false,
};

const Correctness = struct {
    oracleId: []const u8 = "metal/compute-exact-output-v1",
    expectedOutcomeSatisfied: bool,
    observedContentMatchesExpected: bool,
    mismatchedBytes: u64,
    firstMismatchByte: ?u64,
    dispatchCount: u32,
    everyDispatchCompleted: bool,
    everySubmitWaitCompleted: bool,
};

const Timing = struct {
    class: []const u8 = "diagnostic",
    wallNs: u64,
    writeSetupNs: u64,
    dispatchSetupNs: u64,
    dispatchEncodeNs: u64,
    dispatchSubmitWaitNs: u64,
    captureNs: u64,
};

const Artifact = struct {
    schemaVersion: u32 = 1,
    artifactKind: []const u8 = "doe_correctness_benchmark",
    workloadId: []const u8 = "metal_compute_exact_output",
    backend: []const u8 = "apple-metal",
    status: []const u8,
    iterations: u32,
    wordsPerIteration: usize = WORD_COUNT,
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
            config.iterations = try std.fmt.parseUnsigned(u32, argv[index], 10);
            if (config.iterations == 0 or config.iterations > 16) {
                return error.InvalidArgument;
            }
            continue;
        }
        return error.UnknownArgument;
    }
    return config;
}

fn makeInput(iteration: u32) [WORD_COUNT]u32 {
    var data: [WORD_COUNT]u32 = undefined;
    for (&data, 0..) |*value, index| {
        value.* = @as(u32, @intCast(index)) +% (iteration *% 257);
    }
    return data;
}

fn expectedFirstWord(input: []const u32) u32 {
    var threadgroup_words: [WORD_COUNT]u32 = undefined;
    @memcpy(threadgroup_words[0..input.len], input);

    var accum = input[0];
    var index: u32 = 0;
    while (index < ITERATION_COUNT) : (index += 1) {
        const word_index: usize = @intCast((index +% accum) % WORD_COUNT_U32);
        accum = (accum ^ threadgroup_words[word_index]) +% 123;
    }
    return accum;
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

    var session = try doe.composition.ExecutionSession.init(
        allocator,
        .native,
        deviceProfile(),
        KERNEL_ROOT,
        .metal_doe_comparable,
        .{},
    );
    defer session.deinit();
    const runtime = session.contextPtr();

    runtime.configureUploadBehavior(.copy_dst, 1);
    runtime.configureQueueSyncMode(.per_command);

    var wall_timer = try std.time.Timer.start();
    var write_setup_ns: u64 = 0;
    var dispatch_setup_ns: u64 = 0;
    var dispatch_encode_ns: u64 = 0;
    var dispatch_submit_wait_ns: u64 = 0;
    var capture_ns: u64 = 0;
    var dispatch_count: u32 = 0;
    var mismatched_bytes: u64 = 0;
    var first_mismatch_byte: ?u64 = null;
    var every_dispatch_completed = true;
    var every_submit_wait_completed = true;

    for (0..config.iterations) |iteration_raw| {
        const iteration: u32 = @intCast(iteration_raw);
        const handle = BUFFER_HANDLE_BASE + iteration;
        var input = makeInput(iteration);
        var expected = input;
        expected[0] = expectedFirstWord(input[0..]);
        const input_bytes = std.mem.sliceAsBytes(input[0..]);
        const expected_bytes = std.mem.sliceAsBytes(expected[0..]);

        const write_result = try runtime.execute_buffer_write_bytes_with_semantic(
            handle,
            0,
            BUFFER_BYTES,
            input_bytes,
            .{},
        );
        if (write_result.status != execution.ExecutionStatus.ok) {
            return error.WriteFailed;
        }
        write_setup_ns +|= write_result.setup_ns;
        every_submit_wait_completed = every_submit_wait_completed and
            write_result.submit_wait_ns > 0;

        const bindings = [_]model_compute_types.KernelBinding{.{
            .binding = 0,
            .resource_kind = .buffer,
            .resource_handle = handle,
            .buffer_size = BUFFER_BYTES,
        }};
        const dispatch_result = try runtime.execute(model_commands.Command{ .kernel_dispatch = .{
            .kernel = KERNEL_NAME,
            .x = 1,
            .y = 1,
            .z = 1,
            .bindings = bindings[0..],
        } });
        if (dispatch_result.status != execution.ExecutionStatus.ok) {
            return error.DispatchFailed;
        }
        dispatch_setup_ns +|= dispatch_result.setup_ns;
        dispatch_encode_ns +|= dispatch_result.encode_ns;
        dispatch_submit_wait_ns +|= dispatch_result.submit_wait_ns;
        dispatch_count +|= dispatch_result.dispatch_count;
        every_dispatch_completed = every_dispatch_completed and
            dispatch_result.dispatch_count == 1;
        every_submit_wait_completed = every_submit_wait_completed and
            dispatch_result.submit_wait_ns > 0;

        if (config.inject_corruption and iteration == 0) {
            var corrupt = [_]u8{expected_bytes[@sizeOf(u32)] ^ 0xff};
            const corrupt_result = try runtime.execute_buffer_write_bytes_with_semantic(
                handle,
                @sizeOf(u32),
                BUFFER_BYTES,
                corrupt[0..],
                .{},
            );
            if (corrupt_result.status != execution.ExecutionStatus.ok) {
                return error.WriteFailed;
            }
            write_setup_ns +|= corrupt_result.setup_ns;
            every_submit_wait_completed = every_submit_wait_completed and
                corrupt_result.submit_wait_ns > 0;
        }

        var capture_timer = try std.time.Timer.start();
        const actual = try runtime.captureBuffer(allocator, handle, 0, BUFFER_BYTES);
        capture_ns +|= capture_timer.read();
        defer allocator.free(actual);

        for (expected_bytes, actual, 0..) |expected_byte, actual_byte, byte_index| {
            if (expected_byte == actual_byte) continue;
            mismatched_bytes +|= 1;
            if (first_mismatch_byte == null) {
                first_mismatch_byte = @as(u64, iteration) * BUFFER_BYTES + byte_index;
            }
        }
    }

    const observed_matches = mismatched_bytes == 0;
    const content_outcome_satisfied = if (config.inject_corruption)
        !observed_matches
    else
        observed_matches;
    const outcome_satisfied = content_outcome_satisfied and
        every_dispatch_completed and every_submit_wait_completed and
        dispatch_count == config.iterations;
    const artifact = Artifact{
        .status = if (outcome_satisfied)
            (if (config.inject_corruption) "oracle_rejected_corruption" else "pass")
        else
            "fail",
        .iterations = config.iterations,
        .totalBytes = @as(u64, config.iterations) * BUFFER_BYTES,
        .faultInjection = config.inject_corruption,
        .correctness = .{
            .expectedOutcomeSatisfied = outcome_satisfied,
            .observedContentMatchesExpected = observed_matches,
            .mismatchedBytes = mismatched_bytes,
            .firstMismatchByte = first_mismatch_byte,
            .dispatchCount = dispatch_count,
            .everyDispatchCompleted = every_dispatch_completed,
            .everySubmitWaitCompleted = every_submit_wait_completed,
        },
        .timing = .{
            .wallNs = wall_timer.read(),
            .writeSetupNs = write_setup_ns,
            .dispatchSetupNs = dispatch_setup_ns,
            .dispatchEncodeNs = dispatch_encode_ns,
            .dispatchSubmitWaitNs = dispatch_submit_wait_ns,
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
