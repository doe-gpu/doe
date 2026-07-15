#include "doe_napi_internal.h"

/* Forward declarations for methods defined in other nd files */
napi_value native_direct_queue_submit(napi_env env, napi_callback_info info);
napi_value native_direct_queue_write_buffer(napi_env env, napi_callback_info info);
napi_value native_direct_queue_write_buffer_batch(napi_env env, napi_callback_info info);
napi_value native_direct_queue_write_texture(napi_env env, napi_callback_info info);
napi_value native_direct_queue_on_submitted_work_done(napi_env env, napi_callback_info info);
napi_value native_direct_buffer_map_async(napi_env env, napi_callback_info info);
napi_value native_direct_buffer_get_mapped_range(napi_env env, napi_callback_info info);
napi_value native_direct_buffer_read_copy(napi_env env, napi_callback_info info);
napi_value native_direct_buffer_map_read_copy_unmap(napi_env env, napi_callback_info info);
napi_value native_direct_buffer_unmap(napi_env env, napi_callback_info info);
napi_value native_direct_buffer_destroy(napi_env env, napi_callback_info info);
napi_value native_direct_device_create_buffer(napi_env env, napi_callback_info info);
napi_value native_direct_device_create_shader_module(napi_env env, napi_callback_info info);
napi_value native_direct_device_create_compute_pipeline(napi_env env, napi_callback_info info);
napi_value native_direct_device_create_compute_pipeline_async(napi_env env, napi_callback_info info);
napi_value native_direct_device_create_bind_group_layout(napi_env env, napi_callback_info info);
napi_value native_direct_device_create_bind_group(napi_env env, napi_callback_info info);
napi_value native_direct_device_create_pipeline_layout(napi_env env, napi_callback_info info);
napi_value native_direct_device_create_command_encoder(napi_env env, napi_callback_info info);
napi_value native_direct_device_destroy(napi_env env, napi_callback_info info);
napi_value native_direct_device_add_event_listener(napi_env env, napi_callback_info info);
napi_value native_direct_device_remove_event_listener(napi_env env, napi_callback_info info);
napi_value native_direct_device_import_external_texture(napi_env env, napi_callback_info info);
napi_value native_direct_command_encoder_begin_compute_pass(napi_env env, napi_callback_info info);
napi_value native_direct_command_encoder_copy_buffer_to_buffer(napi_env env, napi_callback_info info);
napi_value native_direct_command_encoder_clear_buffer(napi_env env, napi_callback_info info);
napi_value native_direct_command_encoder_copy_texture_to_texture(napi_env env, napi_callback_info info);
napi_value native_direct_command_encoder_finish(napi_env env, napi_callback_info info);
napi_value native_direct_compute_pass_set_pipeline(napi_env env, napi_callback_info info);
napi_value native_direct_compute_pass_set_bind_group(napi_env env, napi_callback_info info);
napi_value native_direct_compute_pass_dispatch_workgroups(napi_env env, napi_callback_info info);
napi_value native_direct_compute_pass_dispatch_workgroups_indirect(napi_env env, napi_callback_info info);
napi_value native_direct_compute_pass_end(napi_env env, napi_callback_info info);
napi_value native_direct_compute_pass_set_immediates(napi_env env, napi_callback_info info);
napi_value native_direct_compute_pass_push_debug_group(napi_env env, napi_callback_info info);
napi_value native_direct_compute_pass_pop_debug_group(napi_env env, napi_callback_info info);
napi_value native_direct_compute_pass_insert_debug_marker(napi_env env, napi_callback_info info);
napi_value native_direct_render_pass_set_immediates(napi_env env, napi_callback_info info);
napi_value native_direct_render_pass_set_viewport(napi_env env, napi_callback_info info);
napi_value native_direct_render_pass_set_scissor_rect(napi_env env, napi_callback_info info);
napi_value native_direct_render_pass_set_blend_constant(napi_env env, napi_callback_info info);
napi_value native_direct_render_pass_set_stencil_reference(napi_env env, napi_callback_info info);
napi_value native_direct_render_pass_push_debug_group(napi_env env, napi_callback_info info);
napi_value native_direct_render_pass_pop_debug_group(napi_env env, napi_callback_info info);
napi_value native_direct_render_pass_insert_debug_marker(napi_env env, napi_callback_info info);
napi_value native_direct_render_pass_draw_indirect(napi_env env, napi_callback_info info);
napi_value native_direct_render_pass_draw_indexed_indirect(napi_env env, napi_callback_info info);
napi_value native_direct_render_bundle_encoder_set_immediates(napi_env env, napi_callback_info info);
static bool native_direct_parse_device_descriptor(
    napi_env env,
    napi_value descriptor_value,
    WGPUDeviceDescriptor* out_desc,
    WGPUFeatureName** out_required_features,
    WGPULimits* out_required_limits
);

/* ================================================================
 * Adapter — getPreferredCanvasFormat
 * ================================================================ */

static napi_value native_direct_adapter_get_preferred_canvas_format(napi_env env, napi_callback_info info) {
    size_t argc = 0;
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, NULL, &this_arg, NULL);
    if (!pfn_doeNativeAdapterGetPreferredCanvasFormat) {
        /* Symbol not present yet — return the WebGPU preferred canvas format
         * for Apple Silicon (bgra8unorm is the Metal swapchain default). */
        napi_value result;
        napi_create_string_utf8(env, "bgra8unorm", NAPI_AUTO_LENGTH, &result);
        return result;
    }
    NativeDirectHandleCache* cache = native_direct_get_handle_cache(env, this_arg);
    void* adapter = cache ? cache->native : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
    uint32_t fmt = pfn_doeNativeAdapterGetPreferredCanvasFormat(adapter);
    const char* name = texture_format_u32_to_string(fmt);
    if (name) {
        napi_value result;
        napi_create_string_utf8(env, name, NAPI_AUTO_LENGTH, &result);
        return result;
    }
    /* Unknown format — return the raw u32. */
    napi_value result;
    napi_create_uint32(env, fmt, &result);
    return result;
}

/* ================================================================
 * Adapter — getInfo
 * ================================================================ */

static size_t native_direct_adapter_info_string_len(WGPUStringView view) {
    return view.length == WGPU_STRLEN ? NAPI_AUTO_LENGTH : view.length;
}

static void native_direct_set_adapter_info_string_prop(
    napi_env env,
    napi_value obj,
    const char* name,
    WGPUStringView view
) {
    napi_value value;
    const char* data = view.data ? view.data : "";
    napi_create_string_utf8(env, data, native_direct_adapter_info_string_len(view), &value);
    napi_set_named_property(env, obj, name, value);
}

