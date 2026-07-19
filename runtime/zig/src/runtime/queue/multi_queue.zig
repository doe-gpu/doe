// multi_queue.zig — Multi-queue management and inter-queue synchronization.
//
// Provides multiple independent command queues per device, each with its own
// MTLCommandQueue, backed by MTLSharedEvent for cross-queue ordering guarantees.
// Queue types map to Metal's queue priority API for scheduling preference.

const std = @import("std");
const process_roots = @import("../process_roots.zig");

// Metal bridge declarations — resolved at link time from metal_bridge.m.
extern fn metal_bridge_release(obj: ?*anyopaque) callconv(.c) void;
extern fn metal_bridge_device_new_command_queue(device: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn metal_bridge_device_new_shared_event(device: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn metal_bridge_command_buffer_encode_signal_event(cmd_buf: ?*anyopaque, event: ?*anyopaque, value: u64) callconv(.c) void;
extern fn metal_bridge_command_buffer_encode_wait_event(cmd_buf: ?*anyopaque, event: ?*anyopaque, value: u64) callconv(.c) void;
extern fn metal_bridge_shared_event_wait(event: ?*anyopaque, value: u64) callconv(.c) void;
extern fn metal_bridge_create_command_buffer(queue: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn metal_bridge_command_buffer_commit(cmd_buf: ?*anyopaque) callconv(.c) void;
extern fn metal_bridge_command_buffer_wait_completed(cmd_buf: ?*anyopaque) callconv(.c) void;

// Multi-queue bridge — priority-aware queue creation and cross-queue events.
extern fn metal_bridge_device_new_command_queue_with_priority(device: ?*anyopaque, priority: u32) callconv(.c) ?*anyopaque;

// ============================================================
// Constants
// ============================================================

const MAX_QUEUES_PER_DEVICE: usize = 8;

// Metal command queue priority values (MTLCommandQueuePriority).
const METAL_QUEUE_PRIORITY_LOW: u32 = 0;
const METAL_QUEUE_PRIORITY_NORMAL: u32 = 50;
const METAL_QUEUE_PRIORITY_HIGH: u32 = 100;

// Epoch wraps safely — overflow intentional.
const INITIAL_FENCE_EPOCH: u64 = 0;

// ============================================================
// Public types
// ============================================================

pub const QueueType = enum {
    graphics,
    compute,
    transfer,
};

pub const QueueRole = enum {
    graphics,
    compute,
    transfer,
    readback,
};

pub const SubmitIntent = enum {
    interactive,
    model_load,
    steady_state_inference,
};

pub const QueueDescriptor = struct {
    queue_type: QueueType,
    label: ?[]const u8,
};

pub const QueuePlan = struct {
    role: QueueRole,
    queue_type: QueueType,
    intent: SubmitIntent,
};

pub fn queue_type_for_role(role: QueueRole) QueueType {
    return switch (role) {
        .graphics => .graphics,
        .compute => .compute,
        .transfer => .transfer,
        .readback => .transfer,
    };
}

pub fn default_queue_plan(role: QueueRole, intent: SubmitIntent) QueuePlan {
    return .{
        .role = role,
        .queue_type = queue_type_for_role(role),
        .intent = intent,
    };
}

// FencePoint names a specific signal on a specific queue that another
// queue's submit can wait before executing commands.
pub const FencePoint = struct {
    queue_id: u32,
    epoch: u64,
};

pub const SubmitError = error{
    InvalidQueueId,
    QueueNotReady,
    FenceWaitFailed,
    CommandBufferFailed,
};

// ============================================================
// QueueInstance — one MTLCommandQueue with its own fence epoch.
// ============================================================

pub const QueueInstance = struct {
    mtl_queue: ?*anyopaque,
    shared_event: ?*anyopaque,
    queue_type: QueueType,
    next_epoch: u64,
    label_storage: [64]u8,
    label_len: usize,

    fn init(device: ?*anyopaque, desc: QueueDescriptor) !QueueInstance {
        // Transfer queues get low priority; compute gets normal; graphics high.
        const priority: u32 = switch (desc.queue_type) {
            .transfer => METAL_QUEUE_PRIORITY_LOW,
            .compute => METAL_QUEUE_PRIORITY_NORMAL,
            .graphics => METAL_QUEUE_PRIORITY_HIGH,
        };
        // Fall back to standard queue if priority variant unavailable.
        const mtl_queue = metal_bridge_device_new_command_queue_with_priority(device, priority) orelse metal_bridge_device_new_command_queue(device) orelse return error.QueueNotReady;
        errdefer metal_bridge_release(mtl_queue);

        const shared_event = metal_bridge_device_new_shared_event(device) orelse return error.QueueNotReady;

        var self = QueueInstance{
            .mtl_queue = mtl_queue,
            .shared_event = shared_event,
            .queue_type = desc.queue_type,
            .next_epoch = INITIAL_FENCE_EPOCH + 1,
            .label_storage = std.mem.zeroes([64]u8),
            .label_len = 0,
        };

        if (desc.label) |lbl| {
            const copy_len = @min(lbl.len, self.label_storage.len);
            std.mem.copyForwards(u8, self.label_storage[0..copy_len], lbl[0..copy_len]);
            self.label_len = copy_len;
        }

        return self;
    }

    fn deinit(self: *QueueInstance) void {
        if (self.shared_event) |ev| {
            metal_bridge_release(ev);
            self.shared_event = null;
        }
        if (self.mtl_queue) |q| {
            metal_bridge_release(q);
            self.mtl_queue = null;
        }
    }

    // Signal the queue's shared event at the current epoch, then advance.
    // Returns the epoch that was signaled so callers can construct a FencePoint.
    pub fn signal(self: *QueueInstance, cmd_buf: ?*anyopaque) u64 {
        const epoch = self.next_epoch;
        if (self.shared_event) |ev| {
            metal_bridge_command_buffer_encode_signal_event(cmd_buf, ev, epoch);
        }
        self.next_epoch +%= 1;
        // Wrap-around skips 0 — 0 is used as "no-signal" sentinel.
        if (self.next_epoch == 0) self.next_epoch = 1;
        return epoch;
    }

    // Block until this queue's event reaches the target epoch.
    pub fn wait_for_epoch(self: *const QueueInstance, epoch: u64) void {
        if (self.shared_event) |ev| {
            metal_bridge_shared_event_wait(ev, epoch);
        }
    }
};

// ============================================================
// MultiQueueDevice — owns an ordered set of QueueInstances.
// ============================================================

pub const MultiQueueDevice = struct {
    allocator: std.mem.Allocator,
    device: ?*anyopaque,
    queues: std.ArrayListUnmanaged(QueueInstance),

    pub fn init(allocator: std.mem.Allocator, device: ?*anyopaque) MultiQueueDevice {
        return .{
            .allocator = allocator,
            .device = device,
            .queues = .{},
        };
    }

    pub fn deinit(self: *MultiQueueDevice) void {
        for (self.queues.items) |*q| q.deinit();
        self.queues.deinit(self.allocator);
    }

    // Create a new queue and return its stable numeric id.
    pub fn create_queue(self: *MultiQueueDevice, desc: QueueDescriptor) !u32 {
        if (self.queues.items.len >= MAX_QUEUES_PER_DEVICE) {
            return error.QueueNotReady;
        }
        const instance = try QueueInstance.init(self.device, desc);
        const id: u32 = @intCast(self.queues.items.len);
        try self.queues.append(self.allocator, instance);
        return id;
    }

    pub fn get_queue(self: *MultiQueueDevice, id: u32) !*QueueInstance {
        if (id >= self.queues.items.len) return error.InvalidQueueId;
        return &self.queues.items[id];
    }

    // Submit a command buffer on a specific queue, waiting for any listed
    // fence points before encoding begins on the GPU timeline.
    pub fn submit_on_queue(
        self: *MultiQueueDevice,
        queue_id: u32,
        wait_fences: []const FencePoint,
    ) SubmitError!FencePoint {
        const q = self.get_queue(queue_id) catch return error.InvalidQueueId;
        const mtl_queue = q.mtl_queue orelse return error.QueueNotReady;

        const cmd_buf = metal_bridge_create_command_buffer(mtl_queue) orelse return error.CommandBufferFailed;
        defer metal_bridge_release(cmd_buf);

        // Encode waits for all upstream fence points before GPU work proceeds.
        for (wait_fences) |fence| {
            const src_q = self.get_queue(fence.queue_id) catch return error.InvalidQueueId;
            if (src_q.shared_event) |ev| {
                // Metal's encodeWait on a command buffer ensures the GPU
                // won't begin executing this buffer until the event reaches
                // the target value — zero kernel transitions required.
                metal_bridge_command_buffer_encode_wait_event(cmd_buf, ev, fence.epoch);
            }
        }

        const signaled_epoch = q.signal(cmd_buf);
        metal_bridge_command_buffer_commit(cmd_buf);
        metal_bridge_command_buffer_wait_completed(cmd_buf);

        return FencePoint{
            .queue_id = queue_id,
            .epoch = signaled_epoch,
        };
    }

    // Wait on the CPU for a fence point to be reached by the GPU.
    pub fn wait_fence(self: *MultiQueueDevice, fence: FencePoint) SubmitError!void {
        const q = self.get_queue(fence.queue_id) catch return error.InvalidQueueId;
        q.wait_for_epoch(fence.epoch);
    }
};

// ============================================================
// C ABI exports consumed by doe_napi.c and JS glue.
// ============================================================

// Opaque handle to a MultiQueueDevice — heap allocated, freed by destroy.
const MAGIC_MQD: u32 = 0xD0E1_2000;

const MQDHandle = struct {
    magic: u32 = MAGIC_MQD,
    mqd: MultiQueueDevice,
};

pub export fn doeNativeMultiQueueDeviceCreate(mtl_device: ?*anyopaque) callconv(.c) ?*anyopaque {
    const allocator = process_roots.multiQueueAllocator();
    const h = allocator.create(MQDHandle) catch return null;
    h.* = .{ .mqd = MultiQueueDevice.init(allocator, mtl_device) };
    return @ptrCast(h);
}

pub export fn doeNativeMultiQueueDeviceDestroy(raw: ?*anyopaque) callconv(.c) void {
    if (raw == null) return;
    const h: *MQDHandle = @ptrCast(@alignCast(raw));
    if (h.magic != MAGIC_MQD) return;
    h.mqd.deinit();
    process_roots.multiQueueAllocator().destroy(h);
}

pub export fn doeNativeDeviceCreateQueue(
    raw: ?*anyopaque,
    queue_type: u32,
) callconv(.c) u32 {
    if (raw == null) return std.math.maxInt(u32);
    const h: *MQDHandle = @ptrCast(@alignCast(raw));
    if (h.magic != MAGIC_MQD) return std.math.maxInt(u32);
    const qt: QueueType = switch (queue_type) {
        0 => .graphics,
        1 => .compute,
        2 => .transfer,
        else => .compute,
    };
    const id = h.mqd.create_queue(.{ .queue_type = qt, .label = null }) catch return std.math.maxInt(u32);
    return id;
}

// Submit an empty synchronization command on the given queue, waiting for
// the listed fence points. Returns encoded epoch for downstream fencing.
// Fence encoding: [queue_id_u32, epoch_u64] interleaved in fences_flat.
pub export fn doeNativeMultiQueueSubmit(
    raw: ?*anyopaque,
    queue_id: u32,
    fences_flat: ?[*]const u64,
    fence_count: u32,
) callconv(.c) u64 {
    if (raw == null) return 0;
    const h: *MQDHandle = @ptrCast(@alignCast(raw));
    if (h.magic != MAGIC_MQD) return 0;

    var fences: [MAX_QUEUES_PER_DEVICE]FencePoint = undefined;
    const n: usize = @min(@as(usize, fence_count), MAX_QUEUES_PER_DEVICE);
    if (fences_flat) |fp| {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            // Each fence is encoded as two consecutive u64 values:
            //   fp[i*2+0] = queue_id (cast from u32)
            //   fp[i*2+1] = epoch
            fences[i] = .{
                .queue_id = @intCast(fp[i * 2]),
                .epoch = fp[i * 2 + 1],
            };
        }
    }

    const point = h.mqd.submit_on_queue(queue_id, fences[0..n]) catch return 0;
    // Pack epoch as the return value; caller uses queue_id + epoch as FencePoint.
    return point.epoch;
}

pub export fn doeNativeQueueWaitFence(
    raw: ?*anyopaque,
    queue_id: u32,
    epoch: u64,
) callconv(.c) void {
    if (raw == null) return;
    const h: *MQDHandle = @ptrCast(@alignCast(raw));
    if (h.magic != MAGIC_MQD) return;
    h.mqd.wait_fence(.{ .queue_id = queue_id, .epoch = epoch }) catch |err| {
        std.debug.print("warn: multi_queue: fence wait: {s}\n", .{@errorName(err)});
    };
}
