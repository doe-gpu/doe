const c = @import("vk_constants.zig");
const model_binding_types = @import("../../contracts/model/model_binding_value_types.zig");
const model_compute_types = @import("../../contracts/model/model_compute_types.zig");

pub const MAX_TRACKED_COMPUTE_BINDINGS: usize = c.MAX_DESCRIPTOR_SETS * 16;

pub const ComputeBindingAccess = struct {
    resource_handle: u64 = 0,
    reads: bool = false,
    writes: bool = false,
};

pub fn make_prior_transfer_writes_visible(self: anytype, command_buffer: c.VkCommandBuffer) void {
    if (!self.has_pending_transfer_writes) return;
    const barrier = c.VkMemoryBarrier{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT,
        .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT,
    };
    c.vkCmdPipelineBarrier(
        command_buffer,
        c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        0,
        1,
        @ptrCast(&barrier),
        0,
        null,
        0,
        null,
    );
    self.has_pending_transfer_writes = false;
}

pub fn make_prior_transfer_writes_visible_for_indirect_dispatch(self: anytype, command_buffer: c.VkCommandBuffer) void {
    if (!self.has_pending_transfer_writes) return;
    const barrier = c.VkMemoryBarrier{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT,
        .dstAccessMask = c.VK_ACCESS_INDIRECT_COMMAND_READ_BIT |
            c.VK_ACCESS_SHADER_READ_BIT |
            c.VK_ACCESS_SHADER_WRITE_BIT,
    };
    c.vkCmdPipelineBarrier(
        command_buffer,
        c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        c.VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT | c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        0,
        1,
        @ptrCast(&barrier),
        0,
        null,
        0,
        null,
    );
    self.has_pending_transfer_writes = false;
}

pub fn make_prior_transfer_writes_visible_for_transfer_read(self: anytype, command_buffer: c.VkCommandBuffer) void {
    if (!self.has_pending_transfer_writes) return;
    const barrier = c.VkMemoryBarrier{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT,
        .dstAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT,
    };
    c.vkCmdPipelineBarrier(
        command_buffer,
        c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        0,
        1,
        @ptrCast(&barrier),
        0,
        null,
        0,
        null,
    );
    self.has_pending_transfer_writes = false;
}

pub fn make_prior_compute_writes_visible(self: anytype, command_buffer: c.VkCommandBuffer) void {
    if (!self.has_pending_compute_writes) return;
    emit_compute_write_visibility_barrier(self, command_buffer);
}

pub fn make_prior_compute_writes_visible_for_transfer_read(self: anytype, command_buffer: c.VkCommandBuffer) void {
    const barrier = c.VkMemoryBarrier{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT,
    };
    c.vkCmdPipelineBarrier(
        command_buffer,
        c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        0,
        1,
        @ptrCast(&barrier),
        0,
        null,
        0,
        null,
    );
    clear_pending_compute_writes(self);
}

pub fn make_prior_compute_writes_visible_for_buffer_copy(
    self: anytype,
    command_buffer: c.VkCommandBuffer,
    src_handle: u64,
    src_buffer: c.VkBuffer,
    dst_handle: u64,
    dst_buffer: c.VkBuffer,
) void {
    if (!self.has_pending_compute_writes) return;
    if (!self.pending_compute_write_tracking_complete or self.pending_compute_write_buffer_count == 0) {
        make_prior_compute_writes_visible_for_transfer_read(self, command_buffer);
        return;
    }

    var barriers = [_]c.VkBufferMemoryBarrier{
        buffer_memory_barrier(src_buffer, c.VK_ACCESS_TRANSFER_READ_BIT),
        buffer_memory_barrier(dst_buffer, c.VK_ACCESS_TRANSFER_WRITE_BIT),
    };
    var barrier_count: u32 = 0;
    if (src_handle != 0 and pending_compute_write_buffer_contains(self, src_handle)) {
        barrier_count = 1;
    }
    if (dst_handle != 0 and pending_compute_write_buffer_contains(self, dst_handle)) {
        if (barrier_count == 1 and src_handle == dst_handle) {
            barriers[0].dstAccessMask |= c.VK_ACCESS_TRANSFER_WRITE_BIT;
        } else {
            barriers[barrier_count] = buffer_memory_barrier(dst_buffer, c.VK_ACCESS_TRANSFER_WRITE_BIT);
            barrier_count += 1;
        }
    }
    if (barrier_count == 0) return;

    c.vkCmdPipelineBarrier(
        command_buffer,
        c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        0,
        0,
        null,
        barrier_count,
        @ptrCast(&barriers),
        0,
        null,
    );

    if (src_handle != 0) remove_pending_compute_write_buffer(self, src_handle);
    if (dst_handle != 0 and dst_handle != src_handle) remove_pending_compute_write_buffer(self, dst_handle);
    self.has_pending_compute_writes = self.pending_compute_write_buffer_count != 0;
}

