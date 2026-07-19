//! Structured metadata emission for generated `pe_program.csl` sources.
//!
//! Until now the Python HostPlan executor (`int4ple_hostplan_execution_plan.py`)
//! had to re-discover the per-target binding shape by regex-parsing the CSL
//! text we just emitted. This module emits the same information as a small
//! JSON sidecar (`pe_program.metadata.json`) so the Python side can consume
//! structured truth instead of re-parsing source text.
//!
//! The parser is intentionally line-oriented and conservative: it recognizes
//! exactly the four declaration shapes our own CSL emitters produce
//! (`var <name>: [<size>]<elem>;`, `var <name> = @zeros([<size>]<elem>);`,
//! `var <ptr>: [*]<elem> = &<backing>;`, `@export_symbol(<ptr>, "<symbol>")`).
//! It is not a general CSL parser and does not need to be — its input is
//! always source text our own emitters wrote.

const std = @import("std");

const MAX_DECLS = 64;
const MAX_POINTERS = 64;
const MAX_EXPORTS = 64;
const MAX_CONSTANTS = 64;
const MAX_LAYOUT_EXPORTS = 64;

const Decl = struct {
    name: []const u8,
    size_expr: []const u8,
    elem_type: []const u8,
};

const Pointer = struct {
    name: []const u8,
    backing: []const u8,
    elem_type: []const u8,
};

const ExportEntry = struct {
    symbol: []const u8,
    pointer: []const u8,
};

const Constant = struct {
    kind: []const u8,
    name: []const u8,
    type_name: []const u8,
    expr: []const u8,
};

const Parsed = struct {
    decls: [MAX_DECLS]Decl = undefined,
    decl_count: usize = 0,
    pointers: [MAX_POINTERS]Pointer = undefined,
    pointer_count: usize = 0,
    exports: [MAX_EXPORTS]ExportEntry = undefined,
    export_count: usize = 0,
    constants: [MAX_CONSTANTS]Constant = undefined,
    constant_count: usize = 0,
};

fn isIdentStart(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_';
}

