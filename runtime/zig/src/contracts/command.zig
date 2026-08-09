const std = @import("std");
const capability_contract = @import("capability.zig");
const resource = @import("model/model_resource_types.zig");
const compute = @import("model/model_compute_types.zig");
const render = @import("model/model_render_types.zig");
const texture = @import("model/model_texture_types.zig");
const surface = @import("model/model_surface_control_types.zig");
const async_types = @import("model/model_async_types.zig");

pub const Capability = capability_contract.Capability;
pub const CapabilitySet = capability_contract.CapabilitySet;

/// The execution surface that owns a command. `full` means full-only; the full
/// runtime accepts both scopes.
pub const Scope = enum {
    core,
    full,
};

/// Stable command identity. Numeric order is part of the JS-to-Zig command
/// dispatch contract and must remain append-only.
pub const Kind = enum(u8) {
    upload,
    buffer_write,
    copy_buffer_to_texture,
    barrier,
    dispatch,
    dispatch_indirect,
    kernel_dispatch,
    render_draw,
    draw_indirect,
    draw_indexed_indirect,
    render_pass,
    sampler_create,
    sampler_destroy,
    texture_write,
    texture_query,
    texture_destroy,
    surface_create,
    surface_capabilities,
    surface_configure,
    surface_acquire,
    surface_present,
    surface_unconfigure,
    surface_release,
    async_diagnostics,
    map_async,
};

/// Compatibility spelling for the published model surface. New internal code
/// should use `Kind`.
pub const CommandKind = Kind;

pub const Command = union(Kind) {
    upload: resource.UploadCommand,
    buffer_write: resource.BufferWriteCommand,
    copy_buffer_to_texture: resource.CopyCommand,
    barrier: resource.BarrierCommand,
    dispatch: compute.DispatchCommand,
    dispatch_indirect: compute.DispatchIndirectCommand,
    kernel_dispatch: compute.KernelDispatchCommand,
    render_draw: render.RenderDrawCommand,
    draw_indirect: render.DrawIndirectCommand,
    draw_indexed_indirect: render.DrawIndexedIndirectCommand,
    render_pass: render.RenderPassCommand,
    sampler_create: render.SamplerCreateCommand,
    sampler_destroy: render.SamplerDestroyCommand,
    texture_write: texture.TextureWriteCommand,
    texture_query: texture.TextureQueryCommand,
    texture_destroy: texture.TextureDestroyCommand,
    surface_create: surface.SurfaceCreateCommand,
    surface_capabilities: surface.SurfaceCapabilitiesCommand,
    surface_configure: surface.SurfaceConfigureCommand,
    surface_acquire: surface.SurfaceAcquireCommand,
    surface_present: surface.SurfacePresentCommand,
    surface_unconfigure: surface.SurfaceUnconfigureCommand,
    surface_release: surface.SurfaceReleaseCommand,
    async_diagnostics: async_types.AsyncDiagnosticsCommand,
    map_async: async_types.MapAsyncCommand,
};

pub const Domain = enum {
    copy,
    compute,
    render,
    resource,
    surface,
    lifecycle,
};

pub const CapabilityPolicy = union(enum) {
    fixed: CapabilitySet,
    async_diagnostics_mode,
};

pub const Metadata = struct {
    scope: Scope,
    trace_name: []const u8,
    domain: Domain,
    is_dispatch: bool,
    capabilities: CapabilityPolicy,
};

pub const KIND_COUNT = @typeInfo(Kind).@"enum".fields.len;

