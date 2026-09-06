#include "doe_napi_internal.h"

typedef void (*FnWgpuComputePassEncoderPushDebugGroup)(WGPUComputePassEncoder, WGPUStringView);
typedef void (*FnWgpuComputePassEncoderPopDebugGroup)(WGPUComputePassEncoder);
typedef void (*FnWgpuComputePassEncoderInsertDebugMarker)(WGPUComputePassEncoder, WGPUStringView);
typedef void (*FnWgpuRenderPassEncoderDrawIndirect)(WGPURenderPassEncoder, WGPUBuffer, uint64_t);
typedef void (*FnWgpuRenderPassEncoderDrawIndexedIndirect)(WGPURenderPassEncoder, WGPUBuffer, uint64_t);

static FnWgpuComputePassEncoderPushDebugGroup resolve_wgpu_compute_pass_push_debug_group(void) {
    static FnWgpuComputePassEncoderPushDebugGroup fn = NULL;
    static bool loaded = false;
    if (!loaded) {
        loaded = true;
        fn = g_lib ? (FnWgpuComputePassEncoderPushDebugGroup)LIB_SYM(g_lib, "wgpuComputePassEncoderPushDebugGroup") : NULL;
    }
    return fn;
}

static FnWgpuComputePassEncoderPopDebugGroup resolve_wgpu_compute_pass_pop_debug_group(void) {
    static FnWgpuComputePassEncoderPopDebugGroup fn = NULL;
    static bool loaded = false;
    if (!loaded) {
        loaded = true;
        fn = g_lib ? (FnWgpuComputePassEncoderPopDebugGroup)LIB_SYM(g_lib, "wgpuComputePassEncoderPopDebugGroup") : NULL;
    }
    return fn;
}

static FnWgpuComputePassEncoderInsertDebugMarker resolve_wgpu_compute_pass_insert_debug_marker(void) {
    static FnWgpuComputePassEncoderInsertDebugMarker fn = NULL;
    static bool loaded = false;
    if (!loaded) {
        loaded = true;
        fn = g_lib ? (FnWgpuComputePassEncoderInsertDebugMarker)LIB_SYM(g_lib, "wgpuComputePassEncoderInsertDebugMarker") : NULL;
    }
    return fn;
}

static FnWgpuRenderPassEncoderDrawIndirect resolve_wgpu_render_pass_draw_indirect(void) {
    static FnWgpuRenderPassEncoderDrawIndirect fn = NULL;
    static bool loaded = false;
    if (!loaded) {
        loaded = true;
        fn = g_lib ? (FnWgpuRenderPassEncoderDrawIndirect)LIB_SYM(g_lib, "wgpuRenderPassEncoderDrawIndirect") : NULL;
    }
    return fn;
}

static FnWgpuRenderPassEncoderDrawIndexedIndirect resolve_wgpu_render_pass_draw_indexed_indirect(void) {
    static FnWgpuRenderPassEncoderDrawIndexedIndirect fn = NULL;
    static bool loaded = false;
    if (!loaded) {
        loaded = true;
        fn = g_lib ? (FnWgpuRenderPassEncoderDrawIndexedIndirect)LIB_SYM(g_lib, "wgpuRenderPassEncoderDrawIndexedIndirect") : NULL;
    }
    return fn;
}

napi_value native_direct_command_encoder_begin_compute_pass(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    NativeDirectHandleCache* encoder_cache = native_direct_get_handle_cache(env, this_arg);
    WGPUCommandEncoder encoder = encoder_cache ? (WGPUCommandEncoder)encoder_cache->native : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
    if (!encoder) NAPI_THROW(env, "Invalid encoder");
    char* label = NULL;
    size_t label_len = 0;
    WGPUComputePassTimestampWrites ts_writes = {0};
    WGPUComputePassTimestampWrites* ts_writes_ptr = NULL;
    if (argc >= 1) {
        napi_valuetype desc_type = napi_undefined;
        if (napi_typeof(env, argv[0], &desc_type) == napi_ok && desc_type == napi_object) {
            if (has_prop(env, argv[0], "label") && prop_type(env, argv[0], "label") == napi_string) {
                label = dup_string_value(env, get_prop(env, argv[0], "label"), &label_len);
                if (!label) NAPI_THROW(env, "beginComputePass: out of memory while reading label");
            }
            if (has_prop(env, argv[0], "timestampWrites") && prop_type(env, argv[0], "timestampWrites") == napi_object) {
                napi_value tw = get_prop(env, argv[0], "timestampWrites");
                ts_writes.querySet = native_direct_unwrap_external_prop(env, get_prop(env, tw, "querySet"), DOE_DIRECT_NATIVE);
                ts_writes.beginningOfPassWriteIndex = get_uint32_prop(env, tw, "beginningOfPassWriteIndex");
                ts_writes.endOfPassWriteIndex = get_uint32_prop(env, tw, "endOfPassWriteIndex");
                ts_writes_ptr = &ts_writes;
            }
        }
    }
    WGPUComputePassDescriptor desc = {
        .nextInChain = NULL,
        .label = { .data = label, .length = label ? label_len : 0 },
        .timestampWrites = ts_writes_ptr,
    };
    WGPUComputePassEncoder pass = pfn_wgpuCommandEncoderBeginComputePass(encoder, &desc);
    free(label);
    if (!pass) NAPI_THROW(env, "beginComputePass failed");
    return create_native_direct_compute_pass_object(env, pass);
}

