// doe_shader_compilation_info_native.zig — GPUShaderModule.getCompilationInfo().
//
// Returns compilation diagnostics captured during shader module creation.
// When the module was created successfully (the common case) the message list
// is empty.  When the WGSL compiler recorded an error before returning null,
// the error details are extracted from the per-module error fields and returned
// as a single-entry JSON array so that callers receive actionable information.
//
// Output format (JSON array of message objects):
//   [{"message":"...","type":"error","lineNum":N,"linePos":N,"offset":0,"length":0}]
// An empty array ("[]") is returned when there are no diagnostics.
//
// The returned JSON is a NUL-terminated C string backed by a static buffer
// (single-threaded read; safe for synchronous N-API calls).  Callers must
// NOT free this pointer; it remains valid until the next call.

const std = @import("std");
const native_types = @import("../support/doe_native_object_types.zig");
const native_helpers = @import("../support/doe_native_object_helpers.zig");

const cast = native_helpers.cast;
const DoeShaderModule = native_types.DoeShaderModule;

// ============================================================
// Imports from the WGSL compiler — error metadata query
// ============================================================

const wgsl_analysis = @import("../../compiler/wgsl/pipeline/analysis.zig");

// ============================================================
// Static output buffer
// ============================================================

// Sufficient for one error message with reasonable length.
// JSON schema: [{"message":"<msg>","type":"error","lineNum":<n>,"linePos":<n>,"offset":0,"length":0}]
const OUT_CAP: usize = 1024;
var out_buf: [OUT_CAP]u8 = undefined;

// Static NUL-terminated empty-array result.
const EMPTY_JSON: [*:0]const u8 = "[]";

const WgslDirectiveDiagnostics = struct {
    line: u32 = 0,
    column: u32 = 0,
    name: [32]u8 = [_]u8{0} ** 32,
    name_len: usize = 0,
};

fn append_json_escaped(writer: anytype, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n', '\r', '\t' => try writer.writeByte(' '),
            else => {
                if (c < 0x20) {
                    try writer.writeByte(' ');
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}

fn write_json_message(
    writer: anytype,
    first: *bool,
    kind: []const u8,
    message: []const u8,
    line: u32,
    column: u32,
) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
    try writer.writeAll("{\"message\":\"");
    try append_json_escaped(writer, message);
    try writer.writeAll("\",\"type\":\"");
    try writer.writeAll(kind);
    try writer.writeAll("\",\"lineNum\":");
    try writer.print("{d}", .{line});
    try writer.writeAll(",\"linePos\":");
    try writer.print("{d}", .{column});
    try writer.writeAll(",\"offset\":0,\"length\":0}");
}

fn scan_enable_directive(line_text: []const u8, line_no: u32) ?WgslDirectiveDiagnostics {
    const trimmed = std.mem.trimLeft(u8, line_text, " \t");
    if (!std.mem.startsWith(u8, trimmed, "enable ")) return null;
    const column_offset = line_text.len - trimmed.len;
    const name_start = "enable ".len;
    var name_end = name_start;
    while (name_end < trimmed.len) : (name_end += 1) {
        const c = trimmed[name_end];
        if (!std.ascii.isAlphabetic(c) and !std.ascii.isDigit(c) and c != '_' and c != '-') break;
    }
    if (name_end == name_start) return null;
    var result = WgslDirectiveDiagnostics{
        .line = line_no,
        .column = @intCast(column_offset + name_start + 1),
    };
    result.name_len = @min(name_end - name_start, result.name.len);
    @memcpy(result.name[0..result.name_len], trimmed[name_start .. name_start + result.name_len]);
    return result;
}

fn find_diagnostic_directive(line_text: []const u8, line_no: u32) ?WgslDirectiveDiagnostics {
    const idx = std.mem.indexOf(u8, line_text, "diagnostic(") orelse return null;
    return .{
        .line = line_no,
        .column = @intCast(idx + 1),
    };
}

fn build_wgsl_diagnostic_json(wgsl: []const u8) ?[*:0]const u8 {
    var stream = std.io.fixedBufferStream(&out_buf);
    const writer = stream.writer();
    writer.writeByte('[') catch return null;
    var first = true;
    var line_no: u32 = 1;
    var line_iter = std.mem.splitScalar(u8, wgsl, '\n');
    while (line_iter.next()) |line_text| : (line_no += 1) {
        if (scan_enable_directive(line_text, line_no)) |enable_info| {
            const name = enable_info.name[0..enable_info.name_len];
            var msg_buf: [96]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &msg_buf,
                "WGSL enable directive `{s}` accepted by the Doe compiler.",
                .{name},
            ) catch return null;
            write_json_message(writer, &first, "info", msg, enable_info.line, enable_info.column) catch return null;
        }
        if (find_diagnostic_directive(line_text, line_no)) |diag_info| {
            write_json_message(
                writer,
                &first,
                "warning",
                "WGSL diagnostic directives are parsed, but Doe does not yet enforce diagnostic filtering semantics during compilation.",
                diag_info.line,
                diag_info.column,
            ) catch return null;
        }
    }
    writer.writeByte(']') catch return null;
    const json = stream.getWritten();
    if (json.len >= out_buf.len) return null;
    out_buf[json.len] = 0;
    return @ptrCast(out_buf[0..].ptr);
}

