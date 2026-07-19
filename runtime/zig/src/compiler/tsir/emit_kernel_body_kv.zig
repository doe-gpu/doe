// emit_kernel_body_kv.zig — slot-sharded CSL emit bodies for kv_write
// and kv_read.
//
// The default `.full_per_pe` KV strategy in
// `emit_kernel_body.zig` allocates a full `[max_seq_len * head_dim]f32`
// cache on every PE. At manifest shape (max_seq_len=4096, head_dim=256)
// that is 4 MiB per cache × 2 caches = 8 MiB per PE — the
// `csl_compile_pe_memory_exhausted` failure surfaced in
// `bench/out/r3-1-31b-full-graph-compile-attempt/receipt.json` for
// kv_write and kv_write_shared.
//
// The `.slot_sharded` strategy implemented here partitions the KV
// cache along the position axis: each PE owns
// `slots_per_pe = ceil(max_seq_len / num_pes)` slots of size
// `head_dim`. A write only mutates the cache when the global decode
// `position` falls inside the local stride; the read kernel emits the
// full local slice and the host plan stitches PE outputs into a
// contiguous logical cache.
//
// This module is reached via the dispatch in
// `emit_kernel_body.zig:emitCslKvWrite/Read` when
// `Config.kv_cache_pe_strategy == .slot_sharded`. All callers continue
// to use `tsir_kernel_body.emitWithConfig`; nothing imports this file
// directly.

const std = @import("std");
const schema = @import("schema.zig");
const body = @import("emit_kernel_body.zig");

pub fn emitCslKvWriteSlotSharded(
    writer: anytype,
    func: schema.SemanticFunction,
    config: *const body.Config,
) body.EmitError!void {
    const key_proj = try body.bindingForRole(func, .key_projection);
    const val_proj = try body.bindingForRole(func, .value_projection);
    const key_cache = try body.bindingForRole(func, .key_cache);
    const val_cache = try body.bindingForRole(func, .value_cache);
    const position = try body.bindingForRole(func, .decode_position);
    const elem = key_cache.elem;
    try body.requireSupportedComputeElem(elem);
    try body.requireElem(key_proj, elem);
    try body.requireElem(val_proj, elem);
    try body.requireElem(key_cache, elem);
    try body.requireElem(val_cache, elem);
    try body.requireElem(position, .u32);

    const p = config.var_prefix;
    const ty = body.cslElemName(elem);
    try writeKvHeader(writer, config);
    try writer.writeAll(
        "const local_kv_len: u32 = @as(u32, slots_per_pe) * @as(u32, head_dim);\n",
    );
    try body.writeCslBufferArray(writer, p, key_proj.name, "head_dim", ty);
    try body.writeCslBufferArray(writer, p, val_proj.name, "head_dim", ty);
    try body.writeCslBufferArray(writer, p, key_cache.name, "local_kv_len", ty);
    try body.writeCslBufferArray(writer, p, val_cache.name, "local_kv_len", ty);
    try body.writeCslBufferArray(writer, p, position.name, "1", "u32");
    try body.writeCslBufferPointer(writer, p, key_proj.name, ty);
    try body.writeCslBufferPointer(writer, p, val_proj.name, ty);
    try body.writeCslBufferPointer(writer, p, key_cache.name, ty);
    try body.writeCslBufferPointer(writer, p, val_cache.name, ty);
    try body.writeCslBufferPointer(writer, p, position.name, "u32");
    try writer.writeAll("\n");
    try writer.writeAll("fn compute() void {\n");
    try writer.print(
        "    const global_pos: u32 = {s}{s}[0];\n",
        .{ p, position.name },
    );
    try writer.writeAll(
        "    const owning_pe: u32 = global_pos / @as(u32, slots_per_pe);\n",
    );
    try writer.writeAll("    if (owning_pe == @as(u32, pe_id)) {\n");
    try writer.writeAll(
        "        const local_slot: u32 = global_pos - owning_pe * @as(u32, slots_per_pe);\n",
    );
    try writer.writeAll(
        "        const base: u32 = local_slot * @as(u32, head_dim);\n",
    );
    try writer.writeAll("        for (@range(i16, head_dim)) |d| {\n");
    try writer.writeAll("            const idx = base + @as(u32, d);\n");
    try writer.print(
        "            {s}{s}[idx] = {s}{s}[@as(u32, d)];\n",
        .{ p, key_cache.name, p, key_proj.name },
    );
    try writer.print(
        "            {s}{s}[idx] = {s}{s}[@as(u32, d)];\n",
        .{ p, val_cache.name, p, val_proj.name },
    );
    try writer.writeAll("        }\n");
    try writer.writeAll("    }\n");
    try writer.writeAll("    sys_mod.unblock_cmd_stream();\n");
    try writer.writeAll("}\n\n");
    try writer.writeAll("comptime {\n");
    try body.writeCslExportSymbol(writer, p, key_proj.name);
    try body.writeCslExportSymbol(writer, p, val_proj.name);
    try body.writeCslExportSymbol(writer, p, key_cache.name);
    try body.writeCslExportSymbol(writer, p, val_cache.name);
    try body.writeCslExportSymbol(writer, p, position.name);
    try writer.writeAll("    @export_symbol(compute);\n");
    try writer.writeAll("}\n");
}

