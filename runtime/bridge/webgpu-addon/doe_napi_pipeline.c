#include "doe_napi_internal.h"

#define DOE_STACK_BIND_GROUP_LAYOUT_ENTRIES 8
#define DOE_STACK_BIND_GROUP_ENTRIES 8
#define DOE_STACK_PIPELINE_LAYOUTS 4
#define DOE_STACK_ENTRY_POINT_BYTES 128

/* ================================================================
 * Compute Pipeline
 * createComputePipeline(device, shaderModule, entryPoint, pipelineLayout?, constants?)
 * ================================================================ */

/* Parse a JS constants object/map {key: value, ...} into a WGPUConstantEntry array.
 * Returns the number of entries written; caller must free the returned array. */
size_t parse_js_override_constants(napi_env env, napi_value constants_obj,
                                           WGPUConstantEntry** out_entries) {
    *out_entries = NULL;
    if (!constants_obj) return 0;
    napi_valuetype vtype;
    napi_typeof(env, constants_obj, &vtype);
    if (vtype != napi_object) return 0;

    napi_value prop_names;
    napi_get_property_names(env, constants_obj, &prop_names);
    uint32_t count = 0;
    napi_get_array_length(env, prop_names, &count);
    if (count == 0) return 0;

    WGPUConstantEntry* entries = (WGPUConstantEntry*)calloc(count, sizeof(WGPUConstantEntry));
    if (!entries) return 0;
    /* Allocate key string storage — each key needs a null-terminated copy. */
    for (uint32_t i = 0; i < count; i++) {
        napi_value key_val;
        napi_get_element(env, prop_names, i, &key_val);
        size_t key_len = 0;
        napi_get_value_string_utf8(env, key_val, NULL, 0, &key_len);
        char* key_str = (char*)malloc(key_len + 1);
        if (!key_str) { free(entries); *out_entries = NULL; return 0; }
        napi_get_value_string_utf8(env, key_val, key_str, key_len + 1, &key_len);
        entries[i].nextInChain = NULL;
        entries[i].key.data = key_str;
        entries[i].key.length = key_len;
        napi_value val;
        napi_get_property(env, constants_obj, key_val, &val);
        napi_get_value_double(env, val, &entries[i].value);
    }
    *out_entries = entries;
    return count;
}

void free_override_constants(WGPUConstantEntry* entries, size_t count) {
    if (!entries) return;
    for (size_t i = 0; i < count; i++) {
        free((void*)entries[i].key.data);
    }
    free(entries);
}

napi_value doe_create_compute_pipeline(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 6);
    CHECK_LIB_LOADED(env);
    WGPUDevice device = unwrap_ptr(env, _args[0]);
    WGPUShaderModule shader = unwrap_ptr(env, _args[1]);
    if (!device || !shader) NAPI_THROW(env, "Invalid device or shader");

    size_t ep_len = 0;
    napi_get_value_string_utf8(env, _args[2], NULL, 0, &ep_len);
    char ep_stack[DOE_STACK_ENTRY_POINT_BYTES + 1];
    bool ep_on_heap = ep_len > DOE_STACK_ENTRY_POINT_BYTES;
    char* ep = ep_on_heap ? (char*)malloc(ep_len + 1) : ep_stack;
    if (!ep) NAPI_THROW(env, "createComputePipeline: out of memory while parsing entryPoint");
    napi_get_value_string_utf8(env, _args[2], ep, ep_len + 1, &ep_len);

    /* pipelineLayout can be null (auto layout) */
    napi_valuetype layout_type;
    napi_typeof(env, _args[3], &layout_type);
    void* layout = NULL;
    if (layout_type == napi_external) layout = unwrap_ptr(env, _args[3]);

    /* Parse optional override constants (5th arg) */
    WGPUConstantEntry* override_entries = NULL;
    size_t override_count = 0;
    if (_argc > 4) {
        napi_valuetype const_type;
        napi_typeof(env, _args[4], &const_type);
        if (const_type == napi_object) {
            override_count = parse_js_override_constants(env, _args[4], &override_entries);
        }
    }

    /* Read label (6th arg) */
    WGPUStringView label_view = { .data = NULL, .length = 0 };
    char label_buf[256] = {0};
    if (_argc > 5) {
        napi_valuetype lt; napi_typeof(env, _args[5], &lt);
        if (lt == napi_string) {
            size_t label_len = 0;
            napi_get_value_string_utf8(env, _args[5], label_buf, sizeof(label_buf), &label_len);
            label_view.data = label_buf;
            label_view.length = label_len;
        }
    }

    WGPUComputePipelineDescriptor desc;
    memset(&desc, 0, sizeof(desc));
    desc.label = label_view;
    desc.layout = layout;
    desc.compute.module = shader;
    desc.compute.entryPoint.data = ep;
    desc.compute.entryPoint.length = ep_len;
    desc.compute.constantCount = override_count;
    desc.compute.constants = override_entries;

    WGPUComputePipeline pipeline = pfn_wgpuDeviceCreateComputePipeline(device, &desc);
    if (ep_on_heap) free(ep);
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
    return wrap_ptr(env, pipeline);
}

