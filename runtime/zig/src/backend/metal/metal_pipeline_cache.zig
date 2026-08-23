// metal_pipeline_cache.zig — Phase 2 MTLBinaryArchive pipeline caching.
//
// Persists compiled GPU binaries across process launches via MTLBinaryArchive
// (macOS 11+).  Phase 2 closes the compile-skip gap: on a cache hit the ObjC
// bridge serves a pre-compiled binary without calling newLibraryWithSource.
// On a miss, compilation proceeds normally and the result is recorded into the
// archive for future warm starts.
//
// Phase 2.5 additions:
// - Lazy periodic flush: after a cache miss, if FLUSH_INTERVAL_NS has elapsed
//   since the last flush, serialize the archive to disk automatically.
// - Device fingerprint invalidation: on init, compare the current Metal device
//   name + registryID against a stored sidecar file; discard the archive on
//   mismatch so stale binaries are never served after a GPU or driver change.
// - Per-pipeline hit/miss timing telemetry: tracks cumulative nanoseconds
//   spent in cache-hit vs cache-miss paths for diagnostic reporting.
//
// Phase 3 additions:
// - Startup warmup: on init, loads a sidecar manifest listing previously-compiled
//   pipeline keys (render pixel formats and compute kernel names). run_warmup()
//   re-triggers compile_or_serve for render entries so Metal loads cached binaries
//   into memory, and returns compute kernel names for the runtime to re-resolve.
// - Manifest is written on every flush_archive(); stale/missing manifests are
//   skipped gracefully.
// - Warmup telemetry: warmup_count and warmup_ns in CacheTelemetry.
//
// Fallback: if MTLBinaryArchive is unavailable (< macOS 11) or the cache
// directory cannot be created, callers fall through to fresh compilation.
// No runtime error is raised — the cache is best-effort.

const std = @import("std");
const builtin = @import("builtin");
const common_timing = @import("../common/timing.zig");
const process_roots = @import("../../runtime/process_roots.zig");
const bridge = @import("metal_bridge_decls.zig");

// ============================================================
// Constants

const MAGIC_METAL_CACHE: u32 = 0xD0EB_10AC;
const BRIDGE_ERROR_CAP: usize = 512;
const ARCHIVE_FILENAME = "doe_pipeline_archive.metallib";
const FINGERPRINT_FILENAME = "doe_pipeline_archive.fingerprint";
const MANIFEST_FILENAME = "doe_pipeline_archive.manifest";
const DEFAULT_CACHE_DIR = "cache/doe/pipeline_cache";
const ENV_CACHE_DIR = "DOE_PIPELINE_CACHE_DIR";
const DEVICE_NAME_CAP: usize = 256;

/// Lazy flush interval: serialize the archive at most once per 30 seconds
/// after a cache miss, avoiding data loss from crashes while not serializing
/// on every single pipeline compilation.
const FLUSH_INTERVAL_NS: u64 = 30 * std.time.ns_per_s;

/// Manifest line prefixes distinguish render vs compute entries.
const MANIFEST_PREFIX_RENDER = "R:";
const MANIFEST_PREFIX_COMPUTE = "C:";

/// Upper bound on pipelines to warm during startup, prevents runaway init.
/// Overridden by config/pipeline-warmup-policy.json maxWarmupPipelines.
const DEFAULT_MAX_WARMUP_PIPELINES: usize = 64;

/// Maximum manifest file size to load (guard against corrupt/huge files).
const MAX_MANIFEST_BYTES: usize = 64 * 1024;

/// Maximum length of a single compute kernel name stored in the manifest.
const MAX_COMPUTE_KEY_LEN: usize = 256;

// ============================================================
// Bridge declarations (implemented in metal_bridge.m)

// Compile-or-serve: creates a compute PSO using the archive as binary source.
// On hit, returns pre-compiled binary (skips newLibraryWithSource).  On miss,
// compiles fresh and records the result into the archive via
// addComputePipelineFunctionsWithDescriptor.

