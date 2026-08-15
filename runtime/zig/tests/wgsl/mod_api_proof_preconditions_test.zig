// mod_api_proof_preconditions_test.zig - Shard of mod_api_test.zig covering proof-guided dispatch-precondition coverage.

const support = @import("mod_api_test_support.zig");
const std = support.std;
const lean_proof = support.lean_proof;
const runtime_compile = support.runtime_compile;
const translateToMsl = support.translateToMsl;
const translateToHlsl = support.translateToHlsl;
const translateToSpirv = support.translateToSpirv;
const analyzeToIr = support.analyzeToIr;
const analyzeToIrWithConfig = support.analyzeToIrWithConfig;
const ir = support.ir;
const MAX_OUTPUT = support.MAX_OUTPUT;
const MAX_HLSL_OUTPUT = support.MAX_HLSL_OUTPUT;
const MAX_SPIRV_OUTPUT = support.MAX_SPIRV_OUTPUT;

test "analyze WGSL folds scalar const binary expressions" {
    const source =
        \\const MASK: u32 = 0xFFu & 0x0Fu;
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = MASK;
        \\}
    ;

    var module_ir = try analyzeToIr(std.testing.allocator, source);
    defer module_ir.deinit();

    try std.testing.expectEqual(@as(usize, 2), module_ir.globals.items.len);
    try std.testing.expect(module_ir.globals.items[0].initializer != null);
    try std.testing.expectEqual(ir.ConstantValue{ .int = 0x0F }, module_ir.globals.items[0].initializer.?);
}

test "analyzeToIrWithConfig records byte-aware gid dispatch preconditions" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\@compute @workgroup_size(4)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    data[gid.x] = 1.0;
        \\}
    ;

    var module_ir = try analyzeToIrWithConfig(std.testing.allocator, source, .{
        .elide_proven_bounds = true,
    });
    defer module_ir.deinit();

    if (!lean_proof.boundsProven(.gid_1d_storage_buffer)) {
        try std.testing.expectEqual(@as(usize, 0), module_ir.dispatch_preconditions.items.len);
        return;
    }

    try std.testing.expectEqual(@as(usize, 1), module_ir.dispatch_preconditions.items.len);
    const precondition = module_ir.dispatch_preconditions.items[0];
    try std.testing.expectEqual(ir.DispatchPreconditionKind.gid_component, precondition.kind);
    try std.testing.expectEqual(@as(u8, 0), precondition.gid_axis);
    try std.testing.expectEqual(@as(u64, 4), precondition.element_stride_bytes);
}

test "analyzeToIrWithConfig elides flat 2d dispatch-x indexing" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\@compute @workgroup_size(8, 2, 1)
        \\fn main(
        \\    @builtin(global_invocation_id) gid: vec3u,
        \\    @builtin(num_workgroups) num_wg: vec3u,
        \\) {
        \\    let width = num_wg.x * 8u;
        \\    let idx = gid.y * width + gid.x;
        \\    data[idx] = 1u;
        \\}
    ;

    var baseline_ir = try analyzeToIrWithConfig(std.testing.allocator, source, .{});
    defer baseline_ir.deinit();
    var baseline_has_min = false;
    for (baseline_ir.functions.items[0].exprs.items) |expr| {
        if (expr.data == .call and std.mem.eql(u8, expr.data.call.name, "min")) {
            baseline_has_min = true;
            break;
        }
    }
    try std.testing.expect(baseline_has_min);

    var elided_ir = try analyzeToIrWithConfig(std.testing.allocator, source, .{
        .elide_proven_bounds = true,
    });
    defer elided_ir.deinit();

    if (!lean_proof.boundsProven(.gid_2d_flat_storage_buffer)) {
        try std.testing.expectEqual(@as(usize, 0), elided_ir.dispatch_preconditions.items.len);
        return;
    }

    try std.testing.expectEqual(@as(usize, 1), elided_ir.dispatch_preconditions.items.len);
    const precondition = elided_ir.dispatch_preconditions.items[0];
    try std.testing.expectEqual(ir.DispatchPreconditionKind.flat_index_2d_dispatch_x, precondition.kind);
    try std.testing.expectEqual(@as(u64, 4), precondition.element_stride_bytes);

    var elided_has_min = false;
    for (elided_ir.functions.items[0].exprs.items) |expr| {
        if (expr.data == .call and std.mem.eql(u8, expr.data.call.name, "min")) {
            elided_has_min = true;
            break;
        }
    }
    try std.testing.expect(!elided_has_min);
}

