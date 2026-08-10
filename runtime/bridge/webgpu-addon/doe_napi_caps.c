#include "doe_napi_internal.h"

/* ================================================================
 * Device capabilities: limits, features
 * ================================================================ */

napi_value create_limits_object(napi_env env, const WGPULimits* limits) {
    napi_value obj;
    napi_create_object(env, &obj);

#define SET_U32(name) do { napi_value v; napi_create_uint32(env, limits->name, &v); napi_set_named_property(env, obj, #name, v); } while(0)
#define SET_U64(name) do { napi_value v; napi_create_double(env, (double)limits->name, &v); napi_set_named_property(env, obj, #name, v); } while(0)

    SET_U32(maxTextureDimension1D);
    SET_U32(maxTextureDimension2D);
    SET_U32(maxTextureDimension3D);
    SET_U32(maxTextureArrayLayers);
    SET_U32(maxBindGroups);
    SET_U32(maxBindGroupsPlusVertexBuffers);
    SET_U32(maxBindingsPerBindGroup);
    SET_U32(maxDynamicUniformBuffersPerPipelineLayout);
    SET_U32(maxDynamicStorageBuffersPerPipelineLayout);
    SET_U32(maxSampledTexturesPerShaderStage);
    SET_U32(maxSamplersPerShaderStage);
    SET_U32(maxStorageBuffersPerShaderStage);
    SET_U32(maxStorageTexturesPerShaderStage);
    SET_U32(maxUniformBuffersPerShaderStage);
    SET_U64(maxUniformBufferBindingSize);
    SET_U64(maxStorageBufferBindingSize);
    SET_U32(minUniformBufferOffsetAlignment);
    SET_U32(minStorageBufferOffsetAlignment);
    SET_U32(maxVertexBuffers);
    SET_U64(maxBufferSize);
    SET_U32(maxVertexAttributes);
    SET_U32(maxVertexBufferArrayStride);
    SET_U32(maxInterStageShaderVariables);
    SET_U32(maxColorAttachments);
    SET_U32(maxColorAttachmentBytesPerSample);
    SET_U32(maxComputeWorkgroupStorageSize);
    SET_U32(maxComputeInvocationsPerWorkgroup);
    SET_U32(maxComputeWorkgroupSizeX);
    SET_U32(maxComputeWorkgroupSizeY);
    SET_U32(maxComputeWorkgroupSizeZ);
    SET_U32(maxComputeWorkgroupsPerDimension);
    SET_U32(maxImmediateSize);

#undef SET_U32
#undef SET_U64

    napi_value max_storage_buffers_in_vertex_stage;
    napi_value max_storage_buffers_in_fragment_stage;
    napi_value max_storage_textures_in_vertex_stage;
    napi_value max_storage_textures_in_fragment_stage;
    napi_create_uint32(env, limits->maxStorageBuffersPerShaderStage, &max_storage_buffers_in_vertex_stage);
    napi_create_uint32(env, limits->maxStorageBuffersPerShaderStage, &max_storage_buffers_in_fragment_stage);
    napi_create_uint32(env, limits->maxStorageTexturesPerShaderStage, &max_storage_textures_in_vertex_stage);
    napi_create_uint32(env, limits->maxStorageTexturesPerShaderStage, &max_storage_textures_in_fragment_stage);
    napi_set_named_property(env, obj, "maxStorageBuffersInVertexStage", max_storage_buffers_in_vertex_stage);
    napi_set_named_property(env, obj, "maxStorageBuffersInFragmentStage", max_storage_buffers_in_fragment_stage);
    napi_set_named_property(env, obj, "maxStorageTexturesInVertexStage", max_storage_textures_in_vertex_stage);
    napi_set_named_property(env, obj, "maxStorageTexturesInFragmentStage", max_storage_textures_in_fragment_stage);

    return obj;
}

