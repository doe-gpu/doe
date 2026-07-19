const std = @import("std");
const testing = std.testing;

const trace = @import("../../src/runtime/trace/trace.zig");
const model = @import("../../src/contracts/model/model.zig");
const execution = @import("../../src/runtime/execution.zig");

// ============================================================
// Helper: mock dispatch result for tracePayloadHash / printTraceLine
// The result parameter is duck-typed; it needs a .decision field
// matching quirk/runtime.zig DispatchDecision.

const MockDecision = struct {
    matched_quirk_id: ?[]const u8 = null,
    action: ?model.QuirkAction = null,
    score: u32 = 0,
    matched_count: u32 = 0,
    requires_lean: bool = false,
    is_blocking: bool = false,
    proof_level: ?model.ProofLevel = null,
    verification_mode: ?model.VerificationMode = null,
    applied_toggle: ?[]const u8 = null,
    matched_scope: ?model.Scope = null,
    matched_safety_class: ?model.SafetyClass = null,
};

const MockResult = struct {
    command: model.Command,
    decision: MockDecision,
};

fn emptyResult() MockResult {
    return .{
        .command = .{ .upload = .{ .bytes = 0, .align_bytes = 4 } },
        .decision = .{},
    };
}

fn populatedResult() MockResult {
    return .{
        .command = .{ .dispatch = .{ .x = 8, .y = 4, .z = 1 } },
        .decision = .{
            .matched_quirk_id = "quirk_alignment_001",
            .action = .no_op,
            .score = 100,
            .matched_count = 3,
            .requires_lean = true,
            .is_blocking = true,
            .proof_level = .proven,
            .verification_mode = .lean_required,
            .applied_toggle = "force_barrier",
            .matched_scope = .barrier,
            .matched_safety_class = .critical,
        },
    };
}

// ============================================================
// writeJsonString — basic escaping

test "writeJsonString: plain ASCII produces quoted string" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try trace.writeJsonString(fbs.writer(), "hello");
    try testing.expectEqualStrings("\"hello\"", fbs.getWritten());
}

test "writeJsonString: empty string produces empty quoted string" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try trace.writeJsonString(fbs.writer(), "");
    try testing.expectEqualStrings("\"\"", fbs.getWritten());
}

// ============================================================
// writeJsonString — special character escaping

test "writeJsonString: double quote is escaped" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try trace.writeJsonString(fbs.writer(), "a\"b");
    try testing.expectEqualStrings("\"a\\\"b\"", fbs.getWritten());
}

test "writeJsonString: backslash is escaped" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try trace.writeJsonString(fbs.writer(), "a\\b");
    try testing.expectEqualStrings("\"a\\\\b\"", fbs.getWritten());
}

test "writeJsonString: newline is escaped" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try trace.writeJsonString(fbs.writer(), "line1\nline2");
    try testing.expectEqualStrings("\"line1\\nline2\"", fbs.getWritten());
}

test "writeJsonString: carriage return is escaped" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try trace.writeJsonString(fbs.writer(), "cr\rhere");
    try testing.expectEqualStrings("\"cr\\rhere\"", fbs.getWritten());
}

test "writeJsonString: tab is escaped" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try trace.writeJsonString(fbs.writer(), "a\tb");
    try testing.expectEqualStrings("\"a\\tb\"", fbs.getWritten());
}

test "writeJsonString: all special chars in one string" {
    var buf: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try trace.writeJsonString(fbs.writer(), "\"\\\n\r\t");
    try testing.expectEqualStrings("\"\\\"\\\\\\n\\r\\t\"", fbs.getWritten());
}

// ============================================================
// writeJsonString — control character unicode escaping

test "writeJsonString: null byte produces \\u0000" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try trace.writeJsonString(fbs.writer(), &[_]u8{0x00});
    try testing.expectEqualStrings("\"\\u0000\"", fbs.getWritten());
}

test "writeJsonString: BEL (0x07) produces \\u0007" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try trace.writeJsonString(fbs.writer(), &[_]u8{0x07});
    try testing.expectEqualStrings("\"\\u0007\"", fbs.getWritten());
}

