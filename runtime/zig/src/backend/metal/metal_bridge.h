#pragma once
#include <stddef.h>
#include <stdint.h>

// Opaque handle: every returned handle is +1 retained; caller owns it.
// Call metal_bridge_release() to decrement when done.
typedef void* MetalHandle;
typedef void (*MetalCompletionCallback)(void* userdata);

typedef struct {
    uint64_t array_stride;
    uint32_t step_mode;
    uint32_t buffer_index;
} MetalVertexBufferLayout;

typedef struct {
    uint32_t format;
    uint64_t offset;
    uint32_t shader_location;
    uint32_t buffer_index;
} MetalVertexAttributeDesc;

typedef struct {
    uint32_t color_load_op;
    uint32_t color_store_op;
    uint32_t depth_load_op;
    uint32_t depth_store_op;
    uint32_t stencil_load_op;
    uint32_t stencil_store_op;
    uint32_t depth_read_only;
    uint32_t stencil_read_only;
    double clear_r;
    double clear_g;
    double clear_b;
    double clear_a;
    float depth_clear_value;
    uint32_t stencil_clear_value;
} MetalRenderPassOps;

MetalHandle metal_bridge_create_default_device(void);
MetalHandle metal_bridge_create_surface_host(MetalHandle* layer_out);
void        metal_bridge_configure_surface_host(MetalHandle host, uint32_t width, uint32_t height);
MetalHandle metal_bridge_retain(MetalHandle obj);
void        metal_bridge_release(MetalHandle obj);

MetalHandle metal_bridge_device_new_command_queue(MetalHandle device);
MetalHandle metal_bridge_device_new_buffer_shared(MetalHandle device, size_t length);
MetalHandle metal_bridge_device_new_buffer_private(MetalHandle device, size_t length);
void*       metal_bridge_buffer_contents(MetalHandle buffer);

// Records a blit copy from src to dst and returns the committed command buffer
// (+1 retained). Call metal_bridge_command_buffer_wait_completed(), then
// metal_bridge_release() when done.
MetalHandle metal_bridge_encode_blit_copy(
    MetalHandle queue,
    MetalHandle src_buffer,
    MetalHandle dst_buffer,
    size_t      byte_count);

void metal_bridge_command_buffer_commit(MetalHandle cmd_buf);
void metal_bridge_command_buffer_wait_completed(MetalHandle cmd_buf);
void metal_bridge_command_buffer_spin_wait(MetalHandle cmd_buf);
// Keep an Objective-C object alive until this command buffer completes.
int metal_bridge_command_buffer_retain_object_until_complete(
    MetalHandle cmd_buf,
    MetalHandle object);

// === Shared Event (lightweight GPU fence) ===

MetalHandle metal_bridge_device_new_shared_event(MetalHandle device);
uint64_t    metal_bridge_shared_event_signaled_value(MetalHandle event);
// Encode a signal on the command buffer; GPU sets event value after completion.
void metal_bridge_command_buffer_encode_signal_event(
    MetalHandle cmd_buf,
    MetalHandle event,
    uint64_t    value);
// Wait until the event reaches the given value.
void metal_bridge_shared_event_wait(MetalHandle event, uint64_t value);
// Invoke callback on the shared-event listener queue when value is reached.
int metal_bridge_shared_event_notify(
    MetalHandle event,
    uint64_t value,
    MetalCompletionCallback callback,
    void* userdata);

// Batch-encode multiple blit copies into a single command buffer.
// Returns the command buffer (+1 retained) ready for commit+wait.
MetalHandle metal_bridge_encode_blit_batch(
    MetalHandle  queue,
    MetalHandle* src_buffers,
    MetalHandle* dst_buffers,
    size_t*      byte_counts,
    uint32_t     count);

// === Streaming Blit Encoder ===

// Create a command buffer with a blit encoder ready for appending copies.
// Returns the command buffer (+1 retained). encoder_out receives the encoder.
MetalHandle metal_bridge_begin_blit_encoding(MetalHandle queue, MetalHandle* encoder_out);
// Append a copy to an open blit encoder.
void metal_bridge_blit_encoder_copy(
    MetalHandle encoder,
    MetalHandle src,
    MetalHandle dst,
    size_t      byte_count);
