#include "doe_napi_internal.h"

#define DOE_STACK_WGSL_SOURCE_BYTES 16384

/* ================================================================
 * Shader Module
 * ================================================================ */

napi_value doe_create_shader_module(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value argv[4];
    if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok) {
        NAPI_THROW(env, "napi_get_cb_info failed");
    }
    if (argc < 2) NAPI_THROW(env, "createShaderModule requires a device and WGSL source");
    CHECK_LIB_LOADED(env);
    WGPUDevice device = unwrap_ptr(env, argv[0]);
    if (!device) NAPI_THROW(env, "Invalid device");

    /* argv[1] is the WGSL source code string */
    size_t code_len = 0;
    napi_get_value_string_utf8(env, argv[1], NULL, 0, &code_len);
    char code_stack[DOE_STACK_WGSL_SOURCE_BYTES + 1];
    bool code_on_heap = code_len > DOE_STACK_WGSL_SOURCE_BYTES;
    char* code = code_on_heap ? (char*)malloc(code_len + 1) : code_stack;
    if (!code) NAPI_THROW(env, "createShaderModule: out of memory");
    napi_get_value_string_utf8(env, argv[1], code, code_len + 1, &code_len);

    /* argv[2] is the optional compilationHints array */
    WGPUShaderModuleCompilationHint* hints = NULL;
    char** hint_entry_points = NULL;
    size_t hint_count = 0;

    if (argc > 2) {
        napi_valuetype hints_type;
        napi_typeof(env, argv[2], &hints_type);
        bool is_array = false;
        if (hints_type == napi_object) {
            napi_is_array(env, argv[2], &is_array);
        }
        if (is_array) {
            uint32_t arr_len = 0;
            napi_get_array_length(env, argv[2], &arr_len);
            if (arr_len > 0) {
                hint_count = arr_len;
                hints = (WGPUShaderModuleCompilationHint*)calloc(hint_count, sizeof(WGPUShaderModuleCompilationHint));
                hint_entry_points = (char**)calloc(hint_count, sizeof(char*));
                if (!hints || !hint_entry_points) {
                    if (code_on_heap) free(code);
                    free(hints);
                    free(hint_entry_points);
                    NAPI_THROW(env, "createShaderModule: out of memory while parsing compilationHints");
                }
                for (uint32_t i = 0; i < arr_len; i++) {
                    napi_value hint_obj;
                    napi_get_element(env, argv[2], i, &hint_obj);

                    /* Read entryPoint string */
                    napi_value ep_val;
                    if (napi_get_named_property(env, hint_obj, "entryPoint", &ep_val) == napi_ok) {
                        napi_valuetype ep_type;
                        napi_typeof(env, ep_val, &ep_type);
                        if (ep_type == napi_string) {
                            size_t ep_len = 0;
                            napi_get_value_string_utf8(env, ep_val, NULL, 0, &ep_len);
                            hint_entry_points[i] = (char*)malloc(ep_len + 1);
                            if (!hint_entry_points[i]) {
                                if (code_on_heap) free(code);
                                for (uint32_t j = 0; j < i; j++) free(hint_entry_points[j]);
                                free(hint_entry_points);
                                free(hints);
                                NAPI_THROW(env, "createShaderModule: out of memory while parsing compilationHints");
                            }
                            napi_get_value_string_utf8(env, ep_val, hint_entry_points[i], ep_len + 1, &ep_len);
                            hints[i].entryPoint.data = hint_entry_points[i];
                            hints[i].entryPoint.length = ep_len;
                        }
                    }

                    /* Read layout — pipeline layout handle or "auto" (NULL) */
                    napi_value layout_val;
                    if (napi_get_named_property(env, hint_obj, "layout", &layout_val) == napi_ok) {
                        napi_valuetype layout_type;
                        napi_typeof(env, layout_val, &layout_type);
                        if (layout_type == napi_string) {
                            /* "auto" → NULL layout */
                            hints[i].layout = NULL;
                        } else if (layout_type == napi_external || layout_type == napi_object) {
                            hints[i].layout = unwrap_ptr(env, layout_val);
                        }
                    }
                }
            }
        }
    }

    WGPUShaderSourceWGSL wgsl_source = {
        .chain = { .next = NULL, .sType = WGPU_STYPE_SHADER_SOURCE_WGSL },
        .code = { .data = code, .length = code_len },
    };
    char* label_str = NULL;
    size_t label_len = 0;
    if (argc > 3) {
        napi_valuetype label_type = napi_undefined;
        if (napi_typeof(env, argv[3], &label_type) == napi_ok && label_type == napi_string) {
            label_str = dup_string_value(env, argv[3], &label_len);
            if (!label_str) {
                if (code_on_heap) free(code);
                for (size_t i = 0; i < hint_count; i++) free(hint_entry_points[i]);
                free(hint_entry_points);
                free(hints);
                NAPI_THROW(env, "createShaderModule: out of memory while parsing label");
            }
        }
    }
    WGPUShaderModuleDescriptor desc = {
        .nextInChain = (void*)&wgsl_source,
        .label = { .data = label_str, .length = label_str ? label_len : 0 },
        .compilationHintCount = hint_count,
        .compilationHints = hints,
    };

    WGPUShaderModule mod = pfn_wgpuDeviceCreateShaderModule(device, &desc);
    free(label_str);
    if (code_on_heap) free(code);
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
            napi_throw_error(env, "DOE_SHADER_MODULE_ERROR", "createShaderModule failed (WGSL translation or compilation error)");
        }
        return NULL;
    }
    return wrap_ptr(env, mod);
}

