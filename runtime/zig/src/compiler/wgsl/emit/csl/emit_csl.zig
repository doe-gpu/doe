// emit_csl.zig — Public entry point for the Cerebras CSL backend.
//
// Thin facade matching the pattern of emit_msl.zig, emit_hlsl.zig, etc.
// Delegates to emit_csl_core for the actual emission logic.

const emit_csl_core = @import("emit_csl_core.zig");
const ir = @import("../../ir/ir.zig");

pub const EmitError = error{
    OutputTooLarge,
    InvalidIr,
    UnsupportedBuiltin,
    UnsupportedConstruct,
    UnsupportedPattern,
};

pub const MAX_OUTPUT: usize = emit_csl_core.MAX_OUTPUT;

pub fn emit(module: *const ir.Module, out: []u8) EmitError!usize {
    return emit_csl_core.emit(module, out);
}