static napi_value native_direct_adapter_get_info(napi_env env, napi_callback_info info) {
    size_t argc = 0;
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, NULL, &this_arg, NULL);

    napi_value obj;
    napi_create_object(env, &obj);

    napi_value v_vendor, v_arch, v_device, v_desc, v_is_fallback, v_sg_min, v_sg_max;
    napi_create_string_utf8(env, "", NAPI_AUTO_LENGTH, &v_vendor);
    napi_create_string_utf8(env, "", NAPI_AUTO_LENGTH, &v_arch);
    napi_create_string_utf8(env, "", NAPI_AUTO_LENGTH, &v_device);
    napi_create_string_utf8(env, "", NAPI_AUTO_LENGTH, &v_desc);
    napi_get_boolean(env, false, &v_is_fallback);
    napi_create_uint32(env, 0, &v_sg_min);
    napi_create_uint32(env, 0, &v_sg_max);
    napi_set_named_property(env, obj, "vendor", v_vendor);
    napi_set_named_property(env, obj, "architecture", v_arch);
    napi_set_named_property(env, obj, "device", v_device);
    napi_set_named_property(env, obj, "description", v_desc);
    napi_set_named_property(env, obj, "isFallbackAdapter", v_is_fallback);
    napi_set_named_property(env, obj, "subgroupMinSize", v_sg_min);
    napi_set_named_property(env, obj, "subgroupMaxSize", v_sg_max);

    NativeDirectHandleCache* cache = native_direct_get_handle_cache(env, this_arg);
    void* adapter = cache ? cache->native
                          : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);

    const char* vendor = "";
    const char* arch   = "";
    const char* device = "";
    const char* desc   = "";
    char* block = NULL;

    const bool tried_native_adapter_info =
        pfn_doeNativeAdapterGetInfo && pfn_doeNativeAdapterFreeInfo;

    if (tried_native_adapter_info) {
        pfn_doeNativeAdapterGetInfo(adapter, &vendor, &arch, &device, &desc, &block);
        if (!vendor) vendor = "";
        if (!arch)   arch   = "";
        if (!device) device = "";
        if (!desc)   desc   = "";
    }

    if (block && pfn_doeNativeAdapterFreeInfo) {
        napi_create_string_utf8(env, vendor, NAPI_AUTO_LENGTH, &v_vendor);
        napi_create_string_utf8(env, arch,   NAPI_AUTO_LENGTH, &v_arch);
        napi_create_string_utf8(env, device, NAPI_AUTO_LENGTH, &v_device);
        napi_create_string_utf8(env, desc,   NAPI_AUTO_LENGTH, &v_desc);
        napi_get_boolean(env, false, &v_is_fallback);
        napi_set_named_property(env, obj, "vendor",       v_vendor);
        napi_set_named_property(env, obj, "architecture", v_arch);
        napi_set_named_property(env, obj, "device",       v_device);
        napi_set_named_property(env, obj, "description",  v_desc);
        napi_set_named_property(env, obj, "isFallbackAdapter", v_is_fallback);

        napi_create_uint32(env, 32, &v_sg_min);
        napi_create_uint32(env, 32, &v_sg_max);
        napi_set_named_property(env, obj, "subgroupMinSize", v_sg_min);
        napi_set_named_property(env, obj, "subgroupMaxSize", v_sg_max);
        pfn_doeNativeAdapterFreeInfo(block);
        return obj;
    }

    WGPUAdapterInfo info_view;
    memset(&info_view, 0, sizeof(info_view));
    info_view.vendor.length = WGPU_STRLEN;
    info_view.architecture.length = WGPU_STRLEN;
    info_view.device.length = WGPU_STRLEN;
    info_view.description.length = WGPU_STRLEN;
    if (pfn_wgpuAdapterGetInfo && pfn_wgpuAdapterGetInfo(adapter, &info_view) == WGPU_STATUS_SUCCESS) {
        native_direct_set_adapter_info_string_prop(env, obj, "vendor", info_view.vendor);
        native_direct_set_adapter_info_string_prop(env, obj, "architecture", info_view.architecture);
        native_direct_set_adapter_info_string_prop(env, obj, "device", info_view.device);
        native_direct_set_adapter_info_string_prop(env, obj, "description", info_view.description);
        napi_get_boolean(env, false, &v_is_fallback);
        napi_create_uint32(env, info_view.subgroupMinSize, &v_sg_min);
        napi_create_uint32(env, info_view.subgroupMaxSize, &v_sg_max);
        napi_set_named_property(env, obj, "isFallbackAdapter", v_is_fallback);
        napi_set_named_property(env, obj, "subgroupMinSize", v_sg_min);
        napi_set_named_property(env, obj, "subgroupMaxSize", v_sg_max);

        if (pfn_wgpuAdapterInfoFreeMembers) {
            pfn_wgpuAdapterInfoFreeMembers(info_view);
        }
    }
    return obj;
}

/* ================================================================
 * ShaderModule — getCompilationInfo
 * ================================================================ */

static napi_value native_direct_shader_module_get_compilation_info(napi_env env, napi_callback_info info) {
    size_t argc = 0;
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, NULL, &this_arg, NULL);

    NativeDirectHandleCache* cache = native_direct_get_handle_cache(env, this_arg);
    void* module_raw = cache ? cache->native
                             : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);

    const char* json_str = "[]";
    if (pfn_doeNativeShaderModuleGetCompilationInfo) {
        const char* native_json = pfn_doeNativeShaderModuleGetCompilationInfo(module_raw);
        if (native_json) json_str = native_json;
    }

    /* Parse via JS JSON.parse — the Zig layer emits strict JSON. */
    napi_value global, json_obj, json_parse_fn, json_str_val, parse_args[1], parsed;
    napi_get_global(env, &global);
    napi_get_named_property(env, global, "JSON", &json_obj);
    napi_get_named_property(env, json_obj, "parse", &json_parse_fn);
    napi_create_string_utf8(env, json_str, NAPI_AUTO_LENGTH, &json_str_val);
    parse_args[0] = json_str_val;

    napi_value messages;
    napi_status parse_status = napi_call_function(env, json_obj, json_parse_fn, 1, parse_args, &parsed);
    if (parse_status != napi_ok) {
        napi_create_array_with_length(env, 0, &messages);
    } else {
        messages = parsed;
    }

    /* Ensure each message has all 5 required fields */
    uint32_t msg_count = 0;
    napi_get_array_length(env, messages, &msg_count);
    for (uint32_t i = 0; i < msg_count; i++) {
        napi_value msg_obj;
        napi_get_element(env, messages, i, &msg_obj);
        ensure_compilation_message_fields(env, msg_obj);
    }

    napi_value compilation_info;
    napi_create_object(env, &compilation_info);
    napi_set_named_property(env, compilation_info, "messages", messages);
    return native_direct_resolved_promise(env, compilation_info);
}

/* ================================================================
 * Adapter lifecycle — requestAdapter, requestDevice, destroy
 * ================================================================ */

static napi_value native_direct_gpu_request_adapter(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    WGPUInstance inst = native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_INSTANCE);
    napi_value options = (argc >= 1) ? argv[0] : NULL;
    WGPUAdapter adapter = native_direct_request_adapter_sync(env, inst, options);
    if (!adapter) return NULL;
    return native_direct_resolved_promise(env, create_native_direct_adapter_object(env, inst, adapter));
}

