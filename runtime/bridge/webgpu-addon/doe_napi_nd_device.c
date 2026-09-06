#include "doe_napi_internal.h"

/* Forward declarations for object constructors used here (defined in doe_napi_nd_creators.c) */
napi_value create_native_direct_buffer_object(napi_env env, WGPUInstance instance, napi_value queue_obj, WGPUBuffer buffer, uint64_t size, uint64_t usage);
napi_value create_native_direct_shader_module_object(napi_env env, WGPUShaderModule shader_module);
napi_value create_native_direct_compute_pipeline_object(napi_env env, WGPUComputePipeline pipeline);
napi_value create_native_direct_bind_group_layout_object(napi_env env, WGPUBindGroupLayout layout);
napi_value create_native_direct_bind_group_object(napi_env env, WGPUBindGroup group);
napi_value create_native_direct_pipeline_layout_object(napi_env env, WGPUPipelineLayout layout);
napi_value create_native_direct_command_encoder_object(napi_env env, WGPUCommandEncoder encoder);

napi_value native_direct_device_create_buffer(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    if (argc < 1) NAPI_THROW(env, "createBuffer requires a descriptor");
    WGPUDevice device = native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
    WGPUInstance inst = native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_INSTANCE);
    napi_value queue_obj = get_prop(env, this_arg, "queue");
    if (!device) NAPI_THROW(env, "Invalid device");

    WGPUBufferDescriptor desc;
    memset(&desc, 0, sizeof(desc));
    desc.usage = (uint64_t)get_int64_prop(env, argv[0], "usage");
    desc.size = (uint64_t)get_int64_prop(env, argv[0], "size");
    desc.mappedAtCreation = get_bool_prop(env, argv[0], "mappedAtCreation") ? 1 : 0;

    WGPUBuffer buffer = pfn_wgpuDeviceCreateBuffer(device, &desc);
    if (!buffer) NAPI_THROW(env, "createBuffer failed");
    return create_native_direct_buffer_object(env, inst, queue_obj, buffer, desc.size, desc.usage);
}

