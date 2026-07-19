const std = @import("std");
const model_commands = @import("../../contracts/model/model_commands.zig");
const model_gpu_types = @import("../../contracts/model/model_texture_value_types.zig");
const execution = @import("../execution.zig");
const main_print = @import("../../cli/entrypoints/main_print.zig");
const semantic_trace = @import("semantic_trace.zig");
const trace = @import("trace.zig");
const hash_utils = @import("../../backend/common/hash_utils.zig");

const model = struct {
    pub const Command = model_commands.Command;
    pub const WGPUWholeSize = model_gpu_types.WGPUWholeSize;
};

const MANIFEST_PATH_SUFFIX = ".operators.json";
const CAPTURE_SUFFIX = ".capture.bin";
const REPRO_COMMANDS_SUFFIX = ".repro.commands.json";
const REPRO_META_SUFFIX = ".repro.meta.json";
const MANIFEST_JSON_PREFIX = "[\n";
const MANIFEST_JSON_SUFFIX = "\n]\n";
const ESTIMATED_RECORD_BYTES: usize = 2048;

pub const Summary = struct {
    enabled: bool = false,
    row_count: u64 = 0,
    capture_count: u64 = 0,
    repro_count: u64 = 0,
    manifest_path: ?[]const u8 = null,
    manifest_hash: ?[]const u8 = null,
};

pub const RecordInput = struct {
    source_index: usize,
    command: model.Command,
    command_label: []const u8,
    kernel_name: ?[]const u8,
    semantic: semantic_trace.SemanticContext,
    capture: ?semantic_trace.CaptureRequest,
    execution_result: ?execution.ExecutionResult,
    profile_vendor: []const u8,
    profile_api: []const u8,
    profile_family: ?[]const u8,
    profile_driver: []const u8,
    trace_hash: ?u64 = null,
    trace_previous_hash: ?u64 = null,
    trace_meta_path: ?[]const u8 = null,
};

