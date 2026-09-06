#include "doe_napi_internal.h"

#define NATIVE_DIRECT_QUEUE_WRITE_BATCH_STACK_MAX 64u

/* Helper: extract a uint32 from a named property of a JS object.
 * Returns 0 if the property is absent or not a number. */
static uint32_t get_u32_prop(napi_env env, napi_value obj, const char* key) {
    napi_value val;
    napi_get_named_property(env, obj, key, &val);
    uint32_t out = 0;
    napi_get_value_uint32(env, val, &out);
    return out;
}

/* Helper: extract a GPUOrigin3D {x,y,z} from a JS object into three uint32 output args. */
static void get_origin_3d(napi_env env, napi_value obj, uint32_t* x, uint32_t* y, uint32_t* z) {
    *x = get_u32_prop(env, obj, "x");
    *y = get_u32_prop(env, obj, "y");
    *z = get_u32_prop(env, obj, "z");
}

/* Helper: extract a GPUExtent3D {width,height,depthOrArrayLayers} from a JS object. */
static void get_extent_3d(napi_env env, napi_value obj, uint32_t* w, uint32_t* h, uint32_t* d) {
    *w = get_u32_prop(env, obj, "width");
    *h = get_u32_prop(env, obj, "height");
    *d = get_u32_prop(env, obj, "depthOrArrayLayers");
    if (*d == 0) *d = 1; /* default per WebGPU spec */
}

static bool native_direct_is_buffer_data(napi_env env, napi_value value) {
    bool is_typedarray = false;
    napi_is_typedarray(env, value, &is_typedarray);
    if (is_typedarray) return true;
    bool is_arraybuffer = false;
    napi_is_arraybuffer(env, value, &is_arraybuffer);
    if (is_arraybuffer) return true;
    bool is_buffer = false;
    napi_is_buffer(env, value, &is_buffer);
    return is_buffer;
}

static void native_direct_queue_write_buffer_raw(
    WGPUQueue queue,
    WGPUBuffer buffer,
    uint64_t offset,
    const void* data,
    size_t byte_length
) {
    if (pfn_doeNativeQueueWriteBuffer) {
        pfn_doeNativeQueueWriteBuffer(queue, buffer, offset, data, byte_length);
    } else {
        pfn_wgpuQueueWriteBuffer(queue, buffer, offset, data, byte_length);
    }
}

static WGPUBuffer native_direct_read_buffer_handle(napi_env env, napi_value value) {
    NativeDirectBufferCache* buffer_cache = native_direct_get_buffer_cache(env, value);
    return buffer_cache ? buffer_cache->buffer : native_direct_unwrap_external_prop(env, value, DOE_DIRECT_NATIVE);
}

napi_value native_direct_queue_write_buffer(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value argv[5];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    if (argc < 3) NAPI_THROW(env, "queue.writeBuffer requires buffer, offset, and data");
    NativeDirectQueueCache* queue_cache = native_direct_get_queue_cache(env, this_arg);
    NativeDirectBufferCache* buffer_cache = native_direct_get_buffer_cache(env, argv[0]);
    WGPUQueue queue = queue_cache ? queue_cache->queue : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
    WGPUBuffer buffer = buffer_cache ? buffer_cache->buffer : native_direct_unwrap_external_prop(env, argv[0], DOE_DIRECT_NATIVE);
    if (!queue || !buffer) NAPI_THROW(env, "queue.writeBuffer requires queue and buffer");
    int64_t offset = 0;
    napi_get_value_int64(env, argv[1], &offset);

    void* data = NULL;
    size_t byte_length = 0;
    bool is_typedarray = false;
    napi_is_typedarray(env, argv[2], &is_typedarray);
    if (is_typedarray) {
        napi_typedarray_type ta_type;
        size_t ta_length;
        napi_value ab;
        size_t byte_offset;
        napi_get_typedarray_info(env, argv[2], &ta_type, &ta_length, &data, &ab, &byte_offset);
        size_t elem_size = 1;
        switch (ta_type) {
            case napi_int16_array: case napi_uint16_array: elem_size = 2; break;
            case napi_int32_array: case napi_uint32_array: case napi_float32_array: elem_size = 4; break;
            case napi_float64_array: case napi_bigint64_array: case napi_biguint64_array: elem_size = 8; break;
            default: elem_size = 1; break;
        }
        byte_length = ta_length * elem_size;
    } else {
        bool is_ab = false;
        napi_is_arraybuffer(env, argv[2], &is_ab);
        if (is_ab) {
            napi_get_arraybuffer_info(env, argv[2], &data, &byte_length);
        } else {
            bool is_buffer = false;
            napi_is_buffer(env, argv[2], &is_buffer);
            if (is_buffer) {
                napi_get_buffer_info(env, argv[2], &data, &byte_length);
            } else {
                NAPI_THROW(env, "queue.writeBuffer data must be TypedArray, ArrayBuffer, or Buffer");
            }
        }
    }

    if (argc >= 4 && argv[3]) {
        uint32_t data_offset = 0;
        napi_get_value_uint32(env, argv[3], &data_offset);
        data = ((uint8_t*)data) + data_offset;
        byte_length = byte_length > data_offset ? byte_length - data_offset : 0;
    }
    if (argc >= 5 && argv[4]) {
        uint32_t size = 0;
        napi_get_value_uint32(env, argv[4], &size);
        if (size < byte_length) byte_length = size;
    }

    native_direct_queue_write_buffer_raw(queue, buffer, (uint64_t)offset, data, byte_length);
    napi_value undefined_value;
    napi_get_undefined(env, &undefined_value);
    return undefined_value;
}

