/*
 * doe_napi_init.c — N-API module entry point for the Doe WebGPU addon.
 *
 * Builds the exports object with all public N-API function descriptors and
 * registers the module via NAPI_MODULE. All callback implementations live
 * in the sibling .c files; their prototypes are declared below.
 */

#include "doe_napi_internal.h"

/* ================================================================
 * Forward declarations — napi callbacks defined in sibling .c files
 * ================================================================ */

/* Library loading (doe_napi_globals.c or doe_napi.c) */
napi_value doe_load_library(napi_env env, napi_callback_info info);
napi_value doe_compute_program_contract_version(napi_env env, napi_callback_info info);
napi_value doe_compute_program_prepare(napi_env env, napi_callback_info info);
napi_value doe_compute_program_supported(napi_env env, napi_callback_info info);
napi_value doe_compute_program_timestamp_info(napi_env env, napi_callback_info info);
napi_value doe_compute_program_submit(napi_env env, napi_callback_info info);
napi_value doe_compute_program_release(napi_env env, napi_callback_info info);

/* Native-direct path (doe_napi.c) */
napi_value doe_native_direct_create(napi_env env, napi_callback_info info);

/* Instance (doe_napi_instance.c) */
napi_value doe_create_instance(napi_env env, napi_callback_info info);
napi_value doe_instance_release(napi_env env, napi_callback_info info);
napi_value doe_request_adapter(napi_env env, napi_callback_info info);
napi_value doe_adapter_release(napi_env env, napi_callback_info info);
napi_value doe_adapter_get_info(napi_env env, napi_callback_info info);
napi_value doe_request_device(napi_env env, napi_callback_info info);
napi_value doe_device_release(napi_env env, napi_callback_info info);
napi_value doe_device_get_queue(napi_env env, napi_callback_info info);
napi_value doe_device_set_uncaptured_error_callback(napi_env env, napi_callback_info info);
napi_value doe_device_register_lost_callback(napi_env env, napi_callback_info info);

/* Buffer */
napi_value doe_create_buffer(napi_env env, napi_callback_info info);
napi_value doe_buffer_release(napi_env env, napi_callback_info info);
napi_value doe_buffer_destroy(napi_env env, napi_callback_info info);
napi_value doe_buffer_unmap(napi_env env, napi_callback_info info);
napi_value doe_buffer_map_sync(napi_env env, napi_callback_info info);
napi_value doe_buffer_get_mapped_range(napi_env env, napi_callback_info info);
napi_value doe_buffer_get_staged_range(napi_env env, napi_callback_info info);
napi_value doe_buffer_flush_staged_range(napi_env env, napi_callback_info info);
napi_value doe_buffer_read_copy(napi_env env, napi_callback_info info);
napi_value doe_buffer_map_read_copy_unmap(napi_env env, napi_callback_info info);
napi_value doe_buffer_write_mapped_range(napi_env env, napi_callback_info info);
napi_value doe_buffer_read_indirect_counts(napi_env env, napi_callback_info info);
napi_value doe_buffer_assert_mapped_prefix_f32(napi_env env, napi_callback_info info);
napi_value doe_buffer_get_map_state(napi_env env, napi_callback_info info);

/* Shader module (doe_napi_shader.c) */
napi_value doe_check_shader_source(napi_env env, napi_callback_info info);
napi_value doe_create_shader_module(napi_env env, napi_callback_info info);
napi_value doe_shader_module_release(napi_env env, napi_callback_info info);
napi_value doe_shader_module_get_bindings(napi_env env, napi_callback_info info);
napi_value doe_shader_module_get_bindings_for_entry_point(napi_env env, napi_callback_info info);
napi_value doe_shader_module_get_compilation_info(napi_env env, napi_callback_info info);

/* Compute pipeline */
napi_value doe_create_compute_pipeline(napi_env env, napi_callback_info info);
napi_value doe_compute_pipeline_release(napi_env env, napi_callback_info info);
napi_value doe_compute_pipeline_get_bind_group_layout(napi_env env, napi_callback_info info);