pub const Recorder = struct {
    allocator: std.mem.Allocator,
    anchor_path: ?[]u8 = null,
    manifest_path: ?[]u8 = null,
    manifest_hash: ?[]u8 = null,
    manifest_file: ?std.fs.File = null,
    manifest_hasher: ?std.crypto.hash.sha2.Sha256 = null,
    first_record: bool = true,
    row_count: u64 = 0,
    capture_count: u64 = 0,
    repro_count: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, anchor: ?[]const u8) !Recorder {
        if (anchor == null) {
            return .{
                .allocator = allocator,
            };
        }
        const owned_anchor = try allocator.dupe(u8, anchor.?);
        errdefer allocator.free(owned_anchor);
        const manifest_path = try std.mem.concat(allocator, u8, &.{ owned_anchor, MANIFEST_PATH_SUFFIX });
        errdefer allocator.free(manifest_path);
        const file = try std.fs.cwd().createFile(manifest_path, .{});
        errdefer file.close();
        var manifest_hasher = std.crypto.hash.sha2.Sha256.init(.{});
        manifest_hasher.update(MANIFEST_JSON_PREFIX);
        try file.writeAll(MANIFEST_JSON_PREFIX);
        return .{
            .allocator = allocator,
            .anchor_path = owned_anchor,
            .manifest_path = manifest_path,
            .manifest_file = file,
            .manifest_hasher = manifest_hasher,
        };
    }

    pub fn deinit(self: *Recorder) void {
        if (self.manifest_file) |file| {
            file.close();
            self.manifest_file = null;
        }
        if (self.anchor_path) |path| self.allocator.free(path);
        if (self.manifest_path) |path| self.allocator.free(path);
        if (self.manifest_hash) |value| self.allocator.free(value);
        self.anchor_path = null;
        self.manifest_path = null;
        self.manifest_hash = null;
    }

    pub fn enabled(self: *const Recorder) bool {
        return self.manifest_file != null;
    }

    pub fn finalize(self: *Recorder) !Summary {
        if (self.manifest_file) |file| {
            try file.writeAll(MANIFEST_JSON_SUFFIX);
            if (self.manifest_hasher) |*manifest_hasher| {
                manifest_hasher.update(MANIFEST_JSON_SUFFIX);
                var digest: [32]u8 = undefined;
                manifest_hasher.final(&digest);
                const hash = hash_utils.sha256_digest_hex(digest);
                self.manifest_hash = try self.allocator.dupe(u8, hash[0..]);
            }
            file.close();
            self.manifest_file = null;
            self.manifest_hasher = null;
        }
        return .{
            .enabled = self.row_count > 0,
            .row_count = self.row_count,
            .capture_count = self.capture_count,
            .repro_count = self.repro_count,
            .manifest_path = if (self.row_count > 0) self.manifest_path else null,
            .manifest_hash = if (self.row_count > 0) self.manifest_hash else null,
        };
    }

    pub fn record(
        self: *Recorder,
        maybe_execution_context: ?*execution.ExecutionContext,
        input: RecordInput,
    ) !void {
        if (!self.enabled()) return;
        if (!input.semantic.present()) return;

        const capture_result = try maybe_capture(self, maybe_execution_context, input);
        defer {
            if (capture_result.path) |value| self.allocator.free(value);
            if (capture_result.sha256) |value| self.allocator.free(value);
        }
        const repro_result = try emit_repro_bundle(self, input);
        defer {
            self.allocator.free(repro_result.commands_path);
            self.allocator.free(repro_result.meta_path);
        }

        const file = self.manifest_file.?;
        var shader_manifest_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer shader_manifest_arena.deinit();
        const shader_manifest = try load_shader_manifest_summary(shader_manifest_arena.allocator(), input.execution_result);

        var record_bytes = try std.ArrayList(u8).initCapacity(self.allocator, ESTIMATED_RECORD_BYTES);
        defer record_bytes.deinit(self.allocator);
        const writer = record_bytes.writer(self.allocator);

        if (!self.first_record) {
            try writer.writeAll(",\n");
        }
        self.first_record = false;

        try writer.writeAll("{\"schemaVersion\":1,\"sourceIndex\":");
        try writer.print("{}", .{input.source_index});
        try writer.writeAll(",\"command\":");
        try trace.writeJsonString(writer, input.command_label);
        if (input.kernel_name) |kernel_name| {
            try writer.writeAll(",\"kernel\":");
            try trace.writeJsonString(writer, kernel_name);
        }
        try write_semantic_fields(writer, input.semantic);
        try write_trace_refs(writer, input.trace_hash, input.trace_previous_hash, input.trace_meta_path);
        try write_profile_fields(writer, input.profile_vendor, input.profile_api, input.profile_family, input.profile_driver);
        try write_execution_fields(writer, input.execution_result);
        try write_command_shape(writer, input.command);
        try write_shader_manifest_fields(writer, shader_manifest);
        try write_capture_fields(writer, input.capture, capture_result);
        try write_repro_fields(writer, repro_result);
        try writer.writeAll("}");
        try file.writeAll(record_bytes.items);
        if (self.manifest_hasher) |*manifest_hasher| {
            manifest_hasher.update(record_bytes.items);
        }

        self.row_count += 1;
        if (capture_result.status == .ok) self.capture_count += 1;
        self.repro_count += 1;
    }
};

const CaptureStatus = enum {
    none,
    ok,
    unsupported,
    @"error",
};

const CaptureResult = struct {
    status: CaptureStatus = .none,
    path: ?[]u8 = null,
    sha256: ?[]u8 = null,
    error_code: ?[]const u8 = null,
};

const ReproResult = struct {
    commands_path: []u8,
    meta_path: []u8,
};

const ShaderManifestSummary = struct {
    manifest_path: ?[]const u8 = null,
    manifest_hash: ?[]const u8 = null,
    pipeline_hash: ?[]const u8 = null,
    wgsl_sha256: ?[]const u8 = null,
    ir_sha256: ?[]const u8 = null,
    backend_shader_field: ?[]const u8 = null,
    backend_shader_sha256: ?[]const u8 = null,
};

fn maybe_capture(
    self: *Recorder,
    maybe_execution_context: ?*execution.ExecutionContext,
    input: RecordInput,
) !CaptureResult {
    const request = input.capture orelse return .{};
    const execution_context = maybe_execution_context orelse {
        return .{ .status = .unsupported, .error_code = "capture_requires_native_execution" };
    };
    const bytes = execution_context.captureBuffer(self.allocator, request.buffer_handle, request.offset, request.size) catch |err| {
        return .{
            .status = if (err == error.UnsupportedFeature) .unsupported else .@"error",
            .error_code = @errorName(err),
        };
    };
    defer self.allocator.free(bytes);

    const capture_path = try op_path(self.allocator, self.anchor_path.?, input.source_index, CAPTURE_SUFFIX);
    errdefer self.allocator.free(capture_path);
    try write_file(capture_path, bytes);
    const capture_hash = hash_utils.sha256_hex(bytes);
    return .{
        .status = .ok,
        .path = capture_path,
        .sha256 = try self.allocator.dupe(u8, capture_hash[0..]),
    };
}