pub const metadata = [KIND_COUNT]Metadata{
    .{ .scope = .core, .trace_name = "upload", .domain = .copy, .is_dispatch = false, .capabilities = .{ .fixed = CapabilitySet.init(&.{.buffer_upload}) } },
    .{ .scope = .core, .trace_name = "buffer_write", .domain = .copy, .is_dispatch = false, .capabilities = .{ .fixed = CapabilitySet.init(&.{.buffer_write}) } },
    .{ .scope = .core, .trace_name = "copy_buffer_to_texture", .domain = .copy, .is_dispatch = false, .capabilities = .{ .fixed = CapabilitySet.init(&.{ .buffer_copy, .texture_write }) } },
    .{ .scope = .core, .trace_name = "barrier", .domain = .compute, .is_dispatch = false, .capabilities = .{ .fixed = CapabilitySet.init(&.{.barrier_sync}) } },
    .{ .scope = .core, .trace_name = "dispatch", .domain = .compute, .is_dispatch = true, .capabilities = .{ .fixed = CapabilitySet.init(&.{.compute_dispatch}) } },
    .{ .scope = .core, .trace_name = "dispatch_indirect", .domain = .compute, .is_dispatch = true, .capabilities = .{ .fixed = CapabilitySet.init(&.{ .compute_dispatch, .compute_dispatch_indirect }) } },
    .{ .scope = .core, .trace_name = "kernel_dispatch", .domain = .compute, .is_dispatch = true, .capabilities = .{ .fixed = CapabilitySet.init(&.{.kernel_dispatch}) } },
    .{ .scope = .full, .trace_name = "render_draw", .domain = .render, .is_dispatch = false, .capabilities = .{ .fixed = CapabilitySet.init(&.{.render_draw}) } },
    .{ .scope = .full, .trace_name = "draw_indirect", .domain = .render, .is_dispatch = false, .capabilities = .{ .fixed = CapabilitySet.init(&.{ .render_draw, .indirect_draw }) } },
    .{ .scope = .full, .trace_name = "draw_indexed_indirect", .domain = .render, .is_dispatch = false, .capabilities = .{ .fixed = CapabilitySet.init(&.{ .render_draw, .indexed_indirect_draw }) } },
    .{ .scope = .full, .trace_name = "render_pass", .domain = .render, .is_dispatch = false, .capabilities = .{ .fixed = CapabilitySet.init(&.{.render_pass}) } },
    .{ .scope = .full, .trace_name = "sampler_create", .domain = .resource, .is_dispatch = false, .capabilities = .{ .fixed = CapabilitySet.init(&.{.sampler_lifecycle}) } },
    .{ .scope = .full, .trace_name = "sampler_destroy", .domain = .resource, .is_dispatch = false, .capabilities = .{ .fixed = CapabilitySet.init(&.{.sampler_lifecycle}) } },
    .{ .scope = .core, .trace_name = "texture_write", .domain = .resource, .is_dispatch = false, .capabilities = .{ .fixed = CapabilitySet.init(&.{.texture_write}) } },
    .{ .scope = .core, .trace_name = "texture_query", .domain = .resource, .is_dispatch = false, .capabilities = .{ .fixed = CapabilitySet.init(&.{.texture_query}) } },
    .{ .scope = .core, .trace_name = "texture_destroy", .domain = .resource, .is_dispatch = false, .capabilities = .{ .fixed = CapabilitySet.init(&.{.texture_destroy}) } },
    .{ .scope = .full, .trace_name = "surface_create", .domain = .surface, .is_dispatch = false, .capabilities = .{ .fixed = CapabilitySet.init(&.{.surface_lifecycle}) } },
    .{ .scope = .full, .trace_name = "surface_capabilities", .domain = .surface, .is_dispatch = false, .capabilities = .{ .fixed = CapabilitySet.init(&.{.surface_lifecycle}) } },
    .{ .scope = .full, .trace_name = "surface_configure", .domain = .surface, .is_dispatch = false, .capabilities = .{ .fixed = CapabilitySet.init(&.{.surface_lifecycle}) } },
    .{ .scope = .full, .trace_name = "surface_acquire", .domain = .surface, .is_dispatch = false, .capabilities = .{ .fixed = CapabilitySet.init(&.{ .surface_lifecycle, .surface_present }) } },
    .{ .scope = .full, .trace_name = "surface_present", .domain = .surface, .is_dispatch = false, .capabilities = .{ .fixed = CapabilitySet.init(&.{ .surface_lifecycle, .surface_present }) } },
    .{ .scope = .full, .trace_name = "surface_unconfigure", .domain = .surface, .is_dispatch = false, .capabilities = .{ .fixed = CapabilitySet.init(&.{.surface_lifecycle}) } },
    .{ .scope = .full, .trace_name = "surface_release", .domain = .surface, .is_dispatch = false, .capabilities = .{ .fixed = CapabilitySet.init(&.{.surface_lifecycle}) } },
    .{ .scope = .full, .trace_name = "async_diagnostics", .domain = .lifecycle, .is_dispatch = false, .capabilities = .async_diagnostics_mode },
    .{ .scope = .core, .trace_name = "map_async", .domain = .resource, .is_dispatch = false, .capabilities = .{ .fixed = CapabilitySet.init(&.{.map_async}) } },
};

pub const Requirements = struct {
    manifest_module: []const u8,
    is_dispatch: bool,
    operation_count: u32,
    required_capabilities: CapabilitySet,
};

pub fn kind(command: Command) Kind {
    return std.meta.activeTag(command);
}

pub fn metadataForKind(value: Kind) Metadata {
    return metadata[@intFromEnum(value)];
}

pub fn scope(value: Kind) Scope {
    return metadataForKind(value).scope;
}

