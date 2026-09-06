const std = @import("std");
const c = @import("vk_constants.zig");
const compute = @import("../../contracts/model/model_compute_types.zig");

pub const Sampler = struct {
    handle: c.VkSampler,
    generation: u64,
};

pub const Binding = struct {
    declaration: compute.KernelBinding,
    generation: u64,
    handle: u64,
    backing_handle: u64 = 0,
    extent: u64 = 0,
    image_layout: u32 = 0,
};

pub fn nextGeneration(self: anytype) !u64 {
    const generation = self.next_native_resource_generation;
    if (generation == 0) return error.InvalidState;
    self.next_native_resource_generation = std.math.add(u64, generation, 1) catch return error.InvalidState;
    return generation;
}

pub fn snapshot(self: anytype, declaration: compute.KernelBinding) !Binding {
    const result: Binding = switch (declaration.resource_kind) {
        .buffer => blk: {
            const resource = self.compute_buffers.get(declaration.resource_handle) orelse return error.InvalidState;
            break :blk .{ .declaration = declaration, .generation = resource.generation, .handle = resource.buffer, .backing_handle = resource.memory, .extent = resource.size };
        },
        .texture, .storage_texture => blk: {
            const resource = self.textures.get(declaration.resource_handle) orelse return error.InvalidState;
            if (resource.parent_handle != 0) {
                const parent = self.textures.get(resource.parent_handle) orelse return error.InvalidState;
                if (parent.generation != resource.parent_generation or parent.image != resource.image) return error.InvalidState;
            }
            break :blk .{ .declaration = declaration, .generation = resource.generation, .handle = resource.view, .backing_handle = resource.image, .image_layout = resource.layout };
        },
        .sampler => blk: {
            const resource = self.samplers.get(declaration.resource_handle) orelse return error.InvalidState;
            break :blk .{ .declaration = declaration, .generation = resource.generation, .handle = resource.handle };
        },
    };
    if (result.generation == 0) return error.InvalidState;
    return result;
}

pub fn matches(self: anytype, retained: []const Binding, declarations: []const compute.KernelBinding) bool {
    if (retained.len != declarations.len) return false;
    for (retained, declarations) |binding, declaration| {
        const current = snapshot(self, declaration) catch return false;
        if (!std.meta.eql(binding, current)) return false;
    }
    return true;
}

pub fn validate(self: anytype, retained: []const Binding) !void {
    for (retained) |binding| {
        if (!std.meta.eql(binding, try snapshot(self, binding.declaration))) return error.InvalidState;
    }
}