static napi_value native_direct_adapter_request_device(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    WGPUInstance inst = native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_INSTANCE);
    WGPUAdapter adapter = native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
    WGPUDeviceDescriptor descriptor = {0};
    WGPUFeatureName* required_features = NULL;
    WGPULimits required_limits = {0};
    const WGPUDeviceDescriptor* descriptor_ptr = NULL;
    if (argc >= 1 && argv[0] != NULL) {
        napi_valuetype vt = napi_undefined;
        if (napi_typeof(env, argv[0], &vt) == napi_ok && vt == napi_object) {
            if (!native_direct_parse_device_descriptor(env, argv[0], &descriptor, &required_features, &required_limits)) {
                free(required_features);
                if (descriptor.label.data) free((void*)descriptor.label.data);
                if (descriptor.defaultQueue.label.data) free((void*)descriptor.defaultQueue.label.data);
                return NULL;
            }
            descriptor_ptr = &descriptor;
        }
    }

    DeviceRequestResult result = {0};
    const WGPURequestDeviceCallbackInfo callback_info = {
        .nextInChain = NULL,
        .mode = WGPU_CALLBACK_MODE_ALLOW_PROCESS_EVENTS,
        .callback = device_callback,
        .userdata1 = &result,
        .userdata2 = NULL,
    };
    WGPUFuture future = pfn_doeNativeAdapterRequestDevice
        ? pfn_doeNativeAdapterRequestDevice(adapter, descriptor_ptr, callback_info)
        : pfn_wgpuAdapterRequestDevice(adapter, descriptor_ptr, callback_info);
    if (future.id == 0) {
        free(required_features);
        if (descriptor.label.data) free((void*)descriptor.label.data);
        if (descriptor.defaultQueue.label.data) free((void*)descriptor.defaultQueue.label.data);
        NAPI_THROW(env, "requestDevice future unavailable");
    }
    if (!process_events_until(inst, &result.done, current_timeout_ns())) {
        free(required_features);
        if (descriptor.label.data) free((void*)descriptor.label.data);
        if (descriptor.defaultQueue.label.data) free((void*)descriptor.defaultQueue.label.data);
        throw_status_error(env, "DOE_REQUEST_DEVICE_TIMEOUT", "requestDevice timed out", result.status, result.message);
        return NULL;
    }
    if (result.status != WGPU_REQUEST_STATUS_SUCCESS || !result.device) {
        free(required_features);
        if (descriptor.label.data) free((void*)descriptor.label.data);
        if (descriptor.defaultQueue.label.data) free((void*)descriptor.defaultQueue.label.data);
        throw_status_error(env, "DOE_REQUEST_DEVICE_ERROR", "requestDevice failed", result.status, result.message);
        return NULL;
    }

    napi_value device_obj = create_native_direct_device_object(env, inst, result.device);
    if (device_obj && descriptor_ptr) {
        if (descriptor.label.data && descriptor.label.length > 0) {
            napi_value label_value;
            napi_create_string_utf8(env, descriptor.label.data, descriptor.label.length, &label_value);
            napi_set_named_property(env, device_obj, "label", label_value);
        }
        if (descriptor.defaultQueue.label.data && descriptor.defaultQueue.label.length > 0) {
            napi_value queue_obj;
            if (napi_get_named_property(env, device_obj, "queue", &queue_obj) == napi_ok) {
                napi_value label_value;
                napi_create_string_utf8(env, descriptor.defaultQueue.label.data, descriptor.defaultQueue.label.length, &label_value);
                napi_set_named_property(env, queue_obj, "label", label_value);
            }
        }
    }
    free(required_features);
    if (descriptor.label.data) free((void*)descriptor.label.data);
    if (descriptor.defaultQueue.label.data) free((void*)descriptor.defaultQueue.label.data);
    return native_direct_resolved_promise(env, device_obj);
}

static napi_value native_direct_adapter_destroy(napi_env env, napi_callback_info info) {
    size_t argc = 0;
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, NULL, &this_arg, NULL);
    WGPUAdapter adapter = native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
    if (adapter) {
        pfn_wgpuAdapterRelease(adapter);
        native_direct_set_external_prop(env, this_arg, DOE_DIRECT_NATIVE, NULL);
    }
    napi_value undefined_value;
    napi_get_undefined(env, &undefined_value);
    return undefined_value;
}

/* ================================================================
 * Object constructors
 * ================================================================ */

typedef struct {
    const char* name;
    uint32_t value;
} NativeDirectFeatureEntry;

static napi_value native_direct_create_feature_set(
    napi_env env,
    bool (*has_feature_fn)(void* handle, uint32_t feature),
    void* handle
) {
    static const NativeDirectFeatureEntry feature_entries[] = {
        { "core-features-and-limits", 0x00000001 },
        { "depth-clip-control", 0x00000002 },
        { "depth32float-stencil8", 0x00000003 },
        { "texture-compression-bc", 0x00000004 },
        { "texture-compression-bc-sliced-3d", 0x00000005 },
        { "texture-compression-etc2", 0x00000006 },
        { "texture-compression-astc", 0x00000007 },
        { "texture-compression-astc-sliced-3d", 0x00000008 },
        { "timestamp-query", 0x00000009 },
        { "indirect-first-instance", 0x0000000A },
        { "shader-f16", 0x0000000B },
        { "rg11b10ufloat-renderable", 0x0000000C },
        { "bgra8unorm-storage", 0x0000000D },
        { "float32-filterable", 0x0000000E },
        { "float32-blendable", 0x0000000F },
        { "clip-distances", 0x00000010 },
        { "dual-source-blending", 0x00000011 },
        { "subgroups", 0x00000012 },
        { "texture-formats-tier1", 0x00000013 },
        { "texture-formats-tier2", 0x00000014 },
        { "primitive-index", 0x00000015 },
        { "texture-component-swizzle", 0x00000016 },
    };
    napi_value set = native_direct_create_empty_set(env);
    if (!has_feature_fn || !handle) {
        return set;
    }

    napi_value add_fn;
    napi_get_named_property(env, set, "add", &add_fn);
    for (size_t i = 0; i < sizeof(feature_entries) / sizeof(feature_entries[0]); i += 1) {
        if (!has_feature_fn(handle, feature_entries[i].value)) {
            continue;
        }
        napi_value name_value;
        napi_create_string_utf8(env, feature_entries[i].name, NAPI_AUTO_LENGTH, &name_value);
        napi_value argv[] = { name_value };
        napi_call_function(env, set, add_fn, 1, argv, NULL);
    }
    return set;
}

