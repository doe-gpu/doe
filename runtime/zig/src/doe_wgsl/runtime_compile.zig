const std = @import("std");
const ir = @import("ir.zig");
const lean_proof = @import("../lean_proof.zig");
const mod = @import("mod.zig");

const MIN_RECORDED_PHASE_NS: u64 = 1;

pub const TranslationInfo = struct {
    workgroup_size: [3]u32 = .{ 1, 1, 1 },
    needs_sizes_buf: bool = false,
    dispatch_preconditions: []const ir.DispatchPrecondition = &.{},
    texture_dispatch_preconditions: []const ir.TextureDispatchPrecondition = &.{},

    pub fn deinit(self: *TranslationInfo, allocator: std.mem.Allocator) void {
        if (self.dispatch_preconditions.len > 0) allocator.free(self.dispatch_preconditions);
        if (self.texture_dispatch_preconditions.len > 0) allocator.free(self.texture_dispatch_preconditions);
        self.* = .{};
    }
};

pub const TranslationResult = struct {
    len: usize,
    info: TranslationInfo,
};

pub const TimedTranslationResult = struct {
    len: usize,
    info: TranslationInfo,
    phase_timings_ns: mod.CompilePhaseTimingsNs,
};

fn nowNs() i128 {
    return std.time.nanoTimestamp();
}

fn elapsedNs(start: i128, end: i128) u64 {
    if (end <= start) return MIN_RECORDED_PHASE_NS;
    const elapsed: u64 = @intCast(end - start);
    return @max(elapsed, MIN_RECORDED_PHASE_NS);
}

pub fn compute_runtime_robustness_config() mod.ir_transform_robustness.Config {
    return .{
        .elide_proven_bounds = lean_proof.bounds_elimination_available,
        .elide_dispatch_validated_bounds = true,
        .elide_dispatch_validated_global_bounds = true,
        .elide_static_storage_bounds = true,
        .elide_uniform_validated_bounds = true,
        // Runtime translation carries dispatch preconditions into pipeline
        // metadata, so it can safely consume proof-backed texture clamp elision.
        .elide_proven_texture_bounds = lean_proof.boundsProven(.gid_texture_1d_dispatch_fit) or
            lean_proof.boundsProven(.gid_texture_2d_dispatch_fit) or
            lean_proof.boundsProven(.gid_texture_3d_dispatch_fit) or
            lean_proof.boundsProven(.gid_texture_1d_affine_dispatch_fit) or
            lean_proof.boundsProven(.gid_texture_2d_affine_dispatch_fit) or
            lean_proof.boundsProven(.gid_texture_3d_affine_dispatch_fit) or
            lean_proof.boundsProven(.gid_texture_1d_tiled_dispatch_fit) or
            lean_proof.boundsProven(.gid_texture_2d_tiled_dispatch_fit) or
            lean_proof.boundsProven(.gid_texture_3d_tiled_dispatch_fit),
    };
}

pub fn vulkan_compute_runtime_robustness_config() mod.ir_transform_robustness.Config {
    return .{
        .elide_proven_bounds = lean_proof.bounds_elimination_available,
        .elide_dispatch_validated_bounds = true,
        .elide_dispatch_validated_global_bounds = true,
        .elide_static_storage_bounds = true,
        .elide_uniform_validated_bounds = true,
    };
}

pub fn translateToMslForComputeRuntime(
    allocator: std.mem.Allocator,
    wgsl: []const u8,
    out: []u8,
    overrides: ?[*]const ir.OverrideEntry,
    override_count: usize,
) mod.TranslateError!TranslationResult {
    const timed = try translateToMslForComputeRuntimeTimed(
        allocator,
        wgsl,
        out,
        overrides,
        override_count,
    );
    return .{
        .len = timed.len,
        .info = timed.info,
    };
}

pub fn translateToMslForComputeRuntimeTimed(
    allocator: std.mem.Allocator,
    wgsl: []const u8,
    out: []u8,
    overrides: ?[*]const ir.OverrideEntry,
    override_count: usize,
) mod.TranslateError!TimedTranslationResult {
    const total_start_ns = nowNs();
    var analysis = try mod.analyzeToIrWithConfigTimed(allocator, wgsl, compute_runtime_robustness_config());
    defer analysis.module.deinit();

    if (overrides != null and override_count > 0) {
        mod.applyOverrides(&analysis.module, overrides.?[0..override_count]);
    }

    const emit_start_ns = nowNs();
    const len = mod.emit_msl.emit(&analysis.module, out) catch |err| return switch (err) {
        error.OutputTooLarge => mod.TranslateError.OutputTooLarge,
        error.InvalidIr => mod.TranslateError.InvalidIr,
    };
    const emit_end_ns = nowNs();
    var phase_timings_ns = analysis.phase_timings_ns;
    phase_timings_ns.emit = elapsedNs(emit_start_ns, emit_end_ns);
    phase_timings_ns.total = elapsedNs(total_start_ns, emit_end_ns);
    return .{
        .len = len,
        .info = try build_translation_info(allocator, &analysis.module),
        .phase_timings_ns = phase_timings_ns,
    };
}