napi_value doe_compute_pipeline_release(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    void* p = unwrap_ptr(env, _args[0]);
    if (p) pfn_wgpuComputePipelineRelease(p);
    return NULL;
}

/* computePipelineGetBindGroupLayout(pipeline, groupIndex) → bindGroupLayout */
napi_value doe_compute_pipeline_get_bind_group_layout(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 2);
    CHECK_LIB_LOADED(env);
    WGPUComputePipeline pipeline = unwrap_ptr(env, _args[0]);
    if (!pipeline) NAPI_THROW(env, "Invalid pipeline");
    uint32_t index;
    napi_get_value_uint32(env, _args[1], &index);
    WGPUBindGroupLayout layout = pfn_wgpuComputePipelineGetBindGroupLayout(pipeline, index);
    if (!layout) NAPI_THROW(env, "getBindGroupLayout failed");
    return wrap_ptr(env, layout);
}

/* ================================================================
 * Bind Group Layout
 * createBindGroupLayout(device, entries[])
 * Each entry: { binding, visibility, buffer?: { type }, sampler?: { type },
 *               texture?: { sampleType, viewDimension, multisampled },
 *               storageTexture?: { access, format, viewDimension } }
 * ================================================================ */

uint32_t buffer_binding_type_from_string(napi_env env, napi_value val) {
    napi_valuetype vt;
    napi_typeof(env, val, &vt);
    if (vt != napi_string) return 0x00000001; /* Undefined */
    char buf[32] = {0};
    size_t len = 0;
    napi_get_value_string_utf8(env, val, buf, sizeof(buf), &len);
    if (strcmp(buf, "uniform") == 0) return 0x00000002;
    if (strcmp(buf, "storage") == 0) return 0x00000003;
    if (strcmp(buf, "read-only-storage") == 0) return 0x00000004;
    return 0x00000001;
}

uint32_t sampler_binding_type_from_string(napi_env env, napi_value val) {
    napi_valuetype vt;
    napi_typeof(env, val, &vt);
    if (vt != napi_string) return 0x00000001; /* Undefined */
    char buf[32] = {0};
    size_t len = 0;
    napi_get_value_string_utf8(env, val, buf, sizeof(buf), &len);
    if (strcmp(buf, "filtering") == 0) return 0x00000002;
    if (strcmp(buf, "non-filtering") == 0 || strcmp(buf, "non_filtering") == 0) return 0x00000003;
    if (strcmp(buf, "comparison") == 0) return 0x00000004;
    return 0x00000001;
}

uint32_t texture_sample_type_from_string(napi_env env, napi_value val) {
    napi_valuetype vt;
    napi_typeof(env, val, &vt);
    if (vt != napi_string) return 0x00000001; /* Undefined */
    char buf[64] = {0};
    size_t len = 0;
    napi_get_value_string_utf8(env, val, buf, sizeof(buf), &len);
    if (strcmp(buf, "float") == 0) return 0x00000002;
    if (strcmp(buf, "unfilterable-float") == 0 || strcmp(buf, "unfilterable_float") == 0) return 0x00000003;
    if (strcmp(buf, "depth") == 0) return 0x00000004;
    if (strcmp(buf, "sint") == 0) return 0x00000005;
    if (strcmp(buf, "uint") == 0) return 0x00000006;
    return 0x00000001;
}