test "writeJsonString: form feed (0x0C) produces \\u000c" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try trace.writeJsonString(fbs.writer(), &[_]u8{0x0C});
    try testing.expectEqualStrings("\"\\u000c\"", fbs.getWritten());
}

test "writeJsonString: control char 0x1F produces \\u001f" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try trace.writeJsonString(fbs.writer(), &[_]u8{0x1F});
    try testing.expectEqualStrings("\"\\u001f\"", fbs.getWritten());
}

test "writeJsonString: 0x08 (backspace) produces unicode escape not \\b" {
    // JSON spec allows \b but trace.zig uses \u00xx for all non-standard controls
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try trace.writeJsonString(fbs.writer(), &[_]u8{0x08});
    try testing.expectEqualStrings("\"\\u0008\"", fbs.getWritten());
}

test "writeJsonString: 0x0B (vertical tab) produces unicode escape" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try trace.writeJsonString(fbs.writer(), &[_]u8{0x0B});
    try testing.expectEqualStrings("\"\\u000b\"", fbs.getWritten());
}

test "writeJsonString: 0x0E produces unicode escape" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try trace.writeJsonString(fbs.writer(), &[_]u8{0x0E});
    try testing.expectEqualStrings("\"\\u000e\"", fbs.getWritten());
}

// ============================================================
// writeJsonString — multi-byte UTF-8 passes through

test "writeJsonString: high-byte UTF-8 passes through unescaped" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    // 0xC3 0xA9 is UTF-8 for e-acute
    try trace.writeJsonString(fbs.writer(), "\xc3\xa9");
    try testing.expectEqualStrings("\"\xc3\xa9\"", fbs.getWritten());
}

// ============================================================
// writeJsonString — buffer overflow returns error

test "writeJsonString: writing to a too-small buffer returns NoSpaceLeft" {
    var buf: [3]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const err = trace.writeJsonString(fbs.writer(), "abcdefgh");
    try testing.expectError(error.NoSpaceLeft, err);
}

test "writeJsonString: exact-fit buffer succeeds" {
    // "ab" = quote + a + b + quote = 4 bytes
    var buf: [4]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try trace.writeJsonString(fbs.writer(), "ab");
    try testing.expectEqualStrings("\"ab\"", fbs.getWritten());
}

test "writeJsonString: escape expansion overflows fixed buffer" {
    // A single backslash expands to \\ (2 bytes) + quotes = 4 bytes total
    // Buffer of 3 should fail
    var buf: [3]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const err = trace.writeJsonString(fbs.writer(), "\\");
    try testing.expectError(error.NoSpaceLeft, err);
}

// ============================================================
// actionName — exhaustive enum-to-string mapping

test "actionName: null returns none" {
    try testing.expectEqualStrings("none", trace.actionName(null));
}

test "actionName: no_op returns no_op" {
    try testing.expectEqualStrings("no_op", trace.actionName(.no_op));
}

test "actionName: use_temporary_buffer returns correct string" {
    const action = model.QuirkAction{ .use_temporary_buffer = .{ .alignment_bytes = 16 } };
    try testing.expectEqualStrings("use_temporary_buffer", trace.actionName(action));
}

test "actionName: use_temporary_render_texture returns correct string" {
    const action = model.QuirkAction{ .use_temporary_render_texture = .{ .min_mip_level = 0 } };
    try testing.expectEqualStrings("use_temporary_render_texture", trace.actionName(action));
}

test "actionName: toggle returns toggle" {
    const action = model.QuirkAction{ .toggle = .{ .toggle_name = "some_toggle" } };
    try testing.expectEqualStrings("toggle", trace.actionName(action));
}

// ============================================================
// scopeName — exhaustive enum-to-string mapping

test "scopeName: null returns none" {
    try testing.expectEqualStrings("none", trace.scopeName(null));
}

test "scopeName: all variants produce correct strings" {
    try testing.expectEqualStrings("alignment", trace.scopeName(.alignment));
    try testing.expectEqualStrings("barrier", trace.scopeName(.barrier));
    try testing.expectEqualStrings("layout", trace.scopeName(.layout));
    try testing.expectEqualStrings("driver_toggle", trace.scopeName(.driver_toggle));
    try testing.expectEqualStrings("memory", trace.scopeName(.memory));
}