napi_value doe_check_shader_source(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    CHECK_LIB_LOADED(env);
    napi_valuetype value_type;
    if (napi_typeof(env, _args[0], &value_type) != napi_ok || value_type != napi_string) {
        NAPI_THROW(env, "checkShaderSource requires a WGSL source string");
    }
    napi_value result;
    napi_create_object(env, &result);
    if (!pfn_doeNativeCheckShaderSource) {
        napi_value ok;
        napi_get_boolean(env, true, &ok);
        napi_set_named_property(env, result, "ok", ok);
        return result;
    }

    size_t code_len = 0;
    napi_get_value_string_utf8(env, _args[0], NULL, 0, &code_len);
    char* code = (char*)malloc(code_len + 1);
    if (!code) NAPI_THROW(env, "checkShaderSource: out of memory");
    napi_get_value_string_utf8(env, _args[0], code, code_len + 1, &code_len);

    const uint32_t ok_status = pfn_doeNativeCheckShaderSource(code, code_len);
    free(code);

    napi_value ok;
    napi_get_boolean(env, ok_status != 0, &ok);
    napi_set_named_property(env, result, "ok", ok);
    if (ok_status != 0) return result;

    char message[DOE_ERROR_BUF_CAP];
    char stage[64];
    char kind[64];
    copy_library_error_message(message, sizeof(message));
    copy_library_error_meta(pfn_doeNativeCopyLastErrorStage, stage, sizeof(stage));
    copy_library_error_meta(pfn_doeNativeCopyLastErrorKind, kind, sizeof(kind));

    napi_value message_val;
    napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &message_val);
    napi_set_named_property(env, result, "message", message_val);
    if (stage[0] != '\0') {
        napi_value stage_val;
        napi_create_string_utf8(env, stage, NAPI_AUTO_LENGTH, &stage_val);
        napi_set_named_property(env, result, "stage", stage_val);
    }
    if (kind[0] != '\0') {
        napi_value kind_val;
        napi_create_string_utf8(env, kind, NAPI_AUTO_LENGTH, &kind_val);
        napi_set_named_property(env, result, "kind", kind_val);
    }
    if (pfn_doeNativeGetLastErrorLine) {
        uint32_t line = pfn_doeNativeGetLastErrorLine();
        if (line > 0) {
            napi_value line_val;
            napi_create_uint32(env, line, &line_val);
            napi_set_named_property(env, result, "line", line_val);
        }
    }
    if (pfn_doeNativeGetLastErrorColumn) {
        uint32_t col = pfn_doeNativeGetLastErrorColumn();
        if (col > 0) {
            napi_value col_val;
            napi_create_uint32(env, col, &col_val);
            napi_set_named_property(env, result, "column", col_val);
        }
    }
    return result;
}