uint32_t texture_view_dimension_from_string(napi_env env, napi_value val) {
    napi_valuetype vt;
    napi_typeof(env, val, &vt);
    if (vt != napi_string) return 0x00000000; /* Undefined */
    char buf[32] = {0};
    size_t len = 0;
    napi_get_value_string_utf8(env, val, buf, sizeof(buf), &len);
    if (strcmp(buf, "1d") == 0) return 0x00000001;
    if (strcmp(buf, "2d") == 0) return 0x00000002;
    if (strcmp(buf, "2d-array") == 0 || strcmp(buf, "2d_array") == 0) return 0x00000003;
    if (strcmp(buf, "cube") == 0) return 0x00000004;
    if (strcmp(buf, "cube-array") == 0 || strcmp(buf, "cube_array") == 0) return 0x00000005;
    if (strcmp(buf, "3d") == 0) return 0x00000006;
    return 0x00000000;
}

uint32_t storage_texture_access_from_string(napi_env env, napi_value val) {
    napi_valuetype vt;
    napi_typeof(env, val, &vt);
    if (vt != napi_string) return 0x00000001; /* Undefined */
    char buf[32] = {0};
    size_t len = 0;
    napi_get_value_string_utf8(env, val, buf, sizeof(buf), &len);
    if (strcmp(buf, "write-only") == 0 || strcmp(buf, "write_only") == 0) return 0x00000002;
    if (strcmp(buf, "read-only") == 0 || strcmp(buf, "read_only") == 0) return 0x00000003;
    if (strcmp(buf, "read-write") == 0 || strcmp(buf, "read_write") == 0) return 0x00000004;
    return 0x00000001;
}

napi_value doe_create_bind_group_layout(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 3);
    CHECK_LIB_LOADED(env);
    WGPUDevice device = unwrap_ptr(env, _args[0]);
    if (!device) NAPI_THROW(env, "Invalid device");

    uint32_t entry_count = 0;
    napi_get_array_length(env, _args[1], &entry_count);

    WGPUBindGroupLayoutEntry stack_entries[DOE_STACK_BIND_GROUP_LAYOUT_ENTRIES];
    memset(stack_entries, 0, sizeof(stack_entries));
    WGPUBindGroupLayoutEntry* heap_entries = NULL;
    WGPUBindGroupLayoutEntry* entries = stack_entries;
    if (entry_count > DOE_STACK_BIND_GROUP_LAYOUT_ENTRIES) {
        heap_entries = (WGPUBindGroupLayoutEntry*)calloc(
            entry_count, sizeof(WGPUBindGroupLayoutEntry));
        if (!heap_entries) NAPI_THROW(env, "createBindGroupLayout: out of memory");
        entries = heap_entries;
    }

    for (uint32_t i = 0; i < entry_count; i++) {
        napi_value elem;
        napi_get_element(env, _args[1], i, &elem);

        entries[i].binding = get_uint32_prop(env, elem, "binding");
        entries[i].visibility = (uint64_t)get_int64_prop(env, elem, "visibility");

        if (has_prop(env, elem, "buffer") && prop_type(env, elem, "buffer") == napi_object) {
            napi_value buf_obj = get_prop(env, elem, "buffer");
            entries[i].buffer.type = buffer_binding_type_from_string(
                env, get_prop(env, buf_obj, "type"));
            if (has_prop(env, buf_obj, "hasDynamicOffset"))
                entries[i].buffer.hasDynamicOffset = get_bool_prop(env, buf_obj, "hasDynamicOffset") ? 1 : 0;
            if (has_prop(env, buf_obj, "minBindingSize"))
                entries[i].buffer.minBindingSize = (uint64_t)get_int64_prop(env, buf_obj, "minBindingSize");
        }

        if (has_prop(env, elem, "sampler") && prop_type(env, elem, "sampler") == napi_object) {
            napi_value sampler_obj = get_prop(env, elem, "sampler");
            entries[i].sampler.type = sampler_binding_type_from_string(
                env, get_prop(env, sampler_obj, "type"));
        }

        if (has_prop(env, elem, "texture") && prop_type(env, elem, "texture") == napi_object) {
            napi_value tex_obj = get_prop(env, elem, "texture");
            entries[i].texture.sampleType = texture_sample_type_from_string(
                env, get_prop(env, tex_obj, "sampleType"));
            entries[i].texture.viewDimension = texture_view_dimension_from_string(
                env, get_prop(env, tex_obj, "viewDimension"));
            if (has_prop(env, tex_obj, "textureBindingViewDimension")) {
                uint32_t tbvd = texture_view_dimension_from_string(
                    env, get_prop(env, tex_obj, "textureBindingViewDimension"));
                if (tbvd != 0)
                    entries[i].texture.viewDimension = tbvd;
            }
            if (has_prop(env, tex_obj, "multisampled"))
                entries[i].texture.multisampled = get_bool_prop(env, tex_obj, "multisampled") ? 1 : 0;
        }

        if (has_prop(env, elem, "storageTexture") && prop_type(env, elem, "storageTexture") == napi_object) {
            napi_value st_obj = get_prop(env, elem, "storageTexture");
            entries[i].storageTexture.access = storage_texture_access_from_string(env, get_prop(env, st_obj, "access"));
            entries[i].storageTexture.format = texture_format_from_string(env, get_prop(env, st_obj, "format"));
            entries[i].storageTexture.viewDimension = texture_view_dimension_from_string(env, get_prop(env, st_obj, "viewDimension"));
        }
    }

    /* Read label (3rd arg) */
    WGPUStringView label_view = { .data = NULL, .length = 0 };
    char label_buf[256] = {0};
    if (_argc > 2) {
        napi_valuetype lt; napi_typeof(env, _args[2], &lt);
        if (lt == napi_string) {
            size_t label_len = 0;
            napi_get_value_string_utf8(env, _args[2], label_buf, sizeof(label_buf), &label_len);
            label_view.data = label_buf;
            label_view.length = label_len;
        }
    }

    WGPUBindGroupLayoutDescriptor desc = {
        .nextInChain = NULL,
        .label = label_view,
        .entryCount = entry_count,
        .entries = entries,
    };

    WGPUBindGroupLayout layout = pfn_wgpuDeviceCreateBindGroupLayout(device, &desc);
    free(heap_entries);
    if (!layout) NAPI_THROW(env, "createBindGroupLayout failed");
    return wrap_ptr(env, layout);
}

