/*
 * doe_napi_render.c — Render pipeline, render pass, debug markers,
 * and render bundle N-API bindings.
 * Format converters are in doe_napi_formats.c.
 */
#include "doe_napi_internal.h"

/* Stencil operation string-to-enum (WebGPU GPUStencilOperation) */
static uint32_t stencil_operation_from_string(napi_env env, napi_value val) {
    napi_valuetype vt; napi_typeof(env, val, &vt);
    if (vt == napi_number) { uint32_t out = 0; napi_get_value_uint32(env, val, &out); return out; }
    char buf[24] = {0}; size_t len = 0;
    napi_get_value_string_utf8(env, val, buf, sizeof(buf), &len);
    if (strcmp(buf, "keep") == 0)            return 0;
    if (strcmp(buf, "zero") == 0)            return 1;
    if (strcmp(buf, "replace") == 0)         return 2;
    if (strcmp(buf, "invert") == 0)          return 3;
    if (strcmp(buf, "increment-clamp") == 0) return 4;
    if (strcmp(buf, "decrement-clamp") == 0) return 5;
    if (strcmp(buf, "increment-wrap") == 0)  return 6;
    if (strcmp(buf, "decrement-wrap") == 0)  return 7;
    napi_throw_error(env, "DOE_ERROR", "Unsupported stencil operation"); return 0;
}

static uint32_t load_op_from_value(napi_env env, napi_value val) {
    napi_valuetype vt; napi_typeof(env, val, &vt);
    if (vt == napi_number) { uint32_t out = 0; napi_get_value_uint32(env, val, &out); return out; }
    char buf[16] = {0}; size_t len = 0;
    napi_get_value_string_utf8(env, val, buf, sizeof(buf), &len);
    if (strcmp(buf, "load") == 0)  return 0x00000001;
    if (strcmp(buf, "clear") == 0) return 0x00000002;
    napi_throw_error(env, "DOE_ERROR", "Unsupported loadOp"); return 0;
}

static uint32_t store_op_from_value(napi_env env, napi_value val) {
    napi_valuetype vt; napi_typeof(env, val, &vt);
    if (vt == napi_number) { uint32_t out = 0; napi_get_value_uint32(env, val, &out); return out; }
    char buf[16] = {0}; size_t len = 0;
    napi_get_value_string_utf8(env, val, buf, sizeof(buf), &len);
    if (strcmp(buf, "store") == 0)   return 0x00000001;
    if (strcmp(buf, "discard") == 0) return 0x00000002;
    napi_throw_error(env, "DOE_ERROR", "Unsupported storeOp"); return 0;
}

/* Parse a GPUStencilFaceState object into a WGPURenderStencilFaceState.
   Defaults per WebGPU spec: compare=always, failOp/depthFailOp/passOp=keep. */
static WGPURenderStencilFaceState parse_stencil_face(napi_env env, napi_value obj) {
    WGPURenderStencilFaceState face;
    face.compare     = has_prop(env, obj, "compare")     ? compare_func_from_value(env, get_prop(env, obj, "compare"))            : 0x00000008;
    face.failOp      = has_prop(env, obj, "failOp")      ? stencil_operation_from_string(env, get_prop(env, obj, "failOp"))        : 0;
    face.depthFailOp = has_prop(env, obj, "depthFailOp") ? stencil_operation_from_string(env, get_prop(env, obj, "depthFailOp"))   : 0;
    face.passOp      = has_prop(env, obj, "passOp")      ? stencil_operation_from_string(env, get_prop(env, obj, "passOp"))        : 0;
    return face;
}

/* Blend state parsing */

static WGPUBlendComponent parse_blend_component(napi_env env, napi_value obj) {
    WGPUBlendComponent comp;
    comp.operation = has_prop(env, obj, "operation")
        ? blend_operation_from_string(env, get_prop(env, obj, "operation")) : 1; /* add */
    comp.srcFactor = has_prop(env, obj, "srcFactor")
        ? blend_factor_from_string(env, get_prop(env, obj, "srcFactor")) : 2; /* one */
    comp.dstFactor = has_prop(env, obj, "dstFactor")
        ? blend_factor_from_string(env, get_prop(env, obj, "dstFactor")) : 1; /* zero */
    return comp;
}

typedef void (*FnWgpuComputePassEncoderPushDebugGroup)(WGPUComputePassEncoder, WGPUStringView);
typedef void (*FnWgpuComputePassEncoderPopDebugGroup)(WGPUComputePassEncoder);
typedef void (*FnWgpuComputePassEncoderInsertDebugMarker)(WGPUComputePassEncoder, WGPUStringView);
typedef void (*FnWgpuRenderPassEncoderDrawIndirect)(WGPURenderPassEncoder, WGPUBuffer, uint64_t);
typedef void (*FnWgpuRenderPassEncoderDrawIndexedIndirect)(WGPURenderPassEncoder, WGPUBuffer, uint64_t);
typedef void (*FnDoeNativeRenderPassExecuteBundles)(void*, size_t, void* const*);
typedef void (*FnWgpuRenderBundleEncoderDrawIndirect)(void*, WGPUBuffer, uint64_t);
typedef void (*FnWgpuRenderBundleEncoderDrawIndexedIndirect)(void*, WGPUBuffer, uint64_t);

static FnWgpuComputePassEncoderPushDebugGroup resolve_wgpu_compute_pass_push_debug_group(void) {
    static FnWgpuComputePassEncoderPushDebugGroup fn = NULL;
    static bool resolved = false;
    if (!resolved) {
        fn = (FnWgpuComputePassEncoderPushDebugGroup)LIB_SYM(g_lib, "wgpuComputePassEncoderPushDebugGroup");
        resolved = true;
    }
    return fn;
}

static FnWgpuComputePassEncoderPopDebugGroup resolve_wgpu_compute_pass_pop_debug_group(void) {
    static FnWgpuComputePassEncoderPopDebugGroup fn = NULL;
    static bool resolved = false;
    if (!resolved) {
        fn = (FnWgpuComputePassEncoderPopDebugGroup)LIB_SYM(g_lib, "wgpuComputePassEncoderPopDebugGroup");
        resolved = true;
    }
    return fn;
}

static FnWgpuComputePassEncoderInsertDebugMarker resolve_wgpu_compute_pass_insert_debug_marker(void) {
    static FnWgpuComputePassEncoderInsertDebugMarker fn = NULL;
    static bool resolved = false;
    if (!resolved) {
        fn = (FnWgpuComputePassEncoderInsertDebugMarker)LIB_SYM(g_lib, "wgpuComputePassEncoderInsertDebugMarker");
        resolved = true;
    }
    return fn;
}

static FnWgpuRenderPassEncoderDrawIndirect resolve_wgpu_render_pass_draw_indirect(void) {
    static FnWgpuRenderPassEncoderDrawIndirect fn = NULL;
    static bool resolved = false;
    if (!resolved) {
        fn = (FnWgpuRenderPassEncoderDrawIndirect)LIB_SYM(g_lib, "wgpuRenderPassEncoderDrawIndirect");
        resolved = true;
    }
    return fn;
}

