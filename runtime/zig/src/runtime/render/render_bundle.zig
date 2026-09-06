// render_bundle.zig — GPURenderBundle encoder and handle for Doe WebGPU runtime.
//
// A render bundle records a fixed set of render commands (draw calls, pipeline
// binds, bind group binds, vertex/index buffer binds) that can be replayed into
// any compatible render pass with executeBundles.
//
// Commands are stored as a backend-agnostic typed command list. Handle fields
// store opaque pointers that each backend interprets accordingly:
//   - Metal: native Objective-C object pointers (MTLBuffer, MTLRenderPipelineState)
//   - Vulkan: VkBuffer/VkPipeline u64 handles stored via @ptrFromInt
//
// Replay functions are provided per backend:
//   - replay_bundle_metal() — replays into an open MTLRenderCommandEncoder
//   - replay_bundle_vk()    — replays into an active VkCommandBuffer render pass
//
// Compatibility check: the bundle's colorFormats[0] must match the render pass
// attachment format. sampleCount must match. Mismatches fail fast with an
// actionable error rather than a silent misfire.

const std = @import("std");
const leases = @import("../../contracts/resource_lease.zig");
const abi_texture = @import("../../core/abi/wgpu_texture_base_types.zig");
const backend_contract = @import("../../contracts/backend.zig");

// ============================================================
// Constants
// ============================================================

const MAGIC_BUNDLE_ENCODER: u32 = 0xD0E1_0020;
const MAGIC_BUNDLE: u32 = 0xD0E1_0021;

// Maximum commands that can be recorded into a single bundle encoder.
pub const MAX_BUNDLE_CMDS: usize = 4096;

// Maximum vertex buffer slots per draw.
pub const MAX_VTX_BUFS: usize = 8;

// Maximum bind groups per bundle.
pub const MAX_BIND_GROUPS: usize = 4;

// Maximum bindings per bind group.
pub const MAX_BINDINGS_PER_GROUP: usize = 16;

// ============================================================
// Recorded command types
// ============================================================

pub const BundleCmdTag = enum {
    set_pipeline,
    set_bind_group,
    set_vertex_buffer,
    set_index_buffer,
    draw,
    draw_indexed,
    draw_indirect,
    draw_indexed_indirect,
};

pub const BundleBindEntry = struct {
    handle: ?*anyopaque,
    offset: u64,
};

pub const BundleBindGroup = struct {
    entries: [MAX_BINDINGS_PER_GROUP]BundleBindEntry,
    count: u32,
};

pub const BundleCmd = union(BundleCmdTag) {
    set_pipeline: struct {
        pipeline_handle: ?*anyopaque,
        // Retain the owning DoeRenderPipeline separately from the backend
        // handle. Native replay needs pipeline metadata (topology, depth
        // state, root signature), while direct backend replay still consumes
        // pipeline_handle.
        pipeline_object_handle: ?*anyopaque = null,
    },
    set_bind_group: struct {
        group: u32,
        bg_handle: ?*anyopaque = null,
        bg: BundleBindGroup,
    },
    set_vertex_buffer: struct {
        slot: u32,
        buffer_handle: ?*anyopaque,
        offset: u64,
        size: u64,
    },
    set_index_buffer: struct {
        buffer_handle: ?*anyopaque,
        format: u32, // WGPUIndexFormat: 0x1=uint16, 0x2=uint32
        offset: u64,
        size: u64,
    },
    draw: struct {
        vertex_count: u32,
        instance_count: u32,
        first_vertex: u32,
        first_instance: u32,
    },
    draw_indexed: struct {
        index_count: u32,
        instance_count: u32,
        first_index: u32,
        base_vertex: i32,
        first_instance: u32,
    },
    draw_indirect: struct {
        indirect_buffer: ?*anyopaque,
        indirect_offset: u64,
    },
    draw_indexed_indirect: struct {
        indirect_buffer: ?*anyopaque,
        indirect_offset: u64,
    },
};

// ============================================================
// DoeBundleEncoder — records commands until finish()
// ============================================================

