// doe_compute_ext_native.zig — Compute pass and pipeline extensions for Doe native Metal backend.
// Sharded from doe_wgpu_native.zig: compute pass operations, getBindGroupLayout, dispatchIndirect.

const std = @import("std");
const native_types = @import("doe_native_object_types.zig");
const native_shared = @import("doe_native_shared_types.zig");
const native_cmds = @import("doe_native_command_types.zig");
const native_helpers = @import("doe_native_object_helpers.zig");
const compute_bind_groups = @import("doe_compute_bind_groups.zig");
const compute_preconditions = @import("doe_compute_preconditions_native.zig");
const vulkan_compute = @import("doe_vulkan_compute_native.zig");
const shader_native = @import("doe_shader_native.zig");
const wgsl_compiler = @import("doe_wgsl/mod.zig");
const resource_ops = @import("backend/dropin_resource_ops.zig");
const bridge = resource_ops.metal_bridge;

const alloc = native_helpers.alloc;
const make = native_helpers.make;
const cast = native_helpers.cast;
const toOpaque = native_helpers.toOpaque;
const metal_bridge_buffer_contents = bridge.metal_bridge_buffer_contents;

const DoeComputePipeline = native_types.DoeComputePipeline;
const DoeComputePass = native_types.DoeComputePass;
const DoeBuffer = native_types.DoeBuffer;
const DoeBindGroup = native_types.DoeBindGroup;
const DoeBindGroupLayout = native_types.DoeBindGroupLayout;
const DoeBindGroupLayoutEntry = native_shared.DoeBindGroupLayoutEntry;
const DoePipelineLayout = native_types.DoePipelineLayout;
const DoeShaderModule = native_types.DoeShaderModule;
const RecordedCmd = native_cmds.RecordedCmd;
const MAX_COMPUTE_BIND_GROUPS = compute_bind_groups.MAX_COMPUTE_BIND_GROUPS;
const MAX_FLAT_BIND = compute_bind_groups.MAX_FLAT_BIND;
const MAX_SHADER_BINDINGS = native_shared.MAX_SHADER_BINDINGS;

const RESOURCE_KIND_NONE: u32 = 0;
const RESOURCE_KIND_BUFFER: u32 = 1;
const RESOURCE_KIND_SAMPLER: u32 = 2;
const RESOURCE_KIND_TEXTURE: u32 = 3;
const RESOURCE_KIND_STORAGE_TEXTURE: u32 = 4;

fn validate_dispatch_preconditions(pass: *const DoeComputePass, pip: *const DoeComputePipeline, dispatch: [3]u32) bool {
    compute_preconditions.validate_bind_groups(
        pip.dispatch_preconditions,
        pip.texture_dispatch_preconditions,
        pass.bind_groups[0..],
        dispatch,
        .{ pip.wg_x, pip.wg_y, pip.wg_z },
    ) catch {
        std.log.err("doe_compute_ext_native: dispatch precondition failed for proof-elided shader", .{});
        return false;
    };
    return true;
}

fn read_indirect_dispatch_counts(buffer: *const DoeBuffer, offset: u64) ?[3]u32 {
    if (buffer.error_object) return null;
    const byte_offset: usize = @intCast(offset);
    const counts_bytes = 3 * @sizeOf(u32);
    if (byte_offset + counts_bytes > buffer.size) return null;
    if (buffer.vk_mapped_ptr) |mapped_ptr| {
        const base = mapped_ptr + byte_offset;
        const ints: *align(1) const [3]u32 = @ptrCast(base);
        return ints.*;
    }
    const contents = metal_bridge_buffer_contents(buffer.mtl) orelse return null;
    const base = contents + byte_offset;
    const ints: *align(1) const [3]u32 = @ptrCast(base);
    return ints.*;
}

fn clamped_binding_count(pip: *const DoeComputePipeline) usize {
    const sm = pip.shader_module orelse return 0;
    const count: usize = @intCast(sm.binding_count);
    if (count <= MAX_SHADER_BINDINGS) return count;
    std.log.err("doe_compute_ext_native: invalid shader binding_count={} max={} - clamping", .{ sm.binding_count, MAX_SHADER_BINDINGS });
    return MAX_SHADER_BINDINGS;
}

