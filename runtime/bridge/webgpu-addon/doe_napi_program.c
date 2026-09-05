#include "doe_napi_internal.h"

napi_value doe_compute_program_supported(napi_env env, napi_callback_info info) {
    (void)info;
    CHECK_LIB_LOADED(env);
    uint32_t (*supported)(void) = (uint32_t (*)(void))LIB_SYM(g_lib, "doeNativeComputeProgramSupported");
    napi_value result;
    napi_get_boolean(env, supported && supported() != 0, &result);
    return result;
}

napi_value doe_compute_program_prepare(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 2);
    CHECK_LIB_LOADED(env);
    void* (*prepare)(void*, void*) = (void* (*)(void*, void*))LIB_SYM(g_lib, "doeNativeComputeProgramPrepare");
    if (!prepare) NAPI_THROW(env, "DOE_PROGRAM_UNSUPPORTED: rebuild the native library for GPU-recorded programs");
    void* queue = unwrap_ptr(env, _args[0]);
    void* commands = unwrap_ptr(env, _args[1]);
    if (!queue || !commands) NAPI_THROW(env, "DOE_PROGRAM_INVALID: expected live queue and command recording");
    void* program = prepare(queue, commands);
    if (!program) NAPI_THROW(env, "DOE_PROGRAM_GPU: GPU program preparation failed; requires Vulkan buffer compute on the selected device");
    return wrap_ptr(env, program);
}

napi_value doe_compute_program_submit(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    CHECK_LIB_LOADED(env);
    uint32_t (*submit)(void*) = (uint32_t (*)(void*))LIB_SYM(g_lib, "doeNativeComputeProgramSubmit");
    void* program = unwrap_ptr(env, _args[0]);
    if (!submit || !program) NAPI_THROW(env, "DOE_PROGRAM_INVALIDATED: GPU recording is unavailable");
    if (!submit(program)) NAPI_THROW(env, "DOE_PROGRAM_INVALIDATED: GPU recording resources or submission failed");
    return NULL;
}

napi_value doe_compute_program_release(napi_env env, napi_callback_info info) {
    NAPI_ASSERT_ARGC(env, info, 1);
    CHECK_LIB_LOADED(env);
    void (*release)(void*) = (void (*)(void*))LIB_SYM(g_lib, "doeNativeComputeProgramRelease");
    void* program = unwrap_ptr(env, _args[0]);
    if (!release || !program) NAPI_THROW(env, "DOE_PROGRAM_INVALIDATED: GPU recording is unavailable");
    release(program);
    return NULL;
}