napi_value native_direct_command_encoder_copy_buffer_to_buffer(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value argv[5];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    if (argc < 5) NAPI_THROW(env, "copyBufferToBuffer requires source, sourceOffset, target, targetOffset, and size");
    NativeDirectHandleCache* encoder_cache = native_direct_get_handle_cache(env, this_arg);
    NativeDirectBufferCache* src_cache = native_direct_get_buffer_cache(env, argv[0]);
    NativeDirectBufferCache* dst_cache = native_direct_get_buffer_cache(env, argv[2]);
    WGPUCommandEncoder encoder = encoder_cache ? (WGPUCommandEncoder)encoder_cache->native : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
    WGPUBuffer src = src_cache ? src_cache->buffer : native_direct_unwrap_external_prop(env, argv[0], DOE_DIRECT_NATIVE);
    WGPUBuffer dst = dst_cache ? dst_cache->buffer : native_direct_unwrap_external_prop(env, argv[2], DOE_DIRECT_NATIVE);
    int64_t src_offset = 0;
    int64_t dst_offset = 0;
    int64_t size = 0;
    if (!encoder || !src || !dst) NAPI_THROW(env, "copyBufferToBuffer requires encoder and buffers");
    napi_get_value_int64(env, argv[1], &src_offset);
    napi_get_value_int64(env, argv[3], &dst_offset);
    napi_get_value_int64(env, argv[4], &size);
    pfn_wgpuCommandEncoderCopyBufferToBuffer(encoder, src, (uint64_t)src_offset, dst, (uint64_t)dst_offset, (uint64_t)size);
    return NULL;
}

napi_value native_direct_command_encoder_finish(napi_env env, napi_callback_info info) {
    size_t argc = 0;
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, NULL, &this_arg, NULL);
    NativeDirectHandleCache* encoder_cache = native_direct_get_handle_cache(env, this_arg);
    WGPUCommandEncoder encoder = encoder_cache ? (WGPUCommandEncoder)encoder_cache->native : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
    if (!encoder) NAPI_THROW(env, "Invalid encoder");
    WGPUCommandBufferDescriptor desc = {
        .nextInChain = NULL,
        .label = { .data = NULL, .length = 0 },
    };
    WGPUCommandBuffer command_buffer = pfn_wgpuCommandEncoderFinish(encoder, &desc);
    if (!command_buffer) NAPI_THROW(env, "commandEncoderFinish failed");
    pfn_wgpuCommandEncoderRelease(encoder);
    native_direct_set_external_prop(env, this_arg, DOE_DIRECT_NATIVE, NULL);
    if (encoder_cache) encoder_cache->native = NULL;
    return create_native_direct_command_buffer_object(env, command_buffer);
}

/* GPUCommandEncoder.clearBuffer(buffer, offset?, size?)
 * argv[0]: GPUBuffer, argv[1]: offset (optional, default 0), argv[2]: size (optional, default WGPU_WHOLE_SIZE) */