fn isIdent(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

fn skipSpaces(line: []const u8, idx: *usize) void {
    while (idx.* < line.len and (line[idx.*] == ' ' or line[idx.*] == '\t')) idx.* += 1;
}

fn matchKeyword(line: []const u8, idx: *usize, keyword: []const u8) bool {
    if (idx.* + keyword.len > line.len) return false;
    if (!std.mem.eql(u8, line[idx.* .. idx.* + keyword.len], keyword)) return false;
    const after = idx.* + keyword.len;
    if (after < line.len and isIdent(line[after])) return false;
    idx.* = after;
    return true;
}

fn readIdent(line: []const u8, idx: *usize) ?[]const u8 {
    if (idx.* >= line.len or !isIdentStart(line[idx.*])) return null;
    const start = idx.*;
    while (idx.* < line.len and isIdent(line[idx.*])) idx.* += 1;
    return line[start..idx.*];
}

fn matchChar(line: []const u8, idx: *usize, c: u8) bool {
    if (idx.* >= line.len or line[idx.*] != c) return false;
    idx.* += 1;
    return true;
}

fn readBracketedExpr(line: []const u8, idx: *usize) ?[]const u8 {
    if (idx.* >= line.len or line[idx.*] != '[') return null;
    idx.* += 1;
    const start = idx.*;
    while (idx.* < line.len and line[idx.*] != ']') idx.* += 1;
    if (idx.* >= line.len) return null;
    const end = idx.*;
    idx.* += 1;
    return std.mem.trim(u8, line[start..end], " \t");
}

fn parseVarTypedLine(line: []const u8, parsed: *Parsed) void {
    var idx: usize = 0;
    skipSpaces(line, &idx);
    if (!matchKeyword(line, &idx, "var")) return;
    skipSpaces(line, &idx);
    const name = readIdent(line, &idx) orelse return;
    skipSpaces(line, &idx);
    if (!matchChar(line, &idx, ':')) return;
    skipSpaces(line, &idx);
    if (idx >= line.len or line[idx] != '[') return;
    idx += 1;
    skipSpaces(line, &idx);
    if (idx < line.len and line[idx] == '*') {
        idx += 1;
        skipSpaces(line, &idx);
        if (!matchChar(line, &idx, ']')) return;
        skipSpaces(line, &idx);
        const elem = readIdent(line, &idx) orelse return;
        skipSpaces(line, &idx);
        if (!matchChar(line, &idx, '=')) return;
        skipSpaces(line, &idx);
        if (!matchChar(line, &idx, '&')) return;
        skipSpaces(line, &idx);
        const backing = readIdent(line, &idx) orelse return;
        if (parsed.pointer_count >= MAX_POINTERS) return;
        parsed.pointers[parsed.pointer_count] = .{
            .name = name,
            .backing = backing,
            .elem_type = elem,
        };
        parsed.pointer_count += 1;
        return;
    }
    const size_start = idx;
    while (idx < line.len and line[idx] != ']') idx += 1;
    if (idx >= line.len) return;
    const size_expr = std.mem.trim(u8, line[size_start..idx], " \t");
    idx += 1;
    skipSpaces(line, &idx);
    const elem = readIdent(line, &idx) orelse return;
    if (parsed.decl_count >= MAX_DECLS) return;
    parsed.decls[parsed.decl_count] = .{
        .name = name,
        .size_expr = size_expr,
        .elem_type = elem,
    };
    parsed.decl_count += 1;
}

fn parseVarZerosLine(line: []const u8, parsed: *Parsed) void {
    var idx: usize = 0;
    skipSpaces(line, &idx);
    if (!matchKeyword(line, &idx, "var")) return;
    skipSpaces(line, &idx);
    const name = readIdent(line, &idx) orelse return;
    skipSpaces(line, &idx);
    if (!matchChar(line, &idx, '=')) return;
    skipSpaces(line, &idx);
    if (idx + "@zeros".len > line.len) return;
    if (!std.mem.startsWith(u8, line[idx..], "@zeros")) return;
    idx += "@zeros".len;
    skipSpaces(line, &idx);
    if (!matchChar(line, &idx, '(')) return;
    skipSpaces(line, &idx);
    const size_expr = readBracketedExpr(line, &idx) orelse return;
    skipSpaces(line, &idx);
    const elem = readIdent(line, &idx) orelse return;
    if (parsed.decl_count >= MAX_DECLS) return;
    for (parsed.decls[0..parsed.decl_count]) |existing| {
        if (std.mem.eql(u8, existing.name, name)) return;
    }
    parsed.decls[parsed.decl_count] = .{
        .name = name,
        .size_expr = size_expr,
        .elem_type = elem,
    };
    parsed.decl_count += 1;
}

fn parseExportSymbolLine(line: []const u8, parsed: *Parsed) void {
    var idx: usize = 0;
    skipSpaces(line, &idx);
    if (idx + "@export_symbol".len > line.len) return;
    if (!std.mem.startsWith(u8, line[idx..], "@export_symbol")) return;
    idx += "@export_symbol".len;
    skipSpaces(line, &idx);
    if (!matchChar(line, &idx, '(')) return;
    skipSpaces(line, &idx);
    const ptr = readIdent(line, &idx) orelse return;
    skipSpaces(line, &idx);
    if (!matchChar(line, &idx, ',')) return;
    skipSpaces(line, &idx);
    if (!matchChar(line, &idx, '"')) return;
    const sym_start = idx;
    while (idx < line.len and line[idx] != '"') idx += 1;
    if (idx >= line.len) return;
    const symbol = line[sym_start..idx];
    if (parsed.export_count >= MAX_EXPORTS) return;
    parsed.exports[parsed.export_count] = .{
        .symbol = symbol,
        .pointer = ptr,
    };
    parsed.export_count += 1;
}

/// Layout-side metadata: each `@export_name("name", <type>[, true|false])`
/// declaration becomes one entry. `kind` follows the Python convention:
/// `device_function` if the type starts with `fn`, else `device_variable`.
const LayoutExport = struct {
    name: []const u8,
    type_str: []const u8,
    kind: []const u8,
    mutable: bool,
};

const LayoutParsed = struct {
    exports: [MAX_LAYOUT_EXPORTS]LayoutExport = undefined,
    export_count: usize = 0,
};

fn classifyLayoutExportKind(type_str: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, type_str, " \t");
    if (std.mem.startsWith(u8, trimmed, "fn") and
        (trimmed.len == 2 or !isIdent(trimmed[2])))
    {
        return "device_function";
    }
    if (std.mem.indexOf(u8, trimmed, "fn(") != null) {
        return "device_function";
    }
    return "device_variable";
}

