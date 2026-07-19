const std = @import("std");
const model_compute_types = @import("../../contracts/model/model_compute_types.zig");

pub fn compute_layout_hash(bindings: ?[]const model_compute_types.KernelBinding) u64 {
    var hasher = std.hash.Wyhash.init(0);
    if (bindings) |bs| {
        for (bs) |binding| {
            hasher.update(std.mem.asBytes(&binding.group));
            hasher.update(std.mem.asBytes(&binding.binding));
            hasher.update(std.mem.asBytes(&binding.resource_kind));
            hasher.update(std.mem.asBytes(&binding.buffer_type));
            hasher.update(std.mem.asBytes(&binding.texture_sample_type));
            hasher.update(std.mem.asBytes(&binding.texture_view_dimension));
            hasher.update(std.mem.asBytes(&binding.storage_texture_access));
            hasher.update(std.mem.asBytes(&binding.texture_format));
            hasher.update(std.mem.asBytes(&binding.texture_multisampled));
        }
    }
    return hasher.final();
}

pub fn compute_descriptor_bindings_hash(bindings: []const model_compute_types.KernelBinding) u64 {
    var hasher = DescriptorBindingsHasher{};
    for (bindings) |binding| {
        hasher.update(binding);
    }
    return hasher.final();
}

pub const DescriptorBindingsHasher = struct {
    hasher: std.hash.Wyhash = std.hash.Wyhash.init(0),

    pub fn update(self: *DescriptorBindingsHasher, binding: model_compute_types.KernelBinding) void {
        self.hasher.update(std.mem.asBytes(&binding.group));
        self.hasher.update(std.mem.asBytes(&binding.binding));
        self.hasher.update(std.mem.asBytes(&binding.resource_kind));
        self.hasher.update(std.mem.asBytes(&binding.resource_handle));
        self.hasher.update(std.mem.asBytes(&binding.visibility));
        self.hasher.update(std.mem.asBytes(&binding.buffer_offset));
        self.hasher.update(std.mem.asBytes(&binding.buffer_size));
        self.hasher.update(std.mem.asBytes(&binding.buffer_type));
        self.hasher.update(std.mem.asBytes(&binding.texture_sample_type));
        self.hasher.update(std.mem.asBytes(&binding.texture_view_dimension));
        self.hasher.update(std.mem.asBytes(&binding.storage_texture_access));
        self.hasher.update(std.mem.asBytes(&binding.texture_aspect));
        self.hasher.update(std.mem.asBytes(&binding.texture_format));
        self.hasher.update(std.mem.asBytes(&binding.texture_multisampled));
    }

    pub fn final(self: *DescriptorBindingsHasher) u64 {
        return self.hasher.final();
    }
};

pub fn compute_pipeline_hash(
    words: []const u32,
    entry_point: ?[]const u8,
    bindings: ?[]const model_compute_types.KernelBinding,
) u64 {
    return compute_pipeline_hash_from_spirv_hash(compute_spirv_words_hash(words), entry_point, bindings);
}

pub fn compute_spirv_words_hash(words: []const u32) u64 {
    return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(words));
}

pub fn compute_pipeline_hash_from_spirv_hash(
    spirv_hash: u64,
    entry_point: ?[]const u8,
    bindings: ?[]const model_compute_types.KernelBinding,
) u64 {
    return compute_pipeline_hash_from_layout_hash(spirv_hash, entry_point, compute_layout_hash(bindings));
}

pub fn compute_pipeline_hash_from_layout_hash(
    spirv_hash: u64,
    entry_point: ?[]const u8,
    layout_hash: u64,
) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&spirv_hash));
    hasher.update(entry_point orelse "main");
    hasher.update(std.mem.asBytes(&layout_hash));
    return hasher.final();
}
