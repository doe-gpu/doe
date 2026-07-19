pub const core = @import("wgpu_dropin_ext_a_core.zig");
pub const pipeline = @import("wgpu_dropin_ext_a_pipeline.zig");
pub const exports = @import("wgpu_dropin_ext_a_exports.zig");

comptime {
    _ = &core;
    _ = &pipeline;
    _ = &exports;
}