napi_value native_direct_command_encoder_clear_buffer(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    if (argc < 1) NAPI_THROW(env, "clearBuffer requires a buffer");
    NativeDirectHandleCache* enc_cache = native_direct_get_handle_cache(env, this_arg);
    NativeDirectBufferCache* buf_cache = native_direct_get_buffer_cache(env, argv[0]);
    void* encoder = enc_cache ? enc_cache->native : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
    void* buffer = buf_cache ? buf_cache->buffer : native_direct_unwrap_external_prop(env, argv[0], DOE_DIRECT_NATIVE);
    if (!encoder || !buffer) NAPI_THROW(env, "clearBuffer: invalid encoder or buffer");
    uint64_t offset = 0;
    uint64_t size = UINT64_MAX; /* WGPU_WHOLE_SIZE */
    if (argc >= 2 && argv[1]) {
        int64_t v = 0;
        napi_get_value_int64(env, argv[1], &v);
        if (v > 0) offset = (uint64_t)v;
    }
    if (argc >= 3 && argv[2]) {
        int64_t v = 0;
        napi_get_value_int64(env, argv[2], &v);
        if (v > 0) size = (uint64_t)v;
    }
    if (pfn_doeNativeCommandEncoderClearBuffer) {
        pfn_doeNativeCommandEncoderClearBuffer(encoder, buffer, offset, size);
    }
    napi_value undefined_value;
    napi_get_undefined(env, &undefined_value);
    return undefined_value;
}

/* GPUCommandEncoder.copyTextureToTexture(source, destination, copySize) */
napi_value native_direct_command_encoder_copy_texture_to_texture(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    if (argc < 3) NAPI_THROW(env, "copyTextureToTexture requires source, destination, and copySize");
    NativeDirectHandleCache* enc_cache = native_direct_get_handle_cache(env, this_arg);
    void* encoder = enc_cache ? enc_cache->native : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
    if (!encoder) NAPI_THROW(env, "copyTextureToTexture: invalid encoder");
    napi_value src_tex_obj = get_prop(env, argv[0], "texture");
    napi_value dst_tex_obj = get_prop(env, argv[1], "texture");
    void* src_texture = native_direct_unwrap_external_prop(env, src_tex_obj, DOE_DIRECT_NATIVE);
    void* dst_texture = native_direct_unwrap_external_prop(env, dst_tex_obj, DOE_DIRECT_NATIVE);
    if (!src_texture || !dst_texture) NAPI_THROW(env, "copyTextureToTexture: invalid source or destination texture");
    napi_value src_origin_val, dst_origin_val;
    napi_valuetype src_origin_type, dst_origin_type, size_type;
    uint32_t src_mip = 0, dst_mip = 0;
    uint32_t src_x = 0, src_y = 0, src_z = 0;
    uint32_t dst_x = 0, dst_y = 0, dst_z = 0;
    uint32_t src_aspect = 0, dst_aspect = 0;
    uint32_t width = 1, height = 1, depth_or_layers = 1;
    /* mipLevel */
    napi_value tmp;
    if (napi_get_named_property(env, argv[0], "mipLevel", &tmp) == napi_ok) napi_get_value_uint32(env, tmp, &src_mip);
    if (napi_get_named_property(env, argv[1], "mipLevel", &tmp) == napi_ok) napi_get_value_uint32(env, tmp, &dst_mip);
    /* origin */
    napi_get_named_property(env, argv[0], "origin", &src_origin_val);
    napi_get_named_property(env, argv[1], "origin", &dst_origin_val);
    napi_typeof(env, src_origin_val, &src_origin_type);
    napi_typeof(env, dst_origin_val, &dst_origin_type);
    if (src_origin_type == napi_object) {
        napi_value x, y, z;
        napi_get_named_property(env, src_origin_val, "x", &x); napi_get_value_uint32(env, x, &src_x);
        napi_get_named_property(env, src_origin_val, "y", &y); napi_get_value_uint32(env, y, &src_y);
        napi_get_named_property(env, src_origin_val, "z", &z); napi_get_value_uint32(env, z, &src_z);
        if (napi_get_named_property(env, src_origin_val, "aspect", &tmp) == napi_ok) napi_get_value_uint32(env, tmp, &src_aspect);
    }
    if (dst_origin_type == napi_object) {
        napi_value x, y, z;
        napi_get_named_property(env, dst_origin_val, "x", &x); napi_get_value_uint32(env, x, &dst_x);
        napi_get_named_property(env, dst_origin_val, "y", &y); napi_get_value_uint32(env, y, &dst_y);
        napi_get_named_property(env, dst_origin_val, "z", &z); napi_get_value_uint32(env, z, &dst_z);
        if (napi_get_named_property(env, dst_origin_val, "aspect", &tmp) == napi_ok) napi_get_value_uint32(env, tmp, &dst_aspect);
    }
    /* copySize */
    napi_typeof(env, argv[2], &size_type);
    if (size_type == napi_object) {
        napi_value w, h, d;
        napi_get_named_property(env, argv[2], "width", &w); napi_get_value_uint32(env, w, &width);
        napi_get_named_property(env, argv[2], "height", &h); napi_get_value_uint32(env, h, &height);
        napi_get_named_property(env, argv[2], "depthOrArrayLayers", &d); napi_get_value_uint32(env, d, &depth_or_layers);
        if (depth_or_layers == 0) depth_or_layers = 1;
    }
    if (pfn_wgpuCommandEncoderCopyTextureToTexture) {
        WGPUTexelCopyTextureInfo src;
        WGPUTexelCopyTextureInfo dst;
        WGPUExtent3D copy_size;
        memset(&src, 0, sizeof(src)); memset(&dst, 0, sizeof(dst));
        src.texture = src_texture; src.mipLevel = src_mip;
        src.origin.x = src_x; src.origin.y = src_y; src.origin.z = src_z;
        src.aspect = src_aspect;
        dst.texture = dst_texture; dst.mipLevel = dst_mip;
        dst.origin.x = dst_x; dst.origin.y = dst_y; dst.origin.z = dst_z;
        dst.aspect = dst_aspect;
        copy_size.width = width; copy_size.height = height; copy_size.depthOrArrayLayers = depth_or_layers;
        pfn_wgpuCommandEncoderCopyTextureToTexture(encoder, &src, &dst, &copy_size);
    } else if (pfn_doeNativeCommandEncoderCopyTextureToTexture) {
        pfn_doeNativeCommandEncoderCopyTextureToTexture(
            encoder,
            src_texture, src_mip, 0, src_x, src_y, src_z,
            dst_texture, dst_mip, 0, dst_x, dst_y, dst_z,
            width, height, depth_or_layers);
    }
    napi_value undefined_value;
    napi_get_undefined(env, &undefined_value);
    return undefined_value;
}

