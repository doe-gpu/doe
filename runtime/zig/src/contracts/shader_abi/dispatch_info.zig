//! Host/shader ABI for the HLSL `num_workgroups` dispatch metadata binding.
//!
//! The compiler emits the shader-visible names and binding coordinates below;
//! the D3D12 runtime allocates and writes the corresponding constant buffer.

pub const DISPATCH_INFO_REGISTER_SLOT: u32 = 0;
pub const DISPATCH_INFO_REGISTER_SPACE: u32 = 7;
pub const DISPATCH_INFO_ROOT_PARAMETER_INDEX: u32 = 0;
pub const DISPATCH_INFO_BUFFER_BYTES: u64 = 256;

pub const DISPATCH_INFO_CBUFFER_NAME: []const u8 = "DoeDispatchInfo";
pub const DISPATCH_INFO_FIELD_NAME: []const u8 = "doe_num_workgroups";
pub const DISPATCH_INFO_PAD_FIELD_NAME: []const u8 = "_doe_num_workgroups_pad";

pub const Words = extern struct {
    x: u32,
    y: u32,
    z: u32,
    _pad: u32 = 0,
};

comptime {
    if (@sizeOf(Words) != 16) {
        @compileError("dispatch-info host words must match HLSL uint3 plus padding");
    }
    if (DISPATCH_INFO_BUFFER_BYTES < @sizeOf(Words) or DISPATCH_INFO_BUFFER_BYTES % 256 != 0) {
        @compileError("dispatch-info constant buffer must use D3D12's 256-byte CBV alignment");
    }
}
