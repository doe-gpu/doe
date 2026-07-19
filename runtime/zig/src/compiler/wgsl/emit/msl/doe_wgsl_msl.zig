// doe_wgsl_msl.zig — WGSL → MSL translator for compute, vertex, and fragment shaders.
//
// Supports:
// - Compute: storage buffers, builtins, body pass-through.
// - Vertex: @location(N) inputs → VertexIn struct, @builtin(position) output.
// - Fragment: @location(N) outputs → FragmentOut struct.
// - Body: vec*() constructor rewriting (vec4f→float4 etc).
//
// Limitations (v0.2):
// - Only the first `fn` is parsed as the entry point. Helper functions not supported.
// - WGSL struct declarations (inter-stage structs) are not parsed.
// - let/var type annotations not rewritten. Body rewriting is limited to
//   type constructors (vec4f→float4) and does not handle texture builtins.
// - @workgroup_size is not parsed or emitted.
// - Comments/strings containing braces or keywords can confuse the parser.

const std = @import("std");

pub const TranslateError = error{
    InvalidWgsl,
    OutputTooLarge,
    OutOfMemory,
};

pub const MAX_OUTPUT: usize = 64 * 1024;
pub const MAX_BINDINGS: usize = 16;
const MAX_LOCATIONS: usize = 16;

const ShaderStage = enum { compute, vertex, fragment };

const Binding = struct {
    group: u32,
    binding: u32,
    name: []const u8,
    is_read_only: bool,
    elem_type: []const u8,
};

const BuiltinParam = struct {
    param_name: []const u8,
    msl_type: []const u8,
    msl_attr: []const u8,
};

const LocationParam = struct {
    location: u32,
    name: []const u8,
    msl_type: []const u8,
};

const Builtin = struct {
    name: []const u8,
    wgsl_type: []const u8,
    msl_attr: []const u8,
    msl_type: []const u8,
};

const BUILTINS = [_]Builtin{
    .{ .name = "global_invocation_id", .wgsl_type = "vec3u", .msl_attr = "thread_position_in_grid", .msl_type = "uint3" },
    .{ .name = "local_invocation_id", .wgsl_type = "vec3u", .msl_attr = "thread_position_in_threadgroup", .msl_type = "uint3" },
    .{ .name = "workgroup_id", .wgsl_type = "vec3u", .msl_attr = "threadgroup_position_in_grid", .msl_type = "uint3" },
    .{ .name = "num_workgroups", .wgsl_type = "vec3u", .msl_attr = "threadgroups_per_grid", .msl_type = "uint3" },
    .{ .name = "local_invocation_index", .wgsl_type = "u32", .msl_attr = "thread_index_in_threadgroup", .msl_type = "uint" },
};

// WGSL type constructor → MSL type replacement pairs.
const VEC_REPLACEMENTS = [_]struct { wgsl: []const u8, msl: []const u8 }{
    // Scalar casts.
    .{ .wgsl = "f32(", .msl = "float(" },
    .{ .wgsl = "f16(", .msl = "half(" },
    .{ .wgsl = "i32(", .msl = "int(" },
    .{ .wgsl = "u32(", .msl = "uint(" },
    .{ .wgsl = "bool(", .msl = "bool(" },
    // Vector constructors.
    .{ .wgsl = "vec2f(", .msl = "float2(" },
    .{ .wgsl = "vec3f(", .msl = "float3(" },
    .{ .wgsl = "vec4f(", .msl = "float4(" },
    .{ .wgsl = "vec2u(", .msl = "uint2(" },
    .{ .wgsl = "vec3u(", .msl = "uint3(" },
    .{ .wgsl = "vec4u(", .msl = "uint4(" },
    .{ .wgsl = "vec2i(", .msl = "int2(" },
    .{ .wgsl = "vec3i(", .msl = "int3(" },
    .{ .wgsl = "vec4i(", .msl = "int4(" },
    .{ .wgsl = "vec2<f32>(", .msl = "float2(" },
    .{ .wgsl = "vec3<f32>(", .msl = "float3(" },
    .{ .wgsl = "vec4<f32>(", .msl = "float4(" },
    .{ .wgsl = "vec2<u32>(", .msl = "uint2(" },
    .{ .wgsl = "vec3<u32>(", .msl = "uint3(" },
    .{ .wgsl = "vec4<u32>(", .msl = "uint4(" },
    .{ .wgsl = "vec2<i32>(", .msl = "int2(" },
    .{ .wgsl = "vec3<i32>(", .msl = "int3(" },
    .{ .wgsl = "vec4<i32>(", .msl = "int4(" },
    .{ .wgsl = "vec2h(", .msl = "half2(" },
    .{ .wgsl = "vec3h(", .msl = "half3(" },
    .{ .wgsl = "vec4h(", .msl = "half4(" },
    .{ .wgsl = "vec2<f16>(", .msl = "half2(" },
    .{ .wgsl = "vec3<f16>(", .msl = "half3(" },
    .{ .wgsl = "vec4<f16>(", .msl = "half4(" },
};

