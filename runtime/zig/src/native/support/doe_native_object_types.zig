const std = @import("std");

const model_compute_types = @import("../../contracts/model/model_compute_types.zig");
const model_render_types = @import("../../contracts/model/model_render_types.zig");
const abi_core = @import("../../core/abi/wgpu_core_base_types.zig");
const abi_binding = @import("../../core/abi/wgpu_binding_base_types.zig");
const abi_callback = @import("../../core/abi/wgpu_callback_descriptor_types.zig");
const abi_feature = @import("../../core/abi/wgpu_feature_base_types.zig");
const wgsl_ir = @import("../../compiler/wgsl/ir/ir.zig");
const error_scope = @import("../../runtime/diagnostics/error_scope.zig");
const gpu_timeline = @import("../../runtime/queue/gpu_timeline.zig");
const shared = @import("doe_native_shared_types.zig");
const backend_contract = @import("../../contracts/backend.zig");
const command_types = @import("doe_native_command_types.zig");

const MAGIC_INSTANCE: u32 = 0xD0E1_0001;
const MAGIC_ADAPTER: u32 = 0xD0E1_0002;
const MAGIC_DEVICE: u32 = 0xD0E1_0003;
const MAGIC_QUEUE: u32 = 0xD0E1_0004;
const MAGIC_BUFFER: u32 = 0xD0E1_0005;
const MAGIC_SHADER: u32 = 0xD0E1_0006;
const MAGIC_COMPUTE_PIPE: u32 = 0xD0E1_0007;
const MAGIC_BGL: u32 = 0xD0E1_0008;
const MAGIC_PIPE_LAYOUT: u32 = 0xD0E1_0009;
const MAGIC_BIND_GROUP: u32 = 0xD0E1_000A;
const MAGIC_CMD_ENCODER: u32 = 0xD0E1_000B;
const MAGIC_COMPUTE_PASS: u32 = 0xD0E1_000C;
const MAGIC_CMD_BUFFER: u32 = 0xD0E1_000D;
const MAGIC_TEXTURE: u32 = 0xD0E1_000E;
const MAGIC_TEXTURE_VIEW: u32 = 0xD0E1_000F;
const MAGIC_SAMPLER: u32 = 0xD0E1_0010;
const MAGIC_RENDER_PIPE: u32 = 0xD0E1_0011;
const MAGIC_RENDER_PASS: u32 = 0xD0E1_0012;

pub const INVALID_COMPUTE_PASS_STATE_GENERATION: u64 = 0;
pub const INITIAL_COMPUTE_PASS_STATE_GENERATION: u64 = 1;
pub const UNUSED_PASS_TIMESTAMP_WRITE_INDEX: u32 = std.math.maxInt(u32);

pub const DoeInstance = struct {
    pub const TYPE_MAGIC = MAGIC_INSTANCE;
    magic: u32 = TYPE_MAGIC,
    ref_count: u32 = 1,
};

pub const DoeAdapter = struct {
    pub const TYPE_MAGIC = MAGIC_ADAPTER;
    magic: u32 = TYPE_MAGIC,
    ref_count: u32 = 1,
    instance: ?*DoeInstance = null,
    mtl_device: ?*anyopaque = null,
    backend: backend_contract.NativeBackendKind = .metal,
    vendor_id: u32 = 0,
    device_id: u32 = 0,
    driver_version: u32 = 0,
    device_name: [backend_contract.ADAPTER_DEVICE_NAME_BYTES]u8 = [_]u8{0} ** backend_contract.ADAPTER_DEVICE_NAME_BYTES,
    device_name_len: usize = 0,
};

pub const DoeDevice = struct {
    pub const TYPE_MAGIC = MAGIC_DEVICE;
    magic: u32 = TYPE_MAGIC,
    ref_count: u32 = 1,
    adapter: ?*DoeAdapter = null,
    mtl_device: ?*anyopaque = null,
    mtl_queue: ?*anyopaque = null,
    queue: ?*DoeQueue = null,
    error_scopes: error_scope.ErrorScopeStack = error_scope.ErrorScopeStack.init(),
    device_lost_callback: ?abi_callback.WGPUDeviceLostCallback = null,
    device_lost_userdata1: ?*anyopaque = null,
    device_lost_userdata2: ?*anyopaque = null,
    backend: backend_contract.NativeBackendKind = .metal,
    vk_runtime: ?*anyopaque = null,
    d3d12_runtime: ?*anyopaque = null,
    enabled_features: []abi_feature.WGPUFeatureName = &.{},
};

