// mod_override_test.zig — Override parsing and substitution tests for the public WGSL API.

const std = @import("std");
const mod = @import("../../src/compiler/wgsl/mod.zig");
const translateToHlsl = mod.translateToHlsl;
const translateToHlslWithOverrides = mod.translateToHlslWithOverrides;
const translateToMsl = mod.translateToMsl;
const translateToMslWithOverrides = mod.translateToMslWithOverrides;
const analyzeToIr = mod.analyzeToIr;
const MAX_HLSL_OUTPUT = mod.MAX_HLSL_OUTPUT;
const MAX_OUTPUT = mod.MAX_OUTPUT;
const ir = mod.ir;
const applyOverrides = mod.applyOverrides;
const runtime_compile = @import("../../src/compiler/wgsl/runtime/runtime_compute_translation.zig");

test "override with @id attribute is parsed and stored in IR" {
    const source =
        \\@id(0) override workgroup_size: u32 = 64;
        \\@id(1) override iterations: u32 = 1;
        \\override untagged: f32 = 1.0;
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = f32(workgroup_size) + f32(iterations) + untagged;
        \\}
    ;
    var module_ir = try analyzeToIr(std.testing.allocator, source);
    defer module_ir.deinit();

    const g0 = module_ir.globals.items[0];
    try std.testing.expectEqualStrings("workgroup_size", g0.name);
    try std.testing.expectEqual(@as(?u32, 0), g0.override_id);
    try std.testing.expectEqual(ir.GlobalClass.override_, g0.class);
    try std.testing.expectEqual(@as(u64, 64), g0.initializer.?.int);

    const g1 = module_ir.globals.items[1];
    try std.testing.expectEqualStrings("iterations", g1.name);
    try std.testing.expectEqual(@as(?u32, 1), g1.override_id);

    const g2 = module_ir.globals.items[2];
    try std.testing.expectEqualStrings("untagged", g2.name);
    try std.testing.expectEqual(@as(?u32, null), g2.override_id);
}

test "applyOverrides substitutes values by numeric id" {
    const source =
        \\@id(0) override workgroup_size: u32 = 64;
        \\@id(1) override scale: f32 = 1.0;
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = f32(workgroup_size) * scale;
        \\}
    ;
    var module_ir = try analyzeToIr(std.testing.allocator, source);
    defer module_ir.deinit();

    const overrides = [_]ir.OverrideEntry{
        .{ .key = "0", .value = 256.0 },
        .{ .key = "1", .value = 4.0 },
    };
    applyOverrides(&module_ir, &overrides);

    // After override, values are substituted and class demoted to const_.
    try std.testing.expectEqual(@as(u64, 256), module_ir.globals.items[0].initializer.?.int);
    try std.testing.expectEqual(ir.GlobalClass.const_, module_ir.globals.items[0].class);
    try std.testing.expectEqual(@as(f64, 4.0), module_ir.globals.items[1].initializer.?.float);
    try std.testing.expectEqual(ir.GlobalClass.const_, module_ir.globals.items[1].class);
}

test "applyOverrides substitutes values by name" {
    const source =
        \\override scale: f32 = 1.0;
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = scale;
        \\}
    ;
    var module_ir = try analyzeToIr(std.testing.allocator, source);
    defer module_ir.deinit();

    const overrides = [_]ir.OverrideEntry{
        .{ .key = "scale", .value = 42.0 },
    };
    applyOverrides(&module_ir, &overrides);

    try std.testing.expectEqual(@as(f64, 42.0), module_ir.globals.items[0].initializer.?.float);
    try std.testing.expectEqual(ir.GlobalClass.const_, module_ir.globals.items[0].class);
}