pub const DoeBundleEncoder = struct {
    pub const TYPE_MAGIC = MAGIC_BUNDLE_ENCODER;
    magic: u32 = TYPE_MAGIC,
    allocator: std.mem.Allocator,
    ref_count: u32 = 1,
    references: std.ArrayListUnmanaged(leases.ResourceLease) = .{},
    backend: backend_contract.NativeBackendKind = .metal,
    // Compatibility signature — validated against render pass at executeBundles time.
    color_format: abi_texture.WGPUTextureFormat,
    depth_stencil_format: abi_texture.WGPUTextureFormat,
    sample_count: u32,
    depth_read_only: bool,
    stencil_read_only: bool,
    // Recorded commands.
    cmds: std.ArrayListUnmanaged(BundleCmd),
};

// ============================================================
// DoeRenderBundle — immutable after finish()
// ============================================================

pub const DoeRenderBundle = struct {
    pub const TYPE_MAGIC = MAGIC_BUNDLE;
    magic: u32 = TYPE_MAGIC,
    allocator: std.mem.Allocator,
    ref_count: u32 = 1,
    references: std.ArrayListUnmanaged(leases.ResourceLease) = .{},
    backend: backend_contract.NativeBackendKind = .metal,
    color_format: abi_texture.WGPUTextureFormat,
    depth_stencil_format: abi_texture.WGPUTextureFormat,
    sample_count: u32,
    cmds: []BundleCmd, // owned slice
};

// ============================================================
// Bridge functions imported from metal_bridge.m
// ============================================================

extern fn metal_bridge_render_encoder_draw(
    encoder: ?*anyopaque,
    draw_count: u32,
    vertex_count: u32,
    instance_count: u32,
    redundant_pipeline: c_int,
    pipeline: ?*anyopaque,
) callconv(.c) void;

extern fn metal_bridge_render_encoder_set_pipeline(
    encoder: ?*anyopaque,
    pipeline: ?*anyopaque,
) callconv(.c) void;

extern fn metal_bridge_render_encoder_set_buffer(
    encoder: ?*anyopaque,
    buffer: ?*anyopaque,
    offset: u64,
    index: u32,
) callconv(.c) void;

extern fn metal_bridge_render_encoder_draw_indexed_bundle(
    encoder: ?*anyopaque,
    index_buffer: ?*anyopaque,
    index_buffer_offset: u64,
    index_type: u32,
    index_count: u32,
    instance_count: u32,
    first_index: u32,
    base_vertex: i32,
    first_instance: u32,
) callconv(.c) void;

extern fn metal_bridge_render_encoder_draw_indirect(
    encoder: ?*anyopaque,
    indirect_buffer: ?*anyopaque,
    indirect_offset: u64,
) callconv(.c) void;

extern fn metal_bridge_render_encoder_draw_indexed_indirect(
    encoder: ?*anyopaque,
    index_buffer: ?*anyopaque,
    index_buffer_offset: u64,
    index_type: u32,
    indirect_buffer: ?*anyopaque,
    indirect_offset: u64,
) callconv(.c) void;

// ============================================================
// Replay
// ============================================================

pub const ReplayError = error{
    FormatMismatch,
    SampleCountMismatch,
};

// Validate bundle compatibility against a render pass without replaying commands.
pub fn check_compatibility(
    b: *const DoeRenderBundle,
    pass_color_format: abi_texture.WGPUTextureFormat,
    pass_sample_count: u32,
) ReplayError!void {
    if (b.color_format != 0 and b.color_format != pass_color_format) {
        return ReplayError.FormatMismatch;
    }
    if (b.sample_count != 0 and b.sample_count != pass_sample_count) {
        return ReplayError.SampleCountMismatch;
    }
}

