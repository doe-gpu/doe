const std = @import("std");
const spirv_translation = @import("../../compiler/wgsl/pipeline/translate_spirv.zig");
const path_utils = @import("../common/path_utils.zig");

const MAX_KERNEL_SOURCE_BYTES: usize = 2 * 1024 * 1024;
const SPIRV_MAGIC: u32 = 0x07230203;
const DEFAULT_KERNEL_ROOT = "bench/kernels";

pub fn load_kernel_source(self: anytype, allocator: std.mem.Allocator, kernel_name: []const u8) ![]u8 {
    if (kernel_name.len == 0) return error.InvalidArgument;
    const path = try resolve_kernel_path(self, allocator, kernel_name);
    defer allocator.free(path);
    return std.fs.cwd().readFileAlloc(allocator, path, MAX_KERNEL_SOURCE_BYTES) catch error.ShaderCompileFailed;
}

pub fn load_kernel_spirv(self: anytype, allocator: std.mem.Allocator, kernel_name: []const u8) ![]u32 {
    return try load_kernel_spirv_uncached(self, allocator, kernel_name);
}

pub fn ensure_kernel_spirv_cached(self: anytype, kernel_name: []const u8) ![]const u32 {
    if (kernel_name.len == 0) return error.InvalidArgument;
    if (self.kernel_spirv_cache.get(kernel_name)) |cached| return cached;
    const words = try load_kernel_spirv_uncached(self, self.allocator, kernel_name);
    const owned_kernel_name = try self.allocator.dupe(u8, kernel_name);
    errdefer self.allocator.free(owned_kernel_name);
    try self.kernel_spirv_cache.put(self.allocator, owned_kernel_name, words);
    return words;
}

pub fn release_kernel_spirv_cache(self: anytype) void {
    var it = self.kernel_spirv_cache.iterator();
    while (it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        self.allocator.free(entry.value_ptr.*);
    }
    self.kernel_spirv_cache.deinit(self.allocator);
}

fn load_kernel_spirv_uncached(self: anytype, allocator: std.mem.Allocator, kernel_name: []const u8) ![]u32 {
    if (kernel_name.len == 0) return error.InvalidArgument;
    const path = resolve_kernel_spirv_path(self, allocator, kernel_name) catch |err| switch (err) {
        error.UnsupportedFeature => return try compile_kernel_wgsl_to_spirv(self, allocator, kernel_name),
        else => return err,
    };
    defer allocator.free(path);

    const bytes = std.fs.cwd().readFileAlloc(allocator, path, MAX_KERNEL_SOURCE_BYTES) catch return error.ShaderCompileFailed;
    defer allocator.free(bytes);
    return try words_from_spirv_bytes(allocator, bytes);
}

pub fn load_kernel_spirv_cached(self: anytype, kernel_name: []const u8) ![]const u32 {
    return ensure_kernel_spirv_cached(self, kernel_name);
}

fn compile_kernel_wgsl_to_spirv(self: anytype, allocator: std.mem.Allocator, kernel_name: []const u8) ![]u32 {
    const source_path = try resolve_kernel_path(self, allocator, kernel_name);
    defer allocator.free(source_path);
    if (!std.mem.endsWith(u8, source_path, ".wgsl")) return error.UnsupportedFeature;

    const wgsl = std.fs.cwd().readFileAlloc(allocator, source_path, MAX_KERNEL_SOURCE_BYTES) catch return error.ShaderCompileFailed;
    defer allocator.free(wgsl);

    var spirv_buf = try allocator.alloc(u8, spirv_translation.MAX_OUTPUT);
    defer allocator.free(spirv_buf);
    const spirv_len = spirv_translation.translateToSpirv(allocator, wgsl, spirv_buf) catch return error.ShaderCompileFailed;
    return try words_from_spirv_bytes(allocator, spirv_buf[0..spirv_len]);
}

pub fn words_from_spirv_bytes(allocator: std.mem.Allocator, bytes: []const u8) ![]u32 {
    if (bytes.len == 0 or (bytes.len % 4) != 0) return error.ShaderCompileFailed;

    const words = try allocator.alloc(u32, bytes.len / 4);
    errdefer allocator.free(words);
    for (words, 0..) |*word, i| {
        const start = i * 4;
        const chunk: *const [4]u8 = @ptrCast(bytes[start .. start + 4].ptr);
        word.* = std.mem.readInt(u32, chunk, .little);
    }
    if (words[0] != SPIRV_MAGIC) return error.ShaderCompileFailed;
    return words;
}

fn resolve_kernel_path(self: anytype, allocator: std.mem.Allocator, kernel_name: []const u8) ![]u8 {
    const direct = try allocator.dupe(u8, kernel_name);
    if (path_utils.file_exists(direct)) return direct;
    allocator.free(direct);

    const root = self.kernel_root orelse DEFAULT_KERNEL_ROOT;
    const rooted = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, kernel_name });
    if (path_utils.file_exists(rooted)) return rooted;
    allocator.free(rooted);

    if (!std.mem.endsWith(u8, kernel_name, ".wgsl")) {
        const with_suffix = try std.fmt.allocPrint(allocator, "{s}/{s}.wgsl", .{ root, kernel_name });
        if (path_utils.file_exists(with_suffix)) return with_suffix;
        allocator.free(with_suffix);
    }
    return error.ShaderToolchainUnavailable;
}

fn resolve_kernel_spirv_path(self: anytype, allocator: std.mem.Allocator, kernel_name: []const u8) ![]u8 {
    const source_path = try resolve_kernel_path(self, allocator, kernel_name);
    defer allocator.free(source_path);

    if (std.mem.endsWith(u8, source_path, ".spv") or std.mem.endsWith(u8, source_path, ".spirv")) {
        return try allocator.dupe(u8, source_path);
    }

    const sibling_spv = try std.fmt.allocPrint(allocator, "{s}.spv", .{source_path});
    if (path_utils.file_exists(sibling_spv)) return sibling_spv;
    allocator.free(sibling_spv);

    if (std.mem.lastIndexOfScalar(u8, source_path, '.')) |idx| {
        const replaced = try std.fmt.allocPrint(allocator, "{s}.spv", .{source_path[0..idx]});
        if (path_utils.file_exists(replaced)) return replaced;
        allocator.free(replaced);
    }

    return error.UnsupportedFeature;
}