napi_value native_direct_queue_write_buffer_batch(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value argv[4];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    if (argc < 1) NAPI_THROW(env, "queue.writeBufferBatch requires entries");
    NativeDirectQueueCache* queue_cache = native_direct_get_queue_cache(env, this_arg);
    WGPUQueue queue = queue_cache ? queue_cache->queue : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
    if (!queue) NAPI_THROW(env, "queue.writeBufferBatch requires queue");

    bool is_array = false;
    napi_is_array(env, argv[0], &is_array);
    if (!is_array) NAPI_THROW(env, "queue.writeBufferBatch buffers or entries must be an array");
    uint32_t entry_count = 0;
    napi_get_array_length(env, argv[0], &entry_count);

    if (argc >= 4) {
        void* offset_bytes = NULL;
        size_t offset_byte_length = 0;
        void* size_bytes = NULL;
        size_t size_byte_length = 0;
        void* data_bytes = NULL;
        size_t data_byte_length = 0;
        extract_buffer_data(env, argv[1], &offset_bytes, &offset_byte_length);
        extract_buffer_data(env, argv[2], &size_bytes, &size_byte_length);
        extract_buffer_data(env, argv[3], &data_bytes, &data_byte_length);
        if (!offset_bytes || offset_byte_length < ((size_t)entry_count * sizeof(uint64_t))) {
            NAPI_THROW(env, "queue.writeBufferBatch compact offsets must be a BigUint64Array");
        }
        if (!size_bytes || size_byte_length < ((size_t)entry_count * sizeof(uint32_t))) {
            NAPI_THROW(env, "queue.writeBufferBatch compact sizes must be a Uint32Array");
        }
        if (!data_bytes && data_byte_length > 0) {
            NAPI_THROW(env, "queue.writeBufferBatch compact data must be buffer-backed");
        }
        if (entry_count > NATIVE_DIRECT_QUEUE_WRITE_BATCH_STACK_MAX) {
            NAPI_THROW(env, "queue.writeBufferBatch compact entry count exceeds stack batch limit");
        }
        WGPUBuffer batch_buffers[NATIVE_DIRECT_QUEUE_WRITE_BATCH_STACK_MAX];
        uint64_t batch_offsets[NATIVE_DIRECT_QUEUE_WRITE_BATCH_STACK_MAX];
        uint32_t batch_sizes[NATIVE_DIRECT_QUEUE_WRITE_BATCH_STACK_MAX];
        const bool use_native_batch = pfn_doeNativeQueueWriteBufferBatch != NULL;
        const uint8_t empty_batch_data = 0;
        const uint8_t* batch_data = data_bytes ? (const uint8_t*)data_bytes : &empty_batch_data;
        size_t data_offset = 0;
        for (uint32_t i = 0; i < entry_count; i++) {
            napi_value buffer_value;
            napi_get_element(env, argv[0], i, &buffer_value);
            WGPUBuffer buffer = native_direct_read_buffer_handle(env, buffer_value);
            if (!buffer) NAPI_THROW(env, "queue.writeBufferBatch compact entry requires buffer");

            uint64_t offset = 0;
            uint32_t byte_length = 0;
            memcpy(&offset, ((uint8_t*)offset_bytes) + ((size_t)i * sizeof(uint64_t)), sizeof(uint64_t));
            memcpy(&byte_length, ((uint8_t*)size_bytes) + ((size_t)i * sizeof(uint32_t)), sizeof(uint32_t));
            if (data_offset + (size_t)byte_length > data_byte_length) {
                NAPI_THROW(env, "queue.writeBufferBatch compact data is shorter than declared sizes");
            }
            batch_buffers[i] = buffer;
            batch_offsets[i] = offset;
            batch_sizes[i] = byte_length;
            if (!use_native_batch) {
                native_direct_queue_write_buffer_raw(
                    queue,
                    buffer,
                    offset,
                    batch_data + data_offset,
                    (size_t)byte_length
                );
            }
            data_offset += (size_t)byte_length;
        }
        if (use_native_batch) {
            pfn_doeNativeQueueWriteBufferBatch(
                queue,
                (size_t)entry_count,
                batch_buffers,
                batch_offsets,
                batch_sizes,
                batch_data
            );
        }

        napi_value undefined_value;
        napi_get_undefined(env, &undefined_value);
        return undefined_value;
    }

    for (uint32_t i = 0; i < entry_count; i++) {
        napi_value entry;
        napi_get_element(env, argv[0], i, &entry);
        napi_valuetype entry_type;
        napi_typeof(env, entry, &entry_type);
        if (entry_type != napi_object) {
            NAPI_THROW(env, "queue.writeBufferBatch entries must be objects");
        }

        napi_value buffer_value = get_prop(env, entry, "buffer");
        WGPUBuffer buffer = native_direct_read_buffer_handle(env, buffer_value);
        if (!buffer) NAPI_THROW(env, "queue.writeBufferBatch entry requires buffer");

        int64_t offset = get_int64_prop(env, entry, "offset");
        if (offset < 0) NAPI_THROW(env, "queue.writeBufferBatch entry offset must be non-negative");

        napi_value data_value = get_prop(env, entry, "data");
        if (!native_direct_is_buffer_data(env, data_value)) {
            NAPI_THROW(env, "queue.writeBufferBatch entry data must be TypedArray, ArrayBuffer, or Buffer");
        }
        void* data = NULL;
        size_t byte_length = 0;
        extract_buffer_data(env, data_value, &data, &byte_length);
        native_direct_queue_write_buffer_raw(queue, buffer, (uint64_t)offset, data, byte_length);
    }

    napi_value undefined_value;
    napi_get_undefined(env, &undefined_value);
    return undefined_value;
}

