//! Prepared render pass and pipeline creation operation contracts.

const std = @import("std");
const identity = @import("identity.zig");

pub const ColorAttachmentDesc = struct {
    texture_view_handle: u64,
    resolve_target_handle: ?u64 = null,
    load_op: enum { load, clear } = .clear,
    store_op: enum { store, discard } = .store,
    clear_color: [4]f32 = [_]f32{ 0, 0, 0, 1 },
};

pub const DepthStencilAttachmentDesc = struct {
    texture_view_handle: u64,
    depth_load_op: enum { load, clear } = .clear,
    depth_store_op: enum { store, discard } = .store,
    depth_clear_value: f32 = 1.0,
};

pub const PreparedRenderPassOperation = struct {
    operation_id: u64,
    color_attachments: []const ColorAttachmentDesc = &.{},
    depth_stencil_attachment: ?DepthStencilAttachmentDesc = null,
    draw_count: u32 = 0,
    vertex_count: u32 = 0,
    instance_count: u32 = 1,
};

pub const PreparedPipelineOperation = struct {
    operation_id: u64,
    program_identity: identity.ProgramIdentity,
    pipeline_type: enum { compute, render },
};
