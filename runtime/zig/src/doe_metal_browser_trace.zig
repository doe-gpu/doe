const std = @import("std");

pub const TRACE_PATH_ENV = "DOE_METAL_BROWSER_TRACE_PATH";
pub const TRACE_KIND = "doe_metal_browser_command_path_v1";

const TraceAccumulator = struct {
    submission_count: u64 = 0,
    source_command_buffer_count: u64 = 0,
    recorded_command_count: u64 = 0,
    native_command_buffer_count: u64 = 0,
    command_buffer_create_ns: u64 = 0,
    command_encode_ns: u64 = 0,
    command_commit_ns: u64 = 0,
};

var g_ready: std.atomic.Value(u8) = .init(0);
var g_init_lock: std.Thread.Mutex = .{};
var g_trace_lock: std.Thread.Mutex = .{};
var g_trace_path: ?[]const u8 = null;
var g_sequence: u64 = 0;
var g_accumulator = TraceAccumulator{};

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

pub fn nowNs() u64 {
    return @intCast(std.time.nanoTimestamp());
}

pub fn elapsedSince(start_ns: u64) u64 {
    return nowNs() - start_ns;
}

pub fn recordSubmission(
    source_command_buffer_count: usize,
    recorded_command_count: usize,
    command_buffer_create_ns: u64,
    command_encode_ns: u64,
    command_commit_ns: u64,
) void {
    if (!enabled()) return;

    g_trace_lock.lock();
    defer g_trace_lock.unlock();
    g_accumulator.submission_count += 1;
    g_accumulator.source_command_buffer_count += @intCast(source_command_buffer_count);
    g_accumulator.recorded_command_count += @intCast(recorded_command_count);
    g_accumulator.native_command_buffer_count += 1;
    g_accumulator.command_buffer_create_ns += command_buffer_create_ns;
    g_accumulator.command_encode_ns += command_encode_ns;
    g_accumulator.command_commit_ns += command_commit_ns;
}

fn appendFlushRow(
    path: []const u8,
    sequence: u64,
    accumulator: TraceAccumulator,
    wait_completed_ns: u64,
    deferred_copy_ns: u64,
    deferred_resolve_ns: u64,
    direct_readback: bool,
) bool {
    var row_buffer: [1024]u8 = undefined;
    const row = std.fmt.bufPrint(
        &row_buffer,
        "{{\"schemaVersion\":1,\"traceKind\":\"{s}\",\"sequence\":{},\"submissionCount\":{},\"sourceCommandBufferCount\":{},\"recordedCommandCount\":{},\"nativeCommandBufferCount\":{},\"commandBufferCreateNs\":{},\"commandEncodeNs\":{},\"commandCommitNs\":{},\"waitCompletedNs\":{},\"deferredCopyNs\":{},\"deferredResolveNs\":{},\"directReadback\":{s}}}\n",
        .{
            TRACE_KIND,
            sequence,
            accumulator.submission_count,
            accumulator.source_command_buffer_count,
            accumulator.recorded_command_count,
            accumulator.native_command_buffer_count,
            accumulator.command_buffer_create_ns,
            accumulator.command_encode_ns,
            accumulator.command_commit_ns,
            wait_completed_ns,
            deferred_copy_ns,
            deferred_resolve_ns,
            if (direct_readback) "true" else "false",
        },
    ) catch return false;

    var file = std.fs.cwd().openFile(path, .{ .mode = .write_only }) catch return false;
    defer file.close();
    file.seekFromEnd(0) catch return false;
    file.writeAll(row) catch return false;
    return true;
}

pub fn recordFlush(
    wait_completed_ns: u64,
    deferred_copy_ns: u64,
    deferred_resolve_ns: u64,
    direct_readback: bool,
) void {
    if (!enabled()) return;

    g_trace_lock.lock();
    defer g_trace_lock.unlock();
    if (g_accumulator.submission_count == 0) return;
    const path = g_trace_path orelse return;
    const next_sequence = g_sequence + 1;
    if (!appendFlushRow(
        path,
        next_sequence,
        g_accumulator,
        wait_completed_ns,
        deferred_copy_ns,
        deferred_resolve_ns,
        direct_readback,
    )) return;
    g_sequence = next_sequence;
    g_accumulator = .{};
}

test "trace row encodes native phases in canonical field order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = "metal-trace.jsonl";
    try tmp.dir.writeFile(.{ .sub_path = path, .data = "" });

    var absolute_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const absolute_path = try tmp.dir.realpath(path, &absolute_buffer);
    try std.testing.expect(appendFlushRow(
        absolute_path,
        3,
        .{
            .submission_count = 2,
            .source_command_buffer_count = 2,
            .recorded_command_count = 7,
            .native_command_buffer_count = 2,
            .command_buffer_create_ns = 11,
            .command_encode_ns = 13,
            .command_commit_ns = 17,
        },
        19,
        23,
        29,
        true,
    ));

    const contents = try tmp.dir.readFileAlloc(
        std.testing.allocator,
        path,
        2048,
    );
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings(
        "{\"schemaVersion\":1,\"traceKind\":\"doe_metal_browser_command_path_v1\",\"sequence\":3,\"submissionCount\":2,\"sourceCommandBufferCount\":2,\"recordedCommandCount\":7,\"nativeCommandBufferCount\":2,\"commandBufferCreateNs\":11,\"commandEncodeNs\":13,\"commandCommitNs\":17,\"waitCompletedNs\":19,\"deferredCopyNs\":23,\"deferredResolveNs\":29,\"directReadback\":true}\n",
        contents,
    );
}
