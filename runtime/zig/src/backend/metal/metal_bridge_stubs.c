/* metal_bridge_stubs.c
 *
 * Non-macOS link stubs for the Metal bridge surface. These keep Linux/Windows
 * Doe artifacts linkable while preserving explicit unsupported behavior at
 * runtime through null/zero/no-op bridge results.
 */

#include <stddef.h>
#include <stdint.h>
#include "metal_bridge.h"
#include "metal_render_state_bridge.h"

static void clear_char_buffer(char* buf, size_t cap) {
    if (buf != NULL && cap > 0) {
        buf[0] = '\0';
    }
}

static void clear_device_list(MetalHandle* out_devices, uint32_t max_count) {
    if (out_devices == NULL) return;
    for (uint32_t i = 0; i < max_count; ++i) {
        out_devices[i] = NULL;
    }
}

MetalHandle metal_bridge_create_default_device(void) { return NULL; }
MetalHandle metal_bridge_create_surface_host(MetalHandle* layer_out) {
    if (layer_out != NULL) *layer_out = NULL;
    return NULL;
}
void metal_bridge_configure_surface_host(MetalHandle host, uint32_t width, uint32_t height) {
    (void)host;
    (void)width;
    (void)height;
}
MetalHandle metal_bridge_retain(MetalHandle obj) {
    (void)obj;
    return NULL;
}
void metal_bridge_release(MetalHandle obj) { (void)obj; }

MetalHandle metal_bridge_device_new_command_queue(MetalHandle device) {
    (void)device;
    return NULL;
}
MetalHandle metal_bridge_device_new_command_queue_with_priority(MetalHandle device, uint32_t priority) {
    (void)device;
    (void)priority;
    return NULL;
}
MetalHandle metal_bridge_device_new_buffer_shared(MetalHandle device, size_t length) {
    (void)device;
    (void)length;
    return NULL;
}
MetalHandle metal_bridge_device_new_buffer_private(MetalHandle device, size_t length) {
    (void)device;
    (void)length;
    return NULL;
}
void* metal_bridge_buffer_contents(MetalHandle buffer) {
    (void)buffer;
    return NULL;
}

MetalHandle metal_bridge_encode_blit_copy(MetalHandle queue, MetalHandle src_buffer, MetalHandle dst_buffer, size_t byte_count) {
    (void)queue;
    (void)src_buffer;
    (void)dst_buffer;
    (void)byte_count;
    return NULL;
}
MetalHandle metal_bridge_encode_blit_batch(MetalHandle queue, MetalHandle* src_buffers, MetalHandle* dst_buffers, size_t* byte_counts, uint32_t count) {
    (void)queue;
    (void)src_buffers;
    (void)dst_buffers;
    (void)byte_counts;
    (void)count;
    return NULL;
}
MetalHandle metal_bridge_begin_blit_encoding(MetalHandle queue, MetalHandle* encoder_out) {
    (void)queue;
    if (encoder_out != NULL) *encoder_out = NULL;
    return NULL;
}
void metal_bridge_blit_encoder_copy(MetalHandle encoder, MetalHandle src, MetalHandle dst, size_t byte_count) {
    (void)encoder;
    (void)src;
    (void)dst;
    (void)byte_count;
}
void metal_bridge_blit_encoder_copy_region(MetalHandle encoder, MetalHandle src, uint64_t src_offset, MetalHandle dst, uint64_t dst_offset, uint64_t size) {
    (void)encoder;
    (void)src;
    (void)src_offset;
    (void)dst;
    (void)dst_offset;
    (void)size;
}
void metal_bridge_blit_encoder_copy_buffer_to_texture(MetalHandle encoder, MetalHandle src, uint64_t src_offset, uint32_t src_bytes_per_row, uint32_t src_rows_per_image, MetalHandle dst_texture, uint32_t dst_mip_level, uint32_t width, uint32_t height, uint32_t depth_or_array_layers) {
    (void)encoder;
    (void)src;
    (void)src_offset;
    (void)src_bytes_per_row;
    (void)src_rows_per_image;
    (void)dst_texture;
    (void)dst_mip_level;
    (void)width;
    (void)height;
    (void)depth_or_array_layers;
}
void metal_bridge_blit_encoder_copy_texture_to_buffer(MetalHandle encoder, MetalHandle src_texture, uint32_t src_mip_level, MetalHandle dst, uint64_t dst_offset, uint32_t dst_bytes_per_row, uint32_t dst_rows_per_image, uint32_t width, uint32_t height, uint32_t depth_or_array_layers) {
    (void)encoder;
    (void)src_texture;
    (void)src_mip_level;
    (void)dst;
    (void)dst_offset;
    (void)dst_bytes_per_row;
    (void)dst_rows_per_image;
    (void)width;
    (void)height;
    (void)depth_or_array_layers;
}
void metal_bridge_blit_encoder_copy_texture_to_texture(MetalHandle encoder, MetalHandle src_texture, uint32_t src_mip_level, MetalHandle dst_texture, uint32_t dst_mip_level, uint32_t width, uint32_t height, uint32_t depth_or_array_layers) {
    (void)encoder;
    (void)src_texture;
    (void)src_mip_level;
    (void)dst_texture;
    (void)dst_mip_level;
    (void)width;
    (void)height;
    (void)depth_or_array_layers;
}
void metal_bridge_end_blit_encoding(MetalHandle encoder) { (void)encoder; }

