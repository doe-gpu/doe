/*
 * doe_napi_formats.c — Texture format, primitive topology, vertex format,
 * and other WebGPU enum string↔uint32 converters.
 */
#include <node_api.h>
#include <stdint.h>
#include <string.h>
#include "../../zig/vendor/webgpu-headers/webgpu.h"

/* Texture / primitive format converters */

uint32_t texture_format_from_string(napi_env env, napi_value val) {
    napi_valuetype vt; napi_typeof(env, val, &vt);
    if (vt == napi_number) { uint32_t out = 0; napi_get_value_uint32(env, val, &out); return out; }
    if (vt != napi_string) return 0x00000016; /* rgba8unorm */
    char buf[32] = {0}; size_t len = 0;
    napi_get_value_string_utf8(env, val, buf, sizeof(buf), &len);
    if (strcmp(buf, "r8unorm") == 0)           return 0x00000001;
    if (strcmp(buf, "r8snorm") == 0)           return 0x00000002;
    if (strcmp(buf, "r8uint") == 0)            return 0x00000003;
    if (strcmp(buf, "r8sint") == 0)            return 0x00000004;
    if (strcmp(buf, "r16unorm") == 0)          return 0x00000005;
    if (strcmp(buf, "r16snorm") == 0)          return 0x00000006;
    if (strcmp(buf, "r16uint") == 0)           return 0x00000007;
    if (strcmp(buf, "r16sint") == 0)           return 0x00000008;
    if (strcmp(buf, "r16float") == 0)          return 0x00000009;
    if (strcmp(buf, "rg8unorm") == 0)          return 0x0000000A;
    if (strcmp(buf, "rg8snorm") == 0)          return 0x0000000B;
    if (strcmp(buf, "rg8uint") == 0)           return 0x0000000C;
    if (strcmp(buf, "rg8sint") == 0)           return 0x0000000D;
    if (strcmp(buf, "r32float") == 0)          return 0x0000000E;
    if (strcmp(buf, "r32uint") == 0)           return 0x0000000F;
    if (strcmp(buf, "r32sint") == 0)           return 0x00000010;
    if (strcmp(buf, "rg16unorm") == 0)         return 0x00000011;
    if (strcmp(buf, "rg16snorm") == 0)         return 0x00000012;
    if (strcmp(buf, "rg16uint") == 0)          return 0x00000013;
    if (strcmp(buf, "rg16sint") == 0)          return 0x00000014;
    if (strcmp(buf, "rg16float") == 0)         return 0x00000015;
    if (strcmp(buf, "rgba8unorm") == 0)        return 0x00000016;
    if (strcmp(buf, "rgba8unorm-srgb") == 0)   return 0x00000017;
    if (strcmp(buf, "rgba8snorm") == 0)        return 0x00000018;
    if (strcmp(buf, "rgba8uint") == 0)         return 0x00000019;
    if (strcmp(buf, "rgba8sint") == 0)         return 0x0000001A;
    if (strcmp(buf, "bgra8unorm") == 0)        return 0x0000001B;
    if (strcmp(buf, "bgra8unorm-srgb") == 0)   return 0x0000001C;
    if (strcmp(buf, "rgb10a2uint") == 0)       return 0x0000001D;
    if (strcmp(buf, "rgb10a2unorm") == 0)      return 0x0000001E;
    if (strcmp(buf, "rg11b10ufloat") == 0)     return 0x0000001F;
    if (strcmp(buf, "rgb9e5ufloat") == 0)      return 0x00000020;
    if (strcmp(buf, "rg32float") == 0)         return 0x00000021;
    if (strcmp(buf, "rg32uint") == 0)          return 0x00000022;
    if (strcmp(buf, "rg32sint") == 0)          return 0x00000023;
    if (strcmp(buf, "rgba16uint") == 0)        return 0x00000024;
    if (strcmp(buf, "rgba16sint") == 0)        return 0x00000025;
    if (strcmp(buf, "rgba16float") == 0)       return 0x00000026;
    if (strcmp(buf, "rgba32float") == 0)       return 0x00000027;
    if (strcmp(buf, "rgba32uint") == 0)        return 0x00000028;
    if (strcmp(buf, "rgba32sint") == 0)        return 0x00000029;
    if (strcmp(buf, "rgba16unorm") == 0)      return 0x0000002A;
    if (strcmp(buf, "rgba16snorm") == 0)      return 0x0000002B;
    if (strcmp(buf, "stencil8") == 0)          return 0x0000002C;
    if (strcmp(buf, "depth16unorm") == 0)      return 0x0000002D;
    if (strcmp(buf, "depth24plus") == 0)       return 0x0000002E;
    if (strcmp(buf, "depth24plus-stencil8") == 0) return 0x0000002F;
    if (strcmp(buf, "depth32float") == 0)      return 0x00000030;
    if (strcmp(buf, "depth32float-stencil8") == 0) return 0x00000031;
    /* BC compressed */
    if (strcmp(buf, "bc1-rgba-unorm") == 0)       return 0x00000032;
    if (strcmp(buf, "bc1-rgba-unorm-srgb") == 0)  return 0x00000033;
    if (strcmp(buf, "bc2-rgba-unorm") == 0)       return 0x00000034;
    if (strcmp(buf, "bc2-rgba-unorm-srgb") == 0)  return 0x00000035;
    if (strcmp(buf, "bc3-rgba-unorm") == 0)       return 0x00000036;
    if (strcmp(buf, "bc3-rgba-unorm-srgb") == 0)  return 0x00000037;
    if (strcmp(buf, "bc4-r-unorm") == 0)          return 0x00000038;
    if (strcmp(buf, "bc4-r-snorm") == 0)          return 0x00000039;
    if (strcmp(buf, "bc5-rg-unorm") == 0)         return 0x0000003A;
    if (strcmp(buf, "bc5-rg-snorm") == 0)         return 0x0000003B;
    if (strcmp(buf, "bc6h-rgb-ufloat") == 0)      return 0x0000003C;
    if (strcmp(buf, "bc6h-rgb-float") == 0)       return 0x0000003D;
    if (strcmp(buf, "bc7-rgba-unorm") == 0)       return 0x0000003E;
    if (strcmp(buf, "bc7-rgba-unorm-srgb") == 0)  return 0x0000003F;
    /* ETC2/EAC compressed */
    if (strcmp(buf, "etc2-rgb8unorm") == 0)        return 0x00000040;
    if (strcmp(buf, "etc2-rgb8unorm-srgb") == 0)   return 0x00000041;
    if (strcmp(buf, "etc2-rgb8a1unorm") == 0)      return 0x00000042;
    if (strcmp(buf, "etc2-rgb8a1unorm-srgb") == 0) return 0x00000043;
    if (strcmp(buf, "etc2-rgba8unorm") == 0)       return 0x00000044;
    if (strcmp(buf, "etc2-rgba8unorm-srgb") == 0)  return 0x00000045;
    if (strcmp(buf, "eac-r11unorm") == 0)          return 0x00000046;
    if (strcmp(buf, "eac-r11snorm") == 0)          return 0x00000047;
    if (strcmp(buf, "eac-rg11unorm") == 0)         return 0x00000048;
    if (strcmp(buf, "eac-rg11snorm") == 0)         return 0x00000049;
    /* ASTC compressed */
    if (strcmp(buf, "astc-4x4-unorm") == 0)        return 0x0000004A;
    if (strcmp(buf, "astc-4x4-unorm-srgb") == 0)   return 0x0000004B;
    if (strcmp(buf, "astc-5x4-unorm") == 0)        return 0x0000004C;
    if (strcmp(buf, "astc-5x4-unorm-srgb") == 0)   return 0x0000004D;
    if (strcmp(buf, "astc-5x5-unorm") == 0)        return 0x0000004E;
    if (strcmp(buf, "astc-5x5-unorm-srgb") == 0)   return 0x0000004F;
    if (strcmp(buf, "astc-6x5-unorm") == 0)        return 0x00000050;
    if (strcmp(buf, "astc-6x5-unorm-srgb") == 0)   return 0x00000051;
    if (strcmp(buf, "astc-6x6-unorm") == 0)        return 0x00000052;
    if (strcmp(buf, "astc-6x6-unorm-srgb") == 0)   return 0x00000053;
    if (strcmp(buf, "astc-8x5-unorm") == 0)        return 0x00000054;
    if (strcmp(buf, "astc-8x5-unorm-srgb") == 0)   return 0x00000055;
    if (strcmp(buf, "astc-8x6-unorm") == 0)        return 0x00000056;
    if (strcmp(buf, "astc-8x6-unorm-srgb") == 0)   return 0x00000057;
    if (strcmp(buf, "astc-8x8-unorm") == 0)        return 0x00000058;
    if (strcmp(buf, "astc-8x8-unorm-srgb") == 0)   return 0x00000059;
    if (strcmp(buf, "astc-10x5-unorm") == 0)       return 0x0000005A;
    if (strcmp(buf, "astc-10x5-unorm-srgb") == 0)  return 0x0000005B;
    if (strcmp(buf, "astc-10x6-unorm") == 0)       return 0x0000005C;
    if (strcmp(buf, "astc-10x6-unorm-srgb") == 0)  return 0x0000005D;
    if (strcmp(buf, "astc-10x8-unorm") == 0)       return 0x0000005E;
    if (strcmp(buf, "astc-10x8-unorm-srgb") == 0)  return 0x0000005F;
    if (strcmp(buf, "astc-10x10-unorm") == 0)      return 0x00000060;
    if (strcmp(buf, "astc-10x10-unorm-srgb") == 0) return 0x00000061;
    if (strcmp(buf, "astc-12x10-unorm") == 0)      return 0x00000062;
    if (strcmp(buf, "astc-12x10-unorm-srgb") == 0) return 0x00000063;
    if (strcmp(buf, "astc-12x12-unorm") == 0)      return 0x00000064;
    if (strcmp(buf, "astc-12x12-unorm-srgb") == 0) return 0x00000065;
    return 0x00000016;
}

