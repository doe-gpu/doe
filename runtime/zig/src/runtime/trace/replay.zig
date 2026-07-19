const std = @import("std");
const tooling_io_context = @import("../../tooling/tooling_io_context.zig");

const MAX_REPLAY_BYTES: usize = 16 * 1024 * 1024;
var next_test_file_id = std.atomic.Value(u64).init(0);

pub const ReplayValidationError = error{
    InvalidReplayHash,
    ReplayArtifactModuleMismatch,
    ReplayArtifactOpCodeMismatch,
    ReplayMissingRow,
    ReplayRowCountMismatch,
    ReplaySeqFieldMissing,
    ReplaySeqMismatch,
    ReplayCommandMismatch,
    ReplayKernelMismatch,
    ReplayHashFieldMissing,
    ReplayCommandFieldMissing,
    ReplayPreviousHashFieldMissing,
    ReplayPreviousHashMismatch,
    ReplayHashMismatch,
};

pub const ReplayExpectation = struct {
    seq: usize,
    command: []const u8,
    kernel: ?[]const u8 = null,
    hash: u64,
    previous_hash: u64,
};

pub const ReplayExpectationSet = struct {
    artifact_text: []const u8,
    expectations: []ReplayExpectation,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ReplayExpectationSet, allocator: std.mem.Allocator) void {
        allocator.free(self.expectations);
        self.arena.deinit();
        allocator.free(self.artifact_text);
        self.* = undefined;
    }
};

pub const RawReplayRow = struct {
    seq: ?usize = null,
    command: ?[]const u8 = null,
    kernel: ?[]const u8 = null,
    hash: ?[]const u8 = null,
    previousHash: ?[]const u8 = null,
    opCode: ?[]const u8 = null,
    module: ?[]const u8 = null,
};

pub fn parseTraceHash(value: []const u8) ReplayValidationError!u64 {
    if (value.len == 0) return ReplayValidationError.InvalidReplayHash;

    if (value.len >= 2 and value[0] == '0' and (value[1] == 'x' or value[1] == 'X')) {
        return std.fmt.parseInt(u64, value[2..], 16) catch return ReplayValidationError.InvalidReplayHash;
    }
    return std.fmt.parseInt(u64, value, 16) catch return ReplayValidationError.InvalidReplayHash;
}

pub fn parseReplayLine(expected_module: []const u8, parsed: *const RawReplayRow) !ReplayExpectation {
    if (parsed.opCode) |op_code| {
        if (!std.mem.eql(u8, op_code, "dispatch")) return ReplayValidationError.ReplayArtifactOpCodeMismatch;
    }
    if (parsed.module) |module_name| {
        if (!std.mem.eql(u8, module_name, expected_module)) {
            return ReplayValidationError.ReplayArtifactModuleMismatch;
        }
    }

    const command = parsed.command orelse return ReplayValidationError.ReplayCommandFieldMissing;
    const hash = parsed.hash orelse return ReplayValidationError.ReplayHashFieldMissing;
    const previous_hash = parsed.previousHash orelse return ReplayValidationError.ReplayPreviousHashFieldMissing;
    const seq = parsed.seq orelse return ReplayValidationError.ReplaySeqFieldMissing;
    const hash_parsed = try parseTraceHash(hash);
    const previous_hash_parsed = try parseTraceHash(previous_hash);

    return .{
        .seq = seq,
        .command = command,
        .kernel = parsed.kernel,
        .hash = hash_parsed,
        .previous_hash = previous_hash_parsed,
    };
}

pub fn loadReplayExpectations(allocator: std.mem.Allocator, path: []const u8) !ReplayExpectationSet {
    return loadReplayExpectationsWithIo(allocator, tooling_io_context.IoContext.sync(), path);
}

