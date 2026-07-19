// metal_deferred_release.zig — Batch deferred release pool for Metal objects.
//
// Doe's explicit reference counting releases Metal objects synchronously via
// CFRelease on each sampler_destroy/texture_destroy call. Under aggregate lane
// pressure (e.g. texture_sampler_write_query_destroy workload with repeat=10),
// per-call CFRelease serializes against Metal's internal ARC machinery, causing
// tail-negative timing versus Dawn's deferred GC.
//
// This module collects pending releases in a fixed-capacity ring buffer and
// batch-drains them at command buffer boundaries (flush_queue_timed). This
// amortizes the Obj-C ARC overhead into a single tight loop at a safe point
// where no encoder holds a reference to the released objects.
//
// Additionally, a sampler descriptor cache avoids redundant MTLSamplerState
// allocations: identical sampler parameter tuples share a single Metal object
// with a reference count, eliminating create/destroy round-trips entirely for
// the common case of repeated identical sampler descriptors.

const std = @import("std");
const bridge = @import("metal_bridge_decls.zig");
const model_render_types = @import("../../contracts/model/model_render_types.zig");
const metal_bridge_release = bridge.metal_bridge_release;
const metal_bridge_device_new_sampler = bridge.metal_bridge_device_new_sampler;

const model = struct {
    pub const SamplerCreateCommand = model_render_types.SamplerCreateCommand;
};

// ============================================================
// Constants
// ============================================================

/// Maximum pending releases before forced drain. Sized to cover the typical
/// texture_sampler_write_query_destroy command stream (2 destroys per iteration
/// x 10 repeats = 20) with headroom for surface/render target churn.
const DEFERRED_RING_CAPACITY: usize = 64;

/// Maximum unique sampler descriptor tuples cached. Metal sampler state objects
/// are immutable and lightweight; caching avoids alloc/dealloc churn. 16 covers
/// the practical range of filter/address/LOD combinations in Doppler workloads.
const SAMPLER_CACHE_CAPACITY: usize = 16;

// ============================================================
// Deferred release ring buffer
// ============================================================

pub const DeferredReleasePool = struct {
    ring: [DEFERRED_RING_CAPACITY]?*anyopaque = [_]?*anyopaque{null} ** DEFERRED_RING_CAPACITY,
    count: usize = 0,

    /// Enqueue a Metal object for deferred release. If the ring is full,
    /// drain all pending releases first to maintain the invariant.
    pub fn enqueue(self: *DeferredReleasePool, obj: ?*anyopaque) void {
        if (obj == null) return;
        if (self.count >= DEFERRED_RING_CAPACITY) {
            self.drain();
        }
        self.ring[self.count] = obj;
        self.count += 1;
    }

    /// Batch-release all pending objects. Called at command buffer boundaries
    /// (flush_queue_timed) and during runtime teardown (deinit).
    pub fn drain(self: *DeferredReleasePool) void {
        const n = self.count;
        if (n == 0) return;
        // Tight release loop — single call site, branch-free interior.
        for (self.ring[0..n]) |obj| {
            metal_bridge_release(obj);
        }
        // Zero the drained slots to avoid dangling pointers.
        @memset(self.ring[0..n], null);
        self.count = 0;
    }

    /// Number of objects waiting for release.
    pub fn pending(self: *const DeferredReleasePool) usize {
        return self.count;
    }
};

// ============================================================
// Sampler descriptor cache
// ============================================================