const char* texture_format_u32_to_string(uint32_t fmt) {
    switch (fmt) {
        case 0x00000001: return "r8unorm";      case 0x00000002: return "r8snorm";
        case 0x00000003: return "r8uint";       case 0x00000004: return "r8sint";
        case 0x00000005: return "r16unorm";     case 0x00000006: return "r16snorm";
        case 0x00000007: return "r16uint";      case 0x00000008: return "r16sint";
        case 0x00000009: return "r16float";     case 0x0000000A: return "rg8unorm";
        case 0x0000000B: return "rg8snorm";     case 0x0000000C: return "rg8uint";
        case 0x0000000D: return "rg8sint";      case 0x0000000E: return "r32float";
        case 0x0000000F: return "r32uint";      case 0x00000010: return "r32sint";
        case 0x00000011: return "rg16unorm";    case 0x00000012: return "rg16snorm";
        case 0x00000013: return "rg16uint";     case 0x00000014: return "rg16sint";
        case 0x00000015: return "rg16float";    case 0x00000016: return "rgba8unorm";
        case 0x00000017: return "rgba8unorm-srgb"; case 0x00000018: return "rgba8snorm";
        case 0x00000019: return "rgba8uint";    case 0x0000001A: return "rgba8sint";
        case 0x0000001B: return "bgra8unorm";   case 0x0000001C: return "bgra8unorm-srgb";
        case 0x0000001D: return "rgb10a2uint";  case 0x0000001E: return "rgb10a2unorm";
        case 0x0000001F: return "rg11b10ufloat"; case 0x00000020: return "rgb9e5ufloat";
        case 0x00000021: return "rg32float";    case 0x00000022: return "rg32uint";
        case 0x00000023: return "rg32sint";     case 0x00000024: return "rgba16uint";
        case 0x00000025: return "rgba16sint";   case 0x00000026: return "rgba16float";
        case 0x00000027: return "rgba32float";  case 0x00000028: return "rgba32uint";
        case 0x00000029: return "rgba32sint";
        case 0x0000002A: return "rgba16unorm";  case 0x0000002B: return "rgba16snorm";
        case 0x0000002C: return "stencil8";
        case 0x0000002D: return "depth16unorm"; case 0x0000002E: return "depth24plus";
        case 0x0000002F: return "depth24plus-stencil8";
        case 0x00000030: return "depth32float"; case 0x00000031: return "depth32float-stencil8";
        default: return NULL;
    }
}

