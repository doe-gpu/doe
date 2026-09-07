const builtin = @import("builtin");
const has_vulkan = (builtin.os.tag == .linux);
const std = @import("std");

const error_scope = @import("../runtime/diagnostics/error_scope.zig");
const model_transfer_types = @import("../contracts/model/model_resource_types.zig");
const native_types = @import("../native/support/doe_native_object_types.zig");
const native_rt_helpers = @import("../native/support/doe_native_runtime_helpers.zig");

pub const metal_bridge = @import("metal/metal_bridge_decls.zig");
pub const d3d12_constants = @import("d3d12/d3d12_constants.zig");
pub const d3d12_formats = @import("d3d12/d3d12_formats.zig");
pub const vk_constants = if (builtin.os.tag == .linux) @import("vulkan/vk_constants.zig") else struct {};
pub const vk_resources = if (builtin.os.tag == .linux) @import("vulkan/vk_resources.zig") else struct {};
pub const vk_timestamp = if (builtin.os.tag == .linux) @import("vulkan/vk_timestamp.zig") else struct {};
pub const vk_dispatch_indirect = if (builtin.os.tag == .linux) @import("vulkan/vk_dispatch_indirect.zig") else struct {};

const DoeBuffer = native_types.DoeBuffer;
const DoeCommandEncoder = native_types.DoeCommandEncoder;
const DoeDevice = native_types.DoeDevice;
const DoeQueue = native_types.DoeQueue;
const DoeTexture = native_types.DoeTexture;

pub const QueueWriteTextureArgs = struct {
    data_ptr: [*]const u8,
    data_len: usize,
    bytes_per_row: u32,
    rows_per_image: u32,
    dst_mip: u32,
    height: u32,
};

fn copyTextureResource(
    texture: *DoeTexture,
    mip_level: u32,
    bytes_per_row: u32,
    rows_per_image: u32,
) model_transfer_types.CopyTextureResource {
    return .{
        .handle = texture.vk_id,
        .kind = .texture,
        .width = texture.width,
        .height = texture.height,
        .depth_or_array_layers = texture.depth_or_array_layers,
        .format = texture.format,
        .usage = texture.usage,
        .dimension = texture.dimension,
        .mip_level = mip_level,
        .sample_count = texture.sample_count,
        .bytes_per_row = bytes_per_row,
        .rows_per_image = rows_per_image,
    };
}

fn failVulkanResourceOp(dev: *DoeDevice, comptime operation: []const u8, reason: []const u8) bool {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Vulkan {s} failed: {s}", .{ operation, reason }) catch "Vulkan resource operation failed";
    std.log.err("dropin_resource_ops: {s}", .{msg});
    dev.error_scopes.deliver(error_scope.ERROR_TYPE_INTERNAL, msg);
    return true;
}

fn failVulkanResourceError(dev: *DoeDevice, comptime operation: []const u8, err: anyerror) bool {
    return failVulkanResourceOp(dev, operation, @errorName(err));
}

pub fn handleVulkanCopyTextureToBuffer(
    enc: *DoeCommandEncoder,
    src_texture: *DoeTexture,
    src_mip_level: u32,
    dst_buffer: *DoeBuffer,
    dst_offset: u64,
    dst_bytes_per_row: u32,
    dst_rows_per_image: u32,
    width: u32,
    height: u32,
    depth_or_array_layers: u32,
) bool {
    _ = depth_or_array_layers;
    if (enc.dev.backend != .vulkan) return false;
    if (comptime !has_vulkan) return failVulkanResourceOp(enc.dev, "copyTextureToBuffer", "backend compiled without Vulkan support");
    const rt = native_rt_helpers.device_vk_runtime(enc.dev) orelse
        return failVulkanResourceOp(enc.dev, "copyTextureToBuffer", "device has no Vulkan runtime");
    if (src_texture.vk_id == 0) return failVulkanResourceOp(enc.dev, "copyTextureToBuffer", "source texture has no Vulkan resource");
    if (dst_buffer.vk_id == 0) return failVulkanResourceOp(enc.dev, "copyTextureToBuffer", "destination buffer has no Vulkan resource");
    const dcb = rt.compute_buffers.get(dst_buffer.vk_id) orelse
        return failVulkanResourceOp(enc.dev, "copyTextureToBuffer", "destination buffer resource is not registered");
    const mapped_ptr = dcb.mapped orelse
        return failVulkanResourceOp(enc.dev, "copyTextureToBuffer", "destination buffer resource is not CPU-mapped");
    rt.texture_read(.{
        .handle = src_texture.vk_id,
        .mip_level = src_mip_level,
        .width = width,
        .height = height,
        .format = src_texture.format,
        .dst_buffer = @as(*anyopaque, @ptrCast(mapped_ptr)),
        .dst_offset = dst_offset,
        .dst_bytes_per_row = dst_bytes_per_row,
        .dst_rows_per_image = dst_rows_per_image,
    }) catch |err| return failVulkanResourceError(enc.dev, "copyTextureToBuffer", err);
    return true;
}

pub fn handleVulkanQueueWriteTexture(
    queue: ?*DoeQueue,
    texture: *DoeTexture,
    args: QueueWriteTextureArgs,
) bool {
    const q = queue orelse return false;
    if (q.dev.backend != .vulkan) return false;
    if (comptime !has_vulkan) return failVulkanResourceOp(q.dev, "writeTexture", "backend compiled without Vulkan support");
    const rt = native_rt_helpers.device_vk_runtime(q.dev) orelse
        return failVulkanResourceOp(q.dev, "writeTexture", "device has no Vulkan runtime");
    if (texture.vk_id == 0) return failVulkanResourceOp(q.dev, "writeTexture", "texture has no Vulkan resource");
    const rows = if (args.rows_per_image > 0) args.rows_per_image else args.height;
    const copy_res = copyTextureResource(texture, args.dst_mip, args.bytes_per_row, rows);
    rt.texture_write(.{ .texture = copy_res, .data = args.data_ptr[0..args.data_len] }) catch |err|
        return failVulkanResourceError(q.dev, "writeTexture", err);
    return true;
}