void metal_bridge_blit_encoder_copy_region(
    MetalHandle encoder,
    MetalHandle src,
    uint64_t    src_offset,
    MetalHandle dst,
    uint64_t    dst_offset,
    uint64_t    size);
void metal_bridge_blit_encoder_copy_buffer_to_texture(
    MetalHandle encoder,
    MetalHandle src,
    uint64_t    src_offset,
    uint32_t    src_bytes_per_row,
    uint32_t    src_rows_per_image,
    MetalHandle dst_texture,
    uint32_t    dst_mip_level,
    uint32_t    width,
    uint32_t    height,
    uint32_t    depth_or_array_layers);
void metal_bridge_blit_encoder_copy_texture_to_buffer(
    MetalHandle encoder,
    MetalHandle src_texture,
    uint32_t    src_mip_level,
    MetalHandle dst,
    uint64_t    dst_offset,
    uint32_t    dst_bytes_per_row,
    uint32_t    dst_rows_per_image,
    uint32_t    width,
    uint32_t    height,
    uint32_t    depth_or_array_layers);
void metal_bridge_blit_encoder_copy_texture_to_texture(
    MetalHandle encoder,
    MetalHandle src_texture,
    uint32_t    src_mip_level,
    MetalHandle dst_texture,
    uint32_t    dst_mip_level,
    uint32_t    width,
    uint32_t    height,
    uint32_t    depth_or_array_layers);
// End the current blit encoder. Call before commit or before starting a new encoder.
void metal_bridge_end_blit_encoding(MetalHandle encoder);

// === Streaming Command Buffer ===

// Create a command buffer without any encoder (+1 retained).
MetalHandle metal_bridge_create_command_buffer(MetalHandle queue);
// Open a blit encoder on an existing command buffer. Returns unretained encoder.
MetalHandle metal_bridge_cmd_buf_blit_encoder(MetalHandle cmd_buf);
// Open a compute encoder on an existing command buffer. Returns unretained encoder.
MetalHandle metal_bridge_cmd_buf_compute_encoder(MetalHandle cmd_buf);
// Open a compute encoder whose pass boundaries write timestamp samples.
MetalHandle metal_bridge_cmd_buf_compute_encoder_with_timestamps(
    MetalHandle cmd_buf,
    MetalHandle counter_buffer,
    uint32_t    begin_query_index,
    uint32_t    end_query_index);
// End the current compute encoder. Call before commit or before starting a new encoder.
void metal_bridge_end_compute_encoding(MetalHandle encoder);
// Encode a render pass on an existing command buffer (no commit).
void metal_bridge_cmd_buf_encode_render_pass(
    MetalHandle cmd_buf,
    MetalHandle pipeline,
    MetalHandle target,
    uint32_t    draw_count,
    uint32_t    vertex_count,
    uint32_t    instance_count,
    int         redundant_pipeline,
    int         redundant_bindgroup);
// Encode an ICB render pass on an existing command buffer (no commit).
void metal_bridge_cmd_buf_encode_icb_render_pass(
    MetalHandle cmd_buf,
    MetalHandle pipeline,
    MetalHandle icb,
    MetalHandle target,
    uint32_t    draw_count);
// Create a render encoder on cmd_buf. The returned encoder is retained.
MetalHandle metal_bridge_cmd_buf_render_encoder(
    MetalHandle cmd_buf,
    MetalHandle pipeline,
    MetalHandle target,
    MetalHandle resolve_target,
    MetalHandle depth_target,
    const MetalRenderPassOps* ops);
void metal_bridge_render_encoder_set_bind_buffer(
    MetalHandle encoder,
    uint32_t    slot,
    MetalHandle buffer,
    uint64_t    offset);
void metal_bridge_render_encoder_set_bind_texture(
    MetalHandle encoder,
    uint32_t    slot,
    MetalHandle texture);
void metal_bridge_render_encoder_set_bind_sampler(
    MetalHandle encoder,
    uint32_t    slot,
    MetalHandle sampler);
void metal_bridge_render_encoder_set_vertex_buffer(
    MetalHandle encoder,
    uint32_t    slot,
    MetalHandle buffer,
    uint64_t    offset);