pub fn translateToSpirvForComputeRuntime(
    allocator: std.mem.Allocator,
    wgsl: []const u8,
    out: []u8,
) mod.TranslateError!TranslationResult {
    var module_ir = try mod.analyzeToIrWithConfig(allocator, wgsl, compute_runtime_robustness_config());
    defer module_ir.deinit();

    const len = mod.emit_spirv.emit(&module_ir, out) catch |err| {
        const kind: mod.TranslateError = switch (err) {
            error.OutputTooLarge => mod.TranslateError.OutputTooLarge,
            error.UnsupportedConstruct => mod.TranslateError.UnsupportedConstruct,
            error.InvalidIr => mod.TranslateError.InvalidIr,
            error.OutOfMemory => mod.TranslateError.OutOfMemory,
        };
        mod.setLastErrorDetailPublic(.spirv_emit, kind, @errorName(err));
        return kind;
    };
    return .{
        .len = len,
        .info = try build_translation_info(allocator, &module_ir),
    };
}

pub fn translateToSpirvTimed(
    allocator: std.mem.Allocator,
    wgsl: []const u8,
    out: []u8,
) mod.TranslateError!TimedTranslationResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const total_start_ns = nowNs();
    var analysis = try mod.analyzeToIrTimed(arena.allocator(), wgsl);

    const emit_start_ns = nowNs();
    const len = mod.emit_spirv.emit(&analysis.module, out) catch |err| {
        const kind: mod.TranslateError = switch (err) {
            error.OutputTooLarge => mod.TranslateError.OutputTooLarge,
            error.UnsupportedConstruct => mod.TranslateError.UnsupportedConstruct,
            error.InvalidIr => mod.TranslateError.InvalidIr,
            error.OutOfMemory => mod.TranslateError.OutOfMemory,
        };
        mod.setLastErrorDetailPublic(.spirv_emit, kind, @errorName(err));
        return kind;
    };
    const emit_end_ns = nowNs();
    var phase_timings_ns = analysis.phase_timings_ns;
    phase_timings_ns.emit = elapsedNs(emit_start_ns, emit_end_ns);
    phase_timings_ns.total = elapsedNs(total_start_ns, emit_end_ns);
    return .{
        .len = len,
        .info = try build_translation_info(allocator, &analysis.module),
        .phase_timings_ns = phase_timings_ns,
    };
}

pub fn translateToSpirvForVulkanComputeRuntime(
    allocator: std.mem.Allocator,
    wgsl: []const u8,
    out: []u8,
) mod.TranslateError!TranslationResult {
    var module_ir = try mod.analyzeToIrWithConfig(allocator, wgsl, vulkan_compute_runtime_robustness_config());
    defer module_ir.deinit();

    const len = mod.emit_spirv.emit(&module_ir, out) catch |err| {
        const kind: mod.TranslateError = switch (err) {
            error.OutputTooLarge => mod.TranslateError.OutputTooLarge,
            error.UnsupportedConstruct => mod.TranslateError.UnsupportedConstruct,
            error.InvalidIr => mod.TranslateError.InvalidIr,
            error.OutOfMemory => mod.TranslateError.OutOfMemory,
        };
        mod.setLastErrorDetailPublic(.spirv_emit, kind, @errorName(err));
        return kind;
    };
    return .{
        .len = len,
        .info = try build_translation_info(allocator, &module_ir),
    };
}

/// Vertex input attribute extracted from the IR for pipeline reflection.
pub const VertexInputAttr = struct {
    location: u32,
    builtin: ir.Builtin,
};

/// Inter-stage I/O variable extracted from the IR for pipeline reflection.
pub const InterStageVar = struct {
    location: u32,
    interpolation: ?ir.Interpolation,
    builtin: ir.Builtin,
};