static FnWgpuRenderPassEncoderDrawIndexedIndirect resolve_wgpu_render_pass_draw_indexed_indirect(void) {
    static FnWgpuRenderPassEncoderDrawIndexedIndirect fn = NULL;
    static bool resolved = false;
    if (!resolved) {
        fn = (FnWgpuRenderPassEncoderDrawIndexedIndirect)LIB_SYM(g_lib, "wgpuRenderPassEncoderDrawIndexedIndirect");
        resolved = true;
    }
    return fn;
}

static FnDoeNativeRenderPassExecuteBundles resolve_doe_native_render_pass_execute_bundles(void) {
    static FnDoeNativeRenderPassExecuteBundles fn = NULL;
    static bool resolved = false;
    if (!resolved) {
        fn = (FnDoeNativeRenderPassExecuteBundles)LIB_SYM(g_lib, "doeNativeRenderPassExecuteBundles");
        resolved = true;
    }
    return fn;
}

static FnWgpuRenderBundleEncoderDrawIndirect resolve_wgpu_render_bundle_encoder_draw_indirect(void) {
    static FnWgpuRenderBundleEncoderDrawIndirect fn = NULL;
    static bool resolved = false;
    if (!resolved) {
        fn = (FnWgpuRenderBundleEncoderDrawIndirect)LIB_SYM(g_lib, "wgpuRenderBundleEncoderDrawIndirect");
        resolved = true;
    }
    return fn;
}

static FnWgpuRenderBundleEncoderDrawIndexedIndirect resolve_wgpu_render_bundle_encoder_draw_indexed_indirect(void) {
    static FnWgpuRenderBundleEncoderDrawIndexedIndirect fn = NULL;
    static bool resolved = false;
    if (!resolved) {
        fn = (FnWgpuRenderBundleEncoderDrawIndexedIndirect)LIB_SYM(g_lib, "wgpuRenderBundleEncoderDrawIndexedIndirect");
        resolved = true;
    }
    return fn;
}

/* Render Pipeline */