/* Bind group layout / bind group */
napi_value doe_create_bind_group_layout(napi_env env, napi_callback_info info);
napi_value doe_create_buffer_bind_group_layout_flat4(napi_env env, napi_callback_info info);
napi_value doe_bind_group_layout_release(napi_env env, napi_callback_info info);
napi_value doe_create_bind_group(napi_env env, napi_callback_info info);
napi_value doe_create_buffer_bind_group_flat4(napi_env env, napi_callback_info info);
napi_value doe_bind_group_release(napi_env env, napi_callback_info info);

/* Pipeline layout */
napi_value doe_create_pipeline_layout(napi_env env, napi_callback_info info);
napi_value doe_create_pipeline_layout_one(napi_env env, napi_callback_info info);
napi_value doe_pipeline_layout_release(napi_env env, napi_callback_info info);

/* Command encoder / buffer */
napi_value doe_create_command_encoder(napi_env env, napi_callback_info info);
napi_value doe_command_encoder_release(napi_env env, napi_callback_info info);
napi_value doe_command_encoder_copy_buffer_to_buffer(napi_env env, napi_callback_info info);
napi_value doe_command_encoder_copy_buffer_to_texture(napi_env env, napi_callback_info info);
napi_value doe_command_encoder_copy_texture_to_buffer(napi_env env, napi_callback_info info);
napi_value doe_command_encoder_clear_buffer(napi_env env, napi_callback_info info);
napi_value doe_command_encoder_copy_texture_to_texture(napi_env env, napi_callback_info info);
napi_value doe_command_encoder_finish(napi_env env, napi_callback_info info);
napi_value doe_create_compute_dispatch_copy_command_buffer(napi_env env, napi_callback_info info);
napi_value doe_create_compute_dispatch_batch_copy_command_buffer(napi_env env, napi_callback_info info);
napi_value doe_command_buffer_release(napi_env env, napi_callback_info info);
napi_value doe_command_encoder_write_timestamp(napi_env env, napi_callback_info info);
napi_value doe_command_encoder_resolve_query_set(napi_env env, napi_callback_info info);

/* Compute pass */
napi_value doe_begin_compute_pass(napi_env env, napi_callback_info info);
napi_value doe_compute_pass_set_pipeline(napi_env env, napi_callback_info info);
napi_value doe_compute_pass_set_bind_group(napi_env env, napi_callback_info info);
napi_value doe_compute_pass_set_immediates(napi_env env, napi_callback_info info);
napi_value doe_compute_pass_dispatch(napi_env env, napi_callback_info info);
napi_value doe_compute_pass_dispatch_bound(napi_env env, napi_callback_info info);
napi_value doe_compute_pass_dispatch_indirect(napi_env env, napi_callback_info info);
napi_value doe_compute_pass_push_debug_group(napi_env env, napi_callback_info info);
napi_value doe_compute_pass_pop_debug_group(napi_env env, napi_callback_info info);
napi_value doe_compute_pass_insert_debug_marker(napi_env env, napi_callback_info info);
napi_value doe_compute_pass_end(napi_env env, napi_callback_info info);
napi_value doe_compute_pass_release(napi_env env, napi_callback_info info);

/* Queue */
napi_value doe_queue_submit(napi_env env, napi_callback_info info);
napi_value doe_queue_submit_one(napi_env env, napi_callback_info info);
napi_value doe_queue_write_buffer(napi_env env, napi_callback_info info);
napi_value doe_queue_write_buffer_batch(napi_env env, napi_callback_info info);
napi_value doe_queue_write_buffer_batch_data_ptrs(napi_env env, napi_callback_info info);
napi_value doe_queue_write_texture(napi_env env, napi_callback_info info);
napi_value doe_queue_flush(napi_env env, napi_callback_info info);
napi_value doe_queue_submit_batched(napi_env env, napi_callback_info info);
napi_value doe_prewarm_prepared_dispatches(napi_env env, napi_callback_info info);
napi_value doe_queue_submit_compute_dispatch_copy(napi_env env, napi_callback_info info);
napi_value doe_native_fast_path_info(napi_env env, napi_callback_info info);
napi_value doe_queue_sync_info(napi_env env, napi_callback_info info);
napi_value doe_queue_pipeline_cache_info(napi_env env, napi_callback_info info);
napi_value doe_queue_pipeline_cache_flush(napi_env env, napi_callback_info info);
napi_value doe_compute_dispatch_flush_and_map_sync(napi_env env, napi_callback_info info);
napi_value doe_queue_release(napi_env env, napi_callback_info info);

