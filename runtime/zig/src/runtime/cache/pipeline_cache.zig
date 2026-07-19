// pipeline_cache.zig — Persistent pipeline cache: key generation, LRU management, disk I/O.
//
// Cache keys hash WGSL source + pipeline descriptor fields so that recompilation is
// skipped on identical input.  Compiled MSL text and MTLLibrary blobs are stored on
// disk under ~/.cache/fawn/pipeline_cache/ (or the path supplied via
// doeNativeDeviceCreatePipelineCache).  An in-process LRU keeps the hottest entries
// live to avoid repeated deserialization.

const builtin = @import("builtin");
const std = @import("std");

// ============================================================
// Constants

const CACHE_FORMAT_VERSION: u32 = 1;
const DEFAULT_CACHE_DIR_SUFFIX = "fawn/pipeline_cache";
const MAX_CACHE_SIZE_BYTES: u64 = 256 * 1024 * 1024; // 256 MB eviction ceiling
const MAX_LRU_ENTRIES: usize = 512;
const KEY_HEX_LEN: usize = 64; // SHA-256 as 64 hex chars
const MAGIC_PIPELINE_CACHE: u32 = 0xD0EC_AC11;
const DRIVER_VERSION_UNKNOWN: u64 = 0;

// On-disk record header (little-endian).
const DiskHeader = extern struct {
    magic: u32 = 0xFAEC_ACED,
    format_version: u32 = CACHE_FORMAT_VERSION,
    key_len: u32, // bytes in key (hex string, KEY_HEX_LEN)
    data_len: u32, // bytes of payload following header
};

// ============================================================
// Cache key — all fields that distinguish pipeline binaries.

pub const PipelineCacheKey = struct {
    // Stable SHA-256 of WGSL source text.
    wgsl_hash: [32]u8,
    // Pipeline kind tag distinguishes compute vs render so keys cannot collide.
    kind: PipelineKind,
    // Pixel format matters for render pipelines; zero for compute.
    pixel_format: u32,
    // Vertex/fragment entry point hashes (zero for compute).
    vertex_entry_hash: u64,
    fragment_entry_hash: u64,
    // Sample count (1 for non-MSAA).
    sample_count: u32,
    // Color attachment count.
    color_attachment_count: u32,

    pub const PipelineKind = enum(u8) { compute = 0, render = 1 };

    // Derive a stable cache key from the combined fields.
    pub fn derive(self: *const PipelineCacheKey) [KEY_HEX_LEN]u8 {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update(self.wgsl_hash[0..]);
        const kind_byte: u8 = @intFromEnum(self.kind);
        h.update(&[_]u8{kind_byte});
        var tmp: [8]u8 = undefined;
        std.mem.writeInt(u32, tmp[0..4], self.pixel_format, .little);
        h.update(tmp[0..4]);
        std.mem.writeInt(u64, &tmp, self.vertex_entry_hash, .little);
        h.update(&tmp);
        std.mem.writeInt(u64, &tmp, self.fragment_entry_hash, .little);
        h.update(&tmp);
        std.mem.writeInt(u32, tmp[0..4], self.sample_count, .little);
        h.update(tmp[0..4]);
        std.mem.writeInt(u32, tmp[0..4], self.color_attachment_count, .little);
        h.update(tmp[0..4]);
        var digest: [32]u8 = undefined;
        h.final(&digest);
        return bytes_to_hex(&digest);
    }
};

pub fn hash_wgsl(src: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(src, &digest, .{});
    return digest;
}

pub fn hash_string_u64(s: []const u8) u64 {
    return std.hash.Wyhash.hash(0, s);
}

// ============================================================
// LRU entry

const LruEntry = struct {
    key_hex: [KEY_HEX_LEN]u8,
    // Heap-allocated payload (owned).
    data: []u8,
    // Monotonic access counter for eviction ordering.
    last_access: u64,
};

// ============================================================
// Disk cache I/O

fn cache_file_path(
    allocator: std.mem.Allocator,
    dir: []const u8,
    key_hex: [KEY_HEX_LEN]u8,
) ![]u8 {
    // Shard into a two-char subdirectory to keep readdir fast on large caches.
    return std.fmt.allocPrint(allocator, "{s}/{c}{c}/{s}.bin", .{
        dir,
        key_hex[0],
        key_hex[1],
        key_hex[0..],
    });
}