fn parseLayoutExportLine(line: []const u8, parsed: *LayoutParsed) void {
    var idx: usize = 0;
    skipSpaces(line, &idx);
    if (idx + "@export_name".len > line.len) return;
    if (!std.mem.startsWith(u8, line[idx..], "@export_name")) return;
    idx += "@export_name".len;
    skipSpaces(line, &idx);
    if (!matchChar(line, &idx, '(')) return;
    skipSpaces(line, &idx);
    if (!matchChar(line, &idx, '"')) return;
    const name_start = idx;
    while (idx < line.len and line[idx] != '"') idx += 1;
    if (idx >= line.len) return;
    const name = line[name_start..idx];
    idx += 1;
    skipSpaces(line, &idx);
    if (!matchChar(line, &idx, ',')) return;
    skipSpaces(line, &idx);
    // Type expression runs until the next top-level `,` (introducing a
    // mutability flag) or the closing `)`. Track parenthesis depth so types
    // like `fn()void` are not split prematurely.
    const type_start = idx;
    var depth: usize = 0;
    var type_end = idx;
    var mutable = false;
    while (idx < line.len) {
        const c = line[idx];
        if (depth == 0 and (c == ',' or c == ')')) break;
        if (c == '(') depth += 1;
        if (c == ')') depth -= 1;
        if (c != ' ' and c != '\t') type_end = idx + 1;
        idx += 1;
    }
    if (type_end == type_start) return;
    if (idx < line.len and line[idx] == ',') {
        idx += 1;
        skipSpaces(line, &idx);
        if (matchKeyword(line, &idx, "true")) {
            mutable = true;
        } else if (matchKeyword(line, &idx, "false")) {
            mutable = false;
        }
    }
    if (parsed.export_count >= MAX_LAYOUT_EXPORTS) return;
    const type_str = line[type_start..type_end];
    parsed.exports[parsed.export_count] = .{
        .name = name,
        .type_str = type_str,
        .kind = classifyLayoutExportKind(type_str),
        .mutable = mutable,
    };
    parsed.export_count += 1;
}

fn parseLayout(source: []const u8) LayoutParsed {
    var parsed = LayoutParsed{};
    var iter = std.mem.splitScalar(u8, source, '\n');
    while (iter.next()) |line| {
        parseLayoutExportLine(line, &parsed);
    }
    return parsed;
}

/// Per-compile-target descriptor, used for the bundle-level
/// `compile/targets.metadata.json` artifact. The Python HostPlan executor
/// reads this to map (kernel, phase) → target name without having to
/// re-implement the suffix-derivation convention that lives in the Zig
/// host-plan tool.
pub const TargetDescriptor = struct {
    name: []const u8,
    base_kernel: []const u8,
    phase: ?[]const u8,
    layout: []const u8,
    pe_program: []const u8,
};

pub fn emitTargetsJson(targets: []const TargetDescriptor, writer: anytype) !void {
    try writer.writeAll("{\n  \"targets\": [");
    for (targets, 0..) |t, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("\n    {");
        try writer.writeAll("\"name\":");
        try writeJsonString(writer, t.name);
        try writer.writeAll(",\"baseKernel\":");
        try writeJsonString(writer, t.base_kernel);
        try writer.writeAll(",\"phase\":");
        if (t.phase) |p| {
            try writeJsonString(writer, p);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"layout\":");
        try writeJsonString(writer, t.layout);
        try writer.writeAll(",\"peProgram\":");
        try writeJsonString(writer, t.pe_program);
        try writer.writeByte('}');
    }
    if (targets.len > 0) try writer.writeAll("\n  ");
    try writer.writeAll("]\n}\n");
}

