// TSIR bootstrap oracle CLI.
//
// This is the narrow Step 8 subprocess bridge for the parity harness. It
// accepts the same bootstrap input JSON as `bench/tools/doe_parity.py`,
// constructs the Phase A semantic shape for fused_gemv / rms_norm / gather,
// and runs `tsir.reference.run` so the CLI's reference hash comes from Zig.

const std = @import("std");
const tsir = @import("doe").compiler.tsir();

const MAX_INPUT_MIB: usize = 16;
const BYTES_PER_MIB: usize = 1024 * 1024;
const MAX_INPUT_BYTES: usize = MAX_INPUT_MIB * BYTES_PER_MIB;
const DIGEST_BYTES: usize = 32;
const F32_BYTES: usize = 4;
const F16_BYTES: usize = 2;
const U32_BYTES: usize = 4;
const NIBBLE_BITS: u5 = 4;
const LOW_NIBBLE_MASK: u8 = 0x0f;
const BF16_SHIFT: u5 = 16;
const F32_EXP_SHIFT: u5 = 23;
const F32_EXP_MASK: u32 = 0xff;
const F32_MANTISSA_MASK: u32 = 0x7fffff;
const BF16_QUIET_NAN_MASK: u32 = 0x40;
const BF16_RNE_BIAS: u32 = 0x7fff;

const Usage =
    \\usage: doe-tsir-bootstrap-oracle --kernel <name> --inputs <path>
    \\       [--semantic-tsir <path>] [--realization-tsir <path>]
    \\
;

const Buffer = struct {
    name: []const u8,
    elem: tsir.ScalarKind,
    shape: []const u64,
    data: []const u8,
};

const InputDoc = struct {
    kernel: []const u8,
    buffers: []const Buffer,
};

const RawInputDoc = struct {
    kernel: []const u8,
    inputs: std.json.Value,
};

const Args = struct {
    kernel: []const u8,
    inputs_path: []const u8,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = parseArgs(allocator) catch |err| {
        try writeError(err, "invalid arguments");
        return err;
    };
    defer {
        allocator.free(args.kernel);
        allocator.free(args.inputs_path);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const result = run(arena_allocator, args) catch |err| switch (err) {
        error.NotImplemented => {
            try writeStatus("not_implemented", null, "bootstrap oracle cannot execute this input");
            return;
        },
        error.InvalidJson => {
            try writeStatus("not_implemented", null, "bootstrap oracle input JSON is unsupported or missing kernel/inputs");
            return;
        },
        else => return err,
    };
    try writeStatus("pass", &result.reference_hash, "zig bootstrap TSIR oracle executed");
}

fn parseArgs(allocator: std.mem.Allocator) !Args {
    var iter = try std.process.argsWithAllocator(allocator);
    defer iter.deinit();
    _ = iter.next();

    var kernel: ?[]u8 = null;
    var inputs_path: ?[]u8 = null;
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--kernel")) {
            const value = iter.next() orelse return error.InvalidArgument;
            kernel = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--inputs")) {
            const value = iter.next() orelse return error.InvalidArgument;
            inputs_path = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--semantic-tsir") or
            std.mem.eql(u8, arg, "--realization-tsir"))
        {
            _ = iter.next() orelse return error.InvalidArgument;
        } else {
            return error.InvalidArgument;
        }
    }

    return .{
        .kernel = kernel orelse return error.InvalidArgument,
        .inputs_path = inputs_path orelse return error.InvalidArgument,
    };
}

fn run(allocator: std.mem.Allocator, args: Args) !tsir.reference.Result {
    const input_bytes = try std.fs.cwd().readFileAlloc(
        allocator,
        args.inputs_path,
        MAX_INPUT_BYTES,
    );
    const doc = try parseInputDoc(allocator, input_bytes);
    const kernel = canonicalKernel(args.kernel);
    if (!std.mem.eql(u8, doc.kernel, kernel)) return error.NotImplemented;

    if (std.mem.eql(u8, kernel, "fused_gemv")) {
        return runFusedGemv(allocator, doc);
    }
    if (std.mem.eql(u8, kernel, "rms_norm")) {
        return runRmsNorm(allocator, doc);
    }
    if (std.mem.eql(u8, kernel, "gather")) {
        return runGather(allocator, doc);
    }
    return error.NotImplemented;
}