napi_value doe_shader_module_release(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    void* mod = unwrap_ptr(env, _args[0]);
    if (mod) pfn_wgpuShaderModuleRelease(mod);
    return NULL;
}

const char* doe_binding_kind_name(uint32_t kind) {
    switch (kind) {
        case 0: return "buffer";
        case 1: return "sampler";
        case 2: return "texture";
        case 3: return "storage_texture";
        default: return "unknown";
    }
}

const char* doe_binding_space_name(uint32_t addr_space) {
    switch (addr_space) {
        case 0: return "function";
        case 1: return "private";
        case 2: return "workgroup";
        case 3: return "uniform";
        case 4: return "storage";
        case 5: return "handle";
        default: return "unknown";
    }
}

const char* doe_binding_access_name(uint32_t access) {
    switch (access) {
        case 0: return "read";
        case 1: return "write";
        case 2: return "read_write";
        default: return "unknown";
    }
}

/* ================================================================
 * Compilation info
 * ================================================================ */

void ensure_compilation_message_fields(napi_env env, napi_value msg) {
    /* Ensure lineNum (uint32, default 0) */
    bool has_line_num = false;
    napi_has_named_property(env, msg, "lineNum", &has_line_num);
    if (!has_line_num) {
        napi_value zero;
        napi_create_uint32(env, 0, &zero);
        napi_set_named_property(env, msg, "lineNum", zero);
    }

    /* Ensure linePos (uint32, default 0) */
    bool has_line_pos = false;
    napi_has_named_property(env, msg, "linePos", &has_line_pos);
    if (!has_line_pos) {
        napi_value zero;
        napi_create_uint32(env, 0, &zero);
        napi_set_named_property(env, msg, "linePos", zero);
    }

    /* Ensure offset (uint64 via double, default 0) */
    bool has_offset = false;
    napi_has_named_property(env, msg, "offset", &has_offset);
    if (!has_offset) {
        napi_value zero;
        napi_create_int64(env, 0, &zero);
        napi_set_named_property(env, msg, "offset", zero);
    }

    /* Ensure length (uint64 via double, default 0) */
    bool has_length = false;
    napi_has_named_property(env, msg, "length", &has_length);
    if (!has_length) {
        napi_value zero;
        napi_create_int64(env, 0, &zero);
        napi_set_named_property(env, msg, "length", zero);
    }

    /* Ensure type (string: "error", "warning", "info"; default "error") */
    bool has_type = false;
    napi_has_named_property(env, msg, "type", &has_type);
    if (!has_type) {
        napi_value type_val;
        napi_create_string_utf8(env, "error", NAPI_AUTO_LENGTH, &type_val);
        napi_set_named_property(env, msg, "type", type_val);
    }
}