void metal_bridge_render_encoder_set_depth_stencil_state(
    MetalHandle encoder,
    MetalHandle depth_state);
void metal_bridge_render_encoder_set_depth_stencil_values(
    MetalHandle encoder,
    uint32_t    compare_fn,
    int         write_enabled);
void metal_bridge_render_encoder_set_depth_clip_mode(
    MetalHandle encoder,
    int         clamp);
void metal_bridge_render_encoder_set_front_facing(
    MetalHandle encoder,
    uint32_t    front_face);
void metal_bridge_render_encoder_set_cull_mode(
    MetalHandle encoder,
    uint32_t    cull_mode);
// Draw loop on an open render encoder.
void metal_bridge_render_encoder_draw(
    MetalHandle encoder,
    uint32_t    topology,
    uint32_t    draw_count,
    uint32_t    vertex_count,
    uint32_t    instance_count,
    uint32_t    first_vertex,
    uint32_t    first_instance,
    int         redundant_pipeline,
    MetalHandle pipeline);
void metal_bridge_render_encoder_draw_indexed(
    MetalHandle encoder,
    uint32_t    topology,
    uint32_t    draw_count,
    uint32_t    index_count,
    uint32_t    instance_count,
    MetalHandle index_buffer,
    uint64_t    index_offset,
    uint32_t    index_format,
    int32_t     base_vertex,
    uint32_t    first_instance);
// Execute ICB on an open render encoder.
void metal_bridge_render_encoder_execute_icb(
    MetalHandle encoder,
    MetalHandle icb,
    uint32_t    draw_count);
// End a render encoder.
void metal_bridge_render_encoder_end(MetalHandle encoder);

// === Compute Pipeline ===

// Compile MSL source into a MTLLibrary. On error writes a NUL-terminated
// message into error_buf (truncated to error_cap) and returns NULL.
MetalHandle metal_bridge_device_new_library_msl(
    MetalHandle device,
    const char* src,
    size_t      src_len,
    char*       error_buf,
    size_t      error_cap);

// Get a named function from a library.
MetalHandle metal_bridge_library_new_function(MetalHandle library, const char* name);

// Create compute pipeline from a function. Returns NULL on failure.
MetalHandle metal_bridge_device_new_compute_pipeline(
    MetalHandle device,
    MetalHandle function,
    char*       error_buf,
    size_t      error_cap);

// Encode and commit a compute dispatch. buffers[i] is the MTLBuffer for
// argument index i; buffers may be NULL (dispatch with no bindings). Returns
// the committed command buffer (+1 retained).
MetalHandle metal_bridge_encode_compute_dispatch(
    MetalHandle  queue,
    MetalHandle  pipeline,
    MetalHandle* buffers,
    uint32_t     buffer_count,
    uint32_t     x,
    uint32_t     y,
    uint32_t     z);

// Encode a blit copy into an existing command buffer (no commit).
void metal_bridge_cmd_buf_encode_blit_copy(
    MetalHandle cmd_buf,
    MetalHandle src,
    uint64_t    src_offset,
    MetalHandle dst,
    uint64_t    dst_offset,
    uint64_t    size);

// Encode a compute dispatch into an existing command buffer (no commit).
// Creates a compute encoder, dispatches, ends encoder.
// wg_x/wg_y/wg_z: shader workgroup size (0 = fallback to pipeline max).
void metal_bridge_cmd_buf_encode_compute_dispatch(
    MetalHandle  cmd_buf,
    MetalHandle  pipeline,
    MetalHandle* buffers,
    uint32_t     buffer_count,
    uint32_t     x,
    uint32_t     y,
    uint32_t     z,
    uint32_t     wg_x,
    uint32_t     wg_y,
    uint32_t     wg_z);

// Encode a compute dispatch on an already-open compute encoder.
void metal_bridge_compute_encoder_encode_dispatch(
    MetalHandle  encoder,
    MetalHandle  pipeline,
    MetalHandle* buffers,
    uint32_t     buffer_count,
    uint32_t     x,
    uint32_t     y,
    uint32_t     z,
    uint32_t     wg_x,
    uint32_t     wg_y,
    uint32_t     wg_z);

