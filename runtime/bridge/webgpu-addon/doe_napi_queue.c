/*
 * doe_napi_queue.c — Command encoder, compute pass, and queue N-API bindings.
 *
 * Covers: createCommandEncoder, command encoder copy/clear ops, compute pass
 * encode/dispatch, queue submit/write/flush paths, and batched fast paths.
 */
#include "doe_napi_internal.h"

#define BATCH_STACK_DISPATCHES 64
#define QUEUE_WRITE_BATCH_STACK_MAX 64u

static int submit_breakdown_enabled(void);

static uint32_t read_bind_group_value(napi_env env, napi_value value, void** bind_groups, uint32_t max_count) {
    if (!value || max_count == 0) {
        return 0;
    }
    napi_valuetype value_type;
    if (napi_typeof(env, value, &value_type) != napi_ok) {
        return 0;
    }
    if (value_type == napi_null || value_type == napi_undefined) {
        return 0;
    }
    bool is_array = false;
    napi_is_array(env, value, &is_array);
    if (!is_array) {
        void* bg = unwrap_ptr(env, value);
        if (!bg) {
            return 0;
        }
        bind_groups[0] = bg;
        return 1;
    }
    uint32_t bg_count = 0;
    napi_get_array_length(env, value, &bg_count);
    if (bg_count > max_count) bg_count = max_count;
    for (uint32_t j = 0; j < bg_count; j++) {
        napi_value bg_val;
        napi_get_element(env, value, j, &bg_val);
        bind_groups[j] = unwrap_ptr(env, bg_val);
    }
    return bg_count;
}

static uint32_t read_command_bind_groups(napi_env env, napi_value cmd, void** bind_groups, uint32_t max_count) {
    napi_value compact_bind_groups = get_prop(env, cmd, "b");
    napi_valuetype compact_type;
    if (napi_typeof(env, compact_bind_groups, &compact_type) == napi_ok &&
        compact_type != napi_undefined &&
        compact_type != napi_null) {
        bool compact_is_array = false;
        napi_is_array(env, compact_bind_groups, &compact_is_array);
        if (!compact_is_array) {
            void* bg = unwrap_ptr(env, compact_bind_groups);
            if (!bg || max_count == 0) return 0;
            bind_groups[0] = bg;
            return 1;
        }
        return read_bind_group_value(env, compact_bind_groups, bind_groups, max_count);
    }
    return read_bind_group_value(env, get_prop(env, cmd, "bg"), bind_groups, max_count);
}

static uint32_t get_command_u32(napi_env env, napi_value cmd, const char* key, uint32_t index) {
    (void)index;
    return get_uint32_prop(env, cmd, key);
}

static int64_t get_command_i64(napi_env env, napi_value cmd, const char* key, uint32_t index) {
    (void)index;
    return get_int64_prop(env, cmd, key);
}

static void* get_command_ptr(napi_env env, napi_value cmd, const char* key, uint32_t index) {
    (void)index;
    return unwrap_ptr(env, get_prop(env, cmd, key));
}

static uint32_t get_command_type(napi_env env, napi_value cmd) {
    return get_uint32_prop(env, cmd, "t");
}

/* ================================================================
 * Command Encoder
 * ================================================================ */

napi_value doe_create_command_encoder(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 2);
    CHECK_LIB_LOADED(env);
    WGPUDevice device = unwrap_ptr(env, _args[0]);
    if (!device) NAPI_THROW(env, "Invalid device");

    /* Read label (2nd arg) */
    WGPUStringView label_view = { .data = NULL, .length = 0 };
    char label_buf[256] = {0};
    if (_argc > 1) {
        napi_valuetype lt; napi_typeof(env, _args[1], &lt);
        if (lt == napi_string) {
            size_t label_len = 0;
            napi_get_value_string_utf8(env, _args[1], label_buf, sizeof(label_buf), &label_len);
            label_view.data = label_buf;
            label_view.length = label_len;
        }
    }

    WGPUCommandEncoderDescriptor desc = {
        .nextInChain = NULL, .label = label_view,
    };
    WGPUCommandEncoder enc = pfn_wgpuDeviceCreateCommandEncoder(device, &desc);
    if (!enc) NAPI_THROW(env, "createCommandEncoder failed");
    return wrap_ptr(env, enc);
}

napi_value doe_command_encoder_release(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    void* p = unwrap_ptr(env, _args[0]);
    if (p) pfn_wgpuCommandEncoderRelease(p);
    return NULL;
}

napi_value doe_command_encoder_copy_buffer_to_buffer(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 6);
    CHECK_LIB_LOADED(env);
    WGPUCommandEncoder enc = unwrap_ptr(env, _args[0]);
    WGPUBuffer src = unwrap_ptr(env, _args[1]);
    int64_t src_offset; napi_get_value_int64(env, _args[2], &src_offset);
    WGPUBuffer dst = unwrap_ptr(env, _args[3]);
    int64_t dst_offset; napi_get_value_int64(env, _args[4], &dst_offset);
    int64_t size; napi_get_value_int64(env, _args[5], &size);
    pfn_wgpuCommandEncoderCopyBufferToBuffer(enc, src, (uint64_t)src_offset,
        dst, (uint64_t)dst_offset, (uint64_t)size);
    return NULL;
}

napi_value doe_command_encoder_copy_buffer_to_texture(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 14);
    CHECK_LIB_LOADED(env);
    WGPUCommandEncoder enc = unwrap_ptr(env, _args[0]);
    WGPUBuffer src_buffer = unwrap_ptr(env, _args[1]);
    if (!enc || !src_buffer) NAPI_THROW(env, "commandEncoderCopyBufferToTexture requires encoder and buffer");
    WGPUTexelCopyBufferInfo src; memset(&src, 0, sizeof(src));
    src.buffer = src_buffer;
    int64_t src_offset = 0; napi_get_value_int64(env, _args[2], &src_offset);
    src.layout.offset = (uint64_t)src_offset;
    napi_get_value_uint32(env, _args[3], &src.layout.bytesPerRow);
    napi_get_value_uint32(env, _args[4], &src.layout.rowsPerImage);
    WGPUTexelCopyTextureInfo dst; memset(&dst, 0, sizeof(dst));
    dst.texture = unwrap_ptr(env, _args[5]);
    if (!dst.texture) NAPI_THROW(env, "commandEncoderCopyBufferToTexture requires destination texture");
    napi_get_value_uint32(env, _args[6], &dst.mipLevel);
    napi_get_value_uint32(env, _args[7], &dst.origin.x);
    napi_get_value_uint32(env, _args[8], &dst.origin.y);
    napi_get_value_uint32(env, _args[9], &dst.origin.z);
    napi_get_value_uint32(env, _args[10], &dst.aspect);
    WGPUExtent3D size;
    napi_get_value_uint32(env, _args[11], &size.width);
    napi_get_value_uint32(env, _args[12], &size.height);
    napi_get_value_uint32(env, _args[13], &size.depthOrArrayLayers);
    if (pfn_wgpuCommandEncoderCopyBufferToTexture) {
        pfn_wgpuCommandEncoderCopyBufferToTexture(enc, &src, &dst, &size);
    } else if (pfn_doeNativeCommandEncoderCopyBufferToTexture) {
        pfn_doeNativeCommandEncoderCopyBufferToTexture(enc, src.buffer,
            src.layout.offset, src.layout.bytesPerRow, src.layout.rowsPerImage,
            dst.texture, dst.mipLevel, dst.origin.x, dst.origin.y, dst.origin.z, dst.aspect,
            size.width, size.height, size.depthOrArrayLayers);
    } else {
        NAPI_THROW(env, "commandEncoderCopyBufferToTexture: no implementation available in loaded library");
    }
    return NULL;
}

napi_value doe_command_encoder_copy_texture_to_buffer(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 14);
    CHECK_LIB_LOADED(env);
    WGPUCommandEncoder enc = unwrap_ptr(env, _args[0]);
    WGPUTexture src_texture = unwrap_ptr(env, _args[1]);
    if (!enc || !src_texture) NAPI_THROW(env, "commandEncoderCopyTextureToBuffer requires encoder and texture");
    WGPUTexelCopyTextureInfo src; memset(&src, 0, sizeof(src));
    src.texture = src_texture;
    napi_get_value_uint32(env, _args[2], &src.mipLevel);
    napi_get_value_uint32(env, _args[3], &src.origin.x);
    napi_get_value_uint32(env, _args[4], &src.origin.y);
    napi_get_value_uint32(env, _args[5], &src.origin.z);
    napi_get_value_uint32(env, _args[6], &src.aspect);
    WGPUTexelCopyBufferInfo dst; memset(&dst, 0, sizeof(dst));
    dst.buffer = unwrap_ptr(env, _args[7]);
    if (!dst.buffer) NAPI_THROW(env, "commandEncoderCopyTextureToBuffer requires destination buffer");
    int64_t dst_offset = 0; napi_get_value_int64(env, _args[8], &dst_offset);
    dst.layout.offset = (uint64_t)dst_offset;
    napi_get_value_uint32(env, _args[9], &dst.layout.bytesPerRow);
    napi_get_value_uint32(env, _args[10], &dst.layout.rowsPerImage);
    WGPUExtent3D size;
    napi_get_value_uint32(env, _args[11], &size.width);
    napi_get_value_uint32(env, _args[12], &size.height);
    napi_get_value_uint32(env, _args[13], &size.depthOrArrayLayers);
    if (pfn_wgpuCommandEncoderCopyTextureToBuffer) {
        pfn_wgpuCommandEncoderCopyTextureToBuffer(enc, &src, &dst, &size);
    } else if (pfn_doeNativeCommandEncoderCopyTextureToBuffer) {
        pfn_doeNativeCommandEncoderCopyTextureToBuffer(enc, src.texture, src.mipLevel,
            src.origin.x, src.origin.y, src.origin.z, src.aspect,
            dst.buffer, dst.layout.offset, dst.layout.bytesPerRow, dst.layout.rowsPerImage,
            size.width, size.height, size.depthOrArrayLayers);
    } else {
        NAPI_THROW(env, "commandEncoderCopyTextureToBuffer: no implementation available in loaded library");
    }
    return NULL;
}

napi_value doe_command_encoder_clear_buffer(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value argv[4];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    CHECK_LIB_LOADED(env);
    if (argc < 2) NAPI_THROW(env, "commandEncoderClearBuffer requires encoder and buffer");
    if (!pfn_doeNativeCommandEncoderClearBuffer)
        NAPI_THROW(env, "commandEncoderClearBuffer: no implementation available in loaded library");
    WGPUCommandEncoder enc = unwrap_ptr(env, argv[0]);
    WGPUBuffer buffer = unwrap_ptr(env, argv[1]);
    if (!enc || !buffer) NAPI_THROW(env, "commandEncoderClearBuffer requires encoder and buffer");
    uint64_t offset = 0;
    uint64_t size = WGPU_WHOLE_SIZE;
    if (argc >= 3) {
        napi_valuetype vt; napi_typeof(env, argv[2], &vt);
        if (vt == napi_number || vt == napi_bigint) {
            int64_t v = 0; napi_get_value_int64(env, argv[2], &v);
            if (v > 0) offset = (uint64_t)v;
        }
    }
    if (argc >= 4) {
        napi_valuetype vt; napi_typeof(env, argv[3], &vt);
        if (vt == napi_number || vt == napi_bigint) {
            int64_t v = 0; napi_get_value_int64(env, argv[3], &v);
            if (v > 0) size = (uint64_t)v;
            else if (v == 0) size = 0;
        }
    }
    pfn_doeNativeCommandEncoderClearBuffer(enc, buffer, offset, size);
    return NULL;
}

napi_value doe_command_encoder_copy_texture_to_texture(napi_env env, napi_callback_info info) {
    size_t argc = 16;
    napi_value argv[16];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    CHECK_LIB_LOADED(env);
    if (argc != 16)
        NAPI_THROW(env, "commandEncoderCopyTextureToTexture requires 16 arguments");
    if (!pfn_doeNativeCommandEncoderCopyTextureToTexture && !pfn_wgpuCommandEncoderCopyTextureToTexture)
        NAPI_THROW(env, "commandEncoderCopyTextureToTexture: no implementation available in loaded library");
    WGPUCommandEncoder enc    = unwrap_ptr(env, argv[0]);
    WGPUTexture src_texture   = unwrap_ptr(env, argv[1]);
    WGPUTexture dst_texture   = unwrap_ptr(env, argv[7]);
    if (!enc || !src_texture || !dst_texture)
        NAPI_THROW(env, "commandEncoderCopyTextureToTexture requires encoder and textures");
    uint32_t src_mip = 0, src_x = 0, src_y = 0, src_z = 0;
    uint32_t dst_mip = 0, dst_x = 0, dst_y = 0, dst_z = 0;
    uint32_t src_aspect = 0, dst_aspect = 0;
    uint32_t width = 1, height = 1, depth_or_layers = 1;
    napi_get_value_uint32(env, argv[2], &src_mip);
    napi_get_value_uint32(env, argv[3], &src_x);
    napi_get_value_uint32(env, argv[4], &src_y);
    napi_get_value_uint32(env, argv[5], &src_z);
    napi_get_value_uint32(env, argv[6], &src_aspect);
    napi_get_value_uint32(env, argv[8], &dst_mip);
    napi_get_value_uint32(env, argv[9], &dst_x);
    napi_get_value_uint32(env, argv[10], &dst_y);
    napi_get_value_uint32(env, argv[11], &dst_z);
    napi_get_value_uint32(env, argv[12], &dst_aspect);
    napi_get_value_uint32(env, argv[13], &width);
    napi_get_value_uint32(env, argv[14], &height);
    napi_get_value_uint32(env, argv[15], &depth_or_layers);
    if (pfn_doeNativeCommandEncoderCopyTextureToTexture) {
        pfn_doeNativeCommandEncoderCopyTextureToTexture(enc,
            src_texture, src_mip, 0, src_x, src_y, src_z,
            dst_texture, dst_mip, 0, dst_x, dst_y, dst_z,
            width, height, depth_or_layers);
    } else if (pfn_wgpuCommandEncoderCopyTextureToTexture) {
        WGPUTexelCopyTextureInfo s, d; WGPUExtent3D sz;
        memset(&s, 0, sizeof(s)); memset(&d, 0, sizeof(d));
        s.texture = src_texture; s.mipLevel = src_mip;
        s.origin.x = src_x; s.origin.y = src_y; s.origin.z = src_z;
        s.aspect = src_aspect;
        d.texture = dst_texture; d.mipLevel = dst_mip;
        d.origin.x = dst_x; d.origin.y = dst_y; d.origin.z = dst_z;
        d.aspect = dst_aspect;
        sz.width = width; sz.height = height; sz.depthOrArrayLayers = depth_or_layers;
        pfn_wgpuCommandEncoderCopyTextureToTexture(enc, &s, &d, &sz);
    } else {
        NAPI_THROW(env, "commandEncoderCopyTextureToTexture: no implementation available in loaded library");
    }
    return NULL;
}