pub fn make_prior_compute_writes_visible_for_indirect_read(
    self: anytype,
    command_buffer: c.VkCommandBuffer,
    resource_handle: u64,
    buffer: c.VkBuffer,
) void {
    if (!self.has_pending_compute_writes) return;
    if (!self.pending_compute_write_tracking_complete or self.pending_compute_write_buffer_count == 0) {
        const barrier = c.VkMemoryBarrier{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT,
            .dstAccessMask = c.VK_ACCESS_INDIRECT_COMMAND_READ_BIT,
        };
        c.vkCmdPipelineBarrier(
            command_buffer,
            c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            c.VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT,
            0,
            1,
            @ptrCast(&barrier),
            0,
            null,
            0,
            null,
        );
        clear_pending_compute_writes(self);
        return;
    }
    if (!pending_compute_write_buffer_contains(self, resource_handle)) return;
    var barrier = buffer_memory_barrier(buffer, c.VK_ACCESS_INDIRECT_COMMAND_READ_BIT);
    c.vkCmdPipelineBarrier(
        command_buffer,
        c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        c.VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT,
        0,
        0,
        null,
        1,
        @ptrCast(&barrier),
        0,
        null,
    );
    remove_pending_compute_write_buffer(self, resource_handle);
    self.has_pending_compute_writes = self.pending_compute_write_buffer_count != 0;
}

pub fn make_transfer_writes_visible_for_host_read(command_buffer: c.VkCommandBuffer) void {
    const barrier = c.VkMemoryBarrier{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT,
        .dstAccessMask = c.VK_ACCESS_HOST_READ_BIT,
    };
    c.vkCmdPipelineBarrier(
        command_buffer,
        c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        c.VK_PIPELINE_STAGE_HOST_BIT,
        0,
        1,
        @ptrCast(&barrier),
        0,
        null,
        0,
        null,
    );
}

pub fn capture_current_compute_bindings(
    self: anytype,
    bindings: ?[]const model_compute_types.KernelBinding,
) void {
    self.current_compute_binding_count = 0;
    self.current_compute_binding_tracking_complete = true;
    const bs = bindings orelse return;

    for (bs) |binding| {
        if (binding.resource_kind != .buffer or binding.resource_handle == 0) continue;
        const access = access_for_buffer_binding(binding);
        if (!access.reads and !access.writes) continue;
        if (merge_current_binding_access(self, binding.resource_handle, access)) continue;

        const index: usize = @intCast(self.current_compute_binding_count);
        if (index >= MAX_TRACKED_COMPUTE_BINDINGS) {
            self.current_compute_binding_tracking_complete = false;
            return;
        }
        self.current_compute_bindings[index] = .{
            .resource_handle = binding.resource_handle,
            .reads = access.reads,
            .writes = access.writes,
        };
        self.current_compute_binding_count += 1;
    }
}

pub fn make_prior_compute_writes_visible_for_current_bindings(
    self: anytype,
    command_buffer: c.VkCommandBuffer,
) void {
    if (!self.has_pending_compute_writes) return;
    if (!self.pending_compute_write_tracking_complete or self.pending_compute_write_buffer_count == 0) {
        emit_compute_write_visibility_barrier(self, command_buffer);
        return;
    }

    for (current_compute_bindings(self)) |binding| {
        if (!binding.reads and !binding.writes) continue;
        if (pending_compute_write_buffer_contains(self, binding.resource_handle)) {
            emit_compute_write_visibility_barrier(self, command_buffer);
            return;
        }
    }
}