napi_value native_direct_device_create_shader_module(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    if (argc < 1) NAPI_THROW(env, "createShaderModule requires a descriptor");
    WGPUDevice device = native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
    if (!device) NAPI_THROW(env, "Invalid device");
    napi_value code_value = has_prop(env, argv[0], "code") ? get_prop(env, argv[0], "code") : get_prop(env, argv[0], "source");
    size_t code_len = 0;
    napi_get_value_string_utf8(env, code_value, NULL, 0, &code_len);
    char* code = (char*)malloc(code_len + 1);
    if (!code) NAPI_THROW(env, "createShaderModule: out of memory");
    napi_get_value_string_utf8(env, code_value, code, code_len + 1, &code_len);

    WGPUShaderModuleCompilationHint* hints = NULL;
    char** hint_entry_points = NULL;
    size_t hint_count = 0;
    if (has_prop(env, argv[0], "compilationHints")) {
        napi_value hints_value = get_prop(env, argv[0], "compilationHints");
        napi_valuetype hints_type = napi_undefined;
        bool is_array = false;
        napi_typeof(env, hints_value, &hints_type);
        if (hints_type == napi_object) {
            napi_is_array(env, hints_value, &is_array);
        }
        if (is_array) {
            uint32_t arr_len = 0;
            napi_get_array_length(env, hints_value, &arr_len);
            if (arr_len > 0) {
                hint_count = arr_len;
                hints = (WGPUShaderModuleCompilationHint*)calloc(hint_count, sizeof(WGPUShaderModuleCompilationHint));
                hint_entry_points = (char**)calloc(hint_count, sizeof(char*));
                if (!hints || !hint_entry_points) {
                    free(code);
                    free(hints);
                    free(hint_entry_points);
                    NAPI_THROW(env, "createShaderModule: out of memory while parsing compilationHints");
                }
                for (uint32_t i = 0; i < arr_len; i++) {
                    napi_value hint_obj;
                    napi_get_element(env, hints_value, i, &hint_obj);

                    napi_value entry_point_value;
                    if (napi_get_named_property(env, hint_obj, "entryPoint", &entry_point_value) == napi_ok) {
                        napi_valuetype entry_point_type = napi_undefined;
                        napi_typeof(env, entry_point_value, &entry_point_type);
                        if (entry_point_type == napi_string) {
                            size_t entry_len = 0;
                            napi_get_value_string_utf8(env, entry_point_value, NULL, 0, &entry_len);
                            hint_entry_points[i] = (char*)malloc(entry_len + 1);
                            if (!hint_entry_points[i]) {
                                free(code);
                                for (uint32_t j = 0; j < i; j++) free(hint_entry_points[j]);
                                free(hint_entry_points);
                                free(hints);
                                NAPI_THROW(env, "createShaderModule: out of memory while parsing compilationHints");
                            }
                            napi_get_value_string_utf8(env, entry_point_value, hint_entry_points[i], entry_len + 1, &entry_len);
                            hints[i].entryPoint.data = hint_entry_points[i];
                            hints[i].entryPoint.length = entry_len;
                        }
                    }

                    napi_value layout_value;
                    if (napi_get_named_property(env, hint_obj, "layout", &layout_value) == napi_ok) {
                        napi_valuetype layout_type = napi_undefined;
                        napi_typeof(env, layout_value, &layout_type);
                        if (layout_type == napi_string) {
                            hints[i].layout = NULL;
                        } else if (layout_type == napi_external || layout_type == napi_object) {
                            hints[i].layout = unwrap_ptr(env, layout_value);
                        }
                    }
                }
            }
        }
    }

    char* label_str = NULL;
    size_t label_len = 0;
    if (has_prop(env, argv[0], "label") && prop_type(env, argv[0], "label") == napi_string) {
        label_str = dup_string_value(env, get_prop(env, argv[0], "label"), &label_len);
        if (!label_str) {
            free(code);
            for (size_t i = 0; i < hint_count; i++) free(hint_entry_points[i]);
            free(hint_entry_points);
            free(hints);
            NAPI_THROW(env, "createShaderModule: out of memory while parsing label");
        }
    }

    WGPUShaderSourceWGSL wgsl_source = {
        .chain = { .next = NULL, .sType = WGPU_STYPE_SHADER_SOURCE_WGSL },
        .code = { .data = code, .length = code_len },
    };
    WGPUShaderModuleDescriptor desc = {
        .nextInChain = (void*)&wgsl_source,
        .label = { .data = label_str, .length = label_str ? label_len : 0 },
        .compilationHintCount = hint_count,
        .compilationHints = hints,
    };

    WGPUShaderModule mod = pfn_wgpuDeviceCreateShaderModule(device, &desc);
    free(label_str);
    free(code);
    for (size_t i = 0; i < hint_count; i++) {
        free(hint_entry_points[i]);
    }
    free(hint_entry_points);
    free(hints);
    if (!mod) {
        char msg[DOE_ERROR_BUF_CAP];
        char stage[64];
        char kind[64];
        copy_library_error_message(msg, sizeof(msg));
        copy_library_error_meta(pfn_doeNativeCopyLastErrorStage, stage, sizeof(stage));
        copy_library_error_meta(pfn_doeNativeCopyLastErrorKind, kind, sizeof(kind));
        if (msg[0] != '\0') {
            char full_msg[DOE_ERROR_BUF_CAP];
            doe_format_library_error_message(full_msg, sizeof(full_msg), stage, kind, msg);
            napi_throw_error(env, "DOE_SHADER_MODULE_ERROR", full_msg);
        } else {
            napi_throw_error(env, "DOE_SHADER_MODULE_ERROR", "createShaderModule failed");
        }
        return NULL;
    }
    return create_native_direct_shader_module_object(env, mod);
}

