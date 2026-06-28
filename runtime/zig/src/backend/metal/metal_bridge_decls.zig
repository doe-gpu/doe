pub extern fn metal_bridge_create_default_device() callconv(.c) ?*anyopaque;
pub extern fn metal_bridge_retain(obj: ?*anyopaque) callconv(.c) ?*anyopaque;
pub extern fn metal_bridge_release(obj: ?*anyopaque) callconv(.c) void;
pub extern fn metal_bridge_device_new_command_queue(device: ?*anyopaque) callconv(.c) ?*anyopaque;
pub extern fn metal_bridge_device_new_buffer_shared(device: ?*anyopaque, length: usize) callconv(.c) ?*anyopaque;
pub extern fn metal_bridge_device_new_buffer_private(device: ?*anyopaque, length: usize) callconv(.c) ?*anyopaque;
pub extern fn metal_bridge_buffer_contents(buffer: ?*anyopaque) callconv(.c) ?[*]u8;
pub extern fn metal_bridge_encode_blit_copy(queue: ?*anyopaque, src: ?*anyopaque, dst: ?*anyopaque, length: usize) callconv(.c) ?*anyopaque;
pub extern fn metal_bridge_encode_blit_batch(queue: ?*anyopaque, srcs: ?[*]?*anyopaque, dsts: ?[*]?*anyopaque, lengths: ?[*]usize, count: u32) callconv(.c) ?*anyopaque;
pub extern fn metal_bridge_begin_blit_encoding(queue: ?*anyopaque, encoder_out: *?*anyopaque) callconv(.c) ?*anyopaque;
pub extern fn metal_bridge_blit_encoder_copy(encoder: ?*anyopaque, src: ?*anyopaque, dst: ?*anyopaque, byte_count: usize) callconv(.c) void;
pub extern fn metal_bridge_create_command_buffer(queue: ?*anyopaque) callconv(.c) ?*anyopaque;
pub extern fn metal_bridge_cmd_buf_blit_encoder(cmd_buf: ?*anyopaque) callconv(.c) ?*anyopaque;
pub extern fn metal_bridge_cmd_buf_compute_encoder(cmd_buf: ?*anyopaque) callconv(.c) ?*anyopaque;
pub extern fn metal_bridge_end_blit_encoding(encoder: ?*anyopaque) callconv(.c) void;
pub extern fn metal_bridge_end_compute_encoding(encoder: ?*anyopaque) callconv(.c) void;
pub extern fn metal_bridge_command_buffer_commit(cmd_buf: ?*anyopaque) callconv(.c) void;
pub extern fn metal_bridge_command_buffer_wait_completed(cmd_buf: ?*anyopaque) callconv(.c) void;
pub extern fn metal_bridge_command_buffer_spin_wait(cmd_buf: ?*anyopaque) callconv(.c) void;
pub extern fn metal_bridge_command_buffer_setup_fast_wait(cmd_buf: ?*anyopaque) callconv(.c) void;
pub extern fn metal_bridge_command_buffer_wait_fast() callconv(.c) void;
pub extern fn metal_bridge_cmd_buf_encode_render_pass(cmd_buf: ?*anyopaque, pipeline: ?*anyopaque, target: ?*anyopaque, draw_count: u32, vertex_count: u32, instance_count: u32, redundant_pipeline: c_int, redundant_bindgroup: c_int) callconv(.c) void;
pub extern fn metal_bridge_cmd_buf_encode_icb_render_pass(cmd_buf: ?*anyopaque, pipeline: ?*anyopaque, icb: ?*anyopaque, target: ?*anyopaque, draw_count: u32) callconv(.c) void;
pub extern fn metal_bridge_cmd_buf_render_encoder(cmd_buf: ?*anyopaque, pipeline: ?*anyopaque, target: ?*anyopaque, depth_target: ?*anyopaque, use_depth_store: c_int, clear_r: f64, clear_g: f64, clear_b: f64, clear_a: f64) callconv(.c) ?*anyopaque;
pub extern fn metal_bridge_render_encoder_set_bind_buffer(encoder: ?*anyopaque, slot: u32, buffer: ?*anyopaque, offset: u64) callconv(.c) void;
pub extern fn metal_bridge_render_encoder_set_bind_texture(encoder: ?*anyopaque, slot: u32, texture: ?*anyopaque) callconv(.c) void;
pub extern fn metal_bridge_render_encoder_set_bind_sampler(encoder: ?*anyopaque, slot: u32, sampler: ?*anyopaque) callconv(.c) void;
pub extern fn metal_bridge_render_encoder_set_vertex_buffer(encoder: ?*anyopaque, slot: u32, buffer: ?*anyopaque, offset: u64) callconv(.c) void;
pub extern fn metal_bridge_render_encoder_set_depth_stencil_state(encoder: ?*anyopaque, depth_state: ?*anyopaque) callconv(.c) void;
pub extern fn metal_bridge_render_encoder_set_depth_stencil_values(encoder: ?*anyopaque, compare_fn: u32, write_enabled: c_int) callconv(.c) void;
pub extern fn metal_bridge_render_encoder_set_depth_clip_mode(encoder: ?*anyopaque, clamp: c_int) callconv(.c) void;
pub extern fn metal_bridge_render_encoder_set_front_facing(encoder: ?*anyopaque, front_face: u32) callconv(.c) void;
pub extern fn metal_bridge_render_encoder_set_cull_mode(encoder: ?*anyopaque, cull_mode: u32) callconv(.c) void;
pub extern fn metal_bridge_render_encoder_draw(encoder: ?*anyopaque, topology: u32, draw_count: u32, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32, redundant_pipeline: c_int, pipeline: ?*anyopaque) callconv(.c) void;
pub extern fn metal_bridge_render_encoder_draw_indexed(encoder: ?*anyopaque, topology: u32, draw_count: u32, index_count: u32, instance_count: u32, index_buffer: ?*anyopaque, index_offset: u64, index_format: u32, base_vertex: i32, first_instance: u32) callconv(.c) void;
pub extern fn metal_bridge_render_encoder_draw_indirect(encoder: ?*anyopaque, indirect_buffer: ?*anyopaque, indirect_offset: u64) callconv(.c) void;
pub extern fn metal_bridge_render_encoder_draw_indexed_indirect(encoder: ?*anyopaque, index_buffer: ?*anyopaque, index_buffer_offset: u64, index_type: u32, indirect_buffer: ?*anyopaque, indirect_offset: u64) callconv(.c) void;
pub extern fn metal_bridge_render_encoder_execute_icb(encoder: ?*anyopaque, icb: ?*anyopaque, draw_count: u32) callconv(.c) void;
pub extern fn metal_bridge_render_encoder_end(encoder: ?*anyopaque) callconv(.c) void;
pub extern fn metal_bridge_device_new_shared_event(device: ?*anyopaque) callconv(.c) ?*anyopaque;
pub extern fn metal_bridge_command_buffer_encode_signal_event(cmd_buf: ?*anyopaque, event: ?*anyopaque, value: u64) callconv(.c) void;
pub extern fn metal_bridge_shared_event_wait(event: ?*anyopaque, value: u64) callconv(.c) void;
pub extern fn metal_bridge_device_new_library_msl(device: ?*anyopaque, src: [*]const u8, src_len: usize, error_buf: ?[*]u8, error_cap: usize) callconv(.c) ?*anyopaque;
pub extern fn metal_bridge_library_new_function(library: ?*anyopaque, name: [*:0]const u8) callconv(.c) ?*anyopaque;
pub extern fn metal_bridge_device_new_compute_pipeline(device: ?*anyopaque, function: ?*anyopaque, error_buf: ?[*]u8, error_cap: usize) callconv(.c) ?*anyopaque;
pub extern fn metal_bridge_encode_compute_dispatch(queue: ?*anyopaque, pipeline: ?*anyopaque, buffers: ?[*]?*anyopaque, buffer_count: u32, x: u32, y: u32, z: u32) callconv(.c) ?*anyopaque;
pub extern fn metal_bridge_encode_compute_dispatch_batch(queue: ?*anyopaque, pipeline: ?*anyopaque, buffers: ?[*]?*anyopaque, buffer_count: u32, x: u32, y: u32, z: u32, repeat_count: u32, wg_x: u32, wg_y: u32, wg_z: u32) callconv(.c) ?*anyopaque;
pub extern fn metal_bridge_cmd_buf_encode_compute_dispatch(cmd_buf: ?*anyopaque, pipeline: ?*anyopaque, bufs: ?[*]?*anyopaque, buf_count: u32, x: u32, y: u32, z: u32, wg_x: u32, wg_y: u32, wg_z: u32) callconv(.c) void;
pub extern fn metal_bridge_compute_encoder_encode_dispatch(encoder: ?*anyopaque, pipeline: ?*anyopaque, bufs: ?[*]?*anyopaque, buf_count: u32, x: u32, y: u32, z: u32, wg_x: u32, wg_y: u32, wg_z: u32) callconv(.c) void;
pub extern fn metal_bridge_compute_encoder_encode_dispatch_batch(encoder: ?*anyopaque, pipelines: ?[*]const ?*anyopaque, bufs: ?[*]const ?*anyopaque, buf_counts: [*]const u32, dispatch_dims: [*]const u32, workgroup_dims: [*]const u32, dispatch_count: u32, max_buffer_count: u32) callconv(.c) void;
pub extern fn metal_bridge_compute_encoder_encode_dispatch_batch_repeated(encoder: ?*anyopaque, pipelines: ?[*]const ?*anyopaque, bufs: ?[*]const ?*anyopaque, buf_counts: [*]const u32, repeat_counts: [*]const u32, dispatch_dims: [*]const u32, workgroup_dims: [*]const u32, dispatch_count: u32, max_buffer_count: u32) callconv(.c) void;
pub extern fn metal_bridge_compute_dispatch_batch_copy_signal_commit(queue: ?*anyopaque, pipelines: ?[*]const ?*anyopaque, bufs: ?[*]const ?*anyopaque, buf_counts: [*]const u32, dispatch_dims: [*]const u32, workgroup_dims: [*]const u32, dispatch_count: u32, max_buffer_count: u32, copy_src: ?*anyopaque, copy_src_off: u64, copy_dst: ?*anyopaque, copy_dst_off: u64, copy_size: u64, event: ?*anyopaque, event_value: u64) callconv(.c) ?*anyopaque;
pub extern fn metal_bridge_cmd_buf_encode_compute_dispatch_indirect(cmd_buf: ?*anyopaque, pipeline: ?*anyopaque, bufs: ?[*]?*anyopaque, buf_count: u32, indirect_buf: ?*anyopaque, indirect_offset: u64, wg_x: u32, wg_y: u32, wg_z: u32) callconv(.c) void;
pub extern fn metal_bridge_device_new_texture(device: ?*anyopaque, width: u32, height: u32, depth_or_array_layers: u32, mip_levels: u32, sample_count: u32, pixel_format: u32, usage: u32, dimension: u32) callconv(.c) ?*anyopaque;
pub extern fn metal_bridge_texture_replace_region(texture: ?*anyopaque, width: u32, height: u32, depth_or_array_layers: u32, data: *const anyopaque, bytes_per_row: u32, bytes_per_image: u32, mip_level: u32) callconv(.c) void;
pub extern fn metal_bridge_texture_width(texture: ?*anyopaque) callconv(.c) u32;
pub extern fn metal_bridge_texture_height(texture: ?*anyopaque) callconv(.c) u32;
pub extern fn metal_bridge_texture_depth(texture: ?*anyopaque) callconv(.c) u32;
pub extern fn metal_bridge_texture_sample_count(texture: ?*anyopaque) callconv(.c) u32;
pub extern fn metal_bridge_device_new_sampler(device: ?*anyopaque, min_filter: u32, mag_filter: u32, mipmap_filter: u32, addr_u: u32, addr_v: u32, addr_w: u32, lod_min: f32, lod_max: f32, max_aniso: u16) callconv(.c) ?*anyopaque;
pub extern fn metal_bridge_device_new_render_pipeline(device: ?*anyopaque, pixel_format: u32, support_icb: c_int, error_buf: ?[*]u8, error_cap: usize) callconv(.c) ?*anyopaque;
pub extern fn metal_bridge_device_new_render_pipeline_functions(device: ?*anyopaque, vertex_function: ?*anyopaque, fragment_function: ?*anyopaque, pixel_format: u32, error_buf: ?[*]u8, error_cap: usize) callconv(.c) ?*anyopaque;
pub extern fn metal_bridge_device_new_render_pipeline_full(device: ?*anyopaque, vertex_function: ?*anyopaque, fragment_function: ?*anyopaque, pixel_format: u32, depth_format: u32, vertex_layouts: ?[*]const MetalVertexBufferLayout, vertex_layout_count: u32, vertex_attributes: ?[*]const MetalVertexAttributeDesc, vertex_attribute_count: u32, error_buf: ?[*]u8, error_cap: usize) callconv(.c) ?*anyopaque;
pub extern fn metal_bridge_device_new_depth_stencil_state(device: ?*anyopaque, compare_fn: u32, write_enabled: c_int, error_buf: ?[*]u8, error_cap: usize) callconv(.c) ?*anyopaque;
pub extern fn metal_bridge_device_new_render_target(device: ?*anyopaque, width: u32, height: u32, pixel_format: u32) callconv(.c) ?*anyopaque;
pub extern fn metal_bridge_encode_render_pass(queue: ?*anyopaque, pipeline: ?*anyopaque, target: ?*anyopaque, draw_count: u32, vertex_count: u32, instance_count: u32, redundant_pipeline: c_int, redundant_bindgroup: c_int) callconv(.c) ?*anyopaque;
pub extern fn metal_bridge_device_new_icb(device: ?*anyopaque, pipeline: ?*anyopaque, command_count: u32, redundant_pipeline: c_int) callconv(.c) ?*anyopaque;
pub extern fn metal_bridge_icb_encode_draws(icb: ?*anyopaque, pipeline: ?*anyopaque, draw_count: u32, vertex_count: u32, instance_count: u32, redundant_pipeline: c_int) callconv(.c) void;
pub extern fn metal_bridge_encode_icb_render_pass(queue: ?*anyopaque, pipeline: ?*anyopaque, icb: ?*anyopaque, target: ?*anyopaque, draw_count: u32) callconv(.c) ?*anyopaque;
pub extern fn metal_bridge_cmd_buf_encode_blit_copy(cmd_buf: ?*anyopaque, src: ?*anyopaque, src_off: u64, dst: ?*anyopaque, dst_off: u64, size: u64) callconv(.c) void;
pub extern fn metal_bridge_compute_dispatch_copy_signal_commit(queue: ?*anyopaque, pipeline: ?*anyopaque, bufs: ?[*]?*anyopaque, buf_count: u32, x: u32, y: u32, z: u32, wg_x: u32, wg_y: u32, wg_z: u32, copy_src: ?*anyopaque, copy_src_off: u64, copy_dst: ?*anyopaque, copy_dst_off: u64, copy_size: u64, event: ?*anyopaque, event_value: u64) callconv(.c) ?*anyopaque;
pub extern fn metal_bridge_blit_encoder_copy_region(encoder: ?*anyopaque, src: ?*anyopaque, src_offset: u64, dst: ?*anyopaque, dst_offset: u64, size: u64) callconv(.c) void;
pub extern fn metal_bridge_blit_encoder_copy_buffer_to_texture(encoder: ?*anyopaque, src: ?*anyopaque, src_offset: u64, src_bytes_per_row: u32, src_rows_per_image: u32, dst_texture: ?*anyopaque, dst_mip_level: u32, width: u32, height: u32, depth_or_array_layers: u32) callconv(.c) void;
pub extern fn metal_bridge_blit_encoder_copy_texture_to_buffer(encoder: ?*anyopaque, src_texture: ?*anyopaque, src_mip_level: u32, dst: ?*anyopaque, dst_offset: u64, dst_bytes_per_row: u32, dst_rows_per_image: u32, width: u32, height: u32, depth_or_array_layers: u32) callconv(.c) void;
pub extern fn metal_bridge_blit_encoder_copy_texture_to_texture(encoder: ?*anyopaque, src_texture: ?*anyopaque, src_mip_level: u32, dst_texture: ?*anyopaque, dst_mip_level: u32, width: u32, height: u32, depth_or_array_layers: u32) callconv(.c) void;
pub extern fn metal_bridge_create_surface_host(layer_out: *?*anyopaque) callconv(.c) ?*anyopaque;
pub extern fn metal_bridge_configure_surface_host(host: ?*anyopaque, width: u32, height: u32) callconv(.c) void;
pub extern fn doe_surface_create_offscreen() callconv(.c) ?*anyopaque;
pub extern fn doe_surface_create_from_layer(layer_h: ?*anyopaque) callconv(.c) ?*anyopaque;
pub extern fn doe_surface_release(surf_h: ?*anyopaque) callconv(.c) void;
pub extern fn doe_surface_configure(surf_h: ?*anyopaque, device_h: ?*anyopaque, width: u32, height: u32, pixel_format: u32, present_mode: u32, tone_mapping_mode: u32, alpha_opaque: c_int, dpi_scale: f32) callconv(.c) c_int;
pub extern fn doe_surface_unconfigure(surf_h: ?*anyopaque) callconv(.c) void;
pub extern fn doe_surface_supports_format(wgpu_format: u32) callconv(.c) c_int;
pub extern fn doe_surface_acquire_drawable(surf_h: ?*anyopaque, drawable_out: *?*anyopaque) callconv(.c) ?*anyopaque;
pub extern fn doe_surface_present_drawable(cmd_buf_h: ?*anyopaque, drawable_h: ?*anyopaque) callconv(.c) void;
pub extern fn doe_surface_present_drawable_async(cmd_buf_h: ?*anyopaque, drawable_h: ?*anyopaque) callconv(.c) void;
pub extern fn doe_surface_discard_drawable(drawable_h: ?*anyopaque) callconv(.c) void;
pub extern fn doe_surface_resize(surf_h: ?*anyopaque, width: u32, height: u32, dpi_scale: f32) callconv(.c) void;
pub extern fn doe_surface_drawable_width(surf_h: ?*anyopaque) callconv(.c) u32;
pub extern fn doe_surface_drawable_height(surf_h: ?*anyopaque) callconv(.c) u32;
pub extern fn doe_surface_is_configured(surf_h: ?*anyopaque) callconv(.c) c_int;