napi_value doe_create_buffer_bind_group_layout_flat4(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 6);
    CHECK_LIB_LOADED(env);
    if (!pfn_doeNativeDeviceCreateBufferBindGroupLayoutFlat4) {
        NAPI_THROW(env, "createBufferBindGroupLayoutFlat4 unavailable");
    }
    WGPUDevice device = unwrap_ptr(env, _args[0]);
    if (!device) NAPI_THROW(env, "Invalid device");
    uint32_t entry_count = 0;
    uint32_t b0 = 0;
    uint32_t b1 = 0;
    uint32_t b2 = 0;
    uint32_t b3 = 0;
    napi_get_value_uint32(env, _args[1], &entry_count);
    napi_get_value_uint32(env, _args[2], &b0);
    napi_get_value_uint32(env, _args[3], &b1);
    napi_get_value_uint32(env, _args[4], &b2);
    napi_get_value_uint32(env, _args[5], &b3);
    WGPUBindGroupLayout layout = pfn_doeNativeDeviceCreateBufferBindGroupLayoutFlat4(
        device,
        entry_count,
        b0,
        b1,
        b2,
        b3
    );
    if (!layout) NAPI_THROW(env, "createBufferBindGroupLayoutFlat4 failed");
    return wrap_ptr(env, layout);
}

napi_value doe_bind_group_layout_release(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    void* p = unwrap_ptr(env, _args[0]);
    if (p) pfn_wgpuBindGroupLayoutRelease(p);
    return NULL;
}

/* ================================================================
 * Bind Group
 * createBindGroup(device, layout, entries[])
 * Each entry: { binding, buffer?, offset?, size?, sampler?, textureView? }
 * ================================================================ */