napi_value native_direct_compute_pass_set_pipeline(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    if (argc < 1) NAPI_THROW(env, "setPipeline requires a pipeline");
    NativeDirectHandleCache* pass_cache = native_direct_get_handle_cache(env, this_arg);
    NativeDirectHandleCache* pipeline_cache = native_direct_get_handle_cache(env, argv[0]);
    WGPUComputePassEncoder pass = pass_cache ? (WGPUComputePassEncoder)pass_cache->native : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
    WGPUComputePipeline pipeline = pipeline_cache ? (WGPUComputePipeline)pipeline_cache->native : native_direct_unwrap_external_prop(env, argv[0], DOE_DIRECT_NATIVE);
    pfn_wgpuComputePassEncoderSetPipeline(pass, pipeline);
    return NULL;
}

napi_value native_direct_compute_pass_set_bind_group(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    if (argc < 2) NAPI_THROW(env, "setBindGroup requires an index and bind group");
    NativeDirectHandleCache* pass_cache = native_direct_get_handle_cache(env, this_arg);
    NativeDirectHandleCache* bind_group_cache = native_direct_get_handle_cache(env, argv[1]);
    WGPUComputePassEncoder pass = pass_cache ? (WGPUComputePassEncoder)pass_cache->native : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
    WGPUBindGroup bind_group = bind_group_cache ? (WGPUBindGroup)bind_group_cache->native : native_direct_unwrap_external_prop(env, argv[1], DOE_DIRECT_NATIVE);
    uint32_t index = 0;
    napi_get_value_uint32(env, argv[0], &index);
    pfn_wgpuComputePassEncoderSetBindGroup(pass, index, bind_group, 0, NULL);
    return NULL;
}

napi_value native_direct_compute_pass_dispatch_workgroups(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    if (argc < 1) NAPI_THROW(env, "dispatchWorkgroups requires x");
    NativeDirectHandleCache* pass_cache = native_direct_get_handle_cache(env, this_arg);
    WGPUComputePassEncoder pass = pass_cache ? (WGPUComputePassEncoder)pass_cache->native : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
    uint32_t x = 1, y = 1, z = 1;
    napi_get_value_uint32(env, argv[0], &x);
    if (argc >= 2 && argv[1]) napi_get_value_uint32(env, argv[1], &y);
    if (argc >= 3 && argv[2]) napi_get_value_uint32(env, argv[2], &z);
    pfn_wgpuComputePassEncoderDispatchWorkgroups(pass, x, y, z);
    return NULL;
}