napi_value doe_create_render_pipeline(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 2);
    CHECK_LIB_LOADED(env);
    WGPUDevice device = unwrap_ptr(env, _args[0]);
    if (!device) NAPI_THROW(env, "Invalid device");
    napi_valuetype descriptor_type; napi_typeof(env, _args[1], &descriptor_type);
    if (descriptor_type != napi_object) NAPI_THROW(env, "createRenderPipeline requires a descriptor object");
    if (prop_type(env, _args[1], "vertex") != napi_object)
        NAPI_THROW(env, "createRenderPipeline requires descriptor.vertex");
    if (prop_type(env, _args[1], "fragment") != napi_object)
        NAPI_THROW(env, "createRenderPipeline requires descriptor.fragment");

    napi_value vertex   = get_prop(env, _args[1], "vertex");
    napi_value fragment = get_prop(env, _args[1], "fragment");
    napi_value targets  = get_prop(env, fragment, "targets");
    bool is_targets_array = false;
    napi_is_array(env, targets, &is_targets_array);
    if (!is_targets_array) NAPI_THROW(env, "createRenderPipeline requires descriptor.fragment.targets");
    uint32_t target_count = 0; napi_get_array_length(env, targets, &target_count);
    if (target_count == 0) NAPI_THROW(env, "createRenderPipeline requires at least one fragment target");
    if (target_count > 1) NAPI_THROW(env, "createRenderPipeline currently supports one color target on this package surface");

    WGPUShaderModule vertex_module   = unwrap_ptr(env, get_prop(env, vertex, "module"));
    WGPUShaderModule fragment_module = unwrap_ptr(env, get_prop(env, fragment, "module"));
    if (!vertex_module)   NAPI_THROW(env, "createRenderPipeline: descriptor.vertex.module must be a shader module");
    if (!fragment_module) NAPI_THROW(env, "createRenderPipeline: descriptor.fragment.module must be a shader module");

    size_t vertex_entry_len = 0, fragment_entry_len = 0;
    char* vertex_entry = has_prop(env, vertex, "entryPoint")
        ? dup_string_value(env, get_prop(env, vertex, "entryPoint"), &vertex_entry_len)
        : NULL;
    if (!has_prop(env, vertex, "entryPoint")) vertex_entry_len = 4;
    if (!has_prop(env, vertex, "entryPoint")) {
        vertex_entry = (char*)malloc(vertex_entry_len + 1);
        if (vertex_entry) memcpy(vertex_entry, "main", vertex_entry_len + 1);
    }
    char* fragment_entry = has_prop(env, fragment, "entryPoint")
        ? dup_string_value(env, get_prop(env, fragment, "entryPoint"), &fragment_entry_len)
        : NULL;
    if (!has_prop(env, fragment, "entryPoint")) fragment_entry_len = 4;
    if (!has_prop(env, fragment, "entryPoint")) {
        fragment_entry = (char*)malloc(fragment_entry_len + 1);
        if (fragment_entry) memcpy(fragment_entry, "main", fragment_entry_len + 1);
    }
    if (!vertex_entry || !fragment_entry) {
        free(vertex_entry); free(fragment_entry);
        NAPI_THROW(env, "createRenderPipeline: out of memory");
    }

    WGPURenderVertexBufferLayout* vertex_buffers = NULL;
    WGPURenderVertexAttribute*    vertex_attributes = NULL;
    WGPURenderDepthStencilState*  depth_stencil = NULL;
    uint32_t vertex_buffer_count = 0;

    if (has_prop(env, vertex, "buffers")) {
        napi_value buffers = get_prop(env, vertex, "buffers");
        bool is_array = false; napi_is_array(env, buffers, &is_array);
        if (!is_array) { free(vertex_entry); free(fragment_entry); NAPI_THROW(env, "createRenderPipeline: descriptor.vertex.buffers must be an array"); }
        napi_get_array_length(env, buffers, &vertex_buffer_count);
        if (vertex_buffer_count > 0) {
            size_t total_attributes = 0;
            for (uint32_t i = 0; i < vertex_buffer_count; i++) {
                napi_value buffer_desc; napi_get_element(env, buffers, i, &buffer_desc);
                if (prop_type(env, buffer_desc, "attributes") == napi_object) {
                    napi_value attrs = get_prop(env, buffer_desc, "attributes");
                    bool attrs_is_array = false; napi_is_array(env, attrs, &attrs_is_array);
                    if (!attrs_is_array) { free(vertex_entry); free(fragment_entry); NAPI_THROW(env, "createRenderPipeline: descriptor.vertex.buffers[*].attributes must be an array"); }
                    uint32_t attr_count = 0; napi_get_array_length(env, attrs, &attr_count);
                    total_attributes += attr_count;
                }
            }
            vertex_buffers = (WGPURenderVertexBufferLayout*)calloc(vertex_buffer_count, sizeof(WGPURenderVertexBufferLayout));
            if (!vertex_buffers) { free(vertex_entry); free(fragment_entry); NAPI_THROW(env, "createRenderPipeline: out of memory"); }
            if (total_attributes > 0) {
                vertex_attributes = (WGPURenderVertexAttribute*)calloc(total_attributes, sizeof(WGPURenderVertexAttribute));
                if (!vertex_attributes) { free(vertex_buffers); free(vertex_entry); free(fragment_entry); NAPI_THROW(env, "createRenderPipeline: out of memory"); }
            }
            size_t attr_index = 0;
            for (uint32_t i = 0; i < vertex_buffer_count; i++) {
                napi_value buffer_desc; napi_get_element(env, buffers, i, &buffer_desc);
                vertex_buffers[i].nextInChain = NULL;
                vertex_buffers[i].stepMode = has_prop(env, buffer_desc, "stepMode")
                    ? vertex_step_mode_from_value(env, get_prop(env, buffer_desc, "stepMode")) : 0x00000001;
                vertex_buffers[i].arrayStride = has_prop(env, buffer_desc, "arrayStride")
                    ? (uint64_t)get_int64_prop(env, buffer_desc, "arrayStride") : 0;
                vertex_buffers[i].attributeCount = 0;
                vertex_buffers[i].attributes = NULL;
                if (prop_type(env, buffer_desc, "attributes") == napi_object) {
                    napi_value attrs = get_prop(env, buffer_desc, "attributes");
                    uint32_t attr_count = 0; napi_get_array_length(env, attrs, &attr_count);
                    vertex_buffers[i].attributeCount = attr_count;
                    vertex_buffers[i].attributes = attr_count > 0 ? &vertex_attributes[attr_index] : NULL;
                    for (uint32_t j = 0; j < attr_count; j++) {
                        napi_value attr; napi_get_element(env, attrs, j, &attr);
                        vertex_attributes[attr_index].nextInChain = NULL;
                        vertex_attributes[attr_index].format = vertex_format_from_value(env, get_prop(env, attr, "format"));
                        vertex_attributes[attr_index].offset = has_prop(env, attr, "offset")
                            ? (uint64_t)get_int64_prop(env, attr, "offset") : 0;
                        vertex_attributes[attr_index].shaderLocation = get_uint32_prop(env, attr, "shaderLocation");
                        attr_index += 1;
                    }
                }
            }
        }
    }

    napi_value target0; napi_get_element(env, targets, 0, &target0);
    WGPURenderColorTargetState color_target; memset(&color_target, 0, sizeof(color_target));
    color_target.format = texture_format_from_string(env, get_prop(env, target0, "format"));
    color_target.writeMask = has_prop(env, target0, "writeMask")
        ? (uint64_t)get_uint32_prop(env, target0, "writeMask") : 0xF;
    WGPUBlendState* blend_state = NULL;
    if (has_prop(env, target0, "blend") && prop_type(env, target0, "blend") == napi_object) {
        napi_value blend_obj = get_prop(env, target0, "blend");
        blend_state = (WGPUBlendState*)calloc(1, sizeof(WGPUBlendState));
        if (!blend_state) { free(vertex_buffers); free(vertex_attributes); free(vertex_entry); free(fragment_entry); NAPI_THROW(env, "createRenderPipeline: out of memory"); }
        if (has_prop(env, blend_obj, "color") && prop_type(env, blend_obj, "color") == napi_object)
            blend_state->color = parse_blend_component(env, get_prop(env, blend_obj, "color"));
        else
            blend_state->color = (WGPUBlendComponent){ 1, 2, 1 }; /* add, one, zero */
        if (has_prop(env, blend_obj, "alpha") && prop_type(env, blend_obj, "alpha") == napi_object)
            blend_state->alpha = parse_blend_component(env, get_prop(env, blend_obj, "alpha"));
        else
            blend_state->alpha = (WGPUBlendComponent){ 1, 2, 1 }; /* add, one, zero */
        color_target.blend = blend_state;
    }

    WGPURenderFragmentState fragment_state; memset(&fragment_state, 0, sizeof(fragment_state));
    fragment_state.module = fragment_module;
    fragment_state.entryPoint.data = fragment_entry; fragment_state.entryPoint.length = fragment_entry_len;
    fragment_state.targetCount = 1; fragment_state.targets = &color_target;

    char* label_str = NULL;
    size_t label_len = 0;
    if (has_prop(env, _args[1], "label")) {
        label_str = dup_string_value(env, get_prop(env, _args[1], "label"), &label_len);
    }

    WGPURenderPipelineDescriptor desc; memset(&desc, 0, sizeof(desc));
    desc.label.data = label_str;
    desc.label.length = label_str ? label_len : 0;
    desc.layout = has_prop(env, _args[1], "layout") && prop_type(env, _args[1], "layout") == napi_external
        ? unwrap_ptr(env, get_prop(env, _args[1], "layout")) : NULL;
    desc.vertex.module = vertex_module;
    desc.vertex.entryPoint.data = vertex_entry; desc.vertex.entryPoint.length = vertex_entry_len;
    desc.vertex.bufferCount = vertex_buffer_count; desc.vertex.buffers = vertex_buffers;
    desc.primitive.topology = 0x00000004; desc.primitive.frontFace = 0x00000001; desc.primitive.cullMode = 0x00000001;
    if (has_prop(env, _args[1], "primitive") && prop_type(env, _args[1], "primitive") == napi_object) {
        napi_value primitive = get_prop(env, _args[1], "primitive");
        if (has_prop(env, primitive, "topology"))
            desc.primitive.topology = primitive_topology_from_string(env, get_prop(env, primitive, "topology"));
        if (has_prop(env, primitive, "frontFace"))
            desc.primitive.frontFace = front_face_from_string(env, get_prop(env, primitive, "frontFace"));
        if (has_prop(env, primitive, "cullMode"))
            desc.primitive.cullMode = cull_mode_from_string(env, get_prop(env, primitive, "cullMode"));
        if (has_prop(env, primitive, "unclippedDepth"))
            desc.primitive.unclippedDepth = get_bool_prop(env, primitive, "unclippedDepth") ? 1 : 0;
    }
    if (has_prop(env, _args[1], "depthStencil") && prop_type(env, _args[1], "depthStencil") == napi_object) {
        napi_value depth_obj = get_prop(env, _args[1], "depthStencil");
        depth_stencil = (WGPURenderDepthStencilState*)calloc(1, sizeof(WGPURenderDepthStencilState));
        if (!depth_stencil) { free(vertex_buffers); free(vertex_attributes); free(vertex_entry); free(fragment_entry); free(label_str); NAPI_THROW(env, "createRenderPipeline: out of memory"); }
        depth_stencil->format = texture_format_from_string(env, get_prop(env, depth_obj, "format"));
        depth_stencil->depthWriteEnabled = has_prop(env, depth_obj, "depthWriteEnabled") ? (get_bool_prop(env, depth_obj, "depthWriteEnabled") ? 1 : 0) : 0;
        depth_stencil->depthCompare = has_prop(env, depth_obj, "depthCompare") ? compare_func_from_value(env, get_prop(env, depth_obj, "depthCompare")) : 0x00000008;
        depth_stencil->stencilReadMask = has_prop(env, depth_obj, "stencilReadMask") ? get_uint32_prop(env, depth_obj, "stencilReadMask") : 0xFFFFFFFFu;
        depth_stencil->stencilWriteMask = has_prop(env, depth_obj, "stencilWriteMask") ? get_uint32_prop(env, depth_obj, "stencilWriteMask") : 0xFFFFFFFFu;
        depth_stencil->depthBias = has_prop(env, depth_obj, "depthBias") ? (int32_t)get_int64_prop(env, depth_obj, "depthBias") : 0;
        depth_stencil->depthBiasSlopeScale = has_prop(env, depth_obj, "depthBiasSlopeScale") ? (float)get_double_prop(env, depth_obj, "depthBiasSlopeScale") : 0.0f;
        depth_stencil->depthBiasClamp = has_prop(env, depth_obj, "depthBiasClamp") ? (float)get_double_prop(env, depth_obj, "depthBiasClamp") : 0.0f;
        if (has_prop(env, depth_obj, "stencilFront") && prop_type(env, depth_obj, "stencilFront") == napi_object)
            depth_stencil->stencilFront = parse_stencil_face(env, get_prop(env, depth_obj, "stencilFront"));
        else
            depth_stencil->stencilFront = (WGPURenderStencilFaceState){ 0x00000008, 0, 0, 0 };
        if (has_prop(env, depth_obj, "stencilBack") && prop_type(env, depth_obj, "stencilBack") == napi_object)
            depth_stencil->stencilBack = parse_stencil_face(env, get_prop(env, depth_obj, "stencilBack"));
        else
            depth_stencil->stencilBack = (WGPURenderStencilFaceState){ 0x00000008, 0, 0, 0 };
        desc.depthStencil = depth_stencil;
    }
    desc.multisample.count = 1; desc.multisample.mask = 0xFFFFffffu;
    if (has_prop(env, _args[1], "multisample") && prop_type(env, _args[1], "multisample") == napi_object) {
        napi_value ms = get_prop(env, _args[1], "multisample");
        if (has_prop(env, ms, "count")) desc.multisample.count = get_uint32_prop(env, ms, "count");
        if (has_prop(env, ms, "mask"))  desc.multisample.mask  = get_uint32_prop(env, ms, "mask");
        if (has_prop(env, ms, "alphaToCoverageEnabled"))
            desc.multisample.alphaToCoverageEnabled = get_bool_prop(env, ms, "alphaToCoverageEnabled") ? 1 : 0;
    }
    WGPUConstantEntry* vertex_constants = NULL;
    size_t vertex_constant_count = 0;
    if (has_prop(env, vertex, "constants") && prop_type(env, vertex, "constants") == napi_object)
        vertex_constant_count = parse_js_override_constants(env, get_prop(env, vertex, "constants"), &vertex_constants);
    desc.vertex.constantCount = vertex_constant_count;
    desc.vertex.constants = vertex_constants;

    WGPUConstantEntry* fragment_constants = NULL;
    size_t fragment_constant_count = 0;
    if (has_prop(env, fragment, "constants") && prop_type(env, fragment, "constants") == napi_object)
        fragment_constant_count = parse_js_override_constants(env, get_prop(env, fragment, "constants"), &fragment_constants);
    fragment_state.constantCount = fragment_constant_count;
    fragment_state.constants = fragment_constants;

    desc.fragment = &fragment_state;

    WGPURenderPipeline rp = pfn_wgpuDeviceCreateRenderPipeline(device, &desc);
    free_override_constants(vertex_constants, vertex_constant_count);
    free_override_constants(fragment_constants, fragment_constant_count);
    free(blend_state); free(depth_stencil); free(vertex_attributes); free(vertex_buffers);
    free(vertex_entry); free(fragment_entry); free(label_str);
    if (!rp) {
        char msg[DOE_ERROR_BUF_CAP];
        char stage[64];
        char kind[64];
        copy_library_error_message(msg, sizeof(msg));
        copy_library_error_meta(pfn_doeNativeCopyLastErrorStage, stage, sizeof(stage));
        copy_library_error_meta(pfn_doeNativeCopyLastErrorKind, kind, sizeof(kind));
        if (msg[0] != '\0') {
            char full_msg[DOE_ERROR_BUF_CAP];
            doe_format_library_error_message(full_msg, sizeof(full_msg), stage, kind, msg);
            napi_throw_error(env, "DOE_RENDER_PIPELINE_ERROR", full_msg);
        } else {
            napi_throw_error(env, "DOE_RENDER_PIPELINE_ERROR", "createRenderPipeline failed");
        }
        return NULL;
    }
    return wrap_ptr(env, rp);
}