/* ================================================================
 * Compute Pass
 * ================================================================ */

napi_value doe_begin_compute_pass(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    CHECK_LIB_LOADED(env);
    if (argc < 1) NAPI_THROW(env, "beginComputePass requires encoder");
    WGPUCommandEncoder enc = unwrap_ptr(env, argv[0]);
    if (!enc) NAPI_THROW(env, "Invalid encoder");

    char* label = NULL;
    size_t label_len = 0;
    WGPUComputePassTimestampWrites ts_writes = {0};
    WGPUComputePassTimestampWrites* ts_writes_ptr = NULL;
    if (argc > 1) {
        napi_valuetype desc_vt; napi_typeof(env, argv[1], &desc_vt);
        if (desc_vt == napi_object) {
            if (has_prop(env, argv[1], "label") && prop_type(env, argv[1], "label") == napi_string) {
                label = dup_string_value(env, get_prop(env, argv[1], "label"), &label_len);
                if (!label) NAPI_THROW(env, "beginComputePass: out of memory while reading label");
            }
            if (has_prop(env, argv[1], "timestampWrites") &&
                prop_type(env, argv[1], "timestampWrites") == napi_object) {
                napi_value tw = get_prop(env, argv[1], "timestampWrites");
                ts_writes.querySet = unwrap_ptr(env, get_prop(env, tw, "querySet"));
                ts_writes.beginningOfPassWriteIndex = get_uint32_prop(env, tw, "beginningOfPassWriteIndex");
                ts_writes.endOfPassWriteIndex = get_uint32_prop(env, tw, "endOfPassWriteIndex");
                ts_writes_ptr = &ts_writes;
            }
        }
    }

    WGPUComputePassDescriptor desc = {
        .nextInChain = NULL, .label = { .data = label, .length = label ? label_len : 0 },
        .timestampWrites = ts_writes_ptr,
    };
    WGPUComputePassEncoder pass = pfn_wgpuCommandEncoderBeginComputePass(enc, &desc);
    free(label);
    if (!pass) NAPI_THROW(env, "beginComputePass failed");
    return wrap_ptr(env, pass);
}

napi_value doe_compute_pass_set_pipeline(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 2);
    pfn_wgpuComputePassEncoderSetPipeline(unwrap_ptr(env, _args[0]), unwrap_ptr(env, _args[1]));
    return NULL;
}

napi_value doe_compute_pass_set_bind_group(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 3);
    WGPUComputePassEncoder pass = unwrap_ptr(env, _args[0]);
    uint32_t index; napi_get_value_uint32(env, _args[1], &index);
    WGPUBindGroup group = unwrap_ptr(env, _args[2]);
    pfn_wgpuComputePassEncoderSetBindGroup(pass, index, group, 0, NULL);
    return NULL;
}

napi_value doe_compute_pass_set_immediates(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 3);
    if (!pfn_doeNativeComputePassSetImmediates) NAPI_THROW(env, "computePassSetImmediates not available");
    WGPUComputePassEncoder pass = unwrap_ptr(env, _args[0]);
    if (!pass) NAPI_THROW(env, "Invalid compute pass");
    uint32_t index = 0; napi_get_value_uint32(env, _args[1], &index);
    void* data_ptr = NULL;
    size_t data_len = 0;
    extract_buffer_data(env, _args[2], &data_ptr, &data_len);
    pfn_doeNativeComputePassSetImmediates(pass, index, (const uint8_t*)data_ptr, data_len);
    return NULL;
}

napi_value doe_compute_pass_dispatch(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 4);
    WGPUComputePassEncoder pass = unwrap_ptr(env, _args[0]);
    uint32_t x, y, z;
    napi_get_value_uint32(env, _args[1], &x);
    napi_get_value_uint32(env, _args[2], &y);
    napi_get_value_uint32(env, _args[3], &z);
    pfn_wgpuComputePassEncoderDispatchWorkgroups(pass, x, y, z);
    return NULL;
}

napi_value doe_compute_pass_dispatch_bound(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 6);
    WGPUComputePassEncoder pass = unwrap_ptr(env, _args[0]);
    WGPUComputePipeline pipeline = unwrap_ptr(env, _args[1]);
    WGPUBindGroup bind_group = unwrap_ptr(env, _args[2]);
    uint32_t x, y, z;
    napi_get_value_uint32(env, _args[3], &x);
    napi_get_value_uint32(env, _args[4], &y);
    napi_get_value_uint32(env, _args[5], &z);
    if (pfn_doeNativeComputePassDispatchBound) {
        pfn_doeNativeComputePassDispatchBound(pass, pipeline, bind_group, x, y, z);
        return NULL;
    }
    pfn_wgpuComputePassEncoderSetPipeline(pass, pipeline);
    pfn_wgpuComputePassEncoderSetBindGroup(pass, 0, bind_group, 0, NULL);
    pfn_wgpuComputePassEncoderDispatchWorkgroups(pass, x, y, z);
    return NULL;
}

/* computePassDispatchWorkgroupsIndirect(pass, buffer, offset) */
napi_value doe_compute_pass_dispatch_indirect(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 3);
    WGPUComputePassEncoder pass = unwrap_ptr(env, _args[0]);
    WGPUBuffer buffer = unwrap_ptr(env, _args[1]);
    int64_t offset; napi_get_value_int64(env, _args[2], &offset);
    if (pfn_doeNativeComputePassDispatchIndirect)
        pfn_doeNativeComputePassDispatchIndirect(pass, buffer, (uint64_t)offset);
    else
        pfn_wgpuComputePassEncoderDispatchWorkgroupsIndirect(pass, buffer, (uint64_t)offset);
    return NULL;
}

napi_value doe_compute_pass_end(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    pfn_wgpuComputePassEncoderEnd(unwrap_ptr(env, _args[0]));
    return NULL;
}

napi_value doe_compute_pass_release(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    void* p = unwrap_ptr(env, _args[0]);
    if (p) pfn_wgpuComputePassEncoderRelease(p);
    return NULL;
}

napi_value doe_command_encoder_finish(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    CHECK_LIB_LOADED(env);
    WGPUCommandEncoder enc = unwrap_ptr(env, _args[0]);
    if (!enc) NAPI_THROW(env, "Invalid encoder");
    WGPUCommandBufferDescriptor desc = {
        .nextInChain = NULL, .label = { .data = NULL, .length = 0 },
    };
    WGPUCommandBuffer cmd = pfn_wgpuCommandEncoderFinish(enc, &desc);
    if (!cmd) NAPI_THROW(env, "commandEncoderFinish failed");
    return wrap_ptr(env, cmd);
}

napi_value doe_create_compute_dispatch_copy_command_buffer(napi_env env, napi_callback_info info) {
    size_t argc = 11;
    napi_value args[11];
    napi_status status = napi_get_cb_info(env, info, &argc, args, NULL, NULL);
    if (status != napi_ok || argc != 11) {
        NAPI_THROW(env, "createComputeDispatchCopyCommandBuffer requires 11 arguments");
    }
    CHECK_LIB_LOADED(env);
    WGPUDevice device = unwrap_ptr(env, args[0]);
    WGPUComputePipeline pipeline = unwrap_ptr(env, args[1]);
    napi_value bgs = args[2];
    uint32_t dx = 0, dy = 0, dz = 0;
    int64_t copy_src_off_i = 0, copy_dst_off_i = 0, copy_size_i = 0;
    napi_get_value_uint32(env, args[3], &dx);
    napi_get_value_uint32(env, args[4], &dy);
    napi_get_value_uint32(env, args[5], &dz);
    WGPUBuffer copy_src = unwrap_ptr(env, args[6]);
    napi_get_value_int64(env, args[7], &copy_src_off_i);
    WGPUBuffer copy_dst = unwrap_ptr(env, args[8]);
    napi_get_value_int64(env, args[9], &copy_dst_off_i);
    napi_get_value_int64(env, args[10], &copy_size_i);
    if (!device || !pipeline || !copy_src || !copy_dst) {
        NAPI_THROW(env, "createComputeDispatchCopyCommandBuffer requires device, pipeline, and buffers");
    }
    void* bind_groups[BATCH_MAX_BIND_GROUPS] = {NULL};
    uint32_t bg_count = read_bind_group_value(env, bgs, bind_groups, BATCH_MAX_BIND_GROUPS);
    WGPUCommandEncoder encoder = pfn_wgpuDeviceCreateCommandEncoder(device, NULL);
    if (!encoder) NAPI_THROW(env, "createComputeDispatchCopyCommandBuffer: createCommandEncoder failed");
    WGPUComputePassEncoder pass = pfn_wgpuCommandEncoderBeginComputePass(encoder, NULL);
    if (!pass) {
        pfn_wgpuCommandEncoderRelease(encoder);
        NAPI_THROW(env, "createComputeDispatchCopyCommandBuffer: beginComputePass failed");
    }
    pfn_wgpuComputePassEncoderSetPipeline(pass, pipeline);
    for (uint32_t j = 0; j < bg_count; j++) {
        if (bind_groups[j]) {
            pfn_wgpuComputePassEncoderSetBindGroup(pass, j, bind_groups[j], 0, NULL);
        }
    }
    pfn_wgpuComputePassEncoderDispatchWorkgroups(pass, dx, dy, dz);
    pfn_wgpuComputePassEncoderEnd(pass);
    pfn_wgpuComputePassEncoderRelease(pass);
    pfn_wgpuCommandEncoderCopyBufferToBuffer(
        encoder,
        copy_src,
        (uint64_t)copy_src_off_i,
        copy_dst,
        (uint64_t)copy_dst_off_i,
        (uint64_t)copy_size_i
    );
    WGPUCommandBufferDescriptor desc = {
        .nextInChain = NULL, .label = { .data = NULL, .length = 0 },
    };
    WGPUCommandBuffer cmd = pfn_wgpuCommandEncoderFinish(encoder, &desc);
    pfn_wgpuCommandEncoderRelease(encoder);
    if (!cmd) NAPI_THROW(env, "createComputeDispatchCopyCommandBuffer: finish failed");
    return wrap_ptr(env, cmd);
}

