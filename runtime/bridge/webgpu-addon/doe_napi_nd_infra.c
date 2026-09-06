#include "doe_napi_internal.h"

/* String values match WGPUPowerPreference enums in the local addon ABI. */
#define DOE_NATIVE_DIRECT_POWER_PREFERENCE_LOW_POWER 1
#define DOE_NATIVE_DIRECT_POWER_PREFERENCE_HIGH_PERFORMANCE 2
#define DOE_NATIVE_DIRECT_FEATURE_LEVEL_COMPATIBILITY 1
#define DOE_NATIVE_DIRECT_FEATURE_LEVEL_CORE 2

napi_value native_direct_resolved_promise(napi_env env, napi_value value) {
    napi_deferred deferred;
    napi_value promise;
    napi_create_promise(env, &deferred, &promise);
    napi_resolve_deferred(env, deferred, value);
    return promise;
}

napi_value native_direct_resolved_undefined_promise(napi_env env) {
    napi_value promise;
    if (native_direct_resolved_undefined_promise_ref) {
        napi_get_reference_value(env, native_direct_resolved_undefined_promise_ref, &promise);
        return promise;
    }
    napi_value undefined_value;
    napi_get_undefined(env, &undefined_value);
    promise = native_direct_resolved_promise(env, undefined_value);
    napi_create_reference(env, promise, 1, &native_direct_resolved_undefined_promise_ref);
    return promise;
}

void native_direct_set_external_prop(napi_env env, napi_value obj, const char* key, void* ptr) {
    napi_value value;
    if (ptr) {
        napi_create_external(env, ptr, NULL, NULL, &value);
    } else {
        napi_get_null(env, &value);
    }
    napi_set_named_property(env, obj, key, value);
}

void native_direct_set_object_prop(napi_env env, napi_value obj, const char* key, napi_value value) {
    napi_set_named_property(env, obj, key, value);
}

void native_direct_set_uint32_prop(napi_env env, napi_value obj, const char* key, uint32_t value) {
    napi_value prop;
    napi_create_uint32(env, value, &prop);
    napi_set_named_property(env, obj, key, prop);
}

void native_direct_set_double_prop(napi_env env, napi_value obj, const char* key, double value) {
    napi_value prop;
    napi_create_double(env, value, &prop);
    napi_set_named_property(env, obj, key, prop);
}

double native_direct_elapsed_ms(uint64_t started_ns) {
    const uint64_t ended_ns = monotonic_now_ns();
    if (ended_ns <= started_ns) return 0.0;
    return (double)(ended_ns - started_ns) / 1000000.0;
}

void* native_direct_unwrap_external_prop(napi_env env, napi_value obj, const char* key) {
    if (!has_prop(env, obj, key)) return NULL;
    napi_value value = get_prop(env, obj, key);
    napi_valuetype vt;
    napi_typeof(env, value, &vt);
    if (vt != napi_external) return NULL;
    return unwrap_ptr(env, value);
}

uint32_t native_direct_get_uint32_prop(napi_env env, napi_value obj, const char* key) {
    if (!has_prop(env, obj, key)) return 0;
    return get_uint32_prop(env, obj, key);
}

bool native_direct_queue_has_pending(napi_env env, napi_value queue_obj) {
    NativeDirectQueueCache* cache = native_direct_get_queue_cache(env, queue_obj);
    if (cache) return cache->completed_serial < cache->submitted_serial;
    uint32_t submitted = native_direct_get_uint32_prop(env, queue_obj, DOE_DIRECT_SUBMITTED_SERIAL);
    uint32_t completed = native_direct_get_uint32_prop(env, queue_obj, DOE_DIRECT_COMPLETED_SERIAL);
    return completed < submitted;
}

void native_direct_queue_mark_submitted(napi_env env, napi_value queue_obj) {
    NativeDirectQueueCache* cache = native_direct_get_queue_cache(env, queue_obj);
    if (cache) {
        cache->submitted_serial += 1;
        return;
    }
    uint32_t submitted = native_direct_get_uint32_prop(env, queue_obj, DOE_DIRECT_SUBMITTED_SERIAL);
    native_direct_set_uint32_prop(env, queue_obj, DOE_DIRECT_SUBMITTED_SERIAL, submitted + 1);
}

void native_direct_queue_mark_done(napi_env env, napi_value queue_obj) {
    NativeDirectQueueCache* cache = native_direct_get_queue_cache(env, queue_obj);
    if (cache) {
        cache->completed_serial = cache->submitted_serial;
        return;
    }
    uint32_t submitted = native_direct_get_uint32_prop(env, queue_obj, DOE_DIRECT_SUBMITTED_SERIAL);
    native_direct_set_uint32_prop(env, queue_obj, DOE_DIRECT_COMPLETED_SERIAL, submitted);
}

napi_value native_direct_create_empty_set(napi_env env) {
    napi_value global;
    napi_value ctor;
    napi_value result;
    napi_get_global(env, &global);
    napi_get_named_property(env, global, "Set", &ctor);
    napi_new_instance(env, ctor, 0, NULL, &result);
    return result;
}