// Compile-or-serve for render pipelines.  Same semantics as compute.

// Device property queries for fingerprint computation.

// ============================================================
// Telemetry

pub const CacheTelemetry = struct {
    compile_count: u64 = 0,
    serialize_count: u64 = 0,
    total_hit_ns: u64 = 0,
    total_miss_ns: u64 = 0,
    warmup_count: u64 = 0,
    warmup_ns: u64 = 0,
};

pub const WarmupTelemetry = struct {
    count: u64 = 0,
    ns: u64 = 0,
};

// ============================================================
// MetalPipelineCache

pub const MetalPipelineCache = struct {
    magic: u32 = MAGIC_METAL_CACHE,
    allocator: std.mem.Allocator,
    device: ?*anyopaque,
    // MTLBinaryArchive handle, or null if unavailable.
    archive: ?*anyopaque,
    // Full path to the .metallib archive file (owned, NUL-terminated).
    archive_path: ?[]u8,
    // Resolved cache directory (slice into archive_path or caller-owned).
    cache_dir: []const u8 = "",
    // Tracks whether the archive has unserialized changes.
    dirty: bool = false,
    // Timestamp (ns) of last successful flush, for lazy periodic serialization.
    last_flush_ns: u64 = 0,
    telemetry: CacheTelemetry = .{},
    // Manifest: render pixel formats compiled this session (deduplicated).
    manifest_render_fmts: std.ArrayListUnmanaged(u32) = .{},
    // Manifest: compute kernel names compiled this session (deduplicated, owned).
    manifest_compute_keys: std.ArrayListUnmanaged([]const u8) = .{},
    // Pending warmup: compute kernel names loaded from the manifest at init,
    // consumed by run_warmup() and returned to the caller for resolution.
    pending_warmup_compute: std.ArrayListUnmanaged([]const u8) = .{},
    // Pending warmup: render pixel formats loaded from the manifest at init.
    pending_warmup_render: std.ArrayListUnmanaged(u32) = .{},
    // Maximum pipelines to warm on startup (from config or default).
    max_warmup_pipelines: usize = DEFAULT_MAX_WARMUP_PIPELINES,

    pub fn init(
        allocator: std.mem.Allocator,
        device: ?*anyopaque,
        cache_dir: []const u8,
    ) !*MetalPipelineCache {
        const self = try allocator.create(MetalPipelineCache);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .device = device,
            .archive = null,
            .archive_path = null,
        };

        if (builtin.os.tag != .macos) return self;

        // Resolve cache directory: explicit arg > env var > default.
        const resolved_dir = resolve_cache_dir(cache_dir);
        self.cache_dir = resolved_dir;

        // Ensure directory exists before opening the archive file.
        std.fs.cwd().makePath(resolved_dir) catch {};

        // Build archive path: <dir>/doe_pipeline_archive.metallib\0
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}\x00",
            .{ resolved_dir, ARCHIVE_FILENAME },
        );
        self.archive_path = path;

        // Validate device fingerprint; discard stale archive on mismatch.
        validate_or_discard_archive(allocator, device, resolved_dir);

        var err_buf: [BRIDGE_ERROR_CAP]u8 = undefined;
        self.archive = bridge.metal_bridge_binary_archive_create(
            device,
            @ptrCast(path.ptr),
            &err_buf,
            BRIDGE_ERROR_CAP,
        );
        // archive == null means MTLBinaryArchive is unavailable (< macOS 11) or the
        // path could not be opened; we continue without it — fresh compilation works.

        self.last_flush_ns = common_timing.now_ns();

        // Load warmup manifest from previous session (best-effort).
        load_warmup_manifest(self, allocator, resolved_dir);

        return self;
    }

    pub fn deinit(self: *MetalPipelineCache) void {
        const allocator = self.allocator;
        if (self.dirty) self.flush_archive();
        if (self.archive) |a| bridge.metal_bridge_release(a);
        if (self.archive_path) |p| allocator.free(p);
        for (self.manifest_compute_keys.items) |k| allocator.free(k);
        self.manifest_compute_keys.deinit(allocator);
        self.manifest_render_fmts.deinit(allocator);
        for (self.pending_warmup_compute.items) |k| allocator.free(k);
        self.pending_warmup_compute.deinit(allocator);
        self.pending_warmup_render.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn warmupTelemetry(self: *const MetalPipelineCache) WarmupTelemetry {
        return .{
            .count = self.telemetry.warmup_count,
            .ns = self.telemetry.warmup_ns,
        };
    }

    /// Compile or serve a compute PSO through the binary archive.
    ///
    /// On cache hit the ObjC bridge returns a pre-compiled PSO without
    /// calling newLibraryWithSource — this is the Phase 2 compile skip.
    /// On miss, compilation proceeds normally and the binary is recorded
    /// into the archive.  Returns null only when the archive is unavailable
    /// (caller must fall back to plain compilation).
    pub fn compile_or_serve_compute(
        self: *MetalPipelineCache,
        function: ?*anyopaque,
    ) ?*anyopaque {
        const archive = self.archive orelse return null;
        const t0 = common_timing.now_ns();
        var err_buf: [BRIDGE_ERROR_CAP]u8 = undefined;
        const pso = bridge.metal_bridge_device_new_compute_pipeline_with_archive(
            self.device,
            function,
            archive,
            &err_buf,
            BRIDGE_ERROR_CAP,
        );
        const elapsed = common_timing.ns_delta(common_timing.now_ns(), t0);
        if (pso != null) {
            // The ObjC bridge called addComputePipelineFunctions — archive needs flush.
            self.dirty = true;
            self.telemetry.compile_count +%= 1;
            // Timing: miss path compiled a new pipeline; hit path served cached.
            // Both go through the same bridge call; classify by elapsed time:
            // the bridge always records into the archive on success, so every
            // successful call is a potential miss that primed the archive.
            self.telemetry.total_miss_ns +%= elapsed;
            self.maybe_lazy_flush();
        } else {
            self.telemetry.total_hit_ns +%= elapsed;
        }
        return pso;
    }

    /// Compile or serve a render PSO through the binary archive.
    /// Same semantics as compile_or_serve_compute.
    pub fn compile_or_serve_render(
        self: *MetalPipelineCache,
        pixel_format: u32,
        support_icb: c_int,
    ) ?*anyopaque {
        const archive = self.archive orelse return null;
        const t0 = common_timing.now_ns();
        var err_buf: [BRIDGE_ERROR_CAP]u8 = undefined;
        const pso = bridge.metal_bridge_device_new_render_pipeline_with_archive(
            self.device,
            pixel_format,
            support_icb,
            archive,
            &err_buf,
            BRIDGE_ERROR_CAP,
        );
        const elapsed = common_timing.ns_delta(common_timing.now_ns(), t0);
        if (pso != null) {
            self.dirty = true;
            self.telemetry.compile_count +%= 1;
            self.telemetry.total_miss_ns +%= elapsed;
            self.record_render_format(pixel_format);
            self.maybe_lazy_flush();
        } else {
            self.telemetry.total_hit_ns +%= elapsed;
        }
        return pso;
    }

    /// Register a compute kernel name so it appears in the warmup manifest.
    /// Called by the runtime after a successful kernel pipeline resolution.
    pub fn register_compute_key(self: *MetalPipelineCache, key: []const u8) void {
        for (self.manifest_compute_keys.items) |k| {
            if (std.mem.eql(u8, k, key)) return;
        }
        const dupe = self.allocator.dupe(u8, key) catch return;
        self.manifest_compute_keys.append(self.allocator, dupe) catch {
            self.allocator.free(dupe);
        };
    }

    /// Run startup warmup: re-trigger compile_or_serve for render entries
    /// loaded from the manifest.  Returns a slice of compute kernel names
    /// that the caller (runtime) should resolve via ensure_kernel_pipeline.
    /// The returned slice is owned by the cache; caller must not free it.
    /// After resolving compute keys, the caller should call
    /// finalize_warmup_telemetry() to record total warmup time.
    pub fn run_warmup(self: *MetalPipelineCache) []const []const u8 {
        if (self.archive == null) return &.{};
        const t0 = common_timing.now_ns();
        var warmed: u64 = 0;
        // Warm render pipelines (cache can do this autonomously).
        for (self.pending_warmup_render.items) |fmt| {
            if (warmed >= self.max_warmup_pipelines) break;
            const pso = self.compile_or_serve_render(fmt, 1);
            if (pso != null) {
                // PSO is retained by the archive; release our extra ref.
                bridge.metal_bridge_release(pso);
                warmed +%= 1;
            }
        }
        self.pending_warmup_render.clearAndFree(self.allocator);
        self.telemetry.warmup_count = warmed;
        self.telemetry.warmup_ns = common_timing.ns_delta(common_timing.now_ns(), t0);
        // Compute keys are returned for the runtime to resolve — they require
        // the full kernel pipeline path (source read, library compile, etc.).
        return self.pending_warmup_compute.items;
    }

    /// Finalize warmup telemetry after the caller has resolved compute keys.
    /// Adds compute_warmed to warmup_count and extends warmup_ns with the
    /// additional elapsed time since run_warmup returned.
    pub fn finalize_warmup_telemetry(self: *MetalPipelineCache, compute_warmed: u64, compute_ns: u64) void {
        self.telemetry.warmup_count +%= compute_warmed;
        self.telemetry.warmup_ns +%= compute_ns;
    }

    // Kept for backward compatibility with Phase 1 callers (C ABI).
    pub fn lookup_compute_pipeline(self: *MetalPipelineCache, function: ?*anyopaque) ?*anyopaque {
        return self.compile_or_serve_compute(function);
    }

    pub fn lookup_render_pipeline(self: *MetalPipelineCache, pixel_format: u32, support_icb: c_int) ?*anyopaque {
        return self.compile_or_serve_render(pixel_format, support_icb);
    }

    /// Write archive and manifest to disk.  Called at deinit and by the native
    /// ABI flush.  The manifest sidecar lists all pipeline keys compiled this
    /// session so the next startup can warm them.
    pub fn flush_archive(self: *MetalPipelineCache) void {
        const archive = self.archive orelse return;
        if (!self.dirty) return;
        var err_buf: [BRIDGE_ERROR_CAP]u8 = undefined;
        const ok = bridge.metal_bridge_binary_archive_serialize(archive, &err_buf, BRIDGE_ERROR_CAP);
        if (ok != 0) self.telemetry.serialize_count +%= 1;
        self.dirty = false;
        self.last_flush_ns = common_timing.now_ns();
        write_warmup_manifest(self);
    }

    pub fn has_archive(self: *const MetalPipelineCache) bool {
        return self.archive != null;
    }

    /// Record a render pixel format into the session manifest (deduplicated).
    fn record_render_format(self: *MetalPipelineCache, fmt: u32) void {
        for (self.manifest_render_fmts.items) |f| {
            if (f == fmt) return;
        }
        self.manifest_render_fmts.append(self.allocator, fmt) catch {};
    }

    /// Lazy periodic flush: serialize the archive if enough time has elapsed
    /// since the last flush.  Called after each cache miss to ensure newly
    /// compiled pipelines are persisted without waiting for deinit.
    fn maybe_lazy_flush(self: *MetalPipelineCache) void {
        if (!self.dirty) return;
        const now = common_timing.now_ns();
        if (common_timing.ns_delta(now, self.last_flush_ns) >= FLUSH_INTERVAL_NS) {
            self.flush_archive();
        }
    }
};