// Replay all recorded commands into an already-open MTLRenderCommandEncoder.
// `pass_color_format` and `pass_sample_count` must match the bundle's signature;
// we fail fast rather than silently producing incorrect draws.
// `encoder` must be a valid, open MTLRenderCommandEncoder — never null.
pub fn replay_bundle_metal(
    b: *const DoeRenderBundle,
    encoder: ?*anyopaque,
    pass_color_format: abi_texture.WGPUTextureFormat,
    pass_sample_count: u32,
) ReplayError!void {
    try check_compatibility(b, pass_color_format, pass_sample_count);

    // Track the current index buffer across draw_indexed commands.
    var cur_index_buf: ?*anyopaque = null;
    var cur_index_off: u64 = 0;
    var cur_index_fmt: u32 = 0x2; // default uint32

    for (b.cmds) |cmd| {
        switch (cmd) {
            .set_pipeline => |p| {
                metal_bridge_render_encoder_set_pipeline(encoder, p.pipeline_handle);
            },
            .set_bind_group => |bg_cmd| {
                // Metal buffer indices: group*MAX_BINDINGS_PER_GROUP + binding.
                for (bg_cmd.bg.entries[0..bg_cmd.bg.count]) |entry| {
                    const slot: u32 = bg_cmd.group * MAX_BINDINGS_PER_GROUP;
                    metal_bridge_render_encoder_set_buffer(encoder, entry.handle, entry.offset, slot);
                }
            },
            .set_vertex_buffer => |vb| {
                // Metal vertex buffers start at index 16 (after fragment/vertex uniform slots).
                const metal_slot: u32 = 16 + vb.slot;
                metal_bridge_render_encoder_set_buffer(encoder, vb.buffer_handle, vb.offset, metal_slot);
            },
            .set_index_buffer => |ib| {
                cur_index_buf = ib.buffer_handle;
                cur_index_off = ib.offset;
                cur_index_fmt = ib.format;
            },
            .draw => |d| {
                // Reuse the Metal bridge draw loop (redundant_pipeline=0 here).
                // draw_count=1 because each bundle cmd is a single logical draw call.
                _ = d.first_vertex;
                _ = d.first_instance;
                metal_bridge_render_encoder_draw(encoder, 1, d.vertex_count, d.instance_count, 0, null);
            },
            .draw_indexed => |d| {
                metal_bridge_render_encoder_draw_indexed_bundle(
                    encoder,
                    cur_index_buf,
                    cur_index_off,
                    cur_index_fmt,
                    d.index_count,
                    d.instance_count,
                    d.first_index,
                    d.base_vertex,
                    d.first_instance,
                );
            },
            .draw_indirect => |d| {
                metal_bridge_render_encoder_draw_indirect(
                    encoder,
                    d.indirect_buffer,
                    d.indirect_offset,
                );
            },
            .draw_indexed_indirect => |d| {
                metal_bridge_render_encoder_draw_indexed_indirect(
                    encoder,
                    cur_index_buf,
                    cur_index_off,
                    cur_index_fmt,
                    d.indirect_buffer,
                    d.indirect_offset,
                );
            },
        }
    }
}

// ============================================================
// Vulkan replay
// ============================================================

// Vulkan vkCmd* externs used by replay_bundle_vk. Declared here to avoid
// importing the full Vulkan backend module tree from render_bundle.zig.
const VkCommandBuffer = ?*opaque {};
const VkBuffer = u64;
const VkPipeline = u64;
const VK_PIPELINE_BIND_POINT_GRAPHICS: i32 = 0;
const VK_INDEX_TYPE_UINT16: u32 = 0;
const VK_INDEX_TYPE_UINT32: u32 = 1;

extern fn vkCmdBindPipeline(commandBuffer: VkCommandBuffer, pipelineBindPoint: i32, pipeline: VkPipeline) callconv(.c) void;
extern fn vkCmdBindVertexBuffers(commandBuffer: VkCommandBuffer, firstBinding: u32, bindingCount: u32, pBuffers: [*]const VkBuffer, pOffsets: [*]const u64) callconv(.c) void;
extern fn vkCmdBindIndexBuffer(commandBuffer: VkCommandBuffer, buffer: VkBuffer, offset: u64, indexType: u32) callconv(.c) void;
extern fn vkCmdDraw(commandBuffer: VkCommandBuffer, vertexCount: u32, instanceCount: u32, firstVertex: u32, firstInstance: u32) callconv(.c) void;
extern fn vkCmdDrawIndexed(commandBuffer: VkCommandBuffer, indexCount: u32, instanceCount: u32, firstIndex: u32, vertexOffset: i32, firstInstance: u32) callconv(.c) void;
extern fn vkCmdDrawIndirect(commandBuffer: VkCommandBuffer, buffer: VkBuffer, offset: u64, drawCount: u32, stride: u32) callconv(.c) void;
extern fn vkCmdDrawIndexedIndirect(commandBuffer: VkCommandBuffer, buffer: VkBuffer, offset: u64, drawCount: u32, stride: u32) callconv(.c) void;

// Convert an opaque handle pointer back to a Vulkan u64 handle.
// Vulkan non-dispatchable handles (VkBuffer, VkPipeline) are stored in
// BundleCmd ?*anyopaque fields via @ptrFromInt at recording time; this
// reverses that encoding.
fn opaque_to_vk_handle(ptr: ?*anyopaque) u64 {
    return if (ptr) |p| @intFromPtr(p) else 0;
}

