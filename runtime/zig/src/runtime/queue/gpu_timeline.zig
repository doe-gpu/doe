// gpu_timeline.zig — Per-queue GPU timeline tracking with MTLSharedEvent fences.
//
// Replaces the ad-hoc event_counter field on DoeQueue with a well-typed timeline
// abstraction. Each submit increments a monotonic sequence number; completion
// callbacks are registered against that sequence number and fired when the GPU
// signals the shared event past the registered value.
//
// For buffer.mapAsync, the map callback must not fire until the GPU has finished
// writing to the buffer. We record the timeline value at submit time and, when
// mapAsync is called, wait for that value before marking the buffer mapped.
//
// Async delivery is dispatched onto Doe worker threads so the caller path does
// not invoke all callbacks inline once the timeline advances.
//
// queue.onSubmittedWorkDone: records the current timeline value and polls in a
// background fashion. Because Doe is synchronous at the JS layer (all submits
// complete before returning to JS), the future is always already done when polled.
// The callback fires inline for correctness; the Future.id is stable for waitAny.

const std = @import("std");
const abi_base = @import("../../core/abi/wgpu_handle_types.zig");
const abi_callback = @import("../../core/abi/wgpu_callback_descriptor_types.zig");
const callback_dispatch = @import("../callback_dispatch.zig");

// ============================================================
// Constants
// ============================================================

const MAX_PENDING_MAP: usize = 64;
const MAX_PENDING_WORK_DONE: usize = 64;

// ============================================================
// Metal bridge externs
// ============================================================

extern fn metal_bridge_shared_event_wait(event: ?*anyopaque, value: u64) callconv(.c) void;

// Read the current signaled value without blocking.
extern fn metal_bridge_shared_event_signaled_value(event: ?*anyopaque) callconv(.c) u64;

// ============================================================
// Pending map operation
// ============================================================

const PendingMap = struct {
    // Timeline value the GPU must have reached before mapping is valid.
    required_value: u64,
    // Buffer handle that will be mapped.
    mtl_buffer: ?*anyopaque,
    // Callback info (copied from the caller to avoid lifetime issues).
    status: u32, // WGPUMapAsyncStatus_Success=1 or error code
    mode: u64,
    offset: usize,
    size: usize,
    cb: ?*const fn (u32, abi_base.WGPUStringView, ?*anyopaque, ?*anyopaque) callconv(.c) void,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
    // Pointer to the DoeBuffer.mapped field — set to true once GPU work is done.
    mapped_flag: *bool,
};

// ============================================================
// Pending work-done notification
// ============================================================

const PendingWorkDone = struct {
    required_value: u64,
    cb: ?*const fn (abi_callback.WGPUQueueWorkDoneStatus, abi_base.WGPUStringView, ?*anyopaque, ?*anyopaque) callconv(.c) void,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
};

// ============================================================
// GpuTimeline — one per DoeQueue
// ============================================================