pub const BindingMeta = struct {
    group: u32,
    binding: u32,
};

/// Extract binding metadata from WGSL source. Returns number of bindings found.
pub fn extractBindings(wgsl: []const u8, out: []BindingMeta) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, wgsl, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (parseBinding(trimmed)) |b| {
            if (count < out.len) {
                out[count] = .{ .group = b.group, .binding = b.binding };
                count += 1;
            }
        }
    }
    return count;
}

/// Translate a WGSL shader to MSL. Returns the MSL source length written.
pub fn translate(wgsl: []const u8, out: []u8) TranslateError!usize {
    const stage = detectStage(wgsl);
    return switch (stage) {
        .compute => translateCompute(wgsl, out),
        .vertex => translateVertex(wgsl, out),
        .fragment => translateFragment(wgsl, out),
    };
}

// ============================================================
// Stage detection
// ============================================================

fn detectStage(wgsl: []const u8) ShaderStage {
    var lines = std.mem.splitScalar(u8, wgsl, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.indexOf(u8, trimmed, "@vertex") != null) return .vertex;
        if (std.mem.indexOf(u8, trimmed, "@fragment") != null) return .fragment;
        if (std.mem.indexOf(u8, trimmed, "@compute") != null) return .compute;
    }
    return .compute;
}

// ============================================================
// Compute translation (original logic, unchanged behavior)
// ============================================================

fn translateCompute(wgsl: []const u8, out: []u8) TranslateError!usize {
    var bindings: [MAX_BINDINGS]Binding = undefined;
    var binding_count: usize = 0;
    var builtin_params: [8]BuiltinParam = undefined;
    var builtin_count: usize = 0;

    var lines = std.mem.splitScalar(u8, wgsl, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        // Strip WGSL extension directives — Metal supports f16 natively.
        if (std.mem.startsWith(u8, trimmed, "enable ")) continue;
        if (parseBinding(trimmed)) |b| {
            if (binding_count < MAX_BINDINGS) {
                bindings[binding_count] = b;
                binding_count += 1;
            }
        }
        if (std.mem.startsWith(u8, trimmed, "fn ")) {
            builtin_count = parseFnBuiltins(trimmed, &builtin_params);
        }
    }

    const body = findFnBody(wgsl) orelse return TranslateError.InvalidWgsl;

    var w = Writer{ .buf = out, .pos = 0 };
    try w.write("#include <metal_stdlib>\nusing namespace metal;\n\n");
    try w.write("kernel void main_kernel(\n");

    var param_idx: usize = 0;
    for (bindings[0..binding_count]) |b| {
        if (param_idx > 0) try w.write(",\n");
        try w.write("    ");
        if (b.is_read_only) try w.write("const ");
        try w.write("device ");
        try w.write(b.elem_type);
        try w.write("* ");
        try w.write(b.name);
        try w.write(" [[buffer(");
        try w.writeInt(b.binding);
        try w.write(")]]");
        param_idx += 1;
    }
    for (builtin_params[0..builtin_count]) |bp| {
        if (param_idx > 0) try w.write(",\n");
        try w.write("    ");
        try w.write(bp.msl_type);
        try w.write(" ");
        try w.write(bp.param_name);
        try w.write(" [[");
        try w.write(bp.msl_attr);
        try w.write("]]");
        param_idx += 1;
    }

    try w.write("\n) {\n");
    try writeBodyRewritten(&w, body);
    try w.write("}\n");
    return w.pos;
}

