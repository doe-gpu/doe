const std = @import("std");
const c = @import("vk_constants.zig");
const identity = @import("vk_descriptor_identity.zig");
const compute = @import("../../contracts/model/model_compute_types.zig");
const shared = @import("vk_shared_pipeline.zig");

const VK_NULL_U64 = c.VK_NULL_U64;
pub const HOT_COMPUTE_STATE_CACHE_CAPACITY: usize = 16;
pub const HOT_DESCRIPTOR_STATE_CACHE_CAPACITY: usize = 32;

pub const CachedDescriptorState = struct {
    descriptor_pool: c.VkDescriptorPool = VK_NULL_U64,
    descriptor_sets: [c.MAX_DESCRIPTOR_SETS]c.VkDescriptorSet = [_]c.VkDescriptorSet{VK_NULL_U64} ** c.MAX_DESCRIPTOR_SETS,
    descriptor_set_count: u32 = 0,
    current_descriptor_bindings_hash: u64 = 0,
    current_descriptor_identity: []const identity.Binding = &.{},
    has_current_descriptor_bindings_hash: bool = false,
};

pub const CachedComputeState = struct {
    pipeline_layout: c.VkPipelineLayout = VK_NULL_U64,
    pipeline: c.VkPipeline = VK_NULL_U64,
    shared_pipeline: ?*shared.Pipeline = null,
    descriptor_pool: c.VkDescriptorPool = VK_NULL_U64,
    descriptor_set_layouts: [c.MAX_DESCRIPTOR_SETS]c.VkDescriptorSetLayout = [_]c.VkDescriptorSetLayout{VK_NULL_U64} ** c.MAX_DESCRIPTOR_SETS,
    descriptor_sets: [c.MAX_DESCRIPTOR_SETS]c.VkDescriptorSet = [_]c.VkDescriptorSet{VK_NULL_U64} ** c.MAX_DESCRIPTOR_SETS,
    descriptor_set_count: u32 = 0,
    current_pipeline_hash: u64 = 0,
    current_layout_hash: u64 = 0,
    current_descriptor_bindings_hash: u64 = 0,
    current_descriptor_identity: []const identity.Binding = &.{},
    hot_descriptor_state_hashes: [HOT_DESCRIPTOR_STATE_CACHE_CAPACITY]u64 = [_]u64{0} ** HOT_DESCRIPTOR_STATE_CACHE_CAPACITY,
    hot_descriptor_states: [HOT_DESCRIPTOR_STATE_CACHE_CAPACITY]CachedDescriptorState = undefined,
    descriptor_state_cache: std.AutoHashMapUnmanaged(u64, CachedDescriptorState) = .{},
    has_pipeline_layout: bool = false,
    has_pipeline: bool = false,
    has_descriptor_pool: bool = false,
    has_current_descriptor_bindings_hash: bool = false,
};

pub fn has_active_compute_state(self: anytype) bool {
    return self.has_pipeline_layout or
        self.has_pipeline or
        self.has_descriptor_pool or
        self.current_pipeline_hash != 0 or
        self.current_layout_hash != 0;
}

pub fn clear_active_compute_state(self: anytype) void {
    self.pipeline_layout = VK_NULL_U64;
    self.pipeline = VK_NULL_U64;
    self.shared_pipeline = null;
    self.descriptor_pool = VK_NULL_U64;
    self.descriptor_set_layouts = [_]c.VkDescriptorSetLayout{VK_NULL_U64} ** c.MAX_DESCRIPTOR_SETS;
    self.descriptor_sets = [_]c.VkDescriptorSet{VK_NULL_U64} ** c.MAX_DESCRIPTOR_SETS;
    self.descriptor_set_count = 0;
    self.current_pipeline_hash = 0;
    self.current_layout_hash = 0;
    self.current_descriptor_bindings_hash = 0;
    self.current_descriptor_identity = &.{};
    self.hot_descriptor_state_hashes = [_]u64{0} ** HOT_DESCRIPTOR_STATE_CACHE_CAPACITY;
    self.hot_descriptor_states = undefined;
    self.current_descriptor_state_cache = .{};
    self.has_pipeline_layout = false;
    self.has_pipeline = false;
    self.has_descriptor_pool = false;
    self.has_current_descriptor_bindings_hash = false;
}