uint32_t primitive_topology_from_string(napi_env env, napi_value val) {
    napi_valuetype vt; napi_typeof(env, val, &vt);
    if (vt == napi_number) { uint32_t out = 0; napi_get_value_uint32(env, val, &out); return out; }
    char buf[32] = {0}; size_t len = 0;
    napi_get_value_string_utf8(env, val, buf, sizeof(buf), &len);
    if (strcmp(buf, "point-list") == 0)     return 0x00000001;
    if (strcmp(buf, "line-list") == 0)      return 0x00000002;
    if (strcmp(buf, "line-strip") == 0)     return 0x00000003;
    if (strcmp(buf, "triangle-list") == 0)  return 0x00000004;
    if (strcmp(buf, "triangle-strip") == 0) return 0x00000005;
    napi_throw_error(env, "DOE_ERROR", "Unsupported primitive topology");
    return 0;
}

uint32_t front_face_from_string(napi_env env, napi_value val) {
    napi_valuetype vt; napi_typeof(env, val, &vt);
    if (vt == napi_number) { uint32_t out = 0; napi_get_value_uint32(env, val, &out); return out; }
    char buf[16] = {0}; size_t len = 0;
    napi_get_value_string_utf8(env, val, buf, sizeof(buf), &len);
    if (strcmp(buf, "ccw") == 0) return 0x00000001;
    if (strcmp(buf, "cw") == 0)  return 0x00000002;
    napi_throw_error(env, "DOE_ERROR", "Unsupported frontFace"); return 0;
}