// Encode multiple compute dispatches on an already-open compute encoder.
void metal_bridge_compute_encoder_encode_dispatch_batch(
    MetalHandle         encoder,
    const MetalHandle*  pipelines,
    const MetalHandle*  buffers,
    const uint32_t*     buffer_counts,
    const uint32_t*     dispatch_dims,
    const uint32_t*     workgroup_dims,
    uint32_t            dispatch_count,
    uint32_t            max_buffer_count);

void metal_bridge_compute_encoder_encode_dispatch_batch_repeated(
    MetalHandle         encoder,
    const MetalHandle*  pipelines,
    const MetalHandle*  buffers,
    const uint32_t*     buffer_counts,
    const uint32_t*     repeat_counts,
    const uint32_t*     dispatch_dims,
    const uint32_t*     workgroup_dims,
    uint32_t            dispatch_count,
    uint32_t            max_buffer_count);

MetalHandle metal_bridge_compute_dispatch_batch_copy_signal_commit(
    MetalHandle         queue,
    const MetalHandle*  pipelines,
    const MetalHandle*  buffers,
    const uint32_t*     buffer_counts,
    const uint32_t*     dispatch_dims,
    const uint32_t*     workgroup_dims,
    uint32_t            dispatch_count,
    uint32_t            max_buffer_count,
    MetalHandle         copy_src,
    uint64_t            copy_src_off,
    MetalHandle         copy_dst,
    uint64_t            copy_dst_off,
    uint64_t            copy_size,
    MetalHandle         event,
    uint64_t            event_value);

// Encode an indirect compute dispatch into an existing command buffer (no commit).
// indirect_buffer contains a MTLDispatchThreadgroupsIndirectArguments struct at offset.
// wg_x/wg_y/wg_z: shader workgroup size (0 = fallback to pipeline max).
void metal_bridge_cmd_buf_encode_compute_dispatch_indirect(
    MetalHandle  cmd_buf,
    MetalHandle  pipeline,
    MetalHandle* buffers,
    uint32_t     buffer_count,
    MetalHandle  indirect_buffer,
    uint64_t     indirect_offset,
    uint32_t     wg_x,
    uint32_t     wg_y,
    uint32_t     wg_z);

// === Texture ===

// pixel_format: WGPU texture format value (mapped internally to MTLPixelFormat).
// usage: WGPU texture usage flags.
// dimension: WGPUTextureDimension value (2 = 2D, 3 = 3D). depth_or_array_layers > 1 with dimension 2 creates a 2D array.
MetalHandle metal_bridge_device_new_texture(
    MetalHandle device,
    uint32_t    width,
    uint32_t    height,
    uint32_t    depth_or_array_layers,
    uint32_t    mip_levels,
    uint32_t    sample_count,
    uint32_t    pixel_format,
    uint32_t    usage,
    uint32_t    dimension);
MetalHandle metal_bridge_texture_new_view(
    MetalHandle texture,
    uint32_t    pixel_format,
    uint32_t    dimension,
    uint32_t    base_mip_level,
    uint32_t    mip_level_count,
    uint32_t    base_array_layer,
    uint32_t    array_layer_count,
    uint32_t    swizzle_r,
    uint32_t    swizzle_g,
    uint32_t    swizzle_b,
    uint32_t    swizzle_a);

// Write CPU data into a texture. For 3D textures uses replaceRegion:bytesPerImage:; for 2D uses bytesPerRow only.
void metal_bridge_texture_replace_region(
    MetalHandle  texture,
    uint32_t     width,
    uint32_t     height,
    uint32_t     depth_or_array_layers,
    const void*  data,
    uint32_t     bytes_per_row,
    uint32_t     bytes_per_image,
    uint32_t     mip_level);

uint32_t metal_bridge_texture_width(MetalHandle texture);
uint32_t metal_bridge_texture_height(MetalHandle texture);
uint32_t metal_bridge_texture_depth(MetalHandle texture);
uint32_t metal_bridge_texture_pixel_format(MetalHandle texture);
uint32_t metal_bridge_texture_mip_level_count(MetalHandle texture);
uint32_t metal_bridge_texture_sample_count(MetalHandle texture);

// === Sampler ===

