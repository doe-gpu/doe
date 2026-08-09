// Fence pool, deferred-submission tracking, and timeline semaphore support
// for the Vulkan backend.
//
// Replaces single-fence + vkQueueWaitIdle with per-submission fence tracking:
//   - FencePool manages a fixed-size ring of VkFence handles
//   - Deferred submissions signal a pool fence instead of VK_NULL_HANDLE
//   - drain waits on all in-flight fences (no vkQueueWaitIdle)
//   - Timeline semaphore detection exposes VK_KHR_timeline_semaphore when available

const std = @import("std");
const c = @import("vk_constants.zig");
const common_errors = @import("../../contracts/execution.zig");

const VK_NULL_U64 = c.VK_NULL_U64;

/// Maximum fences managed by the pool. Sized for typical pipelined depth
/// (upload batch + dispatch + render) without over-allocating driver objects.
pub const FENCE_POOL_CAPACITY: usize = 128;

/// Timeout for per-fence waits (nanoseconds). Matches vk_upload.WAIT_TIMEOUT_NS.
pub const FENCE_WAIT_TIMEOUT_NS: u64 = std.math.maxInt(u64);
pub const IMMEDIATE_FENCE_POLL_SPINS: usize = 2048;

pub fn wait_for_fence_fast(device: c.VkDevice, fence: c.VkFence) common_errors.BackendNativeError!void {
    var spin: usize = 0;
    while (spin < IMMEDIATE_FENCE_POLL_SPINS) : (spin += 1) {
        const status = c.vkGetFenceStatus(device, fence);
        if (status == c.VK_SUCCESS) return;
        if (status != c.VK_NOT_READY) return c.check_vk(status);
        std.atomic.spinLoopHint();
    }
    try c.check_vk(c.vkWaitForFences(device, 1, @ptrCast(&fence), c.VK_TRUE, FENCE_WAIT_TIMEOUT_NS));
}