uint32_t cull_mode_from_string(napi_env env, napi_value val) {
    napi_valuetype vt; napi_typeof(env, val, &vt);
    if (vt == napi_number) { uint32_t out = 0; napi_get_value_uint32(env, val, &out); return out; }
    char buf[16] = {0}; size_t len = 0;
    napi_get_value_string_utf8(env, val, buf, sizeof(buf), &len);
    if (strcmp(buf, "none") == 0)  return 0x00000001;
    if (strcmp(buf, "front") == 0) return 0x00000002;
    if (strcmp(buf, "back") == 0)  return 0x00000003;
    napi_throw_error(env, "DOE_ERROR", "Unsupported cullMode"); return 0;
}

uint32_t filter_mode_from_string(napi_env env, napi_value val) {
    napi_valuetype vt; napi_typeof(env, val, &vt);
    if (vt != napi_string) return 0; /* nearest */
    char buf[16] = {0}; size_t len = 0;
    napi_get_value_string_utf8(env, val, buf, sizeof(buf), &len);
    if (strcmp(buf, "linear") == 0) return 1;
    return 0;
}

uint32_t address_mode_from_string(napi_env env, napi_value val) {
    napi_valuetype vt; napi_typeof(env, val, &vt);
    if (vt != napi_string) return 1; /* clamp-to-edge */
    char buf[24] = {0}; size_t len = 0;
    napi_get_value_string_utf8(env, val, buf, sizeof(buf), &len);
    if (strcmp(buf, "repeat") == 0)        return 2;
    if (strcmp(buf, "mirror-repeat") == 0) return 3;
    return 1;
}

uint32_t compare_func_from_value(napi_env env, napi_value val) {
    napi_valuetype vt; napi_typeof(env, val, &vt);
    if (vt == napi_number) { uint32_t out = 0; napi_get_value_uint32(env, val, &out); return out; }
    char buf[24] = {0}; size_t len = 0;
    napi_get_value_string_utf8(env, val, buf, sizeof(buf), &len);
    if (strcmp(buf, "never") == 0)        return 0x00000001;
    if (strcmp(buf, "less") == 0)         return 0x00000002;
    if (strcmp(buf, "equal") == 0)        return 0x00000003;
    if (strcmp(buf, "less-equal") == 0)   return 0x00000004;
    if (strcmp(buf, "greater") == 0)      return 0x00000005;
    if (strcmp(buf, "not-equal") == 0)    return 0x00000006;
    if (strcmp(buf, "greater-equal") == 0) return 0x00000007;
    if (strcmp(buf, "always") == 0)       return 0x00000008;
    napi_throw_error(env, "DOE_ERROR", "Unsupported compare function"); return 0;
}