pub const DoeQueue = struct {
    pub const TYPE_MAGIC = MAGIC_QUEUE;
    magic: u32 = TYPE_MAGIC,
    ref_count: u32 = 1,
    dev: *DoeDevice,
    pending_cmd: ?*anyopaque = null,
    staged_write_cmd: ?*anyopaque = null,
    staged_write_blit: ?*anyopaque = null,
    staged_write_buffer: ?*anyopaque = null,
    staged_write_contents: ?[*]u8 = null,
    staged_write_capacity: usize = 0,
    staged_write_offset: usize = 0,
    staged_write_count: u32 = 0,
    mtl_event: ?*anyopaque = null,
    event_counter: u64 = 0,
    completed_event_counter: u64 = 0,
    gpu_timeline: gpu_timeline.GpuTimeline = gpu_timeline.GpuTimeline.init(null),
    deferred_copies: [command_types.MAX_DEFERRED_COPIES]command_types.DeferredCopy = undefined,
    deferred_copy_count: u32 = 0,
    deferred_releases: [command_types.MAX_DEFERRED_RELEASES]?*anyopaque = undefined,
    deferred_release_count: u32 = 0,
    deferred_resolves: [command_types.MAX_DEFERRED_RESOLVES]command_types.DeferredResolve = undefined,
    deferred_resolve_count: u32 = 0,
};

pub const DoeBuffer = struct {
    pub const TYPE_MAGIC = MAGIC_BUFFER;
    magic: u32 = TYPE_MAGIC,
    ref_count: u32 = 1,
    error_object: bool = false,
    destroyed: bool = false,
    backend: backend_contract.NativeBackendKind = .metal,
    dev: ?*DoeDevice = null,
    device_ref: ?*DoeDevice = null,
    mtl: ?*anyopaque = null,
    metal_private_storage: bool = false,
    metal_mapped_ptr: ?[*]u8 = null,
    size: u64 = 0,
    usage: u64 = 0,
    mapped: bool = false,
    d3d12_heap_type: c_int = 0,
    d3d12_mapped_ptr: ?*anyopaque = null,
    vk_id: u64 = 0,
    vk_runtime_ref: ?*anyopaque = null,
    vk_mapped_ptr: ?[*]u8 = null,
};

pub const DoeShaderModule = struct {
    pub const TYPE_MAGIC = MAGIC_SHADER;
    magic: u32 = TYPE_MAGIC,
    ref_count: u32 = 1,
    mtl_library: ?*anyopaque = null,
    bindings: [shared.MAX_SHADER_BINDINGS]shared.BindingInfo = undefined,
    binding_count: u32 = 0,
    bindings_ready: bool = false,
    bindings_error: ?@import("../../compiler/wgsl/pipeline/diagnostic.zig").TranslateError = null,
    bindings_mutex: std.Thread.Mutex = .{},
    wg_x: u32 = 0,
    wg_y: u32 = 0,
    wg_z: u32 = 0,
    needs_sizes_buf: bool = false,
    dispatch_preconditions: []const wgsl_ir.DispatchPrecondition = &.{},
    texture_dispatch_preconditions: []const wgsl_ir.TextureDispatchPrecondition = &.{},
    spirv_data: ?[]const u32 = null,
    vertex_spirv_data: ?[]const u32 = null,
    fragment_spirv_data: ?[]const u32 = null,
    hlsl_source: ?[]const u8 = null,
    wgsl_source: ?[]const u8 = null,
    compilation_message_kind: shared.CompilationMessageKind = .none,
    compilation_message: ?[]const u8 = null,
    compilation_message_storage: [512]u8 = undefined,
    compilation_message_line: u32 = 0,
    compilation_message_column: u32 = 0,
    mtl_library_borrowed: bool = false,
};