// WGPUIndexFormat (0x1=uint16, 0x2=uint32) to VkIndexType.
fn wgpu_index_format_to_vk(format: u32) u32 {
    return if (format == 0x1) VK_INDEX_TYPE_UINT16 else VK_INDEX_TYPE_UINT32;
}

// Vulkan draw-indirect command stride (matches VkDrawIndirectCommand size).
const VK_DRAW_INDIRECT_STRIDE: u32 = 16;
// Vulkan draw-indexed-indirect command stride (VkDrawIndexedIndirectCommand).
const VK_DRAW_INDEXED_INDIRECT_STRIDE: u32 = 20;

// Replay all recorded commands into an active Vulkan render pass.
// `cmd_buf` must be a VkCommandBuffer with an active render pass (between
// vkCmdBeginRenderPass and vkCmdEndRenderPass). The caller is responsible
// for setting up viewport, scissor, and the initial render pass state.
pub fn replay_bundle_vk(
    b: *const DoeRenderBundle,
    cmd_buf: VkCommandBuffer,
    pass_color_format: abi_texture.WGPUTextureFormat,
    pass_sample_count: u32,
) ReplayError!void {
    try check_compatibility(b, pass_color_format, pass_sample_count);

    var cur_index_buf: VkBuffer = 0;
    var cur_index_off: u64 = 0;
    var cur_index_fmt: u32 = 0x2; // default uint32

    for (b.cmds) |cmd| {
        switch (cmd) {
            .set_pipeline => |p| {
                const vk_pipeline = opaque_to_vk_handle(p.pipeline_handle);
                if (vk_pipeline != 0) {
                    vkCmdBindPipeline(cmd_buf, VK_PIPELINE_BIND_POINT_GRAPHICS, vk_pipeline);
                }
            },
            .set_bind_group => {
                // Vulkan bind groups require descriptor sets which are managed
                // externally. Bundle bind group commands are a no-op for the
                // replay-into-primary path; the caller must ensure descriptor
                // state is bound before executing bundles.
            },
            .set_vertex_buffer => |vb| {
                const vk_buf = opaque_to_vk_handle(vb.buffer_handle);
                if (vk_buf != 0) {
                    const buffers = [1]VkBuffer{vk_buf};
                    const offsets = [1]u64{vb.offset};
                    vkCmdBindVertexBuffers(cmd_buf, vb.slot, 1, &buffers, &offsets);
                }
            },
            .set_index_buffer => |ib| {
                cur_index_buf = opaque_to_vk_handle(ib.buffer_handle);
                cur_index_off = ib.offset;
                cur_index_fmt = ib.format;
                if (cur_index_buf != 0) {
                    vkCmdBindIndexBuffer(cmd_buf, cur_index_buf, cur_index_off, wgpu_index_format_to_vk(cur_index_fmt));
                }
            },
            .draw => |d| {
                vkCmdDraw(cmd_buf, d.vertex_count, d.instance_count, d.first_vertex, d.first_instance);
            },
            .draw_indexed => |d| {
                if (cur_index_buf != 0) {
                    vkCmdDrawIndexed(cmd_buf, d.index_count, d.instance_count, d.first_index, d.base_vertex, d.first_instance);
                }
            },
            .draw_indirect => |d| {
                const vk_buf = opaque_to_vk_handle(d.indirect_buffer);
                if (vk_buf != 0) {
                    vkCmdDrawIndirect(cmd_buf, vk_buf, d.indirect_offset, 1, VK_DRAW_INDIRECT_STRIDE);
                }
            },
            .draw_indexed_indirect => |d| {
                const vk_buf = opaque_to_vk_handle(d.indirect_buffer);
                if (vk_buf != 0 and cur_index_buf != 0) {
                    vkCmdDrawIndexedIndirect(cmd_buf, vk_buf, d.indirect_offset, 1, VK_DRAW_INDEXED_INDIRECT_STRIDE);
                }
            },
        }
    }
}

// ============================================================
// D3D12 replay
// ============================================================

// D3D12 bridge externs used by replay_bundle_d3d12. Declared here to avoid
// importing the full D3D12 backend module tree from render_bundle.zig.
const D3D12Handle = ?*anyopaque;
const DXGI_FORMAT_R16_UINT: u32 = 56;
const DXGI_FORMAT_R32_UINT: u32 = 42;