uint32_t vertex_step_mode_from_value(napi_env env, napi_value val) {
    napi_valuetype vt; napi_typeof(env, val, &vt);
    if (vt == napi_number) { uint32_t out = 0; napi_get_value_uint32(env, val, &out); return out; }
    char buf[24] = {0}; size_t len = 0;
    napi_get_value_string_utf8(env, val, buf, sizeof(buf), &len);
    if (strcmp(buf, "vertex") == 0)   return 0x00000001;
    if (strcmp(buf, "instance") == 0) return 0x00000002;
    napi_throw_error(env, "DOE_ERROR", "Unsupported vertex stepMode"); return 0;
}

uint32_t vertex_format_from_value(napi_env env, napi_value val) {
    napi_valuetype vt; napi_typeof(env, val, &vt);
    if (vt == napi_number) { uint32_t out = 0; napi_get_value_uint32(env, val, &out); return out; }
    char buf[32] = {0}; size_t len = 0;
    napi_get_value_string_utf8(env, val, buf, sizeof(buf), &len);
    /* 8-bit formats */
    if (strcmp(buf, "uint8") == 0)     return WGPUVertexFormat_Uint8;
    if (strcmp(buf, "uint8x2") == 0)   return WGPUVertexFormat_Uint8x2;
    if (strcmp(buf, "uint8x4") == 0)   return WGPUVertexFormat_Uint8x4;
    if (strcmp(buf, "sint8") == 0)     return WGPUVertexFormat_Sint8;
    if (strcmp(buf, "sint8x2") == 0)   return WGPUVertexFormat_Sint8x2;
    if (strcmp(buf, "sint8x4") == 0)   return WGPUVertexFormat_Sint8x4;
    if (strcmp(buf, "unorm8") == 0)    return WGPUVertexFormat_Unorm8;
    if (strcmp(buf, "unorm8x2") == 0)  return WGPUVertexFormat_Unorm8x2;
    if (strcmp(buf, "unorm8x4") == 0)  return WGPUVertexFormat_Unorm8x4;
    if (strcmp(buf, "snorm8") == 0)    return WGPUVertexFormat_Snorm8;
    if (strcmp(buf, "snorm8x2") == 0)  return WGPUVertexFormat_Snorm8x2;
    if (strcmp(buf, "snorm8x4") == 0)  return WGPUVertexFormat_Snorm8x4;
    /* 16-bit formats */
    if (strcmp(buf, "uint16") == 0)    return WGPUVertexFormat_Uint16;
    if (strcmp(buf, "uint16x2") == 0)  return WGPUVertexFormat_Uint16x2;
    if (strcmp(buf, "uint16x4") == 0)  return WGPUVertexFormat_Uint16x4;
    if (strcmp(buf, "sint16") == 0)    return WGPUVertexFormat_Sint16;
    if (strcmp(buf, "sint16x2") == 0)  return WGPUVertexFormat_Sint16x2;
    if (strcmp(buf, "sint16x4") == 0)  return WGPUVertexFormat_Sint16x4;
    if (strcmp(buf, "unorm16") == 0)   return WGPUVertexFormat_Unorm16;
    if (strcmp(buf, "unorm16x2") == 0) return WGPUVertexFormat_Unorm16x2;
    if (strcmp(buf, "unorm16x4") == 0) return WGPUVertexFormat_Unorm16x4;
    if (strcmp(buf, "snorm16") == 0)   return WGPUVertexFormat_Snorm16;
    if (strcmp(buf, "snorm16x2") == 0) return WGPUVertexFormat_Snorm16x2;
    if (strcmp(buf, "snorm16x4") == 0) return WGPUVertexFormat_Snorm16x4;
    /* 16-bit float formats */
    if (strcmp(buf, "float16") == 0)   return WGPUVertexFormat_Float16;
    if (strcmp(buf, "float16x2") == 0) return WGPUVertexFormat_Float16x2;
    if (strcmp(buf, "float16x4") == 0) return WGPUVertexFormat_Float16x4;
    /* 32-bit float formats */
    if (strcmp(buf, "float32") == 0)   return WGPUVertexFormat_Float32;
    if (strcmp(buf, "float32x2") == 0) return WGPUVertexFormat_Float32x2;
    if (strcmp(buf, "float32x3") == 0) return WGPUVertexFormat_Float32x3;
    if (strcmp(buf, "float32x4") == 0) return WGPUVertexFormat_Float32x4;
    /* 32-bit integer formats */
    if (strcmp(buf, "uint32") == 0)    return WGPUVertexFormat_Uint32;
    if (strcmp(buf, "uint32x2") == 0)  return WGPUVertexFormat_Uint32x2;
    if (strcmp(buf, "uint32x3") == 0)  return WGPUVertexFormat_Uint32x3;
    if (strcmp(buf, "uint32x4") == 0)  return WGPUVertexFormat_Uint32x4;
    if (strcmp(buf, "sint32") == 0)    return WGPUVertexFormat_Sint32;
    if (strcmp(buf, "sint32x2") == 0)  return WGPUVertexFormat_Sint32x2;
    if (strcmp(buf, "sint32x3") == 0)  return WGPUVertexFormat_Sint32x3;
    if (strcmp(buf, "sint32x4") == 0)  return WGPUVertexFormat_Sint32x4;
    /* packed formats */
    if (strcmp(buf, "unorm10-10-10-2") == 0) return WGPUVertexFormat_Unorm10_10_10_2;
    if (strcmp(buf, "unorm8x4-bgra") == 0)   return WGPUVertexFormat_Unorm8x4BGRA;
    napi_throw_error(env, "DOE_ERROR", "Unsupported vertex format"); return 0;
}

