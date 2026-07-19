const builtin = @import("builtin");
const std = @import("std");

const DEFAULT_CACHE_DIR_SUFFIX = "doe/bench_synthetic_assets";
const ENV_CACHE_DIR = "DOE_BENCH_ASSET_CACHE_DIR";

pub fn resolveCacheRoot(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .macos or builtin.os.tag == .linux) {
        if (std.posix.getenv(ENV_CACHE_DIR)) |env_value| {
            return allocator.dupe(u8, env_value);
        }
        if (std.posix.getenv("HOME")) |home| {
            return std.fmt.allocPrint(allocator, "{s}/.cache/{s}", .{ home, DEFAULT_CACHE_DIR_SUFFIX });
        }
    }
    return allocator.dupe(u8, "cache/" ++ DEFAULT_CACHE_DIR_SUFFIX);
}

pub fn resolveAssetPath(
    allocator: std.mem.Allocator,
    cache_namespace: []const u8,
    cache_key: []const u8,
) ![]u8 {
    if (cache_namespace.len == 0 or cache_key.len == 0) return error.InvalidAssetPath;
    const cache_root = try resolveCacheRoot(allocator);
    defer allocator.free(cache_root);
    return std.fmt.allocPrint(allocator, "{s}/{s}/{s}.bin", .{ cache_root, cache_namespace, cache_key });
}

pub fn readAssetBytes(
    allocator: std.mem.Allocator,
    cache_namespace: []const u8,
    cache_key: []const u8,
    expected_len: u64,
) ![]u8 {
    const path = try resolveAssetPath(allocator, cache_namespace, cache_key);
    defer allocator.free(path);
    const max_len = std.math.cast(usize, expected_len) orelse return error.InvalidAssetLength;
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, max_len);
    errdefer allocator.free(bytes);
    if (bytes.len != max_len) return error.InvalidAssetLength;
    return bytes;
}

pub fn readAssetWords(
    allocator: std.mem.Allocator,
    cache_namespace: []const u8,
    cache_key: []const u8,
    expected_len: u64,
) ![]u32 {
    if (expected_len == 0 or expected_len % 4 != 0) return error.InvalidAssetLength;
    const bytes = try readAssetBytes(allocator, cache_namespace, cache_key, expected_len);
    defer allocator.free(bytes);
    const word_count = bytes.len / @sizeOf(u32);
    const words = try allocator.alloc(u32, word_count);
    for (words, 0..) |*word, idx| {
        const byte_index = idx * @sizeOf(u32);
        word.* = std.mem.readInt(u32, bytes[byte_index..][0..@sizeOf(u32)], .little);
    }
    return words;
}
