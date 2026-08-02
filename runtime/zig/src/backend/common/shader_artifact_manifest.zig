const std = @import("std");
const artifact_meta = @import("artifact_meta.zig");
const artifact_state = @import("artifact_state.zig");
const common_errors = @import("errors.zig");
const hash_utils = @import("hash_utils.zig");

const SHADER_ARTIFACT_DIR = "bench/out/shader-artifacts";
const SHADER_TOOLCHAIN_PATH = "config/shader-toolchain.json";
const MAX_TOOLCHAIN_BYTES: usize = 64 * 1024;
const HASH_INPUT_CAPACITY: usize = 512;
const TAXONOMY_CODE_CAPACITY: usize = 128;
const ZERO_HASH = "0000000000000000000000000000000000000000000000000000000000000000";

pub const StageImplementation = enum {
    native_zig,
    external_tool,

    pub fn name(self: StageImplementation) []const u8 {
        return switch (self) {
            .native_zig => "native_zig",
            .external_tool => "external_tool",
        };
    }
};

pub const StageDescriptor = struct {
    stage: []const u8,
    hash_label: []const u8,
    manifest_field: ?[]const u8 = null,
    implementation: StageImplementation = .native_zig,
    tool: ?[]const u8 = null,
    version: ?[]const u8 = null,
    args: []const []const u8 = &.{},
};

pub const ManifestSpec = struct {
    backend_id: []const u8,
    file_prefix: []const u8,
    stages: []const StageDescriptor,
};

/// Runtime-side payload associated with a stage: when the backend has the
/// real compiled artifact bytes (e.g. a SPIR-V module), the manifest emitter
/// writes them to a sibling file and records the path on the matching stage
/// record so downstream gates (`shader_artifact_gate.py --require-spirv-validation`)
/// can run spirv-val against the binary.
pub const StageArtifact = struct {
    manifest_field: []const u8,
    bytes: []const u8,
    extension: []const u8,
};

pub fn manifest_path(self: anytype) ?[]const u8 {
    if (self.manifest_path_len == 0) return null;
    return self.manifest_path_storage[0..self.manifest_path_len];
}

pub fn manifest_hash(self: anytype) ?[]const u8 {
    if (self.manifest_hash_len == 0) return null;
    return self.manifest_hash_storage[0..self.manifest_hash_len];
}

pub fn flush_pending_artifact(self: anytype, spec: ManifestSpec) void {
    if (!self.pending_artifact_write) return;
    self.pending_artifact_write = false;
    const status_code = self.pending_artifact_status_storage[0..self.pending_artifact_status_len];
    if (artifact_state.manifest_signature_matches(
        self.last_manifest_meta,
        self.last_manifest_module_storage[0..self.last_manifest_module_len],
        self.last_manifest_status_storage[0..self.last_manifest_status_len],
        self.pending_artifact_module,
        self.pending_artifact_meta,
        status_code,
    )) {
        release_pending_backend_spirv_bytes(self);
        return;
    }
    var pending_artifacts_buf: [1]StageArtifact = undefined;
    const pending_artifacts = collect_pending_stage_artifacts(self, &pending_artifacts_buf);
    emit_shader_artifact_manifest_for_signature_with_artifacts(
        self,
        spec,
        self.pending_artifact_module,
        self.pending_artifact_meta,
        status_code,
        pending_artifacts,
    ) catch {};
    release_pending_backend_spirv_bytes(self);
}

pub fn emit_shader_artifact_manifest_for_signature(
    self: anytype,
    spec: ManifestSpec,
    module: []const u8,
    meta: artifact_meta.ArtifactMeta,
    status_code: []const u8,
) common_errors.BackendNativeError!void {
    return emit_shader_artifact_manifest_for_signature_with_artifacts(
        self,
        spec,
        module,
        meta,
        status_code,
        &.{},
    );
}

fn collect_pending_stage_artifacts(self: anytype, buffer: *[1]StageArtifact) []const StageArtifact {
    if (!@hasDecl(@TypeOf(self.*), "pending_spirv_bytes_view")) return &.{};
    const bytes = self.pending_spirv_bytes_view() orelse return &.{};
    if (bytes.len == 0) return &.{};
    buffer[0] = .{ .manifest_field = "spirvSha256", .bytes = bytes, .extension = ".spv" };
    return buffer[0..1];
}