test "scopeName: variant count matches expected" {
    const fields = @typeInfo(model.Scope).@"enum".fields;
    try testing.expectEqual(@as(usize, 5), fields.len);
}

// ============================================================
// safetyClassName — exhaustive enum-to-string mapping

test "safetyClassName: null returns none" {
    try testing.expectEqualStrings("none", trace.safetyClassName(null));
}

test "safetyClassName: all variants produce correct strings" {
    try testing.expectEqualStrings("low", trace.safetyClassName(.low));
    try testing.expectEqualStrings("moderate", trace.safetyClassName(.moderate));
    try testing.expectEqualStrings("high", trace.safetyClassName(.high));
    try testing.expectEqualStrings("critical", trace.safetyClassName(.critical));
}

test "safetyClassName: variant count matches expected" {
    const fields = @typeInfo(model.SafetyClass).@"enum".fields;
    try testing.expectEqual(@as(usize, 4), fields.len);
}

// ============================================================
// verificationModeName — exhaustive enum-to-string mapping

test "verificationModeName: null returns none" {
    try testing.expectEqualStrings("none", trace.verificationModeName(null));
}

test "verificationModeName: all variants produce correct strings" {
    try testing.expectEqualStrings("guard_only", trace.verificationModeName(.guard_only));
    try testing.expectEqualStrings("lean_preferred", trace.verificationModeName(.lean_preferred));
    try testing.expectEqualStrings("lean_required", trace.verificationModeName(.lean_required));
}

test "verificationModeName: variant count matches expected" {
    const fields = @typeInfo(model.VerificationMode).@"enum".fields;
    try testing.expectEqual(@as(usize, 3), fields.len);
}

// ============================================================
// proofLevelName — exhaustive enum-to-string mapping

test "proofLevelName: null returns none" {
    try testing.expectEqualStrings("none", trace.proofLevelName(null));
}

test "proofLevelName: all variants produce correct strings" {
    try testing.expectEqualStrings("proven", trace.proofLevelName(.proven));
    try testing.expectEqualStrings("guarded", trace.proofLevelName(.guarded));
    try testing.expectEqualStrings("rejected", trace.proofLevelName(.rejected));
}

test "proofLevelName: variant count matches expected" {
    const fields = @typeInfo(model.ProofLevel).@"enum".fields;
    try testing.expectEqual(@as(usize, 3), fields.len);
}

// ============================================================
// apiName — exhaustive enum-to-string mapping

test "apiName: all variants produce correct strings" {
    try testing.expectEqualStrings("vulkan", trace.apiName(.vulkan));
    try testing.expectEqualStrings("metal", trace.apiName(.metal));
    try testing.expectEqualStrings("d3d12", trace.apiName(.d3d12));
    try testing.expectEqualStrings("webgpu", trace.apiName(.webgpu));
}

test "apiName: variant count matches expected" {
    const fields = @typeInfo(model.Api).@"enum".fields;
    try testing.expectEqual(@as(usize, 4), fields.len);
}

// ============================================================
// commandToTag — command-to-tag mapping

test "commandToTag: upload maps to upload" {
    const cmd = model.Command{ .upload = .{ .bytes = 1024, .align_bytes = 4 } };
    try testing.expectEqualStrings("upload", trace.commandToTag(cmd));
}

test "commandToTag: barrier maps to barrier" {
    const cmd = model.Command{ .barrier = .{ .dependency_count = 2 } };
    try testing.expectEqualStrings("barrier", trace.commandToTag(cmd));
}

test "commandToTag: dispatch maps to dispatch" {
    const cmd = model.Command{ .dispatch = .{ .x = 1, .y = 1, .z = 1 } };
    try testing.expectEqualStrings("dispatch", trace.commandToTag(cmd));
}

test "commandToTag: async_diagnostics maps to diagnostics" {
    const cmd = model.Command{ .async_diagnostics = .{} };
    try testing.expectEqualStrings("diagnostics", trace.commandToTag(cmd));
}

test "commandToTag: map_async maps to sync" {
    const cmd = model.Command{ .map_async = .{ .bytes = 64 } };
    try testing.expectEqualStrings("sync", trace.commandToTag(cmd));
}