napi_value doe_device_get_limits(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    CHECK_LIB_LOADED(env);
    WGPUDevice device = unwrap_ptr(env, _args[0]);
    if (!device) NAPI_THROW(env, "deviceGetLimits: null device");
    uint32_t (*fn)(WGPUDevice, void*) = pfn_doeNativeDeviceGetLimits ? pfn_doeNativeDeviceGetLimits : pfn_wgpuDeviceGetLimits;
    if (!fn) {
        napi_value ret;
        napi_get_null(env, &ret);
        return ret;
    }

    WGPULimits limits;
    memset(&limits, 0, sizeof(limits));
    uint32_t status = fn(device, &limits);
    if (status != WGPU_STATUS_SUCCESS) {
        napi_value ret;
        napi_get_null(env, &ret);
        return ret;
    }

    return create_limits_object(env, &limits);
}

napi_value doe_adapter_get_limits(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    CHECK_LIB_LOADED(env);
    WGPUAdapter adapter = unwrap_ptr(env, _args[0]);
    if (!adapter) NAPI_THROW(env, "adapterGetLimits: null adapter");
    uint32_t (*fn)(WGPUAdapter, void*) = pfn_doeNativeAdapterGetLimits ? pfn_doeNativeAdapterGetLimits : pfn_wgpuAdapterGetLimits;
    if (!fn) {
        napi_value ret;
        napi_get_null(env, &ret);
        return ret;
    }

    WGPULimits limits;
    memset(&limits, 0, sizeof(limits));
    uint32_t status = fn(adapter, &limits);
    if (status != WGPU_STATUS_SUCCESS) {
        napi_value ret;
        napi_get_null(env, &ret);
        return ret;
    }

    return create_limits_object(env, &limits);
}

napi_value doe_device_has_feature(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 2);
    CHECK_LIB_LOADED(env);
    WGPUDevice device = unwrap_ptr(env, _args[0]);
    uint32_t (*fn)(WGPUDevice, uint32_t) = pfn_doeNativeDeviceHasFeature ? pfn_doeNativeDeviceHasFeature : pfn_wgpuDeviceHasFeature;
    if (!fn) {
        napi_value ret;
        napi_get_boolean(env, false, &ret);
        return ret;
    }
    uint32_t feature;
    napi_get_value_uint32(env, _args[1], &feature);
    uint32_t result = fn(device, feature);
    napi_value ret;
    napi_get_boolean(env, result != 0, &ret);
    return ret;
}

napi_value doe_adapter_has_feature(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 2);
    CHECK_LIB_LOADED(env);
    WGPUAdapter adapter = unwrap_ptr(env, _args[0]);
    uint32_t (*fn)(WGPUAdapter, uint32_t) = pfn_doeNativeAdapterHasFeature ? pfn_doeNativeAdapterHasFeature : pfn_wgpuAdapterHasFeature;
    if (!fn) {
        napi_value ret;
        napi_get_boolean(env, false, &ret);
        return ret;
    }
    uint32_t feature;
    napi_get_value_uint32(env, _args[1], &feature);
    uint32_t result = fn(adapter, feature);
    napi_value ret;
    napi_get_boolean(env, result != 0, &ret);
    return ret;
}

/* Returns the preferred swapchain format string for the bound adapter.
 * Falls back to "bgra8unorm" (Metal swapchain default) when the native
 * symbol is absent. */
napi_value doe_get_preferred_canvas_format(napi_env env, napi_callback_info info) {
    size_t argc = 0;
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, NULL, &this_arg, NULL);
    if (!pfn_doeNativeAdapterGetPreferredCanvasFormat) {
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
    napi_value result;
    napi_create_uint32(env, fmt, &result);
    return result;
}

/* ================================================================
 * Error scope
 * ================================================================ */

void pop_error_scope_callback(uint32_t error_type, WGPUStringView message, void* userdata1, void* userdata2) {
    (void)userdata2;
    DevicePopErrorScopeResult* result = (DevicePopErrorScopeResult*)userdata1;
    result->done = 1;
    result->error_type = error_type;
    copy_string_view_message(message, result->message, sizeof(result->message));
}