static bool native_direct_adapter_has_feature_value(void* handle, uint32_t feature) {
    if (!handle) return false;
    if (pfn_doeNativeAdapterHasFeature) {
        return pfn_doeNativeAdapterHasFeature(handle, feature) != 0;
    }
    if (pfn_wgpuAdapterHasFeature) {
        return pfn_wgpuAdapterHasFeature(handle, feature) != 0;
    }
    return false;
}

static bool native_direct_device_has_feature_value(void* handle, uint32_t feature) {
    if (!handle) return false;
    if (pfn_doeNativeDeviceHasFeature) {
        return pfn_doeNativeDeviceHasFeature(handle, feature) != 0;
    }
    if (pfn_wgpuDeviceHasFeature) {
        return pfn_wgpuDeviceHasFeature(handle, feature) != 0;
    }
    return false;
}

static bool native_direct_feature_name_from_string(const char* feature, uint32_t* out_feature) {
    static const struct { const char* name; uint32_t value; } entries[] = {
        { "core-features-and-limits", 0x00000001 },
        { "depth-clip-control", 0x00000002 },
        { "depth32float-stencil8", 0x00000003 },
        { "texture-compression-bc", 0x00000004 },
        { "texture-compression-bc-sliced-3d", 0x00000005 },
        { "texture-compression-etc2", 0x00000006 },
        { "texture-compression-astc", 0x00000007 },
        { "texture-compression-astc-sliced-3d", 0x00000008 },
        { "timestamp-query", 0x00000009 },
        { "indirect-first-instance", 0x0000000A },
        { "shader-f16", 0x0000000B },
        { "rg11b10ufloat-renderable", 0x0000000C },
        { "bgra8unorm-storage", 0x0000000D },
        { "float32-filterable", 0x0000000E },
        { "float32-blendable", 0x0000000F },
        { "clip-distances", 0x00000010 },
        { "dual-source-blending", 0x00000011 },
        { "subgroups", 0x00000012 },
        { "texture-formats-tier1", 0x00000013 },
        { "texture-formats-tier2", 0x00000014 },
        { "primitive-index", 0x00000015 },
        { "texture-component-swizzle", 0x00000016 },
    };
    for (size_t i = 0; i < sizeof(entries) / sizeof(entries[0]); i += 1) {
        if (strcmp(feature, entries[i].name) == 0) {
            if (out_feature) *out_feature = entries[i].value;
            return true;
        }
    }
    return false;
}

static bool native_direct_read_u32_prop(napi_env env, napi_value obj, const char* key, uint32_t* out) {
    napi_value value;
    if (napi_get_named_property(env, obj, key, &value) != napi_ok) return true;
    napi_valuetype vt = napi_undefined;
    if (napi_typeof(env, value, &vt) != napi_ok) return false;
    if (vt == napi_undefined || vt == napi_null) return true;
    if (napi_get_value_uint32(env, value, out) != napi_ok) {
        NAPI_THROW(env, "descriptor.requiredLimits contains a non-number value");
        return false;
    }
    return true;
}

static bool native_direct_read_u64_prop(napi_env env, napi_value obj, const char* key, uint64_t* out) {
    napi_value value;
    if (napi_get_named_property(env, obj, key, &value) != napi_ok) return true;
    napi_valuetype vt = napi_undefined;
    if (napi_typeof(env, value, &vt) != napi_ok) return false;
    if (vt == napi_undefined || vt == napi_null) return true;
    double numeric_value = 0;
    if (napi_get_value_double(env, value, &numeric_value) != napi_ok || !isfinite(numeric_value) || numeric_value < 0) {
        NAPI_THROW(env, "descriptor.requiredLimits contains a non-number value");
        return false;
    }
    *out = (uint64_t)numeric_value;
    return true;
}

static bool native_direct_parse_required_limits(napi_env env, napi_value limits_value, WGPULimits* limits) {
    memset(limits, 0, sizeof(*limits));
    if (limits_value == NULL) return true;
    napi_valuetype vt = napi_undefined;
    if (napi_typeof(env, limits_value, &vt) != napi_ok) {
        NAPI_THROW(env, "descriptor.requiredLimits must be an object");
        return false;
    }
    if (vt == napi_undefined || vt == napi_null) return true;
    if (vt != napi_object) {
        NAPI_THROW(env, "descriptor.requiredLimits must be an object");
        return false;
    }
    if (!native_direct_read_u32_prop(env, limits_value, "maxTextureDimension1D", &limits->maxTextureDimension1D)) return false;
    if (!native_direct_read_u32_prop(env, limits_value, "maxTextureDimension2D", &limits->maxTextureDimension2D)) return false;
    if (!native_direct_read_u32_prop(env, limits_value, "maxTextureDimension3D", &limits->maxTextureDimension3D)) return false;
    if (!native_direct_read_u32_prop(env, limits_value, "maxTextureArrayLayers", &limits->maxTextureArrayLayers)) return false;
    if (!native_direct_read_u32_prop(env, limits_value, "maxBindGroups", &limits->maxBindGroups)) return false;
    if (!native_direct_read_u32_prop(env, limits_value, "maxBindGroupsPlusVertexBuffers", &limits->maxBindGroupsPlusVertexBuffers)) return false;
    if (!native_direct_read_u32_prop(env, limits_value, "maxBindingsPerBindGroup", &limits->maxBindingsPerBindGroup)) return false;
    if (!native_direct_read_u32_prop(env, limits_value, "maxDynamicUniformBuffersPerPipelineLayout", &limits->maxDynamicUniformBuffersPerPipelineLayout)) return false;
    if (!native_direct_read_u32_prop(env, limits_value, "maxDynamicStorageBuffersPerPipelineLayout", &limits->maxDynamicStorageBuffersPerPipelineLayout)) return false;
    if (!native_direct_read_u32_prop(env, limits_value, "maxSampledTexturesPerShaderStage", &limits->maxSampledTexturesPerShaderStage)) return false;
    if (!native_direct_read_u32_prop(env, limits_value, "maxSamplersPerShaderStage", &limits->maxSamplersPerShaderStage)) return false;
    if (!native_direct_read_u32_prop(env, limits_value, "maxStorageBuffersPerShaderStage", &limits->maxStorageBuffersPerShaderStage)) return false;
    if (!native_direct_read_u32_prop(env, limits_value, "maxStorageTexturesPerShaderStage", &limits->maxStorageTexturesPerShaderStage)) return false;
    if (!native_direct_read_u32_prop(env, limits_value, "maxUniformBuffersPerShaderStage", &limits->maxUniformBuffersPerShaderStage)) return false;
    if (!native_direct_read_u64_prop(env, limits_value, "maxUniformBufferBindingSize", &limits->maxUniformBufferBindingSize)) return false;
    if (!native_direct_read_u64_prop(env, limits_value, "maxStorageBufferBindingSize", &limits->maxStorageBufferBindingSize)) return false;
    if (!native_direct_read_u32_prop(env, limits_value, "minUniformBufferOffsetAlignment", &limits->minUniformBufferOffsetAlignment)) return false;
    if (!native_direct_read_u32_prop(env, limits_value, "minStorageBufferOffsetAlignment", &limits->minStorageBufferOffsetAlignment)) return false;
    if (!native_direct_read_u32_prop(env, limits_value, "maxVertexBuffers", &limits->maxVertexBuffers)) return false;
    if (!native_direct_read_u64_prop(env, limits_value, "maxBufferSize", &limits->maxBufferSize)) return false;
    if (!native_direct_read_u32_prop(env, limits_value, "maxVertexAttributes", &limits->maxVertexAttributes)) return false;
    if (!native_direct_read_u32_prop(env, limits_value, "maxVertexBufferArrayStride", &limits->maxVertexBufferArrayStride)) return false;
    if (!native_direct_read_u32_prop(env, limits_value, "maxInterStageShaderVariables", &limits->maxInterStageShaderVariables)) return false;
    if (!native_direct_read_u32_prop(env, limits_value, "maxColorAttachments", &limits->maxColorAttachments)) return false;
    if (!native_direct_read_u32_prop(env, limits_value, "maxColorAttachmentBytesPerSample", &limits->maxColorAttachmentBytesPerSample)) return false;
    if (!native_direct_read_u32_prop(env, limits_value, "maxComputeWorkgroupStorageSize", &limits->maxComputeWorkgroupStorageSize)) return false;
    if (!native_direct_read_u32_prop(env, limits_value, "maxComputeInvocationsPerWorkgroup", &limits->maxComputeInvocationsPerWorkgroup)) return false;
    if (!native_direct_read_u32_prop(env, limits_value, "maxComputeWorkgroupSizeX", &limits->maxComputeWorkgroupSizeX)) return false;
    if (!native_direct_read_u32_prop(env, limits_value, "maxComputeWorkgroupSizeY", &limits->maxComputeWorkgroupSizeY)) return false;
    if (!native_direct_read_u32_prop(env, limits_value, "maxComputeWorkgroupSizeZ", &limits->maxComputeWorkgroupSizeZ)) return false;
    if (!native_direct_read_u32_prop(env, limits_value, "maxComputeWorkgroupsPerDimension", &limits->maxComputeWorkgroupsPerDimension)) return false;
    if (!native_direct_read_u32_prop(env, limits_value, "maxImmediateSize", &limits->maxImmediateSize)) return false;
    return true;
}

