const std = @import("std");
const multi_queue = @import("../../src/runtime/queue/multi_queue.zig");
const QueueType = multi_queue.QueueType;
const QueueDescriptor = multi_queue.QueueDescriptor;
const FencePoint = multi_queue.FencePoint;
const MultiQueueDevice = multi_queue.MultiQueueDevice;
const SubmitError = multi_queue.SubmitError;
const QueueInstance = multi_queue.QueueInstance;

// ============================================================
// QueueType enum
// ============================================================

test "QueueType has graphics, compute, and transfer variants" {
    const g = QueueType.graphics;
    const c = QueueType.compute;
    const t = QueueType.transfer;
    try std.testing.expect(g != c);
    try std.testing.expect(c != t);
    try std.testing.expect(g != t);
}

test "QueueType exhaustive switch covers all variants" {
    const variants = [_]QueueType{ .graphics, .compute, .transfer };
    for (variants) |v| {
        const name: []const u8 = switch (v) {
            .graphics => "graphics",
            .compute => "compute",
            .transfer => "transfer",
        };
        try std.testing.expect(name.len > 0);
    }
}

test "QueueType enum has exactly 3 variants" {
    const fields = std.meta.fields(QueueType);
    try std.testing.expectEqual(@as(usize, 3), fields.len);
    try std.testing.expectEqualStrings("graphics", fields[0].name);
    try std.testing.expectEqualStrings("compute", fields[1].name);
    try std.testing.expectEqualStrings("transfer", fields[2].name);
}

// ============================================================
// QueueDescriptor construction
// ============================================================

test "QueueDescriptor with label" {
    const desc = QueueDescriptor{
        .queue_type = .compute,
        .label = "my-queue",
    };
    try std.testing.expectEqual(QueueType.compute, desc.queue_type);
    try std.testing.expectEqualStrings("my-queue", desc.label.?);
}

test "QueueDescriptor with null label" {
    const desc = QueueDescriptor{
        .queue_type = .transfer,
        .label = null,
    };
    try std.testing.expectEqual(QueueType.transfer, desc.queue_type);
    try std.testing.expectEqual(@as(?[]const u8, null), desc.label);
}

test "QueueDescriptor all queue types" {
    const queue_types = [_]QueueType{ .graphics, .compute, .transfer };
    for (queue_types) |qt| {
        const desc = QueueDescriptor{
            .queue_type = qt,
            .label = null,
        };
        try std.testing.expectEqual(qt, desc.queue_type);
    }
}

test "QueueDescriptor with long label" {
    const long_label = "this-is-a-very-long-queue-label-that-exceeds-storage";
    const desc = QueueDescriptor{
        .queue_type = .graphics,
        .label = long_label,
    };
    try std.testing.expectEqualStrings(long_label, desc.label.?);
}

// ============================================================
// FencePoint
// ============================================================

test "FencePoint struct stores queue_id and epoch" {
    const fp = FencePoint{
        .queue_id = 3,
        .epoch = 42,
    };
    try std.testing.expectEqual(@as(u32, 3), fp.queue_id);
    try std.testing.expectEqual(@as(u64, 42), fp.epoch);
}

test "FencePoint with zero epoch" {
    const fp = FencePoint{
        .queue_id = 0,
        .epoch = 0,
    };
    try std.testing.expectEqual(@as(u32, 0), fp.queue_id);
    try std.testing.expectEqual(@as(u64, 0), fp.epoch);
}

test "FencePoint with max values" {
    const fp = FencePoint{
        .queue_id = std.math.maxInt(u32),
        .epoch = std.math.maxInt(u64),
    };
    try std.testing.expectEqual(std.math.maxInt(u32), fp.queue_id);
    try std.testing.expectEqual(std.math.maxInt(u64), fp.epoch);
}

test "FencePoint equality by value" {
    const a = FencePoint{ .queue_id = 1, .epoch = 10 };
    const b = FencePoint{ .queue_id = 1, .epoch = 10 };
    const c = FencePoint{ .queue_id = 1, .epoch = 11 };
    try std.testing.expectEqual(a.queue_id, b.queue_id);
    try std.testing.expectEqual(a.epoch, b.epoch);
    try std.testing.expect(a.epoch != c.epoch);
}

// ============================================================
// QueueInstance struct layout
// ============================================================