pub fn emitLayoutJson(source: []const u8, writer: anytype) !void {
    const parsed = parseLayout(source);
    try writer.writeAll("{\n  \"exports\": [");
    for (parsed.exports[0..parsed.export_count], 0..) |e, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("\n    {");
        try writer.writeAll("\"name\":");
        try writeJsonString(writer, e.name);
        try writer.writeAll(",\"type\":");
        try writeJsonString(writer, e.type_str);
        try writer.writeAll(",\"kind\":");
        try writeJsonString(writer, e.kind);
        try writer.writeAll(",\"mutable\":");
        try writer.writeAll(if (e.mutable) "true" else "false");
        try writer.writeByte('}');
    }
    if (parsed.export_count > 0) try writer.writeAll("\n  ");
    try writer.writeAll("]\n}\n");
}

fn parseConstantLine(line: []const u8, parsed: *Parsed) void {
    var idx: usize = 0;
    skipSpaces(line, &idx);
    const kind: []const u8 = if (matchKeyword(line, &idx, "const"))
        "const"
    else if (matchKeyword(line, &idx, "param"))
        "param"
    else
        return;
    skipSpaces(line, &idx);
    const name = readIdent(line, &idx) orelse return;
    skipSpaces(line, &idx);
    if (!matchChar(line, &idx, ':')) return;
    skipSpaces(line, &idx);
    const type_name = readIdent(line, &idx) orelse return;
    skipSpaces(line, &idx);
    // `param X: T;` (no default) is a kernel input — we don't record those
    // because they have no value the host plan can read; the cslc invocation
    // supplies them via --params at compile time.
    if (!matchChar(line, &idx, '=')) return;
    skipSpaces(line, &idx);
    const expr_start = idx;
    var expr_end = idx;
    while (idx < line.len and line[idx] != ';') {
        if (line[idx] != ' ' and line[idx] != '\t') expr_end = idx + 1;
        idx += 1;
    }
    if (expr_end == expr_start) return;
    if (parsed.constant_count >= MAX_CONSTANTS) return;
    parsed.constants[parsed.constant_count] = .{
        .kind = kind,
        .name = name,
        .type_name = type_name,
        .expr = line[expr_start..expr_end],
    };
    parsed.constant_count += 1;
}

fn parse(source: []const u8) Parsed {
    var parsed = Parsed{};
    var iter = std.mem.splitScalar(u8, source, '\n');
    while (iter.next()) |line| {
        // Try each pattern in order. Each is a no-op if the line doesn't
        // match — we don't need to dispatch on a leading keyword.
        parseVarTypedLine(line, &parsed);
        parseVarZerosLine(line, &parsed);
        parseExportSymbolLine(line, &parsed);
        parseConstantLine(line, &parsed);
    }
    return parsed;
}

fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

fn findDecl(parsed: *const Parsed, name: []const u8) ?*const Decl {
    for (parsed.decls[0..parsed.decl_count]) |*d| {
        if (std.mem.eql(u8, d.name, name)) return d;
    }
    return null;
}