test "analyzeToIrWithConfig records affine gid offset preconditions" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\@compute @workgroup_size(8)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    data[gid.x + 4u] = 1u;
        \\}
    ;

    var baseline_ir = try analyzeToIrWithConfig(std.testing.allocator, source, .{});
    defer baseline_ir.deinit();
    var baseline_has_min = false;
    for (baseline_ir.functions.items[0].exprs.items) |expr| {
        if (expr.data == .call and std.mem.eql(u8, expr.data.call.name, "min")) {
            baseline_has_min = true;
            break;
        }
    }
    try std.testing.expect(baseline_has_min);

    var elided_ir = try analyzeToIrWithConfig(std.testing.allocator, source, .{
        .elide_proven_bounds = true,
    });
    defer elided_ir.deinit();

    if (!lean_proof.boundsProven(.gid_1d_storage_buffer_offset)) {
        try std.testing.expectEqual(@as(usize, 0), elided_ir.dispatch_preconditions.items.len);
        return;
    }

    try std.testing.expectEqual(@as(usize, 1), elided_ir.dispatch_preconditions.items.len);
    const precondition = elided_ir.dispatch_preconditions.items[0];
    try std.testing.expectEqual(ir.DispatchPreconditionKind.gid_component, precondition.kind);
    try std.testing.expectEqual(@as(u8, 0), precondition.gid_axis);
    try std.testing.expectEqual(@as(u64, 4), precondition.element_stride_bytes);
    try std.testing.expectEqual(@as(u64, 4), precondition.element_offset);

    var elided_has_min = false;
    for (elided_ir.functions.items[0].exprs.items) |expr| {
        if (expr.data == .call and std.mem.eql(u8, expr.data.call.name, "min")) {
            elided_has_min = true;
            break;
        }
    }
    try std.testing.expect(!elided_has_min);
}

test "analyzeToIrWithConfig records affine gid stride preconditions" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\@compute @workgroup_size(8)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    data[gid.x * 4u + 2u] = 1u;
        \\}
    ;

    var baseline_ir = try analyzeToIrWithConfig(std.testing.allocator, source, .{});
    defer baseline_ir.deinit();
    var baseline_has_min = false;
    for (baseline_ir.functions.items[0].exprs.items) |expr| {
        if (expr.data == .call and std.mem.eql(u8, expr.data.call.name, "min")) {
            baseline_has_min = true;
            break;
        }
    }
    try std.testing.expect(baseline_has_min);

    var elided_ir = try analyzeToIrWithConfig(std.testing.allocator, source, .{
        .elide_proven_bounds = true,
    });
    defer elided_ir.deinit();

    if (!lean_proof.boundsProven(.gid_1d_storage_buffer_stride)) {
        try std.testing.expectEqual(@as(usize, 0), elided_ir.dispatch_preconditions.items.len);
        return;
    }

    try std.testing.expectEqual(@as(usize, 1), elided_ir.dispatch_preconditions.items.len);
    const precondition = elided_ir.dispatch_preconditions.items[0];
    try std.testing.expectEqual(ir.DispatchPreconditionKind.gid_component, precondition.kind);
    try std.testing.expectEqual(@as(u8, 0), precondition.gid_axis);
    try std.testing.expectEqual(@as(u64, 4), precondition.element_multiplier);
    try std.testing.expectEqual(@as(u64, 4), precondition.element_stride_bytes);
    try std.testing.expectEqual(@as(u64, 2), precondition.element_offset);

    var elided_has_min = false;
    for (elided_ir.functions.items[0].exprs.items) |expr| {
        if (expr.data == .call and std.mem.eql(u8, expr.data.call.name, "min")) {
            elided_has_min = true;
            break;
        }
    }
    try std.testing.expect(!elided_has_min);
}