fn emit_repro_bundle(self: *Recorder, input: RecordInput) !ReproResult {
    const commands_path = try op_path(self.allocator, self.anchor_path.?, input.source_index, REPRO_COMMANDS_SUFFIX);
    errdefer self.allocator.free(commands_path);
    const meta_path = try op_path(self.allocator, self.anchor_path.?, input.source_index, REPRO_META_SUFFIX);
    errdefer self.allocator.free(meta_path);

    try write_repro_commands(commands_path, input.command, input.semantic, input.capture);
    try write_repro_meta(meta_path, input, commands_path);

    return .{
        .commands_path = commands_path,
        .meta_path = meta_path,
    };
}

fn write_semantic_fields(writer: anytype, semantic: semantic_trace.SemanticContext) !void {
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
        try writer.writeAll(",\"semanticTokenIndex\":");
        try writer.print("{}", .{value});
    }
    if (semantic.layer_index) |value| {
        try writer.writeAll(",\"semanticLayerIndex\":");
        try writer.print("{}", .{value});
    }
    if (semantic.execution_plan_hash) |value| {
        try writer.writeAll(",\"semanticExecutionPlanHash\":");
        try trace.writeJsonString(writer, value);
    }
}

fn write_trace_refs(
    writer: anytype,
    maybe_hash: ?u64,
    maybe_previous_hash: ?u64,
    trace_meta_path: ?[]const u8,
) !void {
    try writer.writeAll(",\"trace\":{");
    var wrote = false;
    if (maybe_hash) |hash| {
        try writer.writeAll("\"hash\":\"0x");
        try writer.print("{x}", .{hash});
        try writer.writeAll("\"");
        wrote = true;
    }
    if (maybe_previous_hash) |hash| {
        if (wrote) try writer.writeAll(",");
        try writer.writeAll("\"previousHash\":\"0x");
        try writer.print("{x}", .{hash});
        try writer.writeAll("\"");
        wrote = true;
    }
    if (trace_meta_path) |path| {
        if (wrote) try writer.writeAll(",");
        try writer.writeAll("\"traceMetaPath\":");
        try trace.writeJsonString(writer, path);
    }
    try writer.writeAll("}");
}

fn write_profile_fields(
    writer: anytype,
    vendor: []const u8,
    api: []const u8,
    family: ?[]const u8,
    driver: []const u8,
) !void {
    try writer.writeAll(",\"profile\":{\"vendor\":");
    try trace.writeJsonString(writer, vendor);
    try writer.writeAll(",\"api\":");
    try trace.writeJsonString(writer, api);
    try writer.writeAll(",\"deviceFamily\":");
    if (family) |value| {
        try trace.writeJsonString(writer, value);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"driver\":");
    try trace.writeJsonString(writer, driver);
    try writer.writeAll("}");
}