// Filter values: 0=nearest, 1=linear.
// Address mode values: 0=clamp_to_edge, 1=mirror_clamp_to_edge, 2=repeat, 3=mirror_repeat.
MetalHandle metal_bridge_device_new_sampler(
    MetalHandle device,
    uint32_t    min_filter,
    uint32_t    mag_filter,
    uint32_t    mipmap_filter,
    uint32_t    addr_u,
    uint32_t    addr_v,
    uint32_t    addr_w,
    float       lod_min,
    float       lod_max,
    uint16_t    max_aniso);

// === Render Pipeline ===

// Create a render pipeline with built-in noop vertex/fragment shaders.
// pixel_format: WGPU texture format. support_icb: 1 to enable ICB use.
// Returns NULL on failure.
MetalHandle metal_bridge_device_new_render_pipeline(
    MetalHandle device,
    uint32_t    pixel_format,
    int         support_icb,
    char*       error_buf,
    size_t      error_cap);
MetalHandle metal_bridge_device_new_render_pipeline_functions(
    MetalHandle device,
    MetalHandle vertex_function,
    MetalHandle fragment_function,
    uint32_t    pixel_format,
    char*       error_buf,
    size_t      error_cap);
MetalHandle metal_bridge_device_new_render_pipeline_full(
    MetalHandle                     device,
    MetalHandle                     vertex_function,
    MetalHandle                     fragment_function,
    uint32_t                        pixel_format,
    uint32_t                        depth_format,
    uint32_t                        sample_count,
    int                             blend_enabled,
    uint32_t                        color_operation,
    uint32_t                        color_src_factor,
    uint32_t                        color_dst_factor,
    uint32_t                        alpha_operation,
    uint32_t                        alpha_src_factor,
    uint32_t                        alpha_dst_factor,
    uint32_t                        color_write_mask,
    const MetalVertexBufferLayout*  vertex_layouts,
    uint32_t                        vertex_layout_count,
    const MetalVertexAttributeDesc* vertex_attributes,
    uint32_t                        vertex_attribute_count,
    char*                           error_buf,
    size_t                          error_cap);
MetalHandle metal_bridge_device_new_depth_stencil_state(
    MetalHandle device,
    uint32_t    compare_fn,
    int         write_enabled,
    char*       error_buf,
    size_t      error_cap);

// Create an offscreen MTLTexture suitable as a render target.
MetalHandle metal_bridge_device_new_render_target(
    MetalHandle device,
    uint32_t    width,
    uint32_t    height,
    uint32_t    pixel_format);

// Encode a render pass with draw_count draw calls and commit. Returns the
// committed command buffer (+1 retained). redundant_pipeline: re-bind
// pipeline before each draw. redundant_bindgroup: no-op in Metal (documented
// deviation from WebGPU — Metal has no bind-group abstraction).
MetalHandle metal_bridge_encode_render_pass(
    MetalHandle queue,
    MetalHandle pipeline,
    MetalHandle target,
    uint32_t    draw_count,
    uint32_t    vertex_count,
    uint32_t    instance_count,
    int         redundant_pipeline,
    int         redundant_bindgroup);

// Create a Metal Indirect Command Buffer for render bundle emulation.
// command_count is the maximum number of draw commands.
MetalHandle metal_bridge_device_new_icb(
    MetalHandle device,
    MetalHandle pipeline,
    uint32_t    command_count,
    int         redundant_pipeline);

// Encode draw commands into an existing ICB. redundant_pipeline: call
// setRenderPipelineState per command (vs. inherit from encoder).
void metal_bridge_icb_encode_draws(
    MetalHandle icb,
    MetalHandle pipeline,
    uint32_t    draw_count,
    uint32_t    vertex_count,
    uint32_t    instance_count,
    int         redundant_pipeline);

// Encode a render pass that replays the ICB and commit. Returns the committed
// command buffer (+1 retained).
MetalHandle metal_bridge_encode_icb_render_pass(
    MetalHandle queue,
    MetalHandle pipeline,
    MetalHandle icb,
    MetalHandle target,
    uint32_t    draw_count);

// === GPU Timestamp Query (MTLCounterSampleBuffer) ===