fn release_pending_backend_spirv_bytes(self: anytype) void {
    if (!@hasDecl(@TypeOf(self.*), "release_pending_spirv_bytes")) return;
    self.release_pending_spirv_bytes();
}

pub fn emit_shader_artifact_manifest_for_signature_with_artifacts(
    self: anytype,
    spec: ManifestSpec,
    module: []const u8,
    meta: artifact_meta.ArtifactMeta,
    status_code: []const u8,
    stage_artifacts: []const StageArtifact,
) common_errors.BackendNativeError!void {
    self.manifest_emit_count +|= 1;

    const toolchain_hash = load_toolchain_sha256(self.allocator) catch return common_errors.BackendNativeError.ShaderCompileFailed;

    var taxonomy_buffer: [TAXONOMY_CODE_CAPACITY]u8 = undefined;
    const taxonomy_code = normalize_taxonomy_code(&taxonomy_buffer, status_code);
    const wgsl_hash = if (@hasDecl(@TypeOf(self.*), "shader_source_hash_for_module"))
        self.shader_source_hash_for_module(module) orelse hash_utils.sha256_hex(module)
    else
        hash_utils.sha256_hex(module);

    std.fs.cwd().makePath(SHADER_ARTIFACT_DIR) catch return common_errors.BackendNativeError.ShaderCompileFailed;

    const stage_artifact_paths = write_stage_artifact_blobs(
        self.allocator,
        spec,
        stage_artifacts,
    ) catch return common_errors.BackendNativeError.ShaderCompileFailed;
    defer free_stage_artifact_paths(self.allocator, stage_artifact_paths);

    const stage_hashes = derive_stage_hashes(
        self.allocator,
        spec.stages,
        wgsl_hash,
        stage_artifact_paths,
    ) catch {
        return common_errors.BackendNativeError.ShaderCompileFailed;
    };
    defer self.allocator.free(stage_hashes);

    const pipeline_stage_hash = if (stage_hashes.len > 0)
        stage_hashes[stage_hashes.len - 1][0..]
    else
        wgsl_hash[0..];

    var pipeline_seed_buffer: [HASH_INPUT_CAPACITY]u8 = undefined;
    const pipeline_seed = std.fmt.bufPrint(
        &pipeline_seed_buffer,
        "{s}|{s}|{s}|{s}|{s}|{s}|{}",
        .{
            spec.backend_id,
            module,
            pipeline_stage_hash,
            taxonomy_code,
            meta.backend_kind.name(),
            meta.timing_source.name(),
            meta.is_claimable(),
        },
    ) catch return common_errors.BackendNativeError.ShaderCompileFailed;

    const pipeline_hash = hash_utils.sha256_hex(pipeline_seed);
    const stages_json = build_stages_json(
        self.allocator,
        spec.stages,
        wgsl_hash,
        stage_hashes,
        stage_artifact_paths,
    ) catch {
        return common_errors.BackendNativeError.ShaderCompileFailed;
    };
    defer self.allocator.free(stages_json);

    const prehash = build_prehash_json(
        self.allocator,
        spec,
        module,
        meta,
        taxonomy_code,
        previous_manifest_hash(self),
        toolchain_hash,
        pipeline_hash,
        wgsl_hash,
        stage_hashes,
        stages_json,
    ) catch return common_errors.BackendNativeError.ShaderCompileFailed;
    defer self.allocator.free(prehash);

    const hash = hash_utils.sha256_hex(prehash);
    const content = std.fmt.allocPrint(
        self.allocator,
        "{s},\"hash\":\"{s}\"}}\n",
        .{
            prehash[0 .. prehash.len - 1],
            hash[0..],
        },
    ) catch return common_errors.BackendNativeError.ShaderCompileFailed;
    defer self.allocator.free(content);

    var path_buffer: [256]u8 = undefined;
    const path = std.fmt.bufPrint(
        &path_buffer,
        "{s}/{s}_shader_artifact_{s}.json",
        .{ SHADER_ARTIFACT_DIR, spec.file_prefix, hash[0..] },
    ) catch return common_errors.BackendNativeError.ShaderCompileFailed;

    const file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch return common_errors.BackendNativeError.ShaderCompileFailed;
    defer file.close();
    file.writeAll(content) catch return common_errors.BackendNativeError.ShaderCompileFailed;

    artifact_state.persist_value(self.manifest_path_storage[0..], &self.manifest_path_len, path);
    artifact_state.persist_value(self.manifest_hash_storage[0..], &self.manifest_hash_len, hash[0..]);
    artifact_state.persist_manifest_signature(
        &self.last_manifest_meta,
        self.last_manifest_module_storage[0..],
        &self.last_manifest_module_len,
        self.last_manifest_status_storage[0..],
        &self.last_manifest_status_len,
        module,
        meta,
        status_code,
    );
}