napi_value doe_create_compute_dispatch_batch_copy_command_buffer(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_status status = napi_get_cb_info(env, info, &argc, args, NULL, NULL);
    if (status != napi_ok || argc != 2) {
        NAPI_THROW(env, "createComputeDispatchBatchCopyCommandBuffer requires 2 arguments");
    }
    CHECK_LIB_LOADED(env);
    WGPUDevice device = unwrap_ptr(env, args[0]);
    if (!device) {
        NAPI_THROW(env, "createComputeDispatchBatchCopyCommandBuffer requires a device");
    }

    napi_value commands = args[1];
    uint32_t cmd_count = 0;
    napi_get_array_length(env, commands, &cmd_count);
    if (cmd_count < 2) {
        NAPI_THROW(env, "createComputeDispatchBatchCopyCommandBuffer requires dispatch commands followed by a copy");
    }

    napi_value copy_cmd;
    napi_get_element(env, commands, cmd_count - 1, &copy_cmd);
    if (get_command_type(env, copy_cmd) != 1) {
        NAPI_THROW(env, "createComputeDispatchBatchCopyCommandBuffer requires a final copy command");
    }

    WGPUCommandEncoder encoder = pfn_wgpuDeviceCreateCommandEncoder(device, NULL);
    if (!encoder) {
        NAPI_THROW(env, "createComputeDispatchBatchCopyCommandBuffer: createCommandEncoder failed");
    }
    WGPUComputePassEncoder pass = pfn_wgpuCommandEncoderBeginComputePass(encoder, NULL);
    if (!pass) {
        pfn_wgpuCommandEncoderRelease(encoder);
        NAPI_THROW(env, "createComputeDispatchBatchCopyCommandBuffer: beginComputePass failed");
    }

#define THROW_BATCH_COMMAND_BUFFER_ERROR(message) do { \
        if (pass) pfn_wgpuComputePassEncoderRelease(pass); \
        if (encoder) pfn_wgpuCommandEncoderRelease(encoder); \
        napi_throw_error(env, "DOE_ERROR", message); \
        return NULL; \
    } while (0)

    void* current_pipeline = NULL;
    void* current_bind_groups[BATCH_MAX_BIND_GROUPS] = {NULL};
    for (uint32_t i = 0; i + 1 < cmd_count; i++) {
        napi_value cmd;
        napi_get_element(env, commands, i, &cmd);
        void* bind_groups[BATCH_MAX_BIND_GROUPS] = {NULL};
        uint32_t command_type = get_uint32_prop(env, cmd, "t");
        void* pipeline = unwrap_ptr(env, get_prop(env, cmd, "p"));
        uint32_t bg_count = read_command_bind_groups(env, cmd, bind_groups, BATCH_MAX_BIND_GROUPS);
        uint32_t dx = get_uint32_prop(env, cmd, "x");
        uint32_t dy = get_uint32_prop(env, cmd, "y");
        uint32_t dz = get_uint32_prop(env, cmd, "z");
        if (command_type != 0) {
            THROW_BATCH_COMMAND_BUFFER_ERROR("createComputeDispatchBatchCopyCommandBuffer requires only dispatch commands before the copy");
        }

        if (!pipeline) {
            THROW_BATCH_COMMAND_BUFFER_ERROR("createComputeDispatchBatchCopyCommandBuffer requires dispatch pipelines");
        }
        if (pipeline != current_pipeline) {
            pfn_wgpuComputePassEncoderSetPipeline(pass, pipeline);
            current_pipeline = pipeline;
            memset(current_bind_groups, 0, sizeof(current_bind_groups));
        }

        for (uint32_t j = 0; j < bg_count; j++) {
            void* bg = bind_groups[j];
            if (bg && bg != current_bind_groups[j]) {
                pfn_wgpuComputePassEncoderSetBindGroup(pass, j, bg, 0, NULL);
                current_bind_groups[j] = bg;
            }
        }

        pfn_wgpuComputePassEncoderDispatchWorkgroups(pass, dx, dy, dz);
    }

    WGPUBuffer copy_src = unwrap_ptr(env, get_prop(env, copy_cmd, "s"));
    WGPUBuffer copy_dst = unwrap_ptr(env, get_prop(env, copy_cmd, "d"));
    uint64_t copy_src_offset = (uint64_t)get_int64_prop(env, copy_cmd, "so");
    uint64_t copy_dst_offset = (uint64_t)get_int64_prop(env, copy_cmd, "do");
    uint64_t copy_size = (uint64_t)get_int64_prop(env, copy_cmd, "sz");
    if (!copy_src || !copy_dst) {
        THROW_BATCH_COMMAND_BUFFER_ERROR("createComputeDispatchBatchCopyCommandBuffer requires copy buffers");
    }

    pfn_wgpuComputePassEncoderEnd(pass);
    pfn_wgpuComputePassEncoderRelease(pass);
    pass = NULL;
    pfn_wgpuCommandEncoderCopyBufferToBuffer(
        encoder,
        copy_src,
        copy_src_offset,
        copy_dst,
        copy_dst_offset,
        copy_size
    );
    WGPUCommandBufferDescriptor desc = {
        .nextInChain = NULL, .label = { .data = NULL, .length = 0 },
    };
    WGPUCommandBuffer cmd = pfn_wgpuCommandEncoderFinish(encoder, &desc);
    pfn_wgpuCommandEncoderRelease(encoder);
    encoder = NULL;
    if (!cmd) {
        THROW_BATCH_COMMAND_BUFFER_ERROR("createComputeDispatchBatchCopyCommandBuffer: finish failed");
    }
#undef THROW_BATCH_COMMAND_BUFFER_ERROR
    return wrap_ptr(env, cmd);
}

napi_value doe_command_buffer_release(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    void* p = unwrap_ptr(env, _args[0]);
    if (p) pfn_wgpuCommandBufferRelease(p);
    return NULL;
}

/* ================================================================
 * Queue
 * ================================================================ */

static napi_value make_submit_breakdown_full(
    napi_env env,
    uint64_t command_replay_ns,
    uint64_t queue_submit_ns,
    uint64_t flush_ns,
    uint64_t wait_completed_ns,
    uint64_t deferred_copy_ns,
    uint64_t deferred_resolve_ns,
    uint64_t command_buffer_end_ns,
    uint64_t sync_prepare_ns,
    uint64_t driver_submit_ns,
    uint64_t command_replay_prepare_ns,
    uint64_t command_replay_record_ns,
    uint64_t command_replay_copy_ns
);
static napi_value make_submit_completion_hint(
    napi_env env,
    uint64_t flush_ns,
    uint64_t wait_completed_ns,
    uint64_t deferred_copy_ns,
    uint64_t deferred_resolve_ns
);

static napi_value make_submit_breakdown(
    napi_env env,
    uint64_t command_replay_ns,
    uint64_t queue_submit_ns,
    uint64_t flush_ns
) {
    if (!submit_breakdown_enabled()) return make_submit_completion_hint(env, flush_ns, 0, 0, 0);
    return make_submit_breakdown_full(env, command_replay_ns, queue_submit_ns, flush_ns, 0, 0, 0, 0, 0, 0, 0, 0, 0);
}

static void maybe_set_submit_breakdown_u64(napi_env env, napi_value result, const char* name, uint64_t value) {
    if (value == 0) return;
    napi_value js_value;
    napi_create_double(env, (double)value, &js_value);
    napi_set_named_property(env, result, name, js_value);
}

static napi_value make_submit_completion_hint(
    napi_env env,
    uint64_t flush_ns,
    uint64_t wait_completed_ns,
    uint64_t deferred_copy_ns,
    uint64_t deferred_resolve_ns
) {
    if (flush_ns == 0 && wait_completed_ns == 0 && deferred_copy_ns == 0 && deferred_resolve_ns == 0) {
        return NULL;
    }
    napi_value result;
    napi_create_object(env, &result);
    maybe_set_submit_breakdown_u64(env, result, "flushNs", flush_ns);
    maybe_set_submit_breakdown_u64(env, result, "waitCompletedNs", wait_completed_ns);
    maybe_set_submit_breakdown_u64(env, result, "deferredCopyNs", deferred_copy_ns);
    maybe_set_submit_breakdown_u64(env, result, "deferredResolveNs", deferred_resolve_ns);
    return result;
}

static napi_value make_submit_breakdown_full(
    napi_env env,
    uint64_t command_replay_ns,
    uint64_t queue_submit_ns,
    uint64_t flush_ns,
    uint64_t wait_completed_ns,
    uint64_t deferred_copy_ns,
    uint64_t deferred_resolve_ns,
    uint64_t command_buffer_end_ns,
    uint64_t sync_prepare_ns,
    uint64_t driver_submit_ns,
    uint64_t command_replay_prepare_ns,
    uint64_t command_replay_record_ns,
    uint64_t command_replay_copy_ns
) {
    napi_value result;
    napi_value replay_value;
    napi_value submit_value;
    napi_value flush_value;
    napi_value wait_value;
    napi_value copy_value;
    napi_value resolve_value;
    napi_value command_buffer_end_value;
    napi_value sync_prepare_value;
    napi_value driver_submit_value;
    napi_value command_replay_prepare_value;
    napi_value command_replay_record_value;
    napi_value command_replay_copy_value;
    napi_create_object(env, &result);
    napi_create_double(env, (double)command_replay_ns, &replay_value);
    napi_create_double(env, (double)queue_submit_ns, &submit_value);
    napi_create_double(env, (double)flush_ns, &flush_value);
    napi_create_double(env, (double)wait_completed_ns, &wait_value);
    napi_create_double(env, (double)deferred_copy_ns, &copy_value);
    napi_create_double(env, (double)deferred_resolve_ns, &resolve_value);
    napi_create_double(env, (double)command_buffer_end_ns, &command_buffer_end_value);
    napi_create_double(env, (double)sync_prepare_ns, &sync_prepare_value);
    napi_create_double(env, (double)driver_submit_ns, &driver_submit_value);
    napi_create_double(env, (double)command_replay_prepare_ns, &command_replay_prepare_value);
    napi_create_double(env, (double)command_replay_record_ns, &command_replay_record_value);
    napi_create_double(env, (double)command_replay_copy_ns, &command_replay_copy_value);
    napi_set_named_property(env, result, "commandReplayNs", replay_value);
    napi_set_named_property(env, result, "queueSubmitNs", submit_value);
    napi_set_named_property(env, result, "flushNs", flush_value);
    napi_set_named_property(env, result, "waitCompletedNs", wait_value);
    napi_set_named_property(env, result, "deferredCopyNs", copy_value);
    napi_set_named_property(env, result, "deferredResolveNs", resolve_value);
    napi_set_named_property(env, result, "commandBufferEndNs", command_buffer_end_value);
    napi_set_named_property(env, result, "syncPrepareNs", sync_prepare_value);
    napi_set_named_property(env, result, "driverSubmitNs", driver_submit_value);
    napi_set_named_property(env, result, "commandReplayPrepareNs", command_replay_prepare_value);
    napi_set_named_property(env, result, "commandReplayRecordNs", command_replay_record_value);
    napi_set_named_property(env, result, "commandReplayCopyNs", command_replay_copy_value);
    return result;
}

static uint64_t flush_queue_after_submit(
    WGPUQueue queue,
    uint64_t* wait_completed_ns,
    uint64_t* deferred_copy_ns,
    uint64_t* deferred_resolve_ns
) {
    if (!queue) return 0;
    const uint64_t flush_started_ns = monotonic_now_ns();
    if (pfn_doeNativeQueueFlushBreakdown) {
        uint64_t wait_ns = 0;
        uint64_t copy_ns = 0;
        uint64_t resolve_ns = 0;
        pfn_doeNativeQueueFlushBreakdown(queue, &wait_ns, &copy_ns, &resolve_ns);
        if (wait_completed_ns) *wait_completed_ns += wait_ns;
        if (deferred_copy_ns) *deferred_copy_ns += copy_ns;
        if (deferred_resolve_ns) *deferred_resolve_ns += resolve_ns;
        return monotonic_now_ns() - flush_started_ns;
    }
    if (pfn_doeNativeQueueFlush) {
        pfn_doeNativeQueueFlush(queue);
        const uint64_t flush_ns = monotonic_now_ns() - flush_started_ns;
        if (wait_completed_ns) *wait_completed_ns += flush_ns;
        return flush_ns;
    }
    return 0;
}

static int submit_breakdown_enabled(void) {
    static int cached = -1;
    if (cached >= 0) return cached;
    const char* value = getenv("DOE_WEBGPU_SUBMIT_BREAKDOWN");
    if (!value || value[0] == '\0') return cached = 0;
    if (strcmp(value, "0") == 0) return cached = 0;
    if (strcmp(value, "false") == 0 || strcmp(value, "False") == 0 || strcmp(value, "FALSE") == 0) return cached = 0;
    return cached = 1;
}

#define DOE_QUEUE_SYNC_INFO_BACKEND_VULKAN 1u
#define DOE_QUEUE_SYNC_INFO_TIMELINE_SEMAPHORE 2u
#define DOE_QUEUE_SYNC_INFO_FENCE_POOL 4u
#define DOE_QUEUE_SYNC_INFO_DEFERRED_SUBMISSIONS 8u
#define DOE_QUEUE_PIPELINE_CACHE_INFO_BACKEND_VULKAN 1u
#define DOE_QUEUE_PIPELINE_CACHE_INFO_ACTIVE 2u
#define DOE_QUEUE_PIPELINE_CACHE_INFO_DISABLED 4u
#define DOE_QUEUE_PIPELINE_CACHE_INFO_SUPPORTED 8u
#define DOE_QUEUE_FAMILY_UNAVAILABLE 0xffffffffu
#define DOE_QUEUE_FAMILY_POLICY_PREFER_GRAPHICS_COMPUTE 0u
#define DOE_QUEUE_FAMILY_POLICY_PREFER_COMPUTE_ONLY 1u
#define DOE_QUEUE_FAMILY_POLICY_REQUIRE_COMPUTE_ONLY 2u
#define DOE_QUEUE_FAMILY_KIND_GRAPHICS_COMPUTE 0u
#define DOE_QUEUE_FAMILY_KIND_COMPUTE_ONLY 1u
#define DOE_DEFERRED_SYNC_POLICY_PREFER_TIMELINE_SEMAPHORE 0u
#define DOE_DEFERRED_SYNC_POLICY_REQUIRE_FENCE_POOL 1u

static void set_bool_property(napi_env env, napi_value obj, const char* name, bool value) {
    napi_value js_value;
    napi_get_boolean(env, value, &js_value);
    napi_set_named_property(env, obj, name, js_value);
}

static void set_string_property(napi_env env, napi_value obj, const char* name, const char* value) {
    napi_value js_value;
    napi_create_string_utf8(env, value, NAPI_AUTO_LENGTH, &js_value);
    napi_set_named_property(env, obj, name, js_value);
}