test "compute runtime translation drops _doe_sizes for proof-covered affine bounds only" {
    const affine_source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\@compute @workgroup_size(8)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    data[gid.x + 4u] = 1u;
        \\}
    ;
    const direct_array_length_source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\@compute @workgroup_size(8)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    if (gid.x < arrayLength(&data)) {
        \\        data[gid.x] = 1u;
        \\    }
        \\}
    ;

    var affine_out: [MAX_OUTPUT]u8 = undefined;
    var affine_translation = try runtime_compile.translateToMslForComputeRuntime(
        std.testing.allocator,
        affine_source,
        &affine_out,
        null,
        0,
    );
    defer affine_translation.info.deinit(std.testing.allocator);

    if (lean_proof.boundsProven(.gid_1d_storage_buffer_offset)) {
        try std.testing.expect(!affine_translation.info.needs_sizes_buf);
    } else {
        try std.testing.expect(affine_translation.info.needs_sizes_buf);
    }

    var direct_out: [MAX_OUTPUT]u8 = undefined;
    var direct_translation = try runtime_compile.translateToMslForComputeRuntime(
        std.testing.allocator,
        direct_array_length_source,
        &direct_out,
        null,
        0,
    );
    defer direct_translation.info.deinit(std.testing.allocator);
    try std.testing.expect(direct_translation.info.needs_sizes_buf);
}

test "compute runtime translation retains clamps for strided affine bounds" {
    const affine_source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\@compute @workgroup_size(8)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    data[gid.x * 4u + 2u] = 1u;
        \\}
    ;

    var affine_out: [MAX_OUTPUT]u8 = undefined;
    var affine_translation = try runtime_compile.translateToMslForComputeRuntime(
        std.testing.allocator,
        affine_source,
        &affine_out,
        null,
        0,
    );
    defer affine_translation.info.deinit(std.testing.allocator);

    try std.testing.expect(affine_translation.info.needs_sizes_buf);
    try std.testing.expectEqual(@as(usize, 0), affine_translation.info.dispatch_preconditions.len);
}

test "analyzeToIrWithConfig records flat 2d offset preconditions" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\@compute @workgroup_size(8, 2, 1)
        \\fn main(
        \\    @builtin(global_invocation_id) gid: vec3u,
        \\    @builtin(num_workgroups) num_wg: vec3u,
        \\) {
        \\    let width = num_wg.x * 8u;
        \\    let idx = gid.y * width + gid.x + 16u;
        \\    data[idx] = 1u;
        \\}
    ;

    var baseline_ir = try analyzeToIrWithConfig(std.testing.allocator, source, .{});
    defer baseline_ir.deinit();
    var baseline_has_min = false;
    for (baseline_ir.functions.items[0].exprs.items) |expr| {
        if (expr.data == .call and std.mem.eql(u8, expr.data.call.name, "min")) {
            baseline_has_min = true;
            break;
        }
    }
    try std.testing.expect(baseline_has_min);

    var elided_ir = try analyzeToIrWithConfig(std.testing.allocator, source, .{
        .elide_proven_bounds = true,
    });
    defer elided_ir.deinit();

    if (!lean_proof.boundsProven(.gid_2d_flat_storage_buffer_offset)) {
        try std.testing.expectEqual(@as(usize, 0), elided_ir.dispatch_preconditions.items.len);
        return;
    }

    try std.testing.expectEqual(@as(usize, 1), elided_ir.dispatch_preconditions.items.len);
    const precondition = elided_ir.dispatch_preconditions.items[0];
    try std.testing.expectEqual(ir.DispatchPreconditionKind.flat_index_2d_dispatch_x, precondition.kind);
    try std.testing.expectEqual(@as(u64, 1), precondition.element_multiplier);
    try std.testing.expectEqual(@as(u64, 4), precondition.element_stride_bytes);
    try std.testing.expectEqual(@as(u64, 16), precondition.element_offset);

    var elided_has_min = false;
    for (elided_ir.functions.items[0].exprs.items) |expr| {
        if (expr.data == .call and std.mem.eql(u8, expr.data.call.name, "min")) {
            elided_has_min = true;
            break;
        }
    }
    try std.testing.expect(!elided_has_min);
}