pub fn emitCslKvReadSlotSharded(
    writer: anytype,
    func: schema.SemanticFunction,
    config: *const body.Config,
) body.EmitError!void {
    const key_cache = try body.bindingForRole(func, .key_cache);
    const val_cache = try body.bindingForRole(func, .value_cache);
    const key_output = try body.bindingForRole(func, .key_output);
    const val_output = try body.bindingForRole(func, .value_output);
    const elem = key_cache.elem;
    try body.requireSupportedComputeElem(elem);
    try body.requireElem(key_cache, elem);
    try body.requireElem(val_cache, elem);
    try body.requireElem(key_output, elem);
    try body.requireElem(val_output, elem);

    const p = config.var_prefix;
    const ty = body.cslElemName(elem);
    try writeKvHeader(writer, config);
    try writer.writeAll(
        "const local_kv_len: u32 = @as(u32, slots_per_pe) * @as(u32, head_dim);\n",
    );
    // Slot-sharded read: each PE emits its full local slice. The host
    // plan stitches PE outputs into the logical [max_seq_len * head_dim]
    // contiguous cache, so read_start / read_len from the full-per-pe
    // path are not surfaced here. Slicing happens host-side.
    try body.writeCslBufferArray(writer, p, key_cache.name, "local_kv_len", ty);
    try body.writeCslBufferArray(writer, p, val_cache.name, "local_kv_len", ty);
    try body.writeCslBufferArray(writer, p, key_output.name, "local_kv_len", ty);
    try body.writeCslBufferArray(writer, p, val_output.name, "local_kv_len", ty);
    try body.writeCslBufferPointer(writer, p, key_cache.name, ty);
    try body.writeCslBufferPointer(writer, p, val_cache.name, ty);
    try body.writeCslBufferPointer(writer, p, key_output.name, ty);
    try body.writeCslBufferPointer(writer, p, val_output.name, ty);
    try writer.writeAll("\n");
    try writer.writeAll("fn compute() void {\n");
    try writer.writeAll("    for (@range(i16, slots_per_pe)) |slot| {\n");
    try writer.writeAll("        for (@range(i16, head_dim)) |d| {\n");
    try writer.writeAll(
        "            const idx: u32 = @as(u32, slot) * @as(u32, head_dim) + @as(u32, d);\n",
    );
    try writer.print(
        "            {s}{s}[idx] = {s}{s}[idx];\n",
        .{ p, key_output.name, p, key_cache.name },
    );
    try writer.print(
        "            {s}{s}[idx] = {s}{s}[idx];\n",
        .{ p, val_output.name, p, val_cache.name },
    );
    try writer.writeAll("        }\n");
    try writer.writeAll("    }\n");
    try writer.writeAll("    sys_mod.unblock_cmd_stream();\n");
    try writer.writeAll("}\n\n");
    try writer.writeAll("comptime {\n");
    try body.writeCslExportSymbol(writer, p, key_cache.name);
    try body.writeCslExportSymbol(writer, p, val_cache.name);
    try body.writeCslExportSymbol(writer, p, key_output.name);
    try body.writeCslExportSymbol(writer, p, val_output.name);
    try writer.writeAll("    @export_symbol(compute);\n");
    try writer.writeAll("}\n");
}

