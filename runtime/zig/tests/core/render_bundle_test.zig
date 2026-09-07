const std = @import("std");
const rb = @import("../../src/runtime/render/render_bundle.zig");
const native = @import("../../src/native/mod.zig");
const doebundle = @import("../../src/native/render/doe_bundle_native.zig");
const command_references = @import("../../src/native/command/doe_command_references.zig");

const TEST_DEVICE_MAGIC: u32 = 0xD0E1_0003;
const TEST_CMD_ENCODER_MAGIC: u32 = 0xD0E1_000B;
const TEST_RENDER_PASS_MAGIC: u32 = 0xD0E1_0012;

// Convenience aliases.
const BundleCmd = rb.BundleCmd;
const BundleCmdTag = rb.BundleCmdTag;
const DoeBundleEncoder = rb.DoeBundleEncoder;
const DoeRenderBundle = rb.DoeRenderBundle;

// ============================================================
// Helpers
// ============================================================

// Create an encoder using the testing allocator instead of the global allocator
// so each fixture owns its allocations explicitly.
fn make_test_encoder(allocator: std.mem.Allocator) DoeBundleEncoder {
    return .{
        .allocator = allocator,
        .color_format = 0x04, // BGRA8Unorm-like placeholder
        .depth_stencil_format = 0,
        .sample_count = 1,
        .depth_read_only = false,
        .stencil_read_only = false,
        .cmds = .{},
    };
}

fn destroy_heap_encoder(enc: *DoeBundleEncoder) void {
    const allocator = enc.allocator;
    enc.cmds.deinit(allocator);
    allocator.destroy(enc);
}

fn push_draw(enc: *DoeBundleEncoder, vertex_count: u32, instance_count: u32) !void {
    try rb.bundle_encoder_push(enc, BundleCmd{ .draw = .{
        .vertex_count = vertex_count,
        .instance_count = instance_count,
        .first_vertex = 0,
        .first_instance = 0,
    } });
}

fn finish_to_bundle(enc: *DoeBundleEncoder) DoeRenderBundle {
    // Manual finish that does not destroy the encoder (tests manage their own memory).
    const cmds_slice = enc.cmds.toOwnedSlice(enc.allocator) catch unreachable;
    return .{
        .allocator = enc.allocator,
        .color_format = enc.color_format,
        .depth_stencil_format = enc.depth_stencil_format,
        .sample_count = enc.sample_count,
        .cmds = cmds_slice,
    };
}

fn make_native_device() native.DoeDevice {
    return .{ .magic = TEST_DEVICE_MAGIC };
}

fn make_native_command_encoder(dev: *native.DoeDevice) native.DoeCommandEncoder {
    return .{
        .magic = TEST_CMD_ENCODER_MAGIC,
        .dev = dev,
    };
}

fn make_native_render_pass(enc: *native.DoeCommandEncoder) native.DoeRenderPass {
    return .{
        .magic = TEST_RENDER_PASS_MAGIC,
        .enc = enc,
        .target_format = 0x04,
    };
}

// ============================================================
// Command recording tests
// ============================================================

test "push single draw command increments count" {
    var enc = make_test_encoder(std.testing.allocator);
    defer enc.cmds.deinit(enc.allocator);

    try push_draw(&enc, 3, 1);

    try std.testing.expectEqual(@as(usize, 1), enc.cmds.items.len);
    try std.testing.expectEqual(BundleCmdTag.draw, std.meta.activeTag(enc.cmds.items[0]));
}

test "push multiple commands preserves order" {
    var enc = make_test_encoder(std.testing.allocator);
    defer enc.cmds.deinit(enc.allocator);

    try rb.bundle_encoder_push(&enc, BundleCmd{ .set_pipeline = .{ .pipeline_handle = null } });
    try push_draw(&enc, 6, 1);
    try rb.bundle_encoder_push(&enc, BundleCmd{ .set_vertex_buffer = .{
        .slot = 0,
        .buffer_handle = null,
        .offset = 0,
        .size = 0,
    } });
    try push_draw(&enc, 12, 2);

    try std.testing.expectEqual(@as(usize, 4), enc.cmds.items.len);
    try std.testing.expectEqual(BundleCmdTag.set_pipeline, std.meta.activeTag(enc.cmds.items[0]));
    try std.testing.expectEqual(BundleCmdTag.draw, std.meta.activeTag(enc.cmds.items[1]));
    try std.testing.expectEqual(BundleCmdTag.set_vertex_buffer, std.meta.activeTag(enc.cmds.items[2]));
    try std.testing.expectEqual(BundleCmdTag.draw, std.meta.activeTag(enc.cmds.items[3]));
}

test "draw command records vertex and instance counts" {
    var enc = make_test_encoder(std.testing.allocator);
    defer enc.cmds.deinit(enc.allocator);

    try push_draw(&enc, 36, 4);

    const d = enc.cmds.items[0].draw;
    try std.testing.expectEqual(@as(u32, 36), d.vertex_count);
    try std.testing.expectEqual(@as(u32, 4), d.instance_count);
    try std.testing.expectEqual(@as(u32, 0), d.first_vertex);
    try std.testing.expectEqual(@as(u32, 0), d.first_instance);
}