// D3D12 draw-indirect command stride (matches D3D12_DRAW_ARGUMENTS size: 4x u32).
const D3D12_DRAW_INDIRECT_STRIDE: u32 = 16;
// D3D12 draw-indexed-indirect command stride (D3D12_DRAW_INDEXED_ARGUMENTS: 5x u32).
const D3D12_DRAW_INDEXED_INDIRECT_STRIDE: u32 = 20;

extern fn d3d12_bridge_command_list_set_pipeline_state(cmd_list: D3D12Handle, pipeline: D3D12Handle) callconv(.c) void;
extern fn d3d12_bridge_command_list_ia_set_vertex_buffers(cmd_list: D3D12Handle, start_slot: u32, num_views: u32, buffer: D3D12Handle, size_in_bytes: u32, stride_in_bytes: u32, offset: u64) callconv(.c) void;
extern fn d3d12_bridge_command_list_ia_set_index_buffer(cmd_list: D3D12Handle, buffer: D3D12Handle, format: u32, size_in_bytes: u32, offset: u64) callconv(.c) void;
extern fn d3d12_bridge_command_list_draw_instanced(cmd_list: D3D12Handle, vertex_count: u32, instance_count: u32, start_vertex: u32, start_instance: u32) callconv(.c) void;
extern fn d3d12_bridge_command_list_draw_indexed_instanced(cmd_list: D3D12Handle, index_count: u32, instance_count: u32, start_index: u32, base_vertex: i32, start_instance: u32) callconv(.c) void;
extern fn d3d12_bridge_command_list_execute_indirect(cmd_list: D3D12Handle, command_sig: D3D12Handle, max_count: u32, arg_buffer: D3D12Handle, arg_offset: u64) callconv(.c) void;

// WGPUIndexFormat (0x1=uint16, 0x2=uint32) to DXGI_FORMAT.
fn wgpu_index_format_to_dxgi(format: u32) u32 {
    return if (format == 0x1) DXGI_FORMAT_R16_UINT else DXGI_FORMAT_R32_UINT;
}

// Replay all recorded commands into an active D3D12 command list within a render pass.
// `cmd_list` must be a ID3D12GraphicsCommandList in recording state with a render target
// already set (between resource barrier transitions). The caller is responsible for
// viewport, scissor, topology, and root signature setup.
//
// For indirect draws, `draw_cmd_sig` and `draw_indexed_cmd_sig` are optional command
// signature handles created by the caller. If null, indirect draws are skipped.
pub fn replay_bundle_d3d12(
    b: *const DoeRenderBundle,
    cmd_list: D3D12Handle,
    pass_color_format: abi_texture.WGPUTextureFormat,
    pass_sample_count: u32,
    draw_cmd_sig: D3D12Handle,
    draw_indexed_cmd_sig: D3D12Handle,
) ReplayError!void {
    try check_compatibility(b, pass_color_format, pass_sample_count);

    var cur_index_buf: D3D12Handle = null;
    var cur_index_off: u64 = 0;
    var cur_index_fmt: u32 = 0x2; // default uint32
    var cur_index_size: u64 = 0;

    for (b.cmds) |cmd| {
        switch (cmd) {
            .set_pipeline => |p| {
                if (p.pipeline_handle != null) {
                    d3d12_bridge_command_list_set_pipeline_state(cmd_list, p.pipeline_handle);
                }
            },
            .set_bind_group => {
                // D3D12 bind groups require descriptor tables which are managed
                // externally. Bundle bind group commands are a no-op for the
                // replay-into-primary path; the caller must ensure descriptor
                // state is bound before executing bundles.
            },
            .set_vertex_buffer => |vb| {
                if (vb.buffer_handle != null) {
                    // Size and stride are not tracked in the bundle command; pass 0
                    // to let the bridge use the full buffer. The caller's pipeline
                    // state defines the input layout stride.
                    d3d12_bridge_command_list_ia_set_vertex_buffers(cmd_list, vb.slot, 1, vb.buffer_handle, 0, 0, vb.offset);
                }
            },
            .set_index_buffer => |ib| {
                cur_index_buf = ib.buffer_handle;
                cur_index_off = ib.offset;
                cur_index_fmt = ib.format;
                cur_index_size = ib.size;
                if (cur_index_buf != null) {
                    const dxgi_fmt = wgpu_index_format_to_dxgi(cur_index_fmt);
                    const size_bytes: u32 = if (cur_index_size > 0) @intCast(@min(cur_index_size, std.math.maxInt(u32))) else 0;
                    d3d12_bridge_command_list_ia_set_index_buffer(cmd_list, cur_index_buf, dxgi_fmt, size_bytes, cur_index_off);
                }
            },
            .draw => |d| {
                d3d12_bridge_command_list_draw_instanced(cmd_list, d.vertex_count, d.instance_count, d.first_vertex, d.first_instance);
            },
            .draw_indexed => |d| {
                if (cur_index_buf != null) {
                    d3d12_bridge_command_list_draw_indexed_instanced(cmd_list, d.index_count, d.instance_count, d.first_index, d.base_vertex, d.first_instance);
                }
            },
            .draw_indirect => |d| {
                if (d.indirect_buffer != null and draw_cmd_sig != null) {
                    d3d12_bridge_command_list_execute_indirect(cmd_list, draw_cmd_sig, 1, d.indirect_buffer, d.indirect_offset);
                }
            },
            .draw_indexed_indirect => |d| {
                if (d.indirect_buffer != null and cur_index_buf != null and draw_indexed_cmd_sig != null) {
                    d3d12_bridge_command_list_execute_indirect(cmd_list, draw_indexed_cmd_sig, 1, d.indirect_buffer, d.indirect_offset);
                }
            },
        }
    }
}

