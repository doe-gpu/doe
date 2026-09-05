const std = @import("std");
const builtin = @import("builtin");

pub const TRACE_PATH_ENV = "DOE_PROGRAM_IDENTITY_TRACE_PATH";
pub const TRACE_KIND = "doe_native_program_identity_v1";

pub fn recordComputeProgramPrepared(program_id: usize, dispatch_count: u64) void {
    recordComputeProgram("compute_program_prepared", program_id, dispatch_count, 0);
}

pub fn recordComputeProgramSubmitted(program_id: usize, dispatch_count: u64, submission: u64) void {
    recordComputeProgram("compute_program_submitted", program_id, dispatch_count, submission);
}

fn recordComputeProgram(event: []const u8, program_id: usize, dispatch_count: u64, submission: u64) void {
    if (!enabled()) return;
    g_trace_lock.lock();
    defer g_trace_lock.unlock();
    const path = g_trace_path orelse return;
    var buffer: [512]u8 = undefined;
    const row = std.fmt.bufPrint(&buffer, "{{\"schemaVersion\":1,\"traceKind\":\"{s}\",\"event\":\"{s}\",\"processId\":{},\"sequence\":{},\"backend\":\"doe_vulkan\",\"programId\":{},\"dispatchCount\":{},\"submissionIndex\":{}}}\n", .{ TRACE_KIND, event, processId(), nextSequence(), program_id, dispatch_count, submission }) catch return;
    _ = appendLocked(path, row);
}

var g_ready: std.atomic.Value(u8) = .init(0);
var g_init_lock: std.Thread.Mutex = .{};
var g_trace_lock: std.Thread.Mutex = .{};
var g_trace_path: ?[]const u8 = null;
var g_sequence: u64 = 0;

fn ensureInitialized() void {
    if (g_ready.load(.acquire) != 0) return;

    g_init_lock.lock();
    defer g_init_lock.unlock();
    if (g_ready.load(.acquire) != 0) return;

    const raw_path = std.process.getEnvVarOwned(
        std.heap.page_allocator,
        TRACE_PATH_ENV,
    ) catch null;
    if (raw_path) |path| {
        if (path.len > 0) {
            g_trace_path = path;
        } else {
            std.heap.page_allocator.free(path);
        }
    }
    g_ready.store(1, .release);
}

pub fn enabled() bool {
    ensureInitialized();
    return g_trace_path != null;
}

fn processId() u64 {
    if (comptime builtin.os.tag == .linux) {
        return @intCast(std.os.linux.getpid());
    }
    return 0;
}

fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn appendLocked(path: []const u8, row: []const u8) bool {
    var file = std.fs.cwd().openFile(path, .{ .mode = .write_only }) catch return false;
    defer file.close();
    file.lock(.exclusive) catch return false;
    defer file.unlock();
    file.seekFromEnd(0) catch return false;
    file.writeAll(row) catch return false;
    return true;
}

fn nextSequence() u64 {
    g_sequence += 1;
    return g_sequence;
}

fn appendDispatchRow(
    path: []const u8,
    sequence: u64,
    pid: u64,
    wgsl: []const u8,
    spirv: []const u32,
    artifact_file: []const u8,
    entry_point: []const u8,
    x: u32,
    y: u32,
    z: u32,
    repeat_index: u32,
    descriptor_hash: u64,
    binding_count: u32,
    binding_resource_hash: u64,
) bool {
    const source_hash = sha256Hex(wgsl);
    const artifact_hash = sha256Hex(std.mem.sliceAsBytes(spirv));
    var row_buffer: [1024]u8 = undefined;
    const row = std.fmt.bufPrint(
        &row_buffer,
        "{{\"schemaVersion\":1,\"traceKind\":\"{s}\",\"event\":\"dispatch_encoded\",\"processId\":{},\"sequence\":{},\"backend\":\"doe_vulkan\",\"wgslSha256\":\"{s}\",\"backendArtifactSha256\":\"{s}\",\"backendArtifactFile\":\"{s}\",\"entryPoint\":\"{s}\",\"workgroups\":[{},{},{}],\"repeatIndex\":{},\"descriptorHash\":{},\"bindingCount\":{},\"bindingResourceHash\":{}}}\n",
        .{
            TRACE_KIND,
            pid,
            sequence,
            source_hash,
            artifact_hash,
            artifact_file,
            entry_point,
            x,
            y,
            z,
            repeat_index,
            descriptor_hash,
            binding_count,
            binding_resource_hash,
        },
    ) catch return false;
    return appendLocked(path, row);
}

