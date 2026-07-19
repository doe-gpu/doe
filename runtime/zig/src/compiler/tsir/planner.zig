// TSIR realization planner.
//
// This pass is the Step 5/6 bridge between backend-independent TSIR
// semantics and mechanical emitters. It is deliberately conservative:
// first-fit tiles, explicit residency decisions, descriptor-declared
// collective support, and typed rejections instead of template rescue.
//
// Collective synthesis itself lives in `collective_synthesis.zig` per
// `docs/tsir-lowering-plan.md §Step 6`; this planner calls into that
// pass while owning residency, tiles, reductions, and overall plan
// assembly.

const std = @import("std");
const targets = @import("../targets/mod.zig");
const tsir = @import("mod.zig");
const collective_synthesis = @import("collective_synthesis.zig");

const FIRST_FIT_TILE_CAP: u32 = 64;
const FIRST_FIT_PE_GRID_WIDTH_CAP: u32 = 8;
const DEFAULT_EMITTER_PARAMS_JSON = "{\"planner\":\"tsir.first_fit_v1\"}";

pub const PlannerError = error{
    OutOfMemory,
};

pub const LoaderCapabilities = struct {
    fabric_streaming: bool = false,
    max_stream_chunk_bytes: u64 = 0,
};

pub const Options = struct {
    loader: LoaderCapabilities = .{},
    emitter_digest: [32]u8 = [_]u8{0} ** 32,
    emitter_params_json: []const u8 = DEFAULT_EMITTER_PARAMS_JSON,
};

pub fn planRealization(
    allocator: std.mem.Allocator,
    semantic: tsir.Semantic,
    descriptor: targets.TargetDescriptor,
    options: Options,
) PlannerError!tsir.Realization {
    var rejections = std.ArrayList(tsir.RejectionEntry){};
    defer rejections.deinit(allocator);

    const functions = try allocator.alloc(tsir.schema.RealizationFunction, semantic.functions.len);
    errdefer allocator.free(functions);

    const target_hash = targets.descriptorHash(descriptor);
    const pe_grid = choosePEGrid(descriptor);

    for (semantic.functions, 0..) |func, function_index| {
        const tiles = try planTiles(allocator, func.axes);
        const residency = try planResidency(
            allocator,
            func,
            @intCast(function_index),
            descriptor,
            pe_grid,
            options.loader,
            &rejections,
        );
        const collectives = try collective_synthesis.synthesize(
            allocator,
            func,
            @intCast(function_index),
            descriptor,
            tiles,
            &rejections,
        );
        const reductions = try synthesizeReductions(
            allocator,
            func,
            @intCast(function_index),
            descriptor,
            &rejections,
        );
        const emitter_params = try allocator.dupe(u8, options.emitter_params_json);

        functions[function_index] = .{
            .semantic_index = @intCast(function_index),
            .tiles = .{ .per_axis = tiles },
            .pe_grid = pe_grid,
            .residency = residency,
            .collectives = collectives,
            .reductions = reductions,
            .emitter_params_json = emitter_params,
            .target_descriptor_hash = target_hash,
        };
    }

    const rejection_slice = rejections.toOwnedSlice(allocator) catch return error.OutOfMemory;

    return .{
        .contract_version = tsir.CONTRACT_VERSION,
        .functions = functions,
        .emitter_digest = options.emitter_digest,
        .rejections = rejection_slice,
    };
}

fn planTiles(
    allocator: std.mem.Allocator,
    axes: []const tsir.schema.IterationAxis,
) PlannerError![]const u32 {
    const out = try allocator.alloc(u32, axes.len);
    errdefer allocator.free(out);
    for (axes, 0..) |axis, i| {
        out[i] = chooseTile(axis.upper_bound);
    }
    return out;
}

fn chooseTile(upper_bound: []const u8) u32 {
    const parsed = std.fmt.parseUnsigned(u32, upper_bound, 10) catch return 1;
    if (parsed == 0) return 1;
    const capped = @min(parsed, FIRST_FIT_TILE_CAP);
    return floorPowerOfTwo(capped);
}

fn choosePEGrid(descriptor: targets.TargetDescriptor) tsir.schema.PEGridShape {
    if (descriptor.correctness.fabric_color_count == 0) {
        return .{ .width = 1, .height = 1 };
    }
    const width = @min(
        FIRST_FIT_PE_GRID_WIDTH_CAP,
        @max(@as(u32, 1), descriptor.correctness.max_collective_group_size),
    );
    return .{ .width = width, .height = 1 };
}