fn previous_manifest_hash(self: anytype) []const u8 {
    return manifest_hash(self) orelse ZERO_HASH;
}

fn derive_stage_hash(seed: []const u8, label: []const u8) [hash_utils.SHA256_HEX_SIZE]u8 {
    var buffer: [HASH_INPUT_CAPACITY]u8 = undefined;
    const input = std.fmt.bufPrint(&buffer, "{s}|{s}", .{ seed, label }) catch label;
    return hash_utils.sha256_hex(input);
}

fn derive_stage_hashes(
    allocator: std.mem.Allocator,
    stages: []const StageDescriptor,
    wgsl_hash: [hash_utils.SHA256_HEX_SIZE]u8,
    stage_artifact_paths: []const StageArtifactPath,
) ![][hash_utils.SHA256_HEX_SIZE]u8 {
    const hashes = try allocator.alloc([hash_utils.SHA256_HEX_SIZE]u8, stages.len);
    var previous = wgsl_hash;
    for (stages, 0..) |stage, index| {
        hashes[index] = lookup_artifact_hash(stage, stage_artifact_paths) orelse
            derive_stage_hash(previous[0..], stage.hash_label);
        previous = hashes[index];
    }
    return hashes;
}

const StageArtifactPath = struct {
    manifest_field: []const u8,
    filename: []u8,
    artifact_hash: [hash_utils.SHA256_HEX_SIZE]u8,
};

fn write_stage_artifact_blobs(
    allocator: std.mem.Allocator,
    spec: ManifestSpec,
    stage_artifacts: []const StageArtifact,
) ![]StageArtifactPath {
    if (stage_artifacts.len == 0) return allocator.alloc(StageArtifactPath, 0);
    var out = try allocator.alloc(StageArtifactPath, stage_artifacts.len);
    var written: usize = 0;
    errdefer {
        for (out[0..written]) |entry| allocator.free(entry.filename);
        allocator.free(out);
    }
    for (stage_artifacts) |artifact| {
        const artifact_hash = hash_utils.sha256_hex(artifact.bytes);
        const filename = try std.fmt.allocPrint(
            allocator,
            "{s}_shader_artifact_{s}{s}",
            .{ spec.file_prefix, artifact_hash[0..], artifact.extension },
        );
        errdefer allocator.free(filename);
        const full_path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}",
            .{ SHADER_ARTIFACT_DIR, filename },
        );
        defer allocator.free(full_path);
        const file = try std.fs.cwd().createFile(full_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(artifact.bytes);
        out[written] = .{
            .manifest_field = artifact.manifest_field,
            .filename = filename,
            .artifact_hash = artifact_hash,
        };
        written += 1;
    }
    return out;
}

fn free_stage_artifact_paths(allocator: std.mem.Allocator, paths: []StageArtifactPath) void {
    for (paths) |entry| allocator.free(entry.filename);
    allocator.free(paths);
}

fn lookup_artifact_path(
    stage: StageDescriptor,
    stage_artifact_paths: []const StageArtifactPath,
) ?[]const u8 {
    const field = stage.manifest_field orelse return null;
    for (stage_artifact_paths) |entry| {
        if (std.mem.eql(u8, entry.manifest_field, field)) return entry.filename;
    }
    return null;
}

fn lookup_artifact_hash(
    stage: StageDescriptor,
    stage_artifact_paths: []const StageArtifactPath,
) ?[hash_utils.SHA256_HEX_SIZE]u8 {
    const field = stage.manifest_field orelse return null;
    for (stage_artifact_paths) |entry| {
        if (std.mem.eql(u8, entry.manifest_field, field)) return entry.artifact_hash;
    }
    return null;
}