test "draw_indexed command records all parameters" {
    var enc = make_test_encoder(std.testing.allocator);
    defer enc.cmds.deinit(enc.allocator);

    try rb.bundle_encoder_push(&enc, BundleCmd{ .draw_indexed = .{
        .index_count = 100,
        .instance_count = 3,
        .first_index = 10,
        .base_vertex = -5,
        .first_instance = 2,
    } });

    const d = enc.cmds.items[0].draw_indexed;
    try std.testing.expectEqual(@as(u32, 100), d.index_count);
    try std.testing.expectEqual(@as(u32, 3), d.instance_count);
    try std.testing.expectEqual(@as(u32, 10), d.first_index);
    try std.testing.expectEqual(@as(i32, -5), d.base_vertex);
    try std.testing.expectEqual(@as(u32, 2), d.first_instance);
}

test "set_bind_group records group index and entry count" {
    var enc = make_test_encoder(std.testing.allocator);
    defer enc.cmds.deinit(enc.allocator);

    var bg = rb.BundleBindGroup{
        .entries = undefined,
        .count = 2,
    };
    bg.entries[0] = .{ .handle = null, .offset = 0 };
    bg.entries[1] = .{ .handle = null, .offset = 64 };

    try rb.bundle_encoder_push(&enc, BundleCmd{ .set_bind_group = .{
        .group = 1,
        .bg = bg,
    } });

    try std.testing.expectEqual(@as(usize, 1), enc.cmds.items.len);
    const sbg = enc.cmds.items[0].set_bind_group;
    try std.testing.expectEqual(@as(u32, 1), sbg.group);
    try std.testing.expectEqual(@as(u32, 2), sbg.bg.count);
    try std.testing.expectEqual(@as(u64, 64), sbg.bg.entries[1].offset);
}

test "set_index_buffer records format and offset" {
    var enc = make_test_encoder(std.testing.allocator);
    defer enc.cmds.deinit(enc.allocator);

    try rb.bundle_encoder_push(&enc, BundleCmd{
        .set_index_buffer = .{
            .buffer_handle = null,
            .format = 0x1, // uint16
            .offset = 128,
            .size = 2048,
        },
    });

    const ib = enc.cmds.items[0].set_index_buffer;
    try std.testing.expectEqual(@as(u32, 0x1), ib.format);
    try std.testing.expectEqual(@as(u64, 128), ib.offset);
    try std.testing.expectEqual(@as(u64, 2048), ib.size);
}

// ============================================================
// Bundle state transition (recording -> finished) tests
// ============================================================

test "finish produces bundle with correct command count and format" {
    var enc = make_test_encoder(std.testing.allocator);

    try push_draw(&enc, 3, 1);
    try push_draw(&enc, 6, 1);
    try push_draw(&enc, 9, 1);

    const bundle = finish_to_bundle(&enc);
    defer std.testing.allocator.free(bundle.cmds);

    try std.testing.expectEqual(@as(usize, 3), bundle.cmds.len);
    try std.testing.expectEqual(@as(u32, 0x04), bundle.color_format);
    try std.testing.expectEqual(@as(u32, 1), bundle.sample_count);
}

test "finish transfers ownership of commands to bundle" {
    var enc = make_test_encoder(std.testing.allocator);

    try push_draw(&enc, 10, 1);
    try push_draw(&enc, 20, 1);

    const bundle = finish_to_bundle(&enc);
    defer std.testing.allocator.free(bundle.cmds);

    // Encoder's command list should be empty after toOwnedSlice.
    try std.testing.expectEqual(@as(usize, 0), enc.cmds.items.len);

    // Bundle holds all commands.
    try std.testing.expectEqual(@as(u32, 10), bundle.cmds[0].draw.vertex_count);
    try std.testing.expectEqual(@as(u32, 20), bundle.cmds[1].draw.vertex_count);
}

test "bundle magic values are correct" {
    try std.testing.expectEqual(@as(u32, 0xD0E1_0020), DoeBundleEncoder.TYPE_MAGIC);
    try std.testing.expectEqual(@as(u32, 0xD0E1_0021), DoeRenderBundle.TYPE_MAGIC);
}

test "encoder default magic is set on construction" {
    var enc = make_test_encoder(std.testing.allocator);
    defer enc.cmds.deinit(enc.allocator);

    try std.testing.expectEqual(DoeBundleEncoder.TYPE_MAGIC, enc.magic);
}

// ============================================================
// Empty bundle tests
// ============================================================

test "empty encoder finishes to bundle with zero commands" {
    var enc = make_test_encoder(std.testing.allocator);

    const bundle = finish_to_bundle(&enc);
    defer std.testing.allocator.free(bundle.cmds);

    try std.testing.expectEqual(@as(usize, 0), bundle.cmds.len);
}

