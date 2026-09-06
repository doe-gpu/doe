const std = @import("std");
const analysis = @import("../../src/compiler/wgsl/pipeline/analysis.zig");
const translation = @import("../../src/compiler/wgsl/pipeline/translate_spirv.zig");
const fusion = @import("../../src/compiler/wgsl/ir/ir_transform_float_fusion.zig");
const ir = @import("../../src/compiler/wgsl/ir/ir.zig");
const validate = @import("../../src/compiler/wgsl/ir/ir_validate.zig").validate;
const spirv = @import("../../src/compiler/wgsl/emit/spirv/spirv_builder.zig");
const testing = std.testing;

const SOURCE =
    \\var<private> counter: u32;
    \\@group(0) @binding(0) var<storage, read_write> output: array<f32>;
    \\fn a() -> f32 { counter += 1u; return f32(counter); }
    \\fn b() -> f32 { counter += 2u; return f32(counter); }
    \\fn c() -> f32 { counter += 3u; return f32(counter); }
    \\fn d() -> f32 { counter += 4u; return f32(counter); }
    \\@compute @workgroup_size(1) fn main() {
    \\    output[0] = (a() + b() * c()) + d();
    \\}
;

fn exerciseFusion(allocator: std.mem.Allocator) !void {
    var module = try analysis.analyzeToIr(allocator, SOURCE);
    defer module.deinit();
    try testing.expectEqual(@as(usize, 1), try fusion.apply(&module));
    try validate(&module);
    try testing.expectEqual(@as(usize, 0), try fusion.apply(&module));
    try validate(&module);
}

test "float fusion preserves ownership under every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, exerciseFusion, .{});
}

fn exerciseNamedValues(allocator: std.mem.Allocator) !void {
    const source =
        \\alias Float = f32;
        \\struct Pair { a: Float, b: Float, }
        \\@group(0) @binding(0) var<storage, read_write> output: array<Pair>;
        \\fn identity(value: Float) -> Float { let copy = value; var result = copy; return result; }
        \\@compute @workgroup_size(1) fn main() {
        \\    output[0].a = identity(output[0].b);
        \\}
    ;
    var module = try analysis.analyzeToIr(allocator, source);
    defer module.deinit();
    try validate(&module);
}

test "float fusion allocation audit covers named declarations and member expressions" {
    try testing.checkAllAllocationFailures(testing.allocator, exerciseNamedValues, .{});
}

fn collectCalls(function: *const ir.Function, id: ir.ExprId, calls: *std.ArrayListUnmanaged([]const u8)) !void {
    switch (function.exprs.items[id].data) {
        .binary => |binary| {
            try collectCalls(function, binary.lhs, calls);
            try collectCalls(function, binary.rhs, calls);
        },
        .call => |call| {
            for (function.expr_args.items[call.args.start..][0..call.args.len]) |arg| try collectCalls(function, arg, calls);
            if (call.kind == .user) try calls.append(testing.allocator, call.name);
        },
        else => {},
    }
}

test "float fusion evaluates each side effect once in original operand order" {
    var module = try analysis.analyzeToIr(testing.allocator, SOURCE);
    defer module.deinit();
    const function = &module.functions.items[module.entry_points.items[0].function];
    var root: ?ir.ExprId = null;
    for (function.stmts.items) |stmt| if (stmt == .assign) {
        root = stmt.assign.rhs;
    };
    try testing.expect(root != null);
    var before: std.ArrayListUnmanaged([]const u8) = .{};
    defer before.deinit(testing.allocator);
    var after: std.ArrayListUnmanaged([]const u8) = .{};
    defer after.deinit(testing.allocator);
    try collectCalls(function, root.?, &before);
    try testing.expectEqual(@as(usize, 1), try fusion.apply(&module));
    try collectCalls(function, root.?, &after);
    try testing.expectEqual(@as(usize, 4), before.items.len);
    try testing.expectEqual(before.items.len, after.items.len);
    for (before.items, after.items, [_][]const u8{ "a", "b", "c", "d" }) |original, transformed, expected| {
        try testing.expectEqualStrings(expected, original);
        try testing.expectEqualStrings(original, transformed);
    }
    try validate(&module);
}

test "float fusion leaves integer overflow and vector arithmetic unchanged" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> u: array<u32>;
        \\@group(0) @binding(1) var<storage, read_write> v: array<vec2f>;
        \\@compute @workgroup_size(1) fn main() {
        \\    u[0] = (u[1] + u[2] * u[3]) + u[4];
        \\    v[0] = (v[1] + v[2] * v[3]) + v[4];
        \\}
    ;
    var module = try analysis.analyzeToIr(testing.allocator, source);
    defer module.deinit();
    try testing.expectEqual(@as(usize, 0), try fusion.apply(&module));
    try validate(&module);
}

test "float fusion SPIR-V policy retains graphics expression graphs" {
    const source =
        \\@fragment fn main(@location(0) v: vec4f) -> @location(0) f32 {
        \\    return (v.x + v.y * v.z) + v.w;
        \\}
    ;
    var module = try analysis.analyzeToIr(testing.allocator, source);
    defer module.deinit();
    const function = &module.functions.items[module.entry_points.items[0].function];
    const count = function.exprs.items.len;
    try translation.prepareComputeIr(&module);
    try testing.expectEqual(count, function.exprs.items.len);
    try validate(&module);
}

test "float fusion emits explicit SPIR-V Fma without duplicating user calls" {
    var output: [translation.MAX_OUTPUT]u8 = undefined;
    const len = try translation.translateToSpirv(testing.allocator, SOURCE, &output);
    const words = std.mem.bytesAsSlice(u32, output[0..len]);
    const glsl_fma_instruction = 50;
    var callees = [_]u32{0} ** 4;
    var index: usize = 5;
    var fma_count: usize = 0;
    var call_count: usize = 0;
    while (index < words.len) {
        const opcode: u16 = @truncate(words[index]);
        const count = words[index] >> 16;
        try testing.expect(count > 0 and index + count <= words.len);
        if (opcode == spirv.Opcode.Name and count == 3) {
            for ("abcd", 0..) |name, slot| if (words[index + 2] == name) {
                callees[slot] = words[index + 1];
            };
        }
        index += count;
    }
    for (callees) |callee| try testing.expect(callee != 0);
    index = 5;
    while (index < words.len) {
        const opcode: u16 = @truncate(words[index]);
        const count = words[index] >> 16;
        try testing.expect(count > 0 and index + count <= words.len);
        if (opcode == spirv.Opcode.ExtInst and count >= 5 and words[index + 4] == glsl_fma_instruction) fma_count += 1;
        if (opcode == spirv.Opcode.FunctionCall and std.mem.indexOfScalar(u32, &callees, words[index + 3]) != null) call_count += 1;
        index += count;
    }
    try testing.expectEqual(@as(usize, 1), fma_count);
    try testing.expectEqual(@as(usize, 4), call_count);
}