napi_value native_direct_compute_pass_dispatch_workgroups_indirect(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    if (argc < 1) NAPI_THROW(env, "dispatchWorkgroupsIndirect requires a buffer");
    NativeDirectHandleCache* pass_cache = native_direct_get_handle_cache(env, this_arg);
    NativeDirectBufferCache* buffer_cache = native_direct_get_buffer_cache(env, argv[0]);
    WGPUComputePassEncoder pass = pass_cache ? (WGPUComputePassEncoder)pass_cache->native : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
    WGPUBuffer buffer = buffer_cache ? buffer_cache->buffer : native_direct_unwrap_external_prop(env, argv[0], DOE_DIRECT_NATIVE);
    int64_t offset = 0;
    if (argc >= 2 && argv[1]) napi_get_value_int64(env, argv[1], &offset);
    if (pfn_doeNativeComputePassDispatchIndirect) {
        pfn_doeNativeComputePassDispatchIndirect(pass, buffer, (uint64_t)offset);
    } else {
        pfn_wgpuComputePassEncoderDispatchWorkgroupsIndirect(pass, buffer, (uint64_t)offset);
    }
    napi_value undefined_value;
    napi_get_undefined(env, &undefined_value);
    return undefined_value;
}

/* GPUBindingCommandsMixin#setImmediates — registered on compute pass encoders */
napi_value native_direct_compute_pass_set_immediates(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    if (argc < 2) NAPI_THROW(env, "setImmediates requires index and data");
    uint32_t index = 0;
    napi_get_value_uint32(env, argv[0], &index);
    void* data_ptr = NULL;
    size_t data_len = 0;
    extract_buffer_data(env, argv[1], &data_ptr, &data_len);
    if (pfn_doeNativeComputePassSetImmediates) {
        NativeDirectHandleCache* pass_cache = native_direct_get_handle_cache(env, this_arg);
        void* pass = pass_cache ? pass_cache->native : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
        pfn_doeNativeComputePassSetImmediates(pass, index, (const uint8_t*)data_ptr, data_len);
    }
    /* When pfn is NULL the C side has not been delivered yet; silently no-op
     * so JS callers don't crash during the transition period. */
    napi_value undefined_value;
    napi_get_undefined(env, &undefined_value);
    return undefined_value;
}

napi_value native_direct_compute_pass_push_debug_group(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    if (argc < 1) NAPI_THROW(env, "pushDebugGroup requires groupLabel");
    FnWgpuComputePassEncoderPushDebugGroup fn = resolve_wgpu_compute_pass_push_debug_group();
    if (!fn) NAPI_THROW(env, "computePassPushDebugGroup not available");
    NativeDirectHandleCache* cache = native_direct_get_handle_cache(env, this_arg);
    WGPUComputePassEncoder pass = cache ? (WGPUComputePassEncoder)cache->native : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
    if (!pass) NAPI_THROW(env, "Invalid compute pass");
    size_t label_len = 0;
    napi_get_value_string_utf8(env, argv[0], NULL, 0, &label_len);
    char* label = (char*)malloc(label_len + 1);
    if (!label) NAPI_THROW(env, "computePassPushDebugGroup: out of memory");
    napi_get_value_string_utf8(env, argv[0], label, label_len + 1, &label_len);
    fn(pass, (WGPUStringView){ .data = label, .length = label_len });
    free(label);
    napi_value undefined_value;
    napi_get_undefined(env, &undefined_value);
    return undefined_value;
}

napi_value native_direct_compute_pass_pop_debug_group(napi_env env, napi_callback_info info) {
    size_t argc = 0;
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, NULL, &this_arg, NULL);
    FnWgpuComputePassEncoderPopDebugGroup fn = resolve_wgpu_compute_pass_pop_debug_group();
    if (!fn) NAPI_THROW(env, "computePassPopDebugGroup not available");
    NativeDirectHandleCache* cache = native_direct_get_handle_cache(env, this_arg);
    WGPUComputePassEncoder pass = cache ? (WGPUComputePassEncoder)cache->native : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
    if (!pass) NAPI_THROW(env, "Invalid compute pass");
    fn(pass);
    napi_value undefined_value;
    napi_get_undefined(env, &undefined_value);
    return undefined_value;
}