static void set_u64_property(napi_env env, napi_value obj, const char* name, uint64_t value) {
    napi_value js_value;
    napi_create_double(env, (double)value, &js_value);
    napi_set_named_property(env, obj, name, js_value);
}

static void set_optional_u32_property(napi_env env, napi_value obj, const char* name, uint32_t value) {
    if (value == DOE_QUEUE_FAMILY_UNAVAILABLE) return;
    napi_value js_value;
    napi_create_uint32(env, value, &js_value);
    napi_set_named_property(env, obj, name, js_value);
}

static void set_optional_bool_code_property(napi_env env, napi_value obj, const char* name, uint32_t value) {
    if (value == DOE_QUEUE_FAMILY_UNAVAILABLE) return;
    set_bool_property(env, obj, name, value != 0);
}

static const char* queue_family_policy_name(uint32_t value) {
    switch (value) {
        case DOE_QUEUE_FAMILY_POLICY_PREFER_GRAPHICS_COMPUTE:
            return "prefer_graphics_compute";
        case DOE_QUEUE_FAMILY_POLICY_PREFER_COMPUTE_ONLY:
            return "prefer_compute_only";
        case DOE_QUEUE_FAMILY_POLICY_REQUIRE_COMPUTE_ONLY:
            return "require_compute_only";
        default:
            return NULL;
    }
}

static const char* queue_family_kind_name(uint32_t value) {
    switch (value) {
        case DOE_QUEUE_FAMILY_KIND_GRAPHICS_COMPUTE:
            return "graphics_compute";
        case DOE_QUEUE_FAMILY_KIND_COMPUTE_ONLY:
            return "compute_only";
        default:
            return NULL;
    }
}

static const char* deferred_sync_policy_name(uint32_t value) {
    switch (value) {
        case DOE_DEFERRED_SYNC_POLICY_PREFER_TIMELINE_SEMAPHORE:
            return "prefer_timeline_semaphore";
        case DOE_DEFERRED_SYNC_POLICY_REQUIRE_FENCE_POOL:
            return "require_fence_pool";
        default:
            return NULL;
    }
}

static void set_optional_string_property(napi_env env, napi_value obj, const char* name, const char* value) {
    if (!value) return;
    napi_value js_value;
    napi_create_string_utf8(env, value, NAPI_AUTO_LENGTH, &js_value);
    napi_set_named_property(env, obj, name, js_value);
}

napi_value doe_native_fast_path_info(napi_env env, napi_callback_info info) {
    (void)info;
    CHECK_LIB_LOADED(env);
    napi_value result;
    napi_create_object(env, &result);
#if defined(__APPLE__)
    set_bool_property(env, result, "appleFastPathCompiled", true);
#else
    set_bool_property(env, result, "appleFastPathCompiled", false);
#endif
    set_bool_property(env, result, "queueFlush", pfn_doeNativeQueueFlush != NULL);
    set_bool_property(env, result, "queueFlushBreakdown", pfn_doeNativeQueueFlushBreakdown != NULL);
    set_bool_property(env, result, "queueWriteBufferBatch", pfn_doeNativeQueueWriteBufferBatch != NULL);
    set_bool_property(env, result, "queueWriteBufferBatchDataPtrs", pfn_doeNativeQueueWriteBufferBatchDataPtrs != NULL);
    set_bool_property(env, result, "computeDispatchFlush", pfn_doeNativeComputeDispatchFlush != NULL);
    set_bool_property(env, result, "computeDispatchFlushBreakdown", pfn_doeNativeComputeDispatchFlushBreakdown != NULL);
    set_bool_property(env, result, "computeDispatchBatchFlush", pfn_doeNativeComputeDispatchBatchFlush != NULL);
    set_bool_property(env, result, "computeDispatchBatchCopyFlush", pfn_doeNativeComputeDispatchBatchCopyFlush != NULL);
    set_bool_property(env, result, "computeDispatchBatchCopyFlushBreakdown", pfn_doeNativeComputeDispatchBatchCopyFlushBreakdown != NULL);
    set_bool_property(env, result, "computePrewarmDispatchBindings", pfn_doeNativeComputePrewarmDispatchBindings != NULL);
    set_bool_property(env, result, "bufferMapReadCopyUnmap", pfn_doeBufferMapReadCopyUnmapFlat != NULL);
    return result;
}

napi_value doe_queue_sync_info(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    CHECK_LIB_LOADED(env);
    WGPUQueue queue = unwrap_ptr(env, _args[0]);
    if (!queue) NAPI_THROW(env, "queueSyncInfo requires queue");
    if (!pfn_doeNativeQueueSyncInfo) {
        napi_value null_value;
        napi_get_null(env, &null_value);
        return null_value;
    }
    const uint32_t bits = pfn_doeNativeQueueSyncInfo(queue);
    napi_value result;
    napi_create_object(env, &result);
    set_bool_property(env, result, "backendVulkan", (bits & DOE_QUEUE_SYNC_INFO_BACKEND_VULKAN) != 0);
    set_bool_property(env, result, "timelineSemaphore", (bits & DOE_QUEUE_SYNC_INFO_TIMELINE_SEMAPHORE) != 0);
    set_bool_property(env, result, "fencePool", (bits & DOE_QUEUE_SYNC_INFO_FENCE_POOL) != 0);
    set_bool_property(env, result, "deferredSubmissions", (bits & DOE_QUEUE_SYNC_INFO_DEFERRED_SUBMISSIONS) != 0);
    if (pfn_doeNativeQueueFamilyPolicyCode) {
        set_optional_string_property(env, result, "queueFamilyPolicy", queue_family_policy_name(pfn_doeNativeQueueFamilyPolicyCode(queue)));
    }
    if (pfn_doeNativeQueueDeferredSubmissionSyncPolicyCode) {
        set_optional_string_property(env, result, "deferredSubmissionSyncPolicy", deferred_sync_policy_name(pfn_doeNativeQueueDeferredSubmissionSyncPolicyCode(queue)));
    }
    if (pfn_doeNativeQueueFamilyKindCode) {
        set_optional_string_property(env, result, "queueFamilyKind", queue_family_kind_name(pfn_doeNativeQueueFamilyKindCode(queue)));
    }
    if (pfn_doeNativeQueueFamilyIndex) {
        set_optional_u32_property(env, result, "queueFamilyIndex", pfn_doeNativeQueueFamilyIndex(queue));
    }
    if (pfn_doeNativeQueueFamilyQueueCount) {
        set_optional_u32_property(env, result, "queueFamilyQueueCount", pfn_doeNativeQueueFamilyQueueCount(queue));
    }
    if (pfn_doeNativeQueueFamilyTimestampValidBits) {
        set_optional_u32_property(env, result, "queueFamilyTimestampValidBits", pfn_doeNativeQueueFamilyTimestampValidBits(queue));
    }
    if (pfn_doeNativeQueueFamilySupportsGraphics) {
        set_optional_bool_code_property(env, result, "queueFamilySupportsGraphics", pfn_doeNativeQueueFamilySupportsGraphics(queue));
    }
    return result;
}

napi_value doe_queue_pipeline_cache_info(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    CHECK_LIB_LOADED(env);
    WGPUQueue queue = unwrap_ptr(env, _args[0]);
    if (!queue) NAPI_THROW(env, "queuePipelineCacheInfo requires queue");
    if (!pfn_doeNativeQueuePipelineCacheInfo) {
        napi_value null_value;
        napi_get_null(env, &null_value);
        return null_value;
    }
    const uint32_t bits = pfn_doeNativeQueuePipelineCacheInfo(queue);
    if ((bits & DOE_QUEUE_PIPELINE_CACHE_INFO_BACKEND_VULKAN) == 0) {
        napi_value null_value;
        napi_get_null(env, &null_value);
        return null_value;
    }
    const bool active = (bits & DOE_QUEUE_PIPELINE_CACHE_INFO_ACTIVE) != 0;
    const bool disabled = (bits & DOE_QUEUE_PIPELINE_CACHE_INFO_DISABLED) != 0;
    const bool supported = (bits & DOE_QUEUE_PIPELINE_CACHE_INFO_SUPPORTED) != 0;
    const char* reason = !supported
        ? "platform-unsupported"
        : disabled
            ? "cli-flag"
            : active
                ? "default"
                : "non-doe-backend";
    napi_value result;
    napi_create_object(env, &result);
    set_string_property(env, result, "backend", "vulkan");
    set_string_property(env, result, "state", active ? "enabled" : "disabled");
    set_string_property(env, result, "reason", reason);
    set_u64_property(
        env,
        result,
        "warmupCount",
        pfn_doeNativeQueuePipelineCacheWarmupCount ? pfn_doeNativeQueuePipelineCacheWarmupCount(queue) : 0
    );
    set_u64_property(
        env,
        result,
        "warmupNs",
        pfn_doeNativeQueuePipelineCacheWarmupNs ? pfn_doeNativeQueuePipelineCacheWarmupNs(queue) : 0
    );
    return result;
}

napi_value doe_queue_pipeline_cache_flush(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    CHECK_LIB_LOADED(env);
    WGPUQueue queue = unwrap_ptr(env, _args[0]);
    if (!queue) NAPI_THROW(env, "queuePipelineCacheFlush requires queue");
    if (pfn_doeNativeQueuePipelineCacheFlush) {
        pfn_doeNativeQueuePipelineCacheFlush(queue);
    }
    return NULL;
}

napi_value doe_queue_submit(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 2);
    CHECK_LIB_LOADED(env);
    WGPUQueue queue = unwrap_ptr(env, _args[0]);
    if (!queue) NAPI_THROW(env, "Invalid queue");
    uint32_t cmd_count = 0;
    napi_get_array_length(env, _args[1], &cmd_count);
    const int wants_submit_breakdown = submit_breakdown_enabled();
    if (cmd_count == 0) {
        return wants_submit_breakdown ? make_submit_breakdown(env, 0, 0, 0) : NULL;
    }
    const uint64_t command_replay_started_ns = wants_submit_breakdown ? monotonic_now_ns() : 0;
    if (cmd_count == 1) {
        napi_value elem;
        napi_get_element(env, _args[1], 0, &elem);
        WGPUCommandBuffer cmd = unwrap_ptr(env, elem);
        const uint64_t command_replay_ns = wants_submit_breakdown ? monotonic_now_ns() - command_replay_started_ns : 0;
        const uint64_t queue_submit_started_ns = wants_submit_breakdown ? monotonic_now_ns() : 0;
        pfn_wgpuQueueSubmit(queue, 1, &cmd);
        const uint64_t queue_submit_ns = wants_submit_breakdown ? monotonic_now_ns() - queue_submit_started_ns : 0;
        return wants_submit_breakdown ? make_submit_breakdown(env, command_replay_ns, queue_submit_ns, 0) : NULL;
    }
    WGPUCommandBuffer* cmds = (WGPUCommandBuffer*)calloc(cmd_count, sizeof(WGPUCommandBuffer));
    for (uint32_t i = 0; i < cmd_count; i++) {
        napi_value elem;
        napi_get_element(env, _args[1], i, &elem);
        cmds[i] = unwrap_ptr(env, elem);
    }
    const uint64_t command_replay_ns = wants_submit_breakdown ? monotonic_now_ns() - command_replay_started_ns : 0;
    const uint64_t queue_submit_started_ns = wants_submit_breakdown ? monotonic_now_ns() : 0;
    pfn_wgpuQueueSubmit(queue, cmd_count, cmds);
    const uint64_t queue_submit_ns = wants_submit_breakdown ? monotonic_now_ns() - queue_submit_started_ns : 0;
    free(cmds);
    return wants_submit_breakdown ? make_submit_breakdown(env, command_replay_ns, queue_submit_ns, 0) : NULL;
}

napi_value doe_queue_submit_one(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 2);
    CHECK_LIB_LOADED(env);
    WGPUQueue queue = unwrap_ptr(env, _args[0]);
    WGPUCommandBuffer cmd = unwrap_ptr(env, _args[1]);
    if (!queue || !cmd) NAPI_THROW(env, "queueSubmitOne requires queue and command buffer");
    const int wants_submit_breakdown = submit_breakdown_enabled();
    const uint64_t queue_submit_started_ns = wants_submit_breakdown ? monotonic_now_ns() : 0;
    pfn_wgpuQueueSubmit(queue, 1, &cmd);
    const uint64_t queue_submit_ns = wants_submit_breakdown ? monotonic_now_ns() - queue_submit_started_ns : 0;
    return wants_submit_breakdown ? make_submit_breakdown(env, 0, queue_submit_ns, 0) : NULL;
}