fn build_stages_json(
    allocator: std.mem.Allocator,
    stages: []const StageDescriptor,
    wgsl_hash: [hash_utils.SHA256_HEX_SIZE]u8,
    stage_hashes: []const [hash_utils.SHA256_HEX_SIZE]u8,
    stage_artifact_paths: []const StageArtifactPath,
) ![]u8 {
    var list = try std.ArrayList(u8).initCapacity(allocator, 0);
    errdefer list.deinit(allocator);
    const writer = list.writer(allocator);

    try writer.writeByte('[');
    try write_stage_json(writer, .{
        .stage = "wgsl_parse",
        .hash_label = "wgsl_parse",
    }, wgsl_hash, null);
    for (stages, 0..) |stage, index| {
        try writer.writeByte(',');
        try write_stage_json(writer, stage, stage_hashes[index], lookup_artifact_path(stage, stage_artifact_paths));
    }
    try writer.writeByte(']');
    return list.toOwnedSlice(allocator);
}

fn write_stage_json(
    writer: anytype,
    stage: StageDescriptor,
    artifact_hash: [hash_utils.SHA256_HEX_SIZE]u8,
    artifact_path: ?[]const u8,
) !void {
    try writer.print(
        "{{\"stage\":\"{s}\",\"implementation\":\"{s}\",\"artifactSha256\":\"{s}\"",
        .{ stage.stage, stage.implementation.name(), artifact_hash[0..] },
    );
    if (artifact_path) |path| {
        try writer.print(",\"artifactPath\":\"{s}\"", .{path});
    }
    switch (stage.implementation) {
        .native_zig => {},
        .external_tool => {
            const tool = stage.tool orelse return error.InvalidArgument;
            const version = stage.version orelse return error.InvalidArgument;
            try writer.print(",\"tool\":\"{s}\",\"version\":\"{s}\",\"args\":[", .{ tool, version });
            for (stage.args, 0..) |arg, index| {
                if (index > 0) try writer.writeByte(',');
                try writer.print("\"{s}\"", .{arg});
            }
            try writer.writeByte(']');
        },
    }
    try writer.writeByte('}');
}

fn build_prehash_json(
    allocator: std.mem.Allocator,
    spec: ManifestSpec,
    module: []const u8,
    meta: artifact_meta.ArtifactMeta,
    taxonomy_code: []const u8,
    previous_hash: []const u8,
    toolchain_hash: [hash_utils.SHA256_HEX_SIZE]u8,
    pipeline_hash: [hash_utils.SHA256_HEX_SIZE]u8,
    wgsl_hash: [hash_utils.SHA256_HEX_SIZE]u8,
    stage_hashes: []const [hash_utils.SHA256_HEX_SIZE]u8,
    stages_json: []const u8,
) ![]u8 {
    var list = try std.ArrayList(u8).initCapacity(allocator, 0);
    errdefer list.deinit(allocator);
    const writer = list.writer(allocator);

    _ = meta;
    try writer.print(
        "{{\"schemaVersion\":2,\"backendId\":\"{s}\",\"module\":\"{s}\",\"pipelineHash\":\"{s}\",\"wgslSha256\":\"{s}\"",
        .{ spec.backend_id, module, pipeline_hash[0..], wgsl_hash[0..] },
    );
    for (spec.stages, 0..) |stage, index| {
        if (stage.manifest_field) |field| {
            try writer.print(",\"{s}\":\"{s}\"", .{ field, stage_hashes[index][0..] });
        }
    }
    try writer.print(
        ",\"toolchainSha256\":\"{s}\",\"taxonomyCode\":\"{s}\",\"previousHash\":\"{s}\",\"stages\":{s}}}",
        .{ toolchain_hash[0..], taxonomy_code, previous_hash, stages_json },
    );
    return list.toOwnedSlice(allocator);
}

fn load_toolchain_sha256(allocator: std.mem.Allocator) ![hash_utils.SHA256_HEX_SIZE]u8 {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, SHADER_TOOLCHAIN_PATH, MAX_TOOLCHAIN_BYTES);
    defer allocator.free(bytes);
    return hash_utils.sha256_hex(bytes);
}

