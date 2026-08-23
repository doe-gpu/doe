//! Read-only, pre-validated execution units consumed by backend ports.
//!
//! Every command enters execution through exactly one domain operation. The
//! domain split prevents backends from exposing a single catch-all command
//! interface to application orchestration. `PreparedOperation` is a borrowed
//! view valid for the synchronous execution/callback extent. Code that queues
//! or retains an operation must first create `OwnedPreparedOperation`, whose
//! arena freezes every slice reachable from the payload.

const std = @import("std");
const command_contract = @import("command.zig");
const compute_contract = @import("compute.zig");
const identity_contract = @import("identity.zig");
const model_async = @import("model/model_async_types.zig");
const model_compute = @import("model/model_compute_types.zig");
const model_render = @import("model/model_render_types.zig");
const model_resource = @import("model/model_resource_types.zig");
const model_surface = @import("model/model_surface_control_types.zig");
const model_texture = @import("model/model_texture_types.zig");
const spatial_contract = @import("spatial_operation.zig");

pub const DirectBufferWrite = struct {
    handle: u64,
    offset_bytes: u64 = 0,
    buffer_size: u64,
    data: []const u8,
};

pub const ComputeOperation = union(enum) {
    barrier: model_resource.BarrierCommand,
    dispatch: model_compute.DispatchCommand,
    dispatch_indirect: model_compute.DispatchIndirectCommand,
    kernel_dispatch: model_compute.KernelDispatchCommand,

    pub fn toCommand(self: ComputeOperation) command_contract.Command {
        return switch (self) {
            .barrier => |value| .{ .barrier = value },
            .dispatch => |value| .{ .dispatch = value },
            .dispatch_indirect => |value| .{ .dispatch_indirect = value },
            .kernel_dispatch => |value| .{ .kernel_dispatch = value },
        };
    }
};

pub const PreparedComputeOperation = struct {
    operation_id: u64,
    operation: ComputeOperation,
    identity: identity_contract.OperationIdentity = .{},

    pub fn kernelDispatch(self: PreparedComputeOperation) ?model_compute.KernelDispatchCommand {
        return switch (self.operation) {
            .kernel_dispatch => |value| value,
            else => null,
        };
    }

    pub fn toDispatchRequest(self: PreparedComputeOperation) ?compute_contract.DispatchRequest {
        const command = self.kernelDispatch() orelse return null;
        return compute_contract.DispatchRequest.fromCommand(command);
    }

    pub fn toCommand(self: PreparedComputeOperation) command_contract.Command {
        return self.operation.toCommand();
    }
};

pub const TransferOperation = union(enum) {
    upload: model_resource.UploadCommand,
    buffer_write: model_resource.BufferWriteCommand,
    copy_buffer_to_texture: model_resource.CopyCommand,
    direct_buffer_write: DirectBufferWrite,

    pub fn toCommand(self: TransferOperation) ?command_contract.Command {
        return switch (self) {
            .upload => |value| .{ .upload = value },
            .buffer_write => |value| .{ .buffer_write = value },
            .copy_buffer_to_texture => |value| .{ .copy_buffer_to_texture = value },
            .direct_buffer_write => null,
        };
    }
};

pub const PreparedTransferOperation = struct {
    operation_id: u64,
    operation: TransferOperation,
    identity: identity_contract.OperationIdentity = .{},
};

pub const RenderOperation = union(enum) {
    render_draw: model_render.RenderDrawCommand,
    draw_indirect: model_render.DrawIndirectCommand,
    draw_indexed_indirect: model_render.DrawIndexedIndirectCommand,
    render_pass: model_render.RenderPassCommand,

    pub fn toCommand(self: RenderOperation) command_contract.Command {
        return switch (self) {
            .render_draw => |value| .{ .render_draw = value },
            .draw_indirect => |value| .{ .draw_indirect = value },
            .draw_indexed_indirect => |value| .{ .draw_indexed_indirect = value },
            .render_pass => |value| .{ .render_pass = value },
        };
    }
};

pub const PreparedRenderOperation = struct {
    operation_id: u64,
    operation: RenderOperation,
    identity: identity_contract.OperationIdentity = .{},
};