/* queueWriteBuffer(queue, buffer, offset, typedArray) */
napi_value doe_queue_write_buffer(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 4);
    CHECK_LIB_LOADED(env);
    WGPUQueue queue = unwrap_ptr(env, _args[0]);
    WGPUBuffer buf = unwrap_ptr(env, _args[1]);
    if (!queue || !buf) NAPI_THROW(env, "queueWriteBuffer requires queue and buffer");
    int64_t offset; napi_get_value_int64(env, _args[2], &offset);
    void* data = NULL;
    size_t byte_length = 0;
    bool is_typedarray = false;
    napi_is_typedarray(env, _args[3], &is_typedarray);
    if (is_typedarray) {
        napi_typedarray_type ta_type; size_t ta_length; napi_value ab; size_t byte_offset;
        napi_get_typedarray_info(env, _args[3], &ta_type, &ta_length, &data, &ab, &byte_offset);
        size_t elem_size = 1;
        switch (ta_type) {
            case napi_int8_array: case napi_uint8_array: case napi_uint8_clamped_array: elem_size = 1; break;
            case napi_int16_array: case napi_uint16_array: elem_size = 2; break;
            case napi_int32_array: case napi_uint32_array: case napi_float32_array: elem_size = 4; break;
            case napi_float64_array: case napi_bigint64_array: case napi_biguint64_array: elem_size = 8; break;
            default: elem_size = 1; break;
        }
        byte_length = ta_length * elem_size;
    } else {
        bool is_ab = false;
        napi_is_arraybuffer(env, _args[3], &is_ab);
        if (is_ab) {
            napi_get_arraybuffer_info(env, _args[3], &data, &byte_length);
        } else {
            bool is_buffer = false;
            napi_is_buffer(env, _args[3], &is_buffer);
            if (is_buffer) napi_get_buffer_info(env, _args[3], &data, &byte_length);
            else NAPI_THROW(env, "queueWriteBuffer: data must be TypedArray, ArrayBuffer, or Buffer");
        }
    }
    if (pfn_doeNativeQueueWriteBuffer) {
        pfn_doeNativeQueueWriteBuffer(queue, buf, (uint64_t)offset, data, byte_length);
    } else {
        pfn_wgpuQueueWriteBuffer(queue, buf, (uint64_t)offset, data, byte_length);
    }
    return NULL;
}

/* queueWriteBufferBatch(queue, buffers, offsets, sizes, data) */
napi_value doe_queue_write_buffer_batch(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 5);
    CHECK_LIB_LOADED(env);
    WGPUQueue queue = unwrap_ptr(env, _args[0]);
    if (!queue) NAPI_THROW(env, "queueWriteBufferBatch requires queue");

    bool is_array = false;
    napi_is_array(env, _args[1], &is_array);
    if (!is_array) NAPI_THROW(env, "queueWriteBufferBatch buffers must be an array");
    uint32_t entry_count = 0;
    napi_get_array_length(env, _args[1], &entry_count);
    if (entry_count == 0) {
        return NULL;
    }

    void* offset_bytes = NULL;
    size_t offset_byte_length = 0;
    void* size_bytes = NULL;
    size_t size_byte_length = 0;
    void* data_bytes = NULL;
    size_t data_byte_length = 0;
    extract_buffer_data(env, _args[2], &offset_bytes, &offset_byte_length);
    extract_buffer_data(env, _args[3], &size_bytes, &size_byte_length);
    extract_buffer_data(env, _args[4], &data_bytes, &data_byte_length);
    if (!offset_bytes || offset_byte_length < ((size_t)entry_count * sizeof(uint64_t))) {
        NAPI_THROW(env, "queueWriteBufferBatch offsets must be a BigUint64Array");
    }
    if (!size_bytes || size_byte_length < ((size_t)entry_count * sizeof(uint32_t))) {
        NAPI_THROW(env, "queueWriteBufferBatch sizes must be a Uint32Array");
    }
    if (!data_bytes && data_byte_length > 0) {
        NAPI_THROW(env, "queueWriteBufferBatch data must be buffer-backed");
    }

    size_t declared_data_byte_length = 0;
    for (uint32_t i = 0; i < entry_count; i++) {
        uint32_t byte_length = 0;
        memcpy(&byte_length, ((uint8_t*)size_bytes) + ((size_t)i * sizeof(uint32_t)), sizeof(uint32_t));
        if (declared_data_byte_length > SIZE_MAX - (size_t)byte_length) {
            NAPI_THROW(env, "queueWriteBufferBatch data length overflows size_t");
        }
        declared_data_byte_length += (size_t)byte_length;
    }
    if (declared_data_byte_length != data_byte_length) {
        NAPI_THROW(env, "queueWriteBufferBatch data length must equal declared sizes");
    }

    WGPUBuffer stack_buffers[QUEUE_WRITE_BATCH_STACK_MAX];
    uint64_t stack_offsets[QUEUE_WRITE_BATCH_STACK_MAX];
    uint32_t stack_sizes[QUEUE_WRITE_BATCH_STACK_MAX];
    WGPUBuffer* batch_buffers = stack_buffers;
    uint64_t* batch_offsets = stack_offsets;
    uint32_t* batch_sizes = stack_sizes;
    const bool heap_batch = entry_count > QUEUE_WRITE_BATCH_STACK_MAX;
    if (heap_batch) {
        batch_buffers = (WGPUBuffer*)malloc((size_t)entry_count * sizeof(*batch_buffers));
        batch_offsets = (uint64_t*)malloc((size_t)entry_count * sizeof(*batch_offsets));
        batch_sizes = (uint32_t*)malloc((size_t)entry_count * sizeof(*batch_sizes));
        if (!batch_buffers || !batch_offsets || !batch_sizes) {
            free(batch_buffers);
            free(batch_offsets);
            free(batch_sizes);
            NAPI_THROW(env, "queueWriteBufferBatch out of memory");
        }
    }

    for (uint32_t i = 0; i < entry_count; i++) {
        napi_value buffer_value;
        napi_get_element(env, _args[1], i, &buffer_value);
        WGPUBuffer buffer = unwrap_ptr(env, buffer_value);
        if (!buffer) {
            if (heap_batch) {
                free(batch_buffers);
                free(batch_offsets);
                free(batch_sizes);
            }
            napi_throw_error(env, "DOE_ERROR", "queueWriteBufferBatch entry requires buffer");
            return NULL;
        }

        uint64_t offset = 0;
        uint32_t byte_length = 0;
        memcpy(&offset, ((uint8_t*)offset_bytes) + ((size_t)i * sizeof(uint64_t)), sizeof(uint64_t));
        memcpy(&byte_length, ((uint8_t*)size_bytes) + ((size_t)i * sizeof(uint32_t)), sizeof(uint32_t));
        batch_buffers[i] = buffer;
        batch_offsets[i] = offset;
        batch_sizes[i] = byte_length;
    }

    const uint8_t empty_batch_data = 0;
    const uint8_t* batch_data = data_bytes ? (const uint8_t*)data_bytes : &empty_batch_data;
    if (pfn_doeNativeQueueWriteBufferBatch) {
        pfn_doeNativeQueueWriteBufferBatch(
            queue,
            (size_t)entry_count,
            batch_buffers,
            batch_offsets,
            batch_sizes,
            batch_data
        );
    } else {
        size_t data_offset = 0;
        for (uint32_t i = 0; i < entry_count; i++) {
            const size_t byte_length = (size_t)batch_sizes[i];
            if (pfn_doeNativeQueueWriteBuffer) {
                pfn_doeNativeQueueWriteBuffer(
                    queue,
                    batch_buffers[i],
                    batch_offsets[i],
                    batch_data + data_offset,
                    byte_length
                );
            } else {
                pfn_wgpuQueueWriteBuffer(
                    queue,
                    batch_buffers[i],
                    batch_offsets[i],
                    batch_data + data_offset,
                    byte_length
                );
            }
            data_offset += byte_length;
        }
    }
    if (heap_batch) {
        free(batch_buffers);
        free(batch_offsets);
        free(batch_sizes);
    }
    return NULL;
}

/* queueWriteBufferBatchDataPtrs(queue, buffers, offsets, sizes, data) */
napi_value doe_queue_write_buffer_batch_data_ptrs(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 5);
    CHECK_LIB_LOADED(env);
    WGPUQueue queue = unwrap_ptr(env, _args[0]);
    if (!queue) NAPI_THROW(env, "queueWriteBufferBatchDataPtrs requires queue");

    bool buffers_is_array = false;
    napi_is_array(env, _args[1], &buffers_is_array);
    if (!buffers_is_array) NAPI_THROW(env, "queueWriteBufferBatchDataPtrs buffers must be an array");

    bool data_is_array = false;
    napi_is_array(env, _args[4], &data_is_array);
    if (!data_is_array) NAPI_THROW(env, "queueWriteBufferBatchDataPtrs data must be an array");

    uint32_t entry_count = 0;
    napi_get_array_length(env, _args[1], &entry_count);
    uint32_t data_count = 0;
    napi_get_array_length(env, _args[4], &data_count);
    if (data_count != entry_count) {
        NAPI_THROW(env, "queueWriteBufferBatchDataPtrs data length must match buffers length");
    }
    if (entry_count == 0) {
        return NULL;
    }

    void* offset_bytes = NULL;
    size_t offset_byte_length = 0;
    void* size_bytes = NULL;
    size_t size_byte_length = 0;
    extract_buffer_data(env, _args[2], &offset_bytes, &offset_byte_length);
    extract_buffer_data(env, _args[3], &size_bytes, &size_byte_length);
    if (!offset_bytes || offset_byte_length < ((size_t)entry_count * sizeof(uint64_t))) {
        NAPI_THROW(env, "queueWriteBufferBatchDataPtrs offsets must be a BigUint64Array");
    }
    if (!size_bytes || size_byte_length < ((size_t)entry_count * sizeof(uint32_t))) {
        NAPI_THROW(env, "queueWriteBufferBatchDataPtrs sizes must be a Uint32Array");
    }

    WGPUBuffer stack_buffers[QUEUE_WRITE_BATCH_STACK_MAX];
    uint64_t stack_offsets[QUEUE_WRITE_BATCH_STACK_MAX];
    uint32_t stack_sizes[QUEUE_WRITE_BATCH_STACK_MAX];
    const void* stack_data_ptrs[QUEUE_WRITE_BATCH_STACK_MAX];
    WGPUBuffer* batch_buffers = stack_buffers;
    uint64_t* batch_offsets = stack_offsets;
    uint32_t* batch_sizes = stack_sizes;
    const void** batch_data_ptrs = stack_data_ptrs;
    const bool heap_batch = entry_count > QUEUE_WRITE_BATCH_STACK_MAX;
    if (heap_batch) {
        batch_buffers = (WGPUBuffer*)malloc((size_t)entry_count * sizeof(*batch_buffers));
        batch_offsets = (uint64_t*)malloc((size_t)entry_count * sizeof(*batch_offsets));
        batch_sizes = (uint32_t*)malloc((size_t)entry_count * sizeof(*batch_sizes));
        batch_data_ptrs = (const void**)malloc((size_t)entry_count * sizeof(*batch_data_ptrs));
        if (!batch_buffers || !batch_offsets || !batch_sizes || !batch_data_ptrs) {
            free(batch_buffers);
            free(batch_offsets);
            free(batch_sizes);
            free((void*)batch_data_ptrs);
            NAPI_THROW(env, "queueWriteBufferBatchDataPtrs out of memory");
        }
    }

    const uint8_t empty_batch_data = 0;
    for (uint32_t i = 0; i < entry_count; i++) {
        napi_value buffer_value;
        napi_get_element(env, _args[1], i, &buffer_value);
        WGPUBuffer buffer = unwrap_ptr(env, buffer_value);
        if (!buffer) {
            if (heap_batch) {
                free(batch_buffers);
                free(batch_offsets);
                free(batch_sizes);
                free((void*)batch_data_ptrs);
            }
            napi_throw_error(env, "DOE_ERROR", "queueWriteBufferBatchDataPtrs entry requires buffer");
            return NULL;
        }

        napi_value data_value;
        napi_get_element(env, _args[4], i, &data_value);
        void* data_ptr = NULL;
        size_t data_byte_length = 0;
        extract_buffer_data(env, data_value, &data_ptr, &data_byte_length);

        uint64_t offset = 0;
        uint32_t byte_length = 0;
        memcpy(&offset, ((uint8_t*)offset_bytes) + ((size_t)i * sizeof(uint64_t)), sizeof(uint64_t));
        memcpy(&byte_length, ((uint8_t*)size_bytes) + ((size_t)i * sizeof(uint32_t)), sizeof(uint32_t));
        if ((size_t)byte_length != data_byte_length) {
            if (heap_batch) {
                free(batch_buffers);
                free(batch_offsets);
                free(batch_sizes);
                free((void*)batch_data_ptrs);
            }
            napi_throw_error(env, "DOE_ERROR", "queueWriteBufferBatchDataPtrs data length must equal declared size");
            return NULL;
        }
        if (!data_ptr && byte_length > 0) {
            if (heap_batch) {
                free(batch_buffers);
                free(batch_offsets);
                free(batch_sizes);
                free((void*)batch_data_ptrs);
            }
            napi_throw_error(env, "DOE_ERROR", "queueWriteBufferBatchDataPtrs data must be buffer-backed");
            return NULL;
        }

        batch_buffers[i] = buffer;
        batch_offsets[i] = offset;
        batch_sizes[i] = byte_length;
        batch_data_ptrs[i] = data_ptr ? data_ptr : &empty_batch_data;
    }

    if (pfn_doeNativeQueueWriteBufferBatchDataPtrs) {
        pfn_doeNativeQueueWriteBufferBatchDataPtrs(
            queue,
            (size_t)entry_count,
            batch_buffers,
            batch_offsets,
            batch_sizes,
            batch_data_ptrs
        );
    } else {
        for (uint32_t i = 0; i < entry_count; i++) {
            const size_t byte_length = (size_t)batch_sizes[i];
            if (pfn_doeNativeQueueWriteBuffer) {
                pfn_doeNativeQueueWriteBuffer(
                    queue,
                    batch_buffers[i],
                    batch_offsets[i],
                    batch_data_ptrs[i],
                    byte_length
                );
            } else {
                pfn_wgpuQueueWriteBuffer(
                    queue,
                    batch_buffers[i],
                    batch_offsets[i],
                    batch_data_ptrs[i],
                    byte_length
                );
            }
        }
    }
    if (heap_batch) {
        free(batch_buffers);
        free(batch_offsets);
        free(batch_sizes);
        free((void*)batch_data_ptrs);
    }
    return NULL;
}