fn synthesize_layout_entry(binding: native_shared.BindingInfo) DoeBindGroupLayoutEntry {
    var entry = DoeBindGroupLayoutEntry{
        .binding = binding.binding,
        .resource_kind = RESOURCE_KIND_NONE,
    };
    switch (binding.kind) {
        @intFromEnum(wgsl_compiler.BindingKind.buffer) => {
            entry.resource_kind = RESOURCE_KIND_BUFFER;
        },
        @intFromEnum(wgsl_compiler.BindingKind.sampler) => {
            entry.resource_kind = RESOURCE_KIND_SAMPLER;
        },
        @intFromEnum(wgsl_compiler.BindingKind.texture) => {
            entry.resource_kind = RESOURCE_KIND_TEXTURE;
        },
        @intFromEnum(wgsl_compiler.BindingKind.storage_texture) => {
            entry.resource_kind = RESOURCE_KIND_STORAGE_TEXTURE;
            entry.texture_sample_type = binding.access;
        },
        else => {
            std.log.err(
                "doe_compute_ext_native: invalid binding kind={} for binding={} - leaving layout entry empty",
                .{ binding.kind, binding.binding },
            );
        },
    }
    return entry;
}

fn populateRecordedDispatchBindings(
    bind_groups: []const ?*DoeBindGroup,
    bufs: *[MAX_FLAT_BIND]?*anyopaque,
    buf_offsets: *[MAX_FLAT_BIND]u64,
    buf_sizes: *[MAX_FLAT_BIND]u64,
) u32 {
    return compute_bind_groups.populateFlatBindings(bind_groups, bufs, buf_offsets, buf_sizes);
}

fn invalidateLastDispatchCache(pass: *DoeComputePass) void {
    pass.last_dispatch_state_generation = native_types.INVALID_COMPUTE_PASS_STATE_GENERATION;
    pass.last_dispatch_pipeline = null;
}

fn bumpPassState(pass: *DoeComputePass) void {
    pass.state_generation +%= 1;
    if (pass.state_generation == native_types.INVALID_COMPUTE_PASS_STATE_GENERATION) {
        pass.state_generation = native_types.INITIAL_COMPUTE_PASS_STATE_GENERATION;
    }
    invalidateLastDispatchCache(pass);
}

fn setPassPipeline(pass: *DoeComputePass, pip: ?*DoeComputePipeline) void {
    if (pass.pipeline == pip) return;
    pass.pipeline = pip;
    bumpPassState(pass);
}

fn setPassBindGroup(pass: *DoeComputePass, index: usize, bg: ?*DoeBindGroup) void {
    if (index >= pass.bind_groups.len) return;
    if (pass.bind_groups[index] == bg) return;
    pass.bind_groups[index] = bg;
    bumpPassState(pass);
}

fn rememberLastRecordedDispatch(pass: *DoeComputePass, pip: *DoeComputePipeline, x: u32, y: u32, z: u32) void {
    if (pass.enc.cmds.items.len == 0) return;
    pass.last_dispatch_state_generation = pass.state_generation;
    pass.last_dispatch_cmd_index = pass.enc.cmds.items.len - 1;
    pass.last_dispatch_pipeline = pip;
    pass.last_dispatch_x = x;
    pass.last_dispatch_y = y;
    pass.last_dispatch_z = z;
}

fn tryRepeatLastRecordedDispatch(pass: *DoeComputePass, pip: *DoeComputePipeline, x: u32, y: u32, z: u32) bool {
    if (pass.enc.cmds.items.len == 0) return false;
    const last_index = pass.enc.cmds.items.len - 1;
    if (pass.last_dispatch_state_generation != pass.state_generation) return false;
    if (pass.last_dispatch_cmd_index != last_index) return false;
    if (pass.last_dispatch_pipeline != pip) return false;
    if (pass.last_dispatch_x != x or pass.last_dispatch_y != y or pass.last_dispatch_z != z) return false;
    const last = &pass.enc.cmds.items[pass.enc.cmds.items.len - 1];
    switch (last.*) {
        .dispatch => |*dispatch| {
            const repeat_count = if (dispatch.repeat_count == 0) 1 else dispatch.repeat_count;
            dispatch.repeat_count = std.math.add(u32, repeat_count, 1) catch return false;
            return true;
        },
        else => return false,
    }
}

// ============================================================
// Compute Pass operations
// ============================================================

pub export fn doeNativeComputePassSetPipeline(pass_raw: ?*anyopaque, pip_raw: ?*anyopaque) callconv(.c) void {
    const pass = cast(DoeComputePass, pass_raw) orelse return;
    setPassPipeline(pass, cast(DoeComputePipeline, pip_raw));
}