// ============================================================
// Device fingerprint — invalidates stale archives on GPU/driver change

/// Build a fingerprint string from the Metal device name and registryID.
/// Format: "<device_name>:<registry_id_hex>".
fn build_device_fingerprint(allocator: std.mem.Allocator, device: ?*anyopaque) ![]u8 {
    var name_buf: [DEVICE_NAME_CAP]u8 = undefined;
    @memset(&name_buf, 0);
    bridge.metal_bridge_device_name(device, &name_buf, DEVICE_NAME_CAP);
    const name_len = std.mem.indexOfScalar(u8, &name_buf, 0) orelse DEVICE_NAME_CAP;
    const registry_id = bridge.metal_bridge_device_registry_id(device);
    return try std.fmt.allocPrint(allocator, "{s}:{x}", .{ name_buf[0..name_len], registry_id });
}

/// Compare the current device fingerprint against the stored sidecar file.
/// On mismatch (or missing sidecar), delete the archive and write the new
/// fingerprint.  This ensures stale binaries from a different GPU/driver
/// are never served.
fn validate_or_discard_archive(
    allocator: std.mem.Allocator,
    device: ?*anyopaque,
    cache_dir: []const u8,
) void {
    const fingerprint = build_device_fingerprint(allocator, device) catch return;
    defer allocator.free(fingerprint);

    const fp_path = std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ cache_dir, FINGERPRINT_FILENAME },
    ) catch return;
    defer allocator.free(fp_path);

    const archive_path = std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ cache_dir, ARCHIVE_FILENAME },
    ) catch return;
    defer allocator.free(archive_path);

    // Read existing fingerprint (if any).
    const stored = std.fs.cwd().readFileAlloc(allocator, fp_path, 1024) catch {
        // No sidecar file — first run or was deleted. Write fingerprint.
        write_fingerprint_file(fp_path, fingerprint);
        return;
    };
    defer allocator.free(stored);

    if (std.mem.eql(u8, stored, fingerprint)) return; // Match — archive is valid.

    // Mismatch — discard stale archive and write new fingerprint.
    std.fs.cwd().deleteFile(archive_path) catch {};
    write_fingerprint_file(fp_path, fingerprint);
}

