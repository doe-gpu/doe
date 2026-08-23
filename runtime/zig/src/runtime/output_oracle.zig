const std = @import("std");
const backend_contract = @import("../contracts/backend.zig");
const model_commands = @import("../contracts/command.zig");
const model_compute_types = @import("../contracts/model/model_compute_types.zig");
const model_profile = @import("../contracts/model/model_profile.zig");
const execution = @import("execution.zig");

pub const Evidence = struct {
    count: u64 = 0,
    matched_count: u64 = 0,
    failed_count: u64 = 0,
    expected_sha256: ?[]const u8 = null,
    actual_sha256: [64]u8 = [_]u8{'0'} ** 64,
    has_actual_sha256: bool = false,
    reference_id: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    reference_class: ?[]const u8 = null,
    reference_sha256: ?[]const u8 = null,
    reference_path: ?[]const u8 = null,
    compared_value_count: u64 = 0,
    mismatch_count: u64 = 0,
    max_absolute_error: f64 = 0,
    max_relative_error: f64 = 0,
    absolute_tolerance: f64 = 0,
    relative_tolerance: f64 = 0,
};

pub const ValidationOptions = struct {
    upload_buffer_usage_mode: execution.UploadBufferUsageMode,
    upload_submit_every: u32,
    queue_wait_mode: execution.QueueWaitMode,
    webgpu_ffi_queue_wait_timeout_ns: u64,
};

const Float32ToleranceResult = struct {
    compared_value_count: u64,
    mismatch_count: u64,
    max_absolute_error: f64,
    max_relative_error: f64,
};

fn referenceClassName(
    reference_class: model_compute_types.KernelDispatchOutputOracleReferenceClass,
) []const u8 {
    return switch (reference_class) {
        .independent => "independent_v1",
        .cross_runtime_consensus => "cross_runtime_consensus_v1",
    };
}

fn compareFloat32Reference(
    actual: []const u8,
    reference: []const u8,
    absolute_tolerance: f32,
    relative_tolerance: f32,
) !Float32ToleranceResult {
    if (actual.len != reference.len or actual.len % @sizeOf(f32) != 0) {
        return error.OutputOracleReferenceSizeMismatch;
    }
    var result = Float32ToleranceResult{
        .compared_value_count = @intCast(actual.len / @sizeOf(f32)),
        .mismatch_count = 0,
        .max_absolute_error = 0,
        .max_relative_error = 0,
    };
    var offset: usize = 0;
    while (offset < actual.len) : (offset += @sizeOf(f32)) {
        const actual_bits = std.mem.readInt(u32, actual[offset..][0..4], .little);
        const reference_bits = std.mem.readInt(u32, reference[offset..][0..4], .little);
        const actual_value: f32 = @bitCast(actual_bits);
        const reference_value: f32 = @bitCast(reference_bits);
        if (!std.math.isFinite(actual_value) or !std.math.isFinite(reference_value)) {
            result.mismatch_count += 1;
            continue;
        }
        const actual_f64: f64 = actual_value;
        const reference_f64: f64 = reference_value;
        const absolute_error = @abs(actual_f64 - reference_f64);
        const reference_magnitude = @abs(reference_f64);
        const relative_error = if (reference_magnitude > 0)
            absolute_error / reference_magnitude
        else
            absolute_error;
        result.max_absolute_error = @max(result.max_absolute_error, absolute_error);
        result.max_relative_error = @max(result.max_relative_error, relative_error);
        const allowed_error = @as(f64, absolute_tolerance) +
            @as(f64, relative_tolerance) * reference_magnitude;
        if (absolute_error > allowed_error) result.mismatch_count += 1;
    }
    return result;
}

fn prewarmKernelDispatches(
    context: *execution.ExecutionContext,
    commands: []const model_commands.Command,
) void {
    for (commands) |command| {
        switch (command) {
            .kernel_dispatch => |dispatch| {
                context.prewarmKernelDispatch(
                    dispatch.kernel,
                    dispatch.entry_point,
                    dispatch.bindings,
                    dispatch.initialize_buffers_on_create,
                ) catch |err| {
                    std.debug.print("warn: output_oracle: kernel dispatch prewarm: {s}\n", .{@errorName(err)});
                };
            },
            else => {},
        }
    }
}