napi_value native_direct_device_create_compute_pipeline(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    if (argc < 1) NAPI_THROW(env, "createComputePipeline requires a descriptor");
    WGPUDevice device = native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
    if (!device) NAPI_THROW(env, "Invalid device");

    napi_value compute = get_prop(env, argv[0], "compute");
    napi_value module_obj = get_prop(env, compute, "module");
    WGPUShaderModule shader = native_direct_unwrap_external_prop(env, module_obj, DOE_DIRECT_NATIVE);
    if (!shader) NAPI_THROW(env, "createComputePipeline: compute.module is required");
    napi_value entry_value = has_prop(env, compute, "entryPoint") ? get_prop(env, compute, "entryPoint") : NULL;
    char* entry_point = NULL;
    size_t entry_len = 0;
    if (entry_value) {
        entry_point = dup_string_value(env, entry_value, &entry_len);
    } else {
        entry_len = 4;
        entry_point = (char*)malloc(entry_len + 1);
        memcpy(entry_point, "main", entry_len + 1);
    }
    if (!entry_point) NAPI_THROW(env, "createComputePipeline: out of memory");

    WGPUPipelineLayout layout = NULL;
    if (has_prop(env, argv[0], "layout")) {
        layout = native_direct_unwrap_external_prop(env, get_prop(env, argv[0], "layout"), DOE_DIRECT_NATIVE);
    }

    /* Parse optional override constants from descriptor.compute.constants */
    WGPUConstantEntry* override_entries = NULL;
    size_t override_count = 0;
    if (has_prop(env, compute, "constants")) {
        napi_value constants_obj = get_prop(env, compute, "constants");
        override_count = parse_js_override_constants(env, constants_obj, &override_entries);
    }

    /* Read label */
    WGPUStringView label_view = { .data = NULL, .length = 0 };
    char label_buf[256] = {0};
    if (has_prop(env, argv[0], "label") && prop_type(env, argv[0], "label") == napi_string) {
        size_t label_len = 0;
        napi_get_value_string_utf8(env, get_prop(env, argv[0], "label"), label_buf, sizeof(label_buf), &label_len);
        label_view.data = label_buf;
        label_view.length = label_len;
    }

    WGPUComputePipelineDescriptor desc;
    memset(&desc, 0, sizeof(desc));
    desc.label = label_view;
    desc.layout = layout;
    desc.compute.module = shader;
    desc.compute.entryPoint.data = entry_point;
    desc.compute.entryPoint.length = entry_len;
    desc.compute.constantCount = override_count;
    desc.compute.constants = override_entries;

    WGPUComputePipeline pipeline = pfn_wgpuDeviceCreateComputePipeline(device, &desc);
    free(entry_point);
    free_override_constants(override_entries, override_count);
    if (!pipeline) {
        char msg[DOE_ERROR_BUF_CAP];
        char stage[64];
        char kind[64];
        copy_library_error_message(msg, sizeof(msg));
        copy_library_error_meta(pfn_doeNativeCopyLastErrorStage, stage, sizeof(stage));
        copy_library_error_meta(pfn_doeNativeCopyLastErrorKind, kind, sizeof(kind));
        if (msg[0] != '\0') {
            char full_msg[DOE_ERROR_BUF_CAP];
            doe_format_library_error_message(full_msg, sizeof(full_msg), stage, kind, msg);
            napi_throw_error(env, "DOE_COMPUTE_PIPELINE_ERROR", full_msg);
        } else {
            napi_throw_error(env, "DOE_COMPUTE_PIPELINE_ERROR", "createComputePipeline failed");
        }
        return NULL;
    }
    return create_native_direct_compute_pipeline_object(env, pipeline);
}

napi_value native_direct_device_create_compute_pipeline_async(napi_env env, napi_callback_info info) {
    napi_value result = native_direct_device_create_compute_pipeline(env, info);
    if (!result) return NULL;
    return native_direct_resolved_promise(env, result);
}