napi_value native_direct_compute_pass_insert_debug_marker(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    if (argc < 1) NAPI_THROW(env, "insertDebugMarker requires markerLabel");
    FnWgpuComputePassEncoderInsertDebugMarker fn = resolve_wgpu_compute_pass_insert_debug_marker();
    if (!fn) NAPI_THROW(env, "computePassInsertDebugMarker not available");
    NativeDirectHandleCache* cache = native_direct_get_handle_cache(env, this_arg);
    WGPUComputePassEncoder pass = cache ? (WGPUComputePassEncoder)cache->native : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
    if (!pass) NAPI_THROW(env, "Invalid compute pass");
    size_t label_len = 0;
    napi_get_value_string_utf8(env, argv[0], NULL, 0, &label_len);
    char* label = (char*)malloc(label_len + 1);
    if (!label) NAPI_THROW(env, "computePassInsertDebugMarker: out of memory");
    napi_get_value_string_utf8(env, argv[0], label, label_len + 1, &label_len);
    fn(pass, (WGPUStringView){ .data = label, .length = label_len });
    free(label);
    napi_value undefined_value;
    napi_get_undefined(env, &undefined_value);
    return undefined_value;
}

napi_value native_direct_compute_pass_end(napi_env env, napi_callback_info info) {
    size_t argc = 0;
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, NULL, &this_arg, NULL);
    NativeDirectHandleCache* pass_cache = native_direct_get_handle_cache(env, this_arg);
    WGPUComputePassEncoder pass = pass_cache ? (WGPUComputePassEncoder)pass_cache->native : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
    pfn_wgpuComputePassEncoderEnd(pass);
    pfn_wgpuComputePassEncoderRelease(pass);
    native_direct_set_external_prop(env, this_arg, DOE_DIRECT_NATIVE, NULL);
    if (pass_cache) pass_cache->native = NULL;
    napi_value undefined_value;
    napi_get_undefined(env, &undefined_value);
    return undefined_value;
}

/* GPURenderPassEncoder#setImmediates */
napi_value native_direct_render_pass_set_immediates(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    if (argc < 2) NAPI_THROW(env, "setImmediates requires index and data");
    uint32_t index = 0;
    napi_get_value_uint32(env, argv[0], &index);
    void* data_ptr = NULL;
    size_t data_len = 0;
    extract_buffer_data(env, argv[1], &data_ptr, &data_len);
    if (pfn_doeNativeRenderPassSetImmediates) {
        NativeDirectHandleCache* pass_cache = native_direct_get_handle_cache(env, this_arg);
        void* pass = pass_cache ? pass_cache->native : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
        pfn_doeNativeRenderPassSetImmediates(pass, index, (const uint8_t*)data_ptr, data_len);
    }
    napi_value undefined_value;
    napi_get_undefined(env, &undefined_value);
    return undefined_value;
}

/* GPURenderBundleEncoder#setImmediates */
napi_value native_direct_render_bundle_encoder_set_immediates(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    if (argc < 2) NAPI_THROW(env, "setImmediates requires index and data");
    uint32_t index = 0;
    napi_get_value_uint32(env, argv[0], &index);
    void* data_ptr = NULL;
    size_t data_len = 0;
    extract_buffer_data(env, argv[1], &data_ptr, &data_len);
    if (pfn_doeNativeRenderBundleEncoderSetImmediates) {
        NativeDirectHandleCache* enc_cache = native_direct_get_handle_cache(env, this_arg);
        void* enc = enc_cache ? enc_cache->native : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
        pfn_doeNativeRenderBundleEncoderSetImmediates(enc, index, (const uint8_t*)data_ptr, data_len);
    }
    napi_value undefined_value;
    napi_get_undefined(env, &undefined_value);
    return undefined_value;
}

/* GPURenderPassEncoder#setViewport(x, y, width, height, minDepth, maxDepth) */
napi_value native_direct_render_pass_set_viewport(napi_env env, napi_callback_info info) {
    size_t argc = 6;
    napi_value argv[6];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    if (argc < 6) NAPI_THROW(env, "setViewport requires x, y, width, height, minDepth, maxDepth");
    double x = 0, y = 0, width = 0, height = 0, min_depth = 0, max_depth = 1;
    napi_get_value_double(env, argv[0], &x);
    napi_get_value_double(env, argv[1], &y);
    napi_get_value_double(env, argv[2], &width);
    napi_get_value_double(env, argv[3], &height);
    napi_get_value_double(env, argv[4], &min_depth);
    napi_get_value_double(env, argv[5], &max_depth);
    if (pfn_doeNativeRenderPassSetViewport) {
        NativeDirectHandleCache* cache = native_direct_get_handle_cache(env, this_arg);
        void* pass = cache ? cache->native : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
        pfn_doeNativeRenderPassSetViewport(pass, x, y, width, height, min_depth, max_depth);
    }
    napi_value undefined_value;
    napi_get_undefined(env, &undefined_value);
    return undefined_value;
}