MetalHandle metal_bridge_create_command_buffer(MetalHandle queue) {
    (void)queue;
    return NULL;
}
MetalHandle metal_bridge_cmd_buf_blit_encoder(MetalHandle cmd_buf) {
    (void)cmd_buf;
    return NULL;
}
MetalHandle metal_bridge_cmd_buf_compute_encoder(MetalHandle cmd_buf) {
    (void)cmd_buf;
    return NULL;
}
void metal_bridge_end_compute_encoding(MetalHandle encoder) { (void)encoder; }
void metal_bridge_command_buffer_commit(MetalHandle cmd_buf) { (void)cmd_buf; }
void metal_bridge_command_buffer_wait_completed(MetalHandle cmd_buf) { (void)cmd_buf; }
void metal_bridge_command_buffer_spin_wait(MetalHandle cmd_buf) { (void)cmd_buf; }
void metal_bridge_command_buffer_setup_fast_wait(MetalHandle cmd_buf) { (void)cmd_buf; }
void metal_bridge_command_buffer_wait_fast(void) {}
void metal_bridge_command_buffer_encode_signal_event(MetalHandle cmd_buf, MetalHandle event, uint64_t value) {
    (void)cmd_buf;
    (void)event;
    (void)value;
}
void metal_bridge_command_buffer_encode_wait_event(MetalHandle cmd_buf, MetalHandle event, uint64_t value) {
    (void)cmd_buf;
    (void)event;
    (void)value;
}

MetalHandle metal_bridge_device_new_shared_event(MetalHandle device) {
    (void)device;
    return NULL;
}
uint64_t metal_bridge_shared_event_signaled_value(MetalHandle event) {
    (void)event;
    return 0;
}
void metal_bridge_shared_event_wait(MetalHandle event, uint64_t value) {
    (void)event;
    (void)value;
}