/// Result of translating a WGSL module containing vertex and/or fragment entry
/// points into per-stage SPIR-V binaries. Caller owns all heap allocations and
/// must call deinit to release them.
pub const GraphicsTranslationResult = struct {
    vertex_spirv: ?[]const u32 = null,
    fragment_spirv: ?[]const u32 = null,
    vertex_input_attrs: []const VertexInputAttr = &.{},
    inter_stage_vars: []const InterStageVar = &.{},
    has_vertex: bool = false,
    has_fragment: bool = false,

    pub fn deinit(self: *GraphicsTranslationResult, allocator: std.mem.Allocator) void {
        if (self.vertex_spirv) |s| allocator.free(s);
        if (self.fragment_spirv) |s| allocator.free(s);
        if (self.vertex_input_attrs.len > 0) allocator.free(self.vertex_input_attrs);
        if (self.inter_stage_vars.len > 0) allocator.free(self.inter_stage_vars);
        self.* = .{};
    }
};

/// Graphics shaders use the same robustness config as compute — Lean proof
/// elimination applies to any array bounds regardless of pipeline stage.
fn graphics_runtime_robustness_config() mod.ir_transform_robustness.Config {
    return .{
        .elide_proven_bounds = lean_proof.bounds_elimination_available,
    };
}

/// Translate WGSL source containing vertex and/or fragment entry points into
/// separate per-stage SPIR-V binaries. Returns heap-allocated u32 word slices
/// for each stage found, plus extracted vertex input and inter-stage interface
/// metadata for pipeline reflection.
pub fn translateToSpirvForGraphicsRuntime(
    allocator: std.mem.Allocator,
    wgsl: []const u8,
) mod.TranslateError!GraphicsTranslationResult {
    var module_ir = try mod.analyzeToIrWithConfig(allocator, wgsl, graphics_runtime_robustness_config());
    defer module_ir.deinit();

    var result = GraphicsTranslationResult{};
    errdefer result.deinit(allocator);

    for (module_ir.entry_points.items) |entry| {
        switch (entry.stage) {
            .vertex => {
                result.has_vertex = true;
                result.vertex_spirv = try emit_stage_spirv_words(allocator, &module_ir, .vertex);
            },
            .fragment => {
                result.has_fragment = true;
                result.fragment_spirv = try emit_stage_spirv_words(allocator, &module_ir, .fragment);
            },
            .compute => {},
        }
    }

    result.vertex_input_attrs = try extract_vertex_inputs(allocator, &module_ir);
    result.inter_stage_vars = try extract_inter_stage_vars(allocator, &module_ir);

    return result;
}

/// Emit SPIR-V for a single stage and convert the byte output to heap-allocated u32 words.
fn emit_stage_spirv_words(
    allocator: std.mem.Allocator,
    module_ir: *const ir.Module,
    stage: ir.ShaderStage,
) mod.TranslateError![]const u32 {
    var spirv_buf = allocator.alloc(u8, mod.MAX_SPIRV_OUTPUT) catch return mod.TranslateError.OutOfMemory;
    defer allocator.free(spirv_buf);

    const len = mod.emit_spirv.emitForStage(module_ir, stage, spirv_buf) catch |err| return switch (err) {
        error.OutputTooLarge => mod.TranslateError.OutputTooLarge,
        error.UnsupportedConstruct => mod.TranslateError.UnsupportedConstruct,
        error.InvalidIr => mod.TranslateError.InvalidIr,
        error.OutOfMemory => mod.TranslateError.OutOfMemory,
    };

    if (len == 0 or (len % 4) != 0) return mod.TranslateError.InvalidIr;

    const word_count = len / 4;
    const words = allocator.alloc(u32, word_count) catch return mod.TranslateError.OutOfMemory;
    for (words, 0..) |*w, i| {
        const offset = i * 4;
        const chunk: *const [4]u8 = @ptrCast(spirv_buf[offset .. offset + 4].ptr);
        w.* = std.mem.readInt(u32, chunk, .little);
    }
    return words;
}

const MAX_VERTEX_INPUT_ATTRS: usize = 32;
const MAX_INTER_STAGE_VARS: usize = 32;

