const std = @import("std");
const model_transfer_types = @import("../../contracts/model/model_resource_types.zig");
const model_async_types = @import("../../contracts/model/model_async_types.zig");
const proc_types = @import("../abi/wgpu_proc_types.zig");
const abi_base = proc_types.base;
const abi_descriptor = proc_types.descriptor;
const abi_execution = @import("../abi/wgpu_execution_types.zig");
const loader = @import("../abi/wgpu_loader.zig");
const resources = @import("wgpu_resources.zig");
const TEMP_BUFFER_TO_TEXTURE_KEY_OFFSET: u64 = 0xFFFF_0000_0000_0001;
const TEMP_TEXTURE_TO_TEXTURE_KEY_OFFSET: u64 = 0xFFFF_0000_0000_0002;

const MapAsyncContext = struct {
    resolved: bool = false,
    status: abi_base.WGPUBufferMapAsyncStatus = undefined,
};

fn onMapBufferCallback(
    status: abi_base.WGPUMapAsyncStatus,
    message: abi_base.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = message;
    _ = userdata2;
    if (userdata1) |ptr| {
        var context = @as(*MapAsyncContext, @ptrCast(@alignCast(ptr)));
        context.status = status;
        context.resolved = true;
    }
}

pub fn executeMapAsync(self: anytype, command: model_async_types.MapAsyncCommand) !abi_execution.NativeExecutionResult {
    const setup_start_ns = std.time.nanoTimestamp();
    const bytes = @as(u64, command.bytes);

    const usage: abi_base.WGPUBufferUsage = if (command.mode == .read)
        abi_base.WGPUBufferUsage_MapRead | abi_base.WGPUBufferUsage_CopyDst
    else
        abi_base.WGPUBufferUsage_MapWrite | abi_base.WGPUBufferUsage_CopySrc;

    const buffer = try resources.getOrCreateBuffer(self, loader.BUFFER_MAP_ASYNC_KEY, bytes, usage);

    // Unmap first in case it was mapped from a previous iteration
    self.core.procs.?.wgpuBufferUnmap(buffer);

    var map_context = MapAsyncContext{};
    const mode_flag: abi_base.WGPUMapMode = if (command.mode == .read) abi_base.WGPUMapMode_Read else abi_base.WGPUMapMode_Write;

    // Map the buffer
    _ = self.core.procs.?.wgpuBufferMapAsync(
        buffer,
        mode_flag,
        0,
        bytes,
        .{
            .nextInChain = null,
            .mode = abi_descriptor.WGPUCallbackMode_WaitAnyOnly,
            .callback = onMapBufferCallback,
            .userdata1 = &map_context,
            .userdata2 = null,
        },
    );

    const setup_end_ns = std.time.nanoTimestamp();

    // Spin block wait for map_async completion
    const submit_wait_start_ns = std.time.nanoTimestamp();
    while (!map_context.resolved) {
        // Yield to browser/Dawn queue to resolve futures
        _ = try self.waitForQueueProcessEvents();
    }
    const submit_wait_end_ns = std.time.nanoTimestamp();

    if (map_context.status != abi_base.WGPUBufferMapAsyncStatus_Success) {
        return .{
            .status = .@"error",
            .status_message = "buffer map async failed",
        };
    }

    if (command.mode == .write) {
        const mapped_ptr = self.core.procs.?.wgpuBufferGetMappedRange(buffer, 0, bytes);
        if (mapped_ptr != null) {
            // Write some dummy data zero payload to force page fault materialization
            @memset(@as([*]u8, @ptrCast(mapped_ptr))[0..bytes], 0);
        }
    }

    // Clean up map for next iteration (benchmarks map/unmap synchronously inside operations)
    self.core.procs.?.wgpuBufferUnmap(buffer);

    const setup_ns = if (setup_end_ns > setup_start_ns) @as(u64, @intCast(setup_end_ns - setup_start_ns)) else 0;
    const submit_wait_ns = if (submit_wait_end_ns > submit_wait_start_ns) @as(u64, @intCast(submit_wait_end_ns - submit_wait_start_ns)) else 0;

    return .{
        .status = .ok,
        .status_message = "buffer map resolved synchronously",
        .setup_ns = setup_ns,
        .submit_wait_ns = submit_wait_ns,
    };
}