/* GPUQueue.writeTexture(destination, data, dataLayout, size)
 * argv[0]: {texture, mipLevel, origin: {x,y,z}, aspect?}
 * argv[1]: ArrayBuffer | TypedArray — pixel data
 * argv[2]: {offset?, bytesPerRow, rowsPerImage?}
 * argv[3]: {width, height, depthOrArrayLayers} */
napi_value native_direct_queue_write_texture(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value argv[4];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    if (argc < 4) NAPI_THROW(env, "writeTexture requires destination, data, dataLayout, and size");
    NativeDirectQueueCache* queue_cache = native_direct_get_queue_cache(env, this_arg);
    void* queue = queue_cache ? queue_cache->queue : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
    if (!queue) NAPI_THROW(env, "writeTexture: invalid queue");
    napi_value tex_obj = get_prop(env, argv[0], "texture");
    void* texture = native_direct_unwrap_external_prop(env, tex_obj, DOE_DIRECT_NATIVE);
    if (!texture) NAPI_THROW(env, "writeTexture: invalid destination texture");
    uint32_t dst_mip = get_u32_prop(env, argv[0], "mipLevel");
    uint32_t dst_x = 0, dst_y = 0, dst_z = 0;
    napi_value dst_origin = get_prop(env, argv[0], "origin");
    napi_valuetype dst_origin_type;
    napi_typeof(env, dst_origin, &dst_origin_type);
    if (dst_origin_type == napi_object) get_origin_3d(env, dst_origin, &dst_x, &dst_y, &dst_z);
    /* Extract pixel data pointer and byte length */
    void* data = NULL;
    size_t data_len = 0;
    bool is_typedarray = false;
    napi_is_typedarray(env, argv[1], &is_typedarray);
    if (is_typedarray) {
        napi_typedarray_type ta_type;
        size_t ta_length;
        napi_value ab;
        size_t byte_offset;
        napi_get_typedarray_info(env, argv[1], &ta_type, &ta_length, &data, &ab, &byte_offset);
        size_t elem_size = 1;
        switch (ta_type) {
            case napi_int16_array: case napi_uint16_array: elem_size = 2; break;
            case napi_int32_array: case napi_uint32_array: case napi_float32_array: elem_size = 4; break;
            case napi_float64_array: case napi_bigint64_array: case napi_biguint64_array: elem_size = 8; break;
            default: elem_size = 1; break;
        }
        data_len = ta_length * elem_size;
    } else {
        bool is_ab = false;
        napi_is_arraybuffer(env, argv[1], &is_ab);
        if (is_ab) {
            napi_get_arraybuffer_info(env, argv[1], &data, &data_len);
        } else {
            NAPI_THROW(env, "writeTexture: data must be TypedArray or ArrayBuffer");
        }
    }
    /* dataLayout: {offset?, bytesPerRow, rowsPerImage?} */
    uint32_t layout_offset = get_u32_prop(env, argv[2], "offset");
    uint32_t bytes_per_row = get_u32_prop(env, argv[2], "bytesPerRow");
    uint32_t rows_per_image = get_u32_prop(env, argv[2], "rowsPerImage");
    if (layout_offset > 0 && layout_offset < data_len) {
        data = ((uint8_t*)data) + layout_offset;
        data_len -= layout_offset;
    }
    /* copySize */
    uint32_t width = 1, height = 1, depth_or_layers = 1;
    napi_valuetype size_type;
    napi_typeof(env, argv[3], &size_type);
    if (size_type == napi_object) get_extent_3d(env, argv[3], &width, &height, &depth_or_layers);
    if (pfn_doeNativeQueueWriteTexture) {
        pfn_doeNativeQueueWriteTexture(
            queue, texture,
            data, data_len,
            bytes_per_row, rows_per_image,
            dst_x, dst_y, dst_z, dst_mip, 0,
            width, height, depth_or_layers);
    }
    napi_value undefined_value;
    napi_get_undefined(env, &undefined_value);
    return undefined_value;
}

static WGPUCommandBuffer native_direct_command_buffer(napi_env env, napi_value object) {
    NativeDirectHandleCache* cache = native_direct_get_handle_cache(env, object);
    return cache ? (WGPUCommandBuffer)cache->native
        : native_direct_unwrap_external_prop(env, object, DOE_DIRECT_NATIVE);
}

static void native_direct_consume_command_buffer(napi_env env, napi_value object) {
    WGPUCommandBuffer command = native_direct_command_buffer(env, object);
    NativeDirectHandleCache* cache = native_direct_get_handle_cache(env, object);
    native_direct_set_external_prop(env, object, DOE_DIRECT_NATIVE, NULL);
    if (cache) cache->native = NULL;
    pfn_wgpuCommandBufferRelease(command);
}