/// Extract vertex input attributes (location-decorated parameters) from all
/// vertex entry points in the module.
fn extract_vertex_inputs(
    allocator: std.mem.Allocator,
    module_ir: *const ir.Module,
) mod.TranslateError![]const VertexInputAttr {
    var attrs_buf: [MAX_VERTEX_INPUT_ATTRS]VertexInputAttr = undefined;
    var count: usize = 0;

    for (module_ir.entry_points.items) |entry| {
        if (entry.stage != .vertex) continue;
        const function = &module_ir.functions.items[entry.function];
        for (function.params.items) |param| {
            // Struct-typed params: each field is a separate vertex input.
            switch (module_ir.types.get(param.ty)) {
                .struct_ => |struct_id| {
                    const struct_def = module_ir.structs.items[struct_id];
                    for (struct_def.fields.items) |field| {
                        if (count >= MAX_VERTEX_INPUT_ATTRS) break;
                        const io = field.io orelse continue;
                        attrs_buf[count] = .{
                            .location = io.location orelse 0,
                            .builtin = io.builtin,
                        };
                        count += 1;
                    }
                },
                else => {
                    if (count >= MAX_VERTEX_INPUT_ATTRS) break;
                    const io = param.io orelse continue;
                    attrs_buf[count] = .{
                        .location = io.location orelse 0,
                        .builtin = io.builtin,
                    };
                    count += 1;
                },
            }
        }
    }

    if (count == 0) return &.{};
    return allocator.dupe(VertexInputAttr, attrs_buf[0..count]) catch return mod.TranslateError.OutOfMemory;
}

/// Extract inter-stage interface variables from vertex output / fragment input.
/// These are the location-decorated fields of the vertex entry point return type.
fn extract_inter_stage_vars(
    allocator: std.mem.Allocator,
    module_ir: *const ir.Module,
) mod.TranslateError![]const InterStageVar {
    var vars_buf: [MAX_INTER_STAGE_VARS]InterStageVar = undefined;
    var count: usize = 0;

    for (module_ir.entry_points.items) |entry| {
        if (entry.stage != .vertex) continue;
        const function = &module_ir.functions.items[entry.function];
        switch (module_ir.types.get(function.return_type)) {
            .struct_ => |struct_id| {
                const struct_def = module_ir.structs.items[struct_id];
                for (struct_def.fields.items) |field| {
                    if (count >= MAX_INTER_STAGE_VARS) break;
                    const io = field.io orelse continue;
                    // Skip builtins like @builtin(position) — they are not user inter-stage vars.
                    if (io.builtin != .none and io.location == null) continue;
                    vars_buf[count] = .{
                        .location = io.location orelse 0,
                        .interpolation = io.interpolation,
                        .builtin = io.builtin,
                    };
                    count += 1;
                }
            },
            else => {
                // Non-struct return with IO attr (e.g. @location(0) vec4f).
                if (function.return_io) |io| {
                    if (count < MAX_INTER_STAGE_VARS and (io.builtin == .none or io.location != null)) {
                        vars_buf[count] = .{
                            .location = io.location orelse 0,
                            .interpolation = io.interpolation,
                            .builtin = io.builtin,
                        };
                        count += 1;
                    }
                }
            },
        }
    }

    if (count == 0) return &.{};
    return allocator.dupe(InterStageVar, vars_buf[0..count]) catch return mod.TranslateError.OutOfMemory;
}

fn build_translation_info(
    allocator: std.mem.Allocator,
    module_ir: *const ir.Module,
) mod.TranslateError!TranslationInfo {
    return .{
        .workgroup_size = compute_workgroup_size(module_ir),
        .needs_sizes_buf = mod.emit_msl.moduleNeedsSizesParam(module_ir),
        .dispatch_preconditions = if (module_ir.dispatch_preconditions.items.len == 0)
            &.{}
        else
            allocator.dupe(ir.DispatchPrecondition, module_ir.dispatch_preconditions.items) catch return mod.TranslateError.OutOfMemory,
        .texture_dispatch_preconditions = if (module_ir.texture_dispatch_preconditions.items.len == 0)
            &.{}
        else
            allocator.dupe(ir.TextureDispatchPrecondition, module_ir.texture_dispatch_preconditions.items) catch return mod.TranslateError.OutOfMemory,
    };
}

fn compute_workgroup_size(module_ir: *const ir.Module) [3]u32 {
    for (module_ir.entry_points.items) |entry| {
        if (entry.stage == .compute) return entry.workgroup_size;
    }
    return .{ 1, 1, 1 };
}

test "timed compute runtime translation reports compiler phases" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = data[id.x] * 2.0;
        \\}
    ;
    var out: [mod.MAX_OUTPUT]u8 = undefined;
    var result = try translateToMslForComputeRuntimeTimed(
        std.testing.allocator,
        source,
        &out,
        null,
        0,
    );
    defer result.info.deinit(std.testing.allocator);

    try std.testing.expect(result.len > 0);
    try std.testing.expect(result.phase_timings_ns.parse > 0);
    try std.testing.expect(result.phase_timings_ns.sema > 0);
    try std.testing.expect(result.phase_timings_ns.lower > 0);
    try std.testing.expect(result.phase_timings_ns.emit > 0);
    try std.testing.expect(result.phase_timings_ns.total >= result.phase_timings_ns.parse);
    try std.testing.expect(result.phase_timings_ns.total >= result.phase_timings_ns.emit);
}