fn findPointer(parsed: *const Parsed, name: []const u8) ?*const Pointer {
    for (parsed.pointers[0..parsed.pointer_count]) |*p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

/// Emit a structured metadata JSON document derived from the source text of
/// a generated `pe_program.csl`. The document contains:
///   variables: [{ name, sizeExpr, elemType }]
///   pointers:  [{ name, backing, elemType }]
///   exports:   [{ symbol, pointer, backing?, sizeExpr?, elemType? }]
/// Export entries resolve `pointer` → `backing` → declaration where possible
/// so the Python loader does not need to follow the indirection itself.
pub fn emitJson(source: []const u8, writer: anytype) !void {
    const parsed = parse(source);
    try writer.writeAll("{\n  \"variables\": [");
    for (parsed.decls[0..parsed.decl_count], 0..) |d, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("\n    {");
        try writer.writeAll("\"name\":");
        try writeJsonString(writer, d.name);
        try writer.writeAll(",\"sizeExpr\":");
        try writeJsonString(writer, d.size_expr);
        try writer.writeAll(",\"elemType\":");
        try writeJsonString(writer, d.elem_type);
        try writer.writeByte('}');
    }
    if (parsed.decl_count > 0) try writer.writeAll("\n  ");
    try writer.writeAll("],\n  \"pointers\": [");
    for (parsed.pointers[0..parsed.pointer_count], 0..) |p, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("\n    {");
        try writer.writeAll("\"name\":");
        try writeJsonString(writer, p.name);
        try writer.writeAll(",\"backing\":");
        try writeJsonString(writer, p.backing);
        try writer.writeAll(",\"elemType\":");
        try writeJsonString(writer, p.elem_type);
        try writer.writeByte('}');
    }
    if (parsed.pointer_count > 0) try writer.writeAll("\n  ");
    try writer.writeAll("],\n  \"exports\": [");
    for (parsed.exports[0..parsed.export_count], 0..) |e, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("\n    {");
        try writer.writeAll("\"symbol\":");
        try writeJsonString(writer, e.symbol);
        try writer.writeAll(",\"pointer\":");
        try writeJsonString(writer, e.pointer);
        if (findPointer(&parsed, e.pointer)) |ptr| {
            try writer.writeAll(",\"backing\":");
            try writeJsonString(writer, ptr.backing);
            if (findDecl(&parsed, ptr.backing)) |decl| {
                try writer.writeAll(",\"sizeExpr\":");
                try writeJsonString(writer, decl.size_expr);
                try writer.writeAll(",\"elemType\":");
                try writeJsonString(writer, decl.elem_type);
            }
        }
        try writer.writeByte('}');
    }
    if (parsed.export_count > 0) try writer.writeAll("\n  ");
    try writer.writeAll("],\n  \"compileTimeConstants\": [");
    for (parsed.constants[0..parsed.constant_count], 0..) |c, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("\n    {");
        try writer.writeAll("\"kind\":");
        try writeJsonString(writer, c.kind);
        try writer.writeAll(",\"name\":");
        try writeJsonString(writer, c.name);
        try writer.writeAll(",\"type\":");
        try writeJsonString(writer, c.type_name);
        try writer.writeAll(",\"expr\":");
        try writeJsonString(writer, c.expr);
        try writer.writeByte('}');
    }
    if (parsed.constant_count > 0) try writer.writeAll("\n  ");
    try writer.writeAll("]\n}\n");
}

test "parses tiled SUMMA exports" {
    const source =
        \\param Mt: i16;
        \\param Kt: i16;
        \\var A_tile = @zeros([Mt * Kt]f32);
        \\var B_tile = @zeros([Kt * Nt]f32);
        \\var A_ptr: [*]f32 = &A_tile;
        \\var B_ptr: [*]f32 = &B_tile;
        \\@export_symbol(A_ptr, "a");
        \\@export_symbol(B_ptr, "b");
    ;
    const parsed = parse(source);
    try std.testing.expectEqual(@as(usize, 2), parsed.decl_count);
    try std.testing.expectEqual(@as(usize, 2), parsed.pointer_count);
    try std.testing.expectEqual(@as(usize, 2), parsed.export_count);
    try std.testing.expectEqualStrings("A_tile", parsed.decls[0].name);
    try std.testing.expectEqualStrings("Mt * Kt", parsed.decls[0].size_expr);
    try std.testing.expectEqualStrings("f32", parsed.decls[0].elem_type);
    try std.testing.expectEqualStrings("A_ptr", parsed.pointers[0].name);
    try std.testing.expectEqualStrings("A_tile", parsed.pointers[0].backing);
    try std.testing.expectEqualStrings("a", parsed.exports[0].symbol);
}

