const std = @import("std");
const execution = @import("../execution.zig");
const quirk = @import("../../quirk/mod.zig");
const semantic_trace = @import("../../contracts/semantic.zig");
const trace = @import("trace.zig");

const ESTIMATED_TRACE_ROW_BYTES: usize = 768;
const ESTIMATED_PLAN_TRACE_ROW_BYTES: usize = 384;
const FILE_WRITE_BUFFER_BYTES: usize = 64 * 1024;
const COMPACT_UPLOAD_TRACE_FORMAT = "compact-upload-repeat-v1";
const COMPACT_UPLOAD_DURATION_ROWS_SUFFIX = ".execution-duration-rows.json";
const COMPACT_UPLOAD_HASH_TAG: u64 = 0xd0e0_c0ac_7a11_0001;
const COMPACT_UPLOAD_HASH_MIX: u64 = 0x9e37_79b9_7f4a_7c15;
const EXECUTION_STATUS_CODE_BYTES: usize = 256;
const ARTIFACT_PATH_BYTES: usize = 512;
const ARTIFACT_HASH_BYTES: usize = 64;

pub const WriteTiming = struct {
    serialize_ns: u64 = 0,
    write_ns: u64 = 0,
};

pub fn compactUploadTraceHash(row_total_ns: []const u64, previous_hash: u64) u64 {
    var hash = previous_hash ^ COMPACT_UPLOAD_HASH_TAG;
    hash = (hash *% COMPACT_UPLOAD_HASH_MIX) ^ @as(u64, row_total_ns.len);
    for (row_total_ns) |duration_ns| {
        hash = (hash *% COMPACT_UPLOAD_HASH_MIX) ^ duration_ns;
    }
    return hash;
}

pub const BufferedTraceRow = struct {
    seq: usize,
    command_label: []const u8,
    kernel_name: ?[]const u8,
    semantic: semantic_trace.SemanticContext,
    decision: quirk.runtime.DispatchDecision,
    timestamp_ns: u64,
    hash: u64,
    previous_hash: u64,
    execution_result: ?execution.ExecutionResult,
    execution_status_code_storage: [EXECUTION_STATUS_CODE_BYTES]u8 = undefined,
    execution_status_code_len: usize = 0,
    shader_manifest_path_storage: [ARTIFACT_PATH_BYTES]u8 = undefined,
    shader_manifest_path_len: usize = 0,
    shader_manifest_hash_storage: [ARTIFACT_HASH_BYTES]u8 = undefined,
    shader_manifest_hash_len: usize = 0,
    host_plan_path_storage: [ARTIFACT_PATH_BYTES]u8 = undefined,
    host_plan_path_len: usize = 0,
    host_plan_hash_storage: [ARTIFACT_HASH_BYTES]u8 = undefined,
    host_plan_hash_len: usize = 0,

    pub fn snapshotExecutionTelemetry(self: *BufferedTraceRow) !void {
        const exec = self.execution_result orelse return;
        self.execution_status_code_len = try snapshotText(
            &self.execution_status_code_storage,
            exec.status_code,
        );
        self.shader_manifest_path_len = try snapshotOptionalText(
            &self.shader_manifest_path_storage,
            exec.shader_artifact_manifest_path,
        );
        self.shader_manifest_hash_len = try snapshotOptionalText(
            &self.shader_manifest_hash_storage,
            exec.shader_artifact_manifest_hash,
        );
        self.host_plan_path_len = try snapshotOptionalText(
            &self.host_plan_path_storage,
            exec.host_plan_artifact_path,
        );
        self.host_plan_hash_len = try snapshotOptionalText(
            &self.host_plan_hash_storage,
            exec.host_plan_artifact_hash,
        );
    }

    fn reboundExecutionResult(self: *const BufferedTraceRow) ?execution.ExecutionResult {
        var exec = self.execution_result orelse return null;
        exec.status_code = self.execution_status_code_storage[0..self.execution_status_code_len];
        exec.shader_artifact_manifest_path = optionalSnapshot(
            &self.shader_manifest_path_storage,
            self.shader_manifest_path_len,
        );
        exec.shader_artifact_manifest_hash = optionalSnapshot(
            &self.shader_manifest_hash_storage,
            self.shader_manifest_hash_len,
        );
        exec.host_plan_artifact_path = optionalSnapshot(
            &self.host_plan_path_storage,
            self.host_plan_path_len,
        );
        exec.host_plan_artifact_hash = optionalSnapshot(
            &self.host_plan_hash_storage,
            self.host_plan_hash_len,
        );
        return exec;
    }
};

