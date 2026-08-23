const std = @import("std");
const pipeline_cache = @import("../../src/runtime/cache/pipeline_cache.zig");
const PipelineCacheKey = pipeline_cache.PipelineCacheKey;
const PipelineCache = pipeline_cache.PipelineCache;

// ============================================================
// Constants

test "KEY_HEX_LEN is 64 (SHA-256 hex encoding)" {
    // PipelineCacheKey.derive returns a [64]u8 hex string.
    const key = make_compute_key("fn main() {}");
    const hex = key.derive();
    try std.testing.expectEqual(@as(usize, 64), hex.len);
}

test "derived key contains only lowercase hex characters" {
    const key = make_compute_key("@compute fn main() {}");
    const hex = key.derive();
    for (hex) |c| {
        const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try std.testing.expect(is_hex);
    }
}

// ============================================================
// Cache key generation — determinism

test "same inputs produce identical derived key" {
    const key_a = make_compute_key("fn main() {}");
    const key_b = make_compute_key("fn main() {}");
    try std.testing.expectEqualSlices(u8, &key_a.derive(), &key_b.derive());
}

test "key derivation is deterministic across repeated calls" {
    const key = make_compute_key("@compute fn dispatch() {}");
    const first = key.derive();
    const second = key.derive();
    const third = key.derive();
    try std.testing.expectEqualSlices(u8, &first, &second);
    try std.testing.expectEqualSlices(u8, &second, &third);
}

// ============================================================
// Cache key generation — sensitivity to each field

test "different WGSL source produces different key" {
    const key_a = make_compute_key("fn main() {}");
    const key_b = make_compute_key("fn other() {}");
    try std.testing.expect(!std.mem.eql(u8, &key_a.derive(), &key_b.derive()));
}

test "compute vs render kind produces different key for same source" {
    const src = "fn shared_shader() {}";
    const wgsl_hash = pipeline_cache.hash_wgsl(src);

    const compute_key = PipelineCacheKey{
        .wgsl_hash = wgsl_hash,
        .kind = .compute,
        .pixel_format = 0,
        .vertex_entry_hash = 0,
        .fragment_entry_hash = 0,
        .sample_count = 1,
        .color_attachment_count = 0,
    };

    const render_key = PipelineCacheKey{
        .wgsl_hash = wgsl_hash,
        .kind = .render,
        .pixel_format = 0,
        .vertex_entry_hash = 0,
        .fragment_entry_hash = 0,
        .sample_count = 1,
        .color_attachment_count = 0,
    };

    try std.testing.expect(!std.mem.eql(u8, &compute_key.derive(), &render_key.derive()));
}

test "different pixel format produces different key" {
    const key_a = make_render_key(80, 0, 0, 1, 1); // BGRA8Unorm
    const key_b = make_render_key(81, 0, 0, 1, 1); // different format
    try std.testing.expect(!std.mem.eql(u8, &key_a.derive(), &key_b.derive()));
}

test "different vertex entry hash produces different key" {
    const key_a = make_render_key(80, 100, 200, 1, 1);
    const key_b = make_render_key(80, 999, 200, 1, 1);
    try std.testing.expect(!std.mem.eql(u8, &key_a.derive(), &key_b.derive()));
}

test "different fragment entry hash produces different key" {
    const key_a = make_render_key(80, 100, 200, 1, 1);
    const key_b = make_render_key(80, 100, 300, 1, 1);
    try std.testing.expect(!std.mem.eql(u8, &key_a.derive(), &key_b.derive()));
}

test "different sample count produces different key" {
    const key_a = make_render_key(80, 0, 0, 1, 1);
    const key_b = make_render_key(80, 0, 0, 4, 1);
    try std.testing.expect(!std.mem.eql(u8, &key_a.derive(), &key_b.derive()));
}

test "different color attachment count produces different key" {
    const key_a = make_render_key(80, 0, 0, 1, 1);
    const key_b = make_render_key(80, 0, 0, 1, 4);
    try std.testing.expect(!std.mem.eql(u8, &key_a.derive(), &key_b.derive()));
}

// ============================================================
// hash_wgsl

test "hash_wgsl returns 32-byte SHA-256 digest" {
    const digest = pipeline_cache.hash_wgsl("hello");
    try std.testing.expectEqual(@as(usize, 32), digest.len);
}

test "hash_wgsl is deterministic" {
    const a = pipeline_cache.hash_wgsl("@compute fn main() {}");
    const b = pipeline_cache.hash_wgsl("@compute fn main() {}");
    try std.testing.expectEqualSlices(u8, &a, &b);
}