/* Texture / sampler */
napi_value doe_create_texture(napi_env env, napi_callback_info info);
napi_value doe_texture_release(napi_env env, napi_callback_info info);
napi_value doe_texture_create_view(napi_env env, napi_callback_info info);
napi_value doe_texture_view_release(napi_env env, napi_callback_info info);
napi_value doe_create_sampler(napi_env env, napi_callback_info info);
napi_value doe_sampler_release(napi_env env, napi_callback_info info);

/* Render pipeline */
napi_value doe_create_render_pipeline(napi_env env, napi_callback_info info);
napi_value doe_render_pipeline_release(napi_env env, napi_callback_info info);
napi_value doe_render_pipeline_get_bind_group_layout(napi_env env, napi_callback_info info);

/* Canvas surface */
napi_value doe_canvas_surface_create(napi_env env, napi_callback_info info);
napi_value doe_canvas_surface_configure(napi_env env, napi_callback_info info);
napi_value doe_canvas_surface_get_current_texture(napi_env env, napi_callback_info info);
napi_value doe_canvas_surface_present(napi_env env, napi_callback_info info);
napi_value doe_canvas_surface_unconfigure(napi_env env, napi_callback_info info);
napi_value doe_canvas_surface_release(napi_env env, napi_callback_info info);

/* Render pass */
napi_value doe_begin_render_pass(napi_env env, napi_callback_info info);
napi_value doe_render_pass_set_pipeline(napi_env env, napi_callback_info info);
napi_value doe_render_pass_set_bind_group(napi_env env, napi_callback_info info);
napi_value doe_render_pass_set_immediates(napi_env env, napi_callback_info info);
napi_value doe_render_pass_set_vertex_buffer(napi_env env, napi_callback_info info);
napi_value doe_render_pass_set_index_buffer(napi_env env, napi_callback_info info);
napi_value doe_render_pass_draw(napi_env env, napi_callback_info info);
napi_value doe_render_pass_draw_indexed(napi_env env, napi_callback_info info);
napi_value doe_render_pass_execute_bundles(napi_env env, napi_callback_info info);
napi_value doe_render_pass_draw_indirect(napi_env env, napi_callback_info info);
napi_value doe_render_pass_draw_indexed_indirect(napi_env env, napi_callback_info info);
napi_value doe_render_pass_end(napi_env env, napi_callback_info info);
napi_value doe_render_pass_release(napi_env env, napi_callback_info info);
napi_value doe_render_pass_set_viewport(napi_env env, napi_callback_info info);
napi_value doe_render_pass_set_scissor_rect(napi_env env, napi_callback_info info);
napi_value doe_render_pass_set_blend_constant(napi_env env, napi_callback_info info);
napi_value doe_render_pass_set_stencil_reference(napi_env env, napi_callback_info info);
napi_value doe_render_pass_push_debug_group(napi_env env, napi_callback_info info);
napi_value doe_render_pass_pop_debug_group(napi_env env, napi_callback_info info);
napi_value doe_render_pass_insert_debug_marker(napi_env env, napi_callback_info info);

/* Render bundle encoder / bundle */
napi_value doe_create_render_bundle_encoder(napi_env env, napi_callback_info info);
napi_value doe_render_bundle_encoder_set_pipeline(napi_env env, napi_callback_info info);
napi_value doe_render_bundle_encoder_set_bind_group(napi_env env, napi_callback_info info);
napi_value doe_render_bundle_encoder_set_immediates(napi_env env, napi_callback_info info);
napi_value doe_render_bundle_encoder_set_vertex_buffer(napi_env env, napi_callback_info info);
napi_value doe_render_bundle_encoder_set_index_buffer(napi_env env, napi_callback_info info);
napi_value doe_render_bundle_encoder_push_debug_group(napi_env env, napi_callback_info info);
napi_value doe_render_bundle_encoder_pop_debug_group(napi_env env, napi_callback_info info);
napi_value doe_render_bundle_encoder_insert_debug_marker(napi_env env, napi_callback_info info);
napi_value doe_render_bundle_encoder_draw(napi_env env, napi_callback_info info);
napi_value doe_render_bundle_encoder_draw_indexed(napi_env env, napi_callback_info info);
napi_value doe_render_bundle_encoder_draw_indirect(napi_env env, napi_callback_info info);
napi_value doe_render_bundle_encoder_draw_indexed_indirect(napi_env env, napi_callback_info info);
napi_value doe_render_bundle_encoder_finish(napi_env env, napi_callback_info info);
napi_value doe_render_bundle_encoder_release(napi_env env, napi_callback_info info);
napi_value doe_render_bundle_release(napi_env env, napi_callback_info info);

