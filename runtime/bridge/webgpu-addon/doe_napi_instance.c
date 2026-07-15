#include "doe_napi_internal.h"

/* ================================================================
 * Instance
 * ================================================================ */

napi_value doe_create_instance(napi_env env, napi_callback_info info) {
    (void)info;
    CHECK_LIB_LOADED(env);
    /* Doe ignores the descriptor — pass NULL for clarity. */
    WGPUInstance inst = pfn_wgpuCreateInstance(NULL);
    if (!inst) NAPI_THROW(env, "wgpuCreateInstance returned NULL");
    return wrap_ptr(env, inst);
}

napi_value doe_instance_release(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    void* inst = unwrap_ptr(env, _args[0]);
    if (inst) pfn_wgpuInstanceRelease(inst);
    return NULL;
}

/* ================================================================
 * Adapter (synchronous requestAdapter via callback + processEvents)
 * ================================================================ */

/* Power preference string values match WGPUPowerPreference enum:
 * 0 = undefined, 1 = low-power, 2 = high-performance */
#define WGPU_POWER_PREFERENCE_LOW_POWER      1
#define WGPU_POWER_PREFERENCE_HIGH_PERFORMANCE 2
#define WGPU_FEATURE_LEVEL_COMPATIBILITY 1
#define WGPU_FEATURE_LEVEL_CORE          2
napi_value doe_request_adapter(napi_env env, napi_callback_info info) {
    /* Accept 1 or 2 args: (instance[, options]) */
    size_t actual_argc = 2;
    napi_value args[2];
    if (napi_get_cb_info(env, info, &actual_argc, args, NULL, NULL) != napi_ok)
        NAPI_THROW(env, "napi_get_cb_info failed");
    CHECK_LIB_LOADED(env);
    WGPUInstance inst = unwrap_ptr(env, args[0]);
    if (!inst) NAPI_THROW(env, "Invalid instance");

    WGPURequestAdapterOptions opts;
    memset(&opts, 0, sizeof(opts));
    const WGPURequestAdapterOptions* opts_ptr = NULL;

    if (actual_argc >= 2) {
        napi_valuetype vt = napi_undefined;
        napi_typeof(env, args[1], &vt);
        if (vt == napi_object) {
            /* featureLevel */
            napi_valuetype feature_level_type = napi_undefined;
            napi_value feature_level_val;
            if (napi_get_named_property(env, args[1], "featureLevel", &feature_level_val) == napi_ok) {
                napi_typeof(env, feature_level_val, &feature_level_type);
            }
            if (feature_level_type == napi_string) {
                char feature_level_str[32];
                size_t feature_level_len = 0;
                napi_get_value_string_utf8(env, feature_level_val, feature_level_str, sizeof(feature_level_str), &feature_level_len);
                if (strcmp(feature_level_str, "compatibility") == 0) {
                    opts.featureLevel = WGPU_FEATURE_LEVEL_COMPATIBILITY;
                } else if (strcmp(feature_level_str, "core") == 0) {
                    opts.featureLevel = WGPU_FEATURE_LEVEL_CORE;
                }
            }
            /* powerPreference */
            napi_valuetype pp_type = napi_undefined;
            napi_value pp_val;
            if (napi_get_named_property(env, args[1], "powerPreference", &pp_val) == napi_ok) {
                napi_typeof(env, pp_val, &pp_type);
            }
            if (pp_type == napi_string) {
                char pp_str[32];
                size_t pp_len = 0;
                napi_get_value_string_utf8(env, pp_val, pp_str, sizeof(pp_str), &pp_len);
                if (strcmp(pp_str, "low-power") == 0) {
                    opts.powerPreference = WGPU_POWER_PREFERENCE_LOW_POWER;
                } else if (strcmp(pp_str, "high-performance") == 0) {
                    opts.powerPreference = WGPU_POWER_PREFERENCE_HIGH_PERFORMANCE;
                }
            }
            /* featureLevel */
            napi_value fl_val;
            napi_valuetype fl_type = napi_undefined;
            if (napi_get_named_property(env, args[1], "featureLevel", &fl_val) == napi_ok) {
                napi_typeof(env, fl_val, &fl_type);
            }
            if (fl_type == napi_string) {
                char fl_str[32];
                size_t fl_len = 0;
                napi_get_value_string_utf8(env, fl_val, fl_str, sizeof(fl_str), &fl_len);
                if (strcmp(fl_str, "compatibility") == 0) {
                    opts.featureLevel = WGPU_FEATURE_LEVEL_COMPATIBILITY;
                } else if (strcmp(fl_str, "core") == 0) {
                    opts.featureLevel = WGPU_FEATURE_LEVEL_CORE;
                }
            }
            /* forceFallbackAdapter */
            napi_value ffa_val;
            napi_valuetype ffa_type = napi_undefined;
            if (napi_get_named_property(env, args[1], "forceFallbackAdapter", &ffa_val) == napi_ok) {
                napi_typeof(env, ffa_val, &ffa_type);
            }
            if (ffa_type == napi_boolean) {
                bool ffa = false;
                napi_get_value_bool(env, ffa_val, &ffa);
                opts.forceFallbackAdapter = ffa ? 1 : 0;
            }
            opts_ptr = &opts;
        }
    }

    AdapterRequestResult result = {0};
    WGPUFuture future;
    if (pfn_doeRequestAdapterFlat) {
        future = pfn_doeRequestAdapterFlat(
            inst, opts_ptr, WGPU_CALLBACK_MODE_ALLOW_PROCESS_EVENTS, adapter_callback, &result, NULL);
    } else {
        const WGPURequestAdapterCallbackInfo callback_info = {
            .nextInChain = NULL,
            .mode = WGPU_CALLBACK_MODE_ALLOW_PROCESS_EVENTS,
            .callback = adapter_callback,
            .userdata1 = &result,
            .userdata2 = NULL,
        };
        future = pfn_wgpuInstanceRequestAdapter(inst, opts_ptr, callback_info);
    }
    if (future.id == 0) NAPI_THROW(env, "requestAdapter future unavailable");
    if (!process_events_until(inst, &result.done, current_timeout_ns()))
        return throw_status_error(env, "DOE_REQUEST_ADAPTER_TIMEOUT", "requestAdapter timed out", result.status, result.message);
    if (result.status != WGPU_REQUEST_STATUS_SUCCESS || !result.adapter)
        return throw_status_error(env, "DOE_REQUEST_ADAPTER_ERROR", "requestAdapter failed", result.status, result.message);

    return wrap_ptr(env, result.adapter);
}