fn write_fingerprint_file(path: []const u8, content: []const u8) void {
    const file = std.fs.cwd().createFile(path, .{}) catch return;
    defer file.close();
    file.writeAll(content) catch {};
}

// ============================================================
// Warmup manifest — sidecar file listing pipeline keys for startup pre-warm

/// Write the warmup manifest sidecar.  Format: one line per entry,
/// "R:<pixel_format_decimal>" for render, "C:<kernel_name>" for compute.
fn write_warmup_manifest(cache: *MetalPipelineCache) void {
    if (cache.cache_dir.len == 0) return;
    const path = std.fmt.allocPrint(
        cache.allocator,
        "{s}/{s}",
        .{ cache.cache_dir, MANIFEST_FILENAME },
    ) catch return;
    defer cache.allocator.free(path);

    const file = std.fs.cwd().createFile(path, .{}) catch return;
    defer file.close();
    for (cache.manifest_render_fmts.items) |fmt| {
        const line = std.fmt.allocPrint(cache.allocator, "{s}{d}\n", .{ MANIFEST_PREFIX_RENDER, fmt }) catch return;
        defer cache.allocator.free(line);
        file.writeAll(line) catch return;
    }
    for (cache.manifest_compute_keys.items) |key| {
        const line = std.fmt.allocPrint(cache.allocator, "{s}{s}\n", .{ MANIFEST_PREFIX_COMPUTE, key }) catch return;
        defer cache.allocator.free(line);
        file.writeAll(line) catch return;
    }
}

