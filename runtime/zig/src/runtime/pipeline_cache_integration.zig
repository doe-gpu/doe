// pipeline_cache_integration.zig — Phase 2 pipeline cache integration.
//
// Lazily initializes a global PipelineCache and exposes lookup/store helpers
// for compute and render pipelines.  Atomic counters track hit/miss/store
// telemetry for warmup-policy decisions.

const std = @import("std");
const pipeline_cache = @import("cache/pipeline_cache.zig");

const PipelineCache = pipeline_cache.PipelineCache;
const PipelineCacheKey = pipeline_cache.PipelineCacheKey;
const PipelineKind = PipelineCacheKey.PipelineKind;

// ============================================================
// Telemetry counters (lock-free)

var cache_hits = std.atomic.Value(u64).init(0);
var cache_misses = std.atomic.Value(u64).init(0);
var cache_stores = std.atomic.Value(u64).init(0);

pub const Telemetry = struct {
    hits: u64,
    misses: u64,
    stores: u64,
};

pub fn getTelemetry() Telemetry {
    return .{
        .hits = cache_hits.load(.monotonic),
        .misses = cache_misses.load(.monotonic),
        .stores = cache_stores.load(.monotonic),
    };
}

// ============================================================
// Global cache singleton

var global_cache: ?*PipelineCache = null;
var init_attempted: bool = false;

pub fn ensureGlobalCache() ?*PipelineCache {
    if (global_cache) |c| return c;
    if (init_attempted) return null;

    init_attempted = true;
    global_cache = PipelineCache.init(std.heap.c_allocator, null) catch null;
    return global_cache;
}

// ============================================================
// Compute pipeline helpers

pub fn lookupComputePipeline(wgsl_source: ?[]const u8) ?[]const u8 {
    const cache = ensureGlobalCache() orelse return null;
    const key = buildComputeKey(wgsl_source);
    if (cache.lookup(&key)) |data| {
        _ = cache_hits.fetchAdd(1, .monotonic);
        return data;
    }
    _ = cache_misses.fetchAdd(1, .monotonic);
    return null;
}

pub fn storeComputePipeline(wgsl_source: ?[]const u8, data: []const u8) void {
    const cache = ensureGlobalCache() orelse return;
    const key = buildComputeKey(wgsl_source);
    cache.store(&key, data);
    _ = cache_stores.fetchAdd(1, .monotonic);
}

pub fn recordComputePipelineCreation(wgsl_source: ?[]const u8) void {
    const cache = ensureGlobalCache() orelse return;
    const key = buildComputeKey(wgsl_source);
    if (cache.lookup(&key) != null) {
        _ = cache_hits.fetchAdd(1, .monotonic);
        return;
    }
    _ = cache_misses.fetchAdd(1, .monotonic);
    const marker = "compute-creation-recorded";
    cache.store(&key, marker);
    _ = cache_stores.fetchAdd(1, .monotonic);
}

fn buildComputeKey(wgsl_source: ?[]const u8) PipelineCacheKey {
    const wgsl_hash = if (wgsl_source) |src|
        pipeline_cache.hash_wgsl(src)
    else
        std.mem.zeroes([32]u8);

    return .{
        .wgsl_hash = wgsl_hash,
        .kind = .compute,
        .pixel_format = 0,
        .vertex_entry_hash = 0,
        .fragment_entry_hash = 0,
        .sample_count = 1,
        .color_attachment_count = 0,
    };
}

// ============================================================
// Render pipeline helpers

pub fn lookupRenderPipeline(
    wgsl_source: ?[]const u8,
    pixel_format: u32,
    vertex_entry: ?[]const u8,
    fragment_entry: ?[]const u8,
    sample_count: u32,
    color_attachment_count: u32,
) ?[]const u8 {
    const cache = ensureGlobalCache() orelse return null;
    const key = buildRenderKey(wgsl_source, pixel_format, vertex_entry, fragment_entry, sample_count, color_attachment_count);
    if (cache.lookup(&key)) |data| {
        _ = cache_hits.fetchAdd(1, .monotonic);
        return data;
    }
    _ = cache_misses.fetchAdd(1, .monotonic);
    return null;
}

pub fn storeRenderPipeline(
    wgsl_source: ?[]const u8,
    pixel_format: u32,
    vertex_entry: ?[]const u8,
    fragment_entry: ?[]const u8,
    sample_count: u32,
    color_attachment_count: u32,
    data: []const u8,
) void {
    const cache = ensureGlobalCache() orelse return;
    const key = buildRenderKey(wgsl_source, pixel_format, vertex_entry, fragment_entry, sample_count, color_attachment_count);
    cache.store(&key, data);
    _ = cache_stores.fetchAdd(1, .monotonic);
}

pub fn recordRenderPipelineCreation() void {
    const cache = ensureGlobalCache() orelse return;
    const key = buildRenderKey(null, 0, null, null, 1, 0);
    if (cache.lookup(&key) != null) {
        _ = cache_hits.fetchAdd(1, .monotonic);
        return;
    }
    _ = cache_misses.fetchAdd(1, .monotonic);
    const marker = "render-creation-recorded";
    cache.store(&key, marker);
    _ = cache_stores.fetchAdd(1, .monotonic);
}

fn buildRenderKey(
    wgsl_source: ?[]const u8,
    pixel_format: u32,
    vertex_entry: ?[]const u8,
    fragment_entry: ?[]const u8,
    sample_count: u32,
    color_attachment_count: u32,
) PipelineCacheKey {
    const wgsl_hash = if (wgsl_source) |src|
        pipeline_cache.hash_wgsl(src)
    else
        std.mem.zeroes([32]u8);

    return .{
        .wgsl_hash = wgsl_hash,
        .kind = .render,
        .pixel_format = pixel_format,
        .vertex_entry_hash = if (vertex_entry) |e| pipeline_cache.hash_string_u64(e) else 0,
        .fragment_entry_hash = if (fragment_entry) |e| pipeline_cache.hash_string_u64(e) else 0,
        .sample_count = sample_count,
        .color_attachment_count = color_attachment_count,
    };
}