fn write_execution_fields(writer: anytype, maybe_execution: ?execution.ExecutionResult) !void {
    try writer.writeAll(",\"execution\":");
    if (maybe_execution == null) {
        try writer.writeAll("null");
        return;
    }
    const exec = maybe_execution.?;
    try writer.writeAll("{\"backend\":");
    try trace.writeJsonString(writer, exec.backend);
    try writer.writeAll(",\"status\":");
    try trace.writeJsonString(writer, execution.executionStatusName(exec.status));
    try writer.writeAll(",\"statusCode\":");
    try trace.writeJsonString(writer, exec.status_code);
    if (exec.backend_lane) |value| {
        try writer.writeAll(",\"backendLane\":");
        try trace.writeJsonString(writer, value);
    }
    if (exec.selection_policy_hash) |value| {
        try writer.writeAll(",\"selectionPolicyHash\":");
        try trace.writeJsonString(writer, value);
    }
    if (exec.shader_artifact_manifest_path) |value| {
        try writer.writeAll(",\"shaderArtifactManifestPath\":");
        try trace.writeJsonString(writer, value);
    }
    if (exec.shader_artifact_manifest_hash) |value| {
        try writer.writeAll(",\"shaderArtifactManifestHash\":");
        try trace.writeJsonString(writer, value);
    }
    if (exec.host_plan_artifact_path) |value| {
        try writer.writeAll(",\"hostPlanArtifactPath\":");
        try trace.writeJsonString(writer, value);
    }
    if (exec.host_plan_artifact_hash) |value| {
        try writer.writeAll(",\"hostPlanArtifactHash\":");
        try trace.writeJsonString(writer, value);
    }
    try writer.writeAll(",\"timings\":{\"durationNs\":");
    try writer.print("{}", .{exec.duration_ns});
    try writer.writeAll(",\"setupNs\":");
    try writer.print("{}", .{exec.setup_ns});
    try writer.writeAll(",\"encodeNs\":");
    try writer.print("{}", .{exec.encode_ns});
    try writer.writeAll(",\"submitWaitNs\":");
    try writer.print("{}", .{exec.submit_wait_ns});
    try writer.writeAll(",\"dispatchCount\":");
    try writer.print("{}", .{exec.dispatch_count});
    try writer.writeAll(",\"gpuTimestampNs\":");
    try writer.print("{}", .{exec.gpu_timestamp_ns});
    try writer.writeAll(",\"gpuTimestampAttempted\":");
    try writer.print("{}", .{exec.gpu_timestamp_attempted});
    try writer.writeAll(",\"gpuTimestampValid\":");
    try writer.print("{}", .{exec.gpu_timestamp_valid});
    try writer.writeAll("}");
    if (exec.adapter_ordinal) |value| {
        try writer.writeAll(",\"adapterOrdinal\":");
        try writer.print("{}", .{value});
    }
    if (exec.queue_family_index) |value| {
        try writer.writeAll(",\"queueFamilyIndex\":");
        try writer.print("{}", .{value});
    }
    if (exec.present_capable) |value| {
        try writer.writeAll(",\"presentCapable\":");
        try writer.print("{}", .{value});
    }
    try writer.writeAll("}");
}

fn write_command_shape(writer: anytype, command: model.Command) !void {
    try writer.writeAll(",\"commandShape\":{");
    switch (command) {
        .upload => |upload| {
            try writer.writeAll("\"uploadBytes\":");
            try writer.print("{}", .{upload.bytes});
        },
        .buffer_write => |buffer_write| {
            try writer.writeAll("\"bufferWriteHandle\":");
            try writer.print("{}", .{buffer_write.handle});
            try writer.writeAll(",\"bufferWriteWords\":");
            try writer.print("{}", .{buffer_write.data.len});
        },
        .copy_buffer_to_texture => |copy| {
            try writer.writeAll("\"copyBytes\":");
            try writer.print("{}", .{copy.bytes});
            try writer.writeAll(",\"srcHandle\":");
            try writer.print("{}", .{copy.src.handle});
            try writer.writeAll(",\"dstHandle\":");
            try writer.print("{}", .{copy.dst.handle});
        },
        .dispatch => |dispatch| {
            try write_dispatch_geometry(writer, dispatch.x, dispatch.y, dispatch.z, null);
        },
        .dispatch_indirect => |dispatch| {
            try write_dispatch_geometry(writer, dispatch.x, dispatch.y, dispatch.z, null);
        },
        .kernel_dispatch => |dispatch| {
            try write_dispatch_geometry(writer, dispatch.x, dispatch.y, dispatch.z, dispatch.repeat);
            if (dispatch.bindings) |bindings| {
                var total_buffer_bytes: u64 = 0;
                for (bindings) |binding| {
                    if (binding.resource_kind == .buffer and binding.buffer_size != model.WGPUWholeSize) {
                        total_buffer_bytes +|= binding.buffer_size;
                    }
                }
                try writer.writeAll(",\"bindingCount\":");
                try writer.print("{}", .{bindings.len});
                try writer.writeAll(",\"bindingBufferBytes\":");
                try writer.print("{}", .{total_buffer_bytes});
            }
        },
        .render_draw, .draw_indirect, .draw_indexed_indirect, .render_pass => |render| {
            try writer.writeAll("\"drawCount\":");
            try writer.print("{}", .{render.draw_count});
            try writer.writeAll(",\"vertexCount\":");
            try writer.print("{}", .{render.vertex_count});
            try writer.writeAll(",\"instanceCount\":");
            try writer.print("{}", .{render.instance_count});
            try writer.writeAll(",\"targetWidth\":");
            try writer.print("{}", .{render.target_width});
            try writer.writeAll(",\"targetHeight\":");
            try writer.print("{}", .{render.target_height});
        },
        else => {},
    }
    try writer.writeAll("}");
}