static bool native_direct_parse_feature_array(napi_env env, napi_value features_value, WGPUFeatureName** out_features, size_t* out_count) {
    if (out_features) *out_features = NULL;
    if (out_count) *out_count = 0;
    if (features_value == NULL) return true;
    napi_valuetype vt = napi_undefined;
    if (napi_typeof(env, features_value, &vt) != napi_ok) {
        NAPI_THROW(env, "descriptor.requiredFeatures must be an array of strings");
        return false;
    }
    if (vt == napi_undefined || vt == napi_null) return true;
    if (vt != napi_object) {
        NAPI_THROW(env, "descriptor.requiredFeatures must be an array of strings");
        return false;
    }
    bool is_array = false;
    if (napi_is_array(env, features_value, &is_array) != napi_ok || !is_array) {
        NAPI_THROW(env, "descriptor.requiredFeatures must be an array of strings");
        return false;
    }
    uint32_t count = 0;
    if (napi_get_array_length(env, features_value, &count) != napi_ok) {
        NAPI_THROW(env, "failed to read descriptor.requiredFeatures length");
        return false;
    }
    if (count == 0) return true;
    WGPUFeatureName* features = (WGPUFeatureName*)calloc(count, sizeof(WGPUFeatureName));
    if (!features) {
        NAPI_THROW(env, "out of memory while parsing descriptor.requiredFeatures");
        return false;
    }
    for (uint32_t i = 0; i < count; i += 1) {
        napi_value item;
        if (napi_get_element(env, features_value, i, &item) != napi_ok) {
            free(features);
            NAPI_THROW(env, "failed to read descriptor.requiredFeatures entry");
            return false;
        }
        napi_valuetype item_type = napi_undefined;
        if (napi_typeof(env, item, &item_type) != napi_ok || item_type != napi_string) {
            free(features);
            NAPI_THROW(env, "descriptor.requiredFeatures entries must be strings");
            return false;
        }
        char feature_name[128];
        size_t feature_name_len = 0;
        if (napi_get_value_string_utf8(env, item, feature_name, sizeof(feature_name), &feature_name_len) != napi_ok) {
            free(features);
            NAPI_THROW(env, "failed to read descriptor.requiredFeatures entry");
            return false;
        }
        feature_name[sizeof(feature_name) - 1] = '\0';
        uint32_t feature_value = 0;
        if (!native_direct_feature_name_from_string(feature_name, &feature_value)) {
            free(features);
            NAPI_THROW(env, "descriptor.requiredFeatures contains an unsupported feature");
            return false;
        }
        features[i] = feature_value;
    }
    if (out_features) *out_features = features;
    if (out_count) *out_count = count;
    return true;
}

static bool native_direct_parse_queue_label(napi_env env, napi_value queue_value, WGPUStringView* out_label) {
    out_label->data = NULL;
    out_label->length = 0;
    if (queue_value == NULL) return true;
    napi_valuetype vt = napi_undefined;
    if (napi_typeof(env, queue_value, &vt) != napi_ok) {
        NAPI_THROW(env, "descriptor.defaultQueue must be an object");
        return false;
    }
    if (vt == napi_undefined || vt == napi_null) return true;
    if (vt != napi_object) {
        NAPI_THROW(env, "descriptor.defaultQueue must be an object");
        return false;
    }
    napi_value label_value;
    if (napi_get_named_property(env, queue_value, "label", &label_value) != napi_ok) return true;
    if (napi_typeof(env, label_value, &vt) != napi_ok || vt != napi_string) {
        NAPI_THROW(env, "descriptor.defaultQueue.label must be a string");
        return false;
    }
    char* label = dup_string_value(env, label_value, &out_label->length);
    if (!label) {
        NAPI_THROW(env, "out of memory while parsing descriptor.defaultQueue.label");
        return false;
    }
    out_label->data = label;
    return true;
}

