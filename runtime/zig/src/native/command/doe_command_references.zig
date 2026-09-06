const std = @import("std");
const objects = @import("../support/doe_native_object_types.zig");
const commands = @import("../support/doe_native_command_types.zig");
const helpers = @import("../support/doe_native_object_helpers.zig");
const exports = @import("../support/doe_native_exports.zig");

pub const List = std.ArrayListUnmanaged(commands.CommandReference);

fn retain(list: *List, object: anytype, release: *const fn (?*anyopaque) callconv(.c) void) void {
    list.append(helpers.alloc, .{
        .handle = helpers.toOpaque(object),
        .release = release,
    }) catch std.debug.panic("command references: OOM retaining recorded resource", .{});
    object.ref_count +|= 1;
}

pub fn retainBuffer(list: *List, buffer: *objects.DoeBuffer) void {
    retain(list, buffer, exports.doeNativeBufferRelease);
}

pub fn retainTexture(list: *List, texture: *objects.DoeTexture) void {
    retain(list, texture, exports.doeNativeTextureRelease);
}

pub fn retainPipeline(list: *List, pipeline: *objects.DoeComputePipeline) void {
    retain(list, pipeline, exports.doeNativeComputePipelineRelease);
}

pub fn retainBindGroup(list: *List, group: *objects.DoeBindGroup) void {
    retain(list, group, exports.doeNativeBindGroupRelease);
}

pub fn releaseAll(references: *List) void {
    for (references.items) |reference| reference.release(reference.handle);
    references.deinit(helpers.alloc);
    references.* = .{};
}