// clearBuffer / copyTextureToTexture / writeTexture
pub extern fn metal_bridge_cmd_buf_fill_buffer(cmd_buf: ?*anyopaque, buffer: ?*anyopaque, offset: u64, size: u64) callconv(.c) void;
pub extern fn metal_bridge_cmd_buf_copy_texture_to_texture(cmd_buf: ?*anyopaque, src_texture: ?*anyopaque, src_mip: u32, src_slice: u32, src_x: u32, src_y: u32, src_z: u32, dst_texture: ?*anyopaque, dst_mip: u32, dst_slice: u32, dst_x: u32, dst_y: u32, dst_z: u32, width: u32, height: u32, depth_or_layers: u32) callconv(.c) void;
pub extern fn metal_bridge_texture_write_region(texture: ?*anyopaque, data: *const anyopaque, bytes_per_row: u32, rows_per_image: u32, dst_x: u32, dst_y: u32, dst_z: u32, dst_mip: u32, dst_slice: u32, width: u32, height: u32, depth_or_layers: u32) callconv(.c) c_int;

// Device capability queries — runtime feature detection
pub extern fn metal_bridge_query_device_features() callconv(.c) u32;
pub extern fn metal_bridge_query_device_max_buffer_length() callconv(.c) u64;

// Adapter info string — four NUL-terminated strings (vendor, arch, device, desc) in one block.
// Caller frees with metal_bridge_free_string.
pub extern fn metal_bridge_adapter_get_info_string(device: ?*anyopaque) callconv(.c) ?[*]u8;
pub extern fn metal_bridge_free_string(str: ?[*]u8) callconv(.c) void;
pub extern fn metal_bridge_retain_device(device: ?*anyopaque) callconv(.c) void;
pub extern fn metal_bridge_enumerate_devices(
    out_devices: ?[*]?*anyopaque,
    max_count: u32,
    out_count: *u32,
) callconv(.c) void;
pub extern fn metal_bridge_device_is_low_power(device: ?*anyopaque) callconv(.c) u32;
pub extern fn metal_bridge_device_is_removable(device: ?*anyopaque) callconv(.c) u32;
pub extern fn metal_bridge_binary_archive_create(
    device: ?*anyopaque,
    path: ?[*]const u8,
    error_buf: ?[*]u8,
    error_cap: usize,
) callconv(.c) ?*anyopaque;
pub extern fn metal_bridge_binary_archive_add_compute(
    archive: ?*anyopaque,
    device: ?*anyopaque,
    pipeline: ?*anyopaque,
    error_buf: ?[*]u8,
    error_cap: usize,
) callconv(.c) u32;
pub extern fn metal_bridge_binary_archive_add_render(
    archive: ?*anyopaque,
    device: ?*anyopaque,
    pipeline: ?*anyopaque,
    error_buf: ?[*]u8,
    error_cap: usize,
) callconv(.c) u32;
pub extern fn metal_bridge_binary_archive_serialize(
    archive: ?*anyopaque,
    error_buf: ?[*]u8,
    error_cap: usize,
) callconv(.c) u32;
pub extern fn metal_bridge_device_new_compute_pipeline_with_archive(
    device: ?*anyopaque,
    function: ?*anyopaque,
    archive: ?*anyopaque,
    error_buf: ?[*]u8,
    error_cap: usize,
) callconv(.c) ?*anyopaque;
pub extern fn metal_bridge_device_new_render_pipeline_with_archive(
    device: ?*anyopaque,
    pixel_format: u32,
    support_icb: c_int,
    archive: ?*anyopaque,
    error_buf: ?[*]u8,
    error_cap: usize,
) callconv(.c) ?*anyopaque;