napi_value doe_render_pipeline_release(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    void* p = unwrap_ptr(env, _args[0]);
    if (p) pfn_wgpuRenderPipelineRelease(p);
    return NULL;
}

napi_value doe_render_pipeline_get_bind_group_layout(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 2);
    CHECK_LIB_LOADED(env);
    void* pipeline = unwrap_ptr(env, _args[0]);
    if (!pipeline) NAPI_THROW(env, "Invalid render pipeline");
    uint32_t index; napi_get_value_uint32(env, _args[1], &index);
    if (!pfn_doeNativeRenderPipelineGetBindGroupLayout) NAPI_THROW(env, "renderPipelineGetBindGroupLayout not available");
    void* layout = pfn_doeNativeRenderPipelineGetBindGroupLayout(pipeline, index);
    if (!layout) NAPI_THROW(env, "renderPipelineGetBindGroupLayout failed");
    return wrap_ptr(env, layout);
}

/* Render Pass */

napi_value doe_begin_render_pass(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 2);
    CHECK_LIB_LOADED(env);
    WGPUCommandEncoder enc = unwrap_ptr(env, _args[0]);
    if (!enc) NAPI_THROW(env, "Invalid encoder");
    if (prop_type(env, _args[1], "colorAttachments") != napi_object)
        NAPI_THROW(env, "beginRenderPass requires descriptor.colorAttachments");
    napi_value color_attachments = get_prop(env, _args[1], "colorAttachments");
    uint32_t att_count = 0; napi_get_array_length(env, color_attachments, &att_count);
    if (att_count == 0) NAPI_THROW(env, "beginRenderPass: need at least one color attachment");
    WGPURenderPassColorAttachment* atts = (WGPURenderPassColorAttachment*)calloc(att_count, sizeof(WGPURenderPassColorAttachment));
    WGPURenderPassDepthStencilAttachment depth_att; memset(&depth_att, 0, sizeof(depth_att));
    bool has_depth_att = false;
    for (uint32_t i = 0; i < att_count; i++) {
        napi_value elem; napi_get_element(env, color_attachments, i, &elem);
        atts[i].view = unwrap_ptr(env, get_prop(env, elem, "view"));
        if (has_prop(env, elem, "resolveTarget") && prop_type(env, elem, "resolveTarget") == napi_external)
            atts[i].resolveTarget = unwrap_ptr(env, get_prop(env, elem, "resolveTarget"));
        atts[i].depthSlice = has_prop(env, elem, "depthSlice")
            ? get_uint32_prop(env, elem, "depthSlice") : UINT32_MAX;
        atts[i].loadOp = has_prop(env, elem, "loadOp")
            ? load_op_from_value(env, get_prop(env, elem, "loadOp"))
            : 0x00000001;
        atts[i].storeOp = has_prop(env, elem, "storeOp")
            ? store_op_from_value(env, get_prop(env, elem, "storeOp"))
            : 0x00000001;
        if (has_prop(env, elem, "clearValue") && prop_type(env, elem, "clearValue") == napi_object) {
            napi_value cv = get_prop(env, elem, "clearValue");
            double r = 0, g = 0, b = 0, a = 1; napi_value tmp;
            if (napi_get_named_property(env, cv, "r", &tmp) == napi_ok) napi_get_value_double(env, tmp, &r);
            if (napi_get_named_property(env, cv, "g", &tmp) == napi_ok) napi_get_value_double(env, tmp, &g);
            if (napi_get_named_property(env, cv, "b", &tmp) == napi_ok) napi_get_value_double(env, tmp, &b);
            if (napi_get_named_property(env, cv, "a", &tmp) == napi_ok) napi_get_value_double(env, tmp, &a);
            atts[i].clearValue = (WGPUColor){ r, g, b, a };
        }
    }
    if (has_prop(env, _args[1], "depthStencilAttachment") && prop_type(env, _args[1], "depthStencilAttachment") == napi_object) {
        napi_value depth_obj = get_prop(env, _args[1], "depthStencilAttachment");
        depth_att.view = unwrap_ptr(env, get_prop(env, depth_obj, "view"));
        depth_att.depthLoadOp = has_prop(env, depth_obj, "depthLoadOp")
            ? load_op_from_value(env, get_prop(env, depth_obj, "depthLoadOp"))
            : 0x00000001;
        depth_att.depthStoreOp = has_prop(env, depth_obj, "depthStoreOp")
            ? store_op_from_value(env, get_prop(env, depth_obj, "depthStoreOp"))
            : 0x00000001;
        depth_att.depthClearValue = has_prop(env, depth_obj, "depthClearValue")
            ? (float)get_double_prop(env, depth_obj, "depthClearValue") : 1.0f;
        depth_att.depthReadOnly = has_prop(env, depth_obj, "depthReadOnly")
            ? (get_bool_prop(env, depth_obj, "depthReadOnly") ? 1 : 0) : 0;
        depth_att.stencilLoadOp = has_prop(env, depth_obj, "stencilLoadOp")
            ? load_op_from_value(env, get_prop(env, depth_obj, "stencilLoadOp"))
            : 0x00000001;
        depth_att.stencilStoreOp = has_prop(env, depth_obj, "stencilStoreOp")
            ? store_op_from_value(env, get_prop(env, depth_obj, "stencilStoreOp"))
            : 0x00000001;
        depth_att.stencilClearValue = has_prop(env, depth_obj, "stencilClearValue")
            ? get_uint32_prop(env, depth_obj, "stencilClearValue") : 0;
        depth_att.stencilReadOnly = has_prop(env, depth_obj, "stencilReadOnly")
            ? (get_bool_prop(env, depth_obj, "stencilReadOnly") ? 1 : 0) : 0;
        has_depth_att = true;
    }
    WGPURenderPassTimestampWrites ts_writes = {0};
    WGPURenderPassTimestampWrites* ts_writes_ptr = NULL;
    if (has_prop(env, _args[1], "timestampWrites") &&
        prop_type(env, _args[1], "timestampWrites") == napi_object) {
        napi_value tw = get_prop(env, _args[1], "timestampWrites");
        ts_writes.querySet = unwrap_ptr(env, get_prop(env, tw, "querySet"));
        ts_writes.beginningOfPassWriteIndex = get_uint32_prop(env, tw, "beginningOfPassWriteIndex");
        ts_writes.endOfPassWriteIndex = get_uint32_prop(env, tw, "endOfPassWriteIndex");
        ts_writes_ptr = &ts_writes;
    }

    char* label_str = NULL;
    size_t label_len = 0;
    if (has_prop(env, _args[1], "label")) {
        label_str = dup_string_value(env, get_prop(env, _args[1], "label"), &label_len);
    }
    WGPURenderPassDescriptor desc; memset(&desc, 0, sizeof(desc));
    desc.label.data = label_str;
    desc.label.length = label_str ? label_len : 0;
    desc.colorAttachmentCount = att_count; desc.colorAttachments = atts;
    desc.depthStencilAttachment = has_depth_att ? &depth_att : NULL;
    if (has_prop(env, _args[1], "occlusionQuerySet") && prop_type(env, _args[1], "occlusionQuerySet") == napi_external)
        desc.occlusionQuerySet = unwrap_ptr(env, get_prop(env, _args[1], "occlusionQuerySet"));
    desc.timestampWrites = ts_writes_ptr;
    desc.maxDrawCount = has_prop(env, _args[1], "maxDrawCount")
        ? (uint64_t)get_uint32_prop(env, _args[1], "maxDrawCount") : 50000000;
    WGPURenderPassEncoder pass = pfn_wgpuCommandEncoderBeginRenderPass(enc, &desc);
    free(atts);
    free(label_str);
    if (!pass) NAPI_THROW(env, "beginRenderPass failed");
    return wrap_ptr(env, pass);
}