void metal_bridge_cmd_buf_encode_render_pass(MetalHandle cmd_buf, MetalHandle pipeline, MetalHandle target, uint32_t draw_count, uint32_t vertex_count, uint32_t instance_count, int redundant_pipeline, int redundant_bindgroup) {
    (void)cmd_buf;
    (void)pipeline;
    (void)target;
    (void)draw_count;
    (void)vertex_count;
    (void)instance_count;
    (void)redundant_pipeline;
    (void)redundant_bindgroup;
}
void metal_bridge_cmd_buf_encode_icb_render_pass(MetalHandle cmd_buf, MetalHandle pipeline, MetalHandle icb, MetalHandle target, uint32_t draw_count) {
    (void)cmd_buf;
    (void)pipeline;
    (void)icb;
    (void)target;
    (void)draw_count;
}
MetalHandle metal_bridge_cmd_buf_render_encoder(MetalHandle cmd_buf, MetalHandle pipeline, MetalHandle target, MetalHandle depth_target, int use_depth_store, double clear_r, double clear_g, double clear_b, double clear_a) {
    (void)cmd_buf;
    (void)pipeline;
    (void)target;
    (void)depth_target;
    (void)use_depth_store;
    (void)clear_r;
    (void)clear_g;
    (void)clear_b;
    (void)clear_a;
    return NULL;
}
void metal_bridge_render_encoder_set_bind_buffer(MetalHandle encoder, uint32_t slot, MetalHandle buffer, uint64_t offset) {
    (void)encoder;
    (void)slot;
    (void)buffer;
    (void)offset;
}
void metal_bridge_render_encoder_set_bind_texture(MetalHandle encoder, uint32_t slot, MetalHandle texture) {
    (void)encoder;
    (void)slot;
    (void)texture;
}
void metal_bridge_render_encoder_set_bind_sampler(MetalHandle encoder, uint32_t slot, MetalHandle sampler) {
    (void)encoder;
    (void)slot;
    (void)sampler;
}
void metal_bridge_render_encoder_set_vertex_buffer(MetalHandle encoder, uint32_t slot, MetalHandle buffer, uint64_t offset) {
    (void)encoder;
    (void)slot;
    (void)buffer;
    (void)offset;
}
void metal_bridge_render_encoder_set_depth_stencil_state(MetalHandle encoder, MetalHandle depth_state) {
    (void)encoder;
    (void)depth_state;
}
void metal_bridge_render_encoder_set_depth_stencil_values(MetalHandle encoder, uint32_t compare_fn, int write_enabled) {
    (void)encoder;
    (void)compare_fn;
    (void)write_enabled;
}
void metal_bridge_render_encoder_set_depth_clip_mode(MetalHandle encoder, int clamp) {
    (void)encoder;
    (void)clamp;
}
void metal_bridge_render_encoder_set_front_facing(MetalHandle encoder, uint32_t front_face) {
    (void)encoder;
    (void)front_face;
}
void metal_bridge_render_encoder_set_cull_mode(MetalHandle encoder, uint32_t cull_mode) {
    (void)encoder;
    (void)cull_mode;
}
void metal_bridge_render_encoder_draw(MetalHandle encoder, uint32_t topology, uint32_t draw_count, uint32_t vertex_count, uint32_t instance_count, uint32_t first_vertex, uint32_t first_instance, int redundant_pipeline, MetalHandle pipeline) {
    (void)encoder;
    (void)topology;
    (void)draw_count;
    (void)vertex_count;
    (void)instance_count;
    (void)first_vertex;
    (void)first_instance;
    (void)redundant_pipeline;
    (void)pipeline;
}
void metal_bridge_render_encoder_draw_indexed(MetalHandle encoder, uint32_t topology, uint32_t draw_count, uint32_t index_count, uint32_t instance_count, MetalHandle index_buffer, uint64_t index_offset, uint32_t index_format, int32_t base_vertex, uint32_t first_instance) {
    (void)encoder;
    (void)topology;
    (void)draw_count;
    (void)index_count;
    (void)instance_count;
    (void)index_buffer;
    (void)index_offset;
    (void)index_format;
    (void)base_vertex;
    (void)first_instance;
}
void metal_bridge_render_encoder_draw_indexed_bundle(MetalHandle encoder, MetalHandle index_buffer, uint64_t index_buffer_offset, uint32_t index_type, uint32_t index_count, uint32_t instance_count, uint32_t first_index, int32_t base_vertex, uint32_t first_instance) {
    (void)encoder;
    (void)index_buffer;
    (void)index_buffer_offset;
    (void)index_type;
    (void)index_count;
    (void)instance_count;
    (void)first_index;
    (void)base_vertex;
    (void)first_instance;
}
void metal_bridge_render_encoder_draw_indirect(MetalHandle encoder, MetalHandle indirect_buffer, uint64_t indirect_offset) {
    (void)encoder;
    (void)indirect_buffer;
    (void)indirect_offset;
}
void metal_bridge_render_encoder_draw_indexed_indirect(MetalHandle encoder, MetalHandle index_buffer, uint64_t index_buffer_offset, uint32_t index_type, MetalHandle indirect_buffer, uint64_t indirect_offset) {
    (void)encoder;
    (void)index_buffer;
    (void)index_buffer_offset;
    (void)index_type;
    (void)indirect_buffer;
    (void)indirect_offset;
}
void metal_bridge_render_encoder_execute_icb(MetalHandle encoder, MetalHandle icb, uint32_t draw_count) {
    (void)encoder;
    (void)icb;
    (void)draw_count;
}
void metal_bridge_render_encoder_end(MetalHandle encoder) { (void)encoder; }
void metal_bridge_render_encoder_set_pipeline(MetalHandle encoder, MetalHandle pipeline) {
    (void)encoder;
    (void)pipeline;
}
void metal_bridge_render_encoder_set_buffer(MetalHandle encoder, MetalHandle buffer, uint64_t offset, uint32_t index) {
    (void)encoder;
    (void)buffer;
    (void)offset;
    (void)index;
}