fn snapshotText(storage: []u8, value: []const u8) !usize {
    if (value.len > storage.len) return error.BufferedTraceFieldTooLong;
    @memcpy(storage[0..value.len], value);
    return value.len;
}

fn snapshotOptionalText(storage: []u8, value: ?[]const u8) !usize {
    return snapshotText(storage, value orelse return 0);
}

fn optionalSnapshot(storage: []const u8, len: usize) ?[]const u8 {
    if (len == 0) return null;
    return storage[0..len];
}

pub fn writeBufferedTraceRows(
    allocator: std.mem.Allocator,
    path: []const u8,
    rows: []const BufferedTraceRow,
) !WriteTiming {
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    var file_buffer: [FILE_WRITE_BUFFER_BYTES]u8 = undefined;
    var file_writer = file.writer(&file_buffer);
    var row_buffer = try std.ArrayList(u8).initCapacity(allocator, ESTIMATED_TRACE_ROW_BYTES);
    defer row_buffer.deinit(allocator);
    var timing = WriteTiming{};

    for (rows) |row| {
        row_buffer.clearRetainingCapacity();
        const serialize_start_ns = nowNs();
        try trace.printTraceLineWithSemantic(
            row_buffer.writer(allocator),
            row.seq,
            row.command_label,
            row.kernel_name,
            row.semantic,
            .{ .decision = row.decision },
            row.timestamp_ns,
            row.hash,
            row.previous_hash,
            row.reboundExecutionResult(),
        );
        timing.serialize_ns += elapsedSince(serialize_start_ns);
        const write_start_ns = nowNs();
        try file_writer.interface.writeAll(row_buffer.items);
        timing.write_ns += elapsedSince(write_start_ns);
    }
    const flush_start_ns = nowNs();
    try file_writer.end();
    timing.write_ns += elapsedSince(flush_start_ns);
    return timing;
}

pub fn writeBufferedPlanTraceRows(
    allocator: std.mem.Allocator,
    path: []const u8,
    module_name: []const u8,
    rows: []const BufferedTraceRow,
) !WriteTiming {
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    var file_buffer: [FILE_WRITE_BUFFER_BYTES]u8 = undefined;
    var file_writer = file.writer(&file_buffer);
    var row_buffer = try std.ArrayList(u8).initCapacity(allocator, ESTIMATED_PLAN_TRACE_ROW_BYTES);
    defer row_buffer.deinit(allocator);
    var timing = WriteTiming{};

    for (rows) |row| {
        row_buffer.clearRetainingCapacity();
        const serialize_start_ns = nowNs();
        try writePlanTraceRow(row_buffer.writer(allocator), module_name, row);
        timing.serialize_ns += elapsedSince(serialize_start_ns);
        const write_start_ns = nowNs();
        try file_writer.interface.writeAll(row_buffer.items);
        timing.write_ns += elapsedSince(write_start_ns);
    }
    const flush_start_ns = nowNs();
    try file_writer.end();
    timing.write_ns += elapsedSince(flush_start_ns);
    return timing;
}