pub const ResourceOperation = union(enum) {
    sampler_create: model_render.SamplerCreateCommand,
    sampler_destroy: model_render.SamplerDestroyCommand,
    texture_write: model_texture.TextureWriteCommand,
    texture_query: model_texture.TextureQueryCommand,
    texture_destroy: model_texture.TextureDestroyCommand,
    map_async: model_async.MapAsyncCommand,

    pub fn toCommand(self: ResourceOperation) command_contract.Command {
        return switch (self) {
            .sampler_create => |value| .{ .sampler_create = value },
            .sampler_destroy => |value| .{ .sampler_destroy = value },
            .texture_write => |value| .{ .texture_write = value },
            .texture_query => |value| .{ .texture_query = value },
            .texture_destroy => |value| .{ .texture_destroy = value },
            .map_async => |value| .{ .map_async = value },
        };
    }
};

pub const PreparedResourceOperation = struct {
    operation_id: u64,
    operation: ResourceOperation,
    identity: identity_contract.OperationIdentity = .{},
};

pub const SurfaceOperation = union(enum) {
    create: model_surface.SurfaceCreateCommand,
    capabilities: model_surface.SurfaceCapabilitiesCommand,
    configure: model_surface.SurfaceConfigureCommand,
    acquire: model_surface.SurfaceAcquireCommand,
    present: model_surface.SurfacePresentCommand,
    unconfigure: model_surface.SurfaceUnconfigureCommand,
    release: model_surface.SurfaceReleaseCommand,

    pub fn toCommand(self: SurfaceOperation) command_contract.Command {
        return switch (self) {
            .create => |value| .{ .surface_create = value },
            .capabilities => |value| .{ .surface_capabilities = value },
            .configure => |value| .{ .surface_configure = value },
            .acquire => |value| .{ .surface_acquire = value },
            .present => |value| .{ .surface_present = value },
            .unconfigure => |value| .{ .surface_unconfigure = value },
            .release => |value| .{ .surface_release = value },
        };
    }
};

pub const PreparedSurfaceOperation = struct {
    operation_id: u64,
    operation: SurfaceOperation,
    identity: identity_contract.OperationIdentity = .{},
};

pub const PreparedLifecycleOperation = struct {
    operation_id: u64,
    operation: model_async.AsyncDiagnosticsCommand,
    identity: identity_contract.OperationIdentity = .{},

    pub fn toCommand(self: PreparedLifecycleOperation) command_contract.Command {
        return .{ .async_diagnostics = self.operation };
    }
};

pub const PreparedSpatialOperation = spatial_contract.PreparedSpatialOperation;

pub const PreparedOperation = union(enum) {
    compute: PreparedComputeOperation,
    transfer: PreparedTransferOperation,
    render: PreparedRenderOperation,
    resource: PreparedResourceOperation,
    surface: PreparedSurfaceOperation,
    lifecycle: PreparedLifecycleOperation,
    spatial: PreparedSpatialOperation,

    pub fn operationId(self: PreparedOperation) u64 {
        return switch (self) {
            inline else => |operation| operation.operation_id,
        };
    }
};

/// An immutable retained snapshot of a prepared operation.
///
/// Opaque handles and callback pointers remain identity values; all slices,
/// including nested binding/oracle data, are recursively copied into the
/// snapshot arena. Call `deinit` exactly once after the last borrowed view.
pub const OwnedPreparedOperation = struct {
    arena: std.heap.ArenaAllocator,
    operation: PreparedOperation,

    pub fn init(allocator: std.mem.Allocator, operation: PreparedOperation) !OwnedPreparedOperation {
        var owned = OwnedPreparedOperation{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .operation = undefined,
        };
        errdefer owned.arena.deinit();
        owned.operation = try cloneValue(PreparedOperation, owned.arena.allocator(), operation);
        return owned;
    }

    pub fn deinit(self: *OwnedPreparedOperation) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn borrow(self: *const OwnedPreparedOperation) PreparedOperation {
        return self.operation;
    }
};