napi_value native_direct_queue_submit(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    if (argc < 1) NAPI_THROW(env, "queue.submit requires command buffers");
    NativeDirectQueueCache* queue_cache = native_direct_get_queue_cache(env, this_arg);
    WGPUQueue queue = queue_cache ? queue_cache->queue : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
    if (!queue) NAPI_THROW(env, "Invalid queue");
    uint32_t cmd_count = 0;
    napi_get_array_length(env, argv[0], &cmd_count);
    if (cmd_count == 1) {
        napi_value elem;
        napi_get_element(env, argv[0], 0, &elem);
        WGPUCommandBuffer cmd = native_direct_command_buffer(env, elem);
        if (!cmd) NAPI_THROW(env, "queue.submit requires an unsubmitted command buffer");
        pfn_wgpuQueueSubmit(queue, 1, &cmd);
        native_direct_consume_command_buffer(env, elem);
    } else {
        WGPUCommandBuffer* cmds = (WGPUCommandBuffer*)calloc(cmd_count, sizeof(WGPUCommandBuffer));
        if (!cmds && cmd_count > 0) NAPI_THROW(env, "queue.submit: out of memory");
        for (uint32_t i = 0; i < cmd_count; i++) {
            napi_value elem;
            napi_get_element(env, argv[0], i, &elem);
            cmds[i] = native_direct_command_buffer(env, elem);
            if (!cmds[i]) {
                free(cmds);
                NAPI_THROW(env, "queue.submit requires unsubmitted command buffers");
            }
            for (uint32_t prior = 0; prior < i; prior++) {
                if (cmds[prior] == cmds[i]) {
                    free(cmds);
                    NAPI_THROW(env, "queue.submit cannot submit the same command buffer twice");
                }
            }
        }
        pfn_wgpuQueueSubmit(queue, cmd_count, cmds);
        for (uint32_t i = 0; i < cmd_count; i++) {
            napi_value elem;
            napi_get_element(env, argv[0], i, &elem);
            native_direct_consume_command_buffer(env, elem);
        }
        free(cmds);
    }
    native_direct_queue_mark_submitted(env, this_arg);
    napi_value undefined_value;
    napi_get_undefined(env, &undefined_value);
    return undefined_value;
}

napi_value native_direct_queue_on_submitted_work_done(napi_env env, napi_callback_info info) {
    size_t argc = 0;
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, NULL, &this_arg, NULL);
    NativeDirectQueueCache* queue_cache = native_direct_get_queue_cache(env, this_arg);
    WGPUInstance inst = queue_cache ? queue_cache->instance : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_INSTANCE);
    WGPUQueue queue = queue_cache ? queue_cache->queue : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
    if (!queue) NAPI_THROW(env, "Invalid queue");
    double queue_flush_ms = 0.0;
    const uint64_t submit_wait_started_ns = monotonic_now_ns();
    if (native_direct_queue_has_pending(env, this_arg)) {
        if (pfn_doeNativeQueueFlush) {
            const uint64_t flush_started_ns = monotonic_now_ns();
            pfn_doeNativeQueueFlush(queue);
            queue_flush_ms = native_direct_elapsed_ms(flush_started_ns);
        } else {
            QueueWorkDoneResult result = {0};
            WGPUQueueWorkDoneCallbackInfo cb_info = {
                .nextInChain = NULL,
                .mode = WGPU_CALLBACK_MODE_WAIT_ANY_ONLY,
                .callback = queue_work_done_callback,
                .userdata1 = &result,
                .userdata2 = NULL,
            };
            WGPUFuture future = pfn_wgpuQueueOnSubmittedWorkDone(queue, cb_info);
            if (future.id == 0) NAPI_THROW(env, "queue work-done future unavailable");
            const uint64_t flush_started_ns = monotonic_now_ns();
            uint64_t start_ns = monotonic_now_ns();
            while (!result.done) {
                WGPUFutureWaitInfo wait_info = {
                    .future = future,
                    .completed = 0,
                };
                uint32_t wait_status = pfn_wgpuInstanceWaitAny(inst, 1, &wait_info, 0);
                if (wait_status == WGPU_WAIT_STATUS_SUCCESS) {
                    if (!result.done) pfn_wgpuInstanceProcessEvents(inst);
                } else if (wait_status == WGPU_WAIT_STATUS_TIMED_OUT) {
                    pfn_wgpuInstanceProcessEvents(inst);
                    if (monotonic_now_ns() - start_ns >= current_timeout_ns()) {
                        napi_throw_error(env, "DOE_QUEUE_TIMEOUT", "queue wait timed out");
                        return NULL;
                    }
                    wait_slice();
                } else if (wait_status == WGPU_WAIT_STATUS_ERROR) {
                    napi_throw_error(env, "DOE_QUEUE_UNAVAILABLE", "queue wait failed");
                    return NULL;
                } else {
                    NAPI_THROW(env, "queue wait returned unsupported status");
                }
            }
            if (result.status != WGPU_QUEUE_WORK_DONE_STATUS_SUCCESS) {
                return throw_status_error(env, "DOE_QUEUE_FLUSH_ERROR", "queue work did not complete", result.status, result.message);
            }
            queue_flush_ms = native_direct_elapsed_ms(flush_started_ns);
        }
        native_direct_queue_mark_done(env, this_arg);
    }
    native_direct_set_double_prop(env, this_arg, DOE_DIRECT_DIAG_QUEUE_FLUSH_MS, queue_flush_ms);
    native_direct_set_double_prop(env, this_arg, DOE_DIRECT_DIAG_SUBMIT_WAIT_MS, native_direct_elapsed_ms(submit_wait_started_ns));
    return native_direct_resolved_undefined_promise(env);
}