MetalHandle metal_bridge_device_new_library_msl(MetalHandle device, const char* src, size_t src_len, char* error_buf, size_t error_cap) {
    (void)device;
    (void)src;
    (void)src_len;
    clear_char_buffer(error_buf, error_cap);
    return NULL;
}
MetalHandle metal_bridge_library_new_function(MetalHandle library, const char* name) {
    (void)library;
    (void)name;
    return NULL;
}
MetalHandle metal_bridge_device_new_compute_pipeline(MetalHandle device, MetalHandle function, char* error_buf, size_t error_cap) {
    (void)device;
    (void)function;
    clear_char_buffer(error_buf, error_cap);
    return NULL;
}
MetalHandle metal_bridge_device_new_compute_pipeline_with_archive(MetalHandle device, MetalHandle function, MetalHandle archive, char* error_buf, size_t error_cap) {
    (void)device;
    (void)function;
    (void)archive;
    clear_char_buffer(error_buf, error_cap);
    return NULL;
}
MetalHandle metal_bridge_encode_compute_dispatch(MetalHandle queue, MetalHandle pipeline, MetalHandle* buffers, uint32_t buffer_count, uint32_t x, uint32_t y, uint32_t z) {
    (void)queue;
    (void)pipeline;
    (void)buffers;
    (void)buffer_count;
    (void)x;
    (void)y;
    (void)z;
    return NULL;
}
MetalHandle metal_bridge_encode_compute_dispatch_batch(MetalHandle queue, MetalHandle pipeline, MetalHandle* buffers, uint32_t buffer_count, uint32_t x, uint32_t y, uint32_t z, uint32_t repeat_count, uint32_t wg_x, uint32_t wg_y, uint32_t wg_z) {
    (void)queue;
    (void)pipeline;
    (void)buffers;
    (void)buffer_count;
    (void)x;
    (void)y;
    (void)z;
    (void)repeat_count;
    (void)wg_x;
    (void)wg_y;
    (void)wg_z;
    return NULL;
}
void metal_bridge_cmd_buf_encode_compute_dispatch(MetalHandle cmd_buf, MetalHandle pipeline, MetalHandle* buffers, uint32_t buffer_count, uint32_t x, uint32_t y, uint32_t z, uint32_t wg_x, uint32_t wg_y, uint32_t wg_z) {
    (void)cmd_buf;
    (void)pipeline;
    (void)buffers;
    (void)buffer_count;
    (void)x;
    (void)y;
    (void)z;
    (void)wg_x;
    (void)wg_y;
    (void)wg_z;
}
void metal_bridge_compute_encoder_encode_dispatch(MetalHandle encoder, MetalHandle pipeline, MetalHandle* buffers, uint32_t buffer_count, uint32_t x, uint32_t y, uint32_t z, uint32_t wg_x, uint32_t wg_y, uint32_t wg_z) {
    (void)encoder;
    (void)pipeline;
    (void)buffers;
    (void)buffer_count;
    (void)x;
    (void)y;
    (void)z;
    (void)wg_x;
    (void)wg_y;
    (void)wg_z;
}
void metal_bridge_compute_encoder_encode_dispatch_batch(MetalHandle encoder, const MetalHandle* pipelines, const MetalHandle* buffers, const uint32_t* buffer_counts, const uint32_t* dispatch_dims, const uint32_t* workgroup_dims, uint32_t dispatch_count, uint32_t max_buffer_count) {
    (void)encoder;
    (void)pipelines;
    (void)buffers;
    (void)buffer_counts;
    (void)dispatch_dims;
    (void)workgroup_dims;
    (void)dispatch_count;
    (void)max_buffer_count;
}
void metal_bridge_compute_encoder_encode_dispatch_batch_repeated(MetalHandle encoder, const MetalHandle* pipelines, const MetalHandle* buffers, const uint32_t* buffer_counts, const uint32_t* repeat_counts, const uint32_t* dispatch_dims, const uint32_t* workgroup_dims, uint32_t dispatch_count, uint32_t max_buffer_count) {
    (void)encoder;
    (void)pipelines;
    (void)buffers;
    (void)buffer_counts;
    (void)repeat_counts;
    (void)dispatch_dims;
    (void)workgroup_dims;
    (void)dispatch_count;
    (void)max_buffer_count;
}
void metal_bridge_cmd_buf_encode_compute_dispatch_indirect(MetalHandle cmd_buf, MetalHandle pipeline, MetalHandle* buffers, uint32_t buffer_count, MetalHandle indirect_buffer, uint64_t indirect_offset, uint32_t wg_x, uint32_t wg_y, uint32_t wg_z) {
    (void)cmd_buf;
    (void)pipeline;
    (void)buffers;
    (void)buffer_count;
    (void)indirect_buffer;
    (void)indirect_offset;
    (void)wg_x;
    (void)wg_y;
    (void)wg_z;
}
MetalHandle metal_bridge_compute_dispatch_copy_signal_commit(MetalHandle queue, MetalHandle pipeline, MetalHandle* buffers, uint32_t buffer_count, uint32_t x, uint32_t y, uint32_t z, uint32_t wg_x, uint32_t wg_y, uint32_t wg_z, MetalHandle copy_src, uint64_t copy_src_off, MetalHandle copy_dst, uint64_t copy_dst_off, uint64_t copy_size, MetalHandle event, uint64_t event_value) {
    (void)queue;
    (void)pipeline;
    (void)buffers;
    (void)buffer_count;
    (void)x;
    (void)y;
    (void)z;
    (void)wg_x;
    (void)wg_y;
    (void)wg_z;
    (void)copy_src;
    (void)copy_src_off;
    (void)copy_dst;
    (void)copy_dst_off;
    (void)copy_size;
    (void)event;
    (void)event_value;
    return NULL;
}
MetalHandle metal_bridge_compute_dispatch_batch_copy_signal_commit(MetalHandle queue, const MetalHandle* pipelines, const MetalHandle* buffers, const uint32_t* buffer_counts, const uint32_t* dispatch_dims, const uint32_t* workgroup_dims, uint32_t dispatch_count, uint32_t max_buffer_count, MetalHandle copy_src, uint64_t copy_src_off, MetalHandle copy_dst, uint64_t copy_dst_off, uint64_t copy_size, MetalHandle event, uint64_t event_value) {
    (void)queue;
    (void)pipelines;
    (void)buffers;
    (void)buffer_counts;
    (void)dispatch_dims;
    (void)workgroup_dims;
    (void)dispatch_count;
    (void)max_buffer_count;
    (void)copy_src;
    (void)copy_src_off;
    (void)copy_dst;
    (void)copy_dst_off;
    (void)copy_size;
    (void)event;
    (void)event_value;
    return NULL;
}