/* GPURenderPassEncoder#setScissorRect(x, y, width, height) */
napi_value native_direct_render_pass_set_scissor_rect(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value argv[4];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    if (argc < 4) NAPI_THROW(env, "setScissorRect requires x, y, width, height");
    uint32_t x = 0, y = 0, width = 0, height = 0;
    napi_get_value_uint32(env, argv[0], &x);
    napi_get_value_uint32(env, argv[1], &y);
    napi_get_value_uint32(env, argv[2], &width);
    napi_get_value_uint32(env, argv[3], &height);
    if (pfn_doeNativeRenderPassSetScissorRect) {
        NativeDirectHandleCache* cache = native_direct_get_handle_cache(env, this_arg);
        void* pass = cache ? cache->native : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
        pfn_doeNativeRenderPassSetScissorRect(pass, x, y, width, height);
    }
    napi_value undefined_value;
    napi_get_undefined(env, &undefined_value);
    return undefined_value;
}

/* GPURenderPassEncoder#setBlendConstant(color) — color: {r,g,b,a} or [r,g,b,a] */
napi_value native_direct_render_pass_set_blend_constant(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    if (argc < 1) NAPI_THROW(env, "setBlendConstant requires a color argument");
    double r = 0, g = 0, b = 0, a = 1;
    napi_valuetype vt;
    napi_typeof(env, argv[0], &vt);
    if (vt == napi_object) {
        napi_value tmp;
        bool is_array = false;
        napi_is_array(env, argv[0], &is_array);
        if (is_array) {
            napi_get_element(env, argv[0], 0, &tmp); napi_get_value_double(env, tmp, &r);
            napi_get_element(env, argv[0], 1, &tmp); napi_get_value_double(env, tmp, &g);
            napi_get_element(env, argv[0], 2, &tmp); napi_get_value_double(env, tmp, &b);
            napi_get_element(env, argv[0], 3, &tmp); napi_get_value_double(env, tmp, &a);
        } else {
            if (napi_get_named_property(env, argv[0], "r", &tmp) == napi_ok) napi_get_value_double(env, tmp, &r);
            if (napi_get_named_property(env, argv[0], "g", &tmp) == napi_ok) napi_get_value_double(env, tmp, &g);
            if (napi_get_named_property(env, argv[0], "b", &tmp) == napi_ok) napi_get_value_double(env, tmp, &b);
            if (napi_get_named_property(env, argv[0], "a", &tmp) == napi_ok) napi_get_value_double(env, tmp, &a);
        }
    }
    if (pfn_doeNativeRenderPassSetBlendConstant) {
        NativeDirectHandleCache* cache = native_direct_get_handle_cache(env, this_arg);
        void* pass = cache ? cache->native : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
        pfn_doeNativeRenderPassSetBlendConstant(pass, r, g, b, a);
    }
    napi_value undefined_value;
    napi_get_undefined(env, &undefined_value);
    return undefined_value;
}

/* GPURenderPassEncoder#setStencilReference(reference) */
napi_value native_direct_render_pass_set_stencil_reference(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    if (argc < 1) NAPI_THROW(env, "setStencilReference requires reference");
    uint32_t reference = 0;
    napi_get_value_uint32(env, argv[0], &reference);
    if (pfn_doeNativeRenderPassSetStencilReference) {
        NativeDirectHandleCache* cache = native_direct_get_handle_cache(env, this_arg);
        void* pass = cache ? cache->native : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
        pfn_doeNativeRenderPassSetStencilReference(pass, reference);
    }
    napi_value undefined_value;
    napi_get_undefined(env, &undefined_value);
    return undefined_value;
}

/* GPURenderPassEncoder#pushDebugGroup(groupLabel) */
napi_value native_direct_render_pass_push_debug_group(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    if (argc < 1) NAPI_THROW(env, "pushDebugGroup requires groupLabel");
    size_t label_len = 0;
    napi_get_value_string_utf8(env, argv[0], NULL, 0, &label_len);
    char* label = (char*)malloc(label_len + 1);
    if (!label) return NULL;
    napi_get_value_string_utf8(env, argv[0], label, label_len + 1, &label_len);
    if (pfn_doeNativeRenderPassPushDebugGroup) {
        NativeDirectHandleCache* cache = native_direct_get_handle_cache(env, this_arg);
        void* pass = cache ? cache->native : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
        pfn_doeNativeRenderPassPushDebugGroup(pass, label, label_len);
    }
    free(label);
    napi_value undefined_value;
    napi_get_undefined(env, &undefined_value);
    return undefined_value;
}