napi_value native_direct_buffer_map_async(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    if (argc < 1) NAPI_THROW(env, "buffer.mapAsync requires a mode");
    NativeDirectBufferCache* buffer_cache = native_direct_get_buffer_cache(env, this_arg);
    WGPUInstance inst = buffer_cache ? buffer_cache->instance : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_INSTANCE);
    WGPUBuffer buffer = buffer_cache ? buffer_cache->buffer : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
    napi_value queue_obj = NULL;
    if (buffer_cache && buffer_cache->queue_ref) {
        napi_get_reference_value(env, buffer_cache->queue_ref, &queue_obj);
    } else {
        queue_obj = get_prop(env, this_arg, DOE_DIRECT_QUEUE);
    }
    if (!buffer) NAPI_THROW(env, "Invalid buffer");
    uint32_t mode = 0;
    int64_t offset = 0;
    int64_t size = buffer_cache ? (int64_t)buffer_cache->size : (int64_t)get_double_prop(env, this_arg, "size");
    napi_get_value_uint32(env, argv[0], &mode);
    if (argc >= 2 && argv[1]) napi_get_value_int64(env, argv[1], &offset);
    if (argc >= 3 && argv[2]) napi_get_value_int64(env, argv[2], &size);
    double map_queue_flush_ms = 0.0;
    if (native_direct_queue_has_pending(env, queue_obj)) {
        NativeDirectQueueCache* queue_cache = native_direct_get_queue_cache(env, queue_obj);
        WGPUQueue queue = queue_cache ? queue_cache->queue : native_direct_unwrap_external_prop(env, queue_obj, DOE_DIRECT_NATIVE);
        if (pfn_doeNativeQueueFlush) {
            const uint64_t flush_started_ns = monotonic_now_ns();
            pfn_doeNativeQueueFlush(queue);
            map_queue_flush_ms = native_direct_elapsed_ms(flush_started_ns);
        } else {
            QueueWorkDoneResult result = {0};
            WGPUQueueWorkDoneCallbackInfo cb_info = {
                .nextInChain = NULL,
                .mode = WGPU_CALLBACK_MODE_WAIT_ANY_ONLY,
                .callback = queue_work_done_callback,
                .userdata1 = &result,
                .userdata2 = NULL,
            };
            WGPUFuture future = pfn_wgpuQueueOnSubmittedWorkDone(queue, cb_info);
            if (future.id == 0) NAPI_THROW(env, "queue work-done future unavailable");
            const uint64_t flush_started_ns = monotonic_now_ns();
            if (!process_events_until(inst, &result.done, current_timeout_ns())) {
                return throw_status_error(env, "DOE_QUEUE_TIMEOUT", "queue wait timed out", result.status, result.message);
            }
            if (result.status != WGPU_QUEUE_WORK_DONE_STATUS_SUCCESS) {
                return throw_status_error(env, "DOE_QUEUE_FLUSH_ERROR", "queue work did not complete", result.status, result.message);
            }
            map_queue_flush_ms = native_direct_elapsed_ms(flush_started_ns);
        }
        native_direct_queue_mark_done(env, queue_obj);
    }

    BufferMapResult result = {0};
    WGPUBufferMapCallbackInfo cb_info = {
        .nextInChain = NULL,
        .mode = WGPU_CALLBACK_MODE_ALLOW_PROCESS_EVENTS,
        .callback = buffer_map_callback,
        .userdata1 = &result,
        .userdata2 = NULL,
    };
    const uint64_t map_started_ns = monotonic_now_ns();
    if (pfn_doeNativeBufferMapAsync) {
        WGPUFuture future = pfn_doeNativeBufferMapAsync(buffer, (uint64_t)mode, (size_t)offset, (size_t)size, cb_info);
        if (future.id == 0 || !result.done) NAPI_THROW(env, "doeNativeBufferMapAsync unavailable");
        if (result.status != WGPU_MAP_ASYNC_STATUS_SUCCESS) {
            return throw_status_error(env, "DOE_BUFFER_MAP_ERROR", "doeNativeBufferMapAsync failed", result.status, result.message);
        }
    } else if (pfn_wgpuBufferMapAsync2) {
        WGPUFuture future = pfn_wgpuBufferMapAsync2(buffer, (uint64_t)mode, (size_t)offset, (size_t)size, cb_info);
        if (future.id == 0) NAPI_THROW(env, "bufferMapAsync future unavailable");
        if (!process_events_until(inst, &result.done, current_timeout_ns())) {
            return throw_status_error(env, "DOE_BUFFER_MAP_TIMEOUT", "bufferMapAsync timed out", result.status, result.message);
        }
        if (result.status != WGPU_MAP_ASYNC_STATUS_SUCCESS) {
            return throw_status_error(env, "DOE_BUFFER_MAP_ERROR", "bufferMapAsync failed", result.status, result.message);
        }
    } else {
        NAPI_THROW(env, "bufferMapAsync unavailable");
    }
    native_direct_set_double_prop(env, this_arg, DOE_DIRECT_DIAG_MAP_QUEUE_FLUSH_MS, map_queue_flush_ms);
    native_direct_set_double_prop(env, this_arg, DOE_DIRECT_DIAG_MAP_ASYNC_MS, native_direct_elapsed_ms(map_started_ns));
    if (buffer_cache) buffer_cache->map_mode = mode;
    return native_direct_resolved_undefined_promise(env);
}

static bool native_direct_flush_mapped_range(napi_env env, NativeDirectBufferCache* cache) {
    if (!cache || !cache->mapped_range_ref || cache->map_mode != DOE_GPU_MAP_WRITE) return true;
    napi_value range;
    void* bytes = NULL;
    size_t size = 0;
    if (napi_get_reference_value(env, cache->mapped_range_ref, &range) != napi_ok ||
        napi_get_arraybuffer_info(env, range, &bytes, &size) != napi_ok ||
        size != cache->mapped_size || (size && !bytes)) return false;
    if (size) memcpy(cache->mapped_ptr, bytes, size);
    return true;
}