fn planResidency(
    allocator: std.mem.Allocator,
    func: tsir.schema.SemanticFunction,
    function_index: u32,
    descriptor: targets.TargetDescriptor,
    pe_grid: tsir.schema.PEGridShape,
    loader: LoaderCapabilities,
    rejections: *std.ArrayList(tsir.RejectionEntry),
) PlannerError![]const tsir.schema.ResidencyDecision {
    var decisions = std.ArrayList(tsir.schema.ResidencyDecision){};
    defer decisions.deinit(allocator);

    for (func.bindings, 0..) |binding, binding_index| {
        const estimated = estimateBindingBytes(binding);
        if (estimated) |bytes| {
            if (bytes <= descriptor.correctness.pe_working_memory_bytes) {
                try decisions.append(allocator, .{
                    .binding_index = @intCast(binding_index),
                    .class = .pe_replicated,
                });
                continue;
            }
            if (chooseSliceAxis(binding.logical_shape)) |axis| {
                const shards = @max(@as(u32, 1), pe_grid.width);
                const sliced_bytes = divCeil(bytes, shards);
                if (sliced_bytes <= descriptor.correctness.pe_working_memory_bytes) {
                    try decisions.append(allocator, .{
                        .binding_index = @intCast(binding_index),
                        .class = .pe_sliced,
                        .axis = axis,
                        .shards = shards,
                    });
                    continue;
                }
            }
        } else {
            switch (descriptor.correctness.runtime_sized_binding_policy) {
                .host_copied => {
                    try decisions.append(allocator, .{
                        .binding_index = @intCast(binding_index),
                        .class = .host_copied,
                    });
                    continue;
                },
                .fabric_streamed_with_loader => {
                    if (loader.fabric_streaming and descriptor.correctness.fabric_color_count > 0) {
                        try decisions.append(allocator, .{
                            .binding_index = @intCast(binding_index),
                            .class = .fabric_streamed,
                            .fabric_color = 0,
                            .chunk_bytes = chooseStreamChunkBytes(descriptor, loader),
                        });
                        continue;
                    }
                },
                .reject => {},
            }
        }

        if (loader.fabric_streaming and descriptor.correctness.fabric_color_count > 0) {
            try decisions.append(allocator, .{
                .binding_index = @intCast(binding_index),
                .class = .fabric_streamed,
                .fabric_color = 0,
                .chunk_bytes = chooseStreamChunkBytes(descriptor, loader),
            });
            continue;
        }

        const path = try std.fmt.allocPrint(
            allocator,
            "functions[{d}].bindings[{d}]",
            .{ function_index, binding_index },
        );
        const detail = try allocator.dupe(
            u8,
            "binding footprint exceeds per-PE budget without legal slice or stream",
        );
        try rejections.append(allocator, .{
            .reason = .tsir_pe_budget_exhausted,
            .node_path = path,
            .detail = detail,
        });
    }

    return decisions.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn estimateBindingBytes(binding: tsir.schema.BufferBinding) ?u64 {
    var elems: u64 = 1;
    for (binding.logical_shape) |dim| {
        if (dim == 0) return null;
        elems = std.math.mul(u64, elems, dim) catch return null;
    }
    return std.math.mul(u64, elems, binding.elem.byteSize()) catch return null;
}

fn chooseSliceAxis(shape: []const u64) ?u32 {
    if (shape.len == 0) return null;
    var best_index: u32 = 0;
    var best_dim: u64 = shape[0];
    for (shape[1..], 1..) |dim, i| {
        if (dim > best_dim) {
            best_index = @intCast(i);
            best_dim = dim;
        }
    }
    if (best_dim <= 1) return null;
    return best_index;
}

fn chooseStreamChunkBytes(
    descriptor: targets.TargetDescriptor,
    loader: LoaderCapabilities,
) u64 {
    const budget = @max(@as(u64, 1), descriptor.correctness.pe_working_memory_bytes);
    if (loader.max_stream_chunk_bytes == 0) return budget;
    return @min(loader.max_stream_chunk_bytes, budget);
}

fn synthesizeReductions(
    allocator: std.mem.Allocator,
    func: tsir.schema.SemanticFunction,
    function_index: u32,
    descriptor: targets.TargetDescriptor,
    rejections: *std.ArrayList(tsir.RejectionEntry),
) PlannerError![]const tsir.schema.ReductionRealizationNode {
    var out = std.ArrayList(tsir.schema.ReductionRealizationNode){};
    defer out.deinit(allocator);

    for (func.reductions, 0..) |reduction, reduction_index| {
        if (!supportsNumericalMode(descriptor, reduction.contract.accumulation)) {
            try appendRejection(
                allocator,
                rejections,
                .tsir_target_unfit,
                function_index,
                "reductions",
                @intCast(reduction_index),
                "reduction accumulation dtype is not native on target",
            );
            continue;
        }
        if (reduction.contract.associativity == .associative_allowed) {
            try out.append(allocator, .{
                .semantic_index = @intCast(reduction_index),
                .tree_shape = .linear,
            });
        }
    }

    return out.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

pub fn supportsNumericalMode(
    descriptor: targets.TargetDescriptor,
    kind: tsir.ScalarKind,
) bool {
    const mode = numericalModeForScalar(kind) orelse return false;
    for (descriptor.correctness.native_numerical_modes) |native| {
        if (native == mode) return true;
    }
    return false;
}

fn numericalModeForScalar(kind: tsir.ScalarKind) ?targets.NumericalMode {
    return switch (kind) {
        .f32 => .f32,
        .f16 => .f16,
        .bf16 => .bf16,
        .i32, .u32 => null,
    };
}

pub fn appendRejection(
    allocator: std.mem.Allocator,
    rejections: *std.ArrayList(tsir.RejectionEntry),
    reason: tsir.RejectionReason,
    function_index: u32,
    field: []const u8,
    node_index: u32,
    detail_text: []const u8,
) PlannerError!void {
    const path = try std.fmt.allocPrint(
        allocator,
        "functions[{d}].{s}[{d}]",
        .{ function_index, field, node_index },
    );
    const detail = try allocator.dupe(u8, detail_text);
    try rejections.append(allocator, .{
        .reason = reason,
        .node_path = path,
        .detail = detail,
    });
}

fn floorPowerOfTwo(value: u32) u32 {
    var out: u32 = 1;
    while (out <= value / 2) : (out *= 2) {}
    return out;
}

fn divCeil(value: u64, divisor: u32) u64 {
    const d: u64 = @intCast(@max(@as(u32, 1), divisor));
    return (value + d - 1) / d;
}