/* queueFlush(instance, queue) — wait for all pending GPU work to complete. */
napi_value doe_queue_flush(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 2);
    CHECK_LIB_LOADED(env);
    WGPUInstance inst = unwrap_ptr(env, _args[0]);
    WGPUQueue queue = unwrap_ptr(env, _args[1]);
    if (!queue) NAPI_THROW(env, "queueFlush requires queue");
    if (pfn_doeNativeQueueFlushBreakdown) {
        uint64_t wait_completed_ns = 0;
        uint64_t deferred_copy_ns = 0;
        uint64_t deferred_resolve_ns = 0;
        napi_value result;
        napi_value wait_value;
        napi_value copy_value;
        napi_value resolve_value;
        pfn_doeNativeQueueFlushBreakdown(queue, &wait_completed_ns, &deferred_copy_ns, &deferred_resolve_ns);
        napi_create_object(env, &result);
        napi_create_double(env, (double)wait_completed_ns, &wait_value);
        napi_create_double(env, (double)deferred_copy_ns, &copy_value);
        napi_create_double(env, (double)deferred_resolve_ns, &resolve_value);
        napi_set_named_property(env, result, "waitCompletedNs", wait_value);
        napi_set_named_property(env, result, "deferredCopyNs", copy_value);
        napi_set_named_property(env, result, "deferredResolveNs", resolve_value);
        return result;
    }
    if (pfn_doeNativeQueueFlush) { pfn_doeNativeQueueFlush(queue); return NULL; }
    if (!inst) {
        napi_throw_error(env, "DOE_QUEUE_UNAVAILABLE", "queueFlush requires instance when doeNativeQueueFlush is unavailable");
        return NULL;
    }
    QueueWorkDoneResult result = {0};
    WGPUQueueWorkDoneCallbackInfo cb_info = {
        .nextInChain = NULL, .mode = WGPU_CALLBACK_MODE_WAIT_ANY_ONLY,
        .callback = queue_work_done_callback, .userdata1 = &result, .userdata2 = NULL,
    };
    WGPUFuture future = pfn_wgpuQueueOnSubmittedWorkDone(queue, cb_info);
    if (future.id == 0) NAPI_THROW(env, "queueFlush: queue work-done future unavailable");
    uint64_t start_ns = monotonic_now_ns();
    while (!result.done) {
        WGPUFutureWaitInfo wait_info = { .future = future, .completed = 0 };
        uint32_t wait_status = pfn_wgpuInstanceWaitAny(inst, 1, &wait_info, 0);
        if (wait_status == WGPU_WAIT_STATUS_SUCCESS) {
            if (!result.done) pfn_wgpuInstanceProcessEvents(inst);
        } else if (wait_status == WGPU_WAIT_STATUS_TIMED_OUT) {
            pfn_wgpuInstanceProcessEvents(inst);
            if (monotonic_now_ns() - start_ns >= current_timeout_ns()) {
                napi_throw_error(env, "DOE_QUEUE_TIMEOUT", "queueFlush: queue wait timed out");
                return NULL;
            }
            wait_slice();
        } else if (wait_status == WGPU_WAIT_STATUS_ERROR) {
            napi_throw_error(env, "DOE_QUEUE_UNAVAILABLE", "queueFlush: wgpuInstanceWaitAny failed");
            return NULL;
        } else {
            NAPI_THROW(env, "queueFlush: unsupported wait status");
        }
    }
    if (result.status != WGPU_QUEUE_WORK_DONE_STATUS_SUCCESS)
        return throw_status_error(env, "DOE_QUEUE_FLUSH_ERROR", "queueFlush: queue work did not complete", result.status, result.message);
    return NULL;
}

/* prewarmPreparedDispatches(queue, dispatchCommands)
 * Setup-only Vulkan path: prepare pipeline/layout/descriptor state without
 * recording or submitting GPU commands. */
napi_value doe_prewarm_prepared_dispatches(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 2);
    CHECK_LIB_LOADED(env);
    WGPUQueue queue = unwrap_ptr(env, _args[0]);
    napi_value commands = _args[1];
    if (!queue) NAPI_THROW(env, "prewarmPreparedDispatches requires queue");
    if (!pfn_doeNativeComputePrewarmDispatchBindings) {
        napi_value zero;
        napi_create_uint32(env, 0, &zero);
        return zero;
    }
    bool is_array = false;
    napi_is_array(env, commands, &is_array);
    if (!is_array) NAPI_THROW(env, "prewarmPreparedDispatches requires a dispatch command array");
    uint32_t cmd_count = 0;
    napi_get_array_length(env, commands, &cmd_count);
    if (cmd_count == 0) {
        napi_value zero;
        napi_create_uint32(env, 0, &zero);
        return zero;
    }

    const size_t bind_group_slots = (size_t)cmd_count * BATCH_MAX_BIND_GROUPS;
    const int use_stack_batch = cmd_count <= BATCH_STACK_DISPATCHES;
    void* stack_pipelines[BATCH_STACK_DISPATCHES];
    void* stack_bind_groups[BATCH_STACK_DISPATCHES * BATCH_MAX_BIND_GROUPS];
    uint32_t stack_bg_counts[BATCH_STACK_DISPATCHES];
    void** pipelines = use_stack_batch ? stack_pipelines : (void**)calloc(cmd_count, sizeof(void*));
    void** bind_groups = use_stack_batch ? stack_bind_groups : (void**)calloc(bind_group_slots, sizeof(void*));
    uint32_t* bg_counts = use_stack_batch ? stack_bg_counts : (uint32_t*)calloc(cmd_count, sizeof(uint32_t));
    if (!pipelines || !bind_groups || !bg_counts) {
        if (!use_stack_batch) {
            free(pipelines);
            free(bind_groups);
            free(bg_counts);
        }
        NAPI_THROW(env, "prewarmPreparedDispatches: out of memory while packing dispatch bindings");
    }
    if (use_stack_batch) {
        memset(pipelines, 0, cmd_count * sizeof(void*));
        memset(bind_groups, 0, bind_group_slots * sizeof(void*));
        memset(bg_counts, 0, cmd_count * sizeof(uint32_t));
    }

    for (uint32_t i = 0; i < cmd_count; i++) {
        napi_value cmd;
        napi_get_element(env, commands, i, &cmd);
        if (get_command_type(env, cmd) != 0) continue;
        pipelines[i] = get_command_ptr(env, cmd, "p", 1);
        void* bg_ptrs[BATCH_MAX_BIND_GROUPS] = {NULL};
        const uint32_t bg_count = read_command_bind_groups(env, cmd, bg_ptrs, BATCH_MAX_BIND_GROUPS);
        bg_counts[i] = bg_count;
        for (uint32_t j = 0; j < bg_count; j++) {
            bind_groups[((size_t)i * BATCH_MAX_BIND_GROUPS) + j] = bg_ptrs[j];
        }
    }

    const uint32_t prepared = pfn_doeNativeComputePrewarmDispatchBindings(
        queue,
        cmd_count,
        pipelines,
        bind_groups,
        bg_counts
    );
    if (!use_stack_batch) {
        free(pipelines);
        free(bind_groups);
        free(bg_counts);
    }
    napi_value result;
    napi_create_uint32(env, prepared, &result);
    return result;
}

/* submitBatched(device, queue, commandsArray)
 * Fast path: a single dispatch or a dispatch batch ending in a copy.
 * Dispatch-only batches remain on the recorded command-buffer path until the
 * direct Vulkan batch replay has exact multi-dispatch parity. */
napi_value doe_queue_submit_batched(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 3);
    CHECK_LIB_LOADED(env);
    WGPUDevice device = unwrap_ptr(env, _args[0]);
    WGPUQueue queue = unwrap_ptr(env, _args[1]);
    napi_value commands = _args[2];
    if (!device || !queue) NAPI_THROW(env, "submitBatched requires device and queue");
    uint32_t cmd_count = 0;
    napi_get_array_length(env, commands, &cmd_count);
    if (cmd_count == 0) return NULL;
    const int wants_submit_breakdown = submit_breakdown_enabled();

#if defined(__APPLE__)
    if (pfn_doeNativeComputeDispatchFlush && (cmd_count == 1 || cmd_count == 2)) {
        napi_value cmd0; napi_get_element(env, commands, 0, &cmd0);
        uint32_t t0 = get_command_type(env, cmd0);
        uint32_t t1 = UINT32_MAX;
        napi_value cmd1 = NULL;
        if (cmd_count == 2) { napi_get_element(env, commands, 1, &cmd1); t1 = get_command_type(env, cmd1); }
        if (t0 == 0 && (cmd_count == 1 || t1 == 1)) {
            void* pipeline = get_command_ptr(env, cmd0, "p", 1);
            void* bg_ptrs[BATCH_MAX_BIND_GROUPS] = {NULL};
            uint32_t bg_count = read_command_bind_groups(env, cmd0, bg_ptrs, BATCH_MAX_BIND_GROUPS);
            uint32_t dx = get_command_u32(env, cmd0, "x", 3);
            uint32_t dy = get_command_u32(env, cmd0, "y", 4);
            uint32_t dz = get_command_u32(env, cmd0, "z", 5);
            void* copy_src = NULL; uint64_t copy_src_off = 0;
            void* copy_dst = NULL; uint64_t copy_dst_off = 0;
            uint64_t copy_size = 0;
            if (cmd_count == 2) {
                copy_src     = get_command_ptr(env, cmd1, "s", 1);
                copy_dst     = get_command_ptr(env, cmd1, "d", 3);
                copy_src_off = (uint64_t)get_command_i64(env, cmd1, "so", 2);
                copy_dst_off = (uint64_t)get_command_i64(env, cmd1, "do", 4);
                copy_size    = (uint64_t)get_command_i64(env, cmd1, "sz", 5);
            }
            if (wants_submit_breakdown && pfn_doeNativeComputeDispatchFlushBreakdown) {
                uint64_t breakdown[DOE_DISPATCH_FLUSH_BREAKDOWN_FIELD_COUNT] = {0};
                pfn_doeNativeComputeDispatchFlushBreakdown(queue, pipeline, (void**)bg_ptrs, bg_count,
                    dx, dy, dz, copy_src, copy_src_off, copy_dst, copy_dst_off, copy_size, breakdown);
                return make_submit_breakdown_full(
                    env,
                    breakdown[DOE_DISPATCH_FLUSH_BREAKDOWN_COMMAND_REPLAY],
                    breakdown[DOE_DISPATCH_FLUSH_BREAKDOWN_QUEUE_SUBMIT],
                    0,
                    0,
                    0,
                    0,
                    breakdown[DOE_DISPATCH_FLUSH_BREAKDOWN_COMMAND_BUFFER_END],
                    breakdown[DOE_DISPATCH_FLUSH_BREAKDOWN_SYNC_PREPARE],
                    breakdown[DOE_DISPATCH_FLUSH_BREAKDOWN_DRIVER_SUBMIT],
                    breakdown[DOE_DISPATCH_FLUSH_BREAKDOWN_COMMAND_REPLAY_PREPARE],
                    breakdown[DOE_DISPATCH_FLUSH_BREAKDOWN_COMMAND_REPLAY_RECORD],
                    breakdown[DOE_DISPATCH_FLUSH_BREAKDOWN_COMMAND_REPLAY_COPY]
                );
            }
            if (wants_submit_breakdown) {
                const uint64_t queue_submit_started_ns = monotonic_now_ns();
                pfn_doeNativeComputeDispatchFlush(queue, pipeline, (void**)bg_ptrs, bg_count,
                    dx, dy, dz, copy_src, copy_src_off, copy_dst, copy_dst_off, copy_size);
                const uint64_t queue_submit_ns = monotonic_now_ns() - queue_submit_started_ns;
                return make_submit_breakdown(env, 0, queue_submit_ns, 0);
            }
            pfn_doeNativeComputeDispatchFlush(queue, pipeline, (void**)bg_ptrs, bg_count,
                dx, dy, dz, copy_src, copy_src_off, copy_dst, copy_dst_off, copy_size);
            return NULL;
        }
    }