test "empty bundle passes compatibility check" {
    var enc = make_test_encoder(std.testing.allocator);
    const bundle = finish_to_bundle(&enc);
    defer std.testing.allocator.free(bundle.cmds);

    // Same format as encoder: should pass.
    try rb.check_compatibility(&bundle, 0x04, 1);
}

// ============================================================
// Replay command sequence tests (pure logic, no Metal calls)
// ============================================================

test "replay produces correct command sequence for mixed commands" {
    var enc = make_test_encoder(std.testing.allocator);

    // Record: pipeline -> vertex buffer -> draw -> draw_indexed
    try rb.bundle_encoder_push(&enc, BundleCmd{ .set_pipeline = .{ .pipeline_handle = null } });
    try rb.bundle_encoder_push(&enc, BundleCmd{ .set_vertex_buffer = .{
        .slot = 0,
        .buffer_handle = null,
        .offset = 0,
        .size = 0,
    } });
    try push_draw(&enc, 6, 1);
    try rb.bundle_encoder_push(&enc, BundleCmd{ .set_index_buffer = .{
        .buffer_handle = null,
        .format = 0x2,
        .offset = 0,
        .size = 1024,
    } });
    try rb.bundle_encoder_push(&enc, BundleCmd{ .draw_indexed = .{
        .index_count = 12,
        .instance_count = 1,
        .first_index = 0,
        .base_vertex = 0,
        .first_instance = 0,
    } });

    const bundle = finish_to_bundle(&enc);
    defer std.testing.allocator.free(bundle.cmds);

    // Verify command sequence matches recording order.
    try std.testing.expectEqual(@as(usize, 5), bundle.cmds.len);
    try std.testing.expectEqual(BundleCmdTag.set_pipeline, std.meta.activeTag(bundle.cmds[0]));
    try std.testing.expectEqual(BundleCmdTag.set_vertex_buffer, std.meta.activeTag(bundle.cmds[1]));
    try std.testing.expectEqual(BundleCmdTag.draw, std.meta.activeTag(bundle.cmds[2]));
    try std.testing.expectEqual(BundleCmdTag.set_index_buffer, std.meta.activeTag(bundle.cmds[3]));
    try std.testing.expectEqual(BundleCmdTag.draw_indexed, std.meta.activeTag(bundle.cmds[4]));

    // Verify data integrity of the draw_indexed command.
    try std.testing.expectEqual(@as(u32, 12), bundle.cmds[4].draw_indexed.index_count);
}

// ============================================================
// Native executeBundles replay tests
// ============================================================