napi_value doe_render_pass_set_pipeline(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 2);
    pfn_wgpuRenderPassEncoderSetPipeline(unwrap_ptr(env, _args[0]), unwrap_ptr(env, _args[1]));
    return NULL;
}

napi_value doe_render_pass_set_bind_group(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 3);
    WGPURenderPassEncoder pass = unwrap_ptr(env, _args[0]);
    uint32_t index = 0; napi_get_value_uint32(env, _args[1], &index);
    WGPUBindGroup bg = unwrap_ptr(env, _args[2]);
    pfn_wgpuRenderPassEncoderSetBindGroup(pass, index, bg, 0, NULL);
    return NULL;
}

napi_value doe_render_pass_set_immediates(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 3);
    if (!pfn_doeNativeRenderPassSetImmediates) NAPI_THROW(env, "renderPassSetImmediates not available");
    WGPURenderPassEncoder pass = unwrap_ptr(env, _args[0]);
    if (!pass) NAPI_THROW(env, "Invalid render pass");
    uint32_t index = 0; napi_get_value_uint32(env, _args[1], &index);
    void* data_ptr = NULL;
    size_t data_len = 0;
    extract_buffer_data(env, _args[2], &data_ptr, &data_len);
    pfn_doeNativeRenderPassSetImmediates(pass, index, (const uint8_t*)data_ptr, data_len);
    return NULL;
}

napi_value doe_render_pass_set_vertex_buffer(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 5);
    WGPURenderPassEncoder pass = unwrap_ptr(env, _args[0]);
    uint32_t slot = 0; napi_get_value_uint32(env, _args[1], &slot);
    WGPUBuffer buffer = unwrap_ptr(env, _args[2]);
    uint64_t offset = (uint64_t)get_int64_value(env, _args[3]);
    uint64_t size   = (uint64_t)get_int64_value(env, _args[4]);
    pfn_wgpuRenderPassEncoderSetVertexBuffer(pass, slot, buffer, offset, size);
    return NULL;
}

napi_value doe_render_pass_set_index_buffer(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 5);
    WGPURenderPassEncoder pass = unwrap_ptr(env, _args[0]);
    WGPUBuffer buffer = unwrap_ptr(env, _args[1]);
    uint32_t format = index_format_from_value(env, _args[2]);
    uint64_t offset = (uint64_t)get_int64_value(env, _args[3]);
    uint64_t size   = (uint64_t)get_int64_value(env, _args[4]);
    pfn_wgpuRenderPassEncoderSetIndexBuffer(pass, buffer, format, offset, size);
    return NULL;
}

napi_value doe_render_pass_draw(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 5);
    WGPURenderPassEncoder pass = unwrap_ptr(env, _args[0]);
    uint32_t vc, ic, fv, fi;
    napi_get_value_uint32(env, _args[1], &vc); napi_get_value_uint32(env, _args[2], &ic);
    napi_get_value_uint32(env, _args[3], &fv); napi_get_value_uint32(env, _args[4], &fi);
    pfn_wgpuRenderPassEncoderDraw(pass, vc, ic, fv, fi);
    return NULL;
}