pub const GpuTimeline = struct {
    // Monotonic counter incremented on each submit.
    submit_counter: u64,
    // Shared Metal event used to track GPU progress.
    // Owned by this timeline; caller must call deinit.
    shared_event: ?*anyopaque,

    pending_maps: [MAX_PENDING_MAP]PendingMap,
    pending_map_count: usize,

    pending_work_done: [MAX_PENDING_WORK_DONE]PendingWorkDone,
    pending_work_done_count: usize,

    pub fn init(shared_event: ?*anyopaque) GpuTimeline {
        return .{
            .submit_counter = 0,
            .shared_event = shared_event,
            .pending_maps = undefined,
            .pending_map_count = 0,
            .pending_work_done = undefined,
            .pending_work_done_count = 0,
        };
    }

    // Advance the timeline counter and return the new value.
    // Call this before committing a command buffer; encode a signal for this value
    // into the command buffer.
    pub fn advance(self: *GpuTimeline) u64 {
        self.submit_counter +%= 1;
        return self.submit_counter;
    }

    // Block until the GPU signals a value >= `required`.
    pub fn wait_for(self: *GpuTimeline, required: u64) void {
        if (self.shared_event == null) return;
        if (metal_bridge_shared_event_signaled_value(self.shared_event) >= required) return;
        metal_bridge_shared_event_wait(self.shared_event, required);
    }

    // Register a mapAsync operation to be completed when the GPU reaches `required_value`.
    // If the GPU has already reached that value, the callback fires immediately.
    pub fn register_map(
        self: *GpuTimeline,
        required_value: u64,
        mtl_buffer: ?*anyopaque,
        mode: u64,
        offset: usize,
        size: usize,
        cb: ?*const fn (u32, abi_base.WGPUStringView, ?*anyopaque, ?*anyopaque) callconv(.c) void,
        userdata1: ?*anyopaque,
        userdata2: ?*anyopaque,
        mapped_flag: *bool,
    ) void {
        const already_done = self.shared_event == null or
            metal_bridge_shared_event_signaled_value(self.shared_event) >= required_value;

        if (already_done) {
            // GPU already past this point; map immediately and call back inline.
            mapped_flag.* = true;
            callback_dispatch.fire_map_callback_inline(WGPU_MAP_ASYNC_STATUS_SUCCESS, cb, userdata1, userdata2);
            return;
        }

        if (self.pending_map_count >= MAX_PENDING_MAP) {
            // Overflow: block synchronously and fire callback.
            self.wait_for(required_value);
            mapped_flag.* = true;
            callback_dispatch.fire_map_callback_inline(WGPU_MAP_ASYNC_STATUS_SUCCESS, cb, userdata1, userdata2);
            return;
        }

        self.pending_maps[self.pending_map_count] = .{
            .required_value = required_value,
            .mtl_buffer = mtl_buffer,
            .status = WGPU_MAP_ASYNC_STATUS_SUCCESS,
            .mode = mode,
            .offset = offset,
            .size = size,
            .cb = cb,
            .userdata1 = userdata1,
            .userdata2 = userdata2,
            .mapped_flag = mapped_flag,
        };
        self.pending_map_count += 1;
    }

    // Register an onSubmittedWorkDone callback for the current timeline value.
    pub fn register_work_done(
        self: *GpuTimeline,
        cb: ?*const fn (abi_callback.WGPUQueueWorkDoneStatus, abi_base.WGPUStringView, ?*anyopaque, ?*anyopaque) callconv(.c) void,
        userdata1: ?*anyopaque,
        userdata2: ?*anyopaque,
    ) void {
        const required = self.submit_counter; // snapshot — no new submit expected before poll
        const already_done = required == 0 or self.shared_event == null or
            metal_bridge_shared_event_signaled_value(self.shared_event) >= required;

        if (already_done) {
            callback_dispatch.fire_work_done_callback_inline(cb, userdata1, userdata2);
            return;
        }

        if (self.pending_work_done_count >= MAX_PENDING_WORK_DONE) {
            // Overflow: block and fire.
            self.wait_for(required);
            callback_dispatch.fire_work_done_callback_inline(cb, userdata1, userdata2);
            return;
        }

        self.pending_work_done[self.pending_work_done_count] = .{
            .required_value = required,
            .cb = cb,
            .userdata1 = userdata1,
            .userdata2 = userdata2,
        };
        self.pending_work_done_count += 1;
    }

    // Drain all pending callbacks whose required_value has been reached.
    // Call this at processEvents time or before mapAsync reads.
    pub fn drain_ready(self: *GpuTimeline) void {
        if (self.shared_event == null) return;
        const current = metal_bridge_shared_event_signaled_value(self.shared_event);

        // Drain pending maps.
        var i: usize = 0;
        while (i < self.pending_map_count) {
            const pm = &self.pending_maps[i];
            if (pm.required_value <= current) {
                pm.mapped_flag.* = true;
                callback_dispatch.dispatch_map_callback(pm.status, pm.cb, pm.userdata1, pm.userdata2);
                // Remove by swap with last.
                self.pending_map_count -= 1;
                if (i < self.pending_map_count) {
                    self.pending_maps[i] = self.pending_maps[self.pending_map_count];
                }
                // Do not advance i — re-check the swapped entry.
            } else {
                i += 1;
            }
        }

        // Drain pending work-done.
        var j: usize = 0;
        while (j < self.pending_work_done_count) {
            const pw = &self.pending_work_done[j];
            if (pw.required_value <= current) {
                callback_dispatch.dispatch_work_done_callback(pw.cb, pw.userdata1, pw.userdata2);
                self.pending_work_done_count -= 1;
                if (j < self.pending_work_done_count) {
                    self.pending_work_done[j] = self.pending_work_done[self.pending_work_done_count];
                }
            } else {
                j += 1;
            }
        }
    }

    // Wait for all outstanding GPU work then drain all callbacks.
    // Called at queue flush / deinit time.
    pub fn flush_all(self: *GpuTimeline) void {
        if (self.submit_counter == 0) return;
        self.wait_for(self.submit_counter);
        self.drain_ready();
        // Any remaining pending entries timed out — fire them with success
        // since we just waited for the full timeline.
        self.fire_all_remaining();
    }

    fn fire_all_remaining(self: *GpuTimeline) void {
        for (self.pending_maps[0..self.pending_map_count]) |pm| {
            pm.mapped_flag.* = true;
            callback_dispatch.dispatch_map_callback(pm.status, pm.cb, pm.userdata1, pm.userdata2);
        }
        self.pending_map_count = 0;

        for (self.pending_work_done[0..self.pending_work_done_count]) |pw| {
            callback_dispatch.dispatch_work_done_callback(pw.cb, pw.userdata1, pw.userdata2);
        }
        self.pending_work_done_count = 0;
    }
};

// ============================================================
// WGPUQueueWorkDoneStatus — matches Dawn C ABI
// ============================================================

const WGPU_MAP_ASYNC_STATUS_SUCCESS: u32 = 1;