pub const DoeComputePipeline = struct {
    pub const TYPE_MAGIC = MAGIC_COMPUTE_PIPE;
    magic: u32 = TYPE_MAGIC,
    ref_count: u32 = 1,
    mtl_pso: ?*anyopaque = null,
    layout: ?*DoePipelineLayout = null,
    shader_module: ?*DoeShaderModule = null,
    binding_count: u32 = 0,
    wg_x: u32 = 0,
    wg_y: u32 = 0,
    wg_z: u32 = 0,
    needs_sizes_buf: bool = false,
    dispatch_preconditions: []const wgsl_ir.DispatchPrecondition = &.{},
    texture_dispatch_preconditions: []const wgsl_ir.TextureDispatchPrecondition = &.{},
    spirv_data: ?[]const u32 = null,
    vk_spirv_hash: u64 = 0,
    vk_spirv_hash_ready: bool = false,
    vk_static_layout_hash: u64 = 0,
    vk_static_pipeline_hash: u64 = 0,
    vk_static_buffer_binding_mask: u128 = 0,
    vk_static_buffer_binding_count: u32 = 0,
    vk_static_pipeline_hash_ready: bool = false,
    vk_flat_buffer_binding_types: [shared.MAX_FLAT_BIND]u32 = [_]u32{0} ** shared.MAX_FLAT_BIND,
    vk_flat_buffer_binding_types_ready: bool = false,
    vk_prepared_binding_cache_next: u32 = 0,
    vk_prepared_binding_cache_keys: [shared.VULKAN_PREPARED_BINDING_CACHE_CAPACITY]u64 = [_]u64{0} ** shared.VULKAN_PREPARED_BINDING_CACHE_CAPACITY,
    vk_prepared_binding_cache_counts: [shared.VULKAN_PREPARED_BINDING_CACHE_CAPACITY]u32 = [_]u32{0} ** shared.VULKAN_PREPARED_BINDING_CACHE_CAPACITY,
    vk_prepared_binding_cache_flat_masks: [shared.VULKAN_PREPARED_BINDING_CACHE_CAPACITY]u128 = [_]u128{0} ** shared.VULKAN_PREPARED_BINDING_CACHE_CAPACITY,
    vk_prepared_binding_cache_descriptor_hashes: [shared.VULKAN_PREPARED_BINDING_CACHE_CAPACITY]u64 = [_]u64{0} ** shared.VULKAN_PREPARED_BINDING_CACHE_CAPACITY,
    vk_prepared_binding_cache_bind_groups: [shared.VULKAN_PREPARED_BINDING_CACHE_CAPACITY][shared.MAX_COMPUTE_BIND_GROUPS]?*DoeBindGroup =
        [_][shared.MAX_COMPUTE_BIND_GROUPS]?*DoeBindGroup{[_]?*DoeBindGroup{null} ** shared.MAX_COMPUTE_BIND_GROUPS} ** shared.VULKAN_PREPARED_BINDING_CACHE_CAPACITY,
    vk_prepared_binding_cache_bindings: [shared.VULKAN_PREPARED_BINDING_CACHE_CAPACITY][shared.MAX_FLAT_BIND]model_compute_types.KernelBinding = undefined,
    /// Entry point name captured from the createComputePipeline
    /// descriptor. Owned (heap-allocated, null-terminated) so it
    /// survives the descriptor struct's lifetime. Consumed at submit
    /// time by vulkan_submit_recorded_dispatch when the dispatch
    /// hasn't overridden the entry point. Previously the Vulkan
    /// pipeline path dropped this field and the runtime defaulted to
    /// "main", which broke any kernel whose SPIR-V OpEntryPoint name
    /// was not "main" (e.g. the Q4K vec4 variant's `main_vec4`).
    /// Freed in `vulkan_release_compute_pipeline`.
    vk_entry_point_owned: ?[:0]u8 = null,
};

pub const DoeBindGroupLayout = struct {
    pub const TYPE_MAGIC = MAGIC_BGL;
    magic: u32 = TYPE_MAGIC,
    ref_count: u32 = 1,
    entry_count: u32 = 0,
    entries: ?[]shared.DoeBindGroupLayoutEntry = null,
    inline_entries: [4]shared.DoeBindGroupLayoutEntry = undefined,
    entries_inline: bool = false,
};

pub const DoePipelineLayout = struct {
    pub const TYPE_MAGIC = MAGIC_PIPE_LAYOUT;
    magic: u32 = TYPE_MAGIC,
    ref_count: u32 = 1,
    immediate_size: u32 = 0,
    bind_group_layout_count: u32 = 0,
    bind_group_layouts: [shared.MAX_COMPUTE_BIND_GROUPS]?*DoeBindGroupLayout = [_]?*DoeBindGroupLayout{null} ** shared.MAX_COMPUTE_BIND_GROUPS,
};