napi_value doe_render_pass_draw_indexed(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 6);
    WGPURenderPassEncoder pass = unwrap_ptr(env, _args[0]);
    uint32_t index_count = 0, instance_count = 0, first_index = 0; int32_t base_vertex = 0; uint32_t first_instance = 0;
    napi_get_value_uint32(env, _args[1], &index_count); napi_get_value_uint32(env, _args[2], &instance_count);
    napi_get_value_uint32(env, _args[3], &first_index); napi_get_value_int32(env, _args[4], &base_vertex);
    napi_get_value_uint32(env, _args[5], &first_instance);
    pfn_wgpuRenderPassEncoderDrawIndexed(pass, index_count, instance_count, first_index, base_vertex, first_instance);
    return NULL;
}

napi_value doe_render_pass_execute_bundles(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 2);
    void* pass = unwrap_ptr(env, _args[0]);
    FnDoeNativeRenderPassExecuteBundles fn = resolve_doe_native_render_pass_execute_bundles();
    if (!pass || !fn) NAPI_THROW(env, "renderPassExecuteBundles not available");
    bool is_array = false;
    napi_is_array(env, _args[1], &is_array);
    if (!is_array) NAPI_THROW(env, "renderPassExecuteBundles requires an array of bundles");

    uint32_t bundle_count = 0;
    napi_get_array_length(env, _args[1], &bundle_count);
    void** bundles = bundle_count ? (void**)calloc(bundle_count, sizeof(void*)) : NULL;
    if (bundle_count && !bundles) NAPI_THROW(env, "renderPassExecuteBundles: out of memory");

    for (uint32_t i = 0; i < bundle_count; i++) {
        napi_value bundle_value;
        napi_get_element(env, _args[1], i, &bundle_value);
        bundles[i] = unwrap_ptr(env, bundle_value);
    }

    fn(pass, (size_t)bundle_count, bundles);
    free(bundles);
    return NULL;
}

napi_value doe_render_pass_end(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    pfn_wgpuRenderPassEncoderEnd(unwrap_ptr(env, _args[0]));
    return NULL;
}

napi_value doe_render_pass_release(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    void* p = unwrap_ptr(env, _args[0]);
    if (p) pfn_wgpuRenderPassEncoderRelease(p);
    return NULL;
}

napi_value doe_render_pass_set_viewport(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 7);
    void* pass = unwrap_ptr(env, _args[0]);
    if (!pass || !pfn_doeNativeRenderPassSetViewport) return NULL;
    double x = 0, y = 0, width = 0, height = 0, min_depth = 0, max_depth = 1;
    napi_get_value_double(env, _args[1], &x); napi_get_value_double(env, _args[2], &y);
    napi_get_value_double(env, _args[3], &width); napi_get_value_double(env, _args[4], &height);
    napi_get_value_double(env, _args[5], &min_depth); napi_get_value_double(env, _args[6], &max_depth);
    pfn_doeNativeRenderPassSetViewport(pass, x, y, width, height, min_depth, max_depth);
    return NULL;
}

napi_value doe_render_pass_set_scissor_rect(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 5);
    void* pass = unwrap_ptr(env, _args[0]);
    if (!pass || !pfn_doeNativeRenderPassSetScissorRect) return NULL;
    uint32_t x = 0, y = 0, width = 0, height = 0;
    napi_get_value_uint32(env, _args[1], &x); napi_get_value_uint32(env, _args[2], &y);
    napi_get_value_uint32(env, _args[3], &width); napi_get_value_uint32(env, _args[4], &height);
    pfn_doeNativeRenderPassSetScissorRect(pass, x, y, width, height);
    return NULL;
}

napi_value doe_render_pass_set_blend_constant(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 5);
    void* pass = unwrap_ptr(env, _args[0]);
    if (!pass || !pfn_doeNativeRenderPassSetBlendConstant) return NULL;
    double r = 0, g = 0, b = 0, a = 1;
    napi_get_value_double(env, _args[1], &r); napi_get_value_double(env, _args[2], &g);
    napi_get_value_double(env, _args[3], &b); napi_get_value_double(env, _args[4], &a);
    pfn_doeNativeRenderPassSetBlendConstant(pass, r, g, b, a);
    return NULL;
}

napi_value doe_render_pass_set_stencil_reference(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 2);
    void* pass = unwrap_ptr(env, _args[0]);
    if (!pass || !pfn_doeNativeRenderPassSetStencilReference) return NULL;
    uint32_t reference = 0; napi_get_value_uint32(env, _args[1], &reference);
    pfn_doeNativeRenderPassSetStencilReference(pass, reference);
    return NULL;
}

/* Debug markers */

napi_value doe_render_pass_push_debug_group(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 2);
    void* pass = unwrap_ptr(env, _args[0]);
    if (!pass || !pfn_doeNativeRenderPassPushDebugGroup) return NULL;
    size_t label_len = 0;
    napi_get_value_string_utf8(env, _args[1], NULL, 0, &label_len);
    char* label = (char*)malloc(label_len + 1); if (!label) return NULL;
    napi_get_value_string_utf8(env, _args[1], label, label_len + 1, &label_len);
    pfn_doeNativeRenderPassPushDebugGroup(pass, label, label_len);
    free(label); return NULL;
}

napi_value doe_render_pass_pop_debug_group(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    void* pass = unwrap_ptr(env, _args[0]);
    if (!pass || !pfn_doeNativeRenderPassPopDebugGroup) return NULL;
    pfn_doeNativeRenderPassPopDebugGroup(pass);
    return NULL;
}

napi_value doe_render_pass_insert_debug_marker(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 2);
    void* pass = unwrap_ptr(env, _args[0]);
    if (!pass || !pfn_doeNativeRenderPassInsertDebugMarker) return NULL;
    size_t label_len = 0;
    napi_get_value_string_utf8(env, _args[1], NULL, 0, &label_len);
    char* label = (char*)malloc(label_len + 1); if (!label) return NULL;
    napi_get_value_string_utf8(env, _args[1], label, label_len + 1, &label_len);
    pfn_doeNativeRenderPassInsertDebugMarker(pass, label, label_len);
    free(label); return NULL;
}

napi_value doe_compute_pass_push_debug_group(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 2);
    WGPUComputePassEncoder pass = unwrap_ptr(env, _args[0]);
    FnWgpuComputePassEncoderPushDebugGroup fn = resolve_wgpu_compute_pass_push_debug_group();
    if (!pass || !fn) NAPI_THROW(env, "computePassPushDebugGroup not available");
    size_t label_len = 0;
    napi_get_value_string_utf8(env, _args[1], NULL, 0, &label_len);
    char* label = (char*)malloc(label_len + 1);
    if (!label) NAPI_THROW(env, "computePassPushDebugGroup: out of memory");
    napi_get_value_string_utf8(env, _args[1], label, label_len + 1, &label_len);
    fn(pass, (WGPUStringView){ .data = label, .length = label_len });
    free(label);
    return NULL;
}