static bool native_direct_parse_device_descriptor(
    napi_env env,
    napi_value descriptor_value,
    WGPUDeviceDescriptor* out_desc,
    WGPUFeatureName** out_required_features,
    WGPULimits* out_required_limits
) {
    memset(out_desc, 0, sizeof(*out_desc));
    if (out_required_features) *out_required_features = NULL;
    if (out_required_limits) memset(out_required_limits, 0, sizeof(*out_required_limits));
    if (descriptor_value == NULL) return true;

    napi_valuetype vt = napi_undefined;
    if (napi_typeof(env, descriptor_value, &vt) != napi_ok || vt != napi_object) {
        NAPI_THROW(env, "GPUAdapter.requestDevice descriptor must be an object");
        return false;
    }

    napi_value label_value;
    if (napi_get_named_property(env, descriptor_value, "label", &label_value) == napi_ok) {
        if (napi_typeof(env, label_value, &vt) != napi_ok) {
            NAPI_THROW(env, "descriptor.label must be a string");
            return false;
        }
        if (vt == napi_undefined || vt == napi_null) {
            label_value = NULL;
        } else if (vt != napi_string) {
            NAPI_THROW(env, "descriptor.label must be a string");
            return false;
        } else {
            char* label = dup_string_value(env, label_value, &out_desc->label.length);
            if (!label) {
                NAPI_THROW(env, "out of memory while parsing descriptor.label");
                return false;
            }
            out_desc->label.data = label;
        }
    }

    napi_value features_value;
    if (napi_get_named_property(env, descriptor_value, "requiredFeatures", &features_value) == napi_ok) {
        if (!native_direct_parse_feature_array(env, features_value, out_required_features, &out_desc->requiredFeatureCount)) {
            return false;
        }
        out_desc->requiredFeatures = out_required_features ? *out_required_features : NULL;
    }

#ifdef _WIN32
    napi_value limits_value;
    if (napi_get_named_property(env, descriptor_value, "requiredLimits", &limits_value) == napi_ok) {
        if (!native_direct_parse_required_limits(env, limits_value, out_required_limits)) {
            return false;
        }
        out_desc->requiredLimits = out_required_limits;
    }
#endif

    napi_value default_queue_value;
    if (napi_get_named_property(env, descriptor_value, "defaultQueue", &default_queue_value) == napi_ok) {
        if (!native_direct_parse_queue_label(env, default_queue_value, &out_desc->defaultQueue.label)) {
            return false;
        }
    }

    return true;
}

napi_value create_native_direct_gpu_object(napi_env env, WGPUInstance instance) {
    napi_value obj;
    napi_create_object(env, &obj);
    native_direct_set_external_prop(env, obj, DOE_DIRECT_INSTANCE, instance);
    native_direct_wrap_handle_cache(env, obj, instance, NULL);
    native_direct_add_cached_method(env, obj, "requestAdapter", native_direct_gpu_request_adapter, &native_direct_method_gpu_request_adapter_ref);
    return obj;
}

napi_value create_native_direct_adapter_object(napi_env env, WGPUInstance instance, WGPUAdapter adapter) {
    napi_value obj;
    napi_create_object(env, &obj);
    native_direct_set_external_prop(env, obj, DOE_DIRECT_INSTANCE, instance);
    native_direct_set_external_prop(env, obj, DOE_DIRECT_NATIVE, adapter);
    native_direct_wrap_handle_cache(env, obj, instance, adapter);
    bool limits_ok = false;
    WGPULimits limits = native_direct_query_adapter_limits(adapter, &limits_ok);
    native_direct_set_object_prop(env, obj, "limits", limits_ok ? create_limits_object(env, &limits) : native_direct_create_empty_object(env));
    native_direct_set_object_prop(env, obj, "features", native_direct_create_feature_set(env, native_direct_adapter_has_feature_value, adapter));
    native_direct_add_cached_method(env, obj, "requestDevice", native_direct_adapter_request_device, &native_direct_method_adapter_request_device_ref);
    native_direct_add_cached_method(env, obj, "destroy", native_direct_adapter_destroy, &native_direct_method_adapter_destroy_ref);
    native_direct_add_cached_method(env, obj, "getPreferredCanvasFormat", native_direct_adapter_get_preferred_canvas_format, &native_direct_method_adapter_get_preferred_canvas_format_ref);
    /* GPUAdapter.info — method that returns the info object directly (not async). */
    native_direct_add_cached_method(env, obj, "getInfo", native_direct_adapter_get_info, &native_direct_method_adapter_get_info_ref);
    return obj;
}

napi_value create_native_direct_queue_object(napi_env env, WGPUInstance instance, WGPUQueue queue) {
    napi_value obj;
    napi_create_object(env, &obj);
    napi_value empty_label;
    napi_create_string_utf8(env, "", NAPI_AUTO_LENGTH, &empty_label);
    napi_set_named_property(env, obj, "label", empty_label);
    native_direct_set_external_prop(env, obj, DOE_DIRECT_INSTANCE, instance);
    native_direct_set_external_prop(env, obj, DOE_DIRECT_NATIVE, queue);
    native_direct_set_external_prop(env, obj, DOE_DIRECT_QUEUE_NATIVE, queue);
    native_direct_set_uint32_prop(env, obj, DOE_DIRECT_SUBMITTED_SERIAL, 0);
    native_direct_set_uint32_prop(env, obj, DOE_DIRECT_COMPLETED_SERIAL, 0);
    native_direct_set_double_prop(env, obj, DOE_DIRECT_DIAG_SUBMIT_WAIT_MS, 0.0);
    native_direct_set_double_prop(env, obj, DOE_DIRECT_DIAG_QUEUE_FLUSH_MS, 0.0);
    native_direct_wrap_queue_cache(env, obj, instance, queue);
    native_direct_add_cached_method(env, obj, "submit", native_direct_queue_submit, &native_direct_method_queue_submit_ref);
    native_direct_add_cached_method(env, obj, "writeBuffer", native_direct_queue_write_buffer, &native_direct_method_queue_write_buffer_ref);
    native_direct_add_cached_method(env, obj, "writeBufferBatch", native_direct_queue_write_buffer_batch, &native_direct_method_queue_write_buffer_batch_ref);
    native_direct_add_cached_method(env, obj, "writeTexture", native_direct_queue_write_texture, &native_direct_method_queue_write_texture_ref);
    native_direct_add_cached_method(env, obj, "onSubmittedWorkDone", native_direct_queue_on_submitted_work_done, &native_direct_method_queue_on_submitted_work_done_ref);
    return obj;
}