test "commandToTag: surface_configure maps to frame" {
    const cmd = model.Command{ .surface_configure = .{ .handle = 1, .width = 800, .height = 600 } };
    try testing.expectEqualStrings("frame", trace.commandToTag(cmd));
}

test "commandToTag: surface_acquire maps to frame" {
    const cmd = model.Command{ .surface_acquire = .{ .handle = 1 } };
    try testing.expectEqualStrings("frame", trace.commandToTag(cmd));
}

test "commandToTag: surface_present maps to frame" {
    const cmd = model.Command{ .surface_present = .{ .handle = 1 } };
    try testing.expectEqualStrings("frame", trace.commandToTag(cmd));
}

test "commandToTag: surface_unconfigure maps to frame" {
    const cmd = model.Command{ .surface_unconfigure = .{ .handle = 1 } };
    try testing.expectEqualStrings("frame", trace.commandToTag(cmd));
}

test "commandToTag: surface_release maps to frame" {
    const cmd = model.Command{ .surface_release = .{ .handle = 1 } };
    try testing.expectEqualStrings("frame", trace.commandToTag(cmd));
}

test "commandToTag: render_draw maps to render_draw" {
    const cmd = model.Command{ .render_draw = std.mem.zeroes(model.RenderDrawCommand) };
    try testing.expectEqualStrings("render_draw", trace.commandToTag(cmd));
}

test "commandToTag: copy_buffer_to_texture maps correctly" {
    const cmd = model.Command{ .copy_buffer_to_texture = std.mem.zeroes(model.CopyCommand) };
    try testing.expectEqualStrings("copy_buffer_to_texture", trace.commandToTag(cmd));
}

test "commandToTag: sampler_create maps to sampler_create" {
    const cmd = model.Command{ .sampler_create = .{ .handle = 1 } };
    try testing.expectEqualStrings("sampler_create", trace.commandToTag(cmd));
}

test "commandToTag: sampler_destroy maps to sampler_destroy" {
    const cmd = model.Command{ .sampler_destroy = .{ .handle = 1 } };
    try testing.expectEqualStrings("sampler_destroy", trace.commandToTag(cmd));
}

test "commandToTag: texture_write maps to texture_write" {
    const cmd = model.Command{ .texture_write = std.mem.zeroes(model.TextureWriteCommand) };
    try testing.expectEqualStrings("texture_write", trace.commandToTag(cmd));
}

test "commandToTag: texture_query maps to texture_query" {
    const cmd = model.Command{ .texture_query = std.mem.zeroes(model.TextureQueryCommand) };
    try testing.expectEqualStrings("texture_query", trace.commandToTag(cmd));
}

test "commandToTag: texture_destroy maps to texture_destroy" {
    const cmd = model.Command{ .texture_destroy = .{ .handle = 1 } };
    try testing.expectEqualStrings("texture_destroy", trace.commandToTag(cmd));
}

test "commandToTag: surface_create maps to surface_create" {
    const cmd = model.Command{ .surface_create = .{ .handle = 1 } };
    try testing.expectEqualStrings("surface_create", trace.commandToTag(cmd));
}

test "commandToTag: surface_capabilities maps to surface_capabilities" {
    const cmd = model.Command{ .surface_capabilities = .{ .handle = 1 } };
    try testing.expectEqualStrings("surface_capabilities", trace.commandToTag(cmd));
}

// ============================================================
// TraceState — default initial hash

test "TraceState: default previous_hash is golden ratio constant" {
    const state = trace.TraceState{};
    try testing.expectEqual(@as(u64, 0x9e3779b97f4a7c15), state.previous_hash);
}

test "TraceState: custom previous_hash is preserved" {
    const state = trace.TraceState{ .previous_hash = 42 };
    try testing.expectEqual(@as(u64, 42), state.previous_hash);
}

// ============================================================
// tracePayloadHash — determinism and hash chain continuity

test "tracePayloadHash: same inputs produce same hash" {
    const state = trace.TraceState{};
    const result = emptyResult();
    const hash1 = trace.tracePayloadHash(state, 0, "upload", result.command, null, result);
    const hash2 = trace.tracePayloadHash(state, 0, "upload", result.command, null, result);
    try testing.expectEqual(hash1, hash2);
}