pub fn isCoreKind(value: Kind) bool {
    return scope(value) == .core;
}

pub fn isFullOnlyKind(value: Kind) bool {
    return scope(value) == .full;
}

pub fn name(value: Kind) []const u8 {
    return metadataForKind(value).trace_name;
}

pub fn domainName(value: Kind) []const u8 {
    return @tagName(metadataForKind(value).domain);
}

pub fn isDispatch(command: Command) bool {
    return metadataForKind(kind(command)).is_dispatch;
}

pub fn operationCount(command: Command) u32 {
    return switch (command) {
        .kernel_dispatch => |kernel| if (kernel.repeat > 0) kernel.repeat else 1,
        .render_draw, .draw_indirect, .draw_indexed_indirect, .render_pass => |draw| if (draw.draw_count > 0) draw.draw_count else 1,
        .async_diagnostics => |diagnostics| if (diagnostics.iterations > 0) diagnostics.iterations else 1,
        else => 1,
    };
}

pub fn shaderArtifactModule(command: Command) []const u8 {
    return switch (command) {
        .kernel_dispatch => |kernel| kernel.kernel,
        else => name(kind(command)),
    };
}

pub fn manifestModule(command: Command) []const u8 {
    return name(kind(command));
}

pub fn requiredCapabilities(command: Command) CapabilitySet {
    const policy = metadataForKind(kind(command)).capabilities;
    return switch (policy) {
        .fixed => |set| set,
        .async_diagnostics_mode => switch (command.async_diagnostics.mode) {
            .pipeline_async => CapabilitySet.init(&.{.async_pipeline_diagnostics}),
            .capability_introspection => CapabilitySet.init(&.{.async_capability_introspection}),
            .resource_table_immediates => CapabilitySet.init(&.{.async_resource_table_immediates}),
            .lifecycle_refcount => CapabilitySet.init(&.{.async_lifecycle_refcount}),
            .pixel_local_storage => CapabilitySet.init(&.{.async_pixel_local_storage}),
            .full => CapabilitySet.init(&.{
                .async_pipeline_diagnostics,
                .async_capability_introspection,
                .async_resource_table_immediates,
                .async_lifecycle_refcount,
                .async_pixel_local_storage,
            }),
        },
    };
}

pub fn requirements(command: Command) Requirements {
    return .{
        .manifest_module = name(kind(command)),
        .is_dispatch = isDispatch(command),
        .operation_count = operationCount(command),
        .required_capabilities = requiredCapabilities(command),
    };
}

pub fn countForScope(comptime command_scope: Scope) comptime_int {
    var count: comptime_int = 0;
    for (metadata) |entry| {
        if (entry.scope == command_scope) count += 1;
    }
    return count;
}

pub const command_kind = kind;
pub const command_kind_name = name;
pub const is_core_command_kind = isCoreKind;
pub const is_full_command_kind = isFullOnlyKind;
pub const manifest_module = manifestModule;
pub const shader_artifact_module = shaderArtifactModule;
pub const is_dispatch = isDispatch;
pub const operation_count = operationCount;
pub const required_capabilities = requiredCapabilities;
pub const CommandRequirements = Requirements;

comptime {
    const fields = @typeInfo(Kind).@"enum".fields;
    if (fields.len != metadata.len) @compileError("every command kind requires metadata");
    for (fields, 0..) |field, index| {
        if (field.value != index) @compileError("command kind values must remain contiguous");
        if (!std.mem.eql(u8, field.name, metadata[index].trace_name)) {
            @compileError("command trace name must match its stable command kind");
        }
    }
    if (countForScope(.core) + countForScope(.full) != KIND_COUNT) {
        @compileError("every command kind must have exactly one execution scope");
    }
}

test "command registry covers stable names, scope, capabilities, and counts" {
    try std.testing.expectEqualStrings("kernel_dispatch", name(.kernel_dispatch));
    try std.testing.expect(isCoreKind(.kernel_dispatch));
    try std.testing.expect(isFullOnlyKind(.render_draw));
    try std.testing.expectEqualStrings("surface", domainName(.surface_present));
    const copy = Command{ .copy_buffer_to_texture = .{
        .direction = .buffer_to_texture,
        .src = .{ .handle = 1 },
        .dst = .{ .handle = 2, .kind = .texture },
        .bytes = 4,
    } };
    const required = requiredCapabilities(copy);
    try std.testing.expect(required.supports(.buffer_copy));
    try std.testing.expect(required.supports(.texture_write));
    try std.testing.expectEqual(KIND_COUNT, countForScope(.core) + countForScope(.full));
}