pub export fn doeNativeComputePassSetBindGroup(pass_raw: ?*anyopaque, index: u32, bg_raw: ?*anyopaque, dyn_count: usize, dyn_offsets: ?[*]const u32) callconv(.c) void {
    _ = dyn_count;
    _ = dyn_offsets;
    const pass = cast(DoeComputePass, pass_raw) orelse return;
    if (index < MAX_COMPUTE_BIND_GROUPS) setPassBindGroup(pass, @intCast(index), cast(DoeBindGroup, bg_raw));
}

fn appendRecordedDispatch(pass: *DoeComputePass, pip: *DoeComputePipeline, x: u32, y: u32, z: u32) void {
    if (tryRepeatLastRecordedDispatch(pass, pip, x, y, z)) return;
    if (!validate_dispatch_preconditions(pass, pip, .{ x, y, z })) return;
    var cmd = RecordedCmd{ .dispatch = .{
        .compute_pipeline = toOpaque(pip),
        .pso = pip.mtl_pso,
        .needs_sizes_buf = pip.needs_sizes_buf,
        .bufs = [_]?*anyopaque{null} ** MAX_FLAT_BIND,
        .buf_offsets = [_]u64{0} ** MAX_FLAT_BIND,
        .buf_sizes = [_]u64{0} ** MAX_FLAT_BIND,
        .buf_count = 0,
        .x = x,
        .y = y,
        .z = z,
        .wg_x = pip.wg_x,
        .wg_y = pip.wg_y,
        .wg_z = pip.wg_z,
    } };
    for (pass.bind_groups, 0..) |maybe_bg, index| {
        cmd.dispatch.bind_groups[index] = if (maybe_bg) |bg| toOpaque(bg) else null;
    }
    cmd.dispatch.buf_count = populateRecordedDispatchBindings(
        pass.bind_groups[0..],
        &cmd.dispatch.bufs,
        &cmd.dispatch.buf_offsets,
        &cmd.dispatch.buf_sizes,
    );
    if (pip.spirv_data != null) {
        cmd.dispatch.vulkan_binding_state = vulkan_compute.vulkan_collect_recorded_binding_state(
            pip,
            cmd.dispatch.bufs[0..cmd.dispatch.buf_count],
            cmd.dispatch.buf_offsets[0..cmd.dispatch.buf_count],
            cmd.dispatch.buf_sizes[0..cmd.dispatch.buf_count],
        );
    }
    if (native_cmds.tryMergeDispatchIntoLast(&pass.enc.cmds, &cmd)) {
        rememberLastRecordedDispatch(pass, pip, x, y, z);
        return;
    }
    pass.enc.cmds.append(alloc, cmd) catch
        std.debug.panic("doe_compute_ext_native: OOM recording dispatch command", .{});
    rememberLastRecordedDispatch(pass, pip, x, y, z);
}

pub export fn doeNativeComputePassDispatch(pass_raw: ?*anyopaque, x: u32, y: u32, z: u32) callconv(.c) void {
    const pass = cast(DoeComputePass, pass_raw) orelse return;
    const pip = pass.pipeline orelse return;
    appendRecordedDispatch(pass, pip, x, y, z);
}

pub export fn doeNativeComputePassDispatchBound(
    pass_raw: ?*anyopaque,
    pip_raw: ?*anyopaque,
    bg0_raw: ?*anyopaque,
    x: u32,
    y: u32,
    z: u32,
) callconv(.c) void {
    const pass = cast(DoeComputePass, pass_raw) orelse return;
    const pip = cast(DoeComputePipeline, pip_raw) orelse return;
    setPassPipeline(pass, pip);
    setPassBindGroup(pass, 0, cast(DoeBindGroup, bg0_raw));
    appendRecordedDispatch(pass, pip, x, y, z);
}

pub export fn doeNativeComputePassEnd(raw: ?*anyopaque) callconv(.c) void {
    _ = raw;
}

// ============================================================
// Debug markers — no-ops in headless runtime; symbols required for API surface completeness.
// ============================================================

pub export fn doeNativeComputePassInsertDebugMarker(
    _: ?*anyopaque,
    _: ?[*]const u8,
    _: usize,
) callconv(.c) void {}

pub export fn doeNativeComputePassPushDebugGroup(
    _: ?*anyopaque,
    _: ?[*]const u8,
    _: usize,
) callconv(.c) void {}

pub export fn doeNativeComputePassPopDebugGroup(
    _: ?*anyopaque,
) callconv(.c) void {}