test "tracePayloadHash: different seq produces different hash" {
    const state = trace.TraceState{};
    const result = emptyResult();
    const hash1 = trace.tracePayloadHash(state, 0, "upload", result.command, null, result);
    const hash2 = trace.tracePayloadHash(state, 1, "upload", result.command, null, result);
    try testing.expect(hash1 != hash2);
}

test "tracePayloadHash: different command_label produces different hash" {
    const state = trace.TraceState{};
    const result = emptyResult();
    const hash1 = trace.tracePayloadHash(state, 0, "upload", result.command, null, result);
    const hash2 = trace.tracePayloadHash(state, 0, "barrier", result.command, null, result);
    try testing.expect(hash1 != hash2);
}

test "tracePayloadHash: different previous_hash produces different hash" {
    const state1 = trace.TraceState{ .previous_hash = 1 };
    const state2 = trace.TraceState{ .previous_hash = 2 };
    const result = emptyResult();
    const hash1 = trace.tracePayloadHash(state1, 0, "upload", result.command, null, result);
    const hash2 = trace.tracePayloadHash(state2, 0, "upload", result.command, null, result);
    try testing.expect(hash1 != hash2);
}

test "tracePayloadHash: kernel_name affects hash" {
    const state = trace.TraceState{};
    const result = emptyResult();
    const hash_no_kernel = trace.tracePayloadHash(state, 0, "dispatch", result.command, null, result);
    const hash_with_kernel = trace.tracePayloadHash(state, 0, "dispatch", result.command, "matmul_4x4", result);
    try testing.expect(hash_no_kernel != hash_with_kernel);
}

test "tracePayloadHash: populated decision fields affect hash" {
    const state = trace.TraceState{};
    const empty = emptyResult();
    const populated = populatedResult();
    const hash_empty = trace.tracePayloadHash(state, 0, "cmd", empty.command, null, empty);
    const hash_pop = trace.tracePayloadHash(state, 0, "cmd", populated.command, null, populated);
    try testing.expect(hash_empty != hash_pop);
}

// ============================================================
// Hash chain continuity — simulated two-event chain

test "hash chain: second event hash depends on first event hash" {
    var state = trace.TraceState{};
    const result = emptyResult();

    const hash1 = trace.tracePayloadHash(state, 0, "upload", result.command, null, result);
    state.previous_hash = hash1;

    const hash2 = trace.tracePayloadHash(state, 1, "upload", result.command, null, result);
    // hash2 must differ from hash1 (different seq and different previous_hash)
    try testing.expect(hash1 != hash2);

    // Replay: recompute chain with same inputs to verify determinism
    var replay_state = trace.TraceState{};
    const replay_hash1 = trace.tracePayloadHash(replay_state, 0, "upload", result.command, null, result);
    try testing.expectEqual(hash1, replay_hash1);
    replay_state.previous_hash = replay_hash1;
    const replay_hash2 = trace.tracePayloadHash(replay_state, 1, "upload", result.command, null, result);
    try testing.expectEqual(hash2, replay_hash2);
}

test "hash chain: three events produce unique hashes" {
    var state = trace.TraceState{};
    const result = emptyResult();

    const hash0 = trace.tracePayloadHash(state, 0, "upload", result.command, null, result);
    state.previous_hash = hash0;

    const hash1 = trace.tracePayloadHash(state, 1, "barrier", result.command, null, result);
    state.previous_hash = hash1;

    const hash2 = trace.tracePayloadHash(state, 2, "dispatch", result.command, null, result);

    try testing.expect(hash0 != hash1);
    try testing.expect(hash1 != hash2);
    try testing.expect(hash0 != hash2);
}

// ============================================================
// printTraceLine — JSON structure and required fields