pub fn capture_active_compute_state(self: anytype) CachedComputeState {
    return .{
        .pipeline_layout = self.pipeline_layout,
        .pipeline = self.pipeline,
        .shared_pipeline = self.shared_pipeline,
        .descriptor_pool = self.descriptor_pool,
        .descriptor_set_layouts = self.descriptor_set_layouts,
        .descriptor_sets = self.descriptor_sets,
        .descriptor_set_count = self.descriptor_set_count,
        .current_pipeline_hash = self.current_pipeline_hash,
        .current_layout_hash = self.current_layout_hash,
        .current_descriptor_bindings_hash = self.current_descriptor_bindings_hash,
        .current_descriptor_identity = self.current_descriptor_identity,
        .hot_descriptor_state_hashes = self.hot_descriptor_state_hashes,
        .hot_descriptor_states = self.hot_descriptor_states,
        .descriptor_state_cache = self.current_descriptor_state_cache,
        .has_pipeline_layout = self.has_pipeline_layout,
        .has_pipeline = self.has_pipeline,
        .has_descriptor_pool = self.has_descriptor_pool,
        .has_current_descriptor_bindings_hash = self.has_current_descriptor_bindings_hash,
    };
}

pub fn restore_active_compute_state(self: anytype, cached: CachedComputeState) void {
    self.pipeline_layout = cached.pipeline_layout;
    self.pipeline = cached.pipeline;
    self.shared_pipeline = cached.shared_pipeline;
    self.descriptor_pool = cached.descriptor_pool;
    self.descriptor_set_layouts = cached.descriptor_set_layouts;
    self.descriptor_sets = cached.descriptor_sets;
    self.descriptor_set_count = cached.descriptor_set_count;
    self.current_pipeline_hash = cached.current_pipeline_hash;
    self.current_layout_hash = cached.current_layout_hash;
    self.current_descriptor_bindings_hash = cached.current_descriptor_bindings_hash;
    self.current_descriptor_identity = cached.current_descriptor_identity;
    self.has_bound_descriptor_bindings_hash = false;
    self.hot_descriptor_state_hashes = cached.hot_descriptor_state_hashes;
    self.hot_descriptor_states = cached.hot_descriptor_states;
    self.current_descriptor_state_cache = cached.descriptor_state_cache;
    self.has_pipeline_layout = cached.has_pipeline_layout;
    self.has_pipeline = cached.has_pipeline;
    self.has_descriptor_pool = cached.has_descriptor_pool;
    self.has_current_descriptor_bindings_hash = cached.has_current_descriptor_bindings_hash;
}

pub fn destroy_cached_descriptor_state(self: anytype, cached: CachedDescriptorState) void {
    self.allocator.free(cached.current_descriptor_identity);
    if (cached.descriptor_pool != VK_NULL_U64) {
        c.vkDestroyDescriptorPool(self.device, cached.descriptor_pool, null);
    }
}

pub fn release_descriptor_state_cache(self: anytype) void {
    for (self.hot_descriptor_state_hashes, 0..) |hash, index| {
        if (hash == 0) continue;
        destroy_cached_descriptor_state(self, self.hot_descriptor_states[index]);
        self.hot_descriptor_state_hashes[index] = 0;
    }
    var it = self.current_descriptor_state_cache.valueIterator();
    while (it.next()) |cached| destroy_cached_descriptor_state(self, cached.*);
    self.current_descriptor_state_cache.deinit(self.allocator);
    self.current_descriptor_state_cache = .{};
}