fn write_dispatch_geometry(writer: anytype, x: u32, y: u32, z: u32, repeat: ?u32) !void {
    try writer.writeAll("\"dispatchGeometry\":{\"x\":");
    try writer.print("{}", .{x});
    try writer.writeAll(",\"y\":");
    try writer.print("{}", .{y});
    try writer.writeAll(",\"z\":");
    try writer.print("{}", .{z});
    try writer.writeAll("}");
    if (repeat) |value| {
        try writer.writeAll(",\"repeat\":");
        try writer.print("{}", .{value});
    }
}

fn write_shader_manifest_fields(writer: anytype, summary: ShaderManifestSummary) !void {
    try writer.writeAll(",\"shaderArtifacts\":{");
    var wrote = false;
    if (summary.manifest_path) |value| {
        try writer.writeAll("\"manifestPath\":");
        try trace.writeJsonString(writer, value);
        wrote = true;
    }
    if (summary.manifest_hash) |value| {
        if (wrote) try writer.writeAll(",");
        try writer.writeAll("\"manifestHash\":");
        try trace.writeJsonString(writer, value);
        wrote = true;
    }
    if (summary.pipeline_hash) |value| {
        if (wrote) try writer.writeAll(",");
        try writer.writeAll("\"pipelineHash\":");
        try trace.writeJsonString(writer, value);
        wrote = true;
    }
    if (summary.wgsl_sha256) |value| {
        if (wrote) try writer.writeAll(",");
        try writer.writeAll("\"wgslSha256\":");
        try trace.writeJsonString(writer, value);
        wrote = true;
    }
    if (summary.ir_sha256) |value| {
        if (wrote) try writer.writeAll(",");
        try writer.writeAll("\"irSha256\":");
        try trace.writeJsonString(writer, value);
        wrote = true;
    }
    if (summary.backend_shader_field) |field| {
        if (summary.backend_shader_sha256) |value| {
            if (wrote) try writer.writeAll(",");
            try trace.writeJsonString(writer, field);
            try writer.writeAll(":");
            try trace.writeJsonString(writer, value);
        }
    }
    try writer.writeAll("}");
}

fn write_capture_fields(
    writer: anytype,
    request: ?semantic_trace.CaptureRequest,
    result: CaptureResult,
) !void {
    try writer.writeAll(",\"capture\":");
    if (request == null) {
        try writer.writeAll("null");
        return;
    }
    try writer.writeAll("{\"bufferHandle\":");
    try writer.print("{}", .{request.?.buffer_handle});
    try writer.writeAll(",\"offset\":");
    try writer.print("{}", .{request.?.offset});
    try writer.writeAll(",\"size\":");
    try writer.print("{}", .{request.?.size});
    try writer.writeAll(",\"status\":");
    try trace.writeJsonString(writer, @tagName(result.status));
    if (result.path) |value| {
        try writer.writeAll(",\"path\":");
        try trace.writeJsonString(writer, value);
    }
    if (result.sha256) |value| {
        try writer.writeAll(",\"sha256\":");
        try trace.writeJsonString(writer, value);
    }
    if (result.error_code) |value| {
        try writer.writeAll(",\"errorCode\":");
        try trace.writeJsonString(writer, value);
    }
    try writer.writeAll("}");
}

fn write_repro_fields(writer: anytype, result: ReproResult) !void {
    try writer.writeAll(",\"repro\":{");
    try writer.writeAll("\"commandsPath\":");
    try trace.writeJsonString(writer, result.commands_path);
    try writer.writeAll(",\"metaPath\":");
    try trace.writeJsonString(writer, result.meta_path);
    try writer.writeAll(",\"rerunMode\":\"structural_same_device_backend\",\"bitwise\":false}");
}