fn persistBackendArtifact(
    trace_path: []const u8,
    artifact_hash: [64]u8,
    bytes: []const u8,
    filename_buffer: []u8,
) ?[]const u8 {
    const filename = std.fmt.bufPrint(
        filename_buffer,
        "doe-native-vulkan-{s}.spv",
        .{artifact_hash},
    ) catch return null;
    const directory = std.fs.path.dirname(trace_path) orelse ".";
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ directory, filename }) catch return null;
    const file = std.fs.cwd().createFile(path, .{
        .truncate = false,
        .exclusive = true,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => return filename,
        else => return null,
    };
    defer file.close();
    file.writeAll(bytes) catch return null;
    return filename;
}

fn appendSubmissionRow(path: []const u8, sequence: u64, pid: u64) bool {
    var row_buffer: [256]u8 = undefined;
    const row = std.fmt.bufPrint(
        &row_buffer,
        "{{\"schemaVersion\":1,\"traceKind\":\"{s}\",\"event\":\"submission_succeeded\",\"processId\":{},\"sequence\":{},\"backend\":\"doe_vulkan\"}}\n",
        .{ TRACE_KIND, pid, sequence },
    ) catch return false;
    return appendLocked(path, row);
}

fn appendRenderDrawRow(
    path: []const u8,
    sequence: u64,
    pid: u64,
    vertex_wgsl_sha256: [32]u8,
    fragment_wgsl_sha256: [32]u8,
    vertex_artifact_sha256: [64]u8,
    vertex_artifact_file: []const u8,
    fragment_artifact_sha256: [64]u8,
    fragment_artifact_file: []const u8,
    vertex_entry_point: []const u8,
    fragment_entry_point: []const u8,
    vertex_count: u32,
    instance_count: u32,
    first_vertex: u32,
    first_instance: u32,
) bool {
    const vertex_source_hash = std.fmt.bytesToHex(vertex_wgsl_sha256, .lower);
    const fragment_source_hash = std.fmt.bytesToHex(fragment_wgsl_sha256, .lower);
    var row_buffer: [2048]u8 = undefined;
    const row = std.fmt.bufPrint(
        &row_buffer,
        "{{\"schemaVersion\":1,\"traceKind\":\"{s}\",\"event\":\"render_draw_executed\",\"processId\":{},\"sequence\":{},\"backend\":\"doe_vulkan\",\"completion\":\"internal_submit_and_wait_succeeded\",\"vertexWgslSha256\":\"{s}\",\"fragmentWgslSha256\":\"{s}\",\"vertexBackendArtifactSha256\":\"{s}\",\"vertexBackendArtifactFile\":\"{s}\",\"fragmentBackendArtifactSha256\":\"{s}\",\"fragmentBackendArtifactFile\":\"{s}\",\"vertexEntryPoint\":\"{s}\",\"fragmentEntryPoint\":\"{s}\",\"drawKind\":\"draw\",\"args\":[{},{},{},{}]}}\n",
        .{
            TRACE_KIND,
            pid,
            sequence,
            vertex_source_hash,
            fragment_source_hash,
            vertex_artifact_sha256,
            vertex_artifact_file,
            fragment_artifact_sha256,
            fragment_artifact_file,
            vertex_entry_point,
            fragment_entry_point,
            vertex_count,
            instance_count,
            first_vertex,
            first_instance,
        },
    ) catch return false;
    return appendLocked(path, row);
}