pub fn destroy_cached_compute_state(self: anytype, cached: CachedComputeState) void {
    self.allocator.free(cached.current_descriptor_identity);
    if (cached.shared_pipeline) |entry| {
        self.shared_pipelines.release(self.allocator, self.device, entry);
    } else if (cached.pipeline != VK_NULL_U64) c.vkDestroyPipeline(self.device, cached.pipeline, null);
    if (cached.descriptor_pool != VK_NULL_U64) c.vkDestroyDescriptorPool(self.device, cached.descriptor_pool, null);
    for (cached.hot_descriptor_state_hashes, 0..) |hash, index| {
        if (hash == 0) continue;
        destroy_cached_descriptor_state(self, cached.hot_descriptor_states[index]);
    }
    var descriptor_state_cache = cached.descriptor_state_cache;
    var descriptor_it = descriptor_state_cache.valueIterator();
    while (descriptor_it.next()) |descriptor_cached| {
        destroy_cached_descriptor_state(self, descriptor_cached.*);
    }
    descriptor_state_cache.deinit(self.allocator);
    for (cached.descriptor_set_layouts) |layout| {
        if (layout != VK_NULL_U64) c.vkDestroyDescriptorSetLayout(self.device, layout, null);
    }
    if (cached.pipeline_layout != VK_NULL_U64) c.vkDestroyPipelineLayout(self.device, cached.pipeline_layout, null);
}

pub fn release_cached_compute_states(self: anytype) void {
    for (self.hot_compute_state_hashes, 0..) |hash, index| {
        if (hash == 0) continue;
        destroy_cached_compute_state(self, self.hot_compute_states[index]);
        self.hot_compute_state_hashes[index] = 0;
    }
    var it = self.cached_compute_states.valueIterator();
    while (it.next()) |cached| destroy_cached_compute_state(self, cached.*);
    self.cached_compute_states.deinit(self.allocator);
}

fn take_hot_compute_state(self: anytype, pipeline_hash: u64) ?CachedComputeState {
    if (pipeline_hash == 0) return null;
    for (self.hot_compute_state_hashes, 0..) |hash, index| {
        if (hash != pipeline_hash) continue;
        const cached = self.hot_compute_states[index];
        self.hot_compute_state_hashes[index] = 0;
        return cached;
    }
    return null;
}

fn cached_compute_state(self: anytype, key: u64) ?*const CachedComputeState {
    for (self.hot_compute_state_hashes, 0..) |hash, index| {
        if (hash == key) return &self.hot_compute_states[index];
    }
    return self.cached_compute_states.getPtr(key);
}

/// Hashes locate candidates; exact identity authorizes reuse. Collision entries
/// stay independently owned so already-recorded commands retain their pipelines.
pub fn resolve_compute_state_hash(self: anytype, hash: u64, request: shared.Request) !u64 {
    var key = if (hash == 0) 1 else hash;
    while (true) {
        const entry = blk: {
            if (self.has_pipeline and self.current_pipeline_hash == key) {
                break :blk self.shared_pipeline orelse return error.InvalidState;
            }
            if (cached_compute_state(self, key)) |cached| {
                break :blk cached.shared_pipeline orelse return error.InvalidState;
            }
            return key;
        };
        if (try entry.matches(request)) return key;
        key +%= 1;
        if (key == 0) key = 1;
    }
}

fn put_hot_compute_state(self: anytype, pipeline_hash: u64, cached: CachedComputeState) bool {
    if (pipeline_hash == 0) return false;
    for (self.hot_compute_state_hashes, 0..) |hash, index| {
        if (hash != 0 and hash != pipeline_hash) continue;
        if (hash == pipeline_hash) {
            destroy_cached_compute_state(self, self.hot_compute_states[index]);
        }
        self.hot_compute_states[index] = cached;
        self.hot_compute_state_hashes[index] = pipeline_hash;
        return true;
    }
    return false;
}