fn load_shader_manifest_summary(
    allocator: std.mem.Allocator,
    maybe_execution: ?execution.ExecutionResult,
) !ShaderManifestSummary {
    const exec = maybe_execution orelse return .{};
    const manifest_path = exec.shader_artifact_manifest_path orelse return .{};
    const bytes = try read_file_alloc(allocator, manifest_path);
    defer allocator.free(bytes);
    const Parsed = struct {
        pipelineHash: ?[]const u8 = null,
        wgslSha256: ?[]const u8 = null,
        irSha256: ?[]const u8 = null,
        spirvSha256: ?[]const u8 = null,
        mslSha256: ?[]const u8 = null,
        metallibSha256: ?[]const u8 = null,
        dxilSha256: ?[]const u8 = null,
    };
    const parsed = try std.json.parseFromSliceLeaky(Parsed, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    var backend_shader_field: ?[]const u8 = null;
    var backend_shader_sha256: ?[]const u8 = null;
    if (parsed.spirvSha256) |value| {
        backend_shader_field = "spirvSha256";
        backend_shader_sha256 = value;
    } else if (parsed.metallibSha256) |value| {
        backend_shader_field = "metallibSha256";
        backend_shader_sha256 = value;
    } else if (parsed.mslSha256) |value| {
        backend_shader_field = "mslSha256";
        backend_shader_sha256 = value;
    } else if (parsed.dxilSha256) |value| {
        backend_shader_field = "dxilSha256";
        backend_shader_sha256 = value;
    }
    return .{
        .manifest_path = manifest_path,
        .manifest_hash = exec.shader_artifact_manifest_hash,
        .pipeline_hash = parsed.pipelineHash,
        .wgsl_sha256 = parsed.wgslSha256,
        .ir_sha256 = parsed.irSha256,
        .backend_shader_field = backend_shader_field,
        .backend_shader_sha256 = backend_shader_sha256,
    };
}

fn write_repro_commands(
    path: []const u8,
    command: model.Command,
    semantic: semantic_trace.SemanticContext,
    capture: ?semantic_trace.CaptureRequest,
) !void {
    var list = try std.ArrayList(u8).initCapacity(std.heap.page_allocator, 0);
    defer list.deinit(std.heap.page_allocator);
    try main_print.printNormalizedCommand(list.writer(std.heap.page_allocator), 0, command);
    const base = std.mem.trimRight(u8, list.items, "\n\r\t ");
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    var writer = file.deprecatedWriter();
    try writer.writeAll("[\n");
    if ((semantic.present() or capture != null) and base.len > 0 and base[base.len - 1] == '}') {
        try writer.writeAll(base[0 .. base.len - 1]);
        try append_semantic_extras(writer, semantic);
        if (capture) |request| {
            try writer.writeAll(",\"captureBufferHandle\":");
            try writer.print("{}", .{request.buffer_handle});
            try writer.writeAll(",\"captureOffset\":");
            try writer.print("{}", .{request.offset});
            try writer.writeAll(",\"captureSize\":");
            try writer.print("{}", .{request.size});
        }
        try writer.writeAll("}\n");
    } else {
        try writer.writeAll(base);
        try writer.writeAll("\n");
    }
    try writer.writeAll("]\n");
}

fn append_semantic_extras(writer: anytype, semantic: semantic_trace.SemanticContext) !void {
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
        try writer.writeAll(",\"semanticTokenIndex\":");
        try writer.print("{}", .{value});
    }
    if (semantic.layer_index) |value| {
        try writer.writeAll(",\"semanticLayerIndex\":");
        try writer.print("{}", .{value});
    }
    if (semantic.execution_plan_hash) |value| {
        try writer.writeAll(",\"semanticExecutionPlanHash\":");
        try trace.writeJsonString(writer, value);
    }
}

fn write_repro_meta(path: []const u8, input: RecordInput, commands_path: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    var writer = file.deprecatedWriter();
    try writer.writeAll("{\"schemaVersion\":1,\"reproMode\":\"structural_same_device_backend\",\"bitwise\":false,\"commandsPath\":");
    try trace.writeJsonString(writer, commands_path);
    try writer.writeAll(",\"command\":");
    try trace.writeJsonString(writer, input.command_label);
    if (input.kernel_name) |kernel_name| {
        try writer.writeAll(",\"kernel\":");
        try trace.writeJsonString(writer, kernel_name);
    }
    try write_semantic_fields(writer, input.semantic);
    try write_profile_fields(writer, input.profile_vendor, input.profile_api, input.profile_family, input.profile_driver);
    try write_execution_fields(writer, input.execution_result);
    try write_command_shape(writer, input.command);
    try writer.writeAll("}");
}

fn op_path(allocator: std.mem.Allocator, anchor: []const u8, index: usize, suffix: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}.op{d:0>4}{s}", .{ anchor, index, suffix });
}

fn write_file(path: []const u8, bytes: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(bytes);
}

fn read_file_alloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, 16 * 1024 * 1024);
}