fn writeKvHeader(writer: anytype, config: *const body.Config) !void {
    try writer.writeAll("param memcpy_params;\n");
    try writer.writeAll("param pe_id: i16;\n");
    try writer.writeAll("param num_pes: i16;\n");
    if (config.head_dim_default) |value| {
        try writer.print("param head_dim: i16 = {d};\n", .{value});
    } else {
        try writer.writeAll("param head_dim: i16;\n");
    }
    if (config.max_seq_len_default) |value| {
        try writer.print("param max_seq_len: i16 = {d};\n", .{value});
    } else {
        try writer.writeAll("param max_seq_len: i16;\n");
    }
    if (config.kv_slots_per_pe_default) |value| {
        try writer.print("param slots_per_pe: i16 = {d};\n", .{value});
    } else {
        try writer.writeAll("param slots_per_pe: i16;\n");
    }
    try writer.writeAll(
        "const sys_mod = @import_module(\"<memcpy/memcpy>\", memcpy_params);\n",
    );
}

test "slot_sharded kv_write emits ownership guard + local_kv_len buffers" {
    const allocator = std.testing.allocator;
    const bindings = [_]schema.BufferBinding{
        .{ .name = "kp", .group = 0, .binding = 0, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
        .{ .name = "vp", .group = 0, .binding = 1, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
        .{ .name = "kc", .group = 0, .binding = 2, .logical_shape = &.{ 0, 0 }, .elem = .f32, .read_write = true },
        .{ .name = "vc", .group = 0, .binding = 3, .logical_shape = &.{ 0, 0 }, .elem = .f32, .read_write = true },
        .{ .name = "position", .group = 0, .binding = 4, .logical_shape = &.{1}, .elem = .u32, .read_write = false },
    };
    const body_bindings = [_]schema.SemanticBodyBinding{
        .{ .binding_index = 0, .role = .key_projection },
        .{ .binding_index = 1, .role = .value_projection },
        .{ .binding_index = 2, .role = .key_cache },
        .{ .binding_index = 3, .role = .value_cache },
        .{ .binding_index = 4, .role = .decode_position },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "d", .lower_bound = "0", .upper_bound = "head_dim", .step = "1" },
    };
    const body_axes = [_]schema.SemanticBodyAxis{
        .{ .axis_index = 0, .role = .hidden },
    };
    const semantic = schema.SemanticFunction{
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
    const config = body.Config{
        .var_prefix = "",
        .head_dim_default = 256,
        .max_seq_len_default = 4096,
        .kv_cache_pe_strategy = .slot_sharded,
        .kv_slots_per_pe_default = 17,
    };
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    try body.emitWithConfig(buf.writer(allocator), semantic, .csl, &config);
    const text = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, text, "param pe_id: i16;") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "param num_pes: i16;") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "param slots_per_pe: i16 = 17;") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "const local_kv_len: u32 = @as(u32, slots_per_pe) * @as(u32, head_dim);") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "var kc: [local_kv_len]f32") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "if (owning_pe == @as(u32, pe_id))") != null);
    // Make sure the full-per-pe kv_cache_len buffer is NOT emitted.
    try std.testing.expect(std.mem.indexOf(u8, text, "[kv_cache_len]f32") == null);
}