test "printTraceLine: output contains required trace fields" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    const result = emptyResult();
    try trace.printTraceLine(
        writer,
        0,
        "upload",
        null,
        result,
        1000000,
        0xABCD,
        0x1234,
        null,
    );

    const output = fbs.getWritten();
    // Required fields per trace schema
    try testing.expect(std.mem.indexOf(u8, output, "\"traceVersion\":1") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"module\":\"doe-zig-runtime\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"opCode\":\"dispatch\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"seq\":0") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"timestampMonoNs\":1000000") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"hash\":\"0xabcd\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"previousHash\":\"0x1234\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"command\":\"upload\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"scope\":") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"safetyClass\":") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"verificationMode\":") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"proofLevel\":") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"requiresLean\":") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"blocking\":") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"score\":") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"action\":") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"toggle\":") != null);
}

test "printTraceLine: output ends with newline" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    const result = emptyResult();
    try trace.printTraceLine(writer, 0, "upload", null, result, 0, 0, 0, null);

    const output = fbs.getWritten();
    try testing.expect(output.len > 0);
    try testing.expectEqual(@as(u8, '\n'), output[output.len - 1]);
}

test "printTraceLine: output starts with open brace" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    const result = emptyResult();
    try trace.printTraceLine(writer, 0, "upload", null, result, 0, 0, 0, null);

    const output = fbs.getWritten();
    try testing.expect(output.len > 0);
    try testing.expectEqual(@as(u8, '{'), output[0]);
}

test "printTraceLine: null matched_quirk_id emits matched:null" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    const result = emptyResult();
    try trace.printTraceLine(writer, 0, "upload", null, result, 0, 0, 0, null);

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "\"matched\":null") != null);
}

test "printTraceLine: non-null matched_quirk_id emits matched with value" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    const result = populatedResult();
    try trace.printTraceLine(writer, 0, "dispatch", null, result, 0, 0, 0, null);

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "\"matched\":\"quirk_alignment_001\"") != null);
}

test "printTraceLine: kernel name emitted when present" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    const result = emptyResult();
    try trace.printTraceLine(writer, 0, "dispatch", "matmul_4x4", result, 0, 0, 0, null);

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "\"kernel\":\"matmul_4x4\"") != null);
}

test "printTraceLine: kernel name absent when null" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    const result = emptyResult();
    try trace.printTraceLine(writer, 0, "upload", null, result, 0, 0, 0, null);

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "\"kernel\":") == null);
}

// ============================================================
// printTraceLine — with execution result

test "printTraceLine: execution result fields are emitted" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    const result = emptyResult();
    const exec = execution.ExecutionResult{
        .backend = "vulkan",
        .status = .ok,
        .status_code = "success",
        .duration_ns = 5000,
        .setup_ns = 1000,
        .encode_ns = 2000,
        .submit_wait_ns = 2000,
        .dispatch_count = 4,
        .submit_count = 2,
        .gpu_timestamp_ns = 3500,
        .gpu_timestamp_attempted = true,
        .gpu_timestamp_valid = true,
        .backend_selection_reason = null,
        .fallback_used = null,
        .selection_policy_hash = null,
        .shader_artifact_manifest_path = null,
        .shader_artifact_manifest_hash = null,
        .host_plan_artifact_path = null,
        .host_plan_artifact_hash = null,
        .backend_lane = null,
        .adapter_ordinal = null,
        .queue_family_index = null,
        .present_capable = null,
    };
    try trace.printTraceLine(writer, 0, "dispatch", null, result, 1000, 0xFF, 0x00, exec);

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "\"executionBackend\":\"vulkan\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"backendId\":\"vulkan\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"executionStatus\":\"ok\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"executionDurationNs\":5000") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"executionSetupNs\":1000") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"executionEncodeNs\":2000") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"executionSubmitWaitNs\":2000") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"executionDispatchCount\":4") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"executionSubmitCount\":2") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"executionGpuTimestampNs\":3500") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"executionGpuTimestampAttempted\":true") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"executionGpuTimestampValid\":true") != null);
}

test "printTraceLine: no execution fields when execution is null" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    const result = emptyResult();
    try trace.printTraceLine(writer, 0, "upload", null, result, 0, 0, 0, null);

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "executionBackend") == null);
    try testing.expect(std.mem.indexOf(u8, output, "executionDurationNs") == null);
}

// ============================================================
// printTraceLine — command label with special characters

test "printTraceLine: command label with quotes is JSON-escaped" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    const result = emptyResult();
    try trace.printTraceLine(writer, 0, "cmd\"special", null, result, 0, 0, 0, null);

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "\"command\":\"cmd\\\"special\"") != null);
}