// ============================================================
// Vertex translation
// ============================================================

fn translateVertex(wgsl: []const u8, out: []u8) TranslateError!usize {
    var inputs: [MAX_LOCATIONS]LocationParam = undefined;
    var input_count: usize = 0;

    // Parse the fn line for @location(N) params.
    var lines = std.mem.splitScalar(u8, wgsl, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "fn ") or
            (std.mem.indexOf(u8, trimmed, "fn ") != null and std.mem.indexOf(u8, trimmed, "@vertex") != null))
        {
            input_count = parseFnLocations(trimmed, &inputs);
            break;
        }
    }

    // Parse return type for @builtin(position) and @location outputs.
    const ret_info = parseReturnInfo(wgsl);
    const body = findFnBody(wgsl) orelse return TranslateError.InvalidWgsl;

    var w = Writer{ .buf = out, .pos = 0 };
    try w.write("#include <metal_stdlib>\nusing namespace metal;\n\n");

    // VertexIn struct (from @location params).
    if (input_count > 0) {
        try w.write("struct VertexIn {\n");
        for (inputs[0..input_count]) |inp| {
            try w.write("    ");
            try w.write(inp.msl_type);
            try w.write(" ");
            try w.write(inp.name);
            try w.write(" [[attribute(");
            try w.writeInt(inp.location);
            try w.write(")]];\n");
        }
        try w.write("};\n\n");
    }

    // VertexOut struct.
    try w.write("struct VertexOut {\n");
    if (ret_info.has_position) {
        try w.write("    float4 _position [[position]];\n");
    }
    for (ret_info.locations[0..ret_info.location_count]) |loc| {
        try w.write("    ");
        try w.write(loc.msl_type);
        try w.write(" _loc");
        try w.writeInt(loc.location);
        try w.write(" [[user(loc");
        try w.writeInt(loc.location);
        try w.write(")]];\n");
    }
    try w.write("};\n\n");

    // Function signature.
    try w.write("vertex VertexOut main_vertex(\n");
    var param_idx: usize = 0;
    if (input_count > 0) {
        try w.write("    VertexIn in [[stage_in]]");
        param_idx += 1;
    }
    try w.write("\n) {\n");

    // Body with vec constructor rewriting.
    try writeBodyRewritten(&w, body);

    try w.write("}\n");
    return w.pos;
}

// ============================================================
// Fragment translation
// ============================================================

fn translateFragment(wgsl: []const u8, out: []u8) TranslateError!usize {
    // Parse return @location(N) outputs.
    const ret_info = parseReturnInfo(wgsl);
    const body = findFnBody(wgsl) orelse return TranslateError.InvalidWgsl;

    // Parse input @location params (inter-stage from vertex).
    var inputs: [MAX_LOCATIONS]LocationParam = undefined;
    var input_count: usize = 0;
    var frag_lines = std.mem.splitScalar(u8, wgsl, '\n');
    while (frag_lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "fn ") or
            (std.mem.indexOf(u8, trimmed, "fn ") != null and std.mem.indexOf(u8, trimmed, "@fragment") != null))
        {
            input_count = parseFnLocations(trimmed, &inputs);
            break;
        }
    }

    var w = Writer{ .buf = out, .pos = 0 };
    try w.write("#include <metal_stdlib>\nusing namespace metal;\n\n");

    // FragmentIn struct (from vertex outputs).
    if (input_count > 0) {
        try w.write("struct FragmentIn {\n");
        for (inputs[0..input_count]) |inp| {
            try w.write("    ");
            try w.write(inp.msl_type);
            try w.write(" ");
            try w.write(inp.name);
            try w.write(" [[user(loc");
            try w.writeInt(inp.location);
            try w.write(")]];\n");
        }
        try w.write("};\n\n");
    }

    // FragmentOut struct.
    try w.write("struct FragmentOut {\n");
    if (ret_info.location_count > 0) {
        for (ret_info.locations[0..ret_info.location_count]) |loc| {
            try w.write("    ");
            try w.write(loc.msl_type);
            try w.write(" color");
            try w.writeInt(loc.location);
            try w.write(" [[color(");
            try w.writeInt(loc.location);
            try w.write(")]];\n");
        }
    } else {
        try w.write("    float4 color0 [[color(0)]];\n");
    }
    try w.write("};\n\n");

    // Function signature.
    try w.write("fragment FragmentOut main_fragment(\n");
    if (input_count > 0) {
        try w.write("    FragmentIn in [[stage_in]]");
    }
    try w.write("\n) {\n");

    try writeBodyRewritten(&w, body);

    try w.write("}\n");
    return w.pos;
}