test "translateToMslWithOverrides emits overridden constant values" {
    const source =
        \\@id(0) override BLOCK_SIZE: u32 = 64;
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = f32(BLOCK_SIZE);
        \\}
    ;
    var out: [MAX_OUTPUT]u8 = undefined;

    // Without overrides: default value 64.
    const len_default = try translateToMsl(std.testing.allocator, source, &out);
    const msl_default = out[0..len_default];
    try std.testing.expect(std.mem.indexOf(u8, msl_default, "constant uint BLOCK_SIZE = 64") != null);

    // With override: value changed to 256.
    const overrides = [_]ir.OverrideEntry{
        .{ .key = "0", .value = 256.0 },
    };
    const len_overridden = try translateToMslWithOverrides(
        std.testing.allocator,
        source,
        &out,
        &overrides,
        overrides.len,
    );
    const msl_overridden = out[0..len_overridden];
    // Overridden: should emit 256, not 64.
    try std.testing.expect(std.mem.indexOf(u8, msl_overridden, "256") != null);
    // Should not contain the old default.
    try std.testing.expect(std.mem.indexOf(u8, msl_overridden, "constant uint BLOCK_SIZE = 64") == null);
}

test "translateToSpirv accepts override-backed workgroup size defaults" {
    const source =
        \\override WORKGROUP_SIZE: u32 = 256u;
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(WORKGROUP_SIZE, 1, 1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = 1.0;
        \\}
    ;

    var out: [mod.MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try mod.translateToSpirv(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
}

test "override-backed workgroup array uses default and pipeline-specialized sizes" {
    const source =
        \\override SHARED_INPUT_SIZE: u32 = 256u;
        \\var<workgroup> shared_input: array<f32, SHARED_INPUT_SIZE>;
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\@compute @workgroup_size(SHARED_INPUT_SIZE, 1, 1)
        \\fn main(@builtin(local_invocation_id) lid: vec3u) {
        \\    shared_input[lid.x] = f32(lid.x);
        \\    workgroupBarrier();
        \\    data[lid.x] = shared_input[lid.x];
        \\}
    ;
    var out: [MAX_OUTPUT]u8 = undefined;

    var default_translation = try runtime_compile.translateToMslForComputeRuntime(
        std.testing.allocator,
        source,
        &out,
        null,
        0,
    );
    defer default_translation.info.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 256), default_translation.info.workgroup_size[0]);
    try std.testing.expect(std.mem.indexOf(u8, out[0..default_translation.len], "shared_input[256]") != null);

    const overrides = [_]ir.OverrideEntry{.{ .key = "SHARED_INPUT_SIZE", .value = 128.0 }};
    var specialized_translation = try runtime_compile.translateToMslForComputeRuntime(
        std.testing.allocator,
        source,
        &out,
        &overrides,
        overrides.len,
    );
    defer specialized_translation.info.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 128), specialized_translation.info.workgroup_size[0]);
    const specialized_msl = out[0..specialized_translation.len];
    try std.testing.expect(std.mem.indexOf(u8, specialized_msl, "shared_input[128]") != null);
    try std.testing.expect(std.mem.indexOf(u8, specialized_msl, "shared_input[256]") == null);

    var spirv_out: [mod.MAX_SPIRV_OUTPUT]u8 = undefined;
    var specialized_spirv = try runtime_compile.translateToSpirvForVulkanComputeRuntimeWithOverrides(
        std.testing.allocator,
        source,
        &spirv_out,
        &overrides,
        overrides.len,
    );
    defer specialized_spirv.info.deinit(std.testing.allocator);
    try std.testing.expect(specialized_spirv.len > 0);
    try std.testing.expectEqual(@as(u32, 128), specialized_spirv.info.workgroup_size[0]);
}

test "translateToHlslWithOverrides emits overridden render-stage constant values" {
    const source =
        \\@id(0) override SCALE: f32 = 1.0;
        \\@vertex
        \\fn vs_main(@builtin(vertex_index) index: u32) -> @builtin(position) vec4f {
        \\    let x = f32(index) * SCALE;
        \\    return vec4f(x, 0.0, 0.0, 1.0);
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;

    const len_default = try translateToHlsl(std.testing.allocator, source, &out);
    const hlsl_default = out[0..len_default];
    try std.testing.expect(std.mem.indexOf(u8, hlsl_default, "SCALE = 1") != null);

    const overrides = [_]ir.OverrideEntry{
        .{ .key = "0", .value = 4.0 },
    };
    const len_overridden = try translateToHlslWithOverrides(
        std.testing.allocator,
        source,
        &out,
        &overrides,
        overrides.len,
    );
    const hlsl_overridden = out[0..len_overridden];
    try std.testing.expect(std.mem.indexOf(u8, hlsl_overridden, "SCALE = 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl_overridden, "SCALE = 1") == null);
}