// ============================================================
// C ABI helpers (cast / make shared with doe_wgpu_native.zig)
// ============================================================

pub fn make_bundle_encoder(
    a: std.mem.Allocator,
    color_format: abi_texture.WGPUTextureFormat,
    depth_stencil_format: abi_texture.WGPUTextureFormat,
    sample_count: u32,
    depth_read_only: bool,
    stencil_read_only: bool,
) ?*DoeBundleEncoder {
    const enc = a.create(DoeBundleEncoder) catch return null;
    enc.* = .{
        .allocator = a,
        .color_format = color_format,
        .depth_stencil_format = depth_stencil_format,
        .sample_count = if (sample_count == 0) 1 else sample_count,
        .depth_read_only = depth_read_only,
        .stencil_read_only = stencil_read_only,
        .cmds = .{},
    };
    return enc;
}

pub fn bundle_encoder_push(enc: *DoeBundleEncoder, cmd: BundleCmd) void {
    enc.cmds.append(enc.allocator, cmd) catch
        std.debug.panic("render_bundle: OOM recording bundle command", .{});
}

pub fn bundle_encoder_finish(enc: *DoeBundleEncoder) ?*DoeRenderBundle {
    const a = enc.allocator;
    const bundle = a.create(DoeRenderBundle) catch return null;
    const cmds_slice = enc.cmds.toOwnedSlice(a) catch {
        a.destroy(bundle);
        return null;
    };
    bundle.* = .{
        .allocator = a,
        .backend = enc.backend,
        .color_format = enc.color_format,
        .depth_stencil_format = enc.depth_stencil_format,
        .sample_count = enc.sample_count,
        .cmds = cmds_slice,
        .references = enc.references,
    };
    enc.references = .{};
    return bundle;
}

pub fn bundle_destroy(b: *DoeRenderBundle) void {
    if (!leases.releaseCount(&b.ref_count)) return;
    destroyReleasedBundle(b);
}

pub fn destroyReleasedBundle(b: *DoeRenderBundle) void {
    leases.releaseAll(b.allocator, &b.references);
    const a = b.allocator;
    a.free(b.cmds);
    a.destroy(b);
}

pub fn cast_bundle_encoder(p: ?*anyopaque) ?*DoeBundleEncoder {
    const ptr = p orelse return null;
    const result: *DoeBundleEncoder = @ptrCast(@alignCast(ptr));
    if (result.magic != DoeBundleEncoder.TYPE_MAGIC) return null;
    return result;
}

pub fn cast_bundle(p: ?*anyopaque) ?*DoeRenderBundle {
    const ptr = p orelse return null;
    const result: *DoeRenderBundle = @ptrCast(@alignCast(ptr));
    if (result.magic != DoeRenderBundle.TYPE_MAGIC) return null;
    return result;
}