pub fn executeUpload(self: anytype, upload: model_transfer_types.UploadCommand) !abi_execution.NativeExecutionResult {
    const setup_start_ns = std.time.nanoTimestamp();
    const bytes = @as(u64, upload.bytes);

    const usage = switch (self.core.upload_buffer_usage_mode) {
        .copy_dst_copy_src => abi_base.WGPUBufferUsage_CopyDst | abi_base.WGPUBufferUsage_CopySrc,
        .copy_dst => abi_base.WGPUBufferUsage_CopyDst,
    };
    const upload_buffer = try resources.getOrCreateBuffer(self, loader.BUFFER_UPLOAD_KEY, bytes, usage);
    const bytes_usize = std.math.cast(usize, bytes) orelse unreachable;

    if (bytes_usize > self.core.upload_scratch.len) {
        if (self.core.upload_scratch.len > 0) {
            self.core.allocator.free(self.core.upload_scratch);
        }
        self.core.upload_scratch = try self.core.allocator.alloc(u8, bytes_usize);
        @memset(self.core.upload_scratch, 0);
    }
    const staging = self.core.upload_scratch[0..bytes_usize];
    self.core.procs.?.wgpuQueueWriteBuffer(self.core.queue.?, upload_buffer, 0, @ptrCast(staging.ptr), bytes_usize);
    const setup_end_ns = std.time.nanoTimestamp();

    self.core.upload_submit_pending += 1;
    var submit_wait_ns: u64 = 0;
    if (self.core.upload_submit_pending >= self.core.upload_submit_every) {
        submit_wait_ns = try self.submitEmpty();
        self.core.upload_submit_pending = 0;
    }

    const setup_ns = if (setup_end_ns > setup_start_ns)
        @as(u64, @intCast(setup_end_ns - setup_start_ns))
    else
        0;

    return .{
        .status = .ok,
        .status_message = "upload staged via queueWriteBuffer",
        .setup_ns = setup_ns,
        .submit_wait_ns = submit_wait_ns,
    };
}

pub fn executeBufferWrite(self: anytype, command: model_transfer_types.BufferWriteCommand) !abi_execution.NativeExecutionResult {
    return executeBufferWriteBytes(
        self,
        command.handle,
        command.offset,
        command.buffer_size,
        std.mem.sliceAsBytes(command.data),
    );
}

pub fn executeBufferWriteBytes(
    self: anytype,
    handle: u64,
    offset: u64,
    buffer_size: u64,
    data_bytes: []const u8,
) !abi_execution.NativeExecutionResult {
    const setup_start_ns = std.time.nanoTimestamp();
    if (data_bytes.len == 0) return error.InvalidArgument;

    const required_size = if (buffer_size > 0)
        @max(buffer_size, try resources.requiredBytes(data_bytes.len, offset))
    else
        try resources.requiredBytes(data_bytes.len, offset);
    const usage = abi_base.WGPUBufferUsage_Storage |
        abi_base.WGPUBufferUsage_Uniform |
        abi_base.WGPUBufferUsage_CopyDst |
        abi_base.WGPUBufferUsage_CopySrc;
    const buffer = try resources.getOrCreateBuffer(self, handle, required_size, usage);
    self.core.procs.?.wgpuQueueWriteBuffer(
        self.core.queue.?,
        buffer,
        offset,
        @ptrCast(data_bytes.ptr),
        data_bytes.len,
    );
    const setup_end_ns = std.time.nanoTimestamp();

    self.core.upload_submit_pending += 1;
    var submit_wait_ns: u64 = 0;
    if (self.core.upload_submit_pending >= self.core.upload_submit_every) {
        submit_wait_ns = try self.submitEmpty();
        self.core.upload_submit_pending = 0;
    }

    const setup_ns = if (setup_end_ns > setup_start_ns)
        @as(u64, @intCast(setup_end_ns - setup_start_ns))
    else
        0;

    return .{
        .status = .ok,
        .status_message = "buffer seeded via queueWriteBuffer",
        .setup_ns = setup_ns,
        .submit_wait_ns = submit_wait_ns,
    };
}