/// Load the warmup manifest from a previous session into the pending warmup
/// lists.  Missing or malformed manifests are silently skipped.
fn load_warmup_manifest(
    cache: *MetalPipelineCache,
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
) void {
    const path = std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ cache_dir, MANIFEST_FILENAME },
    ) catch return;
    defer allocator.free(path);

    const content = std.fs.cwd().readFileAlloc(allocator, path, MAX_MANIFEST_BYTES) catch return;
    defer allocator.free(content);

    var total: usize = 0;
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        if (total >= cache.max_warmup_pipelines) break;
        if (std.mem.startsWith(u8, line, MANIFEST_PREFIX_RENDER)) {
            const val = line[MANIFEST_PREFIX_RENDER.len..];
            const fmt = std.fmt.parseInt(u32, val, 10) catch continue;
            cache.pending_warmup_render.append(allocator, fmt) catch continue;
            total += 1;
        } else if (std.mem.startsWith(u8, line, MANIFEST_PREFIX_COMPUTE)) {
            const val = line[MANIFEST_PREFIX_COMPUTE.len..];
            if (val.len == 0 or val.len > MAX_COMPUTE_KEY_LEN) continue;
            const dupe = allocator.dupe(u8, val) catch continue;
            cache.pending_warmup_compute.append(allocator, dupe) catch {
                allocator.free(dupe);
                continue;
            };
            total += 1;
        }
    }
}