test "QueueInstance has expected fields" {
    try std.testing.expect(@hasField(QueueInstance, "mtl_queue"));
    try std.testing.expect(@hasField(QueueInstance, "shared_event"));
    try std.testing.expect(@hasField(QueueInstance, "queue_type"));
    try std.testing.expect(@hasField(QueueInstance, "next_epoch"));
    try std.testing.expect(@hasField(QueueInstance, "label_storage"));
    try std.testing.expect(@hasField(QueueInstance, "label_len"));
}

test "QueueInstance label_storage is 64 bytes" {
    // The label_storage field is [64]u8.
    const field_info = std.meta.fieldInfo(QueueInstance, .label_storage);
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(field_info.type));
}

test "QueueInstance struct is not zero-size" {
    try std.testing.expect(@sizeOf(QueueInstance) > 0);
}

// ============================================================
// MultiQueueDevice init/deinit lifecycle (null device)
// ============================================================

test "MultiQueueDevice init with null device" {
    var mqd = MultiQueueDevice.init(std.testing.allocator, null);
    defer mqd.deinit();
    try std.testing.expectEqual(@as(?*anyopaque, null), mqd.device);
    try std.testing.expectEqual(@as(usize, 0), mqd.queues.items.len);
}

test "MultiQueueDevice deinit on empty is safe" {
    var mqd = MultiQueueDevice.init(std.testing.allocator, null);
    mqd.deinit();
}

test "MultiQueueDevice get_queue on empty returns InvalidQueueId" {
    var mqd = MultiQueueDevice.init(std.testing.allocator, null);
    defer mqd.deinit();
    try std.testing.expectError(error.InvalidQueueId, mqd.get_queue(0));
    try std.testing.expectError(error.InvalidQueueId, mqd.get_queue(1));
    try std.testing.expectError(error.InvalidQueueId, mqd.get_queue(std.math.maxInt(u32)));
}

test "MultiQueueDevice wait_fence on empty returns InvalidQueueId" {
    var mqd = MultiQueueDevice.init(std.testing.allocator, null);
    defer mqd.deinit();
    const result = mqd.wait_fence(FencePoint{ .queue_id = 0, .epoch = 1 });
    try std.testing.expectError(error.InvalidQueueId, result);
}

test "MultiQueueDevice init has empty queue list" {
    var mqd = MultiQueueDevice.init(std.testing.allocator, null);
    defer mqd.deinit();
    try std.testing.expectEqual(@as(usize, 0), mqd.queues.items.len);
    try std.testing.expectEqual(@as(usize, 0), mqd.queues.capacity);
}

// ============================================================
// SubmitError variants
// ============================================================

test "SubmitError has expected variants" {
    const e1: SubmitError = error.InvalidQueueId;
    const e2: SubmitError = error.QueueNotReady;
    const e3: SubmitError = error.FenceWaitFailed;
    const e4: SubmitError = error.CommandBufferFailed;
    try std.testing.expect(e1 != e2);
    try std.testing.expect(e2 != e3);
    try std.testing.expect(e3 != e4);
}

// ============================================================
// C ABI export symbol existence
// ============================================================

test "C ABI exports are declared as public symbols" {
    // Verify that the exported C ABI symbols exist as public declarations in the module.
    try std.testing.expect(@hasDecl(multi_queue, "doeNativeMultiQueueDeviceCreate"));
    try std.testing.expect(@hasDecl(multi_queue, "doeNativeMultiQueueDeviceDestroy"));
    try std.testing.expect(@hasDecl(multi_queue, "doeNativeDeviceCreateQueue"));
    try std.testing.expect(@hasDecl(multi_queue, "doeNativeMultiQueueSubmit"));
    try std.testing.expect(@hasDecl(multi_queue, "doeNativeQueueWaitFence"));
}

test "doeNativeMultiQueueDeviceDestroy handles null safely" {
    multi_queue.doeNativeMultiQueueDeviceDestroy(null);
}

test "doeNativeDeviceCreateQueue returns maxInt for null handle" {
    const result = multi_queue.doeNativeDeviceCreateQueue(null, 0);
    try std.testing.expectEqual(std.math.maxInt(u32), result);
}

test "doeNativeMultiQueueSubmit returns 0 for null handle" {
    const result = multi_queue.doeNativeMultiQueueSubmit(null, 0, null, 0);
    try std.testing.expectEqual(@as(u64, 0), result);
}

test "doeNativeQueueWaitFence handles null safely" {
    multi_queue.doeNativeQueueWaitFence(null, 0, 0);
}

// ============================================================
// MQDHandle magic number validation (null and wrong-magic paths)
// ============================================================