// Check whether the device supports GPU timestamp counter sampling at stage boundaries.
int metal_bridge_supports_timestamp_query(MetalHandle device);

// Create a MTLCounterSampleBuffer for GPU timestamp queries.
// Returns NULL if counter sampling is unsupported or the timestamp counter set is absent.
MetalHandle metal_bridge_create_counter_sample_buffer(MetalHandle device, uint32_t count);

// Sample a standalone GPU timestamp when blit-boundary sampling is available.
// Stage-boundary-only devices use the timestamped compute encoder above.
void metal_bridge_sample_timestamp(
    MetalHandle cmd_buf,
    MetalHandle counter_buffer,
    uint32_t    query_index);

// Resolve GPU timestamps from the counter sample buffer and copy to dest.
// dest_ptr must point to query_count * sizeof(uint64_t) bytes.
// Returns 1 on success, 0 on failure.
int metal_bridge_resolve_timestamps(
    MetalHandle counter_buffer,
    uint32_t    first_query,
    uint32_t    query_count,
    uint64_t*   dest_ptr);

// Resolve GPU timestamps from the counter sample buffer and convert to nanoseconds.
// Writes query_count nanosecond values into dest_ptr.
// Uses mach_timebase_info for Mach-absolute-time-to-nanosecond conversion.
// Returns 1 on success, 0 on failure.
int metal_bridge_resolve_timestamps_ns(
    MetalHandle counter_buffer,
    uint32_t    first_query,
    uint32_t    query_count,
    uint64_t*   dest_ptr);

// Release a counter sample buffer handle.
void metal_bridge_destroy_counter_sample_buffer(MetalHandle counter_buffer);

// === Semaphore-based completion (faster than waitUntilCompleted) ===

// Register a completion handler on cmd_buf that signals an internal semaphore.
// Must be called BEFORE commit. Only one pending wait is supported at a time.
void metal_bridge_command_buffer_setup_fast_wait(MetalHandle cmd_buf);
// Block until the completion handler fires. Call after commit.
void metal_bridge_command_buffer_wait_fast(void);

// === Device capability queries ===

// Feature bitmask positions returned by metal_bridge_query_device_features().
#define METAL_FEATURE_BIT_SHADER_F16               (1u << 0)
#define METAL_FEATURE_BIT_SUBGROUPS                (1u << 1)
#define METAL_FEATURE_BIT_TIMESTAMP_QUERY          (1u << 2)
#define METAL_FEATURE_BIT_INDIRECT_FIRST_INSTANCE  (1u << 3)
#define METAL_FEATURE_BIT_DEPTH_CLIP_CONTROL       (1u << 4)
#define METAL_FEATURE_BIT_DEPTH32FLOAT_STENCIL8    (1u << 5)
#define METAL_FEATURE_BIT_BGRA8UNORM_STORAGE       (1u << 6)
#define METAL_FEATURE_BIT_FLOAT32_FILTERABLE       (1u << 7)
#define METAL_FEATURE_BIT_FLOAT32_BLENDABLE        (1u << 8)
#define METAL_FEATURE_BIT_TEXTURE_COMPRESSION_ASTC (1u << 9)
#define METAL_FEATURE_BIT_TEXTURE_COMPRESSION_BC  (1u << 10)
#define METAL_FEATURE_BIT_TEXTURE_COMPRESSION_BC_SLICED_3D (1u << 11)
#define METAL_FEATURE_BIT_TEXTURE_COMPRESSION_ETC2 (1u << 12)
#define METAL_FEATURE_BIT_RG11B10UFLOAT_RENDERABLE (1u << 13)
#define METAL_FEATURE_BIT_SUBGROUPS_F16            (1u << 14)
#define METAL_FEATURE_BIT_TEXTURE_COMPRESSION_ASTC_SLICED_3D (1u << 15)
#define METAL_FEATURE_BIT_CLIP_DISTANCES           (1u << 16)
#define METAL_FEATURE_BIT_DUAL_SOURCE_BLENDING     (1u << 17)

// Query the default Metal device for supported features. Returns a bitmask
// of METAL_FEATURE_BIT_* flags. Result is cached after the first call.
// Returns 0 if no Metal device is available.
uint32_t metal_bridge_query_device_features(void);