fn parseInputDoc(allocator: std.mem.Allocator, bytes: []const u8) !InputDoc {
    const parsed = std.json.parseFromSlice(RawInputDoc, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.InvalidJson;
    const value = parsed.value;
    const buffers = try parseBuffers(allocator, value.inputs);
    return .{
        .kernel = canonicalKernel(value.kernel),
        .buffers = buffers,
    };
}

fn parseBuffers(allocator: std.mem.Allocator, value: std.json.Value) ![]const Buffer {
    var out = std.ArrayList(Buffer){};
    switch (value) {
        .object => |object| {
            var iter = object.iterator();
            while (iter.next()) |entry| {
                try out.append(
                    allocator,
                    try parseBuffer(allocator, entry.key_ptr.*, entry.value_ptr.*),
                );
            }
        },
        .array => |array| {
            for (array.items) |item| {
                const object = try expectObject(item);
                const name = try expectString(object.get("name") orelse return error.InvalidJson);
                try out.append(allocator, try parseBuffer(allocator, name, item));
            }
        },
        else => return error.InvalidJson,
    }
    return out.toOwnedSlice(allocator);
}

fn parseBuffer(
    allocator: std.mem.Allocator,
    name: []const u8,
    value: std.json.Value,
) !Buffer {
    const object = try expectObject(value);
    const elem = try parseElem(try expectString(object.get("elem") orelse return error.InvalidJson));
    const shape = try parseShape(allocator, object.get("shape") orelse return error.InvalidJson);
    const byte_len = try expectedByteLen(shape, elem);
    const data = try allocator.alloc(u8, byte_len);

    if (object.get("bytesHex")) |bytes_hex_value| {
        const bytes_hex = try expectString(bytes_hex_value);
        if (bytes_hex.len != byte_len * 2) return error.InvalidJson;
        _ = try std.fmt.hexToBytes(data, bytes_hex);
    } else if (object.get("values")) |values_value| {
        const values = try expectArray(values_value);
        if (values.items.len != elemCount(shape)) return error.InvalidJson;
        for (values.items, 0..) |item, index| {
            try writeValue(data, elem, index, item);
        }
    } else {
        return error.InvalidJson;
    }

    return .{ .name = name, .elem = elem, .shape = shape, .data = data };
}

fn runFusedGemv(allocator: std.mem.Allocator, doc: InputDoc) !tsir.reference.Result {
    const matrix = findBuffer(doc, "W") orelse return error.NotImplemented;
    const vector = findBuffer(doc, "x") orelse return error.NotImplemented;
    if (matrix.shape.len != 2 or vector.shape.len != 1) return error.NotImplemented;
    if (matrix.shape[1] != vector.shape[0]) return error.NotImplemented;

    const output_shape = try allocator.alloc(u64, 1);
    output_shape[0] = matrix.shape[0];
    const bindings = try allocator.alloc(tsir.schema.BufferBinding, 3);
    bindings[0] = .{ .name = "W", .group = 0, .binding = 0, .logical_shape = matrix.shape, .elem = matrix.elem, .read_write = false };
    bindings[1] = .{ .name = "x", .group = 0, .binding = 1, .logical_shape = vector.shape, .elem = vector.elem, .read_write = false };
    bindings[2] = .{ .name = "y", .group = 0, .binding = 2, .logical_shape = output_shape, .elem = matrix.elem, .read_write = true };

    const axes = try allocator.alloc(tsir.schema.IterationAxis, 2);
    axes[0] = .{ .name = "i", .lower_bound = "0", .upper_bound = "M", .step = "1" };
    axes[1] = .{ .name = "k", .lower_bound = "0", .upper_bound = "K", .step = "1" };
    const body_bindings = try allocator.alloc(tsir.schema.SemanticBodyBinding, 3);
    body_bindings[0] = .{ .binding_index = 0, .role = .matrix };
    body_bindings[1] = .{ .binding_index = 1, .role = .vector };
    body_bindings[2] = .{ .binding_index = 2, .role = .output };
    const body_axes = try allocator.alloc(tsir.schema.SemanticBodyAxis, 2);
    body_axes[0] = .{ .axis_index = 0, .role = .output };
    body_axes[1] = .{ .axis_index = 1, .role = .reduction };
    const reductions = try allocator.alloc(tsir.schema.ReductionRegion, 1);
    reductions[0] = .{
        .axis = 1,
        .op = .sum,
        .contract = .{ .accumulation = .f32, .associativity = .strict_ordered, .nan_inf = .propagate },
        .target_binding = 2,
    };

    const semantic = try oneFunctionSemantic(allocator, .fused_gemv, axes, bindings, reductions, .{
        .op = .fused_gemv,
        .binding_roles = body_bindings,
        .axis_roles = body_axes,
    });
    return tsir.reference.run(allocator, semantic, emptyRealization(), &[_][]const u8{
        matrix.data,
        vector.data,
    });
}

fn runRmsNorm(allocator: std.mem.Allocator, doc: InputDoc) !tsir.reference.Result {
    const input = findBuffer(doc, "input") orelse return error.NotImplemented;
    const weight = findBuffer(doc, "weight") orelse return error.NotImplemented;
    const uniform = findBuffer(doc, "u") orelse return error.NotImplemented;
    if (input.shape.len != 1 or weight.shape.len != 1) return error.NotImplemented;
    if (input.shape[0] != weight.shape[0]) return error.NotImplemented;

    const bindings = try allocator.alloc(tsir.schema.BufferBinding, 4);
    bindings[0] = .{ .name = "input", .group = 0, .binding = 0, .logical_shape = input.shape, .elem = input.elem, .read_write = false };
    bindings[1] = .{ .name = "weight", .group = 0, .binding = 1, .logical_shape = weight.shape, .elem = weight.elem, .read_write = false };
    bindings[2] = .{ .name = "output", .group = 0, .binding = 2, .logical_shape = input.shape, .elem = input.elem, .read_write = true };
    bindings[3] = .{ .name = "u", .group = 0, .binding = 3, .logical_shape = uniform.shape, .elem = uniform.elem, .read_write = false };

    const axes = try allocator.alloc(tsir.schema.IterationAxis, 2);
    axes[0] = .{ .name = "d", .lower_bound = "0", .upper_bound = "hidden_size", .step = "1" };
    axes[1] = .{ .name = "i", .lower_bound = "0", .upper_bound = "hidden_size", .step = "1" };
    const body_bindings = try allocator.alloc(tsir.schema.SemanticBodyBinding, 3);
    body_bindings[0] = .{ .binding_index = 0, .role = .input };
    body_bindings[1] = .{ .binding_index = 1, .role = .scale };
    body_bindings[2] = .{ .binding_index = 2, .role = .output };
    const body_axes = try allocator.alloc(tsir.schema.SemanticBodyAxis, 2);
    body_axes[0] = .{ .axis_index = 0, .role = .hidden };
    body_axes[1] = .{ .axis_index = 1, .role = .reduction };
    const reductions = try allocator.alloc(tsir.schema.ReductionRegion, 1);
    reductions[0] = .{
        .axis = 1,
        .op = .sum,
        .contract = .{ .accumulation = .f32, .associativity = .strict_ordered, .nan_inf = .propagate },
        .target_binding = 2,
    };

    const semantic = try oneFunctionSemantic(allocator, .rms_norm, axes, bindings, reductions, .{
        .op = .rms_norm,
        .binding_roles = body_bindings,
        .axis_roles = body_axes,
        .rms_norm = .{
            .formula = .sum_squares_mean_epsilon_rsqrt_scale,
            .epsilon = .{
                .source = .uniform_field,
                .path = "uniform:u.eps",
                .binding_index = 3,
                .byte_offset = 4,
            },
            .hidden_extent_axis = 0,
            .reduction_target = .intermediate_scalar,
        },
    });
    return tsir.reference.run(allocator, semantic, emptyRealization(), &[_][]const u8{
        input.data,
        weight.data,
        uniform.data,
    });
}

fn runGather(allocator: std.mem.Allocator, doc: InputDoc) !tsir.reference.Result {
    const indices = findBuffer(doc, "indices") orelse return error.NotImplemented;
    const table = findBuffer(doc, "table") orelse return error.NotImplemented;
    if (indices.shape.len != 1 or table.shape.len != 2) return error.NotImplemented;

    const output_shape = try allocator.alloc(u64, 2);
    output_shape[0] = indices.shape[0];
    output_shape[1] = table.shape[1];
    const bindings = try allocator.alloc(tsir.schema.BufferBinding, 3);
    bindings[0] = .{ .name = "indices", .group = 0, .binding = 0, .logical_shape = indices.shape, .elem = indices.elem, .read_write = false };
    bindings[1] = .{ .name = "table", .group = 0, .binding = 1, .logical_shape = table.shape, .elem = table.elem, .read_write = false };
    bindings[2] = .{ .name = "output", .group = 0, .binding = 2, .logical_shape = output_shape, .elem = table.elem, .read_write = true };

    const axes = try allocator.alloc(tsir.schema.IterationAxis, 2);
    axes[0] = .{ .name = "t", .lower_bound = "0", .upper_bound = "num_tokens", .step = "1" };
    axes[1] = .{ .name = "h", .lower_bound = "0", .upper_bound = "hidden", .step = "1" };
    const body_bindings = try allocator.alloc(tsir.schema.SemanticBodyBinding, 3);
    body_bindings[0] = .{ .binding_index = 0, .role = .indices };
    body_bindings[1] = .{ .binding_index = 1, .role = .table };
    body_bindings[2] = .{ .binding_index = 2, .role = .output };
    const body_axes = try allocator.alloc(tsir.schema.SemanticBodyAxis, 2);
    body_axes[0] = .{ .axis_index = 0, .role = .token };
    body_axes[1] = .{ .axis_index = 1, .role = .hidden };

    const semantic = try oneFunctionSemantic(allocator, .gather, axes, bindings, &.{}, .{
        .op = .gather,
        .binding_roles = body_bindings,
        .axis_roles = body_axes,
    });
    return tsir.reference.run(allocator, semantic, emptyRealization(), &[_][]const u8{
        indices.data,
        table.data,
    });
}

fn oneFunctionSemantic(
    allocator: std.mem.Allocator,
    family: tsir.KernelFamilyHint,
    axes: []const tsir.schema.IterationAxis,
    bindings: []const tsir.schema.BufferBinding,
    reductions: []const tsir.schema.ReductionRegion,
    body: tsir.schema.SemanticBody,
) !tsir.Semantic {
    const functions = try allocator.alloc(tsir.schema.SemanticFunction, 1);
    functions[0] = .{
        .name = "main",
        .family_hint = family,
        .axes = axes,
        .bindings = bindings,
        .reductions = reductions,
        .collectives = &.{},
        .body = body,
        .source_digest = [_]u8{0} ** DIGEST_BYTES,
    };
    return .{ .functions = functions, .rejections = &.{} };
}

fn emptyRealization() tsir.Realization {
    return .{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** DIGEST_BYTES,
        .rejections = &.{},
    };
}

fn findBuffer(doc: InputDoc, name: []const u8) ?Buffer {
    for (doc.buffers) |buffer| {
        if (std.mem.eql(u8, buffer.name, name)) return buffer;
    }
    return null;
}

fn canonicalKernel(kernel: []const u8) []const u8 {
    const prefix = "doe.tsir.bootstrap.";
    var text = kernel;
    if (std.mem.startsWith(u8, text, prefix)) text = text[prefix.len..];
    if (std.mem.eql(u8, text, "rmsnorm") or std.mem.eql(u8, text, "rms-norm")) {
        return "rms_norm";
    }
    if (std.mem.eql(u8, text, "fused-gemv")) return "fused_gemv";
    return text;
}

fn parseElem(text: []const u8) !tsir.ScalarKind {
    if (std.mem.eql(u8, text, "f32")) return .f32;
    if (std.mem.eql(u8, text, "f16")) return .f16;
    if (std.mem.eql(u8, text, "bf16")) return .bf16;
    if (std.mem.eql(u8, text, "u32")) return .u32;
    return error.NotImplemented;
}

fn parseShape(allocator: std.mem.Allocator, value: std.json.Value) ![]const u64 {
    const array = try expectArray(value);
    const out = try allocator.alloc(u64, array.items.len);
    for (array.items, 0..) |item, index| {
        out[index] = try expectU64(item);
    }
    return out;
}

fn expectedByteLen(shape: []const u64, elem: tsir.ScalarKind) !usize {
    const elems = elemCount(shape);
    return std.math.mul(usize, elems, elem.byteSize()) catch error.NotImplemented;
}

fn elemCount(shape: []const u64) usize {
    var count: usize = 1;
    for (shape) |dim| {
        count = std.math.mul(usize, count, std.math.cast(usize, dim) orelse 0) catch 0;
    }
    return count;
}

fn writeValue(data: []u8, elem: tsir.ScalarKind, index: usize, value: std.json.Value) !void {
    switch (elem) {
        .f32 => {
            const v: f32 = @floatCast(try expectF64(value));
            std.mem.writeInt(u32, data[index * F32_BYTES ..][0..F32_BYTES], @bitCast(v), .little);
        },
        .f16 => {
            const v: f16 = @floatCast(try expectF64(value));
            std.mem.writeInt(u16, data[index * F16_BYTES ..][0..F16_BYTES], @bitCast(v), .little);
        },
        .bf16 => {
            const v: f32 = @floatCast(try expectF64(value));
            std.mem.writeInt(u16, data[index * F16_BYTES ..][0..F16_BYTES], f32ToBf16Rne(v), .little);
        },
        .u32 => {
            std.mem.writeInt(u32, data[index * U32_BYTES ..][0..U32_BYTES], try expectU32(value), .little);
        },
        else => return error.NotImplemented,
    }
}

fn f32ToBf16Rne(val: f32) u16 {
    const bits: u32 = @bitCast(val);
    const exp: u32 = (bits >> F32_EXP_SHIFT) & F32_EXP_MASK;
    const mantissa: u32 = bits & F32_MANTISSA_MASK;
    if (exp == F32_EXP_MASK and mantissa != 0) {
        return @intCast((bits >> BF16_SHIFT) | BF16_QUIET_NAN_MASK);
    }
    const lsb: u32 = (bits >> BF16_SHIFT) & 1;
    return @intCast((bits +% (BF16_RNE_BIAS + lsb)) >> BF16_SHIFT);
}

fn expectObject(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.InvalidJson,
    };
}