test "executeBundles replays indexed indirect bundles with fresh replay state" {
    var dev = make_native_device();
    var cmd_enc = make_native_command_encoder(&dev);
    defer cmd_enc.cmds.deinit(native.alloc);
    defer command_references.releaseAll(&cmd_enc.references);

    var render_pass = make_native_render_pass(&cmd_enc);
    render_pass.enc.state = .{ .pass = @intFromPtr(&render_pass) };

    var pipeline_token_a: u8 = 0;
    var vertex_token_a: u8 = 0;
    var index_token_a: u8 = 0;
    var indirect_token_a: u8 = 0;

    var bundle_a_enc = make_test_encoder(std.testing.allocator);
    defer bundle_a_enc.cmds.deinit(bundle_a_enc.allocator);
    try rb.bundle_encoder_push(&bundle_a_enc, BundleCmd{ .set_pipeline = .{ .pipeline_handle = @ptrCast(&pipeline_token_a) } });
    try rb.bundle_encoder_push(&bundle_a_enc, BundleCmd{ .set_vertex_buffer = .{
        .slot = 0,
        .buffer_handle = @ptrCast(&vertex_token_a),
        .offset = 16,
        .size = 0,
    } });
    try rb.bundle_encoder_push(&bundle_a_enc, BundleCmd{ .set_index_buffer = .{
        .buffer_handle = @ptrCast(&index_token_a),
        .format = 0x1,
        .offset = 24,
        .size = 128,
    } });
    try rb.bundle_encoder_push(&bundle_a_enc, BundleCmd{ .draw_indexed_indirect = .{
        .indirect_buffer = @ptrCast(&indirect_token_a),
        .indirect_offset = 64,
    } });
    const bundle_a = finish_to_bundle(&bundle_a_enc);
    defer std.testing.allocator.free(bundle_a.cmds);

    var pipeline_token_b: u8 = 0;
    var index_token_b: u8 = 0;
    var indirect_token_b: u8 = 0;

    var bundle_b_enc = make_test_encoder(std.testing.allocator);
    defer bundle_b_enc.cmds.deinit(bundle_b_enc.allocator);
    try rb.bundle_encoder_push(&bundle_b_enc, BundleCmd{ .set_index_buffer = .{
        .buffer_handle = @ptrCast(&index_token_b),
        .format = 0x2,
        .offset = 8,
        .size = 256,
    } });
    try rb.bundle_encoder_push(&bundle_b_enc, BundleCmd{ .set_pipeline = .{ .pipeline_handle = @ptrCast(&pipeline_token_b) } });
    try rb.bundle_encoder_push(&bundle_b_enc, BundleCmd{ .draw_indexed_indirect = .{
        .indirect_buffer = @ptrCast(&indirect_token_b),
        .indirect_offset = 32,
    } });
    const bundle_b = finish_to_bundle(&bundle_b_enc);
    defer std.testing.allocator.free(bundle_b.cmds);

    const bundles = [_]?*anyopaque{
        @ptrCast(@constCast(&bundle_a)),
        @ptrCast(@constCast(&bundle_b)),
    };
    doebundle.doeNativeRenderPassExecuteBundles(@ptrCast(&render_pass), bundles.len, &bundles);

    try std.testing.expectEqual(@as(usize, 2), cmd_enc.cmds.items.len);

    const first = cmd_enc.cmds.items[0].render_pass;
    try std.testing.expect(first.indexed);
    try std.testing.expect(first.indirect);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&index_token_a)), first.index_buffer);
    try std.testing.expectEqual(@as(u64, 24), first.index_offset);
    try std.testing.expectEqual(@as(u32, 0x1), first.index_format);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&indirect_token_a)), first.indirect_buffer);
    try std.testing.expectEqual(@as(u64, 64), first.indirect_offset);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&pipeline_token_a)), first.pso);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&vertex_token_a)), first.vertex_buffers[0]);
    try std.testing.expectEqual(@as(u64, 16), first.vertex_buffer_offsets[0]);

    const second = cmd_enc.cmds.items[1].render_pass;
    try std.testing.expect(second.indexed);
    try std.testing.expect(second.indirect);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&index_token_b)), second.index_buffer);
    try std.testing.expectEqual(@as(u64, 8), second.index_offset);
    try std.testing.expectEqual(@as(u32, 0x2), second.index_format);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&indirect_token_b)), second.indirect_buffer);
    try std.testing.expectEqual(@as(u64, 32), second.indirect_offset);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&pipeline_token_b)), second.pso);
    try std.testing.expect(second.vertex_buffers[0] == null);
    try std.testing.expectEqual(@as(u64, 0), second.vertex_buffer_offsets[0]);
}

test "executeBundles skips indexed indirect draws without an index buffer" {
    var dev = make_native_device();
    var cmd_enc = make_native_command_encoder(&dev);
    defer cmd_enc.cmds.deinit(native.alloc);
    defer command_references.releaseAll(&cmd_enc.references);

    var render_pass = make_native_render_pass(&cmd_enc);
    render_pass.enc.state = .{ .pass = @intFromPtr(&render_pass) };

    var indirect_token: u8 = 0;

    var bundle_enc = make_test_encoder(std.testing.allocator);
    defer bundle_enc.cmds.deinit(bundle_enc.allocator);
    try rb.bundle_encoder_push(&bundle_enc, BundleCmd{ .draw_indexed_indirect = .{
        .indirect_buffer = @ptrCast(&indirect_token),
        .indirect_offset = 48,
    } });
    const bundle = finish_to_bundle(&bundle_enc);
    defer std.testing.allocator.free(bundle.cmds);

    const bundles = [_]?*anyopaque{@ptrCast(@constCast(&bundle))};
    doebundle.doeNativeRenderPassExecuteBundles(@ptrCast(&render_pass), bundles.len, &bundles);

    try std.testing.expectEqual(@as(usize, 0), cmd_enc.cmds.items.len);
}

