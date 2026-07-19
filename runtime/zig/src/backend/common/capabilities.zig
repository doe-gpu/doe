const model = @import("../../contracts/model/model_commands.zig");

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

    pub fn supports(self: CapabilitySet, cap: Capability) bool {
        return (self.bits & (@as(u64, 1) << @intFromEnum(cap))) != 0;
    }

    pub fn declare(self: *CapabilitySet, cap: Capability) void {
        self.bits |= @as(u64, 1) << @intFromEnum(cap);
    }

    pub fn declare_all(self: *CapabilitySet, caps: []const Capability) void {
        for (caps) |cap| {
            self.declare(cap);
        }
    }

    pub fn missing(self: CapabilitySet, required: CapabilitySet) ?Capability {
        const gap = required.bits & ~self.bits;
        if (gap == 0) return null;
        return @enumFromInt(@ctz(gap));
    }
};

pub fn required_capabilities(command: model.Command) CapabilitySet {
    var set = CapabilitySet{};
    switch (command) {
        .upload => set.declare(.buffer_upload),
        .buffer_write => set.declare(.buffer_write),
        .copy_buffer_to_texture => {
            set.declare(.buffer_copy);
            set.declare(.texture_write);
        },
        .barrier => set.declare(.barrier_sync),
        .dispatch => set.declare(.compute_dispatch),
        .dispatch_indirect => {
            set.declare(.compute_dispatch);
            set.declare(.compute_dispatch_indirect);
        },
        .kernel_dispatch => set.declare(.kernel_dispatch),
        .render_draw => set.declare(.render_draw),
        .draw_indirect => {
            set.declare(.render_draw);
            set.declare(.indirect_draw);
        },
        .draw_indexed_indirect => {
            set.declare(.render_draw);
            set.declare(.indexed_indirect_draw);
        },
        .render_pass => set.declare(.render_pass),
        .sampler_create, .sampler_destroy => set.declare(.sampler_lifecycle),
        .texture_write => set.declare(.texture_write),
        .texture_query => set.declare(.texture_query),
        .texture_destroy => set.declare(.texture_destroy),
        .surface_create, .surface_capabilities, .surface_configure, .surface_unconfigure, .surface_release => set.declare(.surface_lifecycle),
        .surface_acquire, .surface_present => {
            set.declare(.surface_lifecycle);
            set.declare(.surface_present);
        },
        .async_diagnostics => |diagnostics| switch (diagnostics.mode) {
            .pipeline_async => set.declare(.async_pipeline_diagnostics),
            .capability_introspection => set.declare(.async_capability_introspection),
            .resource_table_immediates => set.declare(.async_resource_table_immediates),
            .lifecycle_refcount => set.declare(.async_lifecycle_refcount),
            .pixel_local_storage => set.declare(.async_pixel_local_storage),
            .full => {
                set.declare(.async_pipeline_diagnostics);
                set.declare(.async_capability_introspection);
                set.declare(.async_resource_table_immediates);
                set.declare(.async_lifecycle_refcount);
                set.declare(.async_pixel_local_storage);
            },
        },
        .map_async => set.declare(.map_async),
    }
    return set;
}

pub fn capability_name(cap: Capability) []const u8 {
    return switch (cap) {
        .compute_dispatch => "compute_dispatch",
        .compute_dispatch_indirect => "compute_dispatch_indirect",
        .kernel_dispatch => "kernel_dispatch",
        .buffer_upload => "buffer_upload",
        .buffer_write => "buffer_write",
        .buffer_copy => "buffer_copy",
        .barrier_sync => "barrier_sync",
        .sampler_lifecycle => "sampler_lifecycle",
        .texture_write => "texture_write",
        .texture_query => "texture_query",
        .texture_destroy => "texture_destroy",
        .surface_lifecycle => "surface_lifecycle",
        .surface_present => "surface_present",
        .async_pipeline_diagnostics => "async_pipeline_diagnostics",
        .async_capability_introspection => "async_capability_introspection",
        .async_resource_table_immediates => "async_resource_table_immediates",
        .async_lifecycle_refcount => "async_lifecycle_refcount",
        .async_pixel_local_storage => "async_pixel_local_storage",
        .map_async => "map_async",
        .gpu_timestamps => "gpu_timestamps",
        .timestamp_inside_passes => "timestamp_inside_passes",
        .indirect_draw => "indirect_draw",
        .indexed_indirect_draw => "indexed_indirect_draw",
        .render_pass => "render_pass",
        .render_draw => "render_draw",
        .on_submitted_work_done => "on_submitted_work_done",
        .device_limits => "device_limits",
        .device_features => "device_features",
        .query_set => "query_set",
        .depth_stencil => "depth_stencil",
        .texture_view => "texture_view",
        .descriptor_binding => "descriptor_binding",
        .render_bundle => "render_bundle",
    };
}