pub const FencePool = struct {
    fences: [FENCE_POOL_CAPACITY]c.VkFence = [_]c.VkFence{VK_NULL_U64} ** FENCE_POOL_CAPACITY,
    in_flight: [FENCE_POOL_CAPACITY]bool = [_]bool{false} ** FENCE_POOL_CAPACITY,
    count: u32 = 0,
    next_index: u32 = 0,
    in_flight_count: u32 = 0,
    last_in_flight_index: u32 = 0,

    /// Initialize the ring. Individual VkFence handles are created on first use.
    pub fn init(device: c.VkDevice) common_errors.BackendNativeError!FencePool {
        _ = device;
        var pool = FencePool{};
        pool.count = FENCE_POOL_CAPACITY;
        return pool;
    }

    /// Acquire the next available fence for a queue submission. If the fence
    /// at the current ring position is still in-flight, wait for it first
    /// so it can be reused. Returns the fence handle to pass to vkQueueSubmit.
    pub fn acquire(self: *FencePool, device: c.VkDevice) common_errors.BackendNativeError!c.VkFence {
        const idx = self.next_index;
        if (self.fences[idx] == VK_NULL_U64) {
            var fence_info = c.VkFenceCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
            };
            try c.check_vk(c.vkCreateFence(device, &fence_info, null, &self.fences[idx]));
        }
        const fence = self.fences[idx];

        // If this slot was in-flight from a previous submission, wait + reset
        if (self.in_flight[idx]) {
            try wait_for_fence_fast(device, fence);
            self.in_flight[idx] = false;
            self.in_flight_count -|= 1;
        }

        try c.check_vk(c.vkResetFences(device, 1, @ptrCast(&fence)));
        self.in_flight[idx] = true;
        self.in_flight_count +|= 1;
        self.last_in_flight_index = idx;
        self.next_index = (idx + 1) % self.count;
        return fence;
    }

    /// Wait for all in-flight fences and mark them reusable. Used to drain all
    /// deferred/pipelined submissions without vkQueueWaitIdle.
    pub fn drain(self: *FencePool, device: c.VkDevice) common_errors.BackendNativeError!void {
        if (self.in_flight_count == 0) return;
        if (self.in_flight_count == 1) {
            var idx = self.last_in_flight_index;
            if (idx >= self.count or !self.in_flight[idx]) {
                idx = 0;
                while (idx < self.count and !self.in_flight[idx]) : (idx += 1) {}
                if (idx >= self.count) {
                    self.in_flight_count = 0;
                    return;
                }
            }
            if (self.fences[idx] == VK_NULL_U64) return error.InvalidState;
            try wait_for_fence_fast(device, self.fences[idx]);
            self.in_flight[idx] = false;
            self.in_flight_count = 0;
            return;
        }

        var handles: [FENCE_POOL_CAPACITY]c.VkFence = undefined;
        var handle_count: u32 = 0;

        var i: u32 = 0;
        while (i < self.count) : (i += 1) {
            if (!self.in_flight[i]) continue;
            if (self.fences[i] == VK_NULL_U64) return error.InvalidState;
            handles[handle_count] = self.fences[i];
            handle_count += 1;
        }

        if (handle_count == 0) return;
        try c.check_vk(c.vkWaitForFences(
            device,
            handle_count,
            @ptrCast(&handles),
            c.VK_TRUE,
            FENCE_WAIT_TIMEOUT_NS,
        ));

        i = 0;
        while (i < self.count) : (i += 1) {
            if (self.in_flight[i]) self.in_flight[i] = false;
        }
        self.in_flight_count = 0;
    }

    /// True when at least one fence is in-flight (deferred work outstanding).
    pub fn has_in_flight(self: *const FencePool) bool {
        return self.in_flight_count != 0;
    }

    /// Destroy all pool fences. Call before device destruction.
    pub fn deinit(self: *FencePool, device: c.VkDevice) void {
        var i: u32 = 0;
        while (i < self.count) : (i += 1) {
            if (self.fences[i] != VK_NULL_U64) {
                // Best-effort wait before destroy to avoid validation errors
                if (self.in_flight[i]) {
                    wait_for_fence_fast(device, self.fences[i]) catch {};
                    self.in_flight[i] = false;
                }
                c.vkDestroyFence(device, self.fences[i], null);
                self.fences[i] = VK_NULL_U64;
            }
        }
        self.count = 0;
        self.next_index = 0;
        self.in_flight_count = 0;
        self.last_in_flight_index = 0;
    }
};

// --- Timeline semaphore support (VK_KHR_timeline_semaphore / Vulkan 1.2) ---

/// VK_STRUCTURE_TYPE values for timeline semaphore structs
const VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_FEATURES: i32 = 1000207000;
const VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO: i32 = 1000207002;
const VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO: i32 = 1000207004;
const VK_STRUCTURE_TYPE_SEMAPHORE_SIGNAL_INFO: i32 = 1000207005;
pub const VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO: i32 = 1000207003;

/// VK_SEMAPHORE_TYPE_TIMELINE = 1
pub const VK_SEMAPHORE_TYPE_TIMELINE: u32 = 1;

/// VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2
const VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2: i32 = 1000059000;

/// VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
const VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO: i32 = 9;

/// Feature struct chained via pNext during device creation to detect support.
pub const VkPhysicalDeviceTimelineSemaphoreFeatures = extern struct {
    sType: c.VkStructureType = VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_FEATURES,
    pNext: ?*anyopaque = null,
    timelineSemaphore: c.VkBool32 = c.VK_FALSE,
};

/// Chained into VkSemaphoreCreateInfo to create a timeline semaphore.
pub const VkSemaphoreTypeCreateInfo = extern struct {
    sType: c.VkStructureType = VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    semaphoreType: u32 = VK_SEMAPHORE_TYPE_TIMELINE,
    initialValue: u64 = 0,
};

/// Submit info extension for timeline semaphore wait/signal values.
pub const VkTimelineSemaphoreSubmitInfo = extern struct {
    sType: c.VkStructureType = VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO,
    pNext: ?*const anyopaque = null,
    waitSemaphoreValueCount: u32 = 0,
    pWaitSemaphoreValues: ?[*]const u64 = null,
    signalSemaphoreValueCount: u32 = 0,
    pSignalSemaphoreValues: ?[*]const u64 = null,
};