pub fn executeCopy(self: anytype, copy: model_transfer_types.CopyCommand) !abi_execution.NativeExecutionResult {
    const bytes = @as(u64, copy.bytes);

    const procs = self.core.procs orelse return error.ProceduralNotReady;

    const setup_start_ns = std.time.nanoTimestamp();
    const encoder = procs.wgpuDeviceCreateCommandEncoder(self.core.device.?, &abi_descriptor.WGPUCommandEncoderDescriptor{
        .nextInChain = null,
        .label = loader.emptyStringView(),
    });
    if (encoder == null) {
        return .{ .status = .@"error", .status_message = "deviceCreateCommandEncoder returned null" };
    }
    defer procs.wgpuCommandEncoderRelease(encoder);
    const setup_end_ns = std.time.nanoTimestamp();

    const encode_start_ns = std.time.nanoTimestamp();
    switch (copy.direction) {
        .buffer_to_buffer => {
            const src_size = try resources.requiredBytes(bytes, copy.src.offset);
            const dst_size = try resources.requiredBytes(bytes, copy.dst.offset);
            const src = try resources.getOrCreateBufferInitialized(
                self,
                copy.src.handle,
                src_size,
                abi_base.WGPUBufferUsage_CopySrc | abi_base.WGPUBufferUsage_CopyDst,
            );
            const dst = try resources.getOrCreateBuffer(self, copy.dst.handle, dst_size, abi_base.WGPUBufferUsage_CopyDst);
            procs.wgpuCommandEncoderCopyBufferToBuffer(encoder, src, copy.src.offset, dst, copy.dst.offset, bytes);
        },
        .buffer_to_texture => {
            const copy_extent = abi_descriptor.WGPUExtent3D{
                .width = copy.dst.width,
                .height = copy.dst.height,
                .depthOrArrayLayers = copy.dst.depth_or_array_layers,
            };
            const src_size = try resources.requiredBytes(bytes, copy.src.offset);
            const dst = try resources.getOrCreateTexture(self, copy.dst, abi_base.WGPUTextureUsage_CopyDst);

            if (copy.uses_temporary_buffer) {
                const alignment: u64 = @max(copy.temporary_buffer_alignment, 1);
                const aligned_size = ((bytes + alignment - 1) / alignment) * alignment;
                const src = try resources.getOrCreateBufferInitialized(
                    self,
                    copy.src.handle,
                    src_size,
                    abi_base.WGPUBufferUsage_CopySrc | abi_base.WGPUBufferUsage_CopyDst,
                );
                const temp_key = copy.src.handle +% TEMP_BUFFER_TO_TEXTURE_KEY_OFFSET;
                const temp = try resources.getOrCreateBuffer(self, temp_key, aligned_size, abi_base.WGPUBufferUsage_CopySrc | abi_base.WGPUBufferUsage_CopyDst);
                procs.wgpuCommandEncoderCopyBufferToBuffer(encoder, src, copy.src.offset, temp, 0, bytes);
                procs.wgpuCommandEncoderCopyBufferToTexture(
                    encoder,
                    &abi_descriptor.WGPUTexelCopyBufferInfo{
                        .layout = .{
                            .offset = 0,
                            .bytesPerRow = copyBufferBytesPerRow(copy),
                            .rowsPerImage = copyBufferRowsPerImage(copy),
                        },
                        .buffer = temp,
                    },
                    &abi_descriptor.WGPUTexelCopyTextureInfo{
                        .texture = dst,
                        .mipLevel = copy.dst.mip_level,
                        .origin = .{ .x = 0, .y = 0, .z = 0 },
                        .aspect = loader.normalizeTextureAspect(copy.dst.aspect),
                    },
                    &copy_extent,
                );
            } else {
                const src = try resources.getOrCreateBufferInitialized(
                    self,
                    copy.src.handle,
                    src_size,
                    abi_base.WGPUBufferUsage_CopySrc | abi_base.WGPUBufferUsage_CopyDst,
                );
                procs.wgpuCommandEncoderCopyBufferToTexture(
                    encoder,
                    &abi_descriptor.WGPUTexelCopyBufferInfo{
                        .layout = .{
                            .offset = copy.src.offset,
                            .bytesPerRow = copyBufferBytesPerRow(copy),
                            .rowsPerImage = copyBufferRowsPerImage(copy),
                        },
                        .buffer = src,
                    },
                    &abi_descriptor.WGPUTexelCopyTextureInfo{
                        .texture = dst,
                        .mipLevel = copy.dst.mip_level,
                        .origin = .{ .x = 0, .y = 0, .z = 0 },
                        .aspect = loader.normalizeTextureAspect(copy.dst.aspect),
                    },
                    &copy_extent,
                );
            }
        },
        .texture_to_buffer => {
            const copy_extent = abi_descriptor.WGPUExtent3D{
                .width = copy.src.width,
                .height = copy.src.height,
                .depthOrArrayLayers = copy.src.depth_or_array_layers,
            };
            const dst_size = try resources.requiredBytes(bytes, copy.dst.offset);
            const src = try resources.getOrCreateTextureInitialized(
                self,
                copy.src,
                abi_base.WGPUTextureUsage_CopySrc | abi_base.WGPUTextureUsage_CopyDst,
            );
            const dst = try resources.getOrCreateBuffer(self, copy.dst.handle, dst_size, abi_base.WGPUBufferUsage_CopyDst);
            procs.wgpuCommandEncoderCopyTextureToBuffer(
                encoder,
                &abi_descriptor.WGPUTexelCopyTextureInfo{
                    .texture = src,
                    .mipLevel = copy.src.mip_level,
                    .origin = .{ .x = 0, .y = 0, .z = 0 },
                    .aspect = loader.normalizeTextureAspect(copy.src.aspect),
                },
                &abi_descriptor.WGPUTexelCopyBufferInfo{
                    .layout = .{
                        .offset = copy.dst.offset,
                        .bytesPerRow = copyBufferBytesPerRow(copy),
                        .rowsPerImage = copyBufferRowsPerImage(copy),
                    },
                    .buffer = dst,
                },
                &copy_extent,
            );
        },
        .texture_to_texture => {
            const copy_extent = abi_descriptor.WGPUExtent3D{
                .width = copy.src.width,
                .height = copy.src.height,
                .depthOrArrayLayers = copy.src.depth_or_array_layers,
            };
            if (copy.uses_temporary_buffer) {
                // Workaround path: tex → temp buffer → tex (avoids direct tex-to-tex copy bugs)
                const alignment: u64 = @max(copy.temporary_buffer_alignment, 1);
                const aligned_size = ((bytes + alignment - 1) / alignment) * alignment;
                const temp_key = copy.src.handle +% TEMP_TEXTURE_TO_TEXTURE_KEY_OFFSET;
                const temp = try resources.getOrCreateBuffer(self, temp_key, aligned_size, abi_base.WGPUBufferUsage_CopySrc | abi_base.WGPUBufferUsage_CopyDst);
                const src = try resources.getOrCreateTextureInitialized(
                    self,
                    copy.src,
                    abi_base.WGPUTextureUsage_CopySrc | abi_base.WGPUTextureUsage_CopyDst,
                );
                const dst = try resources.getOrCreateTexture(self, copy.dst, abi_base.WGPUTextureUsage_CopyDst);

                procs.wgpuCommandEncoderCopyTextureToBuffer(
                    encoder,
                    &abi_descriptor.WGPUTexelCopyTextureInfo{
                        .texture = src,
                        .mipLevel = copy.src.mip_level,
                        .origin = .{ .x = 0, .y = 0, .z = 0 },
                        .aspect = loader.normalizeTextureAspect(copy.src.aspect),
                    },
                    &abi_descriptor.WGPUTexelCopyBufferInfo{
                        .layout = .{
                            .offset = 0,
                            .bytesPerRow = copyTextureSourceBytesPerRow(copy),
                            .rowsPerImage = copyTextureSourceRowsPerImage(copy),
                        },
                        .buffer = temp,
                    },
                    &copy_extent,
                );

                procs.wgpuCommandEncoderCopyBufferToTexture(
                    encoder,
                    &abi_descriptor.WGPUTexelCopyBufferInfo{
                        .layout = .{
                            .offset = 0,
                            .bytesPerRow = copyTextureDestinationBytesPerRow(copy),
                            .rowsPerImage = copyTextureDestinationRowsPerImage(copy),
                        },
                        .buffer = temp,
                    },
                    &abi_descriptor.WGPUTexelCopyTextureInfo{
                        .texture = dst,
                        .mipLevel = copy.dst.mip_level,
                        .origin = .{ .x = 0, .y = 0, .z = 0 },
                        .aspect = loader.normalizeTextureAspect(copy.dst.aspect),
                    },
                    &abi_descriptor.WGPUExtent3D{
                        .width = copy.dst.width,
                        .height = copy.dst.height,
                        .depthOrArrayLayers = copy.dst.depth_or_array_layers,
                    },
                );
            } else {
                const src = try resources.getOrCreateTextureInitialized(
                    self,
                    copy.src,
                    abi_base.WGPUTextureUsage_CopySrc | abi_base.WGPUTextureUsage_CopyDst,
                );
                const dst = try resources.getOrCreateTexture(self, copy.dst, abi_base.WGPUTextureUsage_CopyDst);
                procs.wgpuCommandEncoderCopyTextureToTexture(
                    encoder,
                    &abi_descriptor.WGPUTexelCopyTextureInfo{
                        .texture = src,
                        .mipLevel = copy.src.mip_level,
                        .origin = .{ .x = 0, .y = 0, .z = 0 },
                        .aspect = loader.normalizeTextureAspect(copy.src.aspect),
                    },
                    &abi_descriptor.WGPUTexelCopyTextureInfo{
                        .texture = dst,
                        .mipLevel = copy.dst.mip_level,
                        .origin = .{ .x = 0, .y = 0, .z = 0 },
                        .aspect = loader.normalizeTextureAspect(copy.dst.aspect),
                    },
                    &copy_extent,
                );
            }
        },
    }

    const command_buffer = procs.wgpuCommandEncoderFinish(encoder, &abi_descriptor.WGPUCommandBufferDescriptor{
        .nextInChain = null,
        .label = loader.emptyStringView(),
    });
    const encode_end_ns = std.time.nanoTimestamp();
    const setup_ns = if (setup_end_ns > setup_start_ns)
        @as(u64, @intCast(setup_end_ns - setup_start_ns))
    else
        0;
    const encode_ns = if (encode_end_ns > encode_start_ns)
        @as(u64, @intCast(encode_end_ns - encode_start_ns))
    else
        0;
    if (command_buffer == null) {
        return .{ .status = .@"error", .status_message = "commandEncoderFinish returned null", .setup_ns = setup_ns, .encode_ns = encode_ns };
    }
    defer procs.wgpuCommandBufferRelease(command_buffer);

    var commands = [_]abi_base.WGPUCommandBuffer{command_buffer};
    const submit_wait_ns = try self.submitCommandBuffers(commands[0..]);

    return .{
        .status = .ok,
        .status_message = switch (copy.direction) {
            .buffer_to_buffer => "copy-buffer-to-buffer command submitted",
            .buffer_to_texture => "copy-buffer-to-texture command submitted",
            .texture_to_buffer => "copy-texture-to-buffer command submitted",
            .texture_to_texture => "copy-texture-to-texture command submitted",
        },
        .setup_ns = setup_ns,
        .encode_ns = encode_ns,
        .submit_wait_ns = submit_wait_ns,
    };
}