// ============================================================
// printTraceLine — boolean and numeric decision fields

test "printTraceLine: requires_lean=true and blocking=true appear in output" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    const result = populatedResult();
    try trace.printTraceLine(writer, 0, "dispatch", null, result, 0, 0, 0, null);

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "\"requiresLean\":true") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"blocking\":true") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"score\":100") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"matched_count\":3") != null);
}

test "printTraceLine: toggle none when applied_toggle is null" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    const result = emptyResult();
    try trace.printTraceLine(writer, 0, "upload", null, result, 0, 0, 0, null);

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "\"toggle\":\"none\"") != null);
}

test "printTraceLine: toggle value when applied_toggle is set" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    const result = populatedResult();
    try trace.printTraceLine(writer, 0, "dispatch", null, result, 0, 0, 0, null);

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "\"toggle\":\"force_barrier\"") != null);
}

// ============================================================
// printTraceLine — zero timestamp and zero hash

test "printTraceLine: zero values do not crash and produce valid output" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    const result = emptyResult();
    try trace.printTraceLine(writer, 0, "", null, result, 0, 0, 0, null);

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "\"timestampMonoNs\":0") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"hash\":\"0x0\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"previousHash\":\"0x0\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"command\":\"\"") != null);
}

// ============================================================
// TraceRunSummary — struct construction and field defaults

test "TraceRunSummary: optional fields default to null" {
    const summary = trace.TraceRunSummary{
        .trace_version = 1,
        .module_name = "test-module",
        .seq_max = 0,
        .row_count = 0,
        .command_count = 0,
        .matched_count = 0,
        .blocking_count = 0,
        .requires_lean_count = 0,
        .lean_required_count = 0,
        .execution_row_count = 0,
        .execution_success_count = 0,
        .execution_error_count = 0,
        .execution_skipped_count = 0,
        .execution_unsupported_count = 0,
        .execution_total_ns = 0,
        .execution_setup_total_ns = 0,
        .execution_encode_total_ns = 0,
        .execution_submit_wait_total_ns = 0,
        .execution_dispatch_count = 0,
        .execution_submit_count = 0,
        .execution_gpu_timestamp_total_ns = 0,
        .execution_gpu_timestamp_attempted_count = 0,
        .execution_gpu_timestamp_valid_count = 0,
        .execution_backend = null,
        .backend_selection_reason = null,
        .fallback_used = null,
        .selection_policy_hash = null,
        .shader_artifact_manifest_path = null,
        .shader_artifact_manifest_hash = null,
        .backend_lane = null,
        .final_hash = 0,
        .final_previous_hash = 0,
        .profile_vendor = "test",
        .profile_api = "vulkan",
        .profile_family = null,
        .profile_driver = "1.0.0",
    };
    try testing.expect(summary.adapter_ordinal == null);
    try testing.expect(summary.queue_family_index == null);
    try testing.expect(summary.present_capable == null);
    try testing.expect(summary.queue_sync_mode == null);
    try testing.expect(summary.quirk_mode == null);
}

// ============================================================
// printTraceLine — large seq number

test "printTraceLine: large seq number is formatted correctly" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    const result = emptyResult();
    try trace.printTraceLine(writer, 999999, "upload", null, result, 0, 0, 0, null);

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "\"seq\":999999") != null);
}

// ============================================================
// printTraceLine — execution status code normalization

test "printTraceLine: execution status code is normalized in output" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    const result = emptyResult();
    const exec = execution.ExecutionResult{
        .backend = "vulkan",
        .status = .@"error",
        .status_code = "GPU Timeout Error!",
        .duration_ns = 0,
        .setup_ns = 0,
        .encode_ns = 0,
        .submit_wait_ns = 0,
        .dispatch_count = 0,
        .submit_count = 0,
        .gpu_timestamp_ns = 0,
        .gpu_timestamp_attempted = false,
        .gpu_timestamp_valid = false,
        .backend_selection_reason = null,
        .fallback_used = null,
        .selection_policy_hash = null,
        .shader_artifact_manifest_path = null,
        .shader_artifact_manifest_hash = null,
        .host_plan_artifact_path = null,
        .host_plan_artifact_hash = null,
        .backend_lane = null,
        .adapter_ordinal = null,
        .queue_family_index = null,
        .present_capable = null,
    };
    try trace.printTraceLine(writer, 0, "dispatch", null, result, 0, 0, 0, exec);

    const output = fbs.getWritten();
    // Normalized: lowered, non-alnum to _, collapsed, trailing stripped
    try testing.expect(std.mem.indexOf(u8, output, "\"executionStatusCode\":\"gpu_timeout_error\"") != null);
    // Raw message preserved
    try testing.expect(std.mem.indexOf(u8, output, "\"executionStatusMessage\":\"GPU Timeout Error!\"") != null);
}