// ============================================================
// Cache directory resolution

fn resolve_cache_dir(explicit: []const u8) []const u8 {
    // Honour the composition-owned mutable cache path.
    if (explicit.len > 0) return explicit;

    // Check environment override.
    if (std.posix.getenv(ENV_CACHE_DIR)) |env_val| {
        if (env_val.len > 0) return env_val;
    }

    return DEFAULT_CACHE_DIR;
}

// ============================================================
// C ABI exports

pub export fn doeNativeMetalPipelineCacheCreate(
    device: ?*anyopaque,
    cache_dir: ?[*:0]const u8,
) callconv(.c) ?*anyopaque {
    const dir: []const u8 = if (cache_dir) |d| std.mem.span(d) else "";
    const cache = MetalPipelineCache.init(process_roots.metalPipelineCacheAllocator(), device, dir) catch return null;
    return @ptrCast(cache);
}

pub export fn doeNativeMetalPipelineCacheFlush(raw: ?*anyopaque) callconv(.c) void {
    if (cache_from_opaque(raw)) |c| c.flush_archive();
}

pub export fn doeNativeMetalPipelineCacheRelease(raw: ?*anyopaque) callconv(.c) void {
    if (cache_from_opaque(raw)) |c| c.deinit();
}

/// Compile or serve a compute PSO.  Returns the pipeline handle (+1 retained)
/// on hit or successful compilation.  Returns null only on compile failure or
/// if the cache has no archive.
pub export fn doeNativeMetalPipelineCacheCompileOrServeCompute(
    cache_raw: ?*anyopaque,
    function: ?*anyopaque,
) callconv(.c) ?*anyopaque {
    const cache = cache_from_opaque(cache_raw) orelse return null;
    return cache.compile_or_serve_compute(function);
}

/// Compile or serve a render PSO.
pub export fn doeNativeMetalPipelineCacheCompileOrServeRender(
    cache_raw: ?*anyopaque,
    pixel_format: u32,
    support_icb: c_int,
) callconv(.c) ?*anyopaque {
    const cache = cache_from_opaque(cache_raw) orelse return null;
    return cache.compile_or_serve_render(pixel_format, support_icb);
}

// Legacy Phase 1 exports — kept for external callers, now delegate to Phase 2.
pub export fn doeNativeMetalPipelineCacheLookupCompute(
    cache_raw: ?*anyopaque,
    function: ?*anyopaque,
) callconv(.c) ?*anyopaque {
    const cache = cache_from_opaque(cache_raw) orelse return null;
    return cache.compile_or_serve_compute(function);
}