test "executeBundles preserves render pass ops and bundle pipeline metadata" {
    var dev = make_native_device();
    var cmd_enc = make_native_command_encoder(&dev);
    defer cmd_enc.cmds.deinit(native.alloc);
    defer command_references.releaseAll(&cmd_enc.references);

    var render_pass = make_native_render_pass(&cmd_enc);
    render_pass.enc.state = .{ .pass = @intFromPtr(&render_pass) };
    render_pass.color_load_op = 0x00000002;
    render_pass.color_store_op = 0x00000001;
    render_pass.clear_a = 1;
    render_pass.viewport_width = 64;
    render_pass.viewport_height = 64;
    render_pass.scissor_width = 64;
    render_pass.scissor_height = 64;

    var pso_token: u8 = 0;
    var pipeline: native.DoeRenderPipeline = .{
        .mtl_pso = @ptrCast(&pso_token),
        .topology = 0x00000004,
        .front_face = 0x00000002,
        .cull_mode = 0x00000003,
        .depth_compare = 0x00000004,
        .depth_write_enabled = true,
    };

    var bundle_enc = make_test_encoder(std.testing.allocator);
    defer bundle_enc.cmds.deinit(bundle_enc.allocator);
    try rb.bundle_encoder_push(&bundle_enc, BundleCmd{ .set_pipeline = .{
        .pipeline_handle = pipeline.mtl_pso,
        .pipeline_object_handle = @ptrCast(&pipeline),
    } });
    try push_draw(&bundle_enc, 3, 1);
    const bundle = finish_to_bundle(&bundle_enc);
    defer std.testing.allocator.free(bundle.cmds);

    const bundles = [_]?*anyopaque{@ptrCast(@constCast(&bundle))};
    doebundle.doeNativeRenderPassExecuteBundles(@ptrCast(&render_pass), bundles.len, &bundles);

    try std.testing.expectEqual(@as(usize, 1), cmd_enc.cmds.items.len);
    const recorded = cmd_enc.cmds.items[0].render_pass;
    try std.testing.expect(recorded.pass_start);
    try std.testing.expectEqual(@as(u32, 0x00000002), recorded.color_load_op);
    try std.testing.expectEqual(@as(u32, 0x00000001), recorded.color_store_op);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&pso_token)), recorded.pso);
    try std.testing.expectEqual(@as(u32, 0x00000004), recorded.topology);
    try std.testing.expectEqual(@as(u32, 0x00000002), recorded.front_face);
    try std.testing.expectEqual(@as(u32, 0x00000003), recorded.cull_mode);
    try std.testing.expectEqual(@as(u32, 0x00000004), recorded.depth_compare);
    try std.testing.expect(recorded.depth_write_enabled);
    try std.testing.expectEqual(@as(?f32, 64), recorded.viewport_width);
    try std.testing.expectEqual(@as(?u32, 64), recorded.scissor_width);
}

// ============================================================
// Compatibility check tests
// ============================================================

test "check_compatibility succeeds when formats match" {
    var bundle = DoeRenderBundle{
        .allocator = std.testing.allocator,
        .color_format = 0x04,
        .depth_stencil_format = 0,
        .sample_count = 4,
        .cmds = &.{},
    };

    try rb.check_compatibility(&bundle, 0x04, 4);
}

test "check_compatibility fails on color format mismatch" {
    var bundle = DoeRenderBundle{
        .allocator = std.testing.allocator,
        .color_format = 0x04,
        .depth_stencil_format = 0,
        .sample_count = 1,
        .cmds = &.{},
    };

    try std.testing.expectError(
        rb.ReplayError.FormatMismatch,
        rb.check_compatibility(&bundle, 0x08, 1),
    );
}

test "check_compatibility fails on sample count mismatch" {
    var bundle = DoeRenderBundle{
        .allocator = std.testing.allocator,
        .color_format = 0x04,
        .depth_stencil_format = 0,
        .sample_count = 4,
        .cmds = &.{},
    };

    try std.testing.expectError(
        rb.ReplayError.SampleCountMismatch,
        rb.check_compatibility(&bundle, 0x04, 1),
    );
}

test "check_compatibility skips format check when bundle color_format is 0" {
    // color_format=0 means the bundle is format-agnostic (unset).
    var bundle = DoeRenderBundle{
        .allocator = std.testing.allocator,
        .color_format = 0,
        .depth_stencil_format = 0,
        .sample_count = 1,
        .cmds = &.{},
    };

    // Any pass format should be accepted.
    try rb.check_compatibility(&bundle, 0xFF, 1);
}

test "check_compatibility skips sample count check when bundle sample_count is 0" {
    var bundle = DoeRenderBundle{
        .allocator = std.testing.allocator,
        .color_format = 0x04,
        .depth_stencil_format = 0,
        .sample_count = 0,
        .cmds = &.{},
    };

    try rb.check_compatibility(&bundle, 0x04, 8);
}

// ============================================================
// make_bundle_encoder with an explicit allocator
// ============================================================

test "make_bundle_encoder produces valid encoder with correct fields" {
    const enc = rb.make_bundle_encoder(std.testing.allocator, 0x04, 0x20, 4, true, false) orelse
        return error.AllocationFailed;

    try std.testing.expectEqual(DoeBundleEncoder.TYPE_MAGIC, enc.magic);
    try std.testing.expectEqual(@as(u32, 0x04), enc.color_format);
    try std.testing.expectEqual(@as(u32, 0x20), enc.depth_stencil_format);
    try std.testing.expectEqual(@as(u32, 4), enc.sample_count);
    try std.testing.expect(enc.depth_read_only);
    try std.testing.expect(!enc.stencil_read_only);
    try std.testing.expectEqual(@as(usize, 0), enc.cmds.items.len);

    // Clean up via the public destroy path.
    destroy_heap_encoder(enc);
}

test "make_bundle_encoder normalizes zero sample_count to 1" {
    const enc = rb.make_bundle_encoder(std.testing.allocator, 0x04, 0, 0, false, false) orelse
        return error.AllocationFailed;
    defer destroy_heap_encoder(enc);

    try std.testing.expectEqual(@as(u32, 1), enc.sample_count);
}