napi_value doe_device_push_error_scope(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 2);
    CHECK_LIB_LOADED(env);
    if (!pfn_doeNativeDevicePushErrorScope && !pfn_wgpuDevicePushErrorScope) NAPI_THROW(env, "devicePushErrorScope not available");
    WGPUDevice device = unwrap_ptr(env, _args[0]);
    if (!device) NAPI_THROW(env, "Invalid device");
    uint32_t filter = 0;
    napi_get_value_uint32(env, _args[1], &filter);
    if (pfn_doeNativeDevicePushErrorScope) {
        pfn_doeNativeDevicePushErrorScope(device, filter);
    } else {
        pfn_wgpuDevicePushErrorScope(device, filter);
    }
    return NULL;
}

napi_value doe_device_pop_error_scope(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    CHECK_LIB_LOADED(env);
    if (!pfn_doeNativeDevicePopErrorScope && !pfn_wgpuDevicePopErrorScope) NAPI_THROW(env, "devicePopErrorScope not available");
    WGPUDevice device = unwrap_ptr(env, _args[0]);
    if (!device) NAPI_THROW(env, "Invalid device");

    DevicePopErrorScopeResult result = {0};
    WGPUPopErrorScopeCallbackInfo2 cb_info = {
        .next_in_chain = NULL,
        .mode = WGPU_CALLBACK_MODE_ALLOW_PROCESS_EVENTS,
        .callback = pop_error_scope_callback,
        .userdata1 = &result,
        .userdata2 = NULL,
    };
    if (pfn_wgpuDevicePopErrorScope) {
        pfn_wgpuDevicePopErrorScope(device, cb_info);
    } else {
        pfn_doeNativeDevicePopErrorScope(device, cb_info);
    }
    if (!result.done) {
        NAPI_THROW(env, "popErrorScope: no active error scope");
    }
    if (result.error_type == 0x00000001) {
        return NULL;
    }

    napi_value out, type_val, message_val;
    napi_create_object(env, &out);
    napi_create_string_utf8(env, error_type_string(result.error_type), NAPI_AUTO_LENGTH, &type_val);
    napi_create_string_utf8(env, result.message, NAPI_AUTO_LENGTH, &message_val);
    napi_set_named_property(env, out, "type", type_val);
    napi_set_named_property(env, out, "message", message_val);
    return out;
}

napi_value doe_device_set_uncaptured_error_callback(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 2);
    CHECK_LIB_LOADED(env);
    if (!pfn_doeNativeDeviceSetUncapturedErrorCallback) {
        napi_value result;
        napi_get_boolean(env, false, &result);
        return result;
    }
    WGPUDevice device = unwrap_ptr(env, _args[0]);
    if (!device) NAPI_THROW(env, "Invalid device");

    DeviceCallbackBinding* old = binding_take(&g_uncaptured_bindings, device);
    if (old) {
        pfn_doeNativeDeviceSetUncapturedErrorCallback(device, NULL, NULL, NULL);
        release_binding(old);
    }

    napi_valuetype cb_type;
    napi_typeof(env, _args[1], &cb_type);
    if (cb_type == napi_null || cb_type == napi_undefined) {
        return NULL;
    }
    if (cb_type != napi_function) {
        NAPI_THROW(env, "deviceSetUncapturedErrorCallback requires a function or null");
    }

    DeviceCallbackBinding* binding = (DeviceCallbackBinding*)calloc(1, sizeof(DeviceCallbackBinding));
    if (!binding) NAPI_THROW(env, "Out of memory");
    binding->device = device;
    napi_value resource_name;
    napi_create_string_utf8(env, "doeDeviceUncapturedError", NAPI_AUTO_LENGTH, &resource_name);
    if (napi_create_threadsafe_function(
            env, _args[1], NULL, resource_name, 0, 1,
            binding, binding_finalize, NULL, js_call_uncaptured_error, &binding->tsfn) != napi_ok) {
        free(binding);
        NAPI_THROW(env, "Failed to create uncaptured-error callback bridge");
    }
    napi_unref_threadsafe_function(env, binding->tsfn);
    binding_insert(&g_uncaptured_bindings, binding);
    pfn_doeNativeDeviceSetUncapturedErrorCallback(device, uncaptured_error_native_callback, binding, NULL);
    napi_value result;
    napi_get_boolean(env, true, &result);
    return result;
}