#endif

    if (pfn_doeNativeComputeDispatchBatchCopyFlush && cmd_count >= 2) {
        napi_value copy_cmd;
        napi_get_element(env, commands, cmd_count - 1, &copy_cmd);
        if (get_command_type(env, copy_cmd) == 1) {
            const size_t dispatch_count = (size_t)(cmd_count - 1);
            const size_t bind_group_slots = dispatch_count * BATCH_MAX_BIND_GROUPS;
            const size_t dispatch_dims_count = dispatch_count * 3;
            const int use_stack_batch = dispatch_count <= BATCH_STACK_DISPATCHES;
            void* stack_pipelines[BATCH_STACK_DISPATCHES];
            void* stack_bind_groups[BATCH_STACK_DISPATCHES * BATCH_MAX_BIND_GROUPS];
            uint32_t stack_bg_counts[BATCH_STACK_DISPATCHES];
            uint32_t stack_dispatch_dims[BATCH_STACK_DISPATCHES * 3];
            void** pipelines = use_stack_batch ? stack_pipelines : (void**)malloc(dispatch_count * sizeof(void*));
            void** bind_groups = use_stack_batch ? stack_bind_groups : (void**)malloc(bind_group_slots * sizeof(void*));
            uint32_t* bg_counts = use_stack_batch ? stack_bg_counts : (uint32_t*)malloc(dispatch_count * sizeof(uint32_t));
            uint32_t* dispatch_dims = use_stack_batch ? stack_dispatch_dims : (uint32_t*)malloc(dispatch_dims_count * sizeof(uint32_t));
            if (!pipelines || !bind_groups || !bg_counts || !dispatch_dims) {
                if (!use_stack_batch) {
                    free(pipelines);
                    free(bind_groups);
                    free(bg_counts);
                    free(dispatch_dims);
                }
                NAPI_THROW(env, "submitBatched: out of memory while packing dispatch-copy batch");
            }
            int dispatch_then_copy = 1;
            const uint64_t command_replay_started_ns = wants_submit_breakdown ? monotonic_now_ns() : 0;
            for (uint32_t i = 0; i < dispatch_count; i++) {
                napi_value cmd;
                napi_get_element(env, commands, i, &cmd);
                if (get_command_type(env, cmd) != 0) {
                    dispatch_then_copy = 0;
                    break;
                }
                pipelines[i] = get_command_ptr(env, cmd, "p", 1);
                void* bg_ptrs[BATCH_MAX_BIND_GROUPS] = {NULL};
                uint32_t bg_count = read_command_bind_groups(env, cmd, bg_ptrs, BATCH_MAX_BIND_GROUPS);
                bg_counts[i] = bg_count;
                for (uint32_t j = 0; j < bg_count; j++) {
                    bind_groups[(i * BATCH_MAX_BIND_GROUPS) + j] = bg_ptrs[j];
                }
                dispatch_dims[(i * 3)] = get_command_u32(env, cmd, "x", 3);
                dispatch_dims[(i * 3) + 1] = get_command_u32(env, cmd, "y", 4);
                dispatch_dims[(i * 3) + 2] = get_command_u32(env, cmd, "z", 5);
            }
            if (!dispatch_then_copy) {
                if (!use_stack_batch) {
                    free(pipelines);
                    free(bind_groups);
                    free(bg_counts);
                    free(dispatch_dims);
                }
            } else {
                void* copy_src = get_command_ptr(env, copy_cmd, "s", 1);
                void* copy_dst = get_command_ptr(env, copy_cmd, "d", 3);
                const uint64_t copy_src_off = (uint64_t)get_command_i64(env, copy_cmd, "so", 2);
                const uint64_t copy_dst_off = (uint64_t)get_command_i64(env, copy_cmd, "do", 4);
                const uint64_t copy_size = (uint64_t)get_command_i64(env, copy_cmd, "sz", 5);
                const uint64_t command_replay_ns = wants_submit_breakdown ? monotonic_now_ns() - command_replay_started_ns : 0;
                const uint64_t queue_submit_started_ns = wants_submit_breakdown ? monotonic_now_ns() : 0;
                uint64_t breakdown[DOE_DISPATCH_FLUSH_BREAKDOWN_FIELD_COUNT] = {0};
                if (wants_submit_breakdown && pfn_doeNativeComputeDispatchBatchCopyFlushBreakdown) {
                    pfn_doeNativeComputeDispatchBatchCopyFlushBreakdown(queue, dispatch_count, pipelines, bind_groups, bg_counts, dispatch_dims,
                        copy_src, copy_src_off, copy_dst, copy_dst_off, copy_size, breakdown);
                } else {
                    pfn_doeNativeComputeDispatchBatchCopyFlush(queue, dispatch_count, pipelines, bind_groups, bg_counts, dispatch_dims,
                        copy_src, copy_src_off, copy_dst, copy_dst_off, copy_size);
                }
                const uint64_t queue_submit_ns = wants_submit_breakdown ? monotonic_now_ns() - queue_submit_started_ns : 0;
                if (!use_stack_batch) {
                    free(pipelines);
                    free(bind_groups);
                    free(bg_counts);
                    free(dispatch_dims);
                }
                if (wants_submit_breakdown && pfn_doeNativeComputeDispatchBatchCopyFlushBreakdown) {
                    return make_submit_breakdown_full(
                        env,
                        command_replay_ns + breakdown[DOE_DISPATCH_FLUSH_BREAKDOWN_COMMAND_REPLAY],
                        breakdown[DOE_DISPATCH_FLUSH_BREAKDOWN_QUEUE_SUBMIT],
                        0,
                        0,
                        0,
                        0,
                        breakdown[DOE_DISPATCH_FLUSH_BREAKDOWN_COMMAND_BUFFER_END],
                        breakdown[DOE_DISPATCH_FLUSH_BREAKDOWN_SYNC_PREPARE],
                        breakdown[DOE_DISPATCH_FLUSH_BREAKDOWN_DRIVER_SUBMIT],
                        breakdown[DOE_DISPATCH_FLUSH_BREAKDOWN_COMMAND_REPLAY_PREPARE],
                        breakdown[DOE_DISPATCH_FLUSH_BREAKDOWN_COMMAND_REPLAY_RECORD],
                        breakdown[DOE_DISPATCH_FLUSH_BREAKDOWN_COMMAND_REPLAY_COPY]
                    );
                }
                if (wants_submit_breakdown) {
                    return make_submit_breakdown(env, command_replay_ns, queue_submit_ns, 0);
                }
                return NULL;
            }
        }
    }

    if (pfn_doeNativeComputeDispatchBatchFlush && cmd_count == 1) {
        int all_dispatch = 1;
        for (uint32_t i = 0; i < cmd_count; i++) {
            napi_value cmd;
            napi_get_element(env, commands, i, &cmd);
            if (get_command_type(env, cmd) != 0) {
                all_dispatch = 0;
                break;
            }
        }
        if (all_dispatch) {
            const size_t dispatch_count = (size_t)cmd_count;
            const size_t bind_group_slots = dispatch_count * BATCH_MAX_BIND_GROUPS;
            const size_t dispatch_dims_count = dispatch_count * 3;
            const int use_stack_batch = dispatch_count <= BATCH_STACK_DISPATCHES;
            void* stack_pipelines[BATCH_STACK_DISPATCHES];
            void* stack_bind_groups[BATCH_STACK_DISPATCHES * BATCH_MAX_BIND_GROUPS];
            uint32_t stack_bg_counts[BATCH_STACK_DISPATCHES];
            uint32_t stack_dispatch_dims[BATCH_STACK_DISPATCHES * 3];
            void** pipelines = use_stack_batch ? stack_pipelines : (void**)malloc(dispatch_count * sizeof(void*));
            void** bind_groups = use_stack_batch ? stack_bind_groups : (void**)malloc(bind_group_slots * sizeof(void*));
            uint32_t* bg_counts = use_stack_batch ? stack_bg_counts : (uint32_t*)malloc(dispatch_count * sizeof(uint32_t));
            uint32_t* dispatch_dims = use_stack_batch ? stack_dispatch_dims : (uint32_t*)malloc(dispatch_dims_count * sizeof(uint32_t));
            if (!pipelines || !bind_groups || !bg_counts || !dispatch_dims) {
                if (!use_stack_batch) {
                    free(pipelines);
                    free(bind_groups);
                    free(bg_counts);
                    free(dispatch_dims);
                }
                NAPI_THROW(env, "submitBatched: out of memory while packing dispatch batch");
            }
            const uint64_t command_replay_started_ns = wants_submit_breakdown ? monotonic_now_ns() : 0;
            for (uint32_t i = 0; i < cmd_count; i++) {
                napi_value cmd;
                napi_get_element(env, commands, i, &cmd);
                pipelines[i] = get_command_ptr(env, cmd, "p", 1);
                void* bg_ptrs[BATCH_MAX_BIND_GROUPS] = {NULL};
                uint32_t bg_count = read_command_bind_groups(env, cmd, bg_ptrs, BATCH_MAX_BIND_GROUPS);
                bg_counts[i] = bg_count;
                for (uint32_t j = 0; j < bg_count; j++) {
                    bind_groups[(i * BATCH_MAX_BIND_GROUPS) + j] = bg_ptrs[j];
                }
                dispatch_dims[(i * 3)] = get_command_u32(env, cmd, "x", 3);
                dispatch_dims[(i * 3) + 1] = get_command_u32(env, cmd, "y", 4);
                dispatch_dims[(i * 3) + 2] = get_command_u32(env, cmd, "z", 5);
            }
            const uint64_t command_replay_ns = wants_submit_breakdown ? monotonic_now_ns() - command_replay_started_ns : 0;
            const uint64_t queue_submit_started_ns = wants_submit_breakdown ? monotonic_now_ns() : 0;
            uint64_t breakdown[DOE_DISPATCH_FLUSH_BREAKDOWN_FIELD_COUNT] = {0};
            if (wants_submit_breakdown && pfn_doeNativeComputeDispatchBatchCopyFlushBreakdown) {
                pfn_doeNativeComputeDispatchBatchCopyFlushBreakdown(queue, dispatch_count, pipelines, bind_groups, bg_counts, dispatch_dims,
                    NULL, 0, NULL, 0, 0, breakdown);
            } else {
                pfn_doeNativeComputeDispatchBatchFlush(queue, dispatch_count, pipelines, bind_groups, bg_counts, dispatch_dims);
            }
            const uint64_t queue_submit_ns = wants_submit_breakdown ? monotonic_now_ns() - queue_submit_started_ns : 0;
            if (!use_stack_batch) {
                free(pipelines);
                free(bind_groups);
                free(bg_counts);
                free(dispatch_dims);
            }
            if (wants_submit_breakdown && pfn_doeNativeComputeDispatchBatchCopyFlushBreakdown) {
                return make_submit_breakdown_full(
                    env,
                    command_replay_ns + breakdown[DOE_DISPATCH_FLUSH_BREAKDOWN_COMMAND_REPLAY],
                    breakdown[DOE_DISPATCH_FLUSH_BREAKDOWN_QUEUE_SUBMIT],
                    0,
                    breakdown[DOE_DISPATCH_FLUSH_BREAKDOWN_WAIT_COMPLETED],
                    breakdown[DOE_DISPATCH_FLUSH_BREAKDOWN_DEFERRED_COPY],
                    breakdown[DOE_DISPATCH_FLUSH_BREAKDOWN_DEFERRED_RESOLVE],
                    breakdown[DOE_DISPATCH_FLUSH_BREAKDOWN_COMMAND_BUFFER_END],
                    breakdown[DOE_DISPATCH_FLUSH_BREAKDOWN_SYNC_PREPARE],
                    breakdown[DOE_DISPATCH_FLUSH_BREAKDOWN_DRIVER_SUBMIT],
                    breakdown[DOE_DISPATCH_FLUSH_BREAKDOWN_COMMAND_REPLAY_PREPARE],
                    breakdown[DOE_DISPATCH_FLUSH_BREAKDOWN_COMMAND_REPLAY_RECORD],
                    breakdown[DOE_DISPATCH_FLUSH_BREAKDOWN_COMMAND_REPLAY_COPY]
                );
            }
            if (wants_submit_breakdown) {
                return make_submit_breakdown(env, command_replay_ns, queue_submit_ns, 0);
            }
            return NULL;
        }
    }

    int flush_after_submit = 0;
    if (cmd_count == 2) {
        napi_value cmd0, cmd1;
        napi_get_element(env, commands, 0, &cmd0);
        napi_get_element(env, commands, 1, &cmd1);
        if (get_command_type(env, cmd0) == 0 && get_command_type(env, cmd1) == 1)
            flush_after_submit = 1;
    }
    const uint64_t command_replay_started_ns = wants_submit_breakdown ? monotonic_now_ns() : 0;
    WGPUCommandEncoder encoder = pfn_wgpuDeviceCreateCommandEncoder(device, NULL);
    WGPUComputePassEncoder pass = NULL;
    void* current_pipeline = NULL;
    void* current_bind_groups[BATCH_MAX_BIND_GROUPS] = {NULL};
    if (!encoder) NAPI_THROW(env, "submitBatched: createCommandEncoder failed");
    for (uint32_t i = 0; i < cmd_count; i++) {
        napi_value cmd; napi_get_element(env, commands, i, &cmd);
        uint32_t type = get_command_type(env, cmd);
        if (type == 0) {
            if (!pass) {
                pass = pfn_wgpuCommandEncoderBeginComputePass(encoder, NULL);
                if (!pass) {
                    pfn_wgpuCommandEncoderRelease(encoder);
                    NAPI_THROW(env, "submitBatched: beginComputePass failed");
                }
                current_pipeline = NULL;
                memset(current_bind_groups, 0, sizeof(current_bind_groups));
            }
            void* pipeline = get_command_ptr(env, cmd, "p", 1);
            if (pipeline != current_pipeline) {
                pfn_wgpuComputePassEncoderSetPipeline(pass, pipeline);
                current_pipeline = pipeline;
                memset(current_bind_groups, 0, sizeof(current_bind_groups));
            }
            void* bind_groups[BATCH_MAX_BIND_GROUPS] = {NULL};
            uint32_t bg_count = read_command_bind_groups(env, cmd, bind_groups, BATCH_MAX_BIND_GROUPS);
            for (uint32_t j = 0; j < bg_count; j++) {
                void* bg = bind_groups[j];
                if (bg && bg != current_bind_groups[j]) {
                    pfn_wgpuComputePassEncoderSetBindGroup(pass, j, bg, 0, NULL);
                    current_bind_groups[j] = bg;
                }
            }
            pfn_wgpuComputePassEncoderDispatchWorkgroups(pass,
                get_command_u32(env, cmd, "x", 3), get_command_u32(env, cmd, "y", 4), get_command_u32(env, cmd, "z", 5));
        } else if (type == 1) {
            if (pass) {
                pfn_wgpuComputePassEncoderEnd(pass);
                pfn_wgpuComputePassEncoderRelease(pass);
                pass = NULL;
                current_pipeline = NULL;
                memset(current_bind_groups, 0, sizeof(current_bind_groups));
            }
            void* src = get_command_ptr(env, cmd, "s", 1);
            void* dst = get_command_ptr(env, cmd, "d", 3);
            pfn_wgpuCommandEncoderCopyBufferToBuffer(encoder, src,
                (uint64_t)get_command_i64(env, cmd, "so", 2), dst,
                (uint64_t)get_command_i64(env, cmd, "do", 4),
                (uint64_t)get_command_i64(env, cmd, "sz", 5));
        }
    }
    if (pass) {
        pfn_wgpuComputePassEncoderEnd(pass);
        pfn_wgpuComputePassEncoderRelease(pass);
    }
    WGPUCommandBuffer cmd_buf = pfn_wgpuCommandEncoderFinish(encoder, NULL);
    const uint64_t command_replay_ns = wants_submit_breakdown ? monotonic_now_ns() - command_replay_started_ns : 0;
    const uint64_t queue_submit_started_ns = wants_submit_breakdown ? monotonic_now_ns() : 0;
    pfn_wgpuQueueSubmit(queue, 1, &cmd_buf);
    const uint64_t queue_submit_ns = wants_submit_breakdown ? monotonic_now_ns() - queue_submit_started_ns : 0;
    uint64_t flush_ns = 0;
    uint64_t wait_completed_ns = 0;
    uint64_t deferred_copy_ns = 0;
    uint64_t deferred_resolve_ns = 0;
    if (flush_after_submit) {
        flush_ns = flush_queue_after_submit(queue, &wait_completed_ns, &deferred_copy_ns, &deferred_resolve_ns);
    }
    pfn_wgpuCommandBufferRelease(cmd_buf);
    pfn_wgpuCommandEncoderRelease(encoder);
    if (!wants_submit_breakdown) {
        return make_submit_completion_hint(env, flush_ns, wait_completed_ns, deferred_copy_ns, deferred_resolve_ns);
    }
    return make_submit_breakdown_full(env, command_replay_ns, queue_submit_ns, flush_ns, wait_completed_ns, deferred_copy_ns, deferred_resolve_ns, 0, 0, 0, 0, 0, 0);
}