MetalHandle metal_bridge_device_new_texture(MetalHandle device, uint32_t width, uint32_t height, uint32_t depth_or_array_layers, uint32_t mip_levels, uint32_t sample_count, uint32_t pixel_format, uint32_t usage, uint32_t dimension) {
    (void)device;
    (void)width;
    (void)height;
    (void)depth_or_array_layers;
    (void)mip_levels;
    (void)sample_count;
    (void)pixel_format;
    (void)usage;
    (void)dimension;
    return NULL;
}
MetalHandle metal_bridge_device_new_storage_texture_rw(MetalHandle device, uint32_t width, uint32_t height, uint32_t mip_levels, uint32_t pixel_format) {
    (void)device;
    (void)width;
    (void)height;
    (void)mip_levels;
    (void)pixel_format;
    return NULL;
}
MetalHandle metal_bridge_texture_new_view(MetalHandle texture, uint32_t pixel_format, uint32_t dimension, uint32_t base_mip_level, uint32_t mip_level_count, uint32_t base_array_layer, uint32_t array_layer_count, uint32_t swizzle_r, uint32_t swizzle_g, uint32_t swizzle_b, uint32_t swizzle_a) {
    (void)texture;
    (void)pixel_format;
    (void)dimension;
    (void)base_mip_level;
    (void)mip_level_count;
    (void)base_array_layer;
    (void)array_layer_count;
    (void)swizzle_r;
    (void)swizzle_g;
    (void)swizzle_b;
    (void)swizzle_a;
    return NULL;
}
void metal_bridge_texture_replace_region(MetalHandle texture, uint32_t width, uint32_t height, uint32_t depth_or_array_layers, const void* data, uint32_t bytes_per_row, uint32_t bytes_per_image, uint32_t mip_level) {
    (void)texture;
    (void)width;
    (void)height;
    (void)depth_or_array_layers;
    (void)data;
    (void)bytes_per_row;
    (void)bytes_per_image;
    (void)mip_level;
}
uint32_t metal_bridge_texture_width(MetalHandle texture) { (void)texture; return 0; }
uint32_t metal_bridge_texture_height(MetalHandle texture) { (void)texture; return 0; }
uint32_t metal_bridge_texture_depth(MetalHandle texture) { (void)texture; return 0; }
uint32_t metal_bridge_texture_pixel_format(MetalHandle texture) { (void)texture; return 0; }
uint32_t metal_bridge_texture_mip_level_count(MetalHandle texture) { (void)texture; return 0; }
uint32_t metal_bridge_texture_sample_count(MetalHandle texture) { (void)texture; return 0; }
int metal_bridge_texture_write_region(MetalHandle texture, const void* data, uint32_t bytes_per_row, uint32_t rows_per_image, uint32_t dst_x, uint32_t dst_y, uint32_t dst_z, uint32_t dst_mip, uint32_t dst_slice, uint32_t width, uint32_t height, uint32_t depth_or_layers) {
    (void)texture;
    (void)data;
    (void)bytes_per_row;
    (void)rows_per_image;
    (void)dst_x;
    (void)dst_y;
    (void)dst_z;
    (void)dst_mip;
    (void)dst_slice;
    (void)width;
    (void)height;
    (void)depth_or_layers;
    return 0;
}

MetalHandle metal_bridge_device_new_sampler(MetalHandle device, uint32_t min_filter, uint32_t mag_filter, uint32_t mipmap_filter, uint32_t addr_u, uint32_t addr_v, uint32_t addr_w, float lod_min, float lod_max, uint16_t max_aniso) {
    (void)device;
    (void)min_filter;
    (void)mag_filter;
    (void)mipmap_filter;
    (void)addr_u;
    (void)addr_v;
    (void)addr_w;
    (void)lod_min;
    (void)lod_max;
    (void)max_aniso;
    return NULL;
}