napi_value doe_device_register_lost_callback(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 2);
    CHECK_LIB_LOADED(env);
    if (!pfn_doeNativeDeviceRegisterLostCallback) {
        napi_value result;
        napi_get_boolean(env, false, &result);
        return result;
    }
    WGPUDevice device = unwrap_ptr(env, _args[0]);
    if (!device) NAPI_THROW(env, "Invalid device");

    DeviceCallbackBinding* old = binding_take(&g_lost_bindings, device);
    if (old) {
        release_binding(old);
    }

    napi_valuetype cb_type;
    napi_typeof(env, _args[1], &cb_type);
    if (cb_type != napi_function) {
        NAPI_THROW(env, "deviceRegisterLostCallback requires a function");
    }

    DeviceCallbackBinding* binding = (DeviceCallbackBinding*)calloc(1, sizeof(DeviceCallbackBinding));
    if (!binding) NAPI_THROW(env, "Out of memory");
    binding->device = device;
    napi_value resource_name;
    napi_create_string_utf8(env, "doeDeviceLost", NAPI_AUTO_LENGTH, &resource_name);
    if (napi_create_threadsafe_function(
            env, _args[1], NULL, resource_name, 0, 1,
            binding, binding_finalize, NULL, js_call_lost_callback, &binding->tsfn) != napi_ok) {
        free(binding);
        NAPI_THROW(env, "Failed to create device-lost callback bridge");
    }
    napi_unref_threadsafe_function(env, binding->tsfn);
    binding_insert(&g_lost_bindings, binding);
    pfn_doeNativeDeviceRegisterLostCallback(device, lost_native_callback, binding);
    napi_value result;
    napi_get_boolean(env, true, &result);
    return result;
}

/* ================================================================
 * Adapter info and shader module compilation info
 * ================================================================ */

static size_t adapter_info_string_len(WGPUStringView view) {
    return view.length == WGPU_STRLEN ? NAPI_AUTO_LENGTH : view.length;
}

static void set_adapter_info_string_prop(napi_env env, napi_value obj, const char* name, WGPUStringView view) {
    napi_value value;
    const char* data = view.data ? view.data : "";
    napi_create_string_utf8(env, data, adapter_info_string_len(view), &value);
    napi_set_named_property(env, obj, name, value);
}