fn write_entry_to_disk(dir: []const u8, key_hex: [KEY_HEX_LEN]u8, data: []const u8, allocator: std.mem.Allocator) void {
    const path = cache_file_path(allocator, dir, key_hex) catch return;
    defer allocator.free(path);

    // Ensure shard directory exists.
    const shard_len = dir.len + 4; // "/<c><c>"
    var shard_buf: [512]u8 = undefined;
    if (shard_len >= shard_buf.len) return;
    const shard_dir = std.fmt.bufPrint(&shard_buf, "{s}/{c}{c}", .{ dir, key_hex[0], key_hex[1] }) catch return;
    std.fs.cwd().makePath(shard_dir) catch return;

    const file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch return;
    defer file.close();

    const hdr = DiskHeader{
        .magic = 0xFAEC_ACED,
        .format_version = CACHE_FORMAT_VERSION,
        .key_len = KEY_HEX_LEN,
        .data_len = @intCast(data.len),
    };
    file.writeAll(std.mem.asBytes(&hdr)) catch return;
    file.writeAll(key_hex[0..]) catch return;
    file.writeAll(data) catch return;
}

fn read_entry_from_disk(dir: []const u8, key_hex: [KEY_HEX_LEN]u8, allocator: std.mem.Allocator) ?[]u8 {
    const path = cache_file_path(allocator, dir, key_hex) catch return null;
    defer allocator.free(path);

    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();

    var hdr: DiskHeader = undefined;
    const hdr_bytes = std.mem.asBytes(&hdr);
    const n = file.read(hdr_bytes) catch return null;
    if (n < hdr_bytes.len) return null;
    if (hdr.magic != 0xFAEC_ACED) return null;
    if (hdr.format_version != CACHE_FORMAT_VERSION) return null;
    if (hdr.key_len != KEY_HEX_LEN) return null;

    // Skip the stored key (already validated by path).
    var stored_key: [KEY_HEX_LEN]u8 = undefined;
    const kn = file.read(&stored_key) catch return null;
    if (kn < KEY_HEX_LEN) return null;
    if (!std.mem.eql(u8, &stored_key, &key_hex)) return null;

    const data = allocator.alloc(u8, hdr.data_len) catch return null;
    const dn = file.read(data) catch {
        allocator.free(data);
        return null;
    };
    if (dn < data.len) {
        allocator.free(data);
        return null;
    }
    return data;
}

// ============================================================
// PipelineCache — main handle