// ============================================================
// Full lifecycle: make -> push -> finish -> destroy
// ============================================================

test "full lifecycle: create encoder, record, finish, destroy" {
    const enc = rb.make_bundle_encoder(std.testing.allocator, 0x04, 0, 1, false, false) orelse
        return error.AllocationFailed;
    defer destroy_heap_encoder(enc);

    try rb.bundle_encoder_push(enc, BundleCmd{ .set_pipeline = .{ .pipeline_handle = null } });
    try rb.bundle_encoder_push(enc, BundleCmd{ .draw = .{
        .vertex_count = 3,
        .instance_count = 1,
        .first_vertex = 0,
        .first_instance = 0,
    } });

    // finish consumes the encoder.
    const bundle = rb.bundle_encoder_finish(enc) orelse
        return error.FinishFailed;

    try std.testing.expectEqual(DoeRenderBundle.TYPE_MAGIC, bundle.magic);
    try std.testing.expectEqual(@as(usize, 2), bundle.cmds.len);
    try std.testing.expectEqual(@as(u32, 3), bundle.cmds[1].draw.vertex_count);

    // Destroy frees bundle + its command slice.
    rb.bundle_destroy(bundle);
}

// ============================================================
// Cast helpers
// ============================================================

test "cast_bundle_encoder returns null for null input" {
    try std.testing.expect(rb.cast_bundle_encoder(null) == null);
}

test "cast_bundle returns null for null input" {
    try std.testing.expect(rb.cast_bundle(null) == null);
}

test "cast_bundle_encoder validates magic" {
    const enc = rb.make_bundle_encoder(std.testing.allocator, 0x04, 0, 1, false, false) orelse
        return error.AllocationFailed;
    defer destroy_heap_encoder(enc);

    // Valid cast.
    const opaque_ptr: *anyopaque = @ptrCast(enc);
    const recovered = rb.cast_bundle_encoder(opaque_ptr);
    try std.testing.expect(recovered != null);
    try std.testing.expectEqual(enc, recovered.?);
}

test "cast_bundle validates magic" {
    const enc = rb.make_bundle_encoder(std.testing.allocator, 0x04, 0, 1, false, false) orelse
        return error.AllocationFailed;
    defer destroy_heap_encoder(enc);

    const bundle = rb.bundle_encoder_finish(enc) orelse
        return error.FinishFailed;
    defer rb.bundle_destroy(bundle);

    const opaque_ptr: *anyopaque = @ptrCast(bundle);
    const recovered = rb.cast_bundle(opaque_ptr);
    try std.testing.expect(recovered != null);
    try std.testing.expectEqual(bundle, recovered.?);
}

// ============================================================
// All command tag variants are representable
// ============================================================

test "all BundleCmdTag variants can be pushed and recovered" {
    var enc = make_test_encoder(std.testing.allocator);
    defer enc.cmds.deinit(enc.allocator);

    try rb.bundle_encoder_push(&enc, BundleCmd{ .set_pipeline = .{ .pipeline_handle = null } });
    try rb.bundle_encoder_push(&enc, BundleCmd{ .set_bind_group = .{
        .group = 0,
        .bg = .{ .entries = undefined, .count = 0 },
    } });
    try rb.bundle_encoder_push(&enc, BundleCmd{ .set_vertex_buffer = .{
        .slot = 0,
        .buffer_handle = null,
        .offset = 0,
        .size = 0,
    } });
    try rb.bundle_encoder_push(&enc, BundleCmd{ .set_index_buffer = .{
        .buffer_handle = null,
        .format = 0x2,
        .offset = 0,
        .size = 0,
    } });
    try rb.bundle_encoder_push(&enc, BundleCmd{ .draw = .{
        .vertex_count = 1,
        .instance_count = 1,
        .first_vertex = 0,
        .first_instance = 0,
    } });
    try rb.bundle_encoder_push(&enc, BundleCmd{ .draw_indexed = .{
        .index_count = 1,
        .instance_count = 1,
        .first_index = 0,
        .base_vertex = 0,
        .first_instance = 0,
    } });
    try rb.bundle_encoder_push(&enc, BundleCmd{ .draw_indirect = .{
        .indirect_buffer = null,
        .indirect_offset = 0,
    } });
    try rb.bundle_encoder_push(&enc, BundleCmd{ .draw_indexed_indirect = .{
        .indirect_buffer = null,
        .indirect_offset = 0,
    } });

    try std.testing.expectEqual(@as(usize, 8), enc.cmds.items.len);

    const expected_tags = [_]BundleCmdTag{
        .set_pipeline,
        .set_bind_group,
        .set_vertex_buffer,
        .set_index_buffer,
        .draw,
        .draw_indexed,
        .draw_indirect,
        .draw_indexed_indirect,
    };

    for (expected_tags, 0..) |tag, i| {
        try std.testing.expectEqual(tag, std.meta.activeTag(enc.cmds.items[i]));
    }
}

// ============================================================
// Constants
// ============================================================