// ============================================================
// Shared parsing helpers
// ============================================================

fn findFnBody(wgsl: []const u8) ?[]const u8 {
    var in_fn = false;
    var brace_depth: i32 = 0;
    var body_brace_start: usize = 0;
    for (wgsl, 0..) |ch, i| {
        if (!in_fn) {
            if (i + 3 <= wgsl.len and std.mem.eql(u8, wgsl[i .. i + 3], "fn ")) {
                in_fn = true;
            }
        }
        if (in_fn) {
            if (ch == '{') {
                if (brace_depth == 0) body_brace_start = i + 1;
                brace_depth += 1;
            } else if (ch == '}') {
                brace_depth -= 1;
                if (brace_depth == 0) {
                    return wgsl[body_brace_start..i];
                }
            }
        }
    }
    return null;
}

fn parseBinding(line: []const u8) ?Binding {
    const group_prefix = "@group(";
    const gi = std.mem.indexOf(u8, line, group_prefix) orelse return null;
    const g_start = gi + group_prefix.len;
    const g_end = std.mem.indexOfPos(u8, line, g_start, ")") orelse return null;
    const group = std.fmt.parseInt(u32, line[g_start..g_end], 10) catch return null;

    const bind_prefix = "@binding(";
    const bi = std.mem.indexOf(u8, line, bind_prefix) orelse return null;
    const b_start = bi + bind_prefix.len;
    const b_end = std.mem.indexOfPos(u8, line, b_start, ")") orelse return null;
    const binding = std.fmt.parseInt(u32, line[b_start..b_end], 10) catch return null;

    const var_idx = std.mem.indexOf(u8, line, "var<") orelse return null;
    const gt_idx = std.mem.indexOfPos(u8, line, var_idx, ">") orelse return null;
    const storage_spec = line[var_idx .. gt_idx + 1];
    const is_read_only = std.mem.indexOf(u8, storage_spec, "read_write") == null;

    const after_gt = std.mem.trim(u8, line[gt_idx + 1 ..], " \t");
    const name_end = std.mem.indexOfAny(u8, after_gt, " :\t;") orelse after_gt.len;
    const name = after_gt[0..name_end];
    if (name.len == 0) return null;

    const elem_type = parseElemType(line) orelse "float";
    return Binding{
        .group = group,
        .binding = binding,
        .name = name,
        .is_read_only = is_read_only,
        .elem_type = elem_type,
    };
}

fn parseElemType(line: []const u8) ?[]const u8 {
    const arr_idx = std.mem.indexOf(u8, line, "array<") orelse return null;
    const start = arr_idx + 6;
    const end = std.mem.indexOfPos(u8, line, start, ">") orelse return null;
    const inner = line[start..end];
    const comma = std.mem.indexOf(u8, inner, ",");
    const type_str = std.mem.trim(u8, if (comma) |c| inner[0..c] else inner, " \t");
    return wgslTypeToMsl(type_str);
}