fn expectArray(value: std.json.Value) !std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => error.InvalidJson,
    };
}

fn expectString(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |string| string,
        else => error.InvalidJson,
    };
}

fn expectU64(value: std.json.Value) !u64 {
    return switch (value) {
        .integer => |integer| std.math.cast(u64, integer) orelse error.InvalidJson,
        else => error.InvalidJson,
    };
}

fn expectU32(value: std.json.Value) !u32 {
    return switch (value) {
        .integer => |integer| std.math.cast(u32, integer) orelse error.InvalidJson,
        else => error.InvalidJson,
    };
}

fn expectF64(value: std.json.Value) !f64 {
    return switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        else => error.InvalidJson,
    };
}

fn writeStatus(status: []const u8, hash: ?*const [DIGEST_BYTES]u8, detail: []const u8) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.writeAll("{\"detail\":\"");
    try writeJsonStringContents(stdout, detail);
    try stdout.writeAll("\",\"referenceHash\":");
    if (hash) |h| {
        try stdout.writeAll("\"");
        try writeHex(stdout, h.*);
        try stdout.writeAll("\"");
    } else {
        try stdout.writeAll("null");
    }
    try stdout.writeAll(",\"status\":\"");
    try writeJsonStringContents(stdout, status);
    try stdout.writeAll("\"}\n");
}

fn writeError(_: anyerror, detail: []const u8) !void {
    try writeStatus("not_implemented", null, detail);
    const stderr = std.fs.File.stderr().deprecatedWriter();
    try stderr.writeAll(Usage);
}

fn writeHex(writer: anytype, bytes: [DIGEST_BYTES]u8) !void {
    const digits = "0123456789abcdef";
    for (bytes) |byte| {
        const high: usize = @intCast(byte >> NIBBLE_BITS);
        const low: usize = @intCast(byte & LOW_NIBBLE_MASK);
        const pair = [_]u8{ digits[high], digits[low] };
        try writer.writeAll(&pair);
    }
}

fn writeJsonStringContents(writer: anytype, text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(byte),
        }
    }
}