napi_value doe_adapter_release(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    void* adapter = unwrap_ptr(env, _args[0]);
    if (adapter) pfn_wgpuAdapterRelease(adapter);
    return NULL;
}

/* ================================================================
 * Device (synchronous requestDevice via callback + processEvents)
 * ================================================================ */

static bool doe_feature_name_from_string(const char* feature, uint32_t* out_feature) {
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

static bool doe_read_u32_prop(napi_env env, napi_value obj, const char* key, uint32_t* out) {
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

static bool doe_read_u64_prop(napi_env env, napi_value obj, const char* key, uint64_t* out) {
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

static bool doe_parse_required_limits(napi_env env, napi_value limits_value, WGPULimits* limits) {
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
    if (!doe_read_u32_prop(env, limits_value, "maxTextureDimension1D", &limits->maxTextureDimension1D)) return false;
    if (!doe_read_u32_prop(env, limits_value, "maxTextureDimension2D", &limits->maxTextureDimension2D)) return false;
    if (!doe_read_u32_prop(env, limits_value, "maxTextureDimension3D", &limits->maxTextureDimension3D)) return false;
    if (!doe_read_u32_prop(env, limits_value, "maxTextureArrayLayers", &limits->maxTextureArrayLayers)) return false;
    if (!doe_read_u32_prop(env, limits_value, "maxBindGroups", &limits->maxBindGroups)) return false;
    if (!doe_read_u32_prop(env, limits_value, "maxBindGroupsPlusVertexBuffers", &limits->maxBindGroupsPlusVertexBuffers)) return false;
    if (!doe_read_u32_prop(env, limits_value, "maxBindingsPerBindGroup", &limits->maxBindingsPerBindGroup)) return false;
    if (!doe_read_u32_prop(env, limits_value, "maxDynamicUniformBuffersPerPipelineLayout", &limits->maxDynamicUniformBuffersPerPipelineLayout)) return false;
    if (!doe_read_u32_prop(env, limits_value, "maxDynamicStorageBuffersPerPipelineLayout", &limits->maxDynamicStorageBuffersPerPipelineLayout)) return false;
    if (!doe_read_u32_prop(env, limits_value, "maxSampledTexturesPerShaderStage", &limits->maxSampledTexturesPerShaderStage)) return false;
    if (!doe_read_u32_prop(env, limits_value, "maxSamplersPerShaderStage", &limits->maxSamplersPerShaderStage)) return false;
    if (!doe_read_u32_prop(env, limits_value, "maxStorageBuffersPerShaderStage", &limits->maxStorageBuffersPerShaderStage)) return false;
    if (!doe_read_u32_prop(env, limits_value, "maxStorageTexturesPerShaderStage", &limits->maxStorageTexturesPerShaderStage)) return false;
    if (!doe_read_u32_prop(env, limits_value, "maxUniformBuffersPerShaderStage", &limits->maxUniformBuffersPerShaderStage)) return false;
    if (!doe_read_u64_prop(env, limits_value, "maxUniformBufferBindingSize", &limits->maxUniformBufferBindingSize)) return false;
    if (!doe_read_u64_prop(env, limits_value, "maxStorageBufferBindingSize", &limits->maxStorageBufferBindingSize)) return false;
    if (!doe_read_u32_prop(env, limits_value, "minUniformBufferOffsetAlignment", &limits->minUniformBufferOffsetAlignment)) return false;
    if (!doe_read_u32_prop(env, limits_value, "minStorageBufferOffsetAlignment", &limits->minStorageBufferOffsetAlignment)) return false;
    if (!doe_read_u32_prop(env, limits_value, "maxVertexBuffers", &limits->maxVertexBuffers)) return false;
    if (!doe_read_u64_prop(env, limits_value, "maxBufferSize", &limits->maxBufferSize)) return false;
    if (!doe_read_u32_prop(env, limits_value, "maxVertexAttributes", &limits->maxVertexAttributes)) return false;
    if (!doe_read_u32_prop(env, limits_value, "maxVertexBufferArrayStride", &limits->maxVertexBufferArrayStride)) return false;
    if (!doe_read_u32_prop(env, limits_value, "maxInterStageShaderVariables", &limits->maxInterStageShaderVariables)) return false;
    if (!doe_read_u32_prop(env, limits_value, "maxColorAttachments", &limits->maxColorAttachments)) return false;
    if (!doe_read_u32_prop(env, limits_value, "maxColorAttachmentBytesPerSample", &limits->maxColorAttachmentBytesPerSample)) return false;
    if (!doe_read_u32_prop(env, limits_value, "maxComputeWorkgroupStorageSize", &limits->maxComputeWorkgroupStorageSize)) return false;
    if (!doe_read_u32_prop(env, limits_value, "maxComputeInvocationsPerWorkgroup", &limits->maxComputeInvocationsPerWorkgroup)) return false;
    if (!doe_read_u32_prop(env, limits_value, "maxComputeWorkgroupSizeX", &limits->maxComputeWorkgroupSizeX)) return false;
    if (!doe_read_u32_prop(env, limits_value, "maxComputeWorkgroupSizeY", &limits->maxComputeWorkgroupSizeY)) return false;
    if (!doe_read_u32_prop(env, limits_value, "maxComputeWorkgroupSizeZ", &limits->maxComputeWorkgroupSizeZ)) return false;
    if (!doe_read_u32_prop(env, limits_value, "maxComputeWorkgroupsPerDimension", &limits->maxComputeWorkgroupsPerDimension)) return false;
    if (!doe_read_u32_prop(env, limits_value, "maxImmediateSize", &limits->maxImmediateSize)) return false;
    return true;
}

static bool doe_parse_feature_array(napi_env env, napi_value features_value, WGPUFeatureName** out_features, size_t* out_count) {
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
        if (!doe_feature_name_from_string(feature_name, &feature_value)) {
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

static bool doe_parse_queue_label(napi_env env, napi_value queue_value, WGPUStringView* out_label) {
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

static bool doe_parse_device_descriptor(
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
        if (!doe_parse_feature_array(env, features_value, out_required_features, &out_desc->requiredFeatureCount)) {
            return false;
        }
        out_desc->requiredFeatures = out_required_features ? *out_required_features : NULL;
    }

#ifdef _WIN32
    napi_value limits_value;
    if (napi_get_named_property(env, descriptor_value, "requiredLimits", &limits_value) == napi_ok) {
        if (!doe_parse_required_limits(env, limits_value, out_required_limits)) {
            return false;
        }
        out_desc->requiredLimits = out_required_limits;
    }
#endif

    napi_value default_queue_value;
    if (napi_get_named_property(env, descriptor_value, "defaultQueue", &default_queue_value) == napi_ok) {
        if (!doe_parse_queue_label(env, default_queue_value, &out_desc->defaultQueue.label)) {
            return false;
        }
    }

    return true;
}

napi_value doe_request_device(napi_env env, napi_callback_info info) {
    CHECK_LIB_LOADED(env);
    size_t actual_argc = 3;
    napi_value args[3];
    if (napi_get_cb_info(env, info, &actual_argc, args, NULL, NULL) != napi_ok)
        NAPI_THROW(env, "napi_get_cb_info failed");
    if (actual_argc < 2) NAPI_THROW(env, "requestDevice requires instance and adapter");
    WGPUInstance inst = unwrap_ptr(env, args[0]);
    WGPUAdapter adapter = unwrap_ptr(env, args[1]);
    if (!inst || !adapter) NAPI_THROW(env, "Invalid instance or adapter");

    WGPUDeviceDescriptor descriptor = {0};
    WGPUFeatureName* required_features = NULL;
    WGPULimits required_limits = {0};
    const WGPUDeviceDescriptor* descriptor_ptr = NULL;
    if (actual_argc >= 3) {
        napi_valuetype vt = napi_undefined;
        if (napi_typeof(env, args[2], &vt) == napi_ok && vt == napi_object) {
            if (!doe_parse_device_descriptor(env, args[2], &descriptor, &required_features, &required_limits)) {
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
    WGPUFuture future;
    if (pfn_doeRequestDeviceFlat) {
        future = pfn_doeRequestDeviceFlat(
            adapter,
            descriptor_ptr,
            WGPU_CALLBACK_MODE_ALLOW_PROCESS_EVENTS,
            device_callback,
            &result,
            NULL);
    } else {
        future = pfn_doeNativeAdapterRequestDevice
            ? pfn_doeNativeAdapterRequestDevice(adapter, descriptor_ptr, callback_info)
            : pfn_wgpuAdapterRequestDevice(adapter, descriptor_ptr, callback_info);
    }
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
        return throw_status_error(env, "DOE_REQUEST_DEVICE_TIMEOUT", "requestDevice timed out", result.status, result.message);
    }
    if (result.status != WGPU_REQUEST_STATUS_SUCCESS || !result.device) {
        free(required_features);
        if (descriptor.label.data) free((void*)descriptor.label.data);
        if (descriptor.defaultQueue.label.data) free((void*)descriptor.defaultQueue.label.data);
        return throw_status_error(env, "DOE_REQUEST_DEVICE_ERROR", "requestDevice failed", result.status, result.message);
    }

    if (descriptor_ptr) {
        if (pfn_doeNativeObjectSetLabel && descriptor.label.data && descriptor.label.length > 0) {
            pfn_doeNativeObjectSetLabel(result.device, (const uint8_t*)descriptor.label.data, descriptor.label.length);
        }
        if (pfn_wgpuDeviceGetQueue) {
            WGPUQueue queue = pfn_wgpuDeviceGetQueue(result.device);
            if (queue && pfn_doeNativeObjectSetLabel && descriptor.defaultQueue.label.data && descriptor.defaultQueue.label.length > 0) {
                pfn_doeNativeObjectSetLabel(queue, (const uint8_t*)descriptor.defaultQueue.label.data, descriptor.defaultQueue.label.length);
            }
        }
    }

    free(required_features);
    if (descriptor.label.data) free((void*)descriptor.label.data);
    if (descriptor.defaultQueue.label.data) free((void*)descriptor.defaultQueue.label.data);

    return wrap_ptr(env, result.device);
}

napi_value doe_device_release(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    void* device = unwrap_ptr(env, _args[0]);
    if (device) {
        DeviceCallbackBinding* lost = binding_take(&g_lost_bindings, device);
        DeviceCallbackBinding* uncaptured = binding_take(&g_uncaptured_bindings, device);
        if (lost && pfn_doeNativeDeviceRegisterLostCallback) {
            pfn_doeNativeDeviceRegisterLostCallback(device, NULL, NULL);
        }
        if (uncaptured && pfn_doeNativeDeviceSetUncapturedErrorCallback) {
            pfn_doeNativeDeviceSetUncapturedErrorCallback(device, NULL, NULL, NULL);
        }
        if (lost) {
            release_binding(lost);
        }
        if (uncaptured) {
            release_binding(uncaptured);
        }
        pfn_wgpuDeviceRelease(device);
    }
    return NULL;
}

napi_value doe_device_get_queue(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    CHECK_LIB_LOADED(env);
    WGPUDevice device = unwrap_ptr(env, _args[0]);
    if (!device) NAPI_THROW(env, "Invalid device");
    WGPUQueue queue = pfn_wgpuDeviceGetQueue(device);
    return wrap_ptr(env, queue);
}