napi_value doe_compute_pass_pop_debug_group(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    WGPUComputePassEncoder pass = unwrap_ptr(env, _args[0]);
    FnWgpuComputePassEncoderPopDebugGroup fn = resolve_wgpu_compute_pass_pop_debug_group();
    if (!pass || !fn) NAPI_THROW(env, "computePassPopDebugGroup not available");
    fn(pass);
    return NULL;
}

napi_value doe_compute_pass_insert_debug_marker(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 2);
    WGPUComputePassEncoder pass = unwrap_ptr(env, _args[0]);
    FnWgpuComputePassEncoderInsertDebugMarker fn = resolve_wgpu_compute_pass_insert_debug_marker();
    if (!pass || !fn) NAPI_THROW(env, "computePassInsertDebugMarker not available");
    size_t label_len = 0;
    napi_get_value_string_utf8(env, _args[1], NULL, 0, &label_len);
    char* label = (char*)malloc(label_len + 1);
    if (!label) NAPI_THROW(env, "computePassInsertDebugMarker: out of memory");
    napi_get_value_string_utf8(env, _args[1], label, label_len + 1, &label_len);
    fn(pass, (WGPUStringView){ .data = label, .length = label_len });
    free(label);
    return NULL;
}

napi_value doe_render_pass_draw_indirect(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 3);
    WGPURenderPassEncoder pass = unwrap_ptr(env, _args[0]);
    WGPUBuffer buffer = unwrap_ptr(env, _args[1]);
    FnWgpuRenderPassEncoderDrawIndirect fn = resolve_wgpu_render_pass_draw_indirect();
    if (!pass || !buffer || !fn) NAPI_THROW(env, "renderPassDrawIndirect not available");
    uint64_t offset = (uint64_t)get_int64_value(env, _args[2]);
    fn(pass, buffer, offset);
    return NULL;
}

napi_value doe_render_pass_draw_indexed_indirect(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 3);
    WGPURenderPassEncoder pass = unwrap_ptr(env, _args[0]);
    WGPUBuffer buffer = unwrap_ptr(env, _args[1]);
    FnWgpuRenderPassEncoderDrawIndexedIndirect fn = resolve_wgpu_render_pass_draw_indexed_indirect();
    if (!pass || !buffer || !fn) NAPI_THROW(env, "renderPassDrawIndexedIndirect not available");
    uint64_t offset = (uint64_t)get_int64_value(env, _args[2]);
    fn(pass, buffer, offset);
    return NULL;
}

napi_value doe_render_bundle_encoder_draw_indirect(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 3);
    void* enc = unwrap_ptr(env, _args[0]);
    WGPUBuffer buffer = unwrap_ptr(env, _args[1]);
    FnWgpuRenderBundleEncoderDrawIndirect fn = resolve_wgpu_render_bundle_encoder_draw_indirect();
    if (!enc || !buffer || !fn) NAPI_THROW(env, "renderBundleEncoderDrawIndirect not available");
    uint64_t offset = (uint64_t)get_int64_value(env, _args[2]);
    fn(enc, buffer, offset);
    return NULL;
}

napi_value doe_render_bundle_encoder_draw_indexed_indirect(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 3);
    void* enc = unwrap_ptr(env, _args[0]);
    WGPUBuffer buffer = unwrap_ptr(env, _args[1]);
    FnWgpuRenderBundleEncoderDrawIndexedIndirect fn = resolve_wgpu_render_bundle_encoder_draw_indexed_indirect();
    if (!enc || !buffer || !fn) NAPI_THROW(env, "renderBundleEncoderDrawIndexedIndirect not available");
    uint64_t offset = (uint64_t)get_int64_value(env, _args[2]);
    fn(enc, buffer, offset);
    return NULL;
}

/* Render Bundle Encoder */

/* RenderBundleEncoderDescriptor layout matching wgpu_render_types.zig. */
typedef struct {
    void*    nextInChain;
    void*    label_data;
    size_t   label_len;
    size_t   colorFormatCount;
    uint32_t* colorFormats;
    uint32_t depthStencilFormat;
    uint32_t sampleCount;
    uint32_t depthReadOnly;
    uint32_t stencilReadOnly;
} BundleEncoderDescC;

napi_value doe_create_render_bundle_encoder(napi_env env, napi_callback_info info) {
    size_t argc = 7;
    napi_value argv[7];
    if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok) {
        NAPI_THROW(env, "napi_get_cb_info failed");
    }
    if (argc < 6) NAPI_THROW(env, "createRenderBundleEncoder requires device, formats, depth format, sample count, and read-only flags");
    CHECK_LIB_LOADED(env);
    if (!pfn_doeNativeDeviceCreateRenderBundleEncoder) NAPI_THROW(env, "doeNativeDeviceCreateRenderBundleEncoder not available");
    void* device = unwrap_ptr(env, argv[0]);
    if (!device) NAPI_THROW(env, "createRenderBundleEncoder: invalid device");
    uint32_t fmt_count = 0; bool is_array = false;
    napi_is_array(env, argv[1], &is_array);
    if (is_array) napi_get_array_length(env, argv[1], &fmt_count);
    uint32_t* fmts = fmt_count > 0 ? (uint32_t*)malloc(fmt_count * sizeof(uint32_t)) : NULL;
    for (uint32_t i = 0; i < fmt_count; i++) {
        napi_value elem; napi_get_element(env, argv[1], i, &elem);
        napi_get_value_uint32(env, elem, &fmts[i]);
    }
    uint32_t depth_stencil_format = 0; napi_get_value_uint32(env, argv[2], &depth_stencil_format);
    uint32_t sample_count = 1;         napi_get_value_uint32(env, argv[3], &sample_count);
    bool depth_read_only = false;      napi_get_value_bool(env, argv[4], &depth_read_only);
    bool stencil_read_only = false;    napi_get_value_bool(env, argv[5], &stencil_read_only);
    char* label = NULL;
    size_t label_len = 0;
    if (argc >= 7) {
        napi_valuetype label_type = napi_undefined;
        if (napi_typeof(env, argv[6], &label_type) == napi_ok && label_type == napi_string) {
            label = dup_string_value(env, argv[6], &label_len);
            if (!label) {
                free(fmts);
                NAPI_THROW(env, "createRenderBundleEncoder: out of memory while parsing label");
            }
        }
    }
    BundleEncoderDescC desc = {
        .nextInChain = NULL, .label_data = label, .label_len = label_len,
        .colorFormatCount   = (size_t)fmt_count, .colorFormats = fmts,
        .depthStencilFormat = depth_stencil_format,
        .sampleCount        = sample_count == 0 ? 1 : sample_count,
        .depthReadOnly      = depth_read_only ? 1 : 0,
        .stencilReadOnly    = stencil_read_only ? 1 : 0,
    };
    void* enc = pfn_doeNativeDeviceCreateRenderBundleEncoder(device, &desc);
    free(label);
    free(fmts);
    if (!enc) NAPI_THROW(env, "createRenderBundleEncoder failed");
    return wrap_ptr(env, enc);
}

napi_value doe_render_bundle_encoder_set_pipeline(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 2);
    void* enc = unwrap_ptr(env, _args[0]); void* pipeline = unwrap_ptr(env, _args[1]);
    if (!enc || !pipeline) return NULL;
    if (pfn_doeNativeRenderBundleEncoderSetPipeline) pfn_doeNativeRenderBundleEncoderSetPipeline(enc, pipeline);
    return NULL;
}