fn normalize_taxonomy_code(buffer: []u8, raw: []const u8) []const u8 {
    var out_len: usize = 0;
    var previous_underscore = false;
    for (raw) |byte| {
        if (out_len >= buffer.len) break;
        const lowered = std.ascii.toLower(byte);
        const is_valid = (lowered >= 'a' and lowered <= 'z') or (lowered >= '0' and lowered <= '9');
        if (is_valid) {
            buffer[out_len] = lowered;
            out_len += 1;
            previous_underscore = false;
            continue;
        }
        if (!previous_underscore and out_len < buffer.len) {
            buffer[out_len] = '_';
            out_len += 1;
            previous_underscore = true;
        }
    }
    if (out_len == 0) {
        const fallback = "error";
        std.mem.copyForwards(u8, buffer[0..fallback.len], fallback);
        return buffer[0..fallback.len];
    }
    while (out_len > 1 and buffer[out_len - 1] == '_') out_len -= 1;
    return buffer[0..out_len];
}

test "normalize_taxonomy_code normalizes punctuation and case" {
    var buffer: [64]u8 = undefined;
    const value = normalize_taxonomy_code(&buffer, "Shader Compile Failed!");
    try std.testing.expectEqualStrings("shader_compile_failed", value);
}

test "derive_stage_hashes builds deterministic chained hashes" {
    const stages = [_]StageDescriptor{
        .{ .stage = "sema", .hash_label = "sema" },
        .{ .stage = "ir_build", .hash_label = "ir_build", .manifest_field = "irSha256" },
    };
    const wgsl_hash = hash_utils.sha256_hex("module");
    const hashes = try derive_stage_hashes(std.testing.allocator, &stages, wgsl_hash, &.{});
    defer std.testing.allocator.free(hashes);

    try std.testing.expectEqual(derive_stage_hash(wgsl_hash[0..], "sema"), hashes[0]);
    try std.testing.expectEqual(derive_stage_hash(hashes[0][0..], "ir_build"), hashes[1]);
}

test "derive_stage_hashes uses actual stage artifact hash when present" {
    const stages = [_]StageDescriptor{
        .{ .stage = "ir_to_spirv", .hash_label = "ir_to_spirv", .manifest_field = "spirvSha256" },
    };
    const wgsl_hash = hash_utils.sha256_hex("module");
    const filename_owned = try std.testing.allocator.dupe(u8, "shader.spv");
    defer std.testing.allocator.free(filename_owned);
    const artifact_hash = hash_utils.sha256_hex("spirv-bytes");
    const paths = [_]StageArtifactPath{
        .{
            .manifest_field = "spirvSha256",
            .filename = filename_owned,
            .artifact_hash = artifact_hash,
        },
    };
    const hashes = try derive_stage_hashes(std.testing.allocator, &stages, wgsl_hash, &paths);
    defer std.testing.allocator.free(hashes);

    try std.testing.expectEqual(artifact_hash, hashes[0]);
}

test "build_stages_json preserves external tool stage metadata" {
    const stages = [_]StageDescriptor{
        .{
            .stage = "dxil_validate",
            .hash_label = "dxil_validate",
            .implementation = .external_tool,
            .tool = "dxv",
            .version = "1.x",
            .args = &.{},
        },
    };
    const wgsl_hash = hash_utils.sha256_hex("module");
    const stage_hashes = [_][hash_utils.SHA256_HEX_SIZE]u8{hash_utils.sha256_hex("dxil_validate")};
    const json = try build_stages_json(std.testing.allocator, &stages, wgsl_hash, &stage_hashes, &.{});
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"implementation\":\"external_tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tool\":\"dxv\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"version\":\"1.x\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"args\":[]") != null);
}

test "build_stages_json includes artifactPath when provided" {
    const stages = [_]StageDescriptor{
        .{ .stage = "ir_to_spirv", .hash_label = "ir_to_spirv", .manifest_field = "spirvSha256" },
    };
    const wgsl_hash = hash_utils.sha256_hex("module");
    const stage_hashes = [_][hash_utils.SHA256_HEX_SIZE]u8{hash_utils.sha256_hex("ir_to_spirv")};
    const filename_owned = try std.testing.allocator.dupe(u8, "vulkan_shader_artifact_1.spv");
    defer std.testing.allocator.free(filename_owned);
    const paths = [_]StageArtifactPath{
        .{
            .manifest_field = "spirvSha256",
            .filename = filename_owned,
            .artifact_hash = hash_utils.sha256_hex("spirv"),
        },
    };
    const json = try build_stages_json(std.testing.allocator, &stages, wgsl_hash, &stage_hashes, &paths);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"stage\":\"ir_to_spirv\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"artifactPath\":\"vulkan_shader_artifact_1.spv\"") != null);
}