napi_value native_direct_buffer_get_mapped_range(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    NativeDirectBufferCache* buffer_cache = native_direct_get_buffer_cache(env, this_arg);
    WGPUBuffer buffer = buffer_cache ? buffer_cache->buffer : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
    if (!buffer) NAPI_THROW(env, "Invalid buffer");
    int64_t offset = 0;
    int64_t size = buffer_cache ? (int64_t)buffer_cache->size : (int64_t)get_double_prop(env, this_arg, "size");
    if (argc >= 1 && argv[0]) napi_get_value_int64(env, argv[0], &offset);
    if (argc >= 2 && argv[1]) napi_get_value_int64(env, argv[1], &size);
    const uint64_t get_mapped_range_started_ns = monotonic_now_ns();
    void* data = pfn_wgpuBufferGetMappedRange(buffer, (size_t)offset, (size_t)size);
    if (!data) data = (void*)pfn_wgpuBufferGetConstMappedRange(buffer, (size_t)offset, (size_t)size);
    if (!data) NAPI_THROW(env, "getMappedRange returned NULL");
    if (buffer_cache &&
        buffer_cache->mapped_range_ref &&
        buffer_cache->mapped_ptr == data &&
        buffer_cache->mapped_offset == (size_t)offset &&
        buffer_cache->mapped_size == (size_t)size) {
        napi_value cached;
        native_direct_set_double_prop(env, this_arg, DOE_DIRECT_DIAG_GET_MAPPED_RANGE_MS, native_direct_elapsed_ms(get_mapped_range_started_ns));
        napi_get_reference_value(env, buffer_cache->mapped_range_ref, &cached);
        return cached;
    }
    if (!buffer_cache) NAPI_THROW(env, "getMappedRange requires buffer ownership metadata");
    if (!native_direct_flush_mapped_range(env, buffer_cache)) NAPI_THROW(env, "getMappedRange: invalid prior mapped range");
    native_direct_invalidate_buffer_mapped_range_cache(env, buffer_cache);
    napi_value array_buffer;
    void* copy = NULL;
    if (napi_create_arraybuffer(env, (size_t)size, &copy, &array_buffer) != napi_ok)
        NAPI_THROW(env, "getMappedRange: host allocation failed");
    if (size > 0) memcpy(copy, data, (size_t)size);
    if (napi_create_reference(env, array_buffer, 1, &buffer_cache->mapped_range_ref) != napi_ok)
        NAPI_THROW(env, "getMappedRange: retaining host allocation failed");
    buffer_cache->mapped_offset = (size_t)offset;
    buffer_cache->mapped_size = (size_t)size;
    buffer_cache->mapped_ptr = data;
    native_direct_set_double_prop(env, this_arg, DOE_DIRECT_DIAG_GET_MAPPED_RANGE_MS, native_direct_elapsed_ms(get_mapped_range_started_ns));
    return array_buffer;
}

napi_value native_direct_buffer_read_copy(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    NativeDirectBufferCache* buffer_cache = native_direct_get_buffer_cache(env, this_arg);
    WGPUBuffer buffer = buffer_cache ? buffer_cache->buffer : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
    if (!buffer) NAPI_THROW(env, "Invalid buffer");
    int64_t offset = 0;
    int64_t size = buffer_cache ? (int64_t)buffer_cache->size : (int64_t)get_double_prop(env, this_arg, "size");
    if (argc >= 1 && argv[0]) napi_get_value_int64(env, argv[0], &offset);
    if (argc >= 2 && argv[1]) napi_get_value_int64(env, argv[1], &size);
    void* data = pfn_wgpuBufferGetMappedRange(buffer, (size_t)offset, (size_t)size);
    if (!data) data = (void*)pfn_wgpuBufferGetConstMappedRange(buffer, (size_t)offset, (size_t)size);
    if (!data) NAPI_THROW(env, "bufferReadCopy getMappedRange returned NULL");
    void* copy = NULL;
    napi_value array_buffer;
    napi_create_arraybuffer(env, (size_t)size, &copy, &array_buffer);
    if (copy && size > 0) memcpy(copy, data, (size_t)size);
    return array_buffer;
}

/* Combined map+copy+unmap in a single N-API call.
   Eliminates: mapAsync promise overhead, external arraybuffer from getMappedRange,
   .slice() copy in JS, and separate unmap call. Returns a V8-owned ArrayBuffer. */