MetalHandle metal_bridge_device_new_render_pipeline(MetalHandle device, uint32_t pixel_format, int support_icb, char* error_buf, size_t error_cap) {
    (void)device;
    (void)pixel_format;
    (void)support_icb;
    clear_char_buffer(error_buf, error_cap);
    return NULL;
}
MetalHandle metal_bridge_device_new_render_pipeline_functions(MetalHandle device, MetalHandle vertex_function, MetalHandle fragment_function, uint32_t pixel_format, char* error_buf, size_t error_cap) {
    (void)device;
    (void)vertex_function;
    (void)fragment_function;
    (void)pixel_format;
    clear_char_buffer(error_buf, error_cap);
    return NULL;
}
MetalHandle metal_bridge_device_new_render_pipeline_full(MetalHandle device, MetalHandle vertex_function, MetalHandle fragment_function, uint32_t pixel_format, uint32_t depth_format, uint32_t sample_count, int blend_enabled, uint32_t color_operation, uint32_t color_src_factor, uint32_t color_dst_factor, uint32_t alpha_operation, uint32_t alpha_src_factor, uint32_t alpha_dst_factor, uint32_t color_write_mask, const MetalVertexBufferLayout* vertex_layouts, uint32_t vertex_layout_count, const MetalVertexAttributeDesc* vertex_attributes, uint32_t vertex_attribute_count, char* error_buf, size_t error_cap) {
    (void)device;
    (void)vertex_function;
    (void)fragment_function;
    (void)pixel_format;
    (void)depth_format;
    (void)sample_count;
    (void)blend_enabled;
    (void)color_operation;
    (void)color_src_factor;
    (void)color_dst_factor;
    (void)alpha_operation;
    (void)alpha_src_factor;
    (void)alpha_dst_factor;
    (void)color_write_mask;
    (void)vertex_layouts;
    (void)vertex_layout_count;
    (void)vertex_attributes;
    (void)vertex_attribute_count;
    clear_char_buffer(error_buf, error_cap);
    return NULL;
}
MetalHandle metal_bridge_device_new_render_pipeline_with_archive(MetalHandle device, uint32_t pixel_format, int support_icb, MetalHandle archive, char* error_buf, size_t error_cap) {
    (void)device;
    (void)pixel_format;
    (void)support_icb;
    (void)archive;
    clear_char_buffer(error_buf, error_cap);
    return NULL;
}
MetalHandle metal_bridge_device_new_depth_stencil_state(MetalHandle device, uint32_t compare_fn, int write_enabled, char* error_buf, size_t error_cap) {
    (void)device;
    (void)compare_fn;
    (void)write_enabled;
    clear_char_buffer(error_buf, error_cap);
    return NULL;
}
MetalHandle metal_bridge_device_new_render_target(MetalHandle device, uint32_t width, uint32_t height, uint32_t pixel_format) {
    (void)device;
    (void)width;
    (void)height;
    (void)pixel_format;
    return NULL;
}
MetalHandle metal_bridge_encode_render_pass(MetalHandle queue, MetalHandle pipeline, MetalHandle target, uint32_t draw_count, uint32_t vertex_count, uint32_t instance_count, int redundant_pipeline, int redundant_bindgroup) {
    (void)queue;
    (void)pipeline;
    (void)target;
    (void)draw_count;
    (void)vertex_count;
    (void)instance_count;
    (void)redundant_pipeline;
    (void)redundant_bindgroup;
    return NULL;
}
MetalHandle metal_bridge_device_new_icb(MetalHandle device, MetalHandle pipeline, uint32_t command_count, int redundant_pipeline) {
    (void)device;
    (void)pipeline;
    (void)command_count;
    (void)redundant_pipeline;
    return NULL;
}
void metal_bridge_icb_encode_draws(MetalHandle icb, MetalHandle pipeline, uint32_t draw_count, uint32_t vertex_count, uint32_t instance_count, int redundant_pipeline) {
    (void)icb;
    (void)pipeline;
    (void)draw_count;
    (void)vertex_count;
    (void)instance_count;
    (void)redundant_pipeline;
}
MetalHandle metal_bridge_encode_icb_render_pass(MetalHandle queue, MetalHandle pipeline, MetalHandle icb, MetalHandle target, uint32_t draw_count) {
    (void)queue;
    (void)pipeline;
    (void)icb;
    (void)target;
    (void)draw_count;
    return NULL;
}
void metal_bridge_cmd_buf_encode_blit_copy(MetalHandle cmd_buf, MetalHandle src, uint64_t src_offset, MetalHandle dst, uint64_t dst_offset, uint64_t size) {
    (void)cmd_buf;
    (void)src;
    (void)src_offset;
    (void)dst;
    (void)dst_offset;
    (void)size;
}
void metal_bridge_cmd_buf_fill_buffer(MetalHandle cmd_buf, MetalHandle buffer, uint64_t offset, uint64_t size) {
    (void)cmd_buf;
    (void)buffer;
    (void)offset;
    (void)size;
}
void metal_bridge_cmd_buf_copy_texture_to_texture(MetalHandle cmd_buf, MetalHandle src_texture, uint32_t src_mip, uint32_t src_slice, uint32_t src_x, uint32_t src_y, uint32_t src_z, MetalHandle dst_texture, uint32_t dst_mip, uint32_t dst_slice, uint32_t dst_x, uint32_t dst_y, uint32_t dst_z, uint32_t width, uint32_t height, uint32_t depth_or_layers) {
    (void)cmd_buf;
    (void)src_texture;
    (void)src_mip;
    (void)src_slice;
    (void)src_x;
    (void)src_y;
    (void)src_z;
    (void)dst_texture;
    (void)dst_mip;
    (void)dst_slice;
    (void)dst_x;
    (void)dst_y;
    (void)dst_z;
    (void)width;
    (void)height;
    (void)depth_or_layers;
}