test "emits targets metadata with phase and base kernel" {
    const targets = [_]TargetDescriptor{
        .{ .name = "rmsnorm", .base_kernel = "rmsnorm", .phase = null, .layout = "rmsnorm/layout.csl", .pe_program = "rmsnorm/pe_program.csl" },
        .{ .name = "rmsnorm_prefill", .base_kernel = "rmsnorm", .phase = "prefill", .layout = "rmsnorm/layout.csl", .pe_program = "rmsnorm/pe_program.csl" },
        .{ .name = "rmsnorm_decode", .base_kernel = "rmsnorm", .phase = "decode", .layout = "rmsnorm/layout.csl", .pe_program = "rmsnorm/pe_program.csl" },
    };
    var buf: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try emitTargetsJson(&targets, stream.writer());
    const out = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"rmsnorm_prefill\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"phase\":\"prefill\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"phase\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"baseKernel\":\"rmsnorm\"") != null);
}

test "parses layout export_name declarations" {
    const source =
        \\layout {
        \\    @set_rectangle(width, 1);
        \\    @export_name("input", [*]f32, true);
        \\    @export_name("weight", [*]f32, true);
        \\    @export_name("output", [*]f32, true);
        \\    @export_name("compute", fn()void);
        \\}
    ;
    const parsed = parseLayout(source);
    try std.testing.expectEqual(@as(usize, 4), parsed.export_count);
    try std.testing.expectEqualStrings("input", parsed.exports[0].name);
    try std.testing.expectEqualStrings("[*]f32", parsed.exports[0].type_str);
    try std.testing.expectEqualStrings("device_variable", parsed.exports[0].kind);
    try std.testing.expectEqual(true, parsed.exports[0].mutable);
    try std.testing.expectEqualStrings("compute", parsed.exports[3].name);
    try std.testing.expectEqualStrings("fn()void", parsed.exports[3].type_str);
    try std.testing.expectEqualStrings("device_function", parsed.exports[3].kind);
    try std.testing.expectEqual(false, parsed.exports[3].mutable);
}

test "parses const and param-with-default declarations" {
    const source =
        \\param chunk_size: i16 = 1024;
        \\param hidden_size: i16;
        \\const QK_K: u32 = 256;
        \\const Q4K_BLOCK_BYTES: u32 = 144;
        \\const rms_eps: f32 = 0.000001;
    ;
    const parsed = parse(source);
    try std.testing.expectEqual(@as(usize, 4), parsed.constant_count);
    try std.testing.expectEqualStrings("param", parsed.constants[0].kind);
    try std.testing.expectEqualStrings("chunk_size", parsed.constants[0].name);
    try std.testing.expectEqualStrings("i16", parsed.constants[0].type_name);
    try std.testing.expectEqualStrings("1024", parsed.constants[0].expr);
    try std.testing.expectEqualStrings("const", parsed.constants[1].kind);
    try std.testing.expectEqualStrings("QK_K", parsed.constants[1].name);
    try std.testing.expectEqualStrings("rms_eps", parsed.constants[3].name);
    try std.testing.expectEqualStrings("0.000001", parsed.constants[3].expr);
}

test "parses rmsnorm semantic-emitter style typed vars" {
    const source =
        \\var input: [hidden_size]f32 = @zeros([hidden_size]f32);
        \\var weight: [hidden_size]f32 = @zeros([hidden_size]f32);
        \\var input_ptr: [*]f32 = &input;
        \\var weight_ptr: [*]f32 = &weight;
        \\@export_symbol(input_ptr, "input");
        \\@export_symbol(weight_ptr, "weight");
        \\@export_symbol(compute);
    ;
    const parsed = parse(source);
    try std.testing.expectEqual(@as(usize, 2), parsed.decl_count);
    try std.testing.expectEqualStrings("input", parsed.decls[0].name);
    try std.testing.expectEqualStrings("hidden_size", parsed.decls[0].size_expr);
    try std.testing.expectEqualStrings("f32", parsed.decls[0].elem_type);
    try std.testing.expectEqual(@as(usize, 2), parsed.export_count);
}
