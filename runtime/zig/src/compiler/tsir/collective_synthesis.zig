// TSIR Step 6 — collective synthesis pass.
//
// Consumes `SemanticFunction.collectives` (subgroup / barrier / fabric nodes
// declared by the frontend) and emits `CollectiveRealizationNode`s pinned to
// descriptor-declared native capabilities. Fabric colors are assigned in
// source order against the descriptor's fabric-color budget; tree shape is
// currently first-fit linear pending Step 6 numerical-contract work.
//
// Rejections are emitted when:
//   - the collective dtype is not a native numerical mode on the target
//   - the target lacks a native collective of the requested kind/exactness
//   - the target's fabric-color budget is exhausted before the node is
//     assigned a color
//
// This file was carved out of `planner.zig` per
// `docs/tsir-lowering-plan.md §Step 6` — the pass is named, isolated, and
// composable with the Phase-B numerical-contract extensions that this step
// will gain (accumulation dtype, declared reduction tree, NaN/Inf policy).

const std = @import("std");
const targets = @import("../targets/mod.zig");
const tsir = @import("mod.zig");
const planner = @import("planner.zig");

pub const SynthesisError = error{
    OutOfMemory,
};

pub fn synthesize(
    allocator: std.mem.Allocator,
    func: tsir.schema.SemanticFunction,
    function_index: u32,
    descriptor: targets.TargetDescriptor,
    tiles: []const u32,
    rejections: *std.ArrayList(tsir.RejectionEntry),
) SynthesisError![]const tsir.schema.CollectiveRealizationNode {
    var out = std.ArrayList(tsir.schema.CollectiveRealizationNode){};
    defer out.deinit(allocator);

    var next_color: u32 = 0;
    for (func.collectives, 0..) |node, collective_index| {
        if (node.kind != .workgroup_barrier and !planner.supportsNumericalMode(descriptor, node.dtype)) {
            try planner.appendRejection(
                allocator,
                rejections,
                .tsir_target_unfit,
                function_index,
                "collectives",
                @intCast(collective_index),
                "collective dtype is not native on target",
            );
            continue;
        }
        if (!supportsCollective(descriptor, node.kind, node.exactness.class)) {
            try planner.appendRejection(
                allocator,
                rejections,
                .tsir_collective_not_representable,
                function_index,
                "collectives",
                @intCast(collective_index),
                "target lacks native collective exactness",
            );
            continue;
        }

        const color = if (needsFabricColor(node.kind)) blk: {
            if (next_color >= descriptor.correctness.fabric_color_count) {
                try planner.appendRejection(
                    allocator,
                    rejections,
                    .tsir_collective_not_representable,
                    function_index,
                    "collectives",
                    @intCast(collective_index),
                    "target fabric color budget exhausted",
                );
                continue;
            }
            const assigned = next_color;
            next_color += 1;
            break :blk assigned;
        } else null;

        try out.append(allocator, .{
            .semantic_index = @intCast(collective_index),
            .tree_shape = .linear,
            .fabric_color = color,
            .group_size = chooseCollectiveGroupSize(descriptor, node, tiles),
        });
    }

    return out.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn supportsCollective(
    descriptor: targets.TargetDescriptor,
    kind: tsir.schema.CollectiveKind,
    exactness: tsir.ExactnessClass,
) bool {
    const kind_name = @tagName(kind);
    for (descriptor.correctness.native_collectives) |cap| {
        if (std.mem.eql(u8, cap.kind_name, kind_name) and
            collectiveExactnessSatisfies(cap.exactness_name, exactness))
        {
            return true;
        }
    }
    return false;
}

fn collectiveExactnessSatisfies(
    capability_name: []const u8,
    required: tsir.ExactnessClass,
) bool {
    if (std.mem.eql(u8, capability_name, @tagName(required))) return true;
    if (std.mem.eql(u8, capability_name, "bit_exact_solo")) {
        return required == .algorithm_exact or required == .tolerance_bounded;
    }
    return false;
}

fn needsFabricColor(kind: tsir.schema.CollectiveKind) bool {
    return switch (kind) {
        .fabric_reduce,
        .fabric_broadcast,
        .fabric_allreduce,
        => true,
        else => false,
    };
}

fn chooseCollectiveGroupSize(
    descriptor: targets.TargetDescriptor,
    node: tsir.schema.CollectiveSemanticNode,
    tiles: []const u32,
) u32 {
    const max_group = @max(@as(u32, 1), descriptor.correctness.max_collective_group_size);
    if (node.axis >= 0) {
        const axis: usize = @intCast(node.axis);
        if (axis < tiles.len) return @min(max_group, @max(@as(u32, 1), tiles[axis]));
    }
    return max_group;
}