pub fn loadReplayExpectationsWithIo(
    allocator: std.mem.Allocator,
    io_context: tooling_io_context.IoContext,
    path: []const u8,
) !ReplayExpectationSet {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const parse_allocator = arena.allocator();
    const artifact_text = try io_context.readFileAlloc(allocator, path, MAX_REPLAY_BYTES);
    errdefer allocator.free(artifact_text);

    var expectations = std.ArrayList(ReplayExpectation).empty;
    errdefer {
        expectations.deinit(allocator);
    }
    var it = std.mem.splitScalar(u8, artifact_text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        const parsed = try std.json.parseFromSliceLeaky(RawReplayRow, parse_allocator, trimmed, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_if_needed,
        });
        const validated = try parseReplayLine("doe-zig-runtime", &parsed);
        try expectations.append(allocator, validated);
    }

    return .{
        .artifact_text = artifact_text,
        .expectations = try expectations.toOwnedSlice(allocator),
        .arena = arena,
    };
}

pub fn freeReplayExpectations(allocator: std.mem.Allocator, expectations: []ReplayExpectation) void {
    allocator.free(expectations);
}

pub fn matchOptionalText(lhs: ?[]const u8, rhs: ?[]const u8) bool {
    if (lhs == null and rhs == null) return true;
    if (lhs == null or rhs == null) return false;
    return std.mem.eql(u8, lhs.?, rhs.?);
}

fn sliceWithinBuffer(buffer: []const u8, slice: []const u8) bool {
    const buffer_start = @intFromPtr(buffer.ptr);
    const buffer_end = buffer_start + buffer.len;
    const slice_start = @intFromPtr(slice.ptr);
    const slice_end = slice_start + slice.len;
    return slice_start >= buffer_start and slice_end <= buffer_end;
}

fn allocTestPath(allocator: std.mem.Allocator, stem: []const u8) ![]u8 {
    const unique_id = next_test_file_id.fetchAdd(1, .monotonic);
    return std.fmt.allocPrint(
        allocator,
        ".tmp-{s}-{d}-{d}.jsonl",
        .{ stem, unique_id, std.time.nanoTimestamp() },
    );
}

test "parseTraceHash parses plain hex string" {
    const result = try parseTraceHash("deadbeef");
    try std.testing.expectEqual(@as(u64, 0xdeadbeef), result);
}

test "parseTraceHash parses 0x-prefixed hex string" {
    const result = try parseTraceHash("0xCAFE");
    try std.testing.expectEqual(@as(u64, 0xCAFE), result);
}

test "parseTraceHash parses 0X-prefixed hex string" {
    const result = try parseTraceHash("0X1a2b");
    try std.testing.expectEqual(@as(u64, 0x1a2b), result);
}

test "parseTraceHash rejects empty string" {
    const result = parseTraceHash("");
    try std.testing.expectError(ReplayValidationError.InvalidReplayHash, result);
}

test "parseTraceHash rejects non-hex content" {
    const result = parseTraceHash("zzzz");
    try std.testing.expectError(ReplayValidationError.InvalidReplayHash, result);
}

test "matchOptionalText returns true for two null values" {
    try std.testing.expect(matchOptionalText(null, null));
}

test "matchOptionalText returns false when only one side is null" {
    try std.testing.expect(!matchOptionalText("abc", null));
    try std.testing.expect(!matchOptionalText(null, "abc"));
}

test "matchOptionalText compares non-null strings" {
    try std.testing.expect(matchOptionalText("hello", "hello"));
    try std.testing.expect(!matchOptionalText("hello", "world"));
}

test "parseReplayLine returns expectation for valid row" {
    const row = RawReplayRow{
        .seq = 0,
        .command = "buffer_upload",
        .kernel = null,
        .hash = "0xabc",
        .previousHash = "0x0",
        .opCode = "dispatch",
        .module = "doe-zig-runtime",
    };
    const result = try parseReplayLine("doe-zig-runtime", &row);

    try std.testing.expectEqual(@as(usize, 0), result.seq);
    try std.testing.expect(std.mem.eql(u8, "buffer_upload", result.command));
    try std.testing.expectEqual(@as(?[]const u8, null), result.kernel);
    try std.testing.expectEqual(@as(u64, 0xabc), result.hash);
    try std.testing.expectEqual(@as(u64, 0x0), result.previous_hash);
}