napi_value native_direct_device_create_bind_group_layout(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    if (argc < 1) NAPI_THROW(env, "createBindGroupLayout requires a descriptor");
    WGPUDevice device = native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
    if (!device) NAPI_THROW(env, "Invalid device");

    uint32_t entry_count = 0;
    napi_value entries_array = get_prop(env, argv[0], "entries");
    napi_get_array_length(env, entries_array, &entry_count);
    WGPUBindGroupLayoutEntry* entries = (WGPUBindGroupLayoutEntry*)calloc(entry_count, sizeof(WGPUBindGroupLayoutEntry));
    if (!entries && entry_count > 0) NAPI_THROW(env, "createBindGroupLayout: out of memory");

    for (uint32_t i = 0; i < entry_count; i++) {
        napi_value elem;
        napi_get_element(env, entries_array, i, &elem);
        entries[i].binding = get_uint32_prop(env, elem, "binding");
        entries[i].visibility = (uint64_t)get_int64_prop(env, elem, "visibility");
        if (has_prop(env, elem, "buffer") && prop_type(env, elem, "buffer") == napi_object) {
            napi_value buffer = get_prop(env, elem, "buffer");
            entries[i].buffer.type = buffer_binding_type_from_string(env, get_prop(env, buffer, "type"));
            if (has_prop(env, buffer, "hasDynamicOffset")) entries[i].buffer.hasDynamicOffset = get_bool_prop(env, buffer, "hasDynamicOffset") ? 1 : 0;
            if (has_prop(env, buffer, "minBindingSize")) entries[i].buffer.minBindingSize = (uint64_t)get_int64_prop(env, buffer, "minBindingSize");
        }
        if (has_prop(env, elem, "sampler") && prop_type(env, elem, "sampler") == napi_object) {
            napi_value sampler = get_prop(env, elem, "sampler");
            entries[i].sampler.type = sampler_binding_type_from_string(env, get_prop(env, sampler, "type"));
        }
        if (has_prop(env, elem, "texture") && prop_type(env, elem, "texture") == napi_object) {
            napi_value texture = get_prop(env, elem, "texture");
            entries[i].texture.sampleType = texture_sample_type_from_string(env, get_prop(env, texture, "sampleType"));
            entries[i].texture.viewDimension = texture_view_dimension_from_string(env, get_prop(env, texture, "viewDimension"));
            if (has_prop(env, texture, "multisampled")) entries[i].texture.multisampled = get_bool_prop(env, texture, "multisampled") ? 1 : 0;
        }
        if (has_prop(env, elem, "storageTexture") && prop_type(env, elem, "storageTexture") == napi_object) {
            napi_value storage_texture = get_prop(env, elem, "storageTexture");
            entries[i].storageTexture.access = storage_texture_access_from_string(env, get_prop(env, storage_texture, "access"));
            entries[i].storageTexture.format = texture_format_from_string(env, get_prop(env, storage_texture, "format"));
            entries[i].storageTexture.viewDimension = texture_view_dimension_from_string(env, get_prop(env, storage_texture, "viewDimension"));
        }
    }

    /* Read label */
    WGPUStringView label_view = { .data = NULL, .length = 0 };
    char label_buf[256] = {0};
    if (has_prop(env, argv[0], "label") && prop_type(env, argv[0], "label") == napi_string) {
        size_t label_len = 0;
        napi_get_value_string_utf8(env, get_prop(env, argv[0], "label"), label_buf, sizeof(label_buf), &label_len);
        label_view.data = label_buf;
        label_view.length = label_len;
    }

    WGPUBindGroupLayoutDescriptor desc = {
        .nextInChain = NULL,
        .label = label_view,
        .entryCount = entry_count,
        .entries = entries,
    };
    WGPUBindGroupLayout layout = pfn_wgpuDeviceCreateBindGroupLayout(device, &desc);
    free(entries);
    if (!layout) NAPI_THROW(env, "createBindGroupLayout failed");
    return create_native_direct_bind_group_layout_object(env, layout);
}