/* Adapter / device capabilities */
napi_value doe_adapter_get_limits(napi_env env, napi_callback_info info);
napi_value doe_adapter_has_feature(napi_env env, napi_callback_info info);
napi_value doe_device_get_limits(napi_env env, napi_callback_info info);
napi_value doe_device_has_feature(napi_env env, napi_callback_info info);
napi_value doe_device_get_label(napi_env env, napi_callback_info info);
napi_value doe_device_set_label(napi_env env, napi_callback_info info);
napi_value doe_object_set_label(napi_env env, napi_callback_info info);

/* Query set */
napi_value doe_device_create_query_set(napi_env env, napi_callback_info info);
napi_value doe_query_set_destroy(napi_env env, napi_callback_info info);

/* Diagnostics / error inspection */
napi_value doe_set_timeout_ms(napi_env env, napi_callback_info info);
napi_value doe_package_pipeline_cache_flush(napi_env env, napi_callback_info info);

/* ================================================================
 * Module initialization
 * ================================================================ */

napi_value doe_module_init(napi_env env, napi_value exports) {
    napi_property_descriptor descriptors[] = {
        EXPORT_FN("loadLibrary",                              doe_load_library),
        EXPORT_FN("nativeDirectCreate",                       doe_native_direct_create),
        EXPORT_FN("createInstance",                           doe_create_instance),
        EXPORT_FN("instanceRelease",                          doe_instance_release),
        EXPORT_FN("requestAdapter",                           doe_request_adapter),
        EXPORT_FN("adapterRelease",                           doe_adapter_release),
        EXPORT_FN("adapterGetInfo",                           doe_adapter_get_info),
        EXPORT_FN("requestDevice",                            doe_request_device),
        EXPORT_FN("deviceRelease",                            doe_device_release),
        EXPORT_FN("deviceGetQueue",                           doe_device_get_queue),
        EXPORT_FN("deviceSetUncapturedErrorCallback",         doe_device_set_uncaptured_error_callback),
        EXPORT_FN("deviceRegisterLostCallback",               doe_device_register_lost_callback),
        EXPORT_FN("createBuffer",                             doe_create_buffer),
        EXPORT_FN("bufferRelease",                            doe_buffer_release),
        EXPORT_FN("bufferDestroy",                            doe_buffer_destroy),
        EXPORT_FN("bufferUnmap",                              doe_buffer_unmap),
        EXPORT_FN("bufferMapSync",                            doe_buffer_map_sync),
        EXPORT_FN("bufferGetMappedRange",                     doe_buffer_get_mapped_range),
        EXPORT_FN("bufferGetStagedRange",                     doe_buffer_get_staged_range),
        EXPORT_FN("bufferFlushStagedRange",                   doe_buffer_flush_staged_range),
        EXPORT_FN("bufferReadCopy",                           doe_buffer_read_copy),
        EXPORT_FN("bufferMapReadCopyUnmap",                   doe_buffer_map_read_copy_unmap),
        EXPORT_FN("bufferWriteMappedRange",                   doe_buffer_write_mapped_range),
        EXPORT_FN("bufferReadIndirectCounts",                 doe_buffer_read_indirect_counts),
        EXPORT_FN("bufferAssertMappedPrefixF32",              doe_buffer_assert_mapped_prefix_f32),
        EXPORT_FN("bufferGetMapState",                        doe_buffer_get_map_state),
        EXPORT_FN("checkShaderSource",                        doe_check_shader_source),
        EXPORT_FN("createShaderModule",                       doe_create_shader_module),
        EXPORT_FN("shaderModuleRelease",                      doe_shader_module_release),
        EXPORT_FN("shaderModuleGetBindings",                  doe_shader_module_get_bindings),
        EXPORT_FN("shaderModuleGetBindingsForEntryPoint",     doe_shader_module_get_bindings_for_entry_point),
        EXPORT_FN("shaderModuleGetCompilationInfo",           doe_shader_module_get_compilation_info),
        EXPORT_FN("createComputePipeline",                    doe_create_compute_pipeline),
        EXPORT_FN("computePipelineRelease",                   doe_compute_pipeline_release),
        EXPORT_FN("computePipelineGetBindGroupLayout",        doe_compute_pipeline_get_bind_group_layout),
        EXPORT_FN("createBindGroupLayout",                    doe_create_bind_group_layout),
        EXPORT_FN("createBufferBindGroupLayoutFlat4",         doe_create_buffer_bind_group_layout_flat4),
        EXPORT_FN("bindGroupLayoutRelease",                   doe_bind_group_layout_release),
        EXPORT_FN("createBindGroup",                          doe_create_bind_group),
        EXPORT_FN("createBufferBindGroupFlat4",               doe_create_buffer_bind_group_flat4),
        EXPORT_FN("bindGroupRelease",                         doe_bind_group_release),
        EXPORT_FN("createPipelineLayout",                     doe_create_pipeline_layout),
        EXPORT_FN("createPipelineLayoutOne",                  doe_create_pipeline_layout_one),
        EXPORT_FN("pipelineLayoutRelease",                    doe_pipeline_layout_release),
        EXPORT_FN("createCommandEncoder",                     doe_create_command_encoder),
        EXPORT_FN("commandEncoderRelease",                    doe_command_encoder_release),
        EXPORT_FN("commandEncoderCopyBufferToBuffer",         doe_command_encoder_copy_buffer_to_buffer),
        EXPORT_FN("commandEncoderCopyBufferToTexture",        doe_command_encoder_copy_buffer_to_texture),
        EXPORT_FN("commandEncoderCopyTextureToBuffer",        doe_command_encoder_copy_texture_to_buffer),
        EXPORT_FN("commandEncoderClearBuffer",                doe_command_encoder_clear_buffer),
        EXPORT_FN("commandEncoderCopyTextureToTexture",       doe_command_encoder_copy_texture_to_texture),
        EXPORT_FN("commandEncoderFinish",                     doe_command_encoder_finish),
        EXPORT_FN("createComputeDispatchCopyCommandBuffer",   doe_create_compute_dispatch_copy_command_buffer),
        EXPORT_FN("createComputeDispatchBatchCopyCommandBuffer", doe_create_compute_dispatch_batch_copy_command_buffer),
        EXPORT_FN("commandBufferRelease",                     doe_command_buffer_release),
        EXPORT_FN("beginComputePass",                         doe_begin_compute_pass),
        EXPORT_FN("computePassSetPipeline",                   doe_compute_pass_set_pipeline),
        EXPORT_FN("computePassSetBindGroup",                  doe_compute_pass_set_bind_group),
        EXPORT_FN("computePassSetImmediates",                 doe_compute_pass_set_immediates),
        EXPORT_FN("computePassDispatchWorkgroups",            doe_compute_pass_dispatch),
        EXPORT_FN("computePassDispatchBound",                 doe_compute_pass_dispatch_bound),
        EXPORT_FN("computePassDispatchWorkgroupsIndirect",    doe_compute_pass_dispatch_indirect),
        EXPORT_FN("computePassPushDebugGroup",                doe_compute_pass_push_debug_group),
        EXPORT_FN("computePassPopDebugGroup",                 doe_compute_pass_pop_debug_group),
        EXPORT_FN("computePassInsertDebugMarker",             doe_compute_pass_insert_debug_marker),
        EXPORT_FN("computePassEnd",                           doe_compute_pass_end),
        EXPORT_FN("computePassRelease",                       doe_compute_pass_release),
        EXPORT_FN("queueSubmit",                              doe_queue_submit),
        EXPORT_FN("queueSubmitOne",                           doe_queue_submit_one),
        EXPORT_FN("queueWriteBuffer",                         doe_queue_write_buffer),
        EXPORT_FN("queueWriteBufferBatch",                    doe_queue_write_buffer_batch),
        EXPORT_FN("queueWriteBufferBatchDataPtrs",            doe_queue_write_buffer_batch_data_ptrs),
        EXPORT_FN("queueWriteTexture",                        doe_queue_write_texture),
        EXPORT_FN("queueFlush",                               doe_queue_flush),
        EXPORT_FN("submitBatched",                            doe_queue_submit_batched),
        EXPORT_FN("prewarmPreparedDispatches",                 doe_prewarm_prepared_dispatches),
        EXPORT_FN("submitComputeDispatchCopy",                doe_queue_submit_compute_dispatch_copy),
        EXPORT_FN("nativeFastPathInfo",                       doe_native_fast_path_info),
        EXPORT_FN("queueSyncInfo",                            doe_queue_sync_info),
        EXPORT_FN("queuePipelineCacheInfo",                   doe_queue_pipeline_cache_info),
        EXPORT_FN("queuePipelineCacheFlush",                  doe_queue_pipeline_cache_flush),
        EXPORT_FN("flushAndMapSync",                          doe_compute_dispatch_flush_and_map_sync),
        EXPORT_FN("queueRelease",                             doe_queue_release),
        EXPORT_FN("createTexture",                            doe_create_texture),
        EXPORT_FN("textureRelease",                           doe_texture_release),
        EXPORT_FN("textureCreateView",                        doe_texture_create_view),
        EXPORT_FN("textureViewRelease",                       doe_texture_view_release),
        EXPORT_FN("createSampler",                            doe_create_sampler),
        EXPORT_FN("samplerRelease",                           doe_sampler_release),
        EXPORT_FN("canvasSurfaceCreate",                      doe_canvas_surface_create),
        EXPORT_FN("canvasSurfaceConfigure",                   doe_canvas_surface_configure),
        EXPORT_FN("canvasSurfaceGetCurrentTexture",           doe_canvas_surface_get_current_texture),
        EXPORT_FN("canvasSurfacePresent",                     doe_canvas_surface_present),
        EXPORT_FN("canvasSurfaceUnconfigure",                 doe_canvas_surface_unconfigure),
        EXPORT_FN("canvasSurfaceRelease",                     doe_canvas_surface_release),
        EXPORT_FN("createRenderPipeline",                     doe_create_render_pipeline),
        EXPORT_FN("renderPipelineRelease",                    doe_render_pipeline_release),
        EXPORT_FN("renderPipelineGetBindGroupLayout",         doe_render_pipeline_get_bind_group_layout),
        EXPORT_FN("beginRenderPass",                          doe_begin_render_pass),
        EXPORT_FN("renderPassSetPipeline",                    doe_render_pass_set_pipeline),
        EXPORT_FN("renderPassSetBindGroup",                   doe_render_pass_set_bind_group),
        EXPORT_FN("renderPassSetImmediates",                  doe_render_pass_set_immediates),
        EXPORT_FN("renderPassSetVertexBuffer",                doe_render_pass_set_vertex_buffer),
        EXPORT_FN("renderPassSetIndexBuffer",                 doe_render_pass_set_index_buffer),
        EXPORT_FN("renderPassDraw",                           doe_render_pass_draw),
        EXPORT_FN("renderPassDrawIndexed",                    doe_render_pass_draw_indexed),
        EXPORT_FN("renderPassExecuteBundles",                 doe_render_pass_execute_bundles),
        EXPORT_FN("renderPassDrawIndirect",                   doe_render_pass_draw_indirect),
        EXPORT_FN("renderPassDrawIndexedIndirect",            doe_render_pass_draw_indexed_indirect),
        EXPORT_FN("renderPassEnd",                            doe_render_pass_end),
        EXPORT_FN("renderPassRelease",                        doe_render_pass_release),
        EXPORT_FN("renderPassSetViewport",                    doe_render_pass_set_viewport),
        EXPORT_FN("renderPassSetScissorRect",                 doe_render_pass_set_scissor_rect),
        EXPORT_FN("renderPassSetBlendConstant",               doe_render_pass_set_blend_constant),
        EXPORT_FN("renderPassSetStencilReference",            doe_render_pass_set_stencil_reference),
        EXPORT_FN("renderPassPushDebugGroup",                 doe_render_pass_push_debug_group),
        EXPORT_FN("renderPassPopDebugGroup",                  doe_render_pass_pop_debug_group),
        EXPORT_FN("renderPassInsertDebugMarker",              doe_render_pass_insert_debug_marker),
        EXPORT_FN("createRenderBundleEncoder",                doe_create_render_bundle_encoder),
        EXPORT_FN("renderBundleEncoderSetPipeline",           doe_render_bundle_encoder_set_pipeline),
        EXPORT_FN("renderBundleEncoderSetBindGroup",          doe_render_bundle_encoder_set_bind_group),
        EXPORT_FN("renderBundleEncoderSetImmediates",         doe_render_bundle_encoder_set_immediates),
        EXPORT_FN("renderBundleEncoderSetVertexBuffer",       doe_render_bundle_encoder_set_vertex_buffer),
        EXPORT_FN("renderBundleEncoderSetIndexBuffer",        doe_render_bundle_encoder_set_index_buffer),
        EXPORT_FN("renderBundleEncoderDraw",                  doe_render_bundle_encoder_draw),
        EXPORT_FN("renderBundleEncoderDrawIndexed",           doe_render_bundle_encoder_draw_indexed),
        EXPORT_FN("renderBundleEncoderDrawIndirect",          doe_render_bundle_encoder_draw_indirect),
        EXPORT_FN("renderBundleEncoderDrawIndexedIndirect",   doe_render_bundle_encoder_draw_indexed_indirect),
        EXPORT_FN("renderBundleEncoderPushDebugGroup",        doe_render_bundle_encoder_push_debug_group),
        EXPORT_FN("renderBundleEncoderPopDebugGroup",         doe_render_bundle_encoder_pop_debug_group),
        EXPORT_FN("renderBundleEncoderInsertDebugMarker",     doe_render_bundle_encoder_insert_debug_marker),
        EXPORT_FN("renderBundleEncoderFinish",                doe_render_bundle_encoder_finish),
        EXPORT_FN("renderBundleEncoderRelease",               doe_render_bundle_encoder_release),
        EXPORT_FN("renderBundleRelease",                      doe_render_bundle_release),
        EXPORT_FN("adapterGetLimits",                         doe_adapter_get_limits),
        EXPORT_FN("adapterHasFeature",                        doe_adapter_has_feature),
        EXPORT_FN("deviceGetLimits",                          doe_device_get_limits),
        EXPORT_FN("nativeComputeProgramContractVersion",       doe_compute_program_contract_version),
        EXPORT_FN("computeProgramPrepare",                    doe_compute_program_prepare),
        EXPORT_FN("computeProgramSupported",                  doe_compute_program_supported),
        EXPORT_FN("computeProgramTimestampInfo",              doe_compute_program_timestamp_info),
        EXPORT_FN("computeProgramSubmit",                     doe_compute_program_submit),
        EXPORT_FN("computeProgramRelease",                    doe_compute_program_release),
        EXPORT_FN("deviceHasFeature",                         doe_device_has_feature),
        EXPORT_FN("deviceGetLabel",                           doe_device_get_label),
        EXPORT_FN("deviceSetLabel",                           doe_device_set_label),
        EXPORT_FN("objectSetLabel",                           doe_object_set_label),
        EXPORT_FN("createQuerySet",                           doe_device_create_query_set),
        EXPORT_FN("commandEncoderWriteTimestamp",             doe_command_encoder_write_timestamp),
        EXPORT_FN("commandEncoderResolveQuerySet",            doe_command_encoder_resolve_query_set),
        EXPORT_FN("querySetDestroy",                          doe_query_set_destroy),
        EXPORT_FN("setTimeoutMs",                             doe_set_timeout_ms),
        EXPORT_FN("packagePipelineCacheFlush",                doe_package_pipeline_cache_flush),
    };

    size_t count = sizeof(descriptors) / sizeof(descriptors[0]);
    napi_define_properties(env, exports, count, descriptors);
    return exports;
}

NAPI_MODULE(NODE_GYP_MODULE_NAME, doe_module_init)