pub fn stash_active_compute_state(self: anytype) !void {
    if (!has_active_compute_state(self)) return;
    const cache_key = self.current_pipeline_hash;
    if (cache_key == 0) return;
    const cached = capture_active_compute_state(self);
    clear_active_compute_state(self);
    errdefer restore_active_compute_state(self, cached);
    if (self.cached_compute_states.fetchRemove(cache_key)) |removed| {
        destroy_cached_compute_state(self, removed.value);
    }
    if (put_hot_compute_state(self, cache_key, cached)) return;
    try self.cached_compute_states.put(self.allocator, cache_key, cached);
}

pub fn activate_cached_compute_state(self: anytype, pipeline_hash: u64) bool {
    if (take_hot_compute_state(self, pipeline_hash)) |cached| {
        restore_active_compute_state(self, cached);
        return true;
    }
    const removed = self.cached_compute_states.fetchRemove(pipeline_hash) orelse return false;
    restore_active_compute_state(self, removed.value);
    return true;
}

test "hot compute state cache activates before hash map fallback" {
    const TestRuntime = struct {
        allocator: std.mem.Allocator,
        shared_pipelines: shared.Registry = .{},
        device: c.VkDevice = null,
        pipeline_layout: c.VkPipelineLayout = VK_NULL_U64,
        pipeline: c.VkPipeline = VK_NULL_U64,
        shared_pipeline: ?*shared.Pipeline = null,
        descriptor_pool: c.VkDescriptorPool = VK_NULL_U64,
        descriptor_set_layouts: [c.MAX_DESCRIPTOR_SETS]c.VkDescriptorSetLayout = [_]c.VkDescriptorSetLayout{VK_NULL_U64} ** c.MAX_DESCRIPTOR_SETS,
        descriptor_sets: [c.MAX_DESCRIPTOR_SETS]c.VkDescriptorSet = [_]c.VkDescriptorSet{VK_NULL_U64} ** c.MAX_DESCRIPTOR_SETS,
        descriptor_set_count: u32 = 0,
        current_pipeline_hash: u64 = 0,
        current_layout_hash: u64 = 0,
        current_descriptor_bindings_hash: u64 = 0,
        current_descriptor_identity: []const identity.Binding = &.{},
        hot_descriptor_state_hashes: [HOT_DESCRIPTOR_STATE_CACHE_CAPACITY]u64 = [_]u64{0} ** HOT_DESCRIPTOR_STATE_CACHE_CAPACITY,
        hot_descriptor_states: [HOT_DESCRIPTOR_STATE_CACHE_CAPACITY]CachedDescriptorState = undefined,
        current_descriptor_state_cache: std.AutoHashMapUnmanaged(u64, CachedDescriptorState) = .{},
        hot_compute_state_hashes: [HOT_COMPUTE_STATE_CACHE_CAPACITY]u64 = [_]u64{0} ** HOT_COMPUTE_STATE_CACHE_CAPACITY,
        hot_compute_states: [HOT_COMPUTE_STATE_CACHE_CAPACITY]CachedComputeState = undefined,
        cached_compute_states: std.AutoHashMapUnmanaged(u64, CachedComputeState) = .{},
        has_pipeline_layout: bool = false,
        has_pipeline: bool = false,
        has_descriptor_pool: bool = false,
        has_current_descriptor_bindings_hash: bool = false,
        has_bound_descriptor_bindings_hash: bool = false,
    };
    var rt = TestRuntime{
        .allocator = std.testing.allocator,
        .current_pipeline_hash = 42,
        .has_pipeline = true,
        .pipeline = 100,
    };
    try stash_active_compute_state(&rt);
    try std.testing.expectEqual(@as(u64, 42), rt.hot_compute_state_hashes[0]);
    try std.testing.expectEqual(@as(usize, 0), rt.cached_compute_states.count());
    try std.testing.expect(activate_cached_compute_state(&rt, 42));
    try std.testing.expectEqual(@as(u64, 0), rt.hot_compute_state_hashes[0]);
    try std.testing.expectEqual(@as(u64, 42), rt.current_pipeline_hash);
    try std.testing.expectEqual(@as(c.VkPipeline, 100), rt.pipeline);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    rt.allocator = failing.allocator();
    for (&rt.hot_compute_state_hashes, &rt.hot_compute_states, 0..) |*hash, *state, index| {
        hash.* = index + 1;
        state.* = .{};
    }
    try std.testing.expectError(error.OutOfMemory, stash_active_compute_state(&rt));
    try std.testing.expectEqual(@as(u64, 42), rt.current_pipeline_hash);
    try std.testing.expectEqual(@as(c.VkPipeline, 100), rt.pipeline);
    try std.testing.expectEqual(@as(usize, 0), rt.cached_compute_states.count());

    rt.descriptor_pool = 200;
    rt.has_descriptor_pool = true;
    rt.current_descriptor_bindings_hash = 43;
    rt.has_current_descriptor_bindings_hash = true;
    for (&rt.hot_descriptor_state_hashes, &rt.hot_descriptor_states, 0..) |*hash, *state, index| {
        hash.* = index + 1;
        state.* = .{};
    }
    try std.testing.expectError(error.OutOfMemory, stash_active_descriptor_state(&rt));
    try std.testing.expectEqual(@as(c.VkDescriptorPool, 200), rt.descriptor_pool);
    try std.testing.expect(rt.has_descriptor_pool);
    try std.testing.expectEqual(@as(u64, 43), rt.current_descriptor_bindings_hash);
    try std.testing.expectEqual(@as(usize, 0), rt.current_descriptor_state_cache.count());

    rt.allocator = std.testing.allocator;
    try stash_active_compute_state(&rt);
    try std.testing.expect(activate_cached_compute_state(&rt, 42));
    try std.testing.expectEqual(@as(c.VkPipeline, 100), rt.pipeline);
    try std.testing.expectEqual(@as(c.VkDescriptorPool, 200), rt.descriptor_pool);
    try stash_active_descriptor_state(&rt);
    try std.testing.expect(activate_cached_descriptor_state(&rt, 43));
    try std.testing.expectEqual(@as(c.VkDescriptorPool, 200), rt.descriptor_pool);
    rt.cached_compute_states.deinit(rt.allocator);
    rt.current_descriptor_state_cache.deinit(rt.allocator);
}