napi_value native_direct_buffer_map_read_copy_unmap(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    NativeDirectBufferCache* buffer_cache = native_direct_get_buffer_cache(env, this_arg);
    WGPUBuffer buffer = buffer_cache ? buffer_cache->buffer : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
    if (!buffer) NAPI_THROW(env, "Invalid buffer");
    uint32_t mode = DOE_GPU_MAP_READ;
    int64_t offset = 0;
    int64_t size = buffer_cache ? (int64_t)buffer_cache->size : (int64_t)get_double_prop(env, this_arg, "size");
    if (argc >= 1 && argv[0]) napi_get_value_uint32(env, argv[0], &mode);
    if (argc >= 2 && argv[1]) napi_get_value_int64(env, argv[1], &offset);
    if (argc >= 3 && argv[2]) napi_get_value_int64(env, argv[2], &size);
    if (mode != DOE_GPU_MAP_READ) NAPI_THROW(env, "mapReadCopyUnmap only supports MAP_READ");
    if (offset < 0 || size < 0) NAPI_THROW(env, "mapReadCopyUnmap requires non-negative offset and size");
    double queue_wait_completed_ms = 0.0;
    double queue_deferred_copy_ms = 0.0;
    double queue_deferred_resolve_ms = 0.0;
    double map_ms = 0.0;
    double copy_ms = 0.0;
    double unmap_ms = 0.0;

    /* flush queue if pending */
    napi_value queue_obj = NULL;
    if (buffer_cache && buffer_cache->queue_ref) {
        napi_get_reference_value(env, buffer_cache->queue_ref, &queue_obj);
    } else {
        queue_obj = get_prop(env, this_arg, DOE_DIRECT_QUEUE);
    }
    uint32_t should_flush = 0;
    WGPUQueue queue = NULL;
    if (queue_obj && native_direct_queue_has_pending(env, queue_obj)) {
        NativeDirectQueueCache* queue_cache = native_direct_get_queue_cache(env, queue_obj);
        queue = queue_cache ? queue_cache->queue : native_direct_unwrap_external_prop(env, queue_obj, DOE_DIRECT_NATIVE);
        if (!queue) NAPI_THROW(env, "mapReadCopyUnmap requires a valid queue when pending submissions exist");
        should_flush = 1u;
    }

    if (pfn_doeBufferMapReadCopyUnmapFlat) {
        void* copy = NULL;
        napi_value array_buffer;
        napi_create_arraybuffer(env, (size_t)size, &copy, &array_buffer);
        uint64_t breakdown[DOE_READBACK_BREAKDOWN_FIELD_COUNT] = {0};
        const uint32_t status = pfn_doeBufferMapReadCopyUnmapFlat(
            queue,
            buffer,
            (uint64_t)mode,
            (size_t)offset,
            (size_t)size,
            should_flush,
            copy,
            breakdown
        );
        if (status != WGPU_STATUS_SUCCESS) {
            NAPI_THROW(env, "mapReadCopyUnmapFlat failed");
        }
        if (should_flush) {
            native_direct_queue_mark_done(env, queue_obj);
        }
        native_direct_invalidate_buffer_mapped_range_cache(env, buffer_cache);
        native_direct_set_double_prop(env, this_arg, DOE_DIRECT_DIAG_MAP_READ_COPY_UNMAP_QUEUE_WAIT_COMPLETED_MS, (double)breakdown[DOE_READBACK_BREAKDOWN_WAIT_COMPLETED] / 1000000.0);
        native_direct_set_double_prop(env, this_arg, DOE_DIRECT_DIAG_MAP_READ_COPY_UNMAP_DEFERRED_COPY_MS, (double)breakdown[DOE_READBACK_BREAKDOWN_DEFERRED_COPY] / 1000000.0);
        native_direct_set_double_prop(env, this_arg, DOE_DIRECT_DIAG_MAP_READ_COPY_UNMAP_DEFERRED_RESOLVE_MS, (double)breakdown[DOE_READBACK_BREAKDOWN_DEFERRED_RESOLVE] / 1000000.0);
        native_direct_set_double_prop(env, this_arg, DOE_DIRECT_DIAG_MAP_READ_COPY_UNMAP_MAP_MS, (double)breakdown[DOE_READBACK_BREAKDOWN_MAP] / 1000000.0);
        native_direct_set_double_prop(env, this_arg, DOE_DIRECT_DIAG_MAP_READ_COPY_UNMAP_COPY_MS, (double)breakdown[DOE_READBACK_BREAKDOWN_COPY] / 1000000.0);
        native_direct_set_double_prop(env, this_arg, DOE_DIRECT_DIAG_MAP_READ_COPY_UNMAP_UNMAP_MS, (double)breakdown[DOE_READBACK_BREAKDOWN_UNMAP] / 1000000.0);
        return array_buffer;
    }

    if (should_flush) {
        if (pfn_doeNativeQueueFlushBreakdown) {
            uint64_t wait_completed_ns = 0;
            uint64_t deferred_copy_ns = 0;
            uint64_t deferred_resolve_ns = 0;
            pfn_doeNativeQueueFlushBreakdown(queue, &wait_completed_ns, &deferred_copy_ns, &deferred_resolve_ns);
            queue_wait_completed_ms = (double)wait_completed_ns / 1000000.0;
            queue_deferred_copy_ms = (double)deferred_copy_ns / 1000000.0;
            queue_deferred_resolve_ms = (double)deferred_resolve_ns / 1000000.0;
        } else if (pfn_doeNativeQueueFlush) {
            const uint64_t flush_started_ns = monotonic_now_ns();
            pfn_doeNativeQueueFlush(queue);
            queue_wait_completed_ms = native_direct_elapsed_ms(flush_started_ns);
        } else {
            WGPUInstance inst = buffer_cache ? buffer_cache->instance : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_INSTANCE);
            QueueWorkDoneResult qresult = {0};
            WGPUQueueWorkDoneCallbackInfo cb_info = {
                .nextInChain = NULL,
                .mode = WGPU_CALLBACK_MODE_WAIT_ANY_ONLY,
                .callback = queue_work_done_callback,
                .userdata1 = &qresult,
                .userdata2 = NULL,
            };
            WGPUFuture future = pfn_wgpuQueueOnSubmittedWorkDone(queue, cb_info);
            if (future.id == 0) NAPI_THROW(env, "queue work-done future unavailable");
            const uint64_t wait_started_ns = monotonic_now_ns();
            if (!process_events_until(inst, &qresult.done, current_timeout_ns())) {
                NAPI_THROW(env, "queue wait timed out in mapReadCopyUnmap");
            }
            queue_wait_completed_ms = native_direct_elapsed_ms(wait_started_ns);
        }
        native_direct_queue_mark_done(env, queue_obj);
    }

    /* map */
    WGPUInstance inst = buffer_cache ? buffer_cache->instance : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_INSTANCE);
    BufferMapResult result = {0};
    WGPUBufferMapCallbackInfo cb_info = {
        .nextInChain = NULL,
        .mode = WGPU_CALLBACK_MODE_ALLOW_PROCESS_EVENTS,
        .callback = buffer_map_callback,
        .userdata1 = &result,
        .userdata2 = NULL,
    };
    const uint64_t map_started_ns = monotonic_now_ns();
    if (pfn_doeNativeBufferMapAsync) {
        WGPUFuture future = pfn_doeNativeBufferMapAsync(buffer, (uint64_t)mode, (size_t)offset, (size_t)size, cb_info);
        if (future.id == 0 || !result.done) NAPI_THROW(env, "mapReadCopyUnmap: map failed");
    } else if (pfn_wgpuBufferMapAsync2) {
        WGPUFuture future = pfn_wgpuBufferMapAsync2(buffer, (uint64_t)mode, (size_t)offset, (size_t)size, cb_info);
        if (future.id == 0) NAPI_THROW(env, "mapReadCopyUnmap: map future unavailable");
        if (!process_events_until(inst, &result.done, current_timeout_ns())) {
            NAPI_THROW(env, "mapReadCopyUnmap: map timed out");
        }
    } else {
        NAPI_THROW(env, "mapReadCopyUnmap: map unavailable");
    }
    if (result.status != WGPU_MAP_ASYNC_STATUS_SUCCESS) {
        NAPI_THROW(env, "mapReadCopyUnmap: map failed");
    }
    map_ms = native_direct_elapsed_ms(map_started_ns);

    /* copy mapped data into a V8-owned ArrayBuffer */
    const uint64_t copy_started_ns = monotonic_now_ns();
    void* data = pfn_wgpuBufferGetMappedRange(buffer, (size_t)offset, (size_t)size);
    if (!data) data = (void*)pfn_wgpuBufferGetConstMappedRange(buffer, (size_t)offset, (size_t)size);
    if (!data) {
        pfn_wgpuBufferUnmap(buffer);
        NAPI_THROW(env, "mapReadCopyUnmap: getMappedRange returned NULL");
    }
    void* copy = NULL;
    napi_value array_buffer;
    napi_create_arraybuffer(env, (size_t)size, &copy, &array_buffer);
    if (copy && size > 0) memcpy(copy, data, (size_t)size);
    copy_ms = native_direct_elapsed_ms(copy_started_ns);

    /* unmap and invalidate cache */
    const uint64_t unmap_started_ns = monotonic_now_ns();
    native_direct_invalidate_buffer_mapped_range_cache(env, buffer_cache);
    pfn_wgpuBufferUnmap(buffer);
    unmap_ms = native_direct_elapsed_ms(unmap_started_ns);

    native_direct_set_double_prop(env, this_arg, DOE_DIRECT_DIAG_MAP_READ_COPY_UNMAP_QUEUE_WAIT_COMPLETED_MS, queue_wait_completed_ms);
    native_direct_set_double_prop(env, this_arg, DOE_DIRECT_DIAG_MAP_READ_COPY_UNMAP_DEFERRED_COPY_MS, queue_deferred_copy_ms);
    native_direct_set_double_prop(env, this_arg, DOE_DIRECT_DIAG_MAP_READ_COPY_UNMAP_DEFERRED_RESOLVE_MS, queue_deferred_resolve_ms);
    native_direct_set_double_prop(env, this_arg, DOE_DIRECT_DIAG_MAP_READ_COPY_UNMAP_MAP_MS, map_ms);
    native_direct_set_double_prop(env, this_arg, DOE_DIRECT_DIAG_MAP_READ_COPY_UNMAP_COPY_MS, copy_ms);
    native_direct_set_double_prop(env, this_arg, DOE_DIRECT_DIAG_MAP_READ_COPY_UNMAP_UNMAP_MS, unmap_ms);

    return array_buffer;
}