fn cloneValue(comptime T: type, allocator: std.mem.Allocator, value: T) !T {
    return switch (@typeInfo(T)) {
        .optional => |optional| if (value) |present|
            try cloneValue(optional.child, allocator, present)
        else
            null,
        .array => |array| blk: {
            var cloned: T = undefined;
            for (value, 0..) |item, index| {
                cloned[index] = try cloneValue(array.child, allocator, item);
            }
            break :blk cloned;
        },
        .pointer => |pointer| switch (pointer.size) {
            .slice => blk: {
                const cloned = try allocator.alloc(pointer.child, value.len);
                for (value, 0..) |item, index| {
                    cloned[index] = try cloneValue(pointer.child, allocator, item);
                }
                break :blk cloned;
            },
            .one, .many, .c => value,
        },
        .@"struct" => |structure| blk: {
            var cloned: T = undefined;
            inline for (structure.fields) |field| {
                @field(cloned, field.name) = try cloneValue(
                    field.type,
                    allocator,
                    @field(value, field.name),
                );
            }
            break :blk cloned;
        },
        .@"union" => |union_info| blk: {
            const active = std.meta.activeTag(value);
            inline for (union_info.fields) |field| {
                if (active == @field(union_info.tag_type.?, field.name)) {
                    break :blk @unionInit(
                        T,
                        field.name,
                        try cloneValue(field.type, allocator, @field(value, field.name)),
                    );
                }
            }
            unreachable;
        },
        else => value,
    };
}

pub fn fromCommand(command: command_contract.Command, operation_id: u64) PreparedOperation {
    return switch (command) {
        .upload => |value| .{ .transfer = .{ .operation_id = operation_id, .operation = .{ .upload = value } } },
        .buffer_write => |value| .{ .transfer = .{ .operation_id = operation_id, .operation = .{ .buffer_write = value } } },
        .copy_buffer_to_texture => |value| .{ .transfer = .{ .operation_id = operation_id, .operation = .{ .copy_buffer_to_texture = value } } },
        .barrier => |value| .{ .compute = .{ .operation_id = operation_id, .operation = .{ .barrier = value } } },
        .dispatch => |value| .{ .compute = .{ .operation_id = operation_id, .operation = .{ .dispatch = value } } },
        .dispatch_indirect => |value| .{ .compute = .{ .operation_id = operation_id, .operation = .{ .dispatch_indirect = value } } },
        .kernel_dispatch => |value| .{ .compute = .{ .operation_id = operation_id, .operation = .{ .kernel_dispatch = value }, .identity = kernelIdentity(value, operation_id) } },
        .render_draw => |value| .{ .render = .{ .operation_id = operation_id, .operation = .{ .render_draw = value } } },
        .draw_indirect => |value| .{ .render = .{ .operation_id = operation_id, .operation = .{ .draw_indirect = value } } },
        .draw_indexed_indirect => |value| .{ .render = .{ .operation_id = operation_id, .operation = .{ .draw_indexed_indirect = value } } },
        .render_pass => |value| .{ .render = .{ .operation_id = operation_id, .operation = .{ .render_pass = value } } },
        .sampler_create => |value| .{ .resource = .{ .operation_id = operation_id, .operation = .{ .sampler_create = value } } },
        .sampler_destroy => |value| .{ .resource = .{ .operation_id = operation_id, .operation = .{ .sampler_destroy = value } } },
        .texture_write => |value| .{ .resource = .{ .operation_id = operation_id, .operation = .{ .texture_write = value } } },
        .texture_query => |value| .{ .resource = .{ .operation_id = operation_id, .operation = .{ .texture_query = value } } },
        .texture_destroy => |value| .{ .resource = .{ .operation_id = operation_id, .operation = .{ .texture_destroy = value } } },
        .surface_create => |value| .{ .surface = .{ .operation_id = operation_id, .operation = .{ .create = value } } },
        .surface_capabilities => |value| .{ .surface = .{ .operation_id = operation_id, .operation = .{ .capabilities = value } } },
        .surface_configure => |value| .{ .surface = .{ .operation_id = operation_id, .operation = .{ .configure = value } } },
        .surface_acquire => |value| .{ .surface = .{ .operation_id = operation_id, .operation = .{ .acquire = value } } },
        .surface_present => |value| .{ .surface = .{ .operation_id = operation_id, .operation = .{ .present = value } } },
        .surface_unconfigure => |value| .{ .surface = .{ .operation_id = operation_id, .operation = .{ .unconfigure = value } } },
        .surface_release => |value| .{ .surface = .{ .operation_id = operation_id, .operation = .{ .release = value } } },
        .async_diagnostics => |value| .{ .lifecycle = .{ .operation_id = operation_id, .operation = value } },
        .map_async => |value| .{ .resource = .{ .operation_id = operation_id, .operation = .{ .map_async = value } } },
    };
}