/* submitComputeDispatchCopy(device, queue, pipeline, bindGroups, x, y, z,
 *                           src, srcOff, dst, dstOff, size) */
napi_value doe_queue_submit_compute_dispatch_copy(napi_env env, napi_callback_info info) {
    size_t argc = 12;
    napi_value args[12];
    napi_status status = napi_get_cb_info(env, info, &argc, args, NULL, NULL);
    if (status != napi_ok || argc != 12) NAPI_THROW(env, "submitComputeDispatchCopy requires 12 arguments");
    CHECK_LIB_LOADED(env);
    WGPUDevice device = unwrap_ptr(env, args[0]);
    WGPUQueue queue   = unwrap_ptr(env, args[1]);
    void* pipeline    = unwrap_ptr(env, args[2]);
    napi_value bgs    = args[3];
    uint32_t dx = 0, dy = 0, dz = 0;
    int64_t copy_src_off_i = 0, copy_dst_off_i = 0, copy_size_i = 0;
    napi_get_value_uint32(env, args[4], &dx);
    napi_get_value_uint32(env, args[5], &dy);
    napi_get_value_uint32(env, args[6], &dz);
    void* copy_src = unwrap_ptr(env, args[7]);
    napi_get_value_int64(env, args[8], &copy_src_off_i);
    void* copy_dst = unwrap_ptr(env, args[9]);
    napi_get_value_int64(env, args[10], &copy_dst_off_i);
    napi_get_value_int64(env, args[11], &copy_size_i);
    if (!device || !queue || !pipeline) NAPI_THROW(env, "submitComputeDispatchCopy requires device, queue, and pipeline");
    void* bg_ptrs[BATCH_MAX_BIND_GROUPS] = {NULL};
    uint32_t bg_count = read_bind_group_value(env, bgs, bg_ptrs, BATCH_MAX_BIND_GROUPS);
#if defined(__APPLE__)
    if (pfn_doeNativeComputeDispatchFlush) {
        pfn_doeNativeComputeDispatchFlush(queue, pipeline, (void**)bg_ptrs, bg_count, dx, dy, dz,
            copy_src, (uint64_t)copy_src_off_i, copy_dst, (uint64_t)copy_dst_off_i, (uint64_t)copy_size_i);
        return NULL;
    }
#endif
    WGPUCommandEncoder encoder = pfn_wgpuDeviceCreateCommandEncoder(device, NULL);
    if (!encoder) NAPI_THROW(env, "submitComputeDispatchCopy: createCommandEncoder failed");
    WGPUComputePassEncoder pass = pfn_wgpuCommandEncoderBeginComputePass(encoder, NULL);
    if (!pass) { pfn_wgpuCommandEncoderRelease(encoder); NAPI_THROW(env, "submitComputeDispatchCopy: beginComputePass failed"); }
    pfn_wgpuComputePassEncoderSetPipeline(pass, pipeline);
    for (uint32_t j = 0; j < bg_count; j++)
        if (bg_ptrs[j]) pfn_wgpuComputePassEncoderSetBindGroup(pass, j, bg_ptrs[j], 0, NULL);
    pfn_wgpuComputePassEncoderDispatchWorkgroups(pass, dx, dy, dz);
    pfn_wgpuComputePassEncoderEnd(pass);
    pfn_wgpuComputePassEncoderRelease(pass);
    pfn_wgpuCommandEncoderCopyBufferToBuffer(encoder,
        copy_src, (uint64_t)copy_src_off_i, copy_dst, (uint64_t)copy_dst_off_i, (uint64_t)copy_size_i);
    WGPUCommandBuffer cmd_buf = pfn_wgpuCommandEncoderFinish(encoder, NULL);
    if (!cmd_buf) { pfn_wgpuCommandEncoderRelease(encoder); NAPI_THROW(env, "submitComputeDispatchCopy: finish failed"); }
    pfn_wgpuQueueSubmit(queue, 1, &cmd_buf);
    pfn_wgpuCommandBufferRelease(cmd_buf);
    pfn_wgpuCommandEncoderRelease(encoder);
    return NULL;
}

/* flushAndMapSync(instance, queue, buffer, mode, offset, size) */
napi_value doe_compute_dispatch_flush_and_map_sync(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 6);
    CHECK_LIB_LOADED(env);
    WGPUInstance inst = unwrap_ptr(env, _args[0]);
    WGPUQueue queue   = unwrap_ptr(env, _args[1]);
    WGPUBuffer buf    = unwrap_ptr(env, _args[2]);
    uint32_t mode; napi_get_value_uint32(env, _args[3], &mode);
    int64_t offset_i, size_i;
    napi_get_value_int64(env, _args[4], &offset_i);
    napi_get_value_int64(env, _args[5], &size_i);
    if (!queue || !buf) NAPI_THROW(env, "flushAndMapSync requires queue and buffer");
    if (pfn_doeNativeQueueFlush) pfn_doeNativeQueueFlush(queue);
    BufferMapResult result = {0};
    WGPUBufferMapCallbackInfo cb_info = {
        .nextInChain = NULL, .mode = WGPU_CALLBACK_MODE_ALLOW_PROCESS_EVENTS,
        .callback = buffer_map_callback, .userdata1 = &result, .userdata2 = NULL,
    };
    if (pfn_doeNativeBufferMapAsync) {
        WGPUFuture future = pfn_doeNativeBufferMapAsync(buf, (uint64_t)mode, (size_t)offset_i, (size_t)size_i, cb_info);
        if (future.id == 0 || !result.done) NAPI_THROW(env, "flushAndMapSync: doeNativeBufferMapAsync unavailable");
        if (result.status != WGPU_MAP_ASYNC_STATUS_SUCCESS)
            return throw_status_error(env, "DOE_BUFFER_MAP_ERROR", "flushAndMapSync: doeNativeBufferMapAsync failed", result.status, result.message);
    } else if (pfn_wgpuBufferMapAsync2) {
        WGPUFuture future = pfn_wgpuBufferMapAsync2(buf, (uint64_t)mode, (size_t)offset_i, (size_t)size_i, cb_info);
        if (future.id == 0) NAPI_THROW(env, "flushAndMapSync: bufferMapAsync future unavailable");
        if (!process_events_until(inst, &result.done, current_timeout_ns()))
            return throw_status_error(env, "DOE_BUFFER_MAP_TIMEOUT", "flushAndMapSync: bufferMapAsync timed out", result.status, result.message);
        if (result.status != WGPU_MAP_ASYNC_STATUS_SUCCESS)
            return throw_status_error(env, "DOE_BUFFER_MAP_ERROR", "flushAndMapSync: bufferMapAsync failed", result.status, result.message);
    } else {
        NAPI_THROW(env, "flushAndMapSync: bufferMapAsync unavailable");
    }
    napi_value ok; napi_get_boolean(env, true, &ok);
    return ok;
}

napi_value doe_queue_release(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    void* p = unwrap_ptr(env, _args[0]);
    if (p) pfn_wgpuQueueRelease(p);
    return NULL;
}

/* queueWriteTexture(queueNative, textureNative, dataBuffer, dataOffset,
 *                  bytesPerRow, rowsPerImage, mipLevel,
 *                  originX, originY, originZ, width, height, depthOrArrayLayers) */
napi_value doe_queue_write_texture(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 13);
    CHECK_LIB_LOADED(env);
    void* queue   = unwrap_ptr(env, _args[0]);
    void* texture = unwrap_ptr(env, _args[1]);
    if (!queue || !texture) NAPI_THROW(env, "queueWriteTexture: invalid queue or texture");
    void* data = NULL; size_t data_len = 0;
    bool is_typedarray = false;
    napi_is_typedarray(env, _args[2], &is_typedarray);
    if (is_typedarray) {
        napi_typedarray_type ta_type; size_t ta_length; napi_value ab; size_t byte_offset;
        napi_get_typedarray_info(env, _args[2], &ta_type, &ta_length, &data, &ab, &byte_offset);
        size_t elem_size = 1;
        switch (ta_type) {
            case napi_int16_array: case napi_uint16_array: elem_size = 2; break;
            case napi_int32_array: case napi_uint32_array: case napi_float32_array: elem_size = 4; break;
            case napi_float64_array: case napi_bigint64_array: case napi_biguint64_array: elem_size = 8; break;
            default: elem_size = 1; break;
        }
        data_len = ta_length * elem_size;
    } else {
        bool is_ab = false; napi_is_arraybuffer(env, _args[2], &is_ab);
        if (is_ab) napi_get_arraybuffer_info(env, _args[2], &data, &data_len);
        else NAPI_THROW(env, "queueWriteTexture: data must be TypedArray or ArrayBuffer");
    }
    uint32_t data_offset = 0; napi_get_value_uint32(env, _args[3], &data_offset);
    uint32_t bytes_per_row = 0; napi_get_value_uint32(env, _args[4], &bytes_per_row);
    uint32_t rows_per_image = 0; napi_get_value_uint32(env, _args[5], &rows_per_image);
    uint32_t mip_level = 0; napi_get_value_uint32(env, _args[6], &mip_level);
    uint32_t origin_x = 0; napi_get_value_uint32(env, _args[7], &origin_x);
    uint32_t origin_y = 0; napi_get_value_uint32(env, _args[8], &origin_y);
    uint32_t origin_z = 0; napi_get_value_uint32(env, _args[9], &origin_z);
    uint32_t width = 1; napi_get_value_uint32(env, _args[10], &width);
    uint32_t height = 1; napi_get_value_uint32(env, _args[11], &height);
    uint32_t depth_or_layers = 1; napi_get_value_uint32(env, _args[12], &depth_or_layers);
    if (data_offset > 0 && data_offset < (uint32_t)data_len) {
        data = ((uint8_t*)data) + data_offset;
        data_len -= data_offset;
    }
    if (pfn_doeNativeQueueWriteTexture) {
        pfn_doeNativeQueueWriteTexture(queue, texture, data, data_len,
            bytes_per_row, rows_per_image,
            origin_x, origin_y, origin_z, mip_level, 0,
            width, height, depth_or_layers);
    }
    napi_value undefined_value;
    napi_get_undefined(env, &undefined_value);
    return undefined_value;
}

/* queueOnSubmittedWorkDone — immediate async no-op for synchronous Doe runtime. */
napi_value doe_queue_on_submitted_work_done(napi_env env, napi_callback_info info) {
    (void)info;
    return native_direct_resolved_promise(env, NULL);
}
