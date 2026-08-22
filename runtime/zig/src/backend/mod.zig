pub fn iface() type {
    return @import("backend_iface.zig");
}

pub fn runtime() type {
    return @import("backend_runtime.zig");
}

pub fn runtimeTypes() type {
    return @import("runtime_types.zig");
}

pub fn telemetry() type {
    return @import("backend_telemetry.zig");
}

pub fn ports() type {
    return @import("ports/mod.zig");
}