/// Wait info for vkWaitSemaphores.
pub const VkSemaphoreWaitInfo = extern struct {
    sType: c.VkStructureType = VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    semaphoreCount: u32 = 0,
    pSemaphores: ?[*]const c.VkSemaphore = null,
    pValues: ?[*]const u64 = null,
};

/// VkSemaphoreCreateInfo (sType=9). Declared locally; used only for timeline
/// semaphore creation with a pNext chain to VkSemaphoreTypeCreateInfo.
const VkSemaphoreCreateInfo = extern struct {
    sType: c.VkStructureType,
    pNext: ?*const anyopaque,
    flags: u32,
};

// Vulkan entry points for semaphore and timeline operations.
// These link against the Vulkan loader; timeline functions require
// Vulkan 1.2+ or VK_KHR_timeline_semaphore.
extern fn vkCreateSemaphore(device: c.VkDevice, pCreateInfo: *const VkSemaphoreCreateInfo, pAllocator: ?*const c.VkAllocationCallbacks, pSemaphore: *c.VkSemaphore) callconv(.c) c.VkResult;
extern fn vkDestroySemaphore(device: c.VkDevice, semaphore: c.VkSemaphore, pAllocator: ?*const c.VkAllocationCallbacks) callconv(.c) void;
extern fn vkWaitSemaphores(device: c.VkDevice, pWaitInfo: *const VkSemaphoreWaitInfo, timeout: u64) callconv(.c) c.VkResult;
extern fn vkGetSemaphoreCounterValue(device: c.VkDevice, semaphore: c.VkSemaphore, pValue: *u64) callconv(.c) c.VkResult;
extern fn vkGetPhysicalDeviceFeatures2(physicalDevice: c.VkPhysicalDevice, pFeatures: *anyopaque) callconv(.c) void;

/// Manages a single timeline semaphore for monotonic GPU->CPU signaling.
/// Each queue submission increments the timeline value; the CPU can wait
/// on any past value without needing per-submission fence objects.
pub const TimelineSemaphore = struct {
    semaphore: c.VkSemaphore = VK_NULL_U64,
    current_value: u64 = 0,
    available: bool = false,

    /// Attempt to create a timeline semaphore. Returns a struct with
    /// available=false if the device does not support the extension
    /// (caller should fall back to fence pool).
    pub fn init(device: c.VkDevice, timeline_supported: bool) TimelineSemaphore {
        if (!timeline_supported) return .{};

        var type_info = VkSemaphoreTypeCreateInfo{};
        var sem_info = VkSemaphoreCreateInfo{
            .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
            .pNext = @ptrCast(&type_info),
            .flags = 0,
        };

        var sem: c.VkSemaphore = VK_NULL_U64;
        const result = vkCreateSemaphore(device, &sem_info, null, &sem);
        if (result != c.VK_SUCCESS) return .{};

        return .{
            .semaphore = sem,
            .current_value = 0,
            .available = true,
        };
    }

    /// Return the next signal value for a queue submission.
    pub fn next_signal_value(self: *TimelineSemaphore) u64 {
        self.current_value += 1;
        return self.current_value;
    }

    /// Wait on the CPU until the timeline reaches `value`.
    pub fn wait(self: *const TimelineSemaphore, device: c.VkDevice, value: u64) common_errors.BackendNativeError!void {
        if (!self.available) return error.UnsupportedFeature;
        var wait_info = VkSemaphoreWaitInfo{
            .semaphoreCount = 1,
            .pSemaphores = @ptrCast(&self.semaphore),
            .pValues = @ptrCast(&value),
        };
        try c.check_vk(vkWaitSemaphores(device, &wait_info, FENCE_WAIT_TIMEOUT_NS));
    }

    /// Wait for all submissions up to the current value.
    pub fn drain(self: *const TimelineSemaphore, device: c.VkDevice) common_errors.BackendNativeError!void {
        if (!self.available or self.current_value == 0) return;
        try self.wait(device, self.current_value);
    }

    /// Query the current GPU-side counter value (non-blocking).
    pub fn query(self: *const TimelineSemaphore, device: c.VkDevice) common_errors.BackendNativeError!u64 {
        if (!self.available) return error.UnsupportedFeature;
        var value: u64 = 0;
        try c.check_vk(vkGetSemaphoreCounterValue(device, self.semaphore, &value));
        return value;
    }

    pub fn deinit(self: *TimelineSemaphore, device: c.VkDevice) void {
        if (self.semaphore != VK_NULL_U64) {
            if (self.available and self.current_value > 0) {
                self.drain(device) catch {};
            }
            vkDestroySemaphore(device, self.semaphore, null);
            self.semaphore = VK_NULL_U64;
        }
        self.available = false;
        self.current_value = 0;
    }
};