napi_value native_direct_create_empty_object(napi_env env) {
    napi_value obj;
    napi_create_object(env, &obj);
    return obj;
}

void native_direct_add_cached_method(
    napi_env env,
    napi_value obj,
    const char* name,
    napi_callback fn,
    napi_ref* method_ref
) {
    napi_value method;
    if (*method_ref) {
        napi_get_reference_value(env, *method_ref, &method);
    } else {
        napi_create_function(env, name, NAPI_AUTO_LENGTH, fn, NULL, &method);
        napi_create_reference(env, method, 1, method_ref);
    }
    napi_set_named_property(env, obj, name, method);
}

static void native_direct_handle_cache_finalize(napi_env env, void* data, void* hint) {
    (void)env;
    (void)hint;
    if (data) free(data);
}

static void native_direct_queue_cache_finalize(napi_env env, void* data, void* hint) {
    (void)env;
    (void)hint;
    if (data) free(data);
}

static void native_direct_buffer_cache_finalize(napi_env env, void* data, void* hint) {
    NativeDirectBufferCache* cache = (NativeDirectBufferCache*)data;
    (void)hint;
    if (!cache) return;
    if (cache->queue_ref) napi_delete_reference(env, cache->queue_ref);
    if (cache->mapped_range_ref) napi_delete_reference(env, cache->mapped_range_ref);
    free(cache);
}

void native_direct_wrap_handle_cache(napi_env env, napi_value obj, WGPUInstance instance, void* native) {
    NativeDirectHandleCache* cache = (NativeDirectHandleCache*)calloc(1, sizeof(NativeDirectHandleCache));
    if (!cache) {
        napi_throw_error(env, "DOE_ERROR", "nativeDirect: out of memory");
        return;
    }
    cache->instance = instance;
    cache->native = native;
    napi_wrap(env, obj, cache, native_direct_handle_cache_finalize, NULL, NULL);
}

void native_direct_wrap_queue_cache(napi_env env, napi_value obj, WGPUInstance instance, WGPUQueue queue) {
    NativeDirectQueueCache* cache = (NativeDirectQueueCache*)calloc(1, sizeof(NativeDirectQueueCache));
    if (!cache) {
        napi_throw_error(env, "DOE_ERROR", "nativeDirect: out of memory");
        return;
    }
    cache->instance = instance;
    cache->queue = queue;
    napi_wrap(env, obj, cache, native_direct_queue_cache_finalize, NULL, NULL);
}

void native_direct_wrap_buffer_cache(
    napi_env env,
    napi_value obj,
    WGPUInstance instance,
    WGPUBuffer buffer,
    uint64_t size,
    uint64_t usage,
    napi_value queue_obj
) {
    NativeDirectBufferCache* cache = (NativeDirectBufferCache*)calloc(1, sizeof(NativeDirectBufferCache));
    if (!cache) {
        napi_throw_error(env, "DOE_ERROR", "nativeDirect: out of memory");
        return;
    }
    cache->instance = instance;
    cache->buffer = buffer;
    cache->size = size;
    cache->usage = usage;
    napi_create_reference(env, queue_obj, 1, &cache->queue_ref);
    napi_wrap(env, obj, cache, native_direct_buffer_cache_finalize, NULL, NULL);
}

NativeDirectHandleCache* native_direct_get_handle_cache(napi_env env, napi_value obj) {
    NativeDirectHandleCache* cache = NULL;
    napi_unwrap(env, obj, (void**)&cache);
    return cache;
}

NativeDirectQueueCache* native_direct_get_queue_cache(napi_env env, napi_value obj) {
    NativeDirectQueueCache* cache = NULL;
    napi_unwrap(env, obj, (void**)&cache);
    return cache;
}

NativeDirectBufferCache* native_direct_get_buffer_cache(napi_env env, napi_value obj) {
    NativeDirectBufferCache* cache = NULL;
    napi_unwrap(env, obj, (void**)&cache);
    return cache;
}

void native_direct_invalidate_buffer_mapped_range_cache(napi_env env, NativeDirectBufferCache* cache) {
    if (!cache) return;
    if (cache->mapped_range_ref) {
        napi_value range;
        if (napi_get_reference_value(env, cache->mapped_range_ref, &range) == napi_ok) {
            napi_detach_arraybuffer(env, range);
        }
        napi_delete_reference(env, cache->mapped_range_ref);
        cache->mapped_range_ref = NULL;
    }
    cache->mapped_offset = 0;
    cache->mapped_size = 0;
    cache->mapped_ptr = NULL;
}