pub const DoeBindGroup = struct {
    pub const TYPE_MAGIC = MAGIC_BIND_GROUP;
    magic: u32 = TYPE_MAGIC,
    ref_count: u32 = 1,
    buffers: [shared.MAX_BIND]?*anyopaque = [_]?*anyopaque{null} ** shared.MAX_BIND,
    textures: [shared.MAX_BIND]?*anyopaque = [_]?*anyopaque{null} ** shared.MAX_BIND,
    texture_views: [shared.MAX_BIND]?*anyopaque = [_]?*anyopaque{null} ** shared.MAX_BIND,
    resource_kinds: [shared.MAX_BIND]u32 = [_]u32{0} ** shared.MAX_BIND,
    samplers: [shared.MAX_BIND]?*anyopaque = [_]?*anyopaque{null} ** shared.MAX_BIND,
    render_texture_view_count: u32 = 0,
    render_texture_views: [model_render_types.MAX_RENDER_BIND_ENTRIES]?*DoeTextureView =
        [_]?*DoeTextureView{null} ** model_render_types.MAX_RENDER_BIND_ENTRIES,
    render_texture_bindings: [model_render_types.MAX_RENDER_BIND_ENTRIES]u32 =
        [_]u32{model_render_types.RENDER_BINDING_UNSET} ** model_render_types.MAX_RENDER_BIND_ENTRIES,
    render_texture_resource_kinds: [model_render_types.MAX_RENDER_BIND_ENTRIES]u32 =
        [_]u32{0} ** model_render_types.MAX_RENDER_BIND_ENTRIES,
    render_sampler_count: u32 = 0,
    render_samplers: [model_render_types.MAX_RENDER_BIND_ENTRIES]?*DoeSampler =
        [_]?*DoeSampler{null} ** model_render_types.MAX_RENDER_BIND_ENTRIES,
    render_sampler_bindings: [model_render_types.MAX_RENDER_BIND_ENTRIES]u32 =
        [_]u32{model_render_types.RENDER_BINDING_UNSET} ** model_render_types.MAX_RENDER_BIND_ENTRIES,
    retained_buffers: [shared.MAX_BIND]?*DoeBuffer = [_]?*DoeBuffer{null} ** shared.MAX_BIND,
    retained_texture_views: [shared.MAX_BIND]?*DoeTextureView = [_]?*DoeTextureView{null} ** shared.MAX_BIND,
    retained_samplers: [shared.MAX_BIND]?*DoeSampler = [_]?*DoeSampler{null} ** shared.MAX_BIND,
    retained_external_textures: [shared.MAX_BIND]abi_core.WGPUExternalTexture = [_]abi_core.WGPUExternalTexture{null} ** shared.MAX_BIND,
    offsets: [shared.MAX_BIND]u64 = [_]u64{0} ** shared.MAX_BIND,
    buffer_sizes: [shared.MAX_BIND]u64 = [_]u64{0} ** shared.MAX_BIND,
    vk_buffer_handles: [shared.MAX_BIND]u64 = [_]u64{0} ** shared.MAX_BIND,
    vk_buffer_binding_types: [shared.MAX_BIND]u32 =
        [_]u32{abi_binding.WGPUBufferBindingType_Undefined} ** shared.MAX_BIND,
    vk_buffer_binding_mask: u64 = 0,
    vk_buffer_binding_cache_complete: bool = false,
    count: u32 = 0,
};

pub const DoeCommandEncoder = struct {
    pub const TYPE_MAGIC = MAGIC_CMD_ENCODER;
    magic: u32 = TYPE_MAGIC,
    ref_count: u32 = 1,
    dev: *DoeDevice,
    device_ref: ?*DoeDevice = null,
    cmds: std.ArrayListUnmanaged(command_types.RecordedCmd) = .{},
    references: std.ArrayListUnmanaged(command_types.CommandReference) = .{},
};