pub fn validate(
    comptime Session: type,
    allocator: std.mem.Allocator,
    commands: []const model_commands.Command,
    profile: model_profile.DeviceProfile,
    kernel_root: ?[]const u8,
    backend_lane: backend_contract.BackendLane,
    options: ValidationOptions,
) !Evidence {
    var evidence = Evidence{};
    var command_graph_session: ?Session = null;
    var command_graph_context: ?*execution.ExecutionContext = null;
    defer if (command_graph_session) |*session| session.deinit();

    const has_command_graph_oracle = for (commands) |command| {
        switch (command) {
            .kernel_dispatch => |dispatch| {
                if (dispatch.output_oracle) |oracle| {
                    if (oracle.scope == .command_graph) break true;
                }
            },
            else => {},
        }
    } else false;
    if (has_command_graph_oracle) {
        command_graph_session = try Session.init(
            allocator,
            .native,
            profile,
            kernel_root,
            backend_lane,
            .{},
        );
        command_graph_context = command_graph_session.?.contextPtr();
        const context = command_graph_context.?;
        context.configureUploadBehavior(options.upload_buffer_usage_mode, options.upload_submit_every);
        context.configureGpuTimestampMode(.off);
        context.configureQueueWaitMode(options.queue_wait_mode);
        context.configureWebgpuFfiQueueWaitTimeoutNs(options.webgpu_ffi_queue_wait_timeout_ns);
        context.configureQueueSyncMode(.per_command);
        prewarmKernelDispatches(context, commands);
    }

    for (commands) |command| {
        const original = switch (command) {
            .kernel_dispatch => |dispatch| dispatch,
            else => {
                if (command_graph_context) |context| {
                    const result = try context.execute(command);
                    if (result.status != .ok) return error.OutputOracleExecutionFailed;
                }
                continue;
            },
        };
        const oracle = original.output_oracle orelse {
            if (command_graph_context) |context| {
                const result = try context.execute(command);
                if (result.status != .ok) return error.OutputOracleExecutionFailed;
            }
            continue;
        };
        if (oracle.scope == .command_graph and oracle.dispatch_count != original.repeat) {
            return error.OutputOracleDispatchCountMismatch;
        }
        evidence.count += 1;
        evidence.expected_sha256 = oracle.expected_sha256;
        evidence.reference_id = oracle.reference_id;
        evidence.kind = oracle.kind;
        evidence.reference_class = referenceClassName(oracle.reference_class);
        evidence.reference_path = oracle.reference_path;
        evidence.absolute_tolerance = oracle.absolute_tolerance;
        evidence.relative_tolerance = oracle.relative_tolerance;

        const bindings = original.bindings orelse return error.OutputOracleBindingMissing;
        var target_binding: ?@TypeOf(bindings[0]) = null;
        for (bindings) |binding| {
            if (binding.group == oracle.binding_group and
                binding.binding == oracle.binding and
                binding.resource_kind == .buffer)
            {
                target_binding = binding;
                break;
            }
        }
        const binding = target_binding orelse return error.OutputOracleBindingMissing;
        if (binding.buffer_size == 0 or binding.buffer_size == std.math.maxInt(u64)) {
            return error.OutputOracleBufferSizeInvalid;
        }

        var isolated_session: ?Session = null;
        defer if (isolated_session) |*session| session.deinit();
        const oracle_context = switch (oracle.scope) {
            .isolated_dispatch => blk: {
                isolated_session = try Session.init(
                    allocator,
                    .native,
                    profile,
                    kernel_root,
                    backend_lane,
                    .{},
                );
                const context = isolated_session.?.contextPtr();
                context.configureUploadBehavior(options.upload_buffer_usage_mode, options.upload_submit_every);
                context.configureGpuTimestampMode(.off);
                context.configureQueueWaitMode(options.queue_wait_mode);
                context.configureWebgpuFfiQueueWaitTimeoutNs(options.webgpu_ffi_queue_wait_timeout_ns);
                context.configureQueueSyncMode(.per_command);
                try context.prewarmKernelDispatch(
                    original.kernel,
                    original.entry_point,
                    original.bindings,
                    true,
                );
                break :blk context;
            },
            .command_graph => command_graph_context.?,
        };

        var oracle_dispatch = original;
        if (oracle.scope == .isolated_dispatch) {
            oracle_dispatch.repeat = oracle.dispatch_count;
            oracle_dispatch.warmup_dispatch_count = 0;
            oracle_dispatch.initialize_buffers_on_create = true;
        }
        oracle_dispatch.output_oracle = null;
        const result = try oracle_context.execute(.{ .kernel_dispatch = oracle_dispatch });
        if (result.status != .ok) return error.OutputOracleExecutionFailed;
        _ = try oracle_context.flushQueue();
        const bytes = try oracle_context.captureBuffer(
            allocator,
            binding.resource_handle,
            binding.buffer_offset,
            binding.buffer_size,
        );
        defer allocator.free(bytes);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        evidence.actual_sha256 = std.fmt.bytesToHex(digest, .lower);
        evidence.has_actual_sha256 = true;
        const oracle_matches = if (std.mem.eql(u8, oracle.kind, "sha256_exact_v1"))
            std.mem.eql(u8, oracle.expected_sha256, evidence.actual_sha256[0..])
        else blk: {
            const reference_path = oracle.reference_path orelse
                return error.OutputOracleReferencePathMissing;
            const reference = try std.fs.cwd().readFileAlloc(
                allocator,
                reference_path,
                @intCast(binding.buffer_size),
            );
            defer allocator.free(reference);
            var reference_digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(reference, &reference_digest, .{});
            const reference_sha256 = std.fmt.bytesToHex(reference_digest, .lower);
            if (!std.mem.eql(u8, oracle.expected_sha256, reference_sha256[0..])) {
                return error.OutputOracleReferenceHashMismatch;
            }
            evidence.reference_sha256 = oracle.expected_sha256;
            const comparison = try compareFloat32Reference(
                bytes,
                reference,
                oracle.absolute_tolerance,
                oracle.relative_tolerance,
            );
            evidence.compared_value_count = comparison.compared_value_count;
            evidence.mismatch_count = comparison.mismatch_count;
            evidence.max_absolute_error = comparison.max_absolute_error;
            evidence.max_relative_error = comparison.max_relative_error;
            break :blk comparison.mismatch_count == 0;
        };
        if (oracle_matches) {
            evidence.matched_count += 1;
        } else {
            evidence.failed_count += 1;
        }
        if (oracle.scope == .isolated_dispatch) {
            if (command_graph_context) |context| {
                const graph_result = try context.execute(command);
                if (graph_result.status != .ok) return error.OutputOracleExecutionFailed;
            }
        }
    }
    return evidence;
}

test "float32 reference comparison accepts values inside mixed tolerance" {
    const reference_values = [_]f32{ 0, 1, -4, 1000 };
    const actual_values = [_]f32{ 0.0000005, 1.000005, -4.00002, 1000.005 };
    const reference = std.mem.sliceAsBytes(reference_values[0..]);
    const actual = std.mem.sliceAsBytes(actual_values[0..]);
    const result = try compareFloat32Reference(actual, reference, 0.000001, 0.00001);
    try std.testing.expectEqual(@as(u64, reference_values.len), result.compared_value_count);
    try std.testing.expectEqual(@as(u64, 0), result.mismatch_count);
}

test "float32 reference comparison rejects non-finite and out-of-range values" {
    const reference_values = [_]f32{ 1, 2 };
    const actual_values = [_]f32{ 1.1, std.math.nan(f32) };
    const reference = std.mem.sliceAsBytes(reference_values[0..]);
    const actual = std.mem.sliceAsBytes(actual_values[0..]);
    const result = try compareFloat32Reference(actual, reference, 0.000001, 0.00001);
    try std.testing.expectEqual(@as(u64, 2), result.mismatch_count);
}