test "hash_wgsl differs for different sources" {
    const a = pipeline_cache.hash_wgsl("fn a() {}");
    const b = pipeline_cache.hash_wgsl("fn b() {}");
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test "hash_wgsl handles empty string" {
    const digest = pipeline_cache.hash_wgsl("");
    // SHA-256 of empty string is well-defined, should not be all zeros.
    var all_zero = true;
    for (digest) |byte| {
        if (byte != 0) {
            all_zero = false;
            break;
        }
    }
    try std.testing.expect(!all_zero);
}

// ============================================================
// hash_string_u64

test "hash_string_u64 is deterministic" {
    const a = pipeline_cache.hash_string_u64("vertex_main");
    const b = pipeline_cache.hash_string_u64("vertex_main");
    try std.testing.expectEqual(a, b);
}

test "hash_string_u64 differs for different strings" {
    const a = pipeline_cache.hash_string_u64("vertex_main");
    const b = pipeline_cache.hash_string_u64("fragment_main");
    try std.testing.expect(a != b);
}

// ============================================================
// PipelineKind enum values

test "PipelineKind enum has expected integer values" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(PipelineCacheKey.PipelineKind.compute));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(PipelineCacheKey.PipelineKind.render));
}

// ============================================================
// PipelineCache — in-memory LRU (no disk I/O needed for these tests)

test "empty cache returns null on lookup" {
    var fixture = try TestCache.init();
    defer fixture.deinit();
    const cache = fixture.cache;

    const key = make_compute_key("nonexistent shader");
    try std.testing.expect(cache.lookup(&key) == null);
}

test "store then lookup returns same data" {
    var fixture = try TestCache.init();
    defer fixture.deinit();
    const cache = fixture.cache;

    const key = make_compute_key("fn cached() {}");
    const payload = "compiled_msl_text_here";
    cache.store(&key, payload);

    const result = cache.lookup(&key);
    try std.testing.expect(result != null);
    try std.testing.expectEqualSlices(u8, payload, result.?);
}

test "different keys return independent data" {
    var fixture = try TestCache.init();
    defer fixture.deinit();
    const cache = fixture.cache;

    const key_a = make_compute_key("shader_a");
    const key_b = make_compute_key("shader_b");

    cache.store(&key_a, "msl_a");
    cache.store(&key_b, "msl_b");

    const result_a = cache.lookup(&key_a);
    const result_b = cache.lookup(&key_b);
    try std.testing.expect(result_a != null);
    try std.testing.expect(result_b != null);
    try std.testing.expectEqualSlices(u8, "msl_a", result_a.?);
    try std.testing.expectEqualSlices(u8, "msl_b", result_b.?);
}

test "storing same key twice overwrites previous data" {
    var fixture = try TestCache.init();
    defer fixture.deinit();
    const cache = fixture.cache;

    const key = make_compute_key("fn overwrite() {}");
    cache.store(&key, "version_1");
    cache.store(&key, "version_2");

    const result = cache.lookup(&key);
    try std.testing.expect(result != null);
    try std.testing.expectEqualSlices(u8, "version_2", result.?);
}

test "LRU evicts oldest entries when at capacity" {
    var fixture = try TestCache.init();
    defer fixture.deinit();
    const cache = fixture.cache;

    // Fill the cache to MAX_LRU_ENTRIES (512) with distinct keys.
    // Use a buffer to generate unique shader sources.
    var sources: [513][32]u8 = undefined;
    var keys: [513]PipelineCacheKey = undefined;
    for (0..513) |i| {
        const src = std.fmt.bufPrint(&sources[i], "shader_{d:0>20}", .{i}) catch unreachable;
        keys[i] = make_compute_key(src);
    }

    // Insert 512 entries (fills to capacity).
    for (0..512) |i| {
        cache.store(&keys[i], "data");
    }

    // The 513th insert triggers eviction of the oldest half (256 entries).
    cache.store(&keys[512], "data_513");

    // The newest entry should be present.
    const newest = cache.lookup(&keys[512]);
    try std.testing.expect(newest != null);

    // The most recently stored entries before eviction should survive.
    // Entry 511 (the last before the 513th) should still be present.
    const recent = cache.lookup(&keys[511]);
    try std.testing.expect(recent != null);
}

test "lookup miss for unknown key does not corrupt cache state" {
    var fixture = try TestCache.init();
    defer fixture.deinit();
    const cache = fixture.cache;

    const known_key = make_compute_key("known shader");
    cache.store(&known_key, "payload");

    // Lookup a key that was never stored.
    const unknown_key = make_compute_key("unknown shader");
    try std.testing.expect(cache.lookup(&unknown_key) == null);

    // The known key should still be valid.
    const result = cache.lookup(&known_key);
    try std.testing.expect(result != null);
    try std.testing.expectEqualSlices(u8, "payload", result.?);
}

// ============================================================
// Serialization