/// Compact representation of a sampler descriptor for cache keying.
/// Packed into 20 bytes to allow cheap equality comparison.
pub const SamplerDescKey = struct {
    min_filter: u32,
    mag_filter: u32,
    mipmap_filter: u32,
    address_mode_u: u32,
    address_mode_v: u32,
    address_mode_w: u32,
    lod_min_clamp_bits: u32,
    lod_max_clamp_bits: u32,
    max_anisotropy: u16,

    pub fn from_cmd(cmd: model.SamplerCreateCommand) SamplerDescKey {
        return .{
            .min_filter = cmd.min_filter,
            .mag_filter = cmd.mag_filter,
            .mipmap_filter = cmd.mipmap_filter,
            .address_mode_u = cmd.address_mode_u,
            .address_mode_v = cmd.address_mode_v,
            .address_mode_w = cmd.address_mode_w,
            .lod_min_clamp_bits = @bitCast(cmd.lod_min_clamp),
            .lod_max_clamp_bits = @bitCast(cmd.lod_max_clamp),
            .max_anisotropy = cmd.max_anisotropy,
        };
    }
};

const SamplerCacheEntry = struct {
    key: SamplerDescKey,
    handle: ?*anyopaque,
    ref_count: u32,
};

pub const SamplerCache = struct {
    entries: [SAMPLER_CACHE_CAPACITY]SamplerCacheEntry = undefined,
    len: usize = 0,

    pub fn init() SamplerCache {
        var cache = SamplerCache{};
        for (&cache.entries) |*e| {
            e.* = .{ .key = std.mem.zeroes(SamplerDescKey), .handle = null, .ref_count = 0 };
        }
        return cache;
    }

    /// Look up or create a Metal sampler matching the given descriptor.
    /// Returns the cached handle (shared, NOT +1 retained for the caller —
    /// the cache owns the single Metal reference). The caller must call
    /// release() with the same key when done.
    pub fn acquire(self: *SamplerCache, device: ?*anyopaque, cmd: model.SamplerCreateCommand) !?*anyopaque {
        const key = SamplerDescKey.from_cmd(cmd);

        // Scan for existing entry with matching key.
        for (self.entries[0..self.len]) |*entry| {
            if (std.meta.eql(entry.key, key)) {
                entry.ref_count += 1;
                return entry.handle;
            }
        }

        // Cache miss: create new Metal sampler.
        const handle = metal_bridge_device_new_sampler(
            device,
            cmd.min_filter,
            cmd.mag_filter,
            cmd.mipmap_filter,
            cmd.address_mode_u,
            cmd.address_mode_v,
            cmd.address_mode_w,
            cmd.lod_min_clamp,
            cmd.lod_max_clamp,
            cmd.max_anisotropy,
        ) orelse return error.InvalidState;

        // If cache is full, evict the entry with ref_count == 0 (LRU-ish).
        if (self.len >= SAMPLER_CACHE_CAPACITY) {
            var evict_idx: ?usize = null;
            for (self.entries[0..self.len], 0..) |*entry, i| {
                if (entry.ref_count == 0) {
                    evict_idx = i;
                    break;
                }
            }
            if (evict_idx) |idx| {
                metal_bridge_release(self.entries[idx].handle);
                self.entries[idx] = .{ .key = key, .handle = handle, .ref_count = 1 };
                return handle;
            }
            // All entries in use — cannot cache, return uncached handle.
            // Caller manages this handle directly.
            return handle;
        }

        self.entries[self.len] = .{ .key = key, .handle = handle, .ref_count = 1 };
        self.len += 1;
        return handle;
    }

    /// Release a reference to a cached sampler. If the ref count drops to
    /// zero, the entry remains in cache for future reuse (lazy eviction).
    /// Returns true if the handle is cache-managed (caller should NOT release
    /// it via metal_bridge_release). Returns false if the handle was not found
    /// in cache (caller must release it directly).
    pub fn release(self: *SamplerCache, handle: ?*anyopaque) bool {
        if (handle == null) return false;
        for (self.entries[0..self.len]) |*entry| {
            if (entry.handle == handle) {
                entry.ref_count -|= 1;
                return true;
            }
        }
        return false;
    }

    /// Release all cached Metal sampler objects. Called during runtime teardown.
    pub fn deinit(self: *SamplerCache) void {
        for (self.entries[0..self.len]) |*entry| {
            if (entry.handle != null) {
                metal_bridge_release(entry.handle);
                entry.handle = null;
            }
        }
        self.len = 0;
    }
};