test "analyzeToIrWithConfig records flat 3d offset preconditions" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\@compute @workgroup_size(4, 2, 3)
        \\fn main(
        \\    @builtin(global_invocation_id) gid: vec3u,
        \\    @builtin(num_workgroups) num_wg: vec3u,
        \\) {
        \\    let width = num_wg.x * 4u;
        \\    let height = num_wg.y * 2u;
        \\    let idx = gid.z * (height * width) + gid.y * width + gid.x + 7u;
        \\    data[idx] = 1u;
        \\}
    ;

    var baseline_ir = try analyzeToIrWithConfig(std.testing.allocator, source, .{});
    defer baseline_ir.deinit();
    var baseline_has_min = false;
    for (baseline_ir.functions.items[0].exprs.items) |expr| {
        if (expr.data == .call and std.mem.eql(u8, expr.data.call.name, "min")) {
            baseline_has_min = true;
            break;
        }
    }
    try std.testing.expect(baseline_has_min);

    var elided_ir = try analyzeToIrWithConfig(std.testing.allocator, source, .{
        .elide_proven_bounds = true,
    });
    defer elided_ir.deinit();

    if (!lean_proof.boundsProven(.gid_3d_flat_storage_buffer_offset)) {
        try std.testing.expectEqual(@as(usize, 0), elided_ir.dispatch_preconditions.items.len);
        return;
    }

    try std.testing.expectEqual(@as(usize, 1), elided_ir.dispatch_preconditions.items.len);
    const precondition = elided_ir.dispatch_preconditions.items[0];
    try std.testing.expectEqual(ir.DispatchPreconditionKind.flat_index_3d_dispatch_xy, precondition.kind);
    try std.testing.expectEqual(@as(u64, 4), precondition.element_stride_bytes);
    try std.testing.expectEqual(@as(u64, 7), precondition.element_offset);

    var elided_has_min = false;
    for (elided_ir.functions.items[0].exprs.items) |expr| {
        if (expr.data == .call and std.mem.eql(u8, expr.data.call.name, "min")) {
            elided_has_min = true;
            break;
        }
    }
    try std.testing.expect(!elided_has_min);
}

test "analyzeToIrWithConfig records texture dispatch-fit preconditions" {
    const source =
        \\@group(0) @binding(0) var src_tex: texture_2d<f32>;
        \\@group(0) @binding(1) var dst_tex: texture_storage_2d<rgba8unorm, write>;
        \\@compute @workgroup_size(8, 8, 1)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    let sample = textureLoad(src_tex, vec2u(gid.x, gid.y), 0);
        \\    textureStore(dst_tex, vec2u(gid.x, gid.y), sample);
        \\}
    ;

    var baseline_ir = try analyzeToIrWithConfig(std.testing.allocator, source, .{});
    defer baseline_ir.deinit();
    var baseline_has_clamp = false;
    for (baseline_ir.functions.items[0].exprs.items) |expr| {
        if (expr.data == .call and std.mem.eql(u8, expr.data.call.name, "clamp")) {
            baseline_has_clamp = true;
            break;
        }
    }
    try std.testing.expect(baseline_has_clamp);

    var elided_ir = try analyzeToIrWithConfig(std.testing.allocator, source, .{
        .elide_proven_texture_bounds = true,
    });
    defer elided_ir.deinit();

    const proofs_available = lean_proof.boundsProven(.gid_texture_2d_dispatch_fit);
    if (!proofs_available) {
        try std.testing.expectEqual(@as(usize, 0), elided_ir.texture_dispatch_preconditions.items.len);
        return;
    }

    try std.testing.expectEqual(@as(usize, 2), elided_ir.texture_dispatch_preconditions.items.len);
    try std.testing.expectEqual(ir.TextureDispatchPreconditionKind.gid_coords_2d, elided_ir.texture_dispatch_preconditions.items[0].kind);
    try std.testing.expectEqual(@as(u32, 0), elided_ir.texture_dispatch_preconditions.items[0].texture_binding.group);
    try std.testing.expectEqual(@as(u32, 0), elided_ir.texture_dispatch_preconditions.items[0].texture_binding.binding);
    try std.testing.expectEqual(@as(u32, 1), elided_ir.texture_dispatch_preconditions.items[1].texture_binding.binding);

    var elided_has_clamp = false;
    for (elided_ir.functions.items[0].exprs.items) |expr| {
        if (expr.data == .call and std.mem.eql(u8, expr.data.call.name, "clamp")) {
            elided_has_clamp = true;
            break;
        }
    }
    try std.testing.expect(!elided_has_clamp);
}