napi_value create_native_direct_device_object(napi_env env, WGPUInstance instance, WGPUDevice device) {
    napi_value obj;
    WGPUQueue queue = pfn_wgpuDeviceGetQueue(device);
    napi_create_object(env, &obj);
    napi_value empty_label;
    napi_create_string_utf8(env, "", NAPI_AUTO_LENGTH, &empty_label);
    napi_set_named_property(env, obj, "label", empty_label);
    native_direct_set_external_prop(env, obj, DOE_DIRECT_INSTANCE, instance);
    native_direct_set_external_prop(env, obj, DOE_DIRECT_NATIVE, device);
    native_direct_wrap_handle_cache(env, obj, instance, device);
    bool limits_ok = false;
    WGPULimits limits = native_direct_query_device_limits(device, &limits_ok);
    native_direct_set_object_prop(env, obj, "limits", limits_ok ? create_limits_object(env, &limits) : native_direct_create_empty_object(env));
    native_direct_set_object_prop(env, obj, "features", native_direct_create_feature_set(env, native_direct_device_has_feature_value, device));
    native_direct_set_object_prop(env, obj, "queue", create_native_direct_queue_object(env, instance, queue));
    native_direct_add_cached_method(env, obj, "createBuffer", native_direct_device_create_buffer, &native_direct_method_device_create_buffer_ref);
    native_direct_add_cached_method(env, obj, "createShaderModule", native_direct_device_create_shader_module, &native_direct_method_device_create_shader_module_ref);
    native_direct_add_cached_method(env, obj, "createComputePipeline", native_direct_device_create_compute_pipeline, &native_direct_method_device_create_compute_pipeline_ref);
    native_direct_add_cached_method(env, obj, "createComputePipelineAsync", native_direct_device_create_compute_pipeline_async, &native_direct_method_device_create_compute_pipeline_async_ref);
    native_direct_add_cached_method(env, obj, "createBindGroupLayout", native_direct_device_create_bind_group_layout, &native_direct_method_device_create_bind_group_layout_ref);
    native_direct_add_cached_method(env, obj, "createBindGroup", native_direct_device_create_bind_group, &native_direct_method_device_create_bind_group_ref);
    native_direct_add_cached_method(env, obj, "createPipelineLayout", native_direct_device_create_pipeline_layout, &native_direct_method_device_create_pipeline_layout_ref);
    native_direct_add_cached_method(env, obj, "createCommandEncoder", native_direct_device_create_command_encoder, &native_direct_method_device_create_command_encoder_ref);
    native_direct_add_cached_method(env, obj, "destroy", native_direct_device_destroy, &native_direct_method_device_destroy_ref);
    native_direct_add_cached_method(env, obj, "addEventListener", native_direct_device_add_event_listener, &native_direct_method_device_add_event_listener_ref);
    native_direct_add_cached_method(env, obj, "removeEventListener", native_direct_device_remove_event_listener, &native_direct_method_device_remove_event_listener_ref);
    native_direct_add_cached_method(env, obj, "importExternalTexture", native_direct_device_import_external_texture, &native_direct_method_device_import_external_texture_ref);
    return obj;
}

napi_value create_native_direct_buffer_object(napi_env env, WGPUInstance instance, napi_value queue_obj, WGPUBuffer buffer, uint64_t size, uint64_t usage) {
    napi_value obj;
    napi_create_object(env, &obj);
    native_direct_set_external_prop(env, obj, DOE_DIRECT_INSTANCE, instance);
    native_direct_set_external_prop(env, obj, DOE_DIRECT_NATIVE, buffer);
    native_direct_set_object_prop(env, obj, DOE_DIRECT_QUEUE, queue_obj);
    native_direct_set_double_prop(env, obj, "size", (double)size);
    native_direct_set_double_prop(env, obj, "usage", (double)usage);
    native_direct_set_double_prop(env, obj, DOE_DIRECT_DIAG_MAP_ASYNC_MS, 0.0);
    native_direct_set_double_prop(env, obj, DOE_DIRECT_DIAG_MAP_QUEUE_FLUSH_MS, 0.0);
    native_direct_set_double_prop(env, obj, DOE_DIRECT_DIAG_GET_MAPPED_RANGE_MS, 0.0);
    native_direct_set_double_prop(env, obj, DOE_DIRECT_DIAG_MAP_READ_COPY_UNMAP_QUEUE_WAIT_COMPLETED_MS, 0.0);
    native_direct_set_double_prop(env, obj, DOE_DIRECT_DIAG_MAP_READ_COPY_UNMAP_DEFERRED_COPY_MS, 0.0);
    native_direct_set_double_prop(env, obj, DOE_DIRECT_DIAG_MAP_READ_COPY_UNMAP_DEFERRED_RESOLVE_MS, 0.0);
    native_direct_set_double_prop(env, obj, DOE_DIRECT_DIAG_MAP_READ_COPY_UNMAP_MAP_MS, 0.0);
    native_direct_set_double_prop(env, obj, DOE_DIRECT_DIAG_MAP_READ_COPY_UNMAP_COPY_MS, 0.0);
    native_direct_set_double_prop(env, obj, DOE_DIRECT_DIAG_MAP_READ_COPY_UNMAP_UNMAP_MS, 0.0);
    native_direct_wrap_buffer_cache(env, obj, instance, buffer, size, usage, queue_obj);
    native_direct_add_cached_method(env, obj, "mapAsync", native_direct_buffer_map_async, &native_direct_method_buffer_map_async_ref);
    native_direct_add_cached_method(env, obj, "getMappedRange", native_direct_buffer_get_mapped_range, &native_direct_method_buffer_get_mapped_range_ref);
    native_direct_add_cached_method(env, obj, "_readCopy", native_direct_buffer_read_copy, &native_direct_method_buffer_read_copy_ref);
    native_direct_add_cached_method(env, obj, "_mapReadCopyUnmap", native_direct_buffer_map_read_copy_unmap, &native_direct_method_buffer_map_read_copy_unmap_ref);
    native_direct_add_cached_method(env, obj, "unmap", native_direct_buffer_unmap, &native_direct_method_buffer_unmap_ref);
    native_direct_add_cached_method(env, obj, "destroy", native_direct_buffer_destroy, &native_direct_method_buffer_destroy_ref);
    return obj;
}

napi_value create_native_direct_bind_group_layout_object(napi_env env, WGPUBindGroupLayout layout) {
    napi_value obj;
    napi_create_object(env, &obj);
    native_direct_set_external_prop(env, obj, DOE_DIRECT_NATIVE, layout);
    native_direct_wrap_handle_cache(env, obj, NULL, layout);
    return obj;
}

napi_value create_native_direct_bind_group_object(napi_env env, WGPUBindGroup group) {
    napi_value obj;
    napi_create_object(env, &obj);
    native_direct_set_external_prop(env, obj, DOE_DIRECT_NATIVE, group);
    native_direct_wrap_handle_cache(env, obj, NULL, group);
    return obj;
}

napi_value create_native_direct_pipeline_layout_object(napi_env env, WGPUPipelineLayout layout) {
    napi_value obj;
    napi_create_object(env, &obj);
    native_direct_set_external_prop(env, obj, DOE_DIRECT_NATIVE, layout);
    native_direct_wrap_handle_cache(env, obj, NULL, layout);
    return obj;
}

napi_value create_native_direct_shader_module_object(napi_env env, WGPUShaderModule shader_module) {
    napi_value obj;
    napi_create_object(env, &obj);
    native_direct_set_external_prop(env, obj, DOE_DIRECT_NATIVE, shader_module);
    native_direct_wrap_handle_cache(env, obj, NULL, shader_module);
    /* GPUShaderModule.getCompilationInfo() — returns a Promise<GPUCompilationInfo>. */
    native_direct_add_cached_method(env, obj, "getCompilationInfo", native_direct_shader_module_get_compilation_info, &native_direct_method_shader_module_get_compilation_info_ref);
    return obj;
}