test "compute runtime elides workgroup id storage clamp with dispatch precondition" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(workgroup_id) wid: vec3u) {
        \\    data[wid.x] = 1.0;
        \\}
    ;
    var out: [mod.MAX_OUTPUT]u8 = undefined;
    var result = try translateToMslForComputeRuntimeTimed(
        std.testing.allocator,
        source,
        &out,
        null,
        0,
    );
    defer result.info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.info.dispatch_preconditions.len);
    const precondition = result.info.dispatch_preconditions[0];
    try std.testing.expectEqual(ir.DispatchPreconditionKind.workgroup_component, precondition.kind);
    try std.testing.expectEqual(@as(u8, 0), precondition.gid_axis);
    const msl = out[0..result.len];
    try std.testing.expect(std.mem.indexOf(u8, msl, "_doe_sizes") == null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "min(") == null);
}

test "compute runtime elides global id storage clamp with dispatch precondition" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = 1.0;
        \\}
    ;
    var out: [mod.MAX_OUTPUT]u8 = undefined;
    var result = try translateToMslForComputeRuntimeTimed(
        std.testing.allocator,
        source,
        &out,
        null,
        0,
    );
    defer result.info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.info.dispatch_preconditions.len);
    const precondition = result.info.dispatch_preconditions[0];
    try std.testing.expectEqual(ir.DispatchPreconditionKind.gid_component, precondition.kind);
    try std.testing.expectEqual(@as(u8, 0), precondition.gid_axis);
    const msl = out[0..result.len];
    try std.testing.expect(std.mem.indexOf(u8, msl, "_doe_sizes") == null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "min(") == null);
}

test "compute runtime elides local invocation loop storage clamp with dispatch precondition" {
    const source =
        \\const K_WORKGROUP_SIZE: u32 = 256u;
        \\const K_WORKGROUP_ARRAY_SIZE: u32 = 2048u;
        \\const K_LOOP_LENGTH: u32 = K_WORKGROUP_ARRAY_SIZE / K_WORKGROUP_SIZE;
        \\@group(0) @binding(0) var<storage, read_write> dst: array<f32>;
        \\var<workgroup> wg: array<f32, K_WORKGROUP_ARRAY_SIZE>;
        \\@compute @workgroup_size(K_WORKGROUP_SIZE, 1, 1)
        \\fn main(@builtin(local_invocation_id) local_id: vec3u) {
        \\    for (var k: u32 = 0u; k < K_LOOP_LENGTH; k = k + 1u) {
        \\        let index: u32 = K_LOOP_LENGTH * local_id.x + k;
        \\        dst[index] = wg[index];
        \\    }
        \\}
    ;
    var out: [mod.MAX_OUTPUT]u8 = undefined;
    var result = try translateToMslForComputeRuntimeTimed(
        std.testing.allocator,
        source,
        &out,
        null,
        0,
    );
    defer result.info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.info.dispatch_preconditions.len);
    const precondition = result.info.dispatch_preconditions[0];
    try std.testing.expectEqual(ir.DispatchPreconditionKind.local_invocation_component, precondition.kind);
    try std.testing.expectEqual(@as(u8, 0), precondition.gid_axis);
    try std.testing.expectEqual(@as(u64, 8), precondition.element_multiplier);
    try std.testing.expectEqual(@as(u64, 8), precondition.loop_limit);
    try std.testing.expectEqual(@as(u64, 1), precondition.loop_limit_multiplier);
    try std.testing.expect(!result.info.needs_sizes_buf);
    const msl = out[0..result.len];
    try std.testing.expect(std.mem.indexOf(u8, msl, "_doe_sizes") == null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "min(") == null);
}