napi_value doe_adapter_get_info(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    CHECK_LIB_LOADED(env);
    void* adapter = unwrap_ptr(env, _args[0]);
    if (!adapter) NAPI_THROW(env, "Invalid adapter");

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

    const char* vendor = "";
    const char* arch = "";
    const char* device = "";
    const char* desc = "";
    char* block = NULL;

    const bool tried_native_adapter_info =
        pfn_doeNativeAdapterGetInfo && pfn_doeNativeAdapterFreeInfo;

    if (tried_native_adapter_info) {
        pfn_doeNativeAdapterGetInfo(adapter, &vendor, &arch, &device, &desc, &block);
        if (!vendor) vendor = "";
        if (!arch) arch = "";
        if (!device) device = "";
        if (!desc) desc = "";
    }

    if (block && pfn_doeNativeAdapterFreeInfo) {
        napi_create_string_utf8(env, vendor, NAPI_AUTO_LENGTH, &v_vendor);
        napi_create_string_utf8(env, arch, NAPI_AUTO_LENGTH, &v_arch);
        napi_create_string_utf8(env, device, NAPI_AUTO_LENGTH, &v_device);
        napi_create_string_utf8(env, desc, NAPI_AUTO_LENGTH, &v_desc);
        napi_get_boolean(env, false, &v_is_fallback);
        napi_create_uint32(env, 32, &v_sg_min);
        napi_create_uint32(env, 32, &v_sg_max);
        napi_set_named_property(env, obj, "vendor", v_vendor);
        napi_set_named_property(env, obj, "architecture", v_arch);
        napi_set_named_property(env, obj, "device", v_device);
        napi_set_named_property(env, obj, "description", v_desc);
        napi_set_named_property(env, obj, "isFallbackAdapter", v_is_fallback);
        napi_set_named_property(env, obj, "subgroupMinSize", v_sg_min);
        napi_set_named_property(env, obj, "subgroupMaxSize", v_sg_max);
        if (pfn_doeNativeAdapterGetPciIdentity) {
            uint32_t vendor_id = 0;
            uint32_t device_id = 0;
            uint32_t driver_version = 0;
            napi_value v_vendor_id, v_device_id, v_driver_version;
            pfn_doeNativeAdapterGetPciIdentity(adapter, &vendor_id, &device_id, &driver_version);
            napi_create_uint32(env, vendor_id, &v_vendor_id);
            napi_create_uint32(env, device_id, &v_device_id);
            napi_create_uint32(env, driver_version, &v_driver_version);
            napi_set_named_property(env, obj, "vendorID", v_vendor_id);
            napi_set_named_property(env, obj, "deviceID", v_device_id);
            napi_set_named_property(env, obj, "driverVersion", v_driver_version);
        }
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
        set_adapter_info_string_prop(env, obj, "vendor", info_view.vendor);
        set_adapter_info_string_prop(env, obj, "architecture", info_view.architecture);
        set_adapter_info_string_prop(env, obj, "device", info_view.device);
        set_adapter_info_string_prop(env, obj, "description", info_view.description);
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

/* doe_shader_module_get_compilation_info moved to doe_napi_shader.c */

/* ================================================================
 * Sampler
 * ================================================================ */

napi_value doe_create_sampler(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 2);
    CHECK_LIB_LOADED(env);
    WGPUDevice device = unwrap_ptr(env, _args[0]);
    if (!device) NAPI_THROW(env, "Invalid device");

    WGPUSamplerDescriptor desc;
    memset(&desc, 0, sizeof(desc));
    desc.lodMaxClamp = 32.0f;
    desc.maxAnisotropy = 1;

    char* label_str = NULL;
    size_t label_len = 0;
    napi_valuetype desc_type;
    napi_typeof(env, _args[1], &desc_type);
    if (desc_type == napi_object) {
        if (has_prop(env, _args[1], "label"))
            label_str = dup_string_value(env, get_prop(env, _args[1], "label"), &label_len);
        if (has_prop(env, _args[1], "magFilter"))
            desc.magFilter = filter_mode_from_string(env, get_prop(env, _args[1], "magFilter"));
        if (has_prop(env, _args[1], "minFilter"))
            desc.minFilter = filter_mode_from_string(env, get_prop(env, _args[1], "minFilter"));
        if (has_prop(env, _args[1], "mipmapFilter"))
            desc.mipmapFilter = filter_mode_from_string(env, get_prop(env, _args[1], "mipmapFilter"));
        if (has_prop(env, _args[1], "addressModeU"))
            desc.addressModeU = address_mode_from_string(env, get_prop(env, _args[1], "addressModeU"));
        if (has_prop(env, _args[1], "addressModeV"))
            desc.addressModeV = address_mode_from_string(env, get_prop(env, _args[1], "addressModeV"));
        if (has_prop(env, _args[1], "addressModeW"))
            desc.addressModeW = address_mode_from_string(env, get_prop(env, _args[1], "addressModeW"));
        if (has_prop(env, _args[1], "lodMinClamp"))
            desc.lodMinClamp = (float)get_double_prop(env, _args[1], "lodMinClamp");
        if (has_prop(env, _args[1], "lodMaxClamp"))
            desc.lodMaxClamp = (float)get_double_prop(env, _args[1], "lodMaxClamp");
        if (has_prop(env, _args[1], "compare"))
            desc.compare = compare_func_from_value(env, get_prop(env, _args[1], "compare"));
        if (has_prop(env, _args[1], "maxAnisotropy"))
            desc.maxAnisotropy = (uint16_t)get_uint32_prop(env, _args[1], "maxAnisotropy");
    }
    desc.label.data = label_str;
    desc.label.length = label_str ? label_len : 0;

    WGPUSampler sampler = pfn_wgpuDeviceCreateSampler(device, &desc);
    free(label_str);
    if (!sampler) NAPI_THROW(env, "createSampler failed");
    return wrap_ptr(env, sampler);
}

napi_value doe_sampler_release(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    void* p = unwrap_ptr(env, _args[0]);
    if (p) pfn_wgpuSamplerRelease(p);
    return NULL;
}

/* ================================================================
 * Texture and texture view
 * ================================================================ */

napi_value doe_create_texture(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 2);
    CHECK_LIB_LOADED(env);
    WGPUDevice device = unwrap_ptr(env, _args[0]);
    if (!device) NAPI_THROW(env, "Invalid device");

    char* label_str = NULL;
    size_t label_len = 0;
    if (has_prop(env, _args[1], "label"))
        label_str = dup_string_value(env, get_prop(env, _args[1], "label"), &label_len);

    WGPUTextureDescriptor desc;
    memset(&desc, 0, sizeof(desc));
    desc.label.data = label_str;
    desc.label.length = label_str ? label_len : 0;
    desc.format = texture_format_from_string(env, get_prop(env, _args[1], "format"));
    desc.size.width = get_uint32_prop(env, _args[1], "width");
    desc.size.height = get_uint32_prop(env, _args[1], "height");
    desc.size.depthOrArrayLayers = 1;
    if (has_prop(env, _args[1], "depthOrArrayLayers"))
        desc.size.depthOrArrayLayers = get_uint32_prop(env, _args[1], "depthOrArrayLayers");
    desc.usage = (uint64_t)get_int64_prop(env, _args[1], "usage");
    desc.mipLevelCount = 1;
    if (has_prop(env, _args[1], "mipLevelCount"))
        desc.mipLevelCount = get_uint32_prop(env, _args[1], "mipLevelCount");
    desc.sampleCount = 1;
    if (has_prop(env, _args[1], "sampleCount"))
        desc.sampleCount = get_uint32_prop(env, _args[1], "sampleCount");
    desc.dimension = 2; /* WGPUTextureDimension_2D */
    if (has_prop(env, _args[1], "dimension"))
        desc.dimension = get_uint32_prop(env, _args[1], "dimension");

    uint32_t* view_formats = NULL;
    uint32_t view_format_count = 0;
    if (has_prop(env, _args[1], "viewFormats")) {
        napi_value vf_arr = get_prop(env, _args[1], "viewFormats");
        bool vf_is_array = false;
        napi_is_array(env, vf_arr, &vf_is_array);
        if (vf_is_array) {
            napi_get_array_length(env, vf_arr, &view_format_count);
            if (view_format_count > 0) {
                view_formats = (uint32_t*)calloc(view_format_count, sizeof(uint32_t));
                for (uint32_t i = 0; i < view_format_count; i++) {
                    napi_value elem;
                    napi_get_element(env, vf_arr, i, &elem);
                    view_formats[i] = texture_format_from_string(env, elem);
                }
            }
        }
    }
    desc.viewFormatCount = (size_t)view_format_count;
    desc.viewFormats = view_formats;

    /* textureBindingViewDimension: string → enum, defaults to matching dimension */
    if (has_prop(env, _args[1], "textureBindingViewDimension"))
        desc.textureBindingViewDimension = texture_view_dimension_from_string(
            env, get_prop(env, _args[1], "textureBindingViewDimension"));

    WGPUTexture tex = pfn_wgpuDeviceCreateTexture(device, &desc);
    free(view_formats);
    free(label_str);
    if (!tex) NAPI_THROW(env, "createTexture failed");
    return wrap_ptr(env, tex);
}