napi_value doe_shader_module_get_compilation_info(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    CHECK_LIB_LOADED(env);
    void* shader_module = unwrap_ptr(env, _args[0]);

    const char* json_str = "[]";
    if (pfn_doeNativeShaderModuleGetCompilationInfo) {
        const char* native_json = pfn_doeNativeShaderModuleGetCompilationInfo(shader_module);
        if (native_json) json_str = native_json;
    }

    /* Parse the JSON array from the native layer */
    napi_value global, json_obj, json_parse_fn, json_str_val, parse_args[1], parsed;
    napi_get_global(env, &global);
    napi_get_named_property(env, global, "JSON", &json_obj);
    napi_get_named_property(env, json_obj, "parse", &json_parse_fn);
    napi_create_string_utf8(env, json_str, NAPI_AUTO_LENGTH, &json_str_val);
    parse_args[0] = json_str_val;

    napi_value messages;
    if (napi_call_function(env, json_obj, json_parse_fn, 1, parse_args, &parsed) != napi_ok) {
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
 * Bindings
 * ================================================================ */

napi_value doe_shader_module_get_bindings(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    WGPUShaderModule shader_module = unwrap_ptr(env, _args[0]);
    if (!shader_module) NAPI_THROW(env, "shaderModuleGetBindings: null shader module");
    if (!pfn_doeNativeShaderModuleGetBindings) NAPI_THROW(env, "shaderModuleGetBindings: native binding metadata not available");

    DoeShaderBindingInfo bindings[16];
    size_t count = pfn_doeNativeShaderModuleGetBindings(shader_module, bindings, 16);

    napi_value array;
    napi_create_array_with_length(env, count, &array);
    for (size_t i = 0; i < count; i++) {
        napi_value entry;
        napi_create_object(env, &entry);

        napi_value group, binding, kind, space, access;
        napi_create_uint32(env, bindings[i].group, &group);
        napi_create_uint32(env, bindings[i].binding, &binding);
        napi_create_string_utf8(env, doe_binding_kind_name(bindings[i].kind), NAPI_AUTO_LENGTH, &kind);
        napi_create_string_utf8(env, doe_binding_space_name(bindings[i].addr_space), NAPI_AUTO_LENGTH, &space);
        napi_create_string_utf8(env, doe_binding_access_name(bindings[i].access), NAPI_AUTO_LENGTH, &access);

        napi_set_named_property(env, entry, "group", group);
        napi_set_named_property(env, entry, "binding", binding);
        napi_set_named_property(env, entry, "type", kind);
        napi_set_named_property(env, entry, "space", space);
        napi_set_named_property(env, entry, "access", access);
        napi_set_element(env, array, i, entry);
    }

    return array;
}

napi_value doe_shader_module_get_bindings_for_entry_point(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 2);
    WGPUShaderModule shader_module = unwrap_ptr(env, _args[0]);
    if (!shader_module) NAPI_THROW(env, "shaderModuleGetBindingsForEntryPoint: null shader module");
    if (!pfn_doeNativeShaderModuleGetBindingsForEntryPoint) {
        NAPI_THROW(env, "shaderModuleGetBindingsForEntryPoint: native entry-point binding metadata not available");
    }
    size_t entry_len = 0;
    napi_get_value_string_utf8(env, _args[1], NULL, 0, &entry_len);
    char* entry_point = (char*)malloc(entry_len + 1);
    if (!entry_point) NAPI_THROW(env, "shaderModuleGetBindingsForEntryPoint: out of memory");
    napi_get_value_string_utf8(env, _args[1], entry_point, entry_len + 1, &entry_len);

    DoeShaderBindingInfo bindings[16];
    size_t count = pfn_doeNativeShaderModuleGetBindingsForEntryPoint(
        shader_module, entry_point, entry_len, bindings, 16);
    free(entry_point);
    napi_value array;
    napi_create_array_with_length(env, count, &array);
    for (size_t i = 0; i < count; i++) {
        napi_value entry;
        napi_create_object(env, &entry);
        napi_value group, binding, kind, space, access;
        napi_create_uint32(env, bindings[i].group, &group);
        napi_create_uint32(env, bindings[i].binding, &binding);
        napi_create_string_utf8(env, doe_binding_kind_name(bindings[i].kind), NAPI_AUTO_LENGTH, &kind);
        napi_create_string_utf8(env, doe_binding_space_name(bindings[i].addr_space), NAPI_AUTO_LENGTH, &space);
        napi_create_string_utf8(env, doe_binding_access_name(bindings[i].access), NAPI_AUTO_LENGTH, &access);
        napi_set_named_property(env, entry, "group", group);
        napi_set_named_property(env, entry, "binding", binding);
        napi_set_named_property(env, entry, "type", kind);
        napi_set_named_property(env, entry, "space", space);
        napi_set_named_property(env, entry, "access", access);
        napi_set_element(env, array, i, entry);
    }
    return array;
}