pub const PipelineCache = struct {
    const TYPE_MAGIC = MAGIC_PIPELINE_CACHE;

    magic: u32 = TYPE_MAGIC,
    allocator: std.mem.Allocator,
    // Absolute path to cache directory on disk.
    cache_dir: []u8,
    // In-process LRU.
    lru: std.ArrayListUnmanaged(LruEntry) = .{},
    access_clock: u64 = 0,
    // Approximate on-disk bytes used (updated on writes, not tracked precisely).
    disk_bytes_approx: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, dir_override: ?[]const u8) !*PipelineCache {
        const dir = if (dir_override) |d|
            try allocator.dupe(u8, d)
        else
            try resolve_default_cache_dir(allocator);
        errdefer allocator.free(dir);

        std.fs.cwd().makePath(dir) catch |err| {
            std.debug.print("warn: pipeline_cache: makePath: {s}\n", .{@errorName(err)});
        };

        const cache = try allocator.create(PipelineCache);
        cache.* = .{
            .allocator = allocator,
            .cache_dir = dir,
        };
        return cache;
    }

    pub fn deinit(self: *PipelineCache) void {
        const allocator = self.allocator;
        for (self.lru.items) |*e| allocator.free(e.data);
        self.lru.deinit(allocator);
        allocator.free(self.cache_dir);
        allocator.destroy(self);
    }

    // Look up compiled MSL text (or MTLLibrary blob) by key.
    // Returns a borrowed slice valid until the next mutation; caller must copy if needed.
    pub fn lookup(self: *PipelineCache, key: *const PipelineCacheKey) ?[]const u8 {
        const key_hex = key.derive();

        // Check in-process LRU first.
        if (self.lru_find(&key_hex)) |entry| {
            self.access_clock +%= 1;
            entry.last_access = self.access_clock;
            return entry.data;
        }

        // Fall through to disk.
        const data = read_entry_from_disk(self.cache_dir, key_hex, self.allocator) orelse return null;

        // Promote to LRU.
        self.access_clock +%= 1;
        self.lru_insert(key_hex, data) catch {
            self.allocator.free(data);
            return null;
        };
        if (self.lru_find(&key_hex)) |e| return e.data;
        return null;
    }

    // Store compiled payload for a key.  Triggers async-style deferred write on hot path.
    pub fn store(self: *PipelineCache, key: *const PipelineCacheKey, data: []const u8) void {
        const key_hex = key.derive();

        // Always update / insert in LRU.
        const owned = self.allocator.dupe(u8, data) catch return;
        self.lru_upsert(key_hex, owned);

        // Persist to disk (synchronous; acceptable at pipeline-creation time, not in a render loop).
        write_entry_to_disk(self.cache_dir, key_hex, data, self.allocator);
        self.disk_bytes_approx +|= @as(u64, data.len) + @sizeOf(DiskHeader) + KEY_HEX_LEN;

        // Evict if we have exceeded size limit.
        if (self.disk_bytes_approx > MAX_CACHE_SIZE_BYTES) {
            self.evict_lru_half();
        }
    }

    // Serialise the in-memory LRU to a flat byte sequence for external storage.
    // Format: [u32 count] ([DiskHeader] [key] [data])*.
    pub fn serialize(self: *const PipelineCache, out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
        var count_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &count_buf, @intCast(self.lru.items.len), .little);
        try out.appendSlice(allocator, &count_buf);
        for (self.lru.items) |*e| {
            const hdr = DiskHeader{
                .key_len = KEY_HEX_LEN,
                .data_len = @intCast(e.data.len),
            };
            try out.appendSlice(allocator, std.mem.asBytes(&hdr));
            try out.appendSlice(allocator, e.key_hex[0..]);
            try out.appendSlice(allocator, e.data);
        }
    }

    // -------------------------------------------------------
    // LRU helpers

    fn lru_find(self: *PipelineCache, key_hex: *const [KEY_HEX_LEN]u8) ?*LruEntry {
        for (self.lru.items) |*e| {
            if (std.mem.eql(u8, &e.key_hex, key_hex)) return e;
        }
        return null;
    }

    fn lru_insert(self: *PipelineCache, key_hex: [KEY_HEX_LEN]u8, data: []u8) !void {
        if (self.lru.items.len >= MAX_LRU_ENTRIES) {
            self.evict_lru_half();
        }
        try self.lru.append(self.allocator, .{
            .key_hex = key_hex,
            .data = data,
            .last_access = self.access_clock,
        });
    }

    fn lru_upsert(self: *PipelineCache, key_hex: [KEY_HEX_LEN]u8, data: []u8) void {
        self.access_clock +%= 1;
        if (self.lru_find(&key_hex)) |entry| {
            self.allocator.free(entry.data);
            entry.data = data;
            entry.last_access = self.access_clock;
            return;
        }
        self.lru_insert(key_hex, data) catch {
            // If insertion fails, data is already owned — free it to avoid leak.
            self.allocator.free(data);
        };
    }

    fn evict_lru_half(self: *PipelineCache) void {
        // Sort ascending by last_access so oldest entries are first.
        std.sort.heap(LruEntry, self.lru.items, {}, compare_lru_access);
        const evict_count = self.lru.items.len / 2;
        for (self.lru.items[0..evict_count]) |*e| self.allocator.free(e.data);
        std.mem.copyForwards(
            LruEntry,
            self.lru.items[0 .. self.lru.items.len - evict_count],
            self.lru.items[evict_count..],
        );
        self.lru.shrinkRetainingCapacity(self.lru.items.len - evict_count);
        // Reset approximate disk bytes after eviction (conservative undercount is fine).
        self.disk_bytes_approx = self.disk_bytes_approx / 2;
    }
};