int metal_bridge_supports_timestamp_query(MetalHandle device) {
    (void)device;
    return 0;
}
MetalHandle metal_bridge_create_counter_sample_buffer(MetalHandle device, uint32_t count) {
    (void)device;
    (void)count;
    return NULL;
}
void metal_bridge_sample_timestamp(MetalHandle cmd_buf, MetalHandle counter_buffer, uint32_t query_index) {
    (void)cmd_buf;
    (void)counter_buffer;
    (void)query_index;
}
int metal_bridge_resolve_timestamps(MetalHandle counter_buffer, uint32_t first_query, uint32_t query_count, uint64_t* dest_ptr) {
    (void)counter_buffer;
    (void)first_query;
    (void)query_count;
    (void)dest_ptr;
    return 0;
}
int metal_bridge_resolve_timestamps_ns(MetalHandle counter_buffer, uint32_t first_query, uint32_t query_count, uint64_t* dest_ptr) {
    (void)counter_buffer;
    (void)first_query;
    (void)query_count;
    (void)dest_ptr;
    return 0;
}
void metal_bridge_destroy_counter_sample_buffer(MetalHandle counter_buffer) { (void)counter_buffer; }

uint32_t metal_bridge_query_device_features(void) { return 0; }
uint64_t metal_bridge_query_device_max_buffer_length(void) { return 0; }
uint64_t metal_bridge_device_max_buffer_length(MetalHandle device) {
    (void)device;
    return 0;
}

void metal_bridge_enumerate_devices(MetalHandle* out_devices, uint32_t max_count, uint32_t* out_count) {
    clear_device_list(out_devices, max_count);
    if (out_count != NULL) *out_count = 0;
}
uint64_t metal_bridge_device_registry_id(MetalHandle device) {
    (void)device;
    return 0;
}
uint32_t metal_bridge_device_is_low_power(MetalHandle device) {
    (void)device;
    return 0;
}
uint32_t metal_bridge_device_is_removable(MetalHandle device) {
    (void)device;
    return 0;
}
void metal_bridge_device_name(MetalHandle device, char* buf, size_t cap) {
    (void)device;
    clear_char_buffer(buf, cap);
}
void metal_bridge_retain_device(MetalHandle device) { (void)device; }
char* metal_bridge_adapter_get_info_string(MetalHandle device) {
    (void)device;
    return NULL;
}
void metal_bridge_free_string(char* str) { (void)str; }

MetalHandle metal_bridge_binary_archive_create(MetalHandle device, const char* path, char* error_buf, size_t error_cap) {
    (void)device;
    (void)path;
    clear_char_buffer(error_buf, error_cap);
    return NULL;
}
uint32_t metal_bridge_binary_archive_add_compute(MetalHandle archive, MetalHandle device, MetalHandle pipeline, char* error_buf, size_t error_cap) {
    (void)archive;
    (void)device;
    (void)pipeline;
    clear_char_buffer(error_buf, error_cap);
    return 0;
}
uint32_t metal_bridge_binary_archive_add_render(MetalHandle archive, MetalHandle device, MetalHandle pipeline, char* error_buf, size_t error_cap) {
    (void)archive;
    (void)device;
    (void)pipeline;
    clear_char_buffer(error_buf, error_cap);
    return 0;
}
uint32_t metal_bridge_binary_archive_serialize(MetalHandle archive, char* error_buf, size_t error_cap) {
    (void)archive;
    clear_char_buffer(error_buf, error_cap);
    return 0;
}

MetalHandle doe_surface_create_offscreen(void) { return NULL; }
MetalHandle doe_surface_create_from_layer(MetalHandle layer_h) {
    (void)layer_h;
    return NULL;
}
void doe_surface_release(MetalHandle surf_h) { (void)surf_h; }
int doe_surface_configure(MetalHandle surf_h, MetalHandle device_h, uint32_t width, uint32_t height, uint32_t pixel_format, uint32_t present_mode, uint32_t tone_mapping_mode, int alpha_opaque, float dpi_scale) {
    (void)surf_h;
    (void)device_h;
    (void)width;
    (void)height;
    (void)pixel_format;
    (void)present_mode;
    (void)tone_mapping_mode;
    (void)alpha_opaque;
    (void)dpi_scale;
    return 0;
}
void doe_surface_unconfigure(MetalHandle surf_h) { (void)surf_h; }
int doe_surface_supports_format(uint32_t wgpu_format) {
    (void)wgpu_format;
    return 0;
}
MetalHandle doe_surface_acquire_drawable(MetalHandle surf_h, MetalHandle* drawable_out) {
    (void)surf_h;
    if (drawable_out != NULL) *drawable_out = NULL;
    return NULL;
}
void doe_surface_present_drawable(MetalHandle cmd_buf_h, MetalHandle drawable_h) {
    (void)cmd_buf_h;
    (void)drawable_h;
}
void doe_surface_present_drawable_async(MetalHandle cmd_buf_h, MetalHandle drawable_h) {
    (void)cmd_buf_h;
    (void)drawable_h;
}
void doe_surface_discard_drawable(MetalHandle drawable_h) { (void)drawable_h; }
void doe_surface_resize(MetalHandle surf_h, uint32_t width, uint32_t height, float dpi_scale) {
    (void)surf_h;
    (void)width;
    (void)height;
    (void)dpi_scale;
}
uint32_t doe_surface_drawable_width(MetalHandle surf_h) {
    (void)surf_h;
    return 0;
}
uint32_t doe_surface_drawable_height(MetalHandle surf_h) {
    (void)surf_h;
    return 0;
}
int doe_surface_is_configured(MetalHandle surf_h) {
    (void)surf_h;
    return 0;
}