fn wgslTypeToMsl(t: []const u8) []const u8 {
    if (std.mem.eql(u8, t, "f32")) return "float";
    if (std.mem.eql(u8, t, "u32")) return "uint";
    if (std.mem.eql(u8, t, "i32")) return "int";
    if (std.mem.eql(u8, t, "f16")) return "half";
    if (std.mem.eql(u8, t, "vec2f") or std.mem.eql(u8, t, "vec2<f32>")) return "float2";
    if (std.mem.eql(u8, t, "vec3f") or std.mem.eql(u8, t, "vec3<f32>")) return "float3";
    if (std.mem.eql(u8, t, "vec4f") or std.mem.eql(u8, t, "vec4<f32>")) return "float4";
    if (std.mem.eql(u8, t, "vec2u") or std.mem.eql(u8, t, "vec2<u32>")) return "uint2";
    if (std.mem.eql(u8, t, "vec3u") or std.mem.eql(u8, t, "vec3<u32>")) return "uint3";
    if (std.mem.eql(u8, t, "vec4u") or std.mem.eql(u8, t, "vec4<u32>")) return "uint4";
    if (std.mem.eql(u8, t, "vec2i") or std.mem.eql(u8, t, "vec2<i32>")) return "int2";
    if (std.mem.eql(u8, t, "vec3i") or std.mem.eql(u8, t, "vec3<i32>")) return "int3";
    if (std.mem.eql(u8, t, "vec4i") or std.mem.eql(u8, t, "vec4<i32>")) return "int4";
    return "float";
}

fn parseFnBuiltins(line: []const u8, out: []BuiltinParam) usize {
    const paren_start = std.mem.indexOf(u8, line, "(") orelse return 0;
    const paren_end = std.mem.lastIndexOf(u8, line, ")") orelse return 0;
    if (paren_start >= paren_end) return 0;
    const params = line[paren_start + 1 .. paren_end];

    var count: usize = 0;
    var iter = std.mem.splitScalar(u8, params, ',');
    while (iter.next()) |param| {
        const trimmed = std.mem.trim(u8, param, " \t");
        if (std.mem.indexOf(u8, trimmed, "@builtin(")) |bii| {
            const b_start = bii + 9;
            const b_end = std.mem.indexOfPos(u8, trimmed, b_start, ")") orelse continue;
            const builtin_name = trimmed[b_start..b_end];
            const after_close = std.mem.trim(u8, trimmed[b_end + 1 ..], " \t");
            const name_end = std.mem.indexOfAny(u8, after_close, " :\t") orelse after_close.len;
            const param_name = after_close[0..name_end];
            for (BUILTINS) |b| {
                if (std.mem.eql(u8, builtin_name, b.name)) {
                    if (count < out.len) {
                        out[count] = .{
                            .param_name = param_name,
                            .msl_type = b.msl_type,
                            .msl_attr = b.msl_attr,
                        };
                        count += 1;
                    }
                    break;
                }
            }
        }
    }
    return count;
}

/// Parse @location(N) parameters from a fn signature line.
fn parseFnLocations(line: []const u8, out: []LocationParam) usize {
    const paren_start = std.mem.indexOf(u8, line, "(") orelse return 0;
    const paren_end = std.mem.lastIndexOf(u8, line, ")") orelse return 0;
    if (paren_start >= paren_end) return 0;
    const params = line[paren_start + 1 .. paren_end];

    var count: usize = 0;
    var iter = std.mem.splitScalar(u8, params, ',');
    while (iter.next()) |param| {
        const trimmed = std.mem.trim(u8, param, " \t");
        const loc_prefix = "@location(";
        const li = std.mem.indexOf(u8, trimmed, loc_prefix) orelse continue;
        const l_start = li + loc_prefix.len;
        const l_end = std.mem.indexOfPos(u8, trimmed, l_start, ")") orelse continue;
        const location = std.fmt.parseInt(u32, trimmed[l_start..l_end], 10) catch continue;

        // Parse "name: type" after the annotation.
        const after = std.mem.trim(u8, trimmed[l_end + 1 ..], " \t");
        const name_end = std.mem.indexOfAny(u8, after, " :\t") orelse after.len;
        const name = after[0..name_end];
        if (name.len == 0) continue;

        // Find the type after ':'
        const colon = std.mem.indexOfPos(u8, after, name_end, ":") orelse continue;
        const type_str = std.mem.trim(u8, after[colon + 1 ..], " \t");
        const type_end = std.mem.indexOfAny(u8, type_str, " ,)\t") orelse type_str.len;

        if (count < out.len) {
            out[count] = .{
                .location = location,
                .name = name,
                .msl_type = wgslTypeToMsl(type_str[0..type_end]),
            };
            count += 1;
        }
    }
    return count;
}