// Query the Metal device's maximum single buffer allocation size in bytes.
// Maps to [MTLDevice maxBufferLength]. Result is cached after the first call.
// Returns 0 if no Metal device is available.
uint64_t metal_bridge_query_device_max_buffer_length(void);

// === Render bundle replay helpers ===

// Set the pipeline state on an open render encoder.
void metal_bridge_render_encoder_set_pipeline(MetalHandle encoder, MetalHandle pipeline);

// Bind a buffer at a given index on an open render encoder.
void metal_bridge_render_encoder_set_buffer(
    MetalHandle encoder,
    MetalHandle buffer,
    uint64_t    offset,
    uint32_t    index);

// Draw indexed primitives on an open render encoder (render bundle replay variant).
// index_type: 1=uint16, 2=uint32 (matching WGPUIndexFormat).
// first_index is applied as a byte offset into the index buffer.
void metal_bridge_render_encoder_draw_indexed_bundle(
    MetalHandle encoder,
    MetalHandle index_buffer,
    uint64_t    index_buffer_offset,
    uint32_t    index_type,
    uint32_t    index_count,
    uint32_t    instance_count,
    uint32_t    first_index,
    int32_t     base_vertex,
    uint32_t    first_instance);

// Draw non-indexed primitives from an indirect buffer on an open render encoder.
void metal_bridge_render_encoder_draw_indirect(
    MetalHandle encoder,
    MetalHandle indirect_buffer,
    uint64_t    indirect_offset);

// Draw indexed primitives from an indirect buffer on an open render encoder.
void metal_bridge_render_encoder_draw_indexed_indirect(
    MetalHandle encoder,
    MetalHandle index_buffer,
    uint64_t    index_buffer_offset,
    uint32_t    index_type,
    MetalHandle indirect_buffer,
    uint64_t    indirect_offset);

// === Multi-queue support ===

// Create a command queue with a priority hint (0=low, 50=normal, 100=high).
// Falls back to default priority on older OS versions.
MetalHandle metal_bridge_device_new_command_queue_with_priority(
    MetalHandle device,
    uint32_t    priority);

// Encode a wait-for-event into cmd_buf so the GPU does not start executing
// commands until the shared event reaches the target value.
void metal_bridge_command_buffer_encode_wait_event(
    MetalHandle cmd_buf,
    MetalHandle event,
    uint64_t    value);

// === Large buffer queries ===

// Return the maximum MTLBuffer length the device supports (bytes).
uint64_t metal_bridge_device_max_buffer_length(MetalHandle device);

// === Read-write storage texture creation ===

// Create a 2D texture with both read and write usage bits set.
// pixel_format: WGPU texture format. Returns NULL on failure.
MetalHandle metal_bridge_device_new_storage_texture_rw(
    MetalHandle device,
    uint32_t    width,
    uint32_t    height,
    uint32_t    mip_levels,
    uint32_t    pixel_format);

// === clearBuffer / copyTextureToTexture / writeTexture (command-buffer / CPU-direct level) ===

// Zero-fill a byte range of buffer on an existing command buffer (no commit).
// Creates a blit encoder, fills the range with value 0, ends encoding.
void metal_bridge_cmd_buf_fill_buffer(
    MetalHandle cmd_buf,
    MetalHandle buffer,
    uint64_t    offset,
    uint64_t    size);

// Copy a region of src_texture to dst_texture on an existing command buffer (no commit).
// Creates a blit encoder, copies, ends encoding.
// src_x/y/z: source origin. dst_x/y/z: destination origin.
void metal_bridge_cmd_buf_copy_texture_to_texture(
    MetalHandle cmd_buf,
    MetalHandle src_texture,
    uint32_t    src_mip,
    uint32_t    src_slice,
    uint32_t    src_x,
    uint32_t    src_y,
    uint32_t    src_z,
    MetalHandle dst_texture,
    uint32_t    dst_mip,
    uint32_t    dst_slice,
    uint32_t    dst_x,
    uint32_t    dst_y,
    uint32_t    dst_z,
    uint32_t    width,
    uint32_t    height,
    uint32_t    depth_or_layers);