// External texture import stubs
#include "metal_external_texture_bridge.h"

MetalHandle doe_metal_import_iosurface(MetalHandle device, void* iosurface, uint32_t plane, uint32_t width, uint32_t height, uint32_t pixel_format) {
    (void)device;
    (void)iosurface;
    (void)plane;
    (void)width;
    (void)height;
    (void)pixel_format;
    return NULL;
}
MetalHandle doe_metal_import_cvpixelbuffer(MetalHandle device, void* cvpixelbuffer, uint32_t plane) {
    (void)device;
    (void)cvpixelbuffer;
    (void)plane;
    return NULL;
}
uint32_t doe_metal_external_plane_count(void* cvpixelbuffer) {
    (void)cvpixelbuffer;
    return 0;
}
void doe_metal_external_plane_size(void* cvpixelbuffer, uint32_t plane, uint32_t* out_width, uint32_t* out_height) {
    (void)cvpixelbuffer;
    (void)plane;
    if (out_width) *out_width = 0;
    if (out_height) *out_height = 0;
}
uint32_t doe_metal_iosurface_plane_count(void* iosurface) {
    (void)iosurface;
    return 0;
}
void doe_metal_iosurface_plane_size(void* iosurface, uint32_t plane, uint32_t* out_width, uint32_t* out_height) {
    (void)iosurface;
    (void)plane;
    if (out_width) *out_width = 0;
    if (out_height) *out_height = 0;
}

void metal_render_state_set_viewport(MetalHandle encoder, double x, double y, double width, double height, double depth_min, double depth_max) {
    (void)encoder;
    (void)x;
    (void)y;
    (void)width;
    (void)height;
    (void)depth_min;
    (void)depth_max;
}
void metal_render_state_set_scissor_rect(MetalHandle encoder, uint32_t x, uint32_t y, uint32_t width, uint32_t height) {
    (void)encoder;
    (void)x;
    (void)y;
    (void)width;
    (void)height;
}
void metal_render_state_set_stencil_reference(MetalHandle encoder, uint32_t value) {
    (void)encoder;
    (void)value;
}
void metal_render_state_set_blend_color(MetalHandle encoder, float r, float g, float b, float a) {
    (void)encoder;
    (void)r;
    (void)g;
    (void)b;
    (void)a;
}
MetalHandle metal_render_state_new_pipeline(MetalHandle device, const char* vertex_msl, const char* fragment_msl, uint32_t pixel_format, uint32_t sample_count, int alpha_to_coverage, const MetalBlendAttachment* blend, const MetalDepthStencilConfig* depth_stencil, int support_icb, char* error_buf, size_t error_cap) {
    (void)device;
    (void)vertex_msl;
    (void)fragment_msl;
    (void)pixel_format;
    (void)sample_count;
    (void)alpha_to_coverage;
    (void)blend;
    (void)depth_stencil;
    (void)support_icb;
    clear_char_buffer(error_buf, error_cap);
    return NULL;
}
MetalHandle metal_render_state_new_depth_stencil_state(MetalHandle device, const MetalDepthStencilConfig* cfg) {
    (void)device;
    (void)cfg;
    return NULL;
}
void metal_render_state_set_depth_stencil_state(MetalHandle encoder, MetalHandle depth_stencil_state) {
    (void)encoder;
    (void)depth_stencil_state;
}
void metal_render_state_push_debug_group(MetalHandle encoder, const char* label, size_t label_len) {
    (void)encoder;
    (void)label;
    (void)label_len;
}
void metal_render_state_pop_debug_group(MetalHandle encoder) { (void)encoder; }
void metal_render_state_insert_debug_marker(MetalHandle encoder, const char* label, size_t label_len) {
    (void)encoder;
    (void)label;
    (void)label_len;
}
MetalHandle metal_render_state_new_msaa_texture(MetalHandle device, uint32_t width, uint32_t height, uint32_t pixel_format, uint32_t sample_count) {
    (void)device;
    (void)width;
    (void)height;
    (void)pixel_format;
    (void)sample_count;
    return NULL;
}
MetalHandle metal_render_state_cmd_buf_msaa_render_encoder(MetalHandle cmd_buf, MetalHandle pipeline, MetalHandle msaa_texture, MetalHandle resolve_target) {
    (void)cmd_buf;
    (void)pipeline;
    (void)msaa_texture;
    (void)resolve_target;
    return NULL;
}