napi_value doe_create_bind_group(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 4);
    CHECK_LIB_LOADED(env);
    WGPUDevice device = unwrap_ptr(env, _args[0]);
    WGPUBindGroupLayout layout = unwrap_ptr(env, _args[1]);
    if (!device || !layout) NAPI_THROW(env, "Invalid device or layout");

    uint32_t entry_count = 0;
    napi_get_array_length(env, _args[2], &entry_count);

    WGPUBindGroupEntry stack_entries[DOE_STACK_BIND_GROUP_ENTRIES];
    memset(stack_entries, 0, sizeof(stack_entries));
    WGPUBindGroupEntry* heap_entries = NULL;
    WGPUBindGroupEntry* entries = stack_entries;
    if (entry_count > DOE_STACK_BIND_GROUP_ENTRIES) {
        heap_entries = (WGPUBindGroupEntry*)calloc(
            entry_count, sizeof(WGPUBindGroupEntry));
        if (!heap_entries) NAPI_THROW(env, "createBindGroup: out of memory");
        entries = heap_entries;
    }

    for (uint32_t i = 0; i < entry_count; i++) {
        napi_value elem;
        napi_get_element(env, _args[2], i, &elem);

        entries[i].binding = get_uint32_prop(env, elem, "binding");

        if (has_prop(env, elem, "buffer") && prop_type(env, elem, "buffer") == napi_external)
            entries[i].buffer = unwrap_ptr(env, get_prop(env, elem, "buffer"));

        if (has_prop(env, elem, "sampler") && prop_type(env, elem, "sampler") == napi_external)
            entries[i].sampler = unwrap_ptr(env, get_prop(env, elem, "sampler"));

        if (has_prop(env, elem, "textureView") && prop_type(env, elem, "textureView") == napi_external)
            entries[i].textureView = unwrap_ptr(env, get_prop(env, elem, "textureView"));

        if (has_prop(env, elem, "offset"))
            entries[i].offset = (uint64_t)get_int64_prop(env, elem, "offset");

        entries[i].size = WGPU_WHOLE_SIZE;
        if (has_prop(env, elem, "size"))
            entries[i].size = (uint64_t)get_int64_prop(env, elem, "size");
    }

    /* Read label (4th arg) */
    WGPUStringView label_view = { .data = NULL, .length = 0 };
    char label_buf[256] = {0};
    if (_argc > 3) {
        napi_valuetype lt; napi_typeof(env, _args[3], &lt);
        if (lt == napi_string) {
            size_t label_len = 0;
            napi_get_value_string_utf8(env, _args[3], label_buf, sizeof(label_buf), &label_len);
            label_view.data = label_buf;
            label_view.length = label_len;
        }
    }

    WGPUBindGroupDescriptor desc = {
        .nextInChain = NULL,
        .label = label_view,
        .layout = layout,
        .entryCount = entry_count,
        .entries = entries,
    };

    WGPUBindGroup group = pfn_wgpuDeviceCreateBindGroup(device, &desc);
    free(heap_entries);
    if (!group) NAPI_THROW(env, "createBindGroup failed");
    return wrap_ptr(env, group);
}

napi_value doe_create_buffer_bind_group_flat4(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 15);
    CHECK_LIB_LOADED(env);
    if (!pfn_doeNativeDeviceCreateBufferBindGroupFlat4) {
        NAPI_THROW(env, "createBufferBindGroupFlat4 unavailable");
    }
    WGPUDevice device = unwrap_ptr(env, _args[0]);
    WGPUBindGroupLayout layout = unwrap_ptr(env, _args[1]);
    if (!device || !layout) NAPI_THROW(env, "Invalid device or layout");
    uint32_t entry_count = 0;
    uint32_t b0 = 0;
    uint32_t b1 = 0;
    uint32_t b2 = 0;
    uint32_t b3 = 0;
    int64_t offset0 = 0;
    int64_t offset1 = 0;
    int64_t offset2 = 0;
    int64_t offset3 = 0;
    napi_get_value_uint32(env, _args[2], &entry_count);
    napi_get_value_uint32(env, _args[3], &b0);
    WGPUBuffer buffer0 = unwrap_ptr(env, _args[4]);
    napi_get_value_int64(env, _args[5], &offset0);
    napi_get_value_uint32(env, _args[6], &b1);
    WGPUBuffer buffer1 = unwrap_ptr(env, _args[7]);
    napi_get_value_int64(env, _args[8], &offset1);
    napi_get_value_uint32(env, _args[9], &b2);
    WGPUBuffer buffer2 = unwrap_ptr(env, _args[10]);
    napi_get_value_int64(env, _args[11], &offset2);
    napi_get_value_uint32(env, _args[12], &b3);
    WGPUBuffer buffer3 = unwrap_ptr(env, _args[13]);
    napi_get_value_int64(env, _args[14], &offset3);
    if (offset0 < 0 || offset1 < 0 || offset2 < 0 || offset3 < 0) {
        NAPI_THROW(env, "createBufferBindGroupFlat4 offsets must be non-negative");
    }
    WGPUBindGroup group = pfn_doeNativeDeviceCreateBufferBindGroupFlat4(
        device,
        layout,
        entry_count,
        b0,
        buffer0,
        (uint64_t)offset0,
        b1,
        buffer1,
        (uint64_t)offset1,
        b2,
        buffer2,
        (uint64_t)offset2,
        b3,
        buffer3,
        (uint64_t)offset3
    );
    if (!group) NAPI_THROW(env, "createBufferBindGroupFlat4 failed");
    return wrap_ptr(env, group);
}

