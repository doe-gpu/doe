const c = @import("vk_constants.zig");
const vk_compute_sync = @import("vk_compute_sync.zig");
const vk_pipeline = @import("vk_pipeline.zig");

const VK_NULL_U64 = c.VK_NULL_U64;

pub fn record_prepared_replay(
    self: anytype,
    indirect_buffer: c.VkBuffer,
    indirect_offset: u64,
    indirect_resource_handle: u64,
) !void {
    if (!self.has_pipeline) return error.Unsupported;
    if (indirect_buffer == VK_NULL_U64) return error.InvalidArgument;
    const command_buffer = try self.begin_prepared_dispatch_replay();
    vk_compute_sync.make_prior_transfer_writes_visible_for_indirect_dispatch(self, command_buffer);
    vk_compute_sync.make_prior_compute_writes_visible_for_indirect_read(self, command_buffer, indirect_resource_handle, indirect_buffer);
    vk_compute_sync.make_prior_compute_writes_visible_for_current_bindings(self, command_buffer);
    vk_pipeline.bind_compute_pipeline_if_needed(self, command_buffer);
    vk_pipeline.bind_descriptor_sets_if_needed(self, command_buffer);
    c.vkCmdDispatchIndirect(command_buffer, indirect_buffer, indirect_offset);
    vk_compute_sync.remember_current_compute_writes(self);
}