pub fn recordVulkanDispatch(
    pipeline: anytype,
    x: u32,
    y: u32,
    z: u32,
    repeat_index: u32,
    descriptor_hash: u64,
    binding_count: u32,
    binding_resource_hash: u64,
) void {
    if (!enabled()) return;
    const shader = pipeline.shader_module orelse return;
    const wgsl = shader.wgsl_source orelse return;
    const spirv = pipeline.spirv_data orelse return;
    const entry_point = if (pipeline.vk_entry_point_owned) |entry| entry[0..entry.len] else "main";
    const spirv_bytes = std.mem.sliceAsBytes(spirv);
    const artifact_hash = sha256Hex(spirv_bytes);
    var artifact_filename_buffer: [128]u8 = undefined;

    g_trace_lock.lock();
    defer g_trace_lock.unlock();
    const path = g_trace_path orelse return;
    const artifact_filename = persistBackendArtifact(
        path,
        artifact_hash,
        spirv_bytes,
        &artifact_filename_buffer,
    ) orelse return;
    _ = appendDispatchRow(
        path,
        nextSequence(),
        processId(),
        wgsl,
        spirv,
        artifact_filename,
        entry_point,
        x,
        y,
        z,
        repeat_index,
        descriptor_hash,
        binding_count,
        binding_resource_hash,
    );
}

pub fn recordNativeObjectCreate(comptime T: type, object: *T) void {
    if (!enabled()) return;
    var row_buffer: [512]u8 = undefined;

    g_trace_lock.lock();
    defer g_trace_lock.unlock();
    const path = g_trace_path orelse return;
    const row = std.fmt.bufPrint(
        &row_buffer,
        "{{\"schemaVersion\":1,\"traceKind\":\"{s}\",\"event\":\"native_object_created\",\"processId\":{},\"sequence\":{},\"objectType\":\"{s}\",\"objectSize\":{},\"objectAddress\":{}}}\n",
        .{ TRACE_KIND, processId(), nextSequence(), @typeName(T), @sizeOf(T), @intFromPtr(object) },
    ) catch return;
    _ = appendLocked(path, row);
}

pub fn recordVulkanRenderDraw(
    pipeline: anytype,
    vertex_count: u32,
    instance_count: u32,
    first_vertex: u32,
    first_instance: u32,
) void {
    if (!enabled()) return;
    if (!pipeline.vertex_wgsl_sha256_ready or !pipeline.fragment_wgsl_sha256_ready) return;
    const vertex_spirv = pipeline.vertex_spirv_data orelse return;
    const fragment_spirv = pipeline.fragment_spirv_data orelse return;
    const vertex_entry_point = pipeline.vertex_entry_point orelse "main";
    const fragment_entry_point = pipeline.fragment_entry_point orelse "main";
    const vertex_bytes = std.mem.sliceAsBytes(vertex_spirv);
    const fragment_bytes = std.mem.sliceAsBytes(fragment_spirv);
    const vertex_artifact_hash = sha256Hex(vertex_bytes);
    const fragment_artifact_hash = sha256Hex(fragment_bytes);
    var vertex_filename_buffer: [128]u8 = undefined;
    var fragment_filename_buffer: [128]u8 = undefined;

    g_trace_lock.lock();
    defer g_trace_lock.unlock();
    const path = g_trace_path orelse return;
    const vertex_artifact_file = persistBackendArtifact(
        path,
        vertex_artifact_hash,
        vertex_bytes,
        &vertex_filename_buffer,
    ) orelse return;
    const fragment_artifact_file = persistBackendArtifact(
        path,
        fragment_artifact_hash,
        fragment_bytes,
        &fragment_filename_buffer,
    ) orelse return;
    _ = appendRenderDrawRow(
        path,
        nextSequence(),
        processId(),
        pipeline.vertex_wgsl_sha256,
        pipeline.fragment_wgsl_sha256,
        vertex_artifact_hash,
        vertex_artifact_file,
        fragment_artifact_hash,
        fragment_artifact_file,
        vertex_entry_point,
        fragment_entry_point,
        vertex_count,
        instance_count,
        first_vertex,
        first_instance,
    );
}