test "compute runtime emits zero for unwritten workgroup reads" {
    const source =
        \\const K_WORKGROUP_SIZE: u32 = 256u;
        \\const K_WORKGROUP_ARRAY_SIZE: u32 = 2048u;
        \\const K_LOOP_LENGTH: u32 = K_WORKGROUP_ARRAY_SIZE / K_WORKGROUP_SIZE;
        \\@group(0) @binding(0) var<storage, read_write> dst: array<f32>;
        \\var<workgroup> wg: array<f32, K_WORKGROUP_ARRAY_SIZE>;
        \\@compute @workgroup_size(K_WORKGROUP_SIZE, 1, 1)
        \\fn main(@builtin(local_invocation_id) local_id: vec3u) {
        \\    for (var k: u32 = 0u; k < K_LOOP_LENGTH; k = k + 1u) {
        \\        let index: u32 = K_LOOP_LENGTH * local_id.x + k;
        \\        dst[index] = wg[index];
        \\    }
        \\}
    ;
    var out: [mod.MAX_OUTPUT]u8 = undefined;
    var result = try translateToMslForComputeRuntimeTimed(
        std.testing.allocator,
        source,
        &out,
        null,
        0,
    );
    defer result.info.deinit(std.testing.allocator);

    try std.testing.expect(!result.info.needs_sizes_buf);
    const msl = out[0..result.len];
    try std.testing.expect(std.mem.indexOf(u8, msl, "threadgroup float wg") == null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "wg[") == null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "= 0.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "_doe_sizes") == null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "min(") == null);
}

test "compute runtime preserves written workgroup storage" {
    const source =
        \\const K_WORKGROUP_SIZE: u32 = 256u;
        \\const K_WORKGROUP_ARRAY_SIZE: u32 = 2048u;
        \\const K_LOOP_LENGTH: u32 = K_WORKGROUP_ARRAY_SIZE / K_WORKGROUP_SIZE;
        \\@group(0) @binding(0) var<storage, read_write> dst: array<f32>;
        \\var<workgroup> wg: array<f32, K_WORKGROUP_ARRAY_SIZE>;
        \\@compute @workgroup_size(K_WORKGROUP_SIZE, 1, 1)
        \\fn main(@builtin(local_invocation_id) local_id: vec3u) {
        \\    for (var k: u32 = 0u; k < K_LOOP_LENGTH; k = k + 1u) {
        \\        let index: u32 = K_LOOP_LENGTH * local_id.x + k;
        \\        wg[index] = f32(index);
        \\        dst[index] = wg[index];
        \\    }
        \\}
    ;
    var out: [mod.MAX_OUTPUT]u8 = undefined;
    var result = try translateToMslForComputeRuntimeTimed(
        std.testing.allocator,
        source,
        &out,
        null,
        0,
    );
    defer result.info.deinit(std.testing.allocator);

    const msl = out[0..result.len];
    try std.testing.expect(std.mem.indexOf(u8, msl, "threadgroup float wg") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "wg[") != null);
}

test "compute runtime lowers single invocation scalar workgroup storage to thread local" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data : array<u32, 1>;
        \\var<workgroup> wg_data : u32;
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    wg_data = data[0];
        \\    workgroupBarrier();
        \\    data[0] = wg_data;
        \\}
    ;
    var out: [mod.MAX_OUTPUT]u8 = undefined;
    var result = try translateToMslForComputeRuntimeTimed(
        std.testing.allocator,
        source,
        &out,
        null,
        0,
    );
    defer result.info.deinit(std.testing.allocator);

    const msl = out[0..result.len];
    try std.testing.expect(std.mem.indexOf(u8, msl, "threadgroup uint wg_data") == null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "uint wg_data;") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "threadgroup_barrier") == null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "(void)0") != null);
}

test "compute runtime preserves single invocation workgroup arrays" {
    const source =
        \\const kBufferSize : u32 = 1024u;
        \\@group(0) @binding(0) var<storage, read_write> data : array<u32, kBufferSize>;
        \\var<workgroup> wg_data : array<u32, kBufferSize>;
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    for (var i : u32 = 0u; i < kBufferSize; i = i + 1u) {
        \\        wg_data[i] = data[i];
        \\    }
        \\    data[0] = wg_data[0];
        \\}
    ;
    var out: [mod.MAX_OUTPUT]u8 = undefined;
    var result = try translateToMslForComputeRuntimeTimed(
        std.testing.allocator,
        source,
        &out,
        null,
        0,
    );
    defer result.info.deinit(std.testing.allocator);

    const msl = out[0..result.len];
    try std.testing.expect(std.mem.indexOf(u8, msl, "threadgroup uint wg_data[1024];") != null);
}