pub fn capture_active_descriptor_state(self: anytype) CachedDescriptorState {
    return .{
        .descriptor_pool = self.descriptor_pool,
        .descriptor_sets = self.descriptor_sets,
        .descriptor_set_count = self.descriptor_set_count,
        .current_descriptor_bindings_hash = self.current_descriptor_bindings_hash,
        .current_descriptor_identity = self.current_descriptor_identity,
        .has_current_descriptor_bindings_hash = self.has_current_descriptor_bindings_hash,
    };
}

pub fn clear_active_descriptor_state(self: anytype) void {
    self.descriptor_pool = VK_NULL_U64;
    self.descriptor_sets = [_]c.VkDescriptorSet{VK_NULL_U64} ** c.MAX_DESCRIPTOR_SETS;
    self.current_descriptor_bindings_hash = 0;
    self.current_descriptor_identity = &.{};
    self.has_descriptor_pool = false;
    self.has_current_descriptor_bindings_hash = false;
}

pub fn restore_active_descriptor_state(self: anytype, cached: CachedDescriptorState) void {
    self.descriptor_pool = cached.descriptor_pool;
    self.descriptor_sets = cached.descriptor_sets;
    self.descriptor_set_count = cached.descriptor_set_count;
    self.current_descriptor_bindings_hash = cached.current_descriptor_bindings_hash;
    self.current_descriptor_identity = cached.current_descriptor_identity;
    self.has_bound_descriptor_bindings_hash = false;
    self.has_descriptor_pool = cached.descriptor_pool != VK_NULL_U64;
    self.has_current_descriptor_bindings_hash = cached.has_current_descriptor_bindings_hash;
}

pub fn has_cached_descriptor_state(self: anytype, key: u64) bool {
    for (self.hot_descriptor_state_hashes) |hash| {
        if (hash == key) return true;
    }
    return self.current_descriptor_state_cache.contains(key);
}