fn compare_lru_access(_: void, a: LruEntry, b: LruEntry) bool {
    return a.last_access < b.last_access;
}

// ============================================================
// C ABI exports

const MAGIC_CACHE_DESC: u32 = 0xD0EC_DE5C;

// Opaque descriptor passed to doeNativeDeviceCreatePipelineCache.
const DoePipelineCacheDescriptor = struct {
    magic: u32 = MAGIC_CACHE_DESC,
    // NUL-terminated path; null means use default.
    path: ?[*:0]const u8 = null,
};

var global_gpa = std.heap.GeneralPurposeAllocator(.{}){};
const alloc = global_gpa.allocator();

pub export fn doeNativeDeviceCreatePipelineCacheDescriptor(path: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    const desc = alloc.create(DoePipelineCacheDescriptor) catch return null;
    desc.* = .{ .path = path };
    return @ptrCast(desc);
}

pub export fn doeNativePipelineCacheDescriptorRelease(raw: ?*anyopaque) callconv(.c) void {
    if (raw == null) return;
    const desc: *DoePipelineCacheDescriptor = @ptrCast(@alignCast(raw));
    if (desc.magic != MAGIC_CACHE_DESC) return;
    alloc.destroy(desc);
}

pub export fn doeNativeDeviceCreatePipelineCache(desc_raw: ?*anyopaque) callconv(.c) ?*anyopaque {
    var dir_override: ?[]const u8 = null;
    if (desc_raw) |d| {
        const desc: *const DoePipelineCacheDescriptor = @ptrCast(@alignCast(d));
        if (desc.magic == MAGIC_CACHE_DESC) {
            if (desc.path) |p| dir_override = std.mem.span(p);
        }
    }
    const cache = PipelineCache.init(alloc, dir_override) catch return null;
    return @ptrCast(cache);
}

pub export fn doeNativePipelineCacheGetData(
    raw: ?*anyopaque,
    out_ptr: *?[*]u8,
    out_len: *usize,
) callconv(.c) u32 {
    const cache = cache_from_opaque(raw) orelse {
        out_ptr.* = null;
        out_len.* = 0;
        return 0;
    };
    var buf: std.ArrayListUnmanaged(u8) = .{};
    cache.serialize(&buf, alloc) catch {
        buf.deinit(alloc);
        out_ptr.* = null;
        out_len.* = 0;
        return 0;
    };
    out_ptr.* = buf.items.ptr;
    out_len.* = buf.items.len;
    return 1;
}

pub export fn doeNativePipelineCacheDataFree(ptr: ?[*]u8, len: usize) callconv(.c) void {
    if (ptr) |p| alloc.free(p[0..len]);
}

pub export fn doeNativePipelineCacheRelease(raw: ?*anyopaque) callconv(.c) void {
    if (cache_from_opaque(raw)) |c| c.deinit();
}

// ============================================================
// Internal helpers

fn cache_from_opaque(raw: ?*anyopaque) ?*PipelineCache {
    const p = raw orelse return null;
    const c: *PipelineCache = @ptrCast(@alignCast(p));
    if (c.magic != MAGIC_PIPELINE_CACHE) return null;
    return c;
}

fn resolve_default_cache_dir(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .macos or builtin.os.tag == .linux) {
        if (std.posix.getenv("HOME")) |home| {
            return std.fmt.allocPrint(allocator, "{s}/.cache/{s}", .{ home, DEFAULT_CACHE_DIR_SUFFIX });
        }
    }
    // Fallback: current-directory relative cache.
    return allocator.dupe(u8, "cache/" ++ DEFAULT_CACHE_DIR_SUFFIX);
}

fn bytes_to_hex(input: *const [32]u8) [KEY_HEX_LEN]u8 {
    const HEX = "0123456789abcdef";
    var out: [KEY_HEX_LEN]u8 = undefined;
    for (input, 0..) |byte, i| {
        out[i * 2] = HEX[(byte >> 4) & 0x0F];
        out[i * 2 + 1] = HEX[byte & 0x0F];
    }
    return out;
}