/// Pre-built chain of VkTimelineSemaphoreSubmitInfo + semaphore/value arrays
/// ready to attach to a VkSubmitInfo. Callers set `submit.pNext`,
/// `submit.signalSemaphoreCount`, and `submit.pSignalSemaphores` from the
/// returned fields before calling vkQueueSubmit.
///
/// Usage:
///   var tsi = TimelineSubmitHelper.prepare(&timeline_sem);
///   if (tsi.ready) {
///       submit.pNext = @ptrCast(&tsi.timeline_info);
///       submit.signalSemaphoreCount = 1;
///       submit.pSignalSemaphores = @ptrCast(&tsi.semaphore);
///   }
pub const TimelineSubmitHelper = struct {
    timeline_info: VkTimelineSemaphoreSubmitInfo = .{},
    semaphore: c.VkSemaphore = VK_NULL_U64,
    signal_value: u64 = 0,
    ready: bool = false,

    /// Prepare a timeline signal for the next queue submission.
    /// Increments the timeline value and populates the helper fields.
    /// Returns a helper with ready=false if the timeline is unavailable.
    pub fn prepare(ts: *TimelineSemaphore) TimelineSubmitHelper {
        if (!ts.available) return .{};
        const value = ts.next_signal_value();
        return .{
            .timeline_info = .{
                .waitSemaphoreValueCount = 0,
                .pWaitSemaphoreValues = null,
                .signalSemaphoreValueCount = 1,
                .pSignalSemaphoreValues = null, // patched below
            },
            .semaphore = ts.semaphore,
            .signal_value = value,
            .ready = true,
        };
    }

    /// Patch the signal value pointer to point at our own signal_value field.
    /// Must be called after prepare() and before passing to vkQueueSubmit,
    /// since the struct address is stable only after the caller has placed it.
    pub fn patch(self: *TimelineSubmitHelper) void {
        if (!self.ready) return;
        self.timeline_info.pSignalSemaphoreValues = @ptrCast(&self.signal_value);
    }
};

/// Detect timeline semaphore support by querying
/// VkPhysicalDeviceTimelineSemaphoreFeatures via the Vulkan 1.1+
/// vkGetPhysicalDeviceFeatures2 entry point.
pub fn detect_timeline_semaphore_support(physical_device: c.VkPhysicalDevice) bool {
    var timeline_features = VkPhysicalDeviceTimelineSemaphoreFeatures{};
    // VkPhysicalDeviceFeatures2 with pNext chain to timeline features
    const Features2 = extern struct {
        sType: c.VkStructureType,
        pNext: ?*anyopaque,
        // VkPhysicalDeviceFeatures is a large struct (56 bools).
        // We only care about the pNext chain; zero-init the features.
        features: [224]u8,
    };
    var features2 = Features2{
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
        .pNext = @ptrCast(&timeline_features),
        .features = std.mem.zeroes([224]u8),
    };
    vkGetPhysicalDeviceFeatures2(physical_device, @ptrCast(&features2));
    return timeline_features.timelineSemaphore == c.VK_TRUE;
}