/* GPURenderPassEncoder#popDebugGroup() */
napi_value native_direct_render_pass_pop_debug_group(napi_env env, napi_callback_info info) {
    size_t argc = 0;
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, NULL, &this_arg, NULL);
    if (pfn_doeNativeRenderPassPopDebugGroup) {
        NativeDirectHandleCache* cache = native_direct_get_handle_cache(env, this_arg);
        void* pass = cache ? cache->native : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
        pfn_doeNativeRenderPassPopDebugGroup(pass);
    }
    napi_value undefined_value;
    napi_get_undefined(env, &undefined_value);
    return undefined_value;
}

/* GPURenderPassEncoder#insertDebugMarker(markerLabel) */
napi_value native_direct_render_pass_insert_debug_marker(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    if (argc < 1) NAPI_THROW(env, "insertDebugMarker requires markerLabel");
    size_t label_len = 0;
    napi_get_value_string_utf8(env, argv[0], NULL, 0, &label_len);
    char* label = (char*)malloc(label_len + 1);
    if (!label) return NULL;
    napi_get_value_string_utf8(env, argv[0], label, label_len + 1, &label_len);
    if (pfn_doeNativeRenderPassInsertDebugMarker) {
        NativeDirectHandleCache* cache = native_direct_get_handle_cache(env, this_arg);
        void* pass = cache ? cache->native : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
        pfn_doeNativeRenderPassInsertDebugMarker(pass, label, label_len);
    }
    free(label);
    napi_value undefined_value;
    napi_get_undefined(env, &undefined_value);
    return undefined_value;
}

napi_value native_direct_render_pass_draw_indirect(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    if (argc < 1) NAPI_THROW(env, "drawIndirect requires an indirect buffer");
    FnWgpuRenderPassEncoderDrawIndirect fn = resolve_wgpu_render_pass_draw_indirect();
    if (!fn) NAPI_THROW(env, "renderPassDrawIndirect not available");
    NativeDirectHandleCache* cache = native_direct_get_handle_cache(env, this_arg);
    WGPURenderPassEncoder pass = cache ? (WGPURenderPassEncoder)cache->native : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
    NativeDirectBufferCache* buffer_cache = native_direct_get_buffer_cache(env, argv[0]);
    WGPUBuffer buffer = buffer_cache ? buffer_cache->buffer : native_direct_unwrap_external_prop(env, argv[0], DOE_DIRECT_NATIVE);
    if (!pass || !buffer) NAPI_THROW(env, "drawIndirect requires a render pass and indirect buffer");
    int64_t offset = 0;
    if (argc >= 2 && argv[1]) napi_get_value_int64(env, argv[1], &offset);
    fn(pass, buffer, (uint64_t)offset);
    napi_value undefined_value;
    napi_get_undefined(env, &undefined_value);
    return undefined_value;
}

napi_value native_direct_render_pass_draw_indexed_indirect(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    if (argc < 1) NAPI_THROW(env, "drawIndexedIndirect requires an indirect buffer");
    FnWgpuRenderPassEncoderDrawIndexedIndirect fn = resolve_wgpu_render_pass_draw_indexed_indirect();
    if (!fn) NAPI_THROW(env, "renderPassDrawIndexedIndirect not available");
    NativeDirectHandleCache* cache = native_direct_get_handle_cache(env, this_arg);
    WGPURenderPassEncoder pass = cache ? (WGPURenderPassEncoder)cache->native : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
    NativeDirectBufferCache* buffer_cache = native_direct_get_buffer_cache(env, argv[0]);
    WGPUBuffer buffer = buffer_cache ? buffer_cache->buffer : native_direct_unwrap_external_prop(env, argv[0], DOE_DIRECT_NATIVE);
    if (!pass || !buffer) NAPI_THROW(env, "drawIndexedIndirect requires a render pass and indirect buffer");
    int64_t offset = 0;
    if (argc >= 2 && argv[1]) napi_get_value_int64(env, argv[1], &offset);
    fn(pass, buffer, (uint64_t)offset);
    napi_value undefined_value;
    napi_get_undefined(env, &undefined_value);
    return undefined_value;
}