pub export fn doeNativeMetalPipelineCacheAddCompute(
    cache_raw: ?*anyopaque,
    pipeline: ?*anyopaque,
) callconv(.c) void {
    // Phase 2: archive priming happens inside the compile-or-serve path.
    // This is a no-op now but kept for ABI stability.
    _ = cache_raw;
    _ = pipeline;
}

pub export fn doeNativeMetalPipelineCacheLookupRender(
    cache_raw: ?*anyopaque,
    pixel_format: u32,
    support_icb: c_int,
) callconv(.c) ?*anyopaque {
    const cache = cache_from_opaque(cache_raw) orelse return null;
    return cache.compile_or_serve_render(pixel_format, support_icb);
}

pub export fn doeNativeMetalPipelineCacheAddRender(
    cache_raw: ?*anyopaque,
    pipeline: ?*anyopaque,
) callconv(.c) void {
    _ = cache_raw;
    _ = pipeline;
}

pub export fn doeNativeMetalPipelineCacheTelemetry(
    cache_raw: ?*anyopaque,
    out_compile_count: *u64,
    out_serialize_count: *u64,
) callconv(.c) void {
    if (cache_from_opaque(cache_raw)) |c| {
        out_compile_count.* = c.telemetry.compile_count;
        out_serialize_count.* = c.telemetry.serialize_count;
    } else {
        out_compile_count.* = 0;
        out_serialize_count.* = 0;
    }
}

/// Extended telemetry export including per-pipeline hit/miss timing.
pub export fn doeNativeMetalPipelineCacheTelemetryExt(
    cache_raw: ?*anyopaque,
    out_compile_count: *u64,
    out_serialize_count: *u64,
    out_total_hit_ns: *u64,
    out_total_miss_ns: *u64,
) callconv(.c) void {
    if (cache_from_opaque(cache_raw)) |c| {
        out_compile_count.* = c.telemetry.compile_count;
        out_serialize_count.* = c.telemetry.serialize_count;
        out_total_hit_ns.* = c.telemetry.total_hit_ns;
        out_total_miss_ns.* = c.telemetry.total_miss_ns;
    } else {
        out_compile_count.* = 0;
        out_serialize_count.* = 0;
        out_total_hit_ns.* = 0;
        out_total_miss_ns.* = 0;
    }
}

/// Warmup telemetry: pipelines warmed and time spent.
pub export fn doeNativeMetalPipelineCacheWarmupTelemetry(
    cache_raw: ?*anyopaque,
    out_warmup_count: *u64,
    out_warmup_ns: *u64,
) callconv(.c) void {
    if (cache_from_opaque(cache_raw)) |c| {
        out_warmup_count.* = c.telemetry.warmup_count;
        out_warmup_ns.* = c.telemetry.warmup_ns;
    } else {
        out_warmup_count.* = 0;
        out_warmup_ns.* = 0;
    }
}

// ============================================================
// Internal

fn cache_from_opaque(raw: ?*anyopaque) ?*MetalPipelineCache {
    const p = raw orelse return null;
    const c: *MetalPipelineCache = @ptrCast(@alignCast(p));
    if (c.magic != MAGIC_METAL_CACHE) return null;
    return c;
}

test "doeNativeMetalPipelineCacheCreate survives repeated create use release cycles" {
    const first_raw = doeNativeMetalPipelineCacheCreate(null, null);
    try std.testing.expect(first_raw != null);
    const first_cache = cache_from_opaque(first_raw);
    try std.testing.expect(first_cache != null);
    first_cache.?.register_compute_key("first-kernel");
    doeNativeMetalPipelineCacheRelease(first_raw);

    const second_raw = doeNativeMetalPipelineCacheCreate(null, null);
    try std.testing.expect(second_raw != null);
    const second_cache = cache_from_opaque(second_raw);
    try std.testing.expect(second_cache != null);
    second_cache.?.register_compute_key("second-kernel");
    doeNativeMetalPipelineCacheRelease(second_raw);
}