test "doeNativeDeviceCreateQueue rejects wrong magic number" {
    // Allocate a buffer large enough to hold MQDHandle so the cast is valid,
    // but fill with a wrong magic value.
    // MQDHandle contains { magic: u32, mqd: MultiQueueDevice }.
    // We need at least @sizeOf(u32) + @sizeOf(MultiQueueDevice) bytes.
    var buf: [512]u8 align(@alignOf(usize)) = undefined;
    @memset(&buf, 0);
    // Write wrong magic at offset 0.
    const magic_ptr: *u32 = @ptrCast(@alignCast(&buf));
    magic_ptr.* = 0xDEAD_BEEF;
    const result = multi_queue.doeNativeDeviceCreateQueue(@ptrCast(&buf), 1);
    try std.testing.expectEqual(std.math.maxInt(u32), result);
}

test "doeNativeMultiQueueSubmit rejects wrong magic number" {
    var buf: [512]u8 align(@alignOf(usize)) = undefined;
    @memset(&buf, 0);
    const magic_ptr: *u32 = @ptrCast(@alignCast(&buf));
    magic_ptr.* = 0x1234_5678;
    const result = multi_queue.doeNativeMultiQueueSubmit(@ptrCast(&buf), 0, null, 0);
    try std.testing.expectEqual(@as(u64, 0), result);
}

test "doeNativeQueueWaitFence rejects wrong magic number" {
    var buf: [512]u8 align(@alignOf(usize)) = undefined;
    @memset(&buf, 0);
    const magic_ptr: *u32 = @ptrCast(@alignCast(&buf));
    magic_ptr.* = 0x0000_0001;
    multi_queue.doeNativeQueueWaitFence(@ptrCast(&buf), 0, 1);
}

// ============================================================
// MultiQueueDevice error paths
// ============================================================

test "MultiQueueDevice submit_on_queue with no queues returns InvalidQueueId" {
    var mqd = MultiQueueDevice.init(std.testing.allocator, null);
    defer mqd.deinit();
    const result = mqd.submit_on_queue(0, &.{});
    try std.testing.expectError(error.InvalidQueueId, result);
}

test "MultiQueueDevice submit_on_queue with high queue_id returns InvalidQueueId" {
    var mqd = MultiQueueDevice.init(std.testing.allocator, null);
    defer mqd.deinit();
    const result = mqd.submit_on_queue(255, &.{});
    try std.testing.expectError(error.InvalidQueueId, result);
}

test "MultiQueueDevice wait_fence with various invalid ids" {
    var mqd = MultiQueueDevice.init(std.testing.allocator, null);
    defer mqd.deinit();
    // All queue IDs should fail on an empty device.
    for ([_]u32{ 0, 1, 7, 100, std.math.maxInt(u32) }) |id| {
        const result = mqd.wait_fence(FencePoint{ .queue_id = id, .epoch = 42 });
        try std.testing.expectError(error.InvalidQueueId, result);
    }
}

// ============================================================
// FencePoint array construction (simulate fence_flat decoding)
// ============================================================

test "FencePoint array from flat u64 pairs" {
    const flat = [_]u64{ 0, 10, 1, 20, 2, 30 };
    const n: usize = 3;

    var fences: [8]FencePoint = undefined;
    for (0..n) |i| {
        fences[i] = .{
            .queue_id = @intCast(flat[i * 2]),
            .epoch = flat[i * 2 + 1],
        };
    }

    try std.testing.expectEqual(@as(u32, 0), fences[0].queue_id);
    try std.testing.expectEqual(@as(u64, 10), fences[0].epoch);
    try std.testing.expectEqual(@as(u32, 1), fences[1].queue_id);
    try std.testing.expectEqual(@as(u64, 20), fences[1].epoch);
    try std.testing.expectEqual(@as(u32, 2), fences[2].queue_id);
    try std.testing.expectEqual(@as(u64, 30), fences[2].epoch);
}

test "FencePoint slice with zero count is valid empty slice" {
    var fences: [8]FencePoint = undefined;
    const slice = fences[0..0];
    try std.testing.expectEqual(@as(usize, 0), slice.len);
}

test "FencePoint single entry decode from flat array" {
    const flat = [_]u64{ 7, 999 };
    const fp = FencePoint{
        .queue_id = @intCast(flat[0]),
        .epoch = flat[1],
    };
    try std.testing.expectEqual(@as(u32, 7), fp.queue_id);
    try std.testing.expectEqual(@as(u64, 999), fp.epoch);
}