uint32_t index_format_from_value(napi_env env, napi_value val) {
    napi_valuetype vt; napi_typeof(env, val, &vt);
    if (vt == napi_number) { uint32_t out = 0; napi_get_value_uint32(env, val, &out); return out; }
    char buf[16] = {0}; size_t len = 0;
    napi_get_value_string_utf8(env, val, buf, sizeof(buf), &len);
    if (strcmp(buf, "uint16") == 0) return 0x00000001;
    if (strcmp(buf, "uint32") == 0) return 0x00000002;
    napi_throw_error(env, "DOE_ERROR", "Unsupported index format"); return 0;
}

uint32_t blend_factor_from_string(napi_env env, napi_value val) {
    napi_valuetype vt; napi_typeof(env, val, &vt);
    if (vt == napi_number) { uint32_t out = 0; napi_get_value_uint32(env, val, &out); return out; }
    char buf[32] = {0}; size_t len = 0;
    napi_get_value_string_utf8(env, val, buf, sizeof(buf), &len);
    if (strcmp(buf, "zero") == 0)                  return 1;
    if (strcmp(buf, "one") == 0)                   return 2;
    if (strcmp(buf, "src") == 0)                   return 3;
    if (strcmp(buf, "one-minus-src") == 0)         return 4;
    if (strcmp(buf, "src-alpha") == 0)             return 5;
    if (strcmp(buf, "one-minus-src-alpha") == 0)   return 6;
    if (strcmp(buf, "dst") == 0)                   return 7;
    if (strcmp(buf, "one-minus-dst") == 0)         return 8;
    if (strcmp(buf, "dst-alpha") == 0)             return 9;
    if (strcmp(buf, "one-minus-dst-alpha") == 0)   return 10;
    if (strcmp(buf, "src-alpha-saturated") == 0)   return 11;
    if (strcmp(buf, "constant") == 0)              return 12;
    if (strcmp(buf, "one-minus-constant") == 0)    return 13;
    if (strcmp(buf, "src1") == 0)                  return 14;
    if (strcmp(buf, "one-minus-src1") == 0)        return 15;
    if (strcmp(buf, "src1-alpha") == 0)            return 16;
    if (strcmp(buf, "one-minus-src1-alpha") == 0)  return 17;
    napi_throw_error(env, "DOE_ERROR", "Unsupported blend factor"); return 0;
}

uint32_t blend_operation_from_string(napi_env env, napi_value val) {
    napi_valuetype vt; napi_typeof(env, val, &vt);
    if (vt == napi_number) { uint32_t out = 0; napi_get_value_uint32(env, val, &out); return out; }
    char buf[24] = {0}; size_t len = 0;
    napi_get_value_string_utf8(env, val, buf, sizeof(buf), &len);
    if (strcmp(buf, "add") == 0)              return 1;
    if (strcmp(buf, "subtract") == 0)         return 2;
    if (strcmp(buf, "reverse-subtract") == 0) return 3;
    if (strcmp(buf, "min") == 0)              return 4;
    if (strcmp(buf, "max") == 0)              return 5;
    napi_throw_error(env, "DOE_ERROR", "Unsupported blend operation"); return 0;
}