napi_value doe_render_bundle_encoder_set_bind_group(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 3);
    void* enc = unwrap_ptr(env, _args[0]); if (!enc) return NULL;
    uint32_t index = 0; napi_get_value_uint32(env, _args[1], &index);
    void* bg = unwrap_ptr(env, _args[2]); if (!bg) return NULL;
    if (pfn_doeNativeRenderBundleEncoderSetBindGroup) pfn_doeNativeRenderBundleEncoderSetBindGroup(enc, index, bg, 0, NULL);
    return NULL;
}

napi_value doe_render_bundle_encoder_set_immediates(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 3);
    if (!pfn_doeNativeRenderBundleEncoderSetImmediates) NAPI_THROW(env, "renderBundleEncoderSetImmediates not available");
    void* enc = unwrap_ptr(env, _args[0]); if (!enc) NAPI_THROW(env, "Invalid render bundle encoder");
    uint32_t index = 0; napi_get_value_uint32(env, _args[1], &index);
    void* data_ptr = NULL;
    size_t data_len = 0;
    extract_buffer_data(env, _args[2], &data_ptr, &data_len);
    pfn_doeNativeRenderBundleEncoderSetImmediates(enc, index, (const uint8_t*)data_ptr, data_len);
    return NULL;
}

napi_value doe_render_bundle_encoder_set_vertex_buffer(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 5);
    void* enc = unwrap_ptr(env, _args[0]); if (!enc) return NULL;
    uint32_t slot = 0; napi_get_value_uint32(env, _args[1], &slot);
    void* buf = unwrap_ptr(env, _args[2]); if (!buf) return NULL;
    int64_t offset = 0; napi_get_value_int64(env, _args[3], &offset);
    int64_t size   = 0; napi_get_value_int64(env, _args[4], &size);
    if (pfn_doeNativeRenderBundleEncoderSetVertexBuffer)
        pfn_doeNativeRenderBundleEncoderSetVertexBuffer(enc, slot, buf, (uint64_t)offset, (uint64_t)size);
    return NULL;
}

napi_value doe_render_bundle_encoder_set_index_buffer(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 5);
    void* enc = unwrap_ptr(env, _args[0]); if (!enc) return NULL;
    void* buf = unwrap_ptr(env, _args[1]); if (!buf) return NULL;
    uint32_t format = index_format_from_value(env, _args[2]);
    int64_t offset = 0; napi_get_value_int64(env, _args[3], &offset);
    int64_t size   = 0; napi_get_value_int64(env, _args[4], &size);
    if (pfn_doeNativeRenderBundleEncoderSetIndexBuffer)
        pfn_doeNativeRenderBundleEncoderSetIndexBuffer(enc, buf, format, (uint64_t)offset, (uint64_t)size);
    return NULL;
}

napi_value doe_render_bundle_encoder_draw(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 5);
    void* enc = unwrap_ptr(env, _args[0]); if (!enc) return NULL;
    uint32_t vertex_count = 0, instance_count = 1, first_vertex = 0, first_instance = 0;
    napi_get_value_uint32(env, _args[1], &vertex_count); napi_get_value_uint32(env, _args[2], &instance_count);
    napi_get_value_uint32(env, _args[3], &first_vertex); napi_get_value_uint32(env, _args[4], &first_instance);
    if (pfn_doeNativeRenderBundleEncoderDraw)
        pfn_doeNativeRenderBundleEncoderDraw(enc, vertex_count, instance_count, first_vertex, first_instance);
    return NULL;
}

napi_value doe_render_bundle_encoder_draw_indexed(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 6);
    void* enc = unwrap_ptr(env, _args[0]); if (!enc) return NULL;
    uint32_t index_count = 0, instance_count = 1, first_index = 0; int32_t base_vertex = 0; uint32_t first_instance = 0;
    napi_get_value_uint32(env, _args[1], &index_count); napi_get_value_uint32(env, _args[2], &instance_count);
    napi_get_value_uint32(env, _args[3], &first_index);
    napi_valuetype bv_type; napi_typeof(env, _args[4], &bv_type);
    if (bv_type == napi_number) { int64_t bv = 0; napi_get_value_int64(env, _args[4], &bv); base_vertex = (int32_t)bv; }
    napi_get_value_uint32(env, _args[5], &first_instance);
    if (pfn_doeNativeRenderBundleEncoderDrawIndexed)
        pfn_doeNativeRenderBundleEncoderDrawIndexed(enc, index_count, instance_count, first_index, base_vertex, first_instance);
    return NULL;
}

napi_value doe_render_bundle_encoder_push_debug_group(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 2);
    void* enc = unwrap_ptr(env, _args[0]); if (!enc || !pfn_doeNativeRenderBundleEncoderPushDebugGroup) return NULL;
    size_t label_len = 0;
    napi_get_value_string_utf8(env, _args[1], NULL, 0, &label_len);
    char* label = (char*)malloc(label_len + 1); if (!label) return NULL;
    napi_get_value_string_utf8(env, _args[1], label, label_len + 1, &label_len);
    pfn_doeNativeRenderBundleEncoderPushDebugGroup(enc, label, label_len);
    free(label); return NULL;
}

napi_value doe_render_bundle_encoder_pop_debug_group(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    void* enc = unwrap_ptr(env, _args[0]); if (!enc || !pfn_doeNativeRenderBundleEncoderPopDebugGroup) return NULL;
    pfn_doeNativeRenderBundleEncoderPopDebugGroup(enc);
    return NULL;
}

napi_value doe_render_bundle_encoder_insert_debug_marker(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 2);
    void* enc = unwrap_ptr(env, _args[0]); if (!enc || !pfn_doeNativeRenderBundleEncoderInsertDebugMarker) return NULL;
    size_t label_len = 0;
    napi_get_value_string_utf8(env, _args[1], NULL, 0, &label_len);
    char* label = (char*)malloc(label_len + 1); if (!label) return NULL;
    napi_get_value_string_utf8(env, _args[1], label, label_len + 1, &label_len);
    pfn_doeNativeRenderBundleEncoderInsertDebugMarker(enc, label, label_len);
    free(label); return NULL;
}

napi_value doe_render_bundle_encoder_finish(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    CHECK_LIB_LOADED(env);
    if (!pfn_doeNativeRenderBundleEncoderFinish) NAPI_THROW(env, "doeNativeRenderBundleEncoderFinish not available");
    void* enc = unwrap_ptr(env, _args[0]);
    if (!enc) NAPI_THROW(env, "renderBundleEncoderFinish: invalid encoder");
    void* bundle = pfn_doeNativeRenderBundleEncoderFinish(enc, NULL);
    if (!bundle) NAPI_THROW(env, "renderBundleEncoderFinish failed");
    return wrap_ptr(env, bundle);
}

napi_value doe_render_bundle_encoder_release(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    void* enc = unwrap_ptr(env, _args[0]);
    if (enc && pfn_doeNativeRenderBundleEncoderRelease) pfn_doeNativeRenderBundleEncoderRelease(enc);
    return NULL;
}

napi_value doe_render_bundle_release(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    void* bundle = unwrap_ptr(env, _args[0]);
    if (bundle && pfn_doeNativeRenderBundleRelease) pfn_doeNativeRenderBundleRelease(bundle);
    return NULL;
}