// Write CPU data into a texture sub-region using replaceRegion (shared/unified-memory path).
// dst_x/y/z: destination origin. dst_mip: mip level. dst_slice: array / depth slice.
// Returns 1 on success, 0 on invalid arguments.
int metal_bridge_texture_write_region(
    MetalHandle  texture,
    const void*  data,
    uint32_t     bytes_per_row,
    uint32_t     rows_per_image,
    uint32_t     dst_x,
    uint32_t     dst_y,
    uint32_t     dst_z,
    uint32_t     dst_mip,
    uint32_t     dst_slice,
    uint32_t     width,
    uint32_t     height,
    uint32_t     depth_or_layers);

// === Multi-device adapter enumeration ===

// Populate out_devices[0..max_count] with retained MTLDevice handles.
// Writes the number of found devices into *out_count (capped at max_count).
// Caller must call metal_bridge_release() on each non-null handle when done.
void metal_bridge_enumerate_devices(
    MetalHandle* out_devices,
    uint32_t     max_count,
    uint32_t*    out_count);

// Device property queries (cheap; no allocation).
uint64_t metal_bridge_device_registry_id(MetalHandle device);
uint32_t metal_bridge_device_is_low_power(MetalHandle device);
uint32_t metal_bridge_device_is_removable(MetalHandle device);
// Write UTF-8 device name (NUL-terminated, truncated to cap) into buf.
void     metal_bridge_device_name(MetalHandle device, char* buf, size_t cap);

// Increment the ARC retain count of a MTLDevice.
// Used when handing a device handle out to a second owner.
void metal_bridge_retain_device(MetalHandle device);

// === Adapter info string ===

// Returns a heap-allocated block holding four NUL-terminated strings packed
// consecutively: vendor, architecture, device, description.
// Caller must free the block with metal_bridge_free_string() when done.
// Returns NULL if the device handle is NULL.
char* metal_bridge_adapter_get_info_string(MetalHandle device);

// Free a string block previously returned by metal_bridge_adapter_get_info_string.
void metal_bridge_free_string(char* str);

// === MTLBinaryArchive pipeline caching (macOS 11+) ===

// Create or open a binary archive at the given file path.
// Returns NULL if MTLBinaryArchive is unavailable (< macOS 11) or path is invalid.
// Returned handle is +1 retained; call metal_bridge_release() when done.
MetalHandle metal_bridge_binary_archive_create(
    MetalHandle device,
    const char* path,
    char*       error_buf,
    size_t      error_cap);

// Legacy Phase 1: best-effort no-op.  Archive priming now happens inside
// metal_bridge_device_new_compute_pipeline_with_archive.  Kept for ABI stability.
uint32_t metal_bridge_binary_archive_add_compute(
    MetalHandle archive,
    MetalHandle device,
    MetalHandle pipeline,
    char*       error_buf,
    size_t      error_cap);

// Legacy Phase 1: best-effort no-op.  Same rationale as add_compute above.
uint32_t metal_bridge_binary_archive_add_render(
    MetalHandle archive,
    MetalHandle device,
    MetalHandle pipeline,
    char*       error_buf,
    size_t      error_cap);

// Persist the archive to the file URL supplied at creation. Returns 1 on success.
uint32_t metal_bridge_binary_archive_serialize(
    MetalHandle archive,
    char*       error_buf,
    size_t      error_cap);

// Compile-or-serve: create a compute pipeline using the archive as binary source.
// On cache hit, returns a pre-compiled PSO (skips shader compilation).
// On cache miss, compiles fresh and records the result into the archive via
// addComputePipelineFunctionsWithDescriptor for future warm starts.
// Returns NULL only on genuine compile failure.
MetalHandle metal_bridge_device_new_compute_pipeline_with_archive(
    MetalHandle device,
    MetalHandle function,
    MetalHandle archive,
    char*       error_buf,
    size_t      error_cap);

// Compile-or-serve for render pipelines. Same semantics as compute above.
// On miss, compiles and primes the archive via addRenderPipelineFunctionsWithDescriptor.
MetalHandle metal_bridge_device_new_render_pipeline_with_archive(
    MetalHandle device,
    uint32_t    pixel_format,
    int         support_icb,
    MetalHandle archive,
    char*       error_buf,
    size_t      error_cap);