test "MAX_BUNDLE_CMDS is 4096" {
    try std.testing.expectEqual(@as(usize, 4096), rb.MAX_BUNDLE_CMDS);
}

test "MAX_VTX_BUFS is 8" {
    try std.testing.expectEqual(@as(usize, 8), rb.MAX_VTX_BUFS);
}

test "MAX_BIND_GROUPS is 4" {
    try std.testing.expectEqual(@as(usize, 4), rb.MAX_BIND_GROUPS);
}

test "MAX_BINDINGS_PER_GROUP is 16" {
    try std.testing.expectEqual(@as(usize, 16), rb.MAX_BINDINGS_PER_GROUP);
}

// ============================================================
// Full replay command sequence: record all command types, finish,
// verify data integrity for replay iteration
// ============================================================

test "replay sequence: all command types recorded and data preserved" {
    const enc = rb.make_bundle_encoder(std.testing.allocator, 0x04, 0x20, 4, false, false) orelse
        return error.AllocationFailed;
    defer destroy_heap_encoder(enc);

    // 1. set_pipeline
    try rb.bundle_encoder_push(enc, BundleCmd{ .set_pipeline = .{ .pipeline_handle = null } });

    // 2. set_bind_group (group 0, 2 entries)
    var bg0 = rb.BundleBindGroup{ .entries = undefined, .count = 2 };
    bg0.entries[0] = .{ .handle = null, .offset = 0 };
    bg0.entries[1] = .{ .handle = null, .offset = 256 };
    try rb.bundle_encoder_push(enc, BundleCmd{ .set_bind_group = .{ .group = 0, .bg = bg0 } });

    // 3. set_vertex_buffer (slot 0)
    try rb.bundle_encoder_push(enc, BundleCmd{ .set_vertex_buffer = .{
        .slot = 0,
        .buffer_handle = null,
        .offset = 0,
        .size = 0,
    } });

    // 4. draw
    try rb.bundle_encoder_push(enc, BundleCmd{ .draw = .{
        .vertex_count = 36,
        .instance_count = 1,
        .first_vertex = 0,
        .first_instance = 0,
    } });

    // 5. set_index_buffer
    try rb.bundle_encoder_push(enc, BundleCmd{ .set_index_buffer = .{
        .buffer_handle = null,
        .format = 0x2,
        .offset = 0,
        .size = 4096,
    } });

    // 6. draw_indexed
    try rb.bundle_encoder_push(enc, BundleCmd{ .draw_indexed = .{
        .index_count = 24,
        .instance_count = 2,
        .first_index = 0,
        .base_vertex = 10,
        .first_instance = 0,
    } });

    // 7. draw_indirect
    try rb.bundle_encoder_push(enc, BundleCmd{ .draw_indirect = .{
        .indirect_buffer = null,
        .indirect_offset = 64,
    } });

    // 8. draw_indexed_indirect
    try rb.bundle_encoder_push(enc, BundleCmd{ .draw_indexed_indirect = .{
        .indirect_buffer = null,
        .indirect_offset = 128,
    } });

    // Finish to bundle.
    const bundle = rb.bundle_encoder_finish(enc) orelse
        return error.FinishFailed;
    defer rb.bundle_destroy(bundle);

    // Verify command count.
    try std.testing.expectEqual(@as(usize, 8), bundle.cmds.len);

    // Verify compatibility metadata transferred.
    try std.testing.expectEqual(@as(u32, 0x04), bundle.color_format);
    try std.testing.expectEqual(@as(u32, 0x20), bundle.depth_stencil_format);
    try std.testing.expectEqual(@as(u32, 4), bundle.sample_count);

    // Verify command tags in replay order.
    const expected_tags = [_]BundleCmdTag{
        .set_pipeline,
        .set_bind_group,
        .set_vertex_buffer,
        .draw,
        .set_index_buffer,
        .draw_indexed,
        .draw_indirect,
        .draw_indexed_indirect,
    };
    for (expected_tags, 0..) |tag, i| {
        try std.testing.expectEqual(tag, std.meta.activeTag(bundle.cmds[i]));
    }

    // Verify set_bind_group data integrity.
    const sbg = bundle.cmds[1].set_bind_group;
    try std.testing.expectEqual(@as(u32, 0), sbg.group);
    try std.testing.expectEqual(@as(u32, 2), sbg.bg.count);
    try std.testing.expectEqual(@as(u64, 256), sbg.bg.entries[1].offset);

    // Verify set_vertex_buffer data.
    const vb = bundle.cmds[2].set_vertex_buffer;
    try std.testing.expectEqual(@as(u32, 0), vb.slot);

    // Verify draw data.
    const draw = bundle.cmds[3].draw;
    try std.testing.expectEqual(@as(u32, 36), draw.vertex_count);
    try std.testing.expectEqual(@as(u32, 1), draw.instance_count);

    // Verify set_index_buffer data.
    const ib = bundle.cmds[4].set_index_buffer;
    try std.testing.expectEqual(@as(u32, 0x2), ib.format);
    try std.testing.expectEqual(@as(u64, 4096), ib.size);

    // Verify draw_indexed data.
    const di = bundle.cmds[5].draw_indexed;
    try std.testing.expectEqual(@as(u32, 24), di.index_count);
    try std.testing.expectEqual(@as(u32, 2), di.instance_count);
    try std.testing.expectEqual(@as(i32, 10), di.base_vertex);

    // Verify draw_indirect data.
    const dind = bundle.cmds[6].draw_indirect;
    try std.testing.expectEqual(@as(u64, 64), dind.indirect_offset);

    // Verify draw_indexed_indirect data.
    const diind = bundle.cmds[7].draw_indexed_indirect;
    try std.testing.expectEqual(@as(u64, 128), diind.indirect_offset);

    // Verify compatibility check passes for matching format.
    try rb.check_compatibility(bundle, 0x04, 4);

    // Verify compatibility check fails for mismatched format.
    try std.testing.expectError(
        rb.ReplayError.FormatMismatch,
        rb.check_compatibility(bundle, 0x08, 4),
    );

    // Verify compatibility check fails for mismatched sample count.
    try std.testing.expectError(
        rb.ReplayError.SampleCountMismatch,
        rb.check_compatibility(bundle, 0x04, 1),
    );
}