pub export fn doeNativeComputePassRelease(raw: ?*anyopaque) callconv(.c) void {
    if (cast(DoeComputePass, raw)) |p| {
        if (!native_helpers.object_should_destroy(p)) return;
        native_helpers.label_store.remove(raw);
        alloc.destroy(p);
    }
}

// ============================================================
// getBindGroupLayout — returns layout derived from WGSL source metadata.
// ============================================================

pub export fn doeNativeComputePipelineGetBindGroupLayout(pip_raw: ?*anyopaque, group_index: u32) callconv(.c) ?*anyopaque {
    const pip = cast(DoeComputePipeline, pip_raw) orelse return null;
    if (pip.layout) |layout| {
        if (group_index < layout.bind_group_layout_count) {
            const retained = layout.bind_group_layouts[group_index] orelse return null;
            native_helpers.object_add_ref(DoeBindGroupLayout, toOpaque(retained));
            return toOpaque(retained);
        }
    }
    const sm: *DoeShaderModule = pip.shader_module orelse return null;
    shader_native.ensureShaderBindings(sm);
    const binding_count = clamped_binding_count(pip);
    var entry_count: usize = 0;
    for (sm.bindings[0..binding_count]) |b| {
        if (b.group == group_index) entry_count += 1;
    }
    const bgl = make(DoeBindGroupLayout) orelse return null;
    var entries: ?[]DoeBindGroupLayoutEntry = null;
    if (entry_count > 0) {
        entries = alloc.alloc(DoeBindGroupLayoutEntry, entry_count) catch {
            alloc.destroy(bgl);
            return null;
        };
        var write_index: usize = 0;
        for (sm.bindings[0..binding_count]) |binding| {
            if (binding.group != group_index) continue;
            entries.?[write_index] = synthesize_layout_entry(binding);
            write_index += 1;
        }
    }
    bgl.* = .{
        .entry_count = @intCast(entry_count),
        .entries = entries,
    };
    return toOpaque(bgl);
}

// ============================================================
// dispatchWorkgroupsIndirect — indirect dispatch from GPU buffer.
// ============================================================

pub export fn doeNativeComputePassDispatchIndirect(pass_raw: ?*anyopaque, buf_raw: ?*anyopaque, offset: u64) callconv(.c) void {
    const pass = cast(DoeComputePass, pass_raw) orelse return;
    const pip = pass.pipeline orelse return;
    const indirect_buf = cast(DoeBuffer, buf_raw) orelse return;
    if (indirect_buf.error_object) return;
    if (pip.dispatch_preconditions.len > 0) {
        const counts = read_indirect_dispatch_counts(indirect_buf, offset) orelse {
            std.log.err("doe_compute_ext_native: indirect dispatch preconditions require readable counts", .{});
            return;
        };
        if (!validate_dispatch_preconditions(pass, pip, counts)) return;
    }
    var cmd = RecordedCmd{ .dispatch_indirect = .{
        .compute_pipeline = toOpaque(pip),
        .pso = pip.mtl_pso,
        .needs_sizes_buf = pip.needs_sizes_buf,
        .bufs = [_]?*anyopaque{null} ** MAX_FLAT_BIND,
        .buf_offsets = [_]u64{0} ** MAX_FLAT_BIND,
        .buf_sizes = [_]u64{0} ** MAX_FLAT_BIND,
        .buf_count = 0,
        .indirect_buf = toOpaque(indirect_buf),
        .offset = offset,
        .wg_x = pip.wg_x,
        .wg_y = pip.wg_y,
        .wg_z = pip.wg_z,
    } };
    cmd.dispatch_indirect.buf_count = populateRecordedDispatchBindings(
        pass.bind_groups[0..],
        &cmd.dispatch_indirect.bufs,
        &cmd.dispatch_indirect.buf_offsets,
        &cmd.dispatch_indirect.buf_sizes,
    );
    if (pip.spirv_data != null) {
        cmd.dispatch_indirect.vulkan_binding_state = vulkan_compute.vulkan_collect_recorded_binding_state(
            pip,
            cmd.dispatch_indirect.bufs[0..cmd.dispatch_indirect.buf_count],
            cmd.dispatch_indirect.buf_offsets[0..cmd.dispatch_indirect.buf_count],
            cmd.dispatch_indirect.buf_sizes[0..cmd.dispatch_indirect.buf_count],
        );
    }
    pass.enc.cmds.append(alloc, cmd) catch
        std.debug.panic("doe_compute_ext_native: OOM recording indirect dispatch command", .{});
}
