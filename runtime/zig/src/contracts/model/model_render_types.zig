const transfer = @import("model_texture_value_types.zig");

pub const DEFAULT_RENDER_TARGET_HANDLE: u64 = 0xFFFF_FFFF_FFFF_FFFE;
pub const DEFAULT_RENDER_TARGET_WIDTH: u32 = 64;
pub const DEFAULT_RENDER_TARGET_HEIGHT: u32 = 64;
pub const DEFAULT_RENDER_TARGET_FORMAT: transfer.WGPUTextureFormat = transfer.WGPUTextureFormat_RGBA8Unorm;

pub const RenderDrawPipelineMode = enum {
    static,
    redundant,
};

pub const RenderDrawBindGroupMode = enum {
    no_change,
    redundant,
};

pub const RenderDrawEncodeMode = enum {
    render_pass,
    render_bundle,
};

pub const RenderIndexFormat = enum {
    uint16,
    uint32,
};

pub const MAX_VERTEX_BUFFERS: usize = 8;
pub const MAX_VERTEX_ATTRIBUTES: usize = 16;
pub const MAX_RENDER_BIND_ENTRIES: usize = 16;
pub const RENDER_BINDING_UNSET: u32 = 0xFFFF_FFFF;

pub const WGPUVertexStepMode_Vertex: u32 = 0x00000001;
pub const WGPUVertexStepMode_Instance: u32 = 0x00000002;

pub const RenderVertexAttribute = struct {
    format: u32 = 0,
    offset: u64 = 0,
    shader_location: u32 = 0,
};

pub const RenderVertexBufferLayout = struct {
    array_stride: u64 = 0,
    step_mode: u32 = WGPUVertexStepMode_Vertex,
    attribute_count: u32 = 0,
    attributes: [MAX_VERTEX_ATTRIBUTES]RenderVertexAttribute = [_]RenderVertexAttribute{.{}} ** MAX_VERTEX_ATTRIBUTES,
};

pub const RenderVertexBinding = struct {
    slot: u32 = 0,
    handle: ?*anyopaque = null,
    offset: u64 = 0,
};

pub const RenderIndexBinding = struct {
    handle: ?*anyopaque = null,
    offset: u64 = 0,
    size: u64 = 0,
    format: u32 = 0,
};

pub const RenderIndexData = union(RenderIndexFormat) {
    uint16: []const u16,
    uint32: []const u32,
};