fn copyBufferBytesPerRow(copy: model_transfer_types.CopyCommand) u32 {
    return loader.normalizeCopyLayoutValue(switch (copy.direction) {
        .texture_to_buffer => firstNonZeroU32(copy.dst.bytes_per_row, copy.src.bytes_per_row),
        else => firstNonZeroU32(copy.src.bytes_per_row, copy.dst.bytes_per_row),
    });
}

fn copyBufferRowsPerImage(copy: model_transfer_types.CopyCommand) u32 {
    return loader.normalizeCopyLayoutValue(switch (copy.direction) {
        .texture_to_buffer => firstNonZeroU32(copy.dst.rows_per_image, copy.src.rows_per_image),
        else => firstNonZeroU32(copy.src.rows_per_image, copy.dst.rows_per_image),
    });
}

fn copyTextureSourceBytesPerRow(copy: model_transfer_types.CopyCommand) u32 {
    return loader.normalizeCopyLayoutValue(firstNonZeroU32(copy.src.bytes_per_row, copy.dst.bytes_per_row));
}

fn copyTextureSourceRowsPerImage(copy: model_transfer_types.CopyCommand) u32 {
    return loader.normalizeCopyLayoutValue(firstNonZeroU32(copy.src.rows_per_image, copy.dst.rows_per_image));
}

fn copyTextureDestinationBytesPerRow(copy: model_transfer_types.CopyCommand) u32 {
    return loader.normalizeCopyLayoutValue(firstNonZeroU32(copy.dst.bytes_per_row, copy.src.bytes_per_row));
}

fn copyTextureDestinationRowsPerImage(copy: model_transfer_types.CopyCommand) u32 {
    return loader.normalizeCopyLayoutValue(firstNonZeroU32(copy.dst.rows_per_image, copy.src.rows_per_image));
}

fn firstNonZeroU32(primary: u32, fallback: u32) u32 {
    return if (primary != 0) primary else fallback;
}
