// mod_api_test_support.zig - Shared aliases for sharded public WGSL translation API tests.

pub const std = @import("std");
const mod = @import("../../src/compiler/wgsl/mod.zig");
pub const lean_proof = @import("../../src/verification/lean_proof.zig");
pub const runtime_compile = @import("../../src/compiler/wgsl/runtime/runtime_compile.zig");
pub const translateToMsl = mod.translateToMsl;
pub const translateToHlsl = mod.translateToHlsl;
pub const translateToSpirv = mod.translateToSpirv;
pub const analyzeToIr = mod.analyzeToIr;
pub const analyzeToIrWithConfig = mod.analyzeToIrWithConfig;
pub const ir = mod.ir;
pub const MAX_OUTPUT = mod.MAX_OUTPUT;
pub const MAX_HLSL_OUTPUT = mod.MAX_HLSL_OUTPUT;
pub const MAX_SPIRV_OUTPUT = mod.MAX_SPIRV_OUTPUT;