napi_value doe_bind_group_release(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    void* p = unwrap_ptr(env, _args[0]);
    if (p) pfn_wgpuBindGroupRelease(p);
    return NULL;
}

/* ================================================================
 * Pipeline Layout
 * createPipelineLayout(device, bindGroupLayouts[], label?, immediateSize?)
 * ================================================================ */

napi_value doe_create_pipeline_layout(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 4);
    CHECK_LIB_LOADED(env);
    WGPUDevice device = unwrap_ptr(env, _args[0]);
    if (!device) NAPI_THROW(env, "Invalid device");

    uint32_t layout_count = 0;
    napi_get_array_length(env, _args[1], &layout_count);

    WGPUBindGroupLayout stack_layouts[DOE_STACK_PIPELINE_LAYOUTS];
    memset(stack_layouts, 0, sizeof(stack_layouts));
    WGPUBindGroupLayout* heap_layouts = NULL;
    WGPUBindGroupLayout* layouts = stack_layouts;
    if (layout_count > DOE_STACK_PIPELINE_LAYOUTS) {
        heap_layouts = (WGPUBindGroupLayout*)calloc(
            layout_count, sizeof(WGPUBindGroupLayout));
        if (!heap_layouts) NAPI_THROW(env, "createPipelineLayout: out of memory");
        layouts = heap_layouts;
    }
    for (uint32_t i = 0; i < layout_count; i++) {
        napi_value elem;
        napi_get_element(env, _args[1], i, &elem);
        layouts[i] = unwrap_ptr(env, elem);
    }

    /* Read optional label / immediateSize */
    WGPUStringView label_view = { .data = NULL, .length = 0 };
    char label_buf[256] = {0};
    uint32_t immediate_size = 0;
    if (_argc >= 3) {
        napi_valuetype arg2_type; napi_typeof(env, _args[2], &arg2_type);
        if (arg2_type == napi_string) {
            size_t label_len = 0;
            napi_get_value_string_utf8(env, _args[2], label_buf, sizeof(label_buf), &label_len);
            label_view.data = label_buf;
            label_view.length = label_len;
        } else if (arg2_type == napi_number) {
            napi_get_value_uint32(env, _args[2], &immediate_size);
        }
    }
    if (_argc >= 4) {
        napi_valuetype arg3_type; napi_typeof(env, _args[3], &arg3_type);
        if (arg3_type == napi_number) {
            napi_get_value_uint32(env, _args[3], &immediate_size);
        }
    }

    WGPUPipelineLayoutDescriptor desc = {
        .nextInChain = NULL,
        .label = label_view,
        .bindGroupLayoutCount = layout_count,
        .bindGroupLayouts = layouts,
        .immediateSize = immediate_size,
    };

    WGPUPipelineLayout pl = pfn_wgpuDeviceCreatePipelineLayout(device, &desc);
    free(heap_layouts);
    if (!pl) NAPI_THROW(env, "createPipelineLayout failed");
    return wrap_ptr(env, pl);
}

napi_value doe_create_pipeline_layout_one(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 3);
    CHECK_LIB_LOADED(env);
    if (!pfn_doeNativeDeviceCreatePipelineLayoutOne) {
        NAPI_THROW(env, "createPipelineLayoutOne unavailable");
    }
    WGPUDevice device = unwrap_ptr(env, _args[0]);
    WGPUBindGroupLayout layout = unwrap_ptr(env, _args[1]);
    if (!device || !layout) NAPI_THROW(env, "Invalid device or layout");
    uint32_t immediate_size = 0;
    napi_get_value_uint32(env, _args[2], &immediate_size);
    WGPUPipelineLayout pipeline_layout = pfn_doeNativeDeviceCreatePipelineLayoutOne(
        device,
        layout,
        immediate_size
    );
    if (!pipeline_layout) NAPI_THROW(env, "createPipelineLayoutOne failed");
    return wrap_ptr(env, pipeline_layout);
}

napi_value doe_pipeline_layout_release(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    void* p = unwrap_ptr(env, _args[0]);
    if (p) pfn_wgpuPipelineLayoutRelease(p);
    return NULL;
}