napi_value doe_texture_create_view(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    CHECK_LIB_LOADED(env);
    if (argc < 1) NAPI_THROW(env, "textureCreateView requires texture");
    WGPUTexture tex = unwrap_ptr(env, argv[0]);
    if (!tex) NAPI_THROW(env, "Invalid texture");

    /* Build a view descriptor when one is provided (argv[1] or argv[2]). */
    napi_value desc_arg = NULL;
    for (size_t i = 1; i < argc; i++) {
        napi_valuetype vt; napi_typeof(env, argv[i], &vt);
        if (vt == napi_object) { desc_arg = argv[i]; break; }
    }

    WGPUTextureViewDescriptor view_desc;
    memset(&view_desc, 0, sizeof(view_desc));
    const WGPUTextureViewDescriptor* view_desc_ptr = NULL;
    if (desc_arg) {
        if (has_prop(env, desc_arg, "format"))
            view_desc.format = texture_format_from_string(env, get_prop(env, desc_arg, "format"));
        if (has_prop(env, desc_arg, "dimension"))
            view_desc.dimension = get_uint32_prop(env, desc_arg, "dimension");
        if (has_prop(env, desc_arg, "baseMipLevel"))
            view_desc.baseMipLevel = get_uint32_prop(env, desc_arg, "baseMipLevel");
        if (has_prop(env, desc_arg, "mipLevelCount"))
            view_desc.mipLevelCount = get_uint32_prop(env, desc_arg, "mipLevelCount");
        if (has_prop(env, desc_arg, "baseArrayLayer"))
            view_desc.baseArrayLayer = get_uint32_prop(env, desc_arg, "baseArrayLayer");
        if (has_prop(env, desc_arg, "arrayLayerCount"))
            view_desc.arrayLayerCount = get_uint32_prop(env, desc_arg, "arrayLayerCount");
        if (has_prop(env, desc_arg, "aspect"))
            view_desc.aspect = get_uint32_prop(env, desc_arg, "aspect");
        if (has_prop(env, desc_arg, "usage"))
            view_desc.usage = (uint64_t)get_int64_prop(env, desc_arg, "usage");
        if (has_prop(env, desc_arg, "swizzle") && prop_type(env, desc_arg, "swizzle") == napi_string) {
            char swizzle[8] = {0};
            size_t swizzle_len = 0;
            napi_get_value_string_utf8(env, get_prop(env, desc_arg, "swizzle"), swizzle, sizeof(swizzle), &swizzle_len);
            if (swizzle_len == 4) {
                view_desc.swizzleR = (swizzle[0] == '0') ? 1 : (swizzle[0] == '1') ? 2 : (swizzle[0] == 'r') ? 3 : (swizzle[0] == 'g') ? 4 : (swizzle[0] == 'b') ? 5 : (swizzle[0] == 'a') ? 6 : 0;
                view_desc.swizzleG = (swizzle[1] == '0') ? 1 : (swizzle[1] == '1') ? 2 : (swizzle[1] == 'r') ? 3 : (swizzle[1] == 'g') ? 4 : (swizzle[1] == 'b') ? 5 : (swizzle[1] == 'a') ? 6 : 0;
                view_desc.swizzleB = (swizzle[2] == '0') ? 1 : (swizzle[2] == '1') ? 2 : (swizzle[2] == 'r') ? 3 : (swizzle[2] == 'g') ? 4 : (swizzle[2] == 'b') ? 5 : (swizzle[2] == 'a') ? 6 : 0;
                view_desc.swizzleA = (swizzle[3] == '0') ? 1 : (swizzle[3] == '1') ? 2 : (swizzle[3] == 'r') ? 3 : (swizzle[3] == 'g') ? 4 : (swizzle[3] == 'b') ? 5 : (swizzle[3] == 'a') ? 6 : 0;
            }
        }
        view_desc_ptr = &view_desc;
    }

    WGPUTextureView view = pfn_wgpuTextureCreateView(tex, view_desc_ptr);
    if (!view) NAPI_THROW(env, "textureCreateView failed");
    return wrap_ptr(env, view);
}