test "parseReplayLine rejects mismatched module" {
    const row = RawReplayRow{
        .seq = 1,
        .command = "dispatch",
        .hash = "ff",
        .previousHash = "00",
        .module = "wrong-module",
    };
    const result = parseReplayLine("doe-zig-runtime", &row);
    try std.testing.expectError(ReplayValidationError.ReplayArtifactModuleMismatch, result);
}

test "parseReplayLine rejects mismatched opCode" {
    const row = RawReplayRow{
        .seq = 1,
        .command = "dispatch",
        .hash = "ff",
        .previousHash = "00",
        .opCode = "render",
    };
    const result = parseReplayLine("doe-zig-runtime", &row);
    try std.testing.expectError(ReplayValidationError.ReplayArtifactOpCodeMismatch, result);
}

test "parseReplayLine returns error for missing required fields" {
    // missing command
    const no_cmd = RawReplayRow{ .seq = 0, .hash = "aa", .previousHash = "00" };
    try std.testing.expectError(ReplayValidationError.ReplayCommandFieldMissing, parseReplayLine("x", &no_cmd));

    // missing hash
    const no_hash = RawReplayRow{ .seq = 0, .command = "c", .previousHash = "00" };
    try std.testing.expectError(ReplayValidationError.ReplayHashFieldMissing, parseReplayLine("x", &no_hash));

    // missing previousHash
    const no_prev = RawReplayRow{ .seq = 0, .command = "c", .hash = "aa" };
    try std.testing.expectError(ReplayValidationError.ReplayPreviousHashFieldMissing, parseReplayLine("x", &no_prev));

    // missing seq
    const no_seq = RawReplayRow{ .command = "c", .hash = "aa", .previousHash = "00" };
    try std.testing.expectError(ReplayValidationError.ReplaySeqFieldMissing, parseReplayLine("x", &no_seq));
}

test "loadReplayExpectations keeps simple field slices inside the owned artifact buffer" {
    const path = try allocTestPath(std.testing.allocator, "replay-owned-buffer");
    defer std.testing.allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    const contents =
        \\{"seq":0,"command":"buffer_upload","kernel":"main","hash":"0x1","previousHash":"0x0","opCode":"dispatch","module":"doe-zig-runtime"}
        \\{"seq":1,"command":"dispatch","hash":"0x2","previousHash":"0x1","opCode":"dispatch","module":"doe-zig-runtime"}
        \\
    ;
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = contents });

    var loaded = try loadReplayExpectations(std.testing.allocator, path);
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), loaded.expectations.len);
    try std.testing.expect(sliceWithinBuffer(loaded.artifact_text, loaded.expectations[0].command));
    try std.testing.expect(sliceWithinBuffer(loaded.artifact_text, loaded.expectations[0].kernel.?));
    try std.testing.expect(sliceWithinBuffer(loaded.artifact_text, loaded.expectations[1].command));
}

test "loadReplayExpectationsWithIo supports cooperative same-thread mode" {
    const path = try allocTestPath(std.testing.allocator, "replay-cooperative-io");
    defer std.testing.allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    try std.fs.cwd().writeFile(.{
        .sub_path = path,
        .data =
        \\{"seq":0,"command":"dispatch","hash":"0x1","previousHash":"0x0","opCode":"dispatch","module":"doe-zig-runtime"}
        \\
        ,
    });

    var loaded = try loadReplayExpectationsWithIo(
        std.testing.allocator,
        tooling_io_context.IoContext.cooperativeSameThread(),
        path,
    );
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), loaded.expectations.len);
    try std.testing.expectEqual(@as(usize, 0), loaded.expectations[0].seq);
}
