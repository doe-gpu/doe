const std = @import("std");
const objects = @import("../support/doe_native_object_types.zig");
const commands = @import("../support/doe_native_command_types.zig");
const helpers = @import("../support/doe_native_object_helpers.zig");
const exports = @import("../support/doe_native_exports.zig");

pub const List = std.ArrayListUnmanaged(commands.CommandReference);

fn retain(allocator: std.mem.Allocator, list: *List, object: anytype, release: *const fn (?*anyopaque) callconv(.c) void) void {
    list.append(allocator, .{
        .handle = helpers.toOpaque(object),
        .release = release,
    }) catch std.debug.panic("command references: OOM retaining recorded resource", .{});
    helpers.object_add_ref(@TypeOf(object.*), helpers.toOpaque(object));
}

pub fn retainBuffer(allocator: std.mem.Allocator, list: *List, buffer: *objects.DoeBuffer) void {
    retain(allocator, list, buffer, exports.doeNativeBufferRelease);
}

pub fn retainTexture(allocator: std.mem.Allocator, list: *List, texture: *objects.DoeTexture) void {
    retain(allocator, list, texture, exports.doeNativeTextureRelease);
}

pub fn retainTextureView(allocator: std.mem.Allocator, list: *List, view: *objects.DoeTextureView) void {
    retain(allocator, list, view, exports.doeNativeTextureViewRelease);
}

pub fn retainRenderPipeline(allocator: std.mem.Allocator, list: *List, pipeline: *objects.DoeRenderPipeline) void {
    retain(allocator, list, pipeline, exports.doeNativeRenderPipelineRelease);
}

pub fn retainRenderBundle(allocator: std.mem.Allocator, list: *List, bundle: *@import("../../runtime/render/render_bundle.zig").DoeRenderBundle) void {
    retain(allocator, list, bundle, exports.doeNativeRenderBundleRelease);
}

pub fn retainDevice(allocator: std.mem.Allocator, list: *List, device: *objects.DoeDevice) void {
    retain(allocator, list, device, exports.doeNativeDeviceRelease);
}

pub fn retainPipeline(allocator: std.mem.Allocator, list: *List, pipeline: *objects.DoeComputePipeline) void {
    retain(allocator, list, pipeline, exports.doeNativeComputePipelineRelease);
}

pub fn retainBindGroup(allocator: std.mem.Allocator, list: *List, group: *objects.DoeBindGroup) void {
    retain(allocator, list, group, exports.doeNativeBindGroupRelease);
}

pub fn releaseAll(references: *List) void {
    @import("../../contracts/resource_lease.zig").releaseAll(helpers.alloc, references);
}
