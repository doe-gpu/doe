const common_timing = @import("../common/timing.zig");
const model_render_types = @import("../../contracts/model/model_render_types.zig");
const webgpu = @import("../runtime_types.zig");
const bridge = @import("metal_bridge_decls.zig");

pub const RenderMetrics = struct {
    setup_ns: u64,
    encode_ns: u64,
    submit_wait_ns: u64,
    draw_count: u32,
    gpu_elapsed_ns: u64 = 0,
    gpu_timestamps_attempted: bool = false,
    gpu_timestamps_valid: bool = false,
};

pub fn render_draw(self: anytype, cmd: model_render_types.RenderDrawCommand, queue_sync_mode: webgpu.QueueSyncMode) !RenderMetrics {
    const fmt = cmd.target_format;
    const is_bundle = cmd.encode_mode == .render_bundle;
    const red_pl: c_int = if (cmd.pipeline_mode == .redundant) 1 else 0;
    const needs_temp_texture = cmd.uses_temporary_render_texture;

    const setup_start = common_timing.now_ns();
    try self.ensure_render_pipeline(fmt);
    try self.ensure_render_target(cmd.target_width, cmd.target_height, fmt);

    var temp_texture: ?*anyopaque = null;
    var saved_target: ?*anyopaque = null;
    if (needs_temp_texture) {
        saved_target = self.render_target;
        temp_texture = bridge.metal_bridge_device_new_render_target(
            self.device,
            cmd.target_width,
            cmd.target_height,
            fmt,
        ) orelse return error.InvalidState;
        self.render_target = temp_texture;
        if (self.streaming_render_encoder) |enc| {
            bridge.metal_bridge_render_encoder_end(enc);
            bridge.metal_bridge_release(enc);
            self.streaming_render_encoder = null;
        }
    }

    try self.ensure_streaming_render_encoder();
    const setup_ns = common_timing.ns_delta(common_timing.now_ns(), setup_start);

    const encode_start = common_timing.now_ns();
    if (is_bundle) {
        bridge.metal_bridge_render_encoder_draw(
            self.streaming_render_encoder,
            0x00000004,
            cmd.draw_count,
            cmd.vertex_count,
            cmd.instance_count,
            0,
            0,
            red_pl,
            self.render_pipeline,
        );
    } else {
        bridge.metal_bridge_render_encoder_draw(
            self.streaming_render_encoder,
            0x00000004,
            cmd.draw_count,
            cmd.vertex_count,
            cmd.instance_count,
            0,
            0,
            red_pl,
            self.render_pipeline,
        );
    }

    if (needs_temp_texture) {
        if (self.streaming_render_encoder) |enc| {
            bridge.metal_bridge_render_encoder_end(enc);
            bridge.metal_bridge_release(enc);
            self.streaming_render_encoder = null;
        }
        self.render_target = saved_target.?;
        if (self.streaming_blit_encoder == null) {
            if (self.streaming_cmd_buf == null) {
                self.streaming_cmd_buf = bridge.metal_bridge_create_command_buffer(self.queue) orelse return error.InvalidState;
            }
            self.streaming_blit_encoder = bridge.metal_bridge_cmd_buf_blit_encoder(self.streaming_cmd_buf) orelse return error.InvalidState;
        }
        bridge.metal_bridge_blit_encoder_copy_texture_to_texture(
            self.streaming_blit_encoder,
            temp_texture,
            0,
            self.render_target,
            0,
            cmd.target_width,
            cmd.target_height,
            1,
        );
        bridge.metal_bridge_release(temp_texture.?);
        self.streaming_has_copy = true;
    }

    const encode_ns = common_timing.ns_delta(common_timing.now_ns(), encode_start);

    if (queue_sync_mode == .deferred) {
        return .{ .setup_ns = setup_ns, .encode_ns = encode_ns, .submit_wait_ns = 0, .draw_count = cmd.draw_count };
    }
    const flush = try self.flush_queue_timed();
    return .{
        .setup_ns = setup_ns,
        .encode_ns = encode_ns,
        .submit_wait_ns = flush.submit_wait_ns,
        .draw_count = cmd.draw_count,
        .gpu_elapsed_ns = flush.gpu_elapsed_ns,
        .gpu_timestamps_attempted = flush.gpu_timestamps_attempted,
        .gpu_timestamps_valid = flush.gpu_timestamps_valid,
    };
}