const ReturnInfo = struct {
    has_position: bool,
    locations: [MAX_LOCATIONS]LocationParam,
    location_count: usize,
    ret_type: []const u8, // MSL type for single-value returns
};

/// Parse return type annotations from the fn signature.
/// Handles: -> @builtin(position) vec4f, -> @location(0) vec4f
fn parseReturnInfo(wgsl: []const u8) ReturnInfo {
    var info = ReturnInfo{
        .has_position = false,
        .locations = undefined,
        .location_count = 0,
        .ret_type = "float4",
    };

    // Find the fn line containing '->'.
    var lines = std.mem.splitScalar(u8, wgsl, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const arrow = std.mem.indexOf(u8, trimmed, "->") orelse continue;
        if (std.mem.indexOf(u8, trimmed, "fn ") == null) continue;

        const after_arrow = std.mem.trim(u8, trimmed[arrow + 2 ..], " \t");

        // Check for @builtin(position)
        if (std.mem.indexOf(u8, after_arrow, "@builtin(position)") != null) {
            info.has_position = true;
            // Find the type after the annotation.
            if (std.mem.indexOf(u8, after_arrow, ")")) |close| {
                const ret_type_str = std.mem.trim(u8, after_arrow[close + 1 ..], " \t{");
                if (ret_type_str.len > 0) {
                    info.ret_type = wgslTypeToMsl(ret_type_str);
                }
            }
        }

        // Check for @location(N) in return
        const loc_prefix = "@location(";
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, after_arrow, pos, loc_prefix)) |li| {
            const l_start = li + loc_prefix.len;
            const l_end = std.mem.indexOfPos(u8, after_arrow, l_start, ")") orelse break;
            const location = std.fmt.parseInt(u32, after_arrow[l_start..l_end], 10) catch break;
            // Type follows the annotation.
            const after_loc = std.mem.trim(u8, after_arrow[l_end + 1 ..], " \t");
            const type_end = std.mem.indexOfAny(u8, after_loc, " ,{\t") orelse after_loc.len;
            if (info.location_count < MAX_LOCATIONS) {
                info.locations[info.location_count] = .{
                    .location = location,
                    .name = "",
                    .msl_type = wgslTypeToMsl(after_loc[0..type_end]),
                };
                info.location_count += 1;
            }
            pos = l_end + 1;
        }

        break;
    }
    return info;
}

// ============================================================
// Body writing
// ============================================================

/// Write body with WGSL→MSL type constructor rewriting.
fn writeBodyRewritten(w: *Writer, body: []const u8) TranslateError!void {
    var body_lines = std.mem.splitScalar(u8, body, '\n');
    while (body_lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) {
            try w.write("\n");
            continue;
        }
        try rewriteLine(w, line);
        try w.write("\n");
    }
}

/// Rewrite a single line: replace WGSL vec constructors with MSL equivalents.
fn rewriteLine(w: *Writer, line: []const u8) TranslateError!void {
    var i: usize = 0;
    while (i < line.len) {
        var matched = false;
        for (VEC_REPLACEMENTS) |rep| {
            if (i + rep.wgsl.len <= line.len and std.mem.eql(u8, line[i..][0..rep.wgsl.len], rep.wgsl)) {
                try w.write(rep.msl);
                i += rep.wgsl.len;
                matched = true;
                break;
            }
        }
        if (!matched) {
            try w.write(line[i..][0..1]);
            i += 1;
        }
    }
}

// ============================================================
// Writer
// ============================================================

const Writer = struct {
    buf: []u8,
    pos: usize,

    fn write(self: *Writer, data: []const u8) TranslateError!void {
        if (self.pos + data.len > self.buf.len) return TranslateError.OutputTooLarge;
        @memcpy(self.buf[self.pos..][0..data.len], data);
        self.pos += data.len;
    }

    fn writeInt(self: *Writer, val: u32) TranslateError!void {
        var tmp: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{val}) catch return TranslateError.OutputTooLarge;
        try self.write(s);
    }
};
