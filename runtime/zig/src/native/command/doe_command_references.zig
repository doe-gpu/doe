const std = @import("std");
const objects = @import("../support/doe_native_object_types.zig");
const commands = @import("../support/doe_native_command_types.zig");
const helpers = @import("../support/doe_native_object_helpers.zig");
const exports = @import("../support/doe_native_exports.zig");

pub const List = std.ArrayListUnmanaged(commands.CommandReference);

fn retain(list: *List, object: anytype, release: *const fn (?*anyopaque) callconv(.c) void) void {
    list.appendAssumeCapacity(.{
        .handle = helpers.toOpaque(object),
        .release = release,
    });
    helpers.object_add_ref(@TypeOf(object.*), helpers.toOpaque(object));
}

pub fn retainBufferAssumeCapacity(list: *List, buffer: *objects.DoeBuffer) void {
    retain(list, buffer, exports.doeNativeBufferRelease);
}

pub fn retainTextureAssumeCapacity(list: *List, texture: *objects.DoeTexture) void {
    retain(list, texture, exports.doeNativeTextureRelease);
}

pub fn retainTextureViewAssumeCapacity(list: *List, view: *objects.DoeTextureView) void {
    retain(list, view, exports.doeNativeTextureViewRelease);
}

pub fn retainRenderPipelineAssumeCapacity(list: *List, pipeline: *objects.DoeRenderPipeline) void {
    retain(list, pipeline, exports.doeNativeRenderPipelineRelease);
}

pub fn retainRenderBundleAssumeCapacity(list: *List, bundle: *@import("../../runtime/render/render_bundle.zig").DoeRenderBundle) void {
    retain(list, bundle, exports.doeNativeRenderBundleRelease);
}

pub fn retainDeviceAssumeCapacity(list: *List, device: *objects.DoeDevice) void {
    retain(list, device, exports.doeNativeDeviceRelease);
}

pub fn retainPipelineAssumeCapacity(list: *List, pipeline: *objects.DoeComputePipeline) void {
    retain(list, pipeline, exports.doeNativeComputePipelineRelease);
}

pub fn retainBindGroupAssumeCapacity(list: *List, group: *objects.DoeBindGroup) void {
    retain(list, group, exports.doeNativeBindGroupRelease);
}

pub fn releaseAll(references: *List) void {
    @import("../../contracts/resource_lease.zig").releaseAll(helpers.alloc, references);
}