pub fn writeCompactUploadTraceRows(
    allocator: std.mem.Allocator,
    path: []const u8,
    module_name: []const u8,
    row_total_ns: []const u64,
    row_hash: u64,
    previous_hash: u64,
) !WriteTiming {
    const duration_rows_path = try std.mem.concat(
        allocator,
        u8,
        &.{ path, COMPACT_UPLOAD_DURATION_ROWS_SUFFIX },
    );
    defer allocator.free(duration_rows_path);

    var timing = WriteTiming{};

    var sidecar_buffer = try std.ArrayList(u8).initCapacity(
        allocator,
        @max(@as(usize, 2), row_total_ns.len * 12),
    );
    defer sidecar_buffer.deinit(allocator);
    const sidecar_serialize_start_ns = nowNs();
    try sidecar_buffer.append(allocator, '[');
    for (row_total_ns, 0..) |duration_ns, index| {
        if (index > 0) try sidecar_buffer.append(allocator, ',');
        try sidecar_buffer.writer(allocator).print("{}", .{duration_ns});
    }
    try sidecar_buffer.appendSlice(allocator, "]\n");
    timing.serialize_ns += elapsedSince(sidecar_serialize_start_ns);

    const sidecar_file = try std.fs.cwd().createFile(duration_rows_path, .{ .truncate = true });
    defer sidecar_file.close();
    const sidecar_write_start_ns = nowNs();
    try sidecar_file.writeAll(sidecar_buffer.items);
    timing.write_ns += elapsedSince(sidecar_write_start_ns);

    var row_total_sum_ns: u64 = 0;
    var row_total_min_ns: u64 = 0;
    var row_total_max_ns: u64 = 0;
    if (row_total_ns.len > 0) {
        row_total_min_ns = row_total_ns[0];
        row_total_max_ns = row_total_ns[0];
        for (row_total_ns) |duration_ns| {
            row_total_sum_ns +|= duration_ns;
            row_total_min_ns = @min(row_total_min_ns, duration_ns);
            row_total_max_ns = @max(row_total_max_ns, duration_ns);
        }
    }

    var summary_row = try std.ArrayList(u8).initCapacity(allocator, ESTIMATED_PLAN_TRACE_ROW_BYTES);
    defer summary_row.deinit(allocator);
    const summary_serialize_start_ns = nowNs();
    const timestamp_ns = nowNs();
    const summary_writer = summary_row.writer(allocator);
    try summary_writer.writeAll("{\"traceVersion\":1,\"module\":");
    try trace.writeJsonString(summary_writer, module_name);
    try summary_writer.writeAll(",\"opCode\":\"upload\",\"seq\":0,\"timestampMonoNs\":");
    try summary_writer.print("{},\"hash\":\"0x{x}\",\"previousHash\":\"0x{x}\",\"command\":\"upload\"", .{
        timestamp_ns,
        row_hash,
        previous_hash,
    });
    try summary_writer.writeAll(",\"traceFormat\":");
    try trace.writeJsonString(summary_writer, COMPACT_UPLOAD_TRACE_FORMAT);
    try summary_writer.print(
        ",\"rowCount\":{},\"executionDurationRowCount\":{},\"executionDurationTotalNs\":{},\"executionDurationMinNs\":{},\"executionDurationMaxNs\":{},\"executionDurationRowsPath\":",
        .{
            row_total_ns.len,
            row_total_ns.len,
            row_total_sum_ns,
            row_total_min_ns,
            row_total_max_ns,
        },
    );
    try trace.writeJsonString(summary_writer, duration_rows_path);
    try summary_writer.writeAll("}\n");
    timing.serialize_ns += elapsedSince(summary_serialize_start_ns);

    const summary_file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer summary_file.close();
    const summary_write_start_ns = nowNs();
    try summary_file.writeAll(summary_row.items);
    timing.write_ns += elapsedSince(summary_write_start_ns);

    return timing;
}

fn writePlanTraceRow(
    writer: anytype,
    module_name: []const u8,
    row: BufferedTraceRow,
) !void {
    const exec = row.reboundExecutionResult() orelse return error.MissingExecutionResult;
    try writer.writeAll("{\"traceVersion\":1,\"module\":");
    try trace.writeJsonString(writer, module_name);
    try writer.writeAll(",\"opCode\":");
    try trace.writeJsonString(writer, row.command_label);
    try writer.print(
        ",\"seq\":{},\"timestampMonoNs\":{},\"hash\":\"0x{x}\",\"previousHash\":\"0x{x}\",\"command\":",
        .{ row.seq, row.timestamp_ns, row.hash, row.previous_hash },
    );
    try trace.writeJsonString(writer, row.command_label);

    if (row.kernel_name) |kernel_name| {
        try writer.writeAll(",\"kernel\":");
        try trace.writeJsonString(writer, kernel_name);
    }
    try writePlanSemanticFields(writer, row.semantic);
    try writePlanExecutionFields(writer, exec);
    try writer.writeAll("}\n");
}

fn writePlanSemanticFields(writer: anytype, semantic: semantic_trace.SemanticContext) !void {
    if (semantic.op_id) |value| {
        try writer.writeAll(",\"semanticOpId\":");
        try trace.writeJsonString(writer, value);
    }
    if (semantic.stage) |value| {
        try writer.writeAll(",\"semanticStage\":");
        try trace.writeJsonString(writer, value);
    }
    if (semantic.phase) |value| {
        try writer.writeAll(",\"semanticPhase\":");
        try trace.writeJsonString(writer, value);
    }
    if (semantic.token_index) |value| {
        try writer.print(",\"semanticTokenIndex\":{}", .{value});
    }
    if (semantic.layer_index) |value| {
        try writer.print(",\"semanticLayerIndex\":{}", .{value});
    }
    if (semantic.execution_plan_hash) |value| {
        try writer.writeAll(",\"semanticExecutionPlanHash\":");
        try trace.writeJsonString(writer, value);
    }
}