pub fn resolve_descriptor_state_hash(self: anytype, hash: u64, bindings: []const compute.KernelBinding) u64 {
    var key = if (hash == 0) 1 else hash;
    while (true) {
        const retained = blk: {
            if (self.has_descriptor_pool and self.has_current_descriptor_bindings_hash and self.current_descriptor_bindings_hash == key) {
                break :blk self.current_descriptor_identity;
            }
            for (self.hot_descriptor_state_hashes, 0..) |candidate, index| {
                if (candidate == key) break :blk self.hot_descriptor_states[index].current_descriptor_identity;
            }
            if (self.current_descriptor_state_cache.get(key)) |cached| break :blk cached.current_descriptor_identity;
            return key;
        };
        if (identity.matches(self, retained, bindings)) return key;
        key +%= 1;
        if (key == 0) key = 1;
    }
}

pub fn validate_compute_resources(self: anytype, state: CachedComputeState) !void {
    try identity.validate(self, state.current_descriptor_identity);
    for (state.hot_descriptor_state_hashes, 0..) |hash, index| {
        if (hash != 0) try identity.validate(self, state.hot_descriptor_states[index].current_descriptor_identity);
    }
    var remaining = state.descriptor_state_cache.valueIterator();
    while (remaining.next()) |cached| try identity.validate(self, cached.current_descriptor_identity);
}

pub fn destroy_active_descriptor_pool(self: anytype) void {
    destroy_cached_descriptor_state(self, capture_active_descriptor_state(self));
    clear_active_descriptor_state(self);
    self.has_bound_descriptor_bindings_hash = false;
}

fn take_hot_descriptor_state(self: anytype, descriptor_bindings_hash: u64) ?CachedDescriptorState {
    if (descriptor_bindings_hash == 0) return null;
    for (self.hot_descriptor_state_hashes, 0..) |hash, index| {
        if (hash != descriptor_bindings_hash) continue;
        const cached = self.hot_descriptor_states[index];
        self.hot_descriptor_state_hashes[index] = 0;
        return cached;
    }
    return null;
}

fn put_hot_descriptor_state(self: anytype, descriptor_bindings_hash: u64, cached: CachedDescriptorState) bool {
    if (descriptor_bindings_hash == 0) return false;
    for (self.hot_descriptor_state_hashes, 0..) |hash, index| {
        if (hash != 0 and hash != descriptor_bindings_hash) continue;
        if (hash == descriptor_bindings_hash) {
            destroy_cached_descriptor_state(self, self.hot_descriptor_states[index]);
        }
        self.hot_descriptor_states[index] = cached;
        self.hot_descriptor_state_hashes[index] = descriptor_bindings_hash;
        return true;
    }
    return false;
}

pub fn stash_active_descriptor_state(self: anytype) !void {
    if (!self.has_descriptor_pool or !self.has_current_descriptor_bindings_hash) return;
    const cache_key = self.current_descriptor_bindings_hash;
    if (cache_key == 0) return;
    const cached = capture_active_descriptor_state(self);
    clear_active_descriptor_state(self);
    errdefer restore_active_descriptor_state(self, cached);
    if (put_hot_descriptor_state(self, cache_key, cached)) return;
    if (self.current_descriptor_state_cache.fetchRemove(cache_key)) |removed| {
        destroy_cached_descriptor_state(self, removed.value);
    }
    try self.current_descriptor_state_cache.put(self.allocator, cache_key, cached);
}

pub fn activate_cached_descriptor_state(self: anytype, descriptor_bindings_hash: u64) bool {
    if (take_hot_descriptor_state(self, descriptor_bindings_hash)) |cached| {
        restore_active_descriptor_state(self, cached);
        return true;
    }
    const removed = self.current_descriptor_state_cache.fetchRemove(descriptor_bindings_hash) orelse return false;
    restore_active_descriptor_state(self, removed.value);
    return true;
}