napi_value native_direct_device_create_bind_group(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    if (argc < 1) NAPI_THROW(env, "createBindGroup requires a descriptor");
    WGPUDevice device = native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
    WGPUBindGroupLayout layout = native_direct_unwrap_external_prop(env, get_prop(env, argv[0], "layout"), DOE_DIRECT_NATIVE);
    if (!device || !layout) NAPI_THROW(env, "Invalid device or layout");

    napi_value entries_array = get_prop(env, argv[0], "entries");
    uint32_t entry_count = 0;
    napi_get_array_length(env, entries_array, &entry_count);
    WGPUBindGroupEntry* entries = (WGPUBindGroupEntry*)calloc(entry_count, sizeof(WGPUBindGroupEntry));
    if (!entries && entry_count > 0) NAPI_THROW(env, "createBindGroup: out of memory");

    for (uint32_t i = 0; i < entry_count; i++) {
        napi_value elem;
        napi_value resource;
        napi_get_element(env, entries_array, i, &elem);
        entries[i].binding = get_uint32_prop(env, elem, "binding");
        resource = get_prop(env, elem, "resource");
        if (has_prop(env, resource, "buffer")) entries[i].buffer = native_direct_unwrap_external_prop(env, get_prop(env, resource, "buffer"), DOE_DIRECT_NATIVE);
        if (has_prop(env, resource, "sampler")) entries[i].sampler = native_direct_unwrap_external_prop(env, get_prop(env, resource, "sampler"), DOE_DIRECT_NATIVE);
        if (has_prop(env, resource, "textureView")) entries[i].textureView = native_direct_unwrap_external_prop(env, get_prop(env, resource, "textureView"), DOE_DIRECT_NATIVE);
        if (has_prop(env, resource, "offset")) entries[i].offset = (uint64_t)get_int64_prop(env, resource, "offset");
        entries[i].size = has_prop(env, resource, "size") ? (uint64_t)get_int64_prop(env, resource, "size") : WGPU_WHOLE_SIZE;
    }

    /* Read label */
    WGPUStringView label_view = { .data = NULL, .length = 0 };
    char label_buf[256] = {0};
    if (has_prop(env, argv[0], "label") && prop_type(env, argv[0], "label") == napi_string) {
        size_t label_len = 0;
        napi_get_value_string_utf8(env, get_prop(env, argv[0], "label"), label_buf, sizeof(label_buf), &label_len);
        label_view.data = label_buf;
        label_view.length = label_len;
    }

    WGPUBindGroupDescriptor desc = {
        .nextInChain = NULL,
        .label = label_view,
        .layout = layout,
        .entryCount = entry_count,
        .entries = entries,
    };
    WGPUBindGroup group = pfn_wgpuDeviceCreateBindGroup(device, &desc);
    free(entries);
    if (!group) NAPI_THROW(env, "createBindGroup failed");
    return create_native_direct_bind_group_object(env, group);
}

napi_value native_direct_device_create_pipeline_layout(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    if (argc < 1) NAPI_THROW(env, "createPipelineLayout requires a descriptor");
    WGPUDevice device = native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
    if (!device) NAPI_THROW(env, "Invalid device");

    napi_value layouts_array = get_prop(env, argv[0], "bindGroupLayouts");
    uint32_t layout_count = 0;
    napi_get_array_length(env, layouts_array, &layout_count);
    WGPUBindGroupLayout* layouts = (WGPUBindGroupLayout*)calloc(layout_count, sizeof(WGPUBindGroupLayout));
    if (!layouts && layout_count > 0) NAPI_THROW(env, "createPipelineLayout: out of memory");
    for (uint32_t i = 0; i < layout_count; i++) {
        napi_value elem;
        napi_get_element(env, layouts_array, i, &elem);
        layouts[i] = native_direct_unwrap_external_prop(env, elem, DOE_DIRECT_NATIVE);
    }

    /* Read label / immediateSize */
    WGPUStringView label_view = { .data = NULL, .length = 0 };
    char label_buf[256] = {0};
    uint32_t immediate_size = 0;
    if (has_prop(env, argv[0], "label") && prop_type(env, argv[0], "label") == napi_string) {
        size_t label_len = 0;
        napi_get_value_string_utf8(env, get_prop(env, argv[0], "label"), label_buf, sizeof(label_buf), &label_len);
        label_view.data = label_buf;
        label_view.length = label_len;
    }
    if (has_prop(env, argv[0], "immediateSize") && prop_type(env, argv[0], "immediateSize") == napi_number) {
        napi_get_value_uint32(env, get_prop(env, argv[0], "immediateSize"), &immediate_size);
    }

    WGPUPipelineLayoutDescriptor desc = {
        .nextInChain = NULL,
        .label = label_view,
        .bindGroupLayoutCount = layout_count,
        .bindGroupLayouts = layouts,
        .immediateSize = immediate_size,
    };
    WGPUPipelineLayout pipeline_layout = pfn_wgpuDeviceCreatePipelineLayout(device, &desc);
    free(layouts);
    if (!pipeline_layout) NAPI_THROW(env, "createPipelineLayout failed");
    return create_native_direct_pipeline_layout_object(env, pipeline_layout);
}