fn writePlanExecutionFields(writer: anytype, exec: execution.ExecutionResult) !void {
    const status_name = execution.executionStatusName(exec.status);
    const status_code = if (exec.status_code.len > 0) exec.status_code else status_name;
    try writer.writeAll(",\"executionBackend\":");
    try trace.writeJsonString(writer, exec.backend);
    try writer.writeAll(",\"backendId\":");
    try trace.writeJsonString(writer, exec.backend);
    if (exec.backend_lane) |value| {
        try writer.writeAll(",\"executionBackendLane\":");
        try trace.writeJsonString(writer, value);
    }
    try writer.writeAll(",\"executionStatus\":");
    try trace.writeJsonString(writer, status_name);
    try writer.writeAll(",\"executionStatusCode\":");
    try trace.writeJsonString(writer, status_code);
    try writer.writeAll(",\"executionStatusMessage\":");
    try trace.writeJsonString(writer, exec.status_code);
    try writer.print(
        ",\"executionDurationNs\":{},\"executionSetupNs\":{},\"executionEncodeNs\":{},\"executionSubmitWaitNs\":{},\"executionDispatchCount\":{},\"executionSubmitCount\":{},\"executionGpuTimestampNs\":{},\"executionGpuTimestampAttempted\":{},\"executionGpuTimestampValid\":{}",
        .{
            exec.duration_ns,
            exec.setup_ns,
            exec.encode_ns,
            exec.submit_wait_ns,
            exec.dispatch_count,
            exec.submit_count,
            exec.gpu_timestamp_ns,
            exec.gpu_timestamp_attempted,
            exec.gpu_timestamp_valid,
        },
    );
}

fn nowNs() u64 {
    return @as(u64, @intCast(std.time.nanoTimestamp()));
}

fn elapsedSince(start_ns: u64) u64 {
    return nowNs() - start_ns;
}

test "buffered trace row owns mutable execution telemetry" {
    var status_storage = [_]u8{ 's', 't', 'a', 't', 'u', 's' };
    var manifest_path_storage = [_]u8{ 'm', 'a', 'n', 'i', 'f', 'e', 's', 't' };
    var manifest_hash_storage = [_]u8{ 'a', 'b', 'c', 'd' };
    var row = BufferedTraceRow{
        .seq = 0,
        .command_label = "kernel_dispatch",
        .kernel_name = "kernel",
        .semantic = .{},
        .decision = .{},
        .timestamp_ns = 0,
        .hash = 0,
        .previous_hash = 0,
        .execution_result = .{
            .backend = "vulkan",
            .status = .executed,
            .status_code = &status_storage,
            .duration_ns = 0,
            .setup_ns = 0,
            .encode_ns = 0,
            .submit_wait_ns = 0,
            .dispatch_count = 1,
            .submit_count = 1,
            .gpu_timestamp_ns = 0,
            .gpu_timestamp_attempted = false,
            .gpu_timestamp_valid = false,
            .backend_selection_reason = null,
            .fallback_used = null,
            .selection_policy_hash = null,
            .shader_artifact_manifest_path = &manifest_path_storage,
            .shader_artifact_manifest_hash = &manifest_hash_storage,
            .host_plan_artifact_path = null,
            .host_plan_artifact_hash = null,
            .backend_lane = null,
            .adapter_ordinal = null,
            .queue_family_index = null,
            .present_capable = null,
        },
    };
    try row.snapshotExecutionTelemetry();

    @memset(&status_storage, 'x');
    @memset(&manifest_path_storage, 'y');
    @memset(&manifest_hash_storage, 'z');

    const rebound = row.reboundExecutionResult().?;
    try std.testing.expectEqualStrings("status", rebound.status_code);
    try std.testing.expectEqualStrings("manifest", rebound.shader_artifact_manifest_path.?);
    try std.testing.expectEqualStrings("abcd", rebound.shader_artifact_manifest_hash.?);
}