// ============================================================
// Hash chain — sensitivity to decision.requires_lean toggle

test "tracePayloadHash: requires_lean toggle changes hash" {
    const state = trace.TraceState{};
    var r1 = emptyResult();
    r1.decision.requires_lean = false;
    var r2 = emptyResult();
    r2.decision.requires_lean = true;
    const h1 = trace.tracePayloadHash(state, 0, "upload", r1.command, null, r1);
    const h2 = trace.tracePayloadHash(state, 0, "upload", r2.command, null, r2);
    try testing.expect(h1 != h2);
}

test "tracePayloadHash: is_blocking toggle changes hash" {
    const state = trace.TraceState{};
    var r1 = emptyResult();
    r1.decision.is_blocking = false;
    var r2 = emptyResult();
    r2.decision.is_blocking = true;
    const h1 = trace.tracePayloadHash(state, 0, "upload", r1.command, null, r1);
    const h2 = trace.tracePayloadHash(state, 0, "upload", r2.command, null, r2);
    try testing.expect(h1 != h2);
}

test "tracePayloadHash: score difference changes hash" {
    const state = trace.TraceState{};
    var r1 = emptyResult();
    r1.decision.score = 0;
    var r2 = emptyResult();
    r2.decision.score = 1;
    const h1 = trace.tracePayloadHash(state, 0, "upload", r1.command, null, r1);
    const h2 = trace.tracePayloadHash(state, 0, "upload", r2.command, null, r2);
    try testing.expect(h1 != h2);
}

test "tracePayloadHash: matched_scope difference changes hash" {
    const state = trace.TraceState{};
    var r1 = emptyResult();
    r1.decision.matched_scope = .barrier;
    var r2 = emptyResult();
    r2.decision.matched_scope = .memory;
    const h1 = trace.tracePayloadHash(state, 0, "upload", r1.command, null, r1);
    const h2 = trace.tracePayloadHash(state, 0, "upload", r2.command, null, r2);
    try testing.expect(h1 != h2);
}

test "tracePayloadHash: matched_safety_class difference changes hash" {
    const state = trace.TraceState{};
    var r1 = emptyResult();
    r1.decision.matched_safety_class = .low;
    var r2 = emptyResult();
    r2.decision.matched_safety_class = .critical;
    const h1 = trace.tracePayloadHash(state, 0, "upload", r1.command, null, r1);
    const h2 = trace.tracePayloadHash(state, 0, "upload", r2.command, null, r2);
    try testing.expect(h1 != h2);
}

test "tracePayloadHash: verification_mode difference changes hash" {
    const state = trace.TraceState{};
    var r1 = emptyResult();
    r1.decision.verification_mode = .guard_only;
    var r2 = emptyResult();
    r2.decision.verification_mode = .lean_required;
    const h1 = trace.tracePayloadHash(state, 0, "upload", r1.command, null, r1);
    const h2 = trace.tracePayloadHash(state, 0, "upload", r2.command, null, r2);
    try testing.expect(h1 != h2);
}

test "tracePayloadHash: proof_level difference changes hash" {
    const state = trace.TraceState{};
    var r1 = emptyResult();
    r1.decision.proof_level = .proven;
    var r2 = emptyResult();
    r2.decision.proof_level = .rejected;
    const h1 = trace.tracePayloadHash(state, 0, "upload", r1.command, null, r1);
    const h2 = trace.tracePayloadHash(state, 0, "upload", r2.command, null, r2);
    try testing.expect(h1 != h2);
}