// ============================================================
// Exported API
// ============================================================

// doeNativeShaderModuleGetCompilationInfo — retrieve compilation diagnostics
// for a previously created shader module.
//
// module_raw: opaque pointer to DoeShaderModule.
// Returns a pointer to a NUL-terminated JSON string.  The pointer remains
// valid until the next call to this function.  Callers must NOT free it.
//
// Behaviour:
//   - If the module handle is valid, returns informational diagnostics for
//     successful compilation. Non-Metal native shader modules also receive an
//     advisory warning that only fatal compiler diagnostics are preserved.
//   - If the module handle is null (e.g. createShaderModule returned null and
//     the caller is querying diagnostics on a null handle), returns the last
//     recorded WGSL error as a single-entry error array.
pub export fn doeNativeShaderModuleGetCompilationInfo(
    module_raw: ?*anyopaque,
) callconv(.c) [*:0]const u8 {
    if (cast(DoeShaderModule, module_raw)) |module| {
        if (module.compilation_message) |message| {
            var stream = std.io.fixedBufferStream(&out_buf);
            const writer = stream.writer();
            writer.writeByte('[') catch return EMPTY_JSON;
            var first = true;
            write_json_message(
                writer,
                &first,
                switch (module.compilation_message_kind) {
                    .@"error" => "error",
                    .warning => "warning",
                    .info => "info",
                    .none => "info",
                },
                message,
                module.compilation_message_line,
                module.compilation_message_column,
            ) catch return EMPTY_JSON;
            writer.writeByte(']') catch return EMPTY_JSON;
            const json = stream.getWritten();
            if (json.len >= out_buf.len) return EMPTY_JSON;
            out_buf[json.len] = 0;
            return @ptrCast(out_buf[0..].ptr);
        }
        if (module.wgsl_source) |wgsl| {
            if (build_wgsl_diagnostic_json(wgsl)) |json| {
                return json;
            }
        }
        return EMPTY_JSON;
    }

    // Module is null: the creation call failed.  Surface the last WGSL error.
    const msg = wgsl_analysis.lastErrorMessage();
    if (msg.len == 0) {
        return EMPTY_JSON;
    }

    const line = wgsl_analysis.lastErrorLine();
    const col = wgsl_analysis.lastErrorColumn();

    // Build escaped message: replace " with \", \ with \\, control chars with space.
    var escaped: [OUT_CAP]u8 = undefined;
    var ei: usize = 0;
    for (msg) |c| {
        if (ei + 2 >= escaped.len) break;
        if (c == '"') {
            escaped[ei] = '\\';
            ei += 1;
            escaped[ei] = '"';
            ei += 1;
        } else if (c == '\\') {
            escaped[ei] = '\\';
            ei += 1;
            escaped[ei] = '\\';
            ei += 1;
        } else if (c < 0x20) {
            escaped[ei] = ' ';
            ei += 1;
        } else {
            escaped[ei] = c;
            ei += 1;
        }
    }
    const escaped_msg = escaped[0..ei];

    const json = std.fmt.bufPrint(
        &out_buf,
        "[{{\"message\":\"{s}\",\"type\":\"error\",\"lineNum\":{d},\"linePos\":{d},\"offset\":0,\"length\":0}}]",
        .{ escaped_msg, line, col },
    ) catch {
        return EMPTY_JSON;
    };
    // Ensure NUL termination.
    if (json.len < out_buf.len) {
        out_buf[json.len] = 0;
    } else {
        out_buf[OUT_CAP - 1] = 0;
    }
    return @ptrCast(out_buf[0..].ptr);
}