pub fn remember_current_compute_writes(self: anytype) void {
    if (!self.current_compute_binding_tracking_complete) {
        clear_pending_compute_write_buffers(self);
        self.pending_compute_write_tracking_complete = false;
        self.has_pending_compute_writes = true;
        return;
    }

    var recorded_write = false;
    for (current_compute_bindings(self)) |binding| {
        if (!binding.writes) continue;
        recorded_write = true;
        add_pending_compute_write_buffer(self, binding.resource_handle) catch {
            clear_pending_compute_write_buffers(self);
            self.pending_compute_write_tracking_complete = false;
            self.has_pending_compute_writes = true;
            return;
        };
    }
    if (recorded_write) self.has_pending_compute_writes = true;
}

pub fn clear_pending_compute_writes(self: anytype) void {
    self.has_pending_compute_writes = false;
    self.pending_compute_write_tracking_complete = true;
    clear_pending_compute_write_buffers(self);
}

fn emit_compute_write_visibility_barrier(self: anytype, command_buffer: c.VkCommandBuffer) void {
    const barrier = c.VkMemoryBarrier{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT,
    };
    c.vkCmdPipelineBarrier(
        command_buffer,
        c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        0,
        1,
        @ptrCast(&barrier),
        0,
        null,
        0,
        null,
    );
    clear_pending_compute_writes(self);
}

fn buffer_memory_barrier(buffer: c.VkBuffer, dst_access_mask: u32) c.VkBufferMemoryBarrier {
    return .{
        .sType = c.VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask = dst_access_mask,
        .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .buffer = buffer,
        .offset = 0,
        .size = c.VK_WHOLE_SIZE,
    };
}

fn access_for_buffer_binding(binding: model_compute_types.KernelBinding) ComputeBindingAccess {
    return switch (binding.buffer_type) {
        model_binding_types.WGPUBufferBindingType_Uniform,
        model_binding_types.WGPUBufferBindingType_ReadOnlyStorage,
        => .{ .reads = true },
        model_binding_types.WGPUBufferBindingType_Storage => .{ .reads = true, .writes = true },
        else => .{ .reads = true, .writes = true },
    };
}

fn current_compute_bindings(self: anytype) []const ComputeBindingAccess {
    const count: usize = @intCast(self.current_compute_binding_count);
    return self.current_compute_bindings[0..count];
}

pub fn pending_compute_write_buffer_contains(self: anytype, resource_handle: u64) bool {
    if (resource_handle == 0) return false;
    if (!self.pending_compute_write_tracking_complete) return true;
    for (self.pending_compute_write_buffer_handles[0..@intCast(self.pending_compute_write_buffer_count)]) |handle| {
        if (handle == resource_handle) return true;
    }
    return false;
}

fn add_pending_compute_write_buffer(self: anytype, resource_handle: u64) !void {
    if (resource_handle == 0 or pending_compute_write_buffer_contains(self, resource_handle)) return;
    const index: usize = @intCast(self.pending_compute_write_buffer_count);
    if (index >= MAX_TRACKED_COMPUTE_BINDINGS) return error.Overflow;
    self.pending_compute_write_buffer_handles[index] = resource_handle;
    self.pending_compute_write_buffer_count += 1;
}

fn remove_pending_compute_write_buffer(self: anytype, resource_handle: u64) void {
    if (resource_handle == 0 or !self.pending_compute_write_tracking_complete) return;
    var index: usize = 0;
    const count: usize = @intCast(self.pending_compute_write_buffer_count);
    while (index < count) : (index += 1) {
        if (self.pending_compute_write_buffer_handles[index] != resource_handle) continue;
        const last_index = count - 1;
        self.pending_compute_write_buffer_handles[index] = self.pending_compute_write_buffer_handles[last_index];
        self.pending_compute_write_buffer_handles[last_index] = 0;
        self.pending_compute_write_buffer_count -= 1;
        return;
    }
}

fn clear_pending_compute_write_buffers(self: anytype) void {
    const count: usize = @intCast(self.pending_compute_write_buffer_count);
    @memset(self.pending_compute_write_buffer_handles[0..count], 0);
    self.pending_compute_write_buffer_count = 0;
}

fn merge_current_binding_access(self: anytype, resource_handle: u64, access: ComputeBindingAccess) bool {
    for (self.current_compute_bindings[0..@intCast(self.current_compute_binding_count)]) |*binding| {
        if (binding.resource_handle != resource_handle) continue;
        binding.reads = binding.reads or access.reads;
        binding.writes = binding.writes or access.writes;
        return true;
    }
    return false;
}