pub const DoeComputePass = struct {
    pub const TYPE_MAGIC = MAGIC_COMPUTE_PASS;
    magic: u32 = TYPE_MAGIC,
    ref_count: u32 = 1,
    enc: *DoeCommandEncoder,
    owns_encoder: bool = false,
    pipeline: ?*DoeComputePipeline = null,
    bind_groups: [4]?*DoeBindGroup = [_]?*DoeBindGroup{null} ** 4,
    state_generation: u64 = INITIAL_COMPUTE_PASS_STATE_GENERATION,
    last_dispatch_state_generation: u64 = INVALID_COMPUTE_PASS_STATE_GENERATION,
    last_dispatch_cmd_index: usize = 0,
    last_dispatch_pipeline: ?*DoeComputePipeline = null,
    last_dispatch_x: u32 = 0,
    last_dispatch_y: u32 = 0,
    last_dispatch_z: u32 = 0,
    timestamp_end_query_set: ?*anyopaque = null,
    timestamp_end_write_index: u32 = UNUSED_PASS_TIMESTAMP_WRITE_INDEX,
};

pub const DoeCommandBuffer = struct {
    pub const TYPE_MAGIC = MAGIC_CMD_BUFFER;
    magic: u32 = TYPE_MAGIC,
    ref_count: u32 = 1,
    dev: *DoeDevice,
    device_ref: ?*DoeDevice = null,
    cmds: std.ArrayListUnmanaged(command_types.RecordedCmd) = .{},
    references: std.ArrayListUnmanaged(command_types.CommandReference) = .{},
};

pub const DoeTexture = struct {
    pub const TYPE_MAGIC = MAGIC_TEXTURE;
    magic: u32 = TYPE_MAGIC,
    ref_count: u32 = 1,
    device_ref: ?*DoeDevice = null,
    error_object: bool = false,
    backend: backend_contract.NativeBackendKind = .metal,
    mtl: ?*anyopaque = null,
    format: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    depth_or_array_layers: u32 = 1,
    dimension: u32 = 0,
    mip_level_count: u32 = 1,
    sample_count: u32 = 1,
    usage: u64 = 0,
    texture_binding_view_dimension: u32 = 0,
    view_format_count: usize = 0,
    vk_id: u64 = 0,
    vk_runtime_ref: ?*anyopaque = null,
};

pub const DoeTextureView = struct {
    pub const TYPE_MAGIC = MAGIC_TEXTURE_VIEW;
    magic: u32 = TYPE_MAGIC,
    ref_count: u32 = 1,
    backend: backend_contract.NativeBackendKind = .metal,
    tex: *DoeTexture,
    handle: ?*anyopaque = null,
    format: u32 = 0,
    dimension: u32 = 0,
    base_mip_level: u32 = 0,
    mip_level_count: u32 = 0,
    base_array_layer: u32 = 0,
    array_layer_count: u32 = 0,
    aspect: u32 = 0,
    usage: u64 = 0,
};

pub const DoeSampler = struct {
    pub const TYPE_MAGIC = MAGIC_SAMPLER;
    magic: u32 = TYPE_MAGIC,
    ref_count: u32 = 1,
    device_ref: ?*DoeDevice = null,
    backend: backend_contract.NativeBackendKind = .metal,
    mtl: ?*anyopaque = null,
    vk_runtime_ref: ?*anyopaque = null,
};