pub fn directBufferWrite(value: DirectBufferWrite, operation_id: u64) PreparedOperation {
    return .{ .transfer = .{
        .operation_id = operation_id,
        .operation = .{ .direct_buffer_write = value },
    } };
}

fn kernelIdentity(command: model_compute.KernelDispatchCommand, operation_id: u64) identity_contract.OperationIdentity {
    var source_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    source_hasher.update(command.kernel);
    var source_sha256: identity_contract.Sha256Digest = undefined;
    source_hasher.final(&source_sha256);

    var dispatch_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    dispatch_hasher.update(std.mem.asBytes(&command.x));
    dispatch_hasher.update(std.mem.asBytes(&command.y));
    dispatch_hasher.update(std.mem.asBytes(&command.z));
    dispatch_hasher.update(std.mem.asBytes(&command.repeat));
    var dispatch_hash: identity_contract.Sha256Digest = undefined;
    dispatch_hasher.final(&dispatch_hash);

    return .{
        .operation_id = operation_id,
        .program = .{
            .source_sha256 = source_sha256,
            .lowered_sha256 = source_sha256,
            .entry_point = command.entry_point orelse "main",
        },
        .dispatch_hash = dispatch_hash,
    };
}

test "every canonical command becomes exactly one prepared domain operation" {
    const command = command_contract.Command{ .surface_present = .{ .handle = 17 } };
    const prepared = fromCommand(command, 9);
    try std.testing.expectEqual(@as(u64, 9), prepared.operationId());
    try std.testing.expectEqual(@as(u64, 17), prepared.surface.operation.present.handle);
}

test "kernel preparation binds source and dispatch identity" {
    const prepared = fromCommand(.{ .kernel_dispatch = .{
        .kernel = "@compute @workgroup_size(1) fn main() {}",
        .x = 2,
        .y = 3,
        .z = 4,
    } }, 31).compute;
    try std.testing.expect(!prepared.identity.program.isNull());
    try std.testing.expectEqual(@as(u64, 31), prepared.identity.operation_id);
    try std.testing.expect(prepared.toDispatchRequest() != null);
}

test "owned prepared operation freezes nested borrowed payloads" {
    var kernel = [_]u8{ 'a', 'b', 'c' };
    var oracle_kind = [_]u8{ 'u', '3', '2' };
    var bindings = [_]model_compute.KernelBinding{.{
        .binding = 2,
        .resource_kind = .buffer,
        .resource_handle = 11,
    }};
    const borrowed = fromCommand(.{ .kernel_dispatch = .{
        .kernel = &kernel,
        .x = 1,
        .y = 1,
        .z = 1,
        .bindings = &bindings,
        .output_oracle = .{
            .schema_version = 1,
            .scope = .isolated_dispatch,
            .reference_class = .independent,
            .kind = &oracle_kind,
            .initialization = "zero",
            .binding_group = 0,
            .binding = 2,
            .dispatch_count = 1,
            .expected_sha256 = "00",
            .reference_id = "fixture",
        },
    } }, 41);
    var owned = try OwnedPreparedOperation.init(std.testing.allocator, borrowed);
    defer owned.deinit();

    kernel[0] = 'z';
    oracle_kind[0] = 'f';
    bindings[0].resource_handle = 99;

    const frozen = owned.borrow().compute.operation.kernel_dispatch;
    try std.testing.expectEqualStrings("abc", frozen.kernel);
    try std.testing.expectEqualStrings("u32", frozen.output_oracle.?.kind);
    try std.testing.expectEqual(@as(u64, 11), frozen.bindings.?[0].resource_handle);
}