napi_value doe_texture_release(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    void* p = unwrap_ptr(env, _args[0]);
    if (p) pfn_wgpuTextureRelease(p);
    return NULL;
}

napi_value doe_texture_view_release(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    void* p = unwrap_ptr(env, _args[0]);
    if (p) pfn_wgpuTextureViewRelease(p);
    return NULL;
}

/* ================================================================
 * QuerySet (timestamp query)
 * ================================================================ */

napi_value doe_device_create_query_set(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 3);
    CHECK_LIB_LOADED(env);
    if (!pfn_doeNativeDeviceCreateQuerySet) NAPI_THROW(env, "doeNativeDeviceCreateQuerySet not available");
    WGPUDevice device = unwrap_ptr(env, _args[0]);
    if (!device) NAPI_THROW(env, "Invalid device");
    uint32_t query_type = 0;
    napi_get_value_uint32(env, _args[1], &query_type);
    uint32_t count = 0;
    napi_get_value_uint32(env, _args[2], &count);
    WGPUQuerySet qs = pfn_doeNativeDeviceCreateQuerySet(device, query_type, count);
    if (!qs) NAPI_THROW(env, "timestamp query sets are not supported on this backend/device");
    return wrap_ptr(env, qs);
}

napi_value doe_command_encoder_write_timestamp(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 3);
    CHECK_LIB_LOADED(env);
    if (!pfn_doeNativeCommandEncoderWriteTimestamp) NAPI_THROW(env, "doeNativeCommandEncoderWriteTimestamp not available");
    WGPUCommandEncoder enc = unwrap_ptr(env, _args[0]);
    WGPUQuerySet qs = unwrap_ptr(env, _args[1]);
    uint32_t query_index = 0;
    napi_get_value_uint32(env, _args[2], &query_index);
    pfn_doeNativeCommandEncoderWriteTimestamp(enc, qs, query_index);
    return NULL;
}