pub const DoeRenderPipeline = struct {
    pub const TYPE_MAGIC = MAGIC_RENDER_PIPE;
    magic: u32 = TYPE_MAGIC,
    ref_count: u32 = 1,
    mtl_pso: ?*anyopaque = null,
    backend_root_signature: ?*anyopaque = null,
    layout: ?*DoePipelineLayout = null,
    vertex_layout_count: u32 = 0,
    vertex_layouts: [model_render_types.MAX_VERTEX_BUFFERS]model_render_types.RenderVertexBufferLayout = [_]model_render_types.RenderVertexBufferLayout{.{}} ** model_render_types.MAX_VERTEX_BUFFERS,
    depth_state: ?*anyopaque = null,
    topology: u32 = 0x00000004,
    front_face: u32 = 0x00000001,
    cull_mode: u32 = 0x00000001,
    depth_stencil_format: u32 = 0,
    depth_compare: u32 = 0,
    depth_write_enabled: bool = false,
    unclipped_depth: bool = false,
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
    blend_enabled: bool = false,
    color_operation: u32 = 0,
    color_src_factor: u32 = 0,
    color_dst_factor: u32 = 0,
    alpha_operation: u32 = 0,
    alpha_src_factor: u32 = 0,
    alpha_dst_factor: u32 = 0,
    color_write_mask: u32 = 0xF,
    sample_count: u32 = 1,
    vertex_buffer_count: u32 = 0,
    vertex_buffer_strides: [shared.MAX_VERTEX_BUFFERS]u64 = [_]u64{0} ** shared.MAX_VERTEX_BUFFERS,
    vertex_step_modes: [shared.MAX_VERTEX_BUFFERS]u32 = [_]u32{0} ** shared.MAX_VERTEX_BUFFERS,
    vertex_attribute_count: u32 = 0,
    vertex_attribute_formats: [shared.MAX_VERTEX_ATTRIBUTES]u32 = [_]u32{0} ** shared.MAX_VERTEX_ATTRIBUTES,
    vertex_attribute_offsets: [shared.MAX_VERTEX_ATTRIBUTES]u64 = [_]u64{0} ** shared.MAX_VERTEX_ATTRIBUTES,
    vertex_attribute_locations: [shared.MAX_VERTEX_ATTRIBUTES]u32 = [_]u32{0} ** shared.MAX_VERTEX_ATTRIBUTES,
    vertex_attribute_buffer_slots: [shared.MAX_VERTEX_ATTRIBUTES]u32 = [_]u32{0} ** shared.MAX_VERTEX_ATTRIBUTES,
    vertex_spirv_data: ?[]const u32 = null,
    fragment_spirv_data: ?[]const u32 = null,
    vertex_wgsl_sha256: [32]u8 = [_]u8{0} ** 32,
    fragment_wgsl_sha256: [32]u8 = [_]u8{0} ** 32,
    vertex_wgsl_sha256_ready: bool = false,
    fragment_wgsl_sha256_ready: bool = false,
    vertex_entry_point: ?[]const u8 = null,
    fragment_entry_point: ?[]const u8 = null,
};

pub const DoeRenderPass = struct {
    pub const TYPE_MAGIC = MAGIC_RENDER_PASS;
    magic: u32 = TYPE_MAGIC,
    ref_count: u32 = 1,
    enc: *DoeCommandEncoder,
    pipeline: ?*DoeRenderPipeline = null,
    max_draw_count: u64 = 50_000_000,
    recorded_draw_count: u64 = 0,
    recorded_command_start: usize = 0,
    target: ?*anyopaque = null,
    resolve_target: ?*anyopaque = null,
    depth_target: ?*anyopaque = null,
    target_view_handle: u64 = 0,
    resolve_target_view_handle: u64 = 0,
    depth_target_view_handle: u64 = 0,
    target_format: u32 = 0,
    depth_stencil_format: u32 = 0,
    sample_count: u32 = 1,
    depth_slice: u32 = 0,
    depth_read_only: bool = false,
    stencil_read_only: bool = false,
    color_load_op: u32 = 0,
    color_store_op: u32 = 0,
    depth_load_op: u32 = 0,
    depth_store_op: u32 = 0,
    stencil_load_op: u32 = 0,
    stencil_store_op: u32 = 0,
    depth_clear_value: f32 = 1,
    stencil_clear_value: u32 = 0,
    depth_compare: u32 = 0,
    depth_write_enabled: bool = false,
    clear_r: f64 = 0,
    clear_g: f64 = 0,
    clear_b: f64 = 0,
    clear_a: f64 = 1,
    bind_groups: [shared.MAX_RENDER_BIND_GROUPS]?*DoeBindGroup = [_]?*DoeBindGroup{null} ** shared.MAX_RENDER_BIND_GROUPS,
    vertex_buffers: [shared.MAX_VERTEX_BUFFERS]?*DoeBuffer = [_]?*DoeBuffer{null} ** shared.MAX_VERTEX_BUFFERS,
    vertex_buffer_offsets: [shared.MAX_VERTEX_BUFFERS]u64 = [_]u64{0} ** shared.MAX_VERTEX_BUFFERS,
    vertex_buffer_sizes: [shared.MAX_VERTEX_BUFFERS]u64 = [_]u64{0} ** shared.MAX_VERTEX_BUFFERS,
    index_buffer: ?*DoeBuffer = null,
    index_offset: u64 = 0,
    index_format: u32 = 0,
    index_buffer_size: u64 = 0,
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
    blend_constant: [4]f32 = .{ 0, 0, 0, 0 },
    stencil_reference: u32 = 0,
    occlusion_query_set: ?*anyopaque = null,
    occlusion_query_active: bool = false,
    occlusion_query_index: u32 = 0,
};