napi_value native_direct_device_create_command_encoder(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, argv, &this_arg, NULL);
    NativeDirectHandleCache* device_cache = native_direct_get_handle_cache(env, this_arg);
    WGPUDevice device = device_cache ? (WGPUDevice)device_cache->native : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
    if (!device) NAPI_THROW(env, "Invalid device");

    /* Read label from optional descriptor */
    WGPUStringView label_view = { .data = NULL, .length = 0 };
    char label_buf[256] = {0};
    if (argc >= 1) {
        napi_valuetype desc_vt; napi_typeof(env, argv[0], &desc_vt);
        if (desc_vt == napi_object && has_prop(env, argv[0], "label") && prop_type(env, argv[0], "label") == napi_string) {
            size_t label_len = 0;
            napi_get_value_string_utf8(env, get_prop(env, argv[0], "label"), label_buf, sizeof(label_buf), &label_len);
            label_view.data = label_buf;
            label_view.length = label_len;
        }
    }

    WGPUCommandEncoderDescriptor desc = {
        .nextInChain = NULL,
        .label = label_view,
    };
    WGPUCommandEncoder encoder = pfn_wgpuDeviceCreateCommandEncoder(device, &desc);
    if (!encoder) NAPI_THROW(env, "createCommandEncoder failed");
    return create_native_direct_command_encoder_object(env, encoder);
}

napi_value native_direct_device_destroy(napi_env env, napi_callback_info info) {
    size_t argc = 0;
    napi_value this_arg;
    napi_get_cb_info(env, info, &argc, NULL, &this_arg, NULL);
    NativeDirectHandleCache* device_cache = native_direct_get_handle_cache(env, this_arg);
    WGPUDevice device = device_cache ? (WGPUDevice)device_cache->native : native_direct_unwrap_external_prop(env, this_arg, DOE_DIRECT_NATIVE);
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
        native_direct_set_external_prop(env, this_arg, DOE_DIRECT_NATIVE, NULL);
        if (device_cache) device_cache->native = NULL;
    }
    if (has_prop(env, this_arg, "queue")) {
        napi_value queue_obj = get_prop(env, this_arg, "queue");
        NativeDirectQueueCache* queue_cache = native_direct_get_queue_cache(env, queue_obj);
        WGPUQueue queue = queue_cache ? queue_cache->queue : native_direct_unwrap_external_prop(env, queue_obj, DOE_DIRECT_NATIVE);
        native_direct_set_external_prop(env, queue_obj, DOE_DIRECT_NATIVE, NULL);
        native_direct_set_external_prop(env, queue_obj, DOE_DIRECT_QUEUE_NATIVE, NULL);
        if (queue_cache) queue_cache->queue = NULL;
        if (queue) pfn_wgpuQueueRelease(queue);
    }
    napi_value undefined_value;
    napi_get_undefined(env, &undefined_value);
    return undefined_value;
}
