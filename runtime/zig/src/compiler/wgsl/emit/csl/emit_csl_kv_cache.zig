// emit_csl_kv_cache.zig — CSL PE programs for KV cache read/write.
//
// KV write: appends projected K/V vectors to the cache at the current
// decode position. Each PE holds a chunk of the head dimension.
//
// KV read: reads a slice of cached K/V for a range of positions.
// Each PE outputs its local chunk. No fabric needed for either.

const std = @import("std");
const ir = @import("../../ir/ir.zig");
const classify = @import("emit_csl_classify.zig");
const W = @import("emit_csl_ir_walk.zig");
const tsir_kernel_body = @import("../../../tsir/emit_kernel_body.zig");
const tsir_schema = @import("../../../tsir/schema.zig");

pub const EmitError = W.EmitError;

pub fn emitWrite(
    buf: []u8,
    pos: *usize,
    module: *const ir.Module,
    info: classify.KvWriteInfo,
) EmitError!void {
    // Delegate to TSIR. The WGSL globals dictate the symbol names the
    // host plan binds (kp / vp / kc / vc); decode_position is a runtime
    // state buffer always exported under the literal symbol "position".
    // TSIR's `kv_write` body matches the prior hand-written control
    // flow; the live wrapper just plumbs the WGSL-derived names into
    // the SemanticFunction and asks TSIR to emit with no `tsir_` var
    // prefix.
    const kp = module.globals.items[info.key_proj_global].name;
    const vp = module.globals.items[info.val_proj_global].name;
    const kc = module.globals.items[info.key_cache_global].name;
    const vc = module.globals.items[info.val_cache_global].name;

    const axes = [_]tsir_schema.IterationAxis{
        .{ .name = "d", .lower_bound = "0", .upper_bound = "head_dim", .step = "1" },
    };
    const bindings = [_]tsir_schema.BufferBinding{
        .{ .name = kp, .group = 0, .binding = 0, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
        .{ .name = vp, .group = 0, .binding = 1, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
        .{ .name = kc, .group = 0, .binding = 2, .logical_shape = &.{ 0, 0 }, .elem = .f32, .read_write = true },
        .{ .name = vc, .group = 0, .binding = 3, .logical_shape = &.{ 0, 0 }, .elem = .f32, .read_write = true },
        .{ .name = "position", .group = 0, .binding = 4, .logical_shape = &.{1}, .elem = .u32, .read_write = false },
    };
    const body_bindings = [_]tsir_schema.SemanticBodyBinding{
        .{ .binding_index = 0, .role = .key_projection },
        .{ .binding_index = 1, .role = .value_projection },
        .{ .binding_index = 2, .role = .key_cache },
        .{ .binding_index = 3, .role = .value_cache },
        .{ .binding_index = 4, .role = .decode_position },
    };
    const body_axes = [_]tsir_schema.SemanticBodyAxis{
        .{ .axis_index = 0, .role = .hidden },
    };
    const semantic = tsir_schema.SemanticFunction{
        .name = "main",
        .family_hint = .elementwise,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &.{},
        .collectives = &.{},
        .body = .{
            .op = .kv_write,
            .binding_roles = &body_bindings,
            .axis_roles = &body_axes,
        },
        .source_digest = [_]u8{0} ** 32,
    };
    const config = tsir_kernel_body.Config{
        .var_prefix = "",
        .head_dim_default = 256,
        .max_seq_len_default = 4096,
        // Slot-sharded residency strategy at manifest shape: each PE
        // owns ceil(max_seq_len / num_pes) position slots and allocates
        // [slots_per_pe * head_dim]f32 per cache. The full-per-pe
        // alternative requires [max_seq_len * head_dim]f32 = 4 MiB per
        // cache at manifest shape, which exceeds the WSE-3 per-PE
        // memory budget. Layout-side `pe_id` / `num_pes` /
        // `slots_per_pe` plumbing lives in
        // `runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_layout.zig:emitKvWriteLayout`.
        .kv_cache_pe_strategy = .slot_sharded,
    };
    var fixed: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fixed);
    var sink = std.ArrayList(u8){};
    defer sink.deinit(fba.allocator());
    tsir_kernel_body.emitWithConfig(sink.writer(fba.allocator()), semantic, .csl, &config) catch |err| switch (err) {
        error.OutOfMemory => return error.OutputTooLarge,
        error.InvalidBodyContract,
        error.MissingBindingRole,
        error.UnsupportedKernelBody,
        error.UnsupportedScalarKind,
        => return error.InvalidIr,
    };
    try W.write(buf, pos, sink.items);
}

pub fn emitRead(
    buf: []u8,
    pos: *usize,
    module: *const ir.Module,
    info: classify.KvReadInfo,
) EmitError!void {
    // Symmetric to emitWrite — delegate to TSIR using the WGSL-derived
    // storage names. No `position` state buffer for the read side; the
    // `read_start` / `read_len` params come from the host plan.
    const kc = module.globals.items[info.key_cache_global].name;
    const vc = module.globals.items[info.val_cache_global].name;
    const ko = module.globals.items[info.key_out_global].name;
    const vo = module.globals.items[info.val_out_global].name;

    const axes = [_]tsir_schema.IterationAxis{
        .{ .name = "i", .lower_bound = "0", .upper_bound = "read_len", .step = "1" },
        .{ .name = "d", .lower_bound = "0", .upper_bound = "head_dim", .step = "1" },
    };
    const bindings = [_]tsir_schema.BufferBinding{
        .{ .name = kc, .group = 0, .binding = 0, .logical_shape = &.{ 0, 0 }, .elem = .f32, .read_write = false },
        .{ .name = vc, .group = 0, .binding = 1, .logical_shape = &.{ 0, 0 }, .elem = .f32, .read_write = false },
        .{ .name = ko, .group = 0, .binding = 2, .logical_shape = &.{ 0, 0 }, .elem = .f32, .read_write = true },
        .{ .name = vo, .group = 0, .binding = 3, .logical_shape = &.{ 0, 0 }, .elem = .f32, .read_write = true },
    };
    const body_bindings = [_]tsir_schema.SemanticBodyBinding{
        .{ .binding_index = 0, .role = .key_cache },
        .{ .binding_index = 1, .role = .value_cache },
        .{ .binding_index = 2, .role = .key_output },
        .{ .binding_index = 3, .role = .value_output },
    };
    const body_axes = [_]tsir_schema.SemanticBodyAxis{
        .{ .axis_index = 0, .role = .token },
        .{ .axis_index = 1, .role = .hidden },
    };
    const semantic = tsir_schema.SemanticFunction{
        .name = "main",
        .family_hint = .gather,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &.{},
        .collectives = &.{},
        .body = .{
            .op = .kv_read,
            .binding_roles = &body_bindings,
            .axis_roles = &body_axes,
        },
        .source_digest = [_]u8{0} ** 32,
    };
    const config = tsir_kernel_body.Config{
        .var_prefix = "",
        .head_dim_default = 256,
        .max_seq_len_default = 4096,
        .read_len_default = 1,
        // Symmetric slot-sharded read so the cache layout matches the
        // write side; see emitWrite above.
        .kv_cache_pe_strategy = .slot_sharded,
    };
    var fixed: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fixed);
    var sink = std.ArrayList(u8){};
    defer sink.deinit(fba.allocator());
    tsir_kernel_body.emitWithConfig(sink.writer(fba.allocator()), semantic, .csl, &config) catch |err| switch (err) {
        error.OutOfMemory => return error.OutputTooLarge,
        error.InvalidBodyContract,
        error.MissingBindingRole,
        error.UnsupportedKernelBody,
        error.UnsupportedScalarKind,
        => return error.InvalidIr,
    };
    try W.write(buf, pos, sink.items);
}