napi_value create_native_direct_compute_pipeline_object(napi_env env, WGPUComputePipeline pipeline) {
    napi_value obj;
    napi_create_object(env, &obj);
    native_direct_set_external_prop(env, obj, DOE_DIRECT_NATIVE, pipeline);
    native_direct_wrap_handle_cache(env, obj, NULL, pipeline);
    return obj;
}

napi_value create_native_direct_command_buffer_object(napi_env env, WGPUCommandBuffer command_buffer) {
    napi_value obj;
    napi_create_object(env, &obj);
    native_direct_set_external_prop(env, obj, DOE_DIRECT_NATIVE, command_buffer);
    native_direct_wrap_handle_cache(env, obj, NULL, command_buffer);
    return obj;
}

napi_value create_native_direct_command_encoder_object(napi_env env, WGPUCommandEncoder encoder) {
    napi_value obj;
    napi_create_object(env, &obj);
    native_direct_set_external_prop(env, obj, DOE_DIRECT_NATIVE, encoder);
    native_direct_wrap_handle_cache(env, obj, NULL, encoder);
    native_direct_add_cached_method(env, obj, "beginComputePass", native_direct_command_encoder_begin_compute_pass, &native_direct_method_command_encoder_begin_compute_pass_ref);
    native_direct_add_cached_method(env, obj, "copyBufferToBuffer", native_direct_command_encoder_copy_buffer_to_buffer, &native_direct_method_command_encoder_copy_buffer_to_buffer_ref);
    native_direct_add_cached_method(env, obj, "clearBuffer", native_direct_command_encoder_clear_buffer, &native_direct_method_command_encoder_clear_buffer_ref);
    native_direct_add_cached_method(env, obj, "copyTextureToTexture", native_direct_command_encoder_copy_texture_to_texture, &native_direct_method_command_encoder_copy_texture_to_texture_ref);
    native_direct_add_cached_method(env, obj, "finish", native_direct_command_encoder_finish, &native_direct_method_command_encoder_finish_ref);
    return obj;
}

napi_value create_native_direct_compute_pass_object(napi_env env, WGPUComputePassEncoder pass) {
    napi_value obj;
    napi_create_object(env, &obj);
    native_direct_set_external_prop(env, obj, DOE_DIRECT_NATIVE, pass);
    native_direct_wrap_handle_cache(env, obj, NULL, pass);
    native_direct_add_cached_method(env, obj, "setPipeline", native_direct_compute_pass_set_pipeline, &native_direct_method_compute_pass_set_pipeline_ref);
    native_direct_add_cached_method(env, obj, "setBindGroup", native_direct_compute_pass_set_bind_group, &native_direct_method_compute_pass_set_bind_group_ref);
    native_direct_add_cached_method(env, obj, "dispatchWorkgroups", native_direct_compute_pass_dispatch_workgroups, &native_direct_method_compute_pass_dispatch_workgroups_ref);
    native_direct_add_cached_method(env, obj, "dispatchWorkgroupsIndirect", native_direct_compute_pass_dispatch_workgroups_indirect, &native_direct_method_compute_pass_dispatch_workgroups_indirect_ref);
    native_direct_add_cached_method(env, obj, "end", native_direct_compute_pass_end, &native_direct_method_compute_pass_end_ref);
    /* GPUBindingCommandsMixin#setImmediates — covers both mixin and compute-pass-specific contract */
    native_direct_add_cached_method(env, obj, "setImmediates", native_direct_compute_pass_set_immediates, &native_direct_method_compute_pass_set_immediates_ref);
    native_direct_add_cached_method(env, obj, "pushDebugGroup", native_direct_compute_pass_push_debug_group, &native_direct_method_compute_pass_push_debug_group_ref);
    native_direct_add_cached_method(env, obj, "popDebugGroup", native_direct_compute_pass_pop_debug_group, &native_direct_method_compute_pass_pop_debug_group_ref);
    native_direct_add_cached_method(env, obj, "insertDebugMarker", native_direct_compute_pass_insert_debug_marker, &native_direct_method_compute_pass_insert_debug_marker_ref);
    return obj;
}

/* create_native_direct_render_pass_object: wraps a WGPURenderPassEncoder as a JS
 * object with all GPURenderPassEncoder control methods registered. */
napi_value create_native_direct_render_pass_object(napi_env env, WGPURenderPassEncoder pass) {
    napi_value obj;
    napi_create_object(env, &obj);
    native_direct_set_external_prop(env, obj, DOE_DIRECT_NATIVE, pass);
    native_direct_wrap_handle_cache(env, obj, NULL, pass);
    /* GPURenderPassEncoder#setImmediates (GPUBindingCommandsMixin) */
    native_direct_add_cached_method(env, obj, "setImmediates", native_direct_render_pass_set_immediates, &native_direct_method_render_pass_set_immediates_ref);
    /* GPURenderPassEncoder dynamic state */
    native_direct_add_cached_method(env, obj, "setViewport", native_direct_render_pass_set_viewport, &native_direct_method_render_pass_set_viewport_ref);
    native_direct_add_cached_method(env, obj, "setScissorRect", native_direct_render_pass_set_scissor_rect, &native_direct_method_render_pass_set_scissor_rect_ref);
    native_direct_add_cached_method(env, obj, "setBlendConstant", native_direct_render_pass_set_blend_constant, &native_direct_method_render_pass_set_blend_constant_ref);
    native_direct_add_cached_method(env, obj, "setStencilReference", native_direct_render_pass_set_stencil_reference, &native_direct_method_render_pass_set_stencil_reference_ref);
    native_direct_add_cached_method(env, obj, "drawIndirect", native_direct_render_pass_draw_indirect, &native_direct_method_render_pass_draw_indirect_ref);
    native_direct_add_cached_method(env, obj, "drawIndexedIndirect", native_direct_render_pass_draw_indexed_indirect, &native_direct_method_render_pass_draw_indexed_indirect_ref);
    /* GPURenderPassEncoder debug markers */
    native_direct_add_cached_method(env, obj, "pushDebugGroup", native_direct_render_pass_push_debug_group, &native_direct_method_render_pass_push_debug_group_ref);
    native_direct_add_cached_method(env, obj, "popDebugGroup", native_direct_render_pass_pop_debug_group, &native_direct_method_render_pass_pop_debug_group_ref);
    native_direct_add_cached_method(env, obj, "insertDebugMarker", native_direct_render_pass_insert_debug_marker, &native_direct_method_render_pass_insert_debug_marker_ref);
    return obj;
}

/* native_direct_create_instance — exported as "nativeDirectCreate".
 * Creates a WGPUInstance and returns a JS GPU object bound to it. */
napi_value doe_native_direct_create(napi_env env, napi_callback_info info) {
    (void)info;
    CHECK_LIB_LOADED(env);
    WGPUInstance inst = pfn_wgpuCreateInstance(NULL);
    if (!inst) NAPI_THROW(env, "wgpuCreateInstance returned NULL");
    return create_native_direct_gpu_object(env, inst);
}