WGPUAdapter native_direct_request_adapter_sync(napi_env env, WGPUInstance inst, napi_value options) {
    if (!inst) NAPI_THROW(env, "nativeDirect.requestAdapter requires instance");

    WGPURequestAdapterOptions opts;
    memset(&opts, 0, sizeof(opts));
    const WGPURequestAdapterOptions* opts_ptr = NULL;

    if (options != NULL) {
        napi_valuetype vt = napi_undefined;
        napi_typeof(env, options, &vt);
        if (vt == napi_object) {
            napi_valuetype feature_level_type = napi_undefined;
            napi_value feature_level_val;
            if (napi_get_named_property(env, options, "featureLevel", &feature_level_val) == napi_ok) {
                napi_typeof(env, feature_level_val, &feature_level_type);
            }
            if (feature_level_type == napi_string) {
                char feature_level_str[32];
                size_t feature_level_len = 0;
                napi_get_value_string_utf8(env, feature_level_val, feature_level_str, sizeof(feature_level_str), &feature_level_len);
                if (strcmp(feature_level_str, "compatibility") == 0) {
                    opts.featureLevel = DOE_NATIVE_DIRECT_FEATURE_LEVEL_COMPATIBILITY;
                } else if (strcmp(feature_level_str, "core") == 0) {
                    opts.featureLevel = DOE_NATIVE_DIRECT_FEATURE_LEVEL_CORE;
                }
            }
            napi_valuetype pp_type = napi_undefined;
            napi_value pp_val;
            if (napi_get_named_property(env, options, "powerPreference", &pp_val) == napi_ok) {
                napi_typeof(env, pp_val, &pp_type);
            }
            if (pp_type == napi_string) {
                char pp_str[32];
                size_t pp_len = 0;
                napi_get_value_string_utf8(env, pp_val, pp_str, sizeof(pp_str), &pp_len);
                if (strcmp(pp_str, "low-power") == 0) {
                    opts.powerPreference = DOE_NATIVE_DIRECT_POWER_PREFERENCE_LOW_POWER;
                } else if (strcmp(pp_str, "high-performance") == 0) {
                    opts.powerPreference = DOE_NATIVE_DIRECT_POWER_PREFERENCE_HIGH_PERFORMANCE;
                }
            }

            napi_value fl_val;
            napi_valuetype fl_type = napi_undefined;
            if (napi_get_named_property(env, options, "featureLevel", &fl_val) == napi_ok) {
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

            napi_value ffa_val;
            napi_valuetype ffa_type = napi_undefined;
            if (napi_get_named_property(env, options, "forceFallbackAdapter", &ffa_val) == napi_ok) {
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
    if (!process_events_until(inst, &result.done, current_timeout_ns())) {
        throw_status_error(env, "DOE_REQUEST_ADAPTER_TIMEOUT", "requestAdapter timed out", result.status, result.message);
        return NULL;
    }
    if (result.status != WGPU_REQUEST_STATUS_SUCCESS || !result.adapter) {
        throw_status_error(env, "DOE_REQUEST_ADAPTER_ERROR", "requestAdapter failed", result.status, result.message);
        return NULL;
    }
    return result.adapter;
}

WGPUDevice native_direct_request_device_sync(napi_env env, WGPUInstance inst, WGPUAdapter adapter) {
    if (!inst || !adapter) NAPI_THROW(env, "nativeDirect.requestDevice requires instance and adapter");

    DeviceRequestResult result = {0};
    const WGPURequestDeviceCallbackInfo cb_info = {
        .nextInChain = NULL,
        .mode = WGPU_CALLBACK_MODE_ALLOW_PROCESS_EVENTS,
        .callback = device_callback,
        .userdata1 = &result,
        .userdata2 = NULL,
    };

    WGPUFuture future = pfn_doeNativeAdapterRequestDevice
        ? pfn_doeNativeAdapterRequestDevice(adapter, NULL, cb_info)
        : pfn_wgpuAdapterRequestDevice(adapter, NULL, cb_info);
    if (future.id == 0) NAPI_THROW(env, "requestDevice future unavailable");
    if (!process_events_until(inst, &result.done, current_timeout_ns())) {
        throw_status_error(env, "DOE_REQUEST_DEVICE_TIMEOUT", "requestDevice timed out", result.status, result.message);
        return NULL;
    }
    if (result.status != WGPU_REQUEST_STATUS_SUCCESS || !result.device) {
        throw_status_error(env, "DOE_REQUEST_DEVICE_ERROR", "requestDevice failed", result.status, result.message);
        return NULL;
    }
    return result.device;
}

WGPULimits native_direct_query_adapter_limits(WGPUAdapter adapter, bool* ok) {
    WGPULimits limits;
    memset(&limits, 0, sizeof(limits));
    *ok = false;
    uint32_t (*fn)(WGPUAdapter, void*) = pfn_doeNativeAdapterGetLimits ? pfn_doeNativeAdapterGetLimits : pfn_wgpuAdapterGetLimits;
    if (!fn) return limits;
    *ok = fn(adapter, &limits) == WGPU_STATUS_SUCCESS;
    return limits;
}

WGPULimits native_direct_query_device_limits(WGPUDevice device, bool* ok) {
    WGPULimits limits;
    memset(&limits, 0, sizeof(limits));
    *ok = false;
    uint32_t (*fn)(WGPUDevice, void*) = pfn_doeNativeDeviceGetLimits ? pfn_doeNativeDeviceGetLimits : pfn_wgpuDeviceGetLimits;
    if (!fn) return limits;
    *ok = fn(device, &limits) == WGPU_STATUS_SUCCESS;
    return limits;
}