napi_value doe_command_encoder_resolve_query_set(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 6);
    CHECK_LIB_LOADED(env);
    if (!pfn_doeNativeCommandEncoderResolveQuerySet) NAPI_THROW(env, "doeNativeCommandEncoderResolveQuerySet not available");
    WGPUCommandEncoder enc = unwrap_ptr(env, _args[0]);
    WGPUQuerySet qs = unwrap_ptr(env, _args[1]);
    uint32_t first_query = 0;
    napi_get_value_uint32(env, _args[2], &first_query);
    uint32_t query_count = 0;
    napi_get_value_uint32(env, _args[3], &query_count);
    WGPUBuffer dst = unwrap_ptr(env, _args[4]);
    int64_t dst_offset = 0;
    napi_get_value_int64(env, _args[5], &dst_offset);
    pfn_doeNativeCommandEncoderResolveQuerySet(enc, qs, first_query, query_count, dst, (uint64_t)dst_offset);
    return NULL;
}

napi_value doe_query_set_destroy(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    if (!pfn_doeNativeQuerySetDestroy) return NULL;
    WGPUQuerySet qs = unwrap_ptr(env, _args[0]);
    if (qs) pfn_doeNativeQuerySetDestroy(qs);
    return NULL;
}

/* ================================================================
 * Device label (stub — label tracking not implemented yet)
 * ================================================================ */

napi_value doe_device_get_label(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    (void)_args;
    napi_value result;
    napi_create_string_utf8(env, "", 0, &result);
    return result;
}

napi_value doe_device_set_label(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 2);
    (void)_args;
    return NULL;
}

napi_value doe_object_set_label(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 2);
    void* handle = unwrap_ptr(env, _args[0]);
    if (!handle || !pfn_doeNativeObjectSetLabel) return NULL;
    size_t label_len = 0;
    char* label = dup_string_value(env, _args[1], &label_len);
    pfn_doeNativeObjectSetLabel(handle, (const uint8_t*)label, label_len);
    free(label);
    return NULL;
}

/* ================================================================
 * Timeout
 * ================================================================ */

napi_value doe_set_timeout_ms(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    uint32_t timeout_ms = 0;
    napi_get_value_uint32(env, _args[0], &timeout_ms);
    g_timeout_ns = (uint64_t)timeout_ms * 1000000ULL;
    return NULL;
}

napi_value doe_package_pipeline_cache_flush(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    if (napi_get_cb_info(env, info, &argc, args, NULL, NULL) != napi_ok) {
        NAPI_THROW(env, "napi_get_cb_info failed");
    }
    CHECK_LIB_LOADED(env);
    if (argc >= 1 && pfn_doeNativeQueuePipelineCacheFlush) {
        WGPUQueue queue = unwrap_ptr(env, args[0]);
        if (queue) {
            pfn_doeNativeQueuePipelineCacheFlush(queue);
        }
    }
    if (pfn_doeNativePackagePipelineCacheFlush) {
        pfn_doeNativePackagePipelineCacheFlush();
    }
    return NULL;
}