// Multi-queue support
pub extern fn metal_bridge_device_new_command_queue_with_priority(device: ?*anyopaque, priority: u32) callconv(.c) ?*anyopaque;
pub extern fn metal_bridge_command_buffer_encode_wait_event(cmd_buf: ?*anyopaque, event: ?*anyopaque, value: u64) callconv(.c) void;

// GPU timestamp query (MTLCounterSampleBuffer)
pub extern fn metal_bridge_supports_timestamp_query(device: ?*anyopaque) callconv(.c) c_int;
pub extern fn metal_bridge_create_counter_sample_buffer(device: ?*anyopaque, count: u32) callconv(.c) ?*anyopaque;
pub extern fn metal_bridge_sample_timestamp(cmd_buf: ?*anyopaque, counter_buffer: ?*anyopaque, query_index: u32) callconv(.c) void;
pub extern fn metal_bridge_resolve_timestamps(counter_buffer: ?*anyopaque, first_query: u32, query_count: u32, dest_ptr: [*]u64) callconv(.c) c_int;
pub extern fn metal_bridge_resolve_timestamps_ns(counter_buffer: ?*anyopaque, first_query: u32, query_count: u32, dest_ptr: [*]u64) callconv(.c) c_int;
pub extern fn metal_bridge_destroy_counter_sample_buffer(counter_buffer: ?*anyopaque) callconv(.c) void;
// External texture import (IOSurface / CVPixelBuffer)
pub extern fn doe_metal_import_iosurface(device: ?*anyopaque, iosurface: ?*anyopaque, plane: u32, width: u32, height: u32, pixel_format: u32) callconv(.c) ?*anyopaque;
pub extern fn doe_metal_import_cvpixelbuffer(device: ?*anyopaque, cvpixelbuffer: ?*anyopaque, plane: u32) callconv(.c) ?*anyopaque;
pub extern fn doe_metal_external_plane_count(cvpixelbuffer: ?*anyopaque) callconv(.c) u32;
pub extern fn doe_metal_external_plane_size(cvpixelbuffer: ?*anyopaque, plane: u32, out_width: *u32, out_height: *u32) callconv(.c) void;
pub extern fn doe_metal_iosurface_plane_count(iosurface: ?*anyopaque) callconv(.c) u32;
pub extern fn doe_metal_iosurface_plane_size(iosurface: ?*anyopaque, plane: u32, out_width: *u32, out_height: *u32) callconv(.c) void;

// Device property queries (implemented in metal_bridge.m).
pub extern fn metal_bridge_device_registry_id(device: ?*anyopaque) callconv(.c) u64;
pub extern fn metal_bridge_device_name(device: ?*anyopaque, buf: [*]u8, cap: usize) callconv(.c) void;
pub extern fn metal_bridge_device_max_buffer_length(device: ?*anyopaque) callconv(.c) u64;

pub const MetalVertexBufferLayout = extern struct {
    array_stride: u64,
    step_mode: u32,
    buffer_index: u32,
};

pub const MetalVertexAttributeDesc = extern struct {
    format: u32,
    offset: u64,
    shader_location: u32,
    buffer_index: u32,
};