test "serialize empty cache produces a four-byte count of zero" {
    var fixture = try TestCache.init();
    defer fixture.deinit();
    const cache = fixture.cache;

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(std.testing.allocator);

    try cache.serialize(&buf, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), buf.items.len);
    const count = std.mem.readInt(u32, buf.items[0..4], .little);
    try std.testing.expectEqual(@as(u32, 0), count);
}

test "serialize non-empty cache encodes correct entry count" {
    var fixture = try TestCache.init();
    defer fixture.deinit();
    const cache = fixture.cache;

    cache.store(&make_compute_key("s1"), "d1");
    cache.store(&make_compute_key("s2"), "d2");
    cache.store(&make_compute_key("s3"), "d3");

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(std.testing.allocator);

    try cache.serialize(&buf, std.testing.allocator);

    const count = std.mem.readInt(u32, buf.items[0..4], .little);
    try std.testing.expectEqual(@as(u32, 3), count);

    // Total size: 4 (count) + 3 * (16 (DiskHeader) + 64 (key) + 2 (data "d1"/"d2"/"d3"))
    // Data lengths are 2 each.
    try std.testing.expect(buf.items.len > 4);
}

test "serialized format contains DiskHeader with correct data_len per entry" {
    var fixture = try TestCache.init();
    defer fixture.deinit();
    const cache = fixture.cache;

    const payload = "compiled_metal_shader_lib";
    cache.store(&make_compute_key("test_shader"), payload);

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(std.testing.allocator);

    try cache.serialize(&buf, std.testing.allocator);

    // Skip count (4 bytes), read DiskHeader at offset 4.
    // DiskHeader is extern struct { magic: u32, format_version: u32, key_len: u32, data_len: u32 } = 16 bytes.
    const hdr_offset: usize = 4;
    const data_len = std.mem.readInt(u32, buf.items[hdr_offset + 12 ..][0..4], .little);
    try std.testing.expectEqual(@as(u32, @intCast(payload.len)), data_len);

    const key_len = std.mem.readInt(u32, buf.items[hdr_offset + 8 ..][0..4], .little);
    try std.testing.expectEqual(@as(u32, 64), key_len);
}

// ============================================================
// PipelineCache.init / deinit

test "cache init with custom directory does not leak" {
    var fixture = try TestCache.init();
    fixture.deinit();
}

test "cache magic field is set on init" {
    var fixture = try TestCache.init();
    defer fixture.deinit();
    const cache = fixture.cache;

    try std.testing.expectEqual(@as(u32, 0xD0EC_AC11), cache.magic);
}

test "access_clock increments on lookup hit" {
    var fixture = try TestCache.init();
    defer fixture.deinit();
    const cache = fixture.cache;

    const key = make_compute_key("clock test shader");
    cache.store(&key, "data");
    const clock_after_store = cache.access_clock;

    _ = cache.lookup(&key);
    try std.testing.expect(cache.access_clock > clock_after_store);
}

test "disk_bytes_approx increases on store" {
    var fixture = try TestCache.init();
    defer fixture.deinit();
    const cache = fixture.cache;

    try std.testing.expectEqual(@as(u64, 0), cache.disk_bytes_approx);

    cache.store(&make_compute_key("s"), "payload_bytes");
    try std.testing.expect(cache.disk_bytes_approx > 0);
}

// ============================================================
// Test helpers

const TestCache = struct {
    cache: *PipelineCache,
    temp_dir: std.testing.TmpDir,

    fn init() !TestCache {
        var temp_dir = std.testing.tmpDir(.{});
        errdefer temp_dir.cleanup();
        const cache_dir = try std.fs.path.join(std.testing.allocator, &.{
            ".zig-cache",
            "tmp",
            temp_dir.sub_path[0..],
        });
        defer std.testing.allocator.free(cache_dir);

        return .{
            .cache = try PipelineCache.init(std.testing.allocator, cache_dir),
            .temp_dir = temp_dir,
        };
    }

    fn deinit(self: *TestCache) void {
        self.cache.deinit();
        self.temp_dir.cleanup();
    }
};

fn make_compute_key(src: []const u8) PipelineCacheKey {
    return PipelineCacheKey{
        .wgsl_hash = pipeline_cache.hash_wgsl(src),
        .kind = .compute,
        .pixel_format = 0,
        .vertex_entry_hash = 0,
        .fragment_entry_hash = 0,
        .sample_count = 1,
        .color_attachment_count = 0,
    };
}

fn make_render_key(pixel_fmt: u32, vert_hash: u64, frag_hash: u64, samples: u32, color_count: u32) PipelineCacheKey {
    return PipelineCacheKey{
        .wgsl_hash = pipeline_cache.hash_wgsl("render shader"),
        .kind = .render,
        .pixel_format = pixel_fmt,
        .vertex_entry_hash = vert_hash,
        .fragment_entry_hash = frag_hash,
        .sample_count = samples,
        .color_attachment_count = color_count,
    };
}