pub fn recordVulkanSubmissionSucceeded() void {
    if (!enabled()) return;
    g_trace_lock.lock();
    defer g_trace_lock.unlock();
    const path = g_trace_path orelse return;
    _ = appendSubmissionRow(path, nextSequence(), processId());
}

test "dispatch row binds exact source and SPIR-V bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "identity.jsonl", .data = "" });

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath("identity.jsonl", &path_buffer);
    const spirv = [_]u32{ 0x07230203, 7 };
    try std.testing.expect(appendDispatchRow(
        path,
        2,
        17,
        "@compute fn main() {}",
        &spirv,
        "doe-native-vulkan-fixture.spv",
        "main",
        3,
        2,
        1,
        0,
        101,
        2,
        202,
    ));
    const contents = try tmp.dir.readFileAlloc(std.testing.allocator, "identity.jsonl", 2048);
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"event\":\"dispatch_encoded\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"processId\":17") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"workgroups\":[3,2,1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"wgslSha256\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"backendArtifactSha256\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"backendArtifactFile\":\"doe-native-vulkan-fixture.spv\"") != null);
}

test "submission row is explicit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "identity.jsonl", .data = "" });

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath("identity.jsonl", &path_buffer);
    try std.testing.expect(appendSubmissionRow(path, 4, 21));
    const contents = try tmp.dir.readFileAlloc(std.testing.allocator, "identity.jsonl", 1024);
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"event\":\"submission_succeeded\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"sequence\":4") != null);
}

test "render draw row binds both source and SPIR-V identities" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "identity.jsonl", .data = "" });

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath("identity.jsonl", &path_buffer);
    var vertex_source_hash: [32]u8 = undefined;
    var fragment_source_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("@vertex fn vs() {}", &vertex_source_hash, .{});
    std.crypto.hash.sha2.Sha256.hash("@fragment fn fs() {}", &fragment_source_hash, .{});
    const artifact_hash = sha256Hex("spirv");
    try std.testing.expect(appendRenderDrawRow(
        path,
        3,
        19,
        vertex_source_hash,
        fragment_source_hash,
        artifact_hash,
        "doe-native-vulkan-vertex.spv",
        artifact_hash,
        "doe-native-vulkan-fragment.spv",
        "vs",
        "fs",
        6,
        1,
        0,
        0,
    ));
    const contents = try tmp.dir.readFileAlloc(std.testing.allocator, "identity.jsonl", 4096);
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"event\":\"render_draw_executed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"completion\":\"internal_submit_and_wait_succeeded\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"vertexEntryPoint\":\"vs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"fragmentEntryPoint\":\"fs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"args\":[6,1,0,0]") != null);
}

test "backend artifact filename binds persisted SPIR-V bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "identity.jsonl", .data = "" });

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const trace_path = try tmp.dir.realpath("identity.jsonl", &path_buffer);
    const bytes = std.mem.sliceAsBytes(&[_]u32{ 0x07230203, 9 });
    const artifact_hash = sha256Hex(bytes);
    var filename_buffer: [128]u8 = undefined;
    const filename = persistBackendArtifact(
        trace_path,
        artifact_hash,
        bytes,
        &filename_buffer,
    ) orelse return error.TestUnexpectedResult;
    const persisted = try tmp.dir.readFileAlloc(std.testing.allocator, filename, 1024);
    defer std.testing.allocator.free(persisted);
    try std.testing.expectEqualSlices(u8, bytes, persisted);
    try std.testing.expect(std.mem.indexOf(u8, filename, &artifact_hash) != null);
}