test "compute runtime elides bitmasked workgroup array clamp" {
    const source =
        \\const kBufferSize : u32 = 1024u;
        \\const kBufferMask : u32 = kBufferSize - 1u;
        \\@group(0) @binding(0) var<storage, read_write> inout_data : array<u32, kBufferSize>;
        \\var<workgroup> wg_data : array<u32, kBufferSize>;
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    var accum : u32 = inout_data[0];
        \\    for (var i : u32 = 0u; i < kBufferSize; i = i + 1u) {
        \\        wg_data[i] = inout_data[i];
        \\    }
        \\    for (var i : u32 = 0u; i < 1000000u; i = i + 1u) {
        \\        let idx = (i + accum) & kBufferMask;
        \\        accum = (accum ^ wg_data[idx]) + 123u;
        \\    }
        \\    inout_data[0] = accum;
        \\}
    ;
    var out: [mod.MAX_OUTPUT]u8 = undefined;
    var result = try translateToMslForComputeRuntimeTimed(
        std.testing.allocator,
        source,
        &out,
        null,
        0,
    );
    defer result.info.deinit(std.testing.allocator);

    const msl = out[0..result.len];
    try std.testing.expect(std.mem.indexOf(u8, msl, "threadgroup uint wg_data[1024];") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "wg_data[min(") == null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "wg_data[idx]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "inout_data[min(") == null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "inout_data[i]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "inout_data[uint(0)]") != null or
        std.mem.indexOf(u8, msl, "inout_data[0]") != null);
}

test "vulkan compute runtime elides global id storage clamp with dispatch precondition" {
    const source =
        \\@group(0) @binding(0) var<storage, read> input_values: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> output_values: array<f32>;
        \\@compute @workgroup_size(256)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    output_values[id.x] = input_values[id.x] * 2.0;
        \\}
    ;
    var out: [mod.MAX_SPIRV_OUTPUT]u8 = undefined;
    var result = try translateToSpirvForVulkanComputeRuntime(
        std.testing.allocator,
        source,
        &out,
    );
    defer result.info.deinit(std.testing.allocator);

    var gid_preconditions: usize = 0;
    for (result.info.dispatch_preconditions) |precondition| {
        if (precondition.kind != .gid_component) continue;
        try std.testing.expectEqual(@as(u8, 0), precondition.gid_axis);
        gid_preconditions += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), gid_preconditions);
}

test "vulkan compute runtime elides uniform product guarded storage clamp" {
    const source =
        \\struct Dims {
        \\    M: u32,
        \\    K: u32,
        \\    N: u32,
        \\    _pad: u32,
        \\}
        \\@group(0) @binding(2) var<storage, read_write> c: array<f32>;
        \\@group(0) @binding(3) var<uniform> dims: Dims;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(workgroup_id) wid: vec3u) {
        \\    let row = wid.y * 16u;
        \\    let col = wid.x * 16u;
        \\    if (row + 1u < dims.M && col + 1u < dims.N) {
        \\        c[((row + 1u) * dims.N + col) + 1u] = 1.0;
        \\    }
        \\}
    ;
    var out: [mod.MAX_SPIRV_OUTPUT]u8 = undefined;
    var result = try translateToSpirvForVulkanComputeRuntime(
        std.testing.allocator,
        source,
        &out,
    );
    defer result.info.deinit(std.testing.allocator);

    var saw_c_extent = false;
    for (result.info.dispatch_preconditions) |precondition| {
        if (precondition.kind != .uniform_extent) continue;
        if (precondition.storage_binding.binding != 2) continue;
        try std.testing.expectEqual(@as(u32, 3), precondition.uniform_binding.binding);
        try std.testing.expectEqual(@as(u32, 0), precondition.uniform_u32_offsets[0]);
        try std.testing.expectEqual(@as(u32, 8), precondition.uniform_u32_offsets[1]);
        try std.testing.expectEqual(@as(u8, 2), precondition.uniform_u32_count);
        saw_c_extent = true;
    }
    try std.testing.expect(saw_c_extent);
}