pub const RenderDrawCommand = struct {
    draw_count: u32,
    vertex_count: u32 = 3,
    instance_count: u32 = 1,
    first_vertex: u32 = 0,
    first_instance: u32 = 0,
    index_count: ?u32 = null,
    first_index: u32 = 0,
    base_vertex: i32 = 0,
    index_data: ?RenderIndexData = null,
    target_handle: u64 = DEFAULT_RENDER_TARGET_HANDLE,
    target_view_handle: u64 = 0,
    target_width: u32 = DEFAULT_RENDER_TARGET_WIDTH,
    target_height: u32 = DEFAULT_RENDER_TARGET_HEIGHT,
    target_format: transfer.WGPUTextureFormat = DEFAULT_RENDER_TARGET_FORMAT,
    uses_temporary_render_texture: bool = false,
    temporary_render_texture_min_mip_level: u32 = 0,
    pipeline_mode: RenderDrawPipelineMode = .static,
    bind_group_mode: RenderDrawBindGroupMode = .no_change,
    encode_mode: RenderDrawEncodeMode = .render_bundle,
    viewport_x: f32 = 0,
    viewport_y: f32 = 0,
    viewport_width: ?f32 = null,
    viewport_height: ?f32 = null,
    viewport_min_depth: f32 = 0,
    viewport_max_depth: f32 = 1,
    scissor_x: u32 = 0,
    scissor_y: u32 = 0,
    scissor_width: ?u32 = null,
    scissor_height: ?u32 = null,
    vertex_layout_count: u32 = 0,
    vertex_layouts: ?[]const RenderVertexBufferLayout = null,
    vertex_binding_count: u32 = 0,
    vertex_bindings: ?[]const RenderVertexBinding = null,
    index_binding: ?RenderIndexBinding = null,
    topology: u32 = 0x00000004,
    front_face: u32 = 0x00000001,
    cull_mode: u32 = 0x00000001,
    blend_enabled: bool = false,
    color_operation: u32 = 1,
    color_src_factor: u32 = 2,
    color_dst_factor: u32 = 1,
    alpha_operation: u32 = 1,
    alpha_src_factor: u32 = 2,
    alpha_dst_factor: u32 = 1,
    color_write_mask: u32 = 0xF,
    sample_count: u32 = 1,
    blend_constant: [4]f32 = .{ 0, 0, 0, 0 },
    clear_color: [4]f32 = .{ 0, 0, 0, 1 },
    stencil_reference: u32 = 0,
    occlusion_query_pool: u64 = 0,
    occlusion_query_index: ?u32 = null,
    bind_group_dynamic_offsets: ?[]const u32 = null,
    vertex_buffer_count: u32 = 0,
    vertex_buffer_handles: [8]u64 = [_]u64{0} ** 8,
    vertex_buffer_offsets: [8]u64 = [_]u64{0} ** 8,
    index_buffer_handle: u64 = 0,
    index_buffer_offset: u64 = 0,
    index_format: u32 = 0,
    vertex_buffer_strides: [8]u64 = [_]u64{0} ** 8,
    vertex_step_modes: [8]u32 = [_]u32{0} ** 8,
    vertex_attribute_count: u32 = 0,
    vertex_attribute_formats: [16]u32 = [_]u32{0} ** 16,
    vertex_attribute_offsets: [16]u64 = [_]u64{0} ** 16,
    vertex_attribute_locations: [16]u32 = [_]u32{0} ** 16,
    vertex_attribute_buffer_slots: [16]u32 = [_]u32{0} ** 16,
    depth_stencil_format: transfer.WGPUTextureFormat = transfer.WGPUTextureFormat_Undefined,
    depth_compare: u32 = 0,
    depth_write_enabled: bool = false,
    stencil_front_compare: u32 = 0x00000008,
    stencil_front_fail_op: u32 = 0,
    stencil_front_depth_fail_op: u32 = 0,
    stencil_front_pass_op: u32 = 0,
    stencil_back_compare: u32 = 0x00000008,
    stencil_back_fail_op: u32 = 0,
    stencil_back_depth_fail_op: u32 = 0,
    stencil_back_pass_op: u32 = 0,
    stencil_read_mask: u32 = 0xFFFF_FFFF,
    stencil_write_mask: u32 = 0xFFFF_FFFF,
    depth_bias: i32 = 0,
    depth_bias_slope_scale: f32 = 0,
    depth_bias_clamp: f32 = 0,
    unclipped_depth: bool = false,
    indirect_buffer_handle: u64 = 0,
    indirect_offset: u64 = 0,
    vertex_spirv: ?[]const u32 = null,
    fragment_spirv: ?[]const u32 = null,
    vertex_entry_point: ?[]const u8 = null,
    fragment_entry_point: ?[]const u8 = null,
    bind_texture_count: u32 = 0,
    bind_texture_handles: [MAX_RENDER_BIND_ENTRIES]u64 = [_]u64{0} ** MAX_RENDER_BIND_ENTRIES,
    bind_texture_bindings: [MAX_RENDER_BIND_ENTRIES]u32 = [_]u32{RENDER_BINDING_UNSET} ** MAX_RENDER_BIND_ENTRIES,
    bind_sampler_count: u32 = 0,
    bind_sampler_handles: [MAX_RENDER_BIND_ENTRIES]u64 = [_]u64{0} ** MAX_RENDER_BIND_ENTRIES,
    bind_sampler_bindings: [MAX_RENDER_BIND_ENTRIES]u32 = [_]u32{RENDER_BINDING_UNSET} ** MAX_RENDER_BIND_ENTRIES,
};

pub const DrawIndirectCommand = RenderDrawCommand;
pub const DrawIndexedIndirectCommand = RenderDrawCommand;
pub const RenderPassCommand = RenderDrawCommand;

pub const SamplerCreateCommand = struct {
    handle: u64,
    address_mode_u: u32 = 2,
    address_mode_v: u32 = 2,
    address_mode_w: u32 = 2,
    mag_filter: u32 = 1,
    min_filter: u32 = 1,
    mipmap_filter: u32 = 1,
    lod_min_clamp: f32 = 0,
    lod_max_clamp: f32 = 32,
    compare: u32 = 0,
    max_anisotropy: u16 = 1,
};

pub const SamplerDestroyCommand = struct {
    handle: u64,
};