napi_value native_direct_buffer_unmap(napi_env env, napi_callback_info info) {
    size_t argc = 0;
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, NULL, &this_arg, NULL);
    NativeDirectBufferCache* buffer_cache = native_direct_get_buffer_cache(env, this_arg);
    WGPUBuffer buffer = buffer_cache ? buffer_cache->buffer : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
    if (!native_direct_flush_mapped_range(env, buffer_cache)) NAPI_THROW(env, "unmap: invalid mapped range");
    native_direct_invalidate_buffer_mapped_range_cache(env, buffer_cache);
    if (buffer_cache) buffer_cache->map_mode = 0;
    if (buffer) pfn_wgpuBufferUnmap(buffer);
    napi_value undefined_value;
    napi_get_undefined(env, &undefined_value);
    return undefined_value;
}

napi_value native_direct_buffer_destroy(napi_env env, napi_callback_info info) {
    size_t argc = 0;
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, NULL, &this_arg, NULL);
    NativeDirectBufferCache* buffer_cache = native_direct_get_buffer_cache(env, this_arg);
    WGPUBuffer buffer = buffer_cache ? buffer_cache->buffer : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
    native_direct_invalidate_buffer_mapped_range_cache(env, buffer_cache);
    if (buffer) {
        pfn_wgpuBufferDestroy(buffer);
        pfn_wgpuBufferRelease(buffer);
        native_direct_set_external_prop(env, this_arg, DOE_DIRECT_NATIVE, NULL);
        if (buffer_cache) buffer_cache->buffer = NULL;
    }
    napi_value undefined_value;
    napi_get_undefined(env, &undefined_value);
    return undefined_value;
}