test "compute runtime elides uniform guarded GEMV storage clamps" {
    const source =
        \\struct Uniforms {
        \\    rows: u32,
        \\    cols: u32,
        \\    _pad0: u32,
        \\    _pad1: u32,
        \\}
        \\@group(0) @binding(0) var<uniform> u: Uniforms;
        \\@group(0) @binding(1) var<storage, read> matrix: array<f32>;
        \\@group(0) @binding(2) var<storage, read> vector: array<f32>;
        \\@group(0) @binding(3) var<storage, read_write> output: array<f32>;
        \\var<workgroup> partial_sums: array<f32, 64>;
        \\fn partial(row: u32, lane: u32) -> f32 {
        \\    let base = row * u.cols;
        \\    let vec_cols = u.cols & ~3u;
        \\    var c = lane * 4u;
        \\    var acc = 0.0;
        \\    loop {
        \\        if (c >= vec_cols) { break; }
        \\        acc = acc + matrix[base + c] + matrix[base + c + 1u] + vector[c + 2u] + vector[c + 3u];
        \\        c = c + 256u;
        \\    }
        \\    c = vec_cols + lane;
        \\    loop {
        \\        if (c >= u.cols) { break; }
        \\        acc = acc + matrix[base + c] * vector[c];
        \\        c = c + 64u;
        \\    }
        \\    return acc;
        \\}
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(workgroup_id) wid: vec3u, @builtin(local_invocation_id) lid: vec3u) {
        \\    let row = wid.x;
        \\    if (row >= u.rows) { return; }
        \\    let lane = lid.x;
        \\    partial_sums[lane] = partial(row, lane);
        \\    workgroupBarrier();
        \\    if (lane == 0u) { output[row] = partial_sums[0]; }
        \\}
    ;
    var out: [mod.MAX_OUTPUT]u8 = undefined;
    var result = try translateToMslForComputeRuntimeTimed(
        std.testing.allocator,
        source,
        &out,
        null,
        0,
    );
    defer result.info.deinit(std.testing.allocator);

    var saw_uniform_extent = false;
    for (result.info.dispatch_preconditions) |precondition| {
        if (precondition.kind == .uniform_extent) saw_uniform_extent = true;
    }
    try std.testing.expect(saw_uniform_extent);
    const msl = out[0..result.len];
    try std.testing.expect(!result.info.needs_sizes_buf);
    try std.testing.expect(std.mem.indexOf(u8, msl, "_doe_sizes") == null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "min(") == null);
}

test "compute runtime elides uniform guarded gid storage clamps" {
    const source =
        \\struct Params {
        \\    count: u32,
        \\    _pad0: u32,
        \\    _pad1: u32,
        \\    _pad2: u32,
        \\}
        \\@group(0) @binding(0) var<uniform> params: Params;
        \\@group(0) @binding(1) var<storage, read> input_values: array<f32>;
        \\@group(0) @binding(2) var<storage, read_write> output_values: array<f32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    let index = gid.x;
        \\    if (index >= params.count) { return; }
        \\    output_values[index] = (input_values[index] * 1.5) + 0.25;
        \\}
    ;
    var out: [mod.MAX_OUTPUT]u8 = undefined;
    var result = try translateToMslForComputeRuntimeTimed(
        std.testing.allocator,
        source,
        &out,
        null,
        0,
    );
    defer result.info.deinit(std.testing.allocator);

    const proof_backed = lean_proof.boundsProven(.gid_1d_storage_buffer);
    var precondition_count: usize = 0;
    var saw_input = false;
    var saw_output = false;
    for (result.info.dispatch_preconditions) |precondition| {
        if (proof_backed) {
            if (precondition.kind != .gid_component) continue;
            try std.testing.expectEqual(@as(u8, 0), precondition.gid_axis);
            try std.testing.expectEqual(@as(u64, 1), precondition.element_multiplier);
        } else {
            if (precondition.kind != .uniform_extent) continue;
            try std.testing.expectEqual(@as(u32, 0), precondition.uniform_binding.group);
            try std.testing.expectEqual(@as(u32, 0), precondition.uniform_binding.binding);
            try std.testing.expectEqual(@as(u32, 0), precondition.uniform_u32_offsets[0]);
            try std.testing.expectEqual(@as(u8, 1), precondition.uniform_u32_count);
        }
        try std.testing.expectEqual(@as(u32, 0), precondition.storage_binding.group);
        switch (precondition.storage_binding.binding) {
            1 => saw_input = true,
            2 => saw_output = true,
            else => return error.TestUnexpectedResult,
        }
        precondition_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), precondition_count);
    try std.testing.expect(saw_input);
    try std.testing.expect(saw_output);

    const msl = out[0..result.len];
    try std.testing.expect(!result.info.needs_sizes_buf);
    try std.testing.expect(std.mem.indexOf(u8, msl, "_doe_sizes") == null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "min(") == null);
}

test "compute runtime emits Metal max total threads from workgroup size" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\@compute @workgroup_size(8, 4, 2)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    data[gid.x] = gid.y + gid.z;
        \\}
    ;
    var out: [mod.MAX_OUTPUT]u8 = undefined;
    var result = try translateToMslForComputeRuntimeTimed(
        std.testing.allocator,
        source,
        &out,
        null,
        0,
    );
    defer result.info.deinit(std.testing.allocator);

    const msl = out[0..result.len];
    try std.testing.expect(std.mem.indexOf(u8, msl, "[[max_total_threads_per_threadgroup(64)]]") != null);
}