test "replay sequence: multiple bind groups in replay order" {
    const enc = rb.make_bundle_encoder(std.testing.allocator, 0x04, 0, 1, false, false) orelse
        return error.AllocationFailed;
    defer destroy_heap_encoder(enc);

    // Record bind groups 0, 1, 2, 3 with different entry counts.
    var i: u32 = 0;
    while (i < rb.MAX_BIND_GROUPS) : (i += 1) {
        var bg = rb.BundleBindGroup{ .entries = undefined, .count = i + 1 };
        var j: u32 = 0;
        while (j < bg.count) : (j += 1) {
            bg.entries[j] = .{ .handle = null, .offset = @as(u64, i) * 1000 + @as(u64, j) * 64 };
        }
        try rb.bundle_encoder_push(enc, BundleCmd{ .set_bind_group = .{ .group = i, .bg = bg } });
    }

    try rb.bundle_encoder_push(enc, BundleCmd{ .draw = .{
        .vertex_count = 3,
        .instance_count = 1,
        .first_vertex = 0,
        .first_instance = 0,
    } });

    const bundle = rb.bundle_encoder_finish(enc) orelse
        return error.FinishFailed;
    defer rb.bundle_destroy(bundle);

    // 4 bind groups + 1 draw = 5 commands.
    try std.testing.expectEqual(@as(usize, 5), bundle.cmds.len);

    // Verify each bind group's data.
    var k: u32 = 0;
    while (k < rb.MAX_BIND_GROUPS) : (k += 1) {
        const cmd = bundle.cmds[k].set_bind_group;
        try std.testing.expectEqual(k, cmd.group);
        try std.testing.expectEqual(k + 1, cmd.bg.count);
        try std.testing.expectEqual(@as(u64, k) * 1000, cmd.bg.entries[0].offset);
    }
}

test "replay sequence: multiple vertex buffer slots" {
    const enc = rb.make_bundle_encoder(std.testing.allocator, 0x04, 0, 1, false, false) orelse
        return error.AllocationFailed;
    defer destroy_heap_encoder(enc);

    try rb.bundle_encoder_push(enc, BundleCmd{ .set_pipeline = .{ .pipeline_handle = null } });

    // Record vertex buffers on slots 0..MAX_VTX_BUFS-1.
    var slot: u32 = 0;
    while (slot < rb.MAX_VTX_BUFS) : (slot += 1) {
        try rb.bundle_encoder_push(enc, BundleCmd{ .set_vertex_buffer = .{
            .slot = slot,
            .buffer_handle = null,
            .offset = @as(u64, slot) * 128,
            .size = 0,
        } });
    }

    try rb.bundle_encoder_push(enc, BundleCmd{ .draw = .{
        .vertex_count = 100,
        .instance_count = 1,
        .first_vertex = 0,
        .first_instance = 0,
    } });

    const bundle = rb.bundle_encoder_finish(enc) orelse
        return error.FinishFailed;
    defer rb.bundle_destroy(bundle);

    // 1 pipeline + MAX_VTX_BUFS vertex buffers + 1 draw.
    try std.testing.expectEqual(@as(usize, 1 + rb.MAX_VTX_BUFS + 1), bundle.cmds.len);

    // Verify each vertex buffer slot and offset.
    var s: u32 = 0;
    while (s < rb.MAX_VTX_BUFS) : (s += 1) {
        const vb = bundle.cmds[1 + s].set_vertex_buffer;
        try std.testing.expectEqual(s, vb.slot);
        try std.testing.expectEqual(@as(u64, s) * 128, vb.offset);
    }
}
