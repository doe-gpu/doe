pub fn execution() type {
    return @import("execution.zig");
}

pub const simd = struct {
    pub fn byteScan() type {
        return @import("../contracts/primitives/byte_scan.zig");
    }

    pub fn f32Ops() type {
        return @import("simd/f32_ops.zig");
    }
};

pub const primitives = struct {
    pub fn byteScan() type {
        return @import("../contracts/primitives/byte_scan.zig");
    }
};

pub fn traceText() type {
    return @import("trace/trace_text.zig");
}
