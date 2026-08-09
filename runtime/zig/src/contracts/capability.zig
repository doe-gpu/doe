const std = @import("std");

/// Backend-neutral runtime capabilities. Enum order is the stable bit index in
/// CapabilitySet; append new values rather than reordering existing ones.
pub const Capability = enum {
    compute_dispatch,
    compute_dispatch_indirect,
    kernel_dispatch,
    buffer_upload,
    buffer_write,
    buffer_copy,
    barrier_sync,
    sampler_lifecycle,
    texture_write,
    texture_query,
    texture_destroy,
    surface_lifecycle,
    surface_present,
    async_pipeline_diagnostics,
    async_capability_introspection,
    async_resource_table_immediates,
    async_lifecycle_refcount,
    async_pixel_local_storage,
    map_async,
    gpu_timestamps,
    timestamp_inside_passes,
    indirect_draw,
    indexed_indirect_draw,
    render_pass,
    render_draw,
    on_submitted_work_done,
    device_limits,
    device_features,
    query_set,
    depth_stencil,
    texture_view,
    descriptor_binding,
    render_bundle,
};

pub const CapabilitySet = struct {
    bits: u64 = 0,

    pub fn init(comptime capabilities: []const Capability) CapabilitySet {
        var set = CapabilitySet{};
        inline for (capabilities) |capability| set.declare(capability);
        return set;
    }

    pub fn supports(self: CapabilitySet, capability: Capability) bool {
        return (self.bits & (@as(u64, 1) << @intFromEnum(capability))) != 0;
    }

    pub fn declare(self: *CapabilitySet, capability: Capability) void {
        self.bits |= @as(u64, 1) << @intFromEnum(capability);
    }

    pub fn declareAll(self: *CapabilitySet, capabilities: []const Capability) void {
        for (capabilities) |capability| self.declare(capability);
    }

    pub const declare_all = declareAll;

    pub fn missing(self: CapabilitySet, required: CapabilitySet) ?Capability {
        const gap = required.bits & ~self.bits;
        if (gap == 0) return null;
        return @enumFromInt(@ctz(gap));
    }
};

pub fn name(capability: Capability) []const u8 {
    return @tagName(capability);
}

pub const capability_name = name;

comptime {
    if (@typeInfo(Capability).@"enum".fields.len > @bitSizeOf(u64)) {
        @compileError("CapabilitySet cannot represent every Capability");
    }
}

test "capability names and set bits share the canonical enum" {
    var set = CapabilitySet.init(&.{ .buffer_upload, .kernel_dispatch });
    try std.testing.expect(set.supports(.buffer_upload));
    try std.testing.expect(set.supports(.kernel_dispatch));
    try std.testing.expect(!set.supports(.render_draw));
    set.declare(.render_draw);
    try std.testing.expectEqualStrings("render_draw", name(.render_draw));
}