test "analyzeToIrWithConfig records affine texture dispatch-fit preconditions at mip level" {
    const source =
        \\@group(0) @binding(0) var src_tex: texture_2d<f32>;
        \\@compute @workgroup_size(4, 4, 1)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    _ = textureLoad(src_tex, vec2u(gid.x * 2u + 1u, gid.y * 3u + 2u), 1);
        \\}
    ;

    var module_ir = try analyzeToIrWithConfig(std.testing.allocator, source, .{
        .elide_proven_texture_bounds = true,
    });
    defer module_ir.deinit();

    if (!lean_proof.boundsProven(.gid_texture_2d_affine_dispatch_fit)) {
        try std.testing.expectEqual(@as(usize, 0), module_ir.texture_dispatch_preconditions.items.len);
        return;
    }

    try std.testing.expectEqual(@as(usize, 1), module_ir.texture_dispatch_preconditions.items.len);
    const precondition = module_ir.texture_dispatch_preconditions.items[0];
    try std.testing.expectEqual(ir.TextureDispatchPreconditionKind.gid_coords_2d, precondition.kind);
    try std.testing.expectEqual(@as(u32, 1), precondition.mip_level);
    try std.testing.expectEqual(ir.TextureDispatchCoordMode.affine, precondition.coord_mode);
    try std.testing.expectEqualSlices(u64, &.{ 2, 3, 1 }, &precondition.coord_multipliers);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 0 }, &precondition.coord_offsets);

    var has_clamp = false;
    for (module_ir.functions.items[0].exprs.items) |expr| {
        if (expr.data == .call and std.mem.eql(u8, expr.data.call.name, "clamp")) {
            has_clamp = true;
            break;
        }
    }
    try std.testing.expect(!has_clamp);
}

test "analyzeToIrWithConfig records tiled 1d texture dispatch-fit preconditions" {
    const source =
        \\@group(0) @binding(0) var src_tex: texture_1d<f32>;
        \\@compute @workgroup_size(4, 1, 1)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    let coord = (gid.x / 4u) * 8u + (gid.x % 4u) + 3u;
        \\    _ = textureLoad(src_tex, coord, 0);
        \\}
    ;

    var module_ir = try analyzeToIrWithConfig(std.testing.allocator, source, .{
        .elide_proven_texture_bounds = true,
    });
    defer module_ir.deinit();

    if (!lean_proof.boundsProven(.gid_texture_1d_tiled_dispatch_fit)) {
        try std.testing.expectEqual(@as(usize, 0), module_ir.texture_dispatch_preconditions.items.len);
        return;
    }

    try std.testing.expectEqual(@as(usize, 1), module_ir.texture_dispatch_preconditions.items.len);
    const precondition = module_ir.texture_dispatch_preconditions.items[0];
    try std.testing.expectEqual(ir.TextureDispatchPreconditionKind.gid_coords_1d, precondition.kind);
    try std.testing.expectEqual(ir.TextureDispatchCoordMode.tiled, precondition.coord_mode);
    try std.testing.expectEqualSlices(u64, &.{ 4, 1, 1 }, &precondition.coord_tile_widths);
    try std.testing.expectEqualSlices(u64, &.{ 8, 1, 1 }, &precondition.coord_tile_strides);
    try std.testing.expectEqualSlices(u64, &.{ 3, 0, 0 }, &precondition.coord_offsets);

    var has_clamp = false;
    for (module_ir.functions.items[0].exprs.items) |expr| {
        if (expr.data == .call and std.mem.eql(u8, expr.data.call.name, "clamp")) {
            has_clamp = true;
            break;
        }
    }
    try std.testing.expect(!has_clamp);
}

test "compute runtime robustness config retains texture clamps without a fallback artifact" {
    const source =
        \\@group(0) @binding(0) var src_tex: texture_2d<f32>;
        \\@group(0) @binding(1) var dst_tex: texture_storage_2d<rgba8unorm, write>;
        \\@compute @workgroup_size(8, 8, 1)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    let sample = textureLoad(src_tex, vec2u(gid.x, gid.y), 0);
        \\    textureStore(dst_tex, vec2u(gid.x, gid.y), sample);
        \\}
    ;

    var module_ir = try analyzeToIrWithConfig(
        std.testing.allocator,
        source,
        runtime_compile.compute_runtime_robustness_config(),
    );
    defer module_ir.deinit();

    try std.testing.expectEqual(@as(usize, 0), module_ir.texture_dispatch_preconditions.items.len);

    var has_clamp = false;
    for (module_ir.functions.items[0].exprs.items) |expr| {
        if (expr.data == .call and std.mem.eql(u8, expr.data.call.name, "clamp")) {
            has_clamp = true;
            break;
        }
    }
    try std.testing.expect(has_clamp);
}
