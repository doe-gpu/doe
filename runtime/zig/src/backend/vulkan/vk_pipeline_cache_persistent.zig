// Provider-owned persistent VkPipelineCache for the Doe Vulkan backend.
//
// Parallels runtime/zig/src/backend/metal/metal_pipeline_cache.zig in shape.
// Creates a real VkPipelineCache via vkCreatePipelineCache at device bring-up
// and passes its handle to vkCreateComputePipelines / vkCreateGraphicsPipelines
// instead of VK_NULL_U64. When a cache directory is configured, the module
// also reads an existing blob at provider startup and writes the current cache
// at provider teardown via vkGetPipelineCacheData (atomic .tmp + rename).
//
// Vulkan-spec behavior: if the blob header does not match the current device's
// pipelineCacheUUID/vendorID/deviceID, the driver silently initializes an
// empty cache from the bytes and continues. We do not need to pre-validate
// the header on our side; the driver handles incompatibility cleanly.

const std = @import("std");
const configuration = @import("../../contracts/runtime_configuration.zig");
const c = @import("vk_constants.zig");

const CACHE_BLOB_BASENAME = "doe-vulkan-pipeline-cache.blob";
const CACHE_BLOB_MAX_BYTES: usize = 64 * 1024 * 1024;
const CACHE_BLOB_MIN_BYTES: usize = 32;
const ENV_CACHE_DIR = "DOE_PIPELINE_CACHE_DIR";

pub const VulkanPipelineCacheState = enum { disabled, enabled, enabled_reloaded };

pub const WarmupTelemetry = struct {
    count: u64 = 0,
    ns: u64 = 0,
};

fn trimTrailingSeparator(dir: []const u8) []const u8 {
    var end = dir.len;
    while (end > 0 and dir[end - 1] == '/') : (end -= 1) {}
    return dir[0..end];
}

/// Provider-owned persistent cache. Configuration, handle, device identity,
/// telemetry, and persistence paths all share the provider lifetime; multiple
/// sessions cannot overwrite one another through process-global state.
pub const VulkanPipelineCache = struct {
    allocator: std.mem.Allocator,
    enabled: bool = true,
    handle: c.VkPipelineCache = c.VK_NULL_U64,
    state: VulkanPipelineCacheState = .disabled,
    device: c.VkDevice = null,
    warmup: WarmupTelemetry = .{},
    cache_path_buf: [512]u8 = undefined,
    cache_path_len: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        cache_configuration: configuration.PipelineCacheConfiguration,
    ) VulkanPipelineCache {
        var self = VulkanPipelineCache{
            .allocator = allocator,
            .enabled = cache_configuration.enabled,
        };
        self.setDirectory(cache_configuration.directory);
        return self;
    }

    fn setDirectory(self: *VulkanPipelineCache, directory: []const u8) void {
        self.cache_path_len = 0;
        const trimmed = trimTrailingSeparator(directory);
        if (trimmed.len == 0 or trimmed.len + 1 + CACHE_BLOB_BASENAME.len >= self.cache_path_buf.len) return;
        @memcpy(self.cache_path_buf[0..trimmed.len], trimmed);
        self.cache_path_buf[trimmed.len] = '/';
        @memcpy(
            self.cache_path_buf[trimmed.len + 1 .. trimmed.len + 1 + CACHE_BLOB_BASENAME.len],
            CACHE_BLOB_BASENAME,
        );
        self.cache_path_len = trimmed.len + 1 + CACHE_BLOB_BASENAME.len;
    }

    fn cachePath(self: *const VulkanPipelineCache) ?[]const u8 {
        if (self.cache_path_len == 0) return null;
        return self.cache_path_buf[0..self.cache_path_len];
    }

    fn configureDirectoryFromEnvironment(self: *VulkanPipelineCache) void {
        if (self.cache_path_len != 0) return;
        const value = std.process.getEnvVarOwned(self.allocator, ENV_CACHE_DIR) catch return;
        defer self.allocator.free(value);
        self.setDirectory(value);
    }

    pub fn create(self: *VulkanPipelineCache, device: c.VkDevice) !void {
        if (!self.enabled) {
            self.state = .disabled;
            return;
        }
        if (self.handle != c.VK_NULL_U64) return;
        if (device == null) return error.InvalidArgument;

        const start_ns = std.time.nanoTimestamp();
        self.configureDirectoryFromEnvironment();

        var blob_bytes: ?[]u8 = null;
        defer if (blob_bytes) |bytes| self.allocator.free(bytes);
        var reloaded = false;
        if (self.cachePath()) |path| {
            blob_bytes = self.tryReadCacheBlob(path);
            reloaded = blob_bytes != null;
        }

        const initial_size: usize = if (blob_bytes) |bytes| bytes.len else 0;
        const initial_ptr: ?*const anyopaque = if (blob_bytes) |bytes| @ptrCast(bytes.ptr) else null;
        var create_info = c.VkPipelineCacheCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .initialDataSize = initial_size,
            .pInitialData = initial_ptr,
        };
        var handle: c.VkPipelineCache = c.VK_NULL_U64;
        const result = c.vkCreatePipelineCache(device, &create_info, null, &handle);
        if (result != c.VK_SUCCESS) {
            self.state = .disabled;
            return error.PipelineCacheCreateFailed;
        }
        self.handle = handle;
        self.device = device;
        self.state = if (reloaded) .enabled_reloaded else .enabled;
        self.warmup = .{
            .count = 1,
            .ns = @intCast(std.time.nanoTimestamp() - start_ns),
        };
    }

    fn tryReadCacheBlob(self: *VulkanPipelineCache, path: []const u8) ?[]u8 {
        const file = if (std.fs.path.isAbsolute(path))
            std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch return null
        else
            std.fs.cwd().openFile(path, .{ .mode = .read_only }) catch return null;
        defer file.close();
        const stat = file.stat() catch return null;
        if (stat.size < CACHE_BLOB_MIN_BYTES or stat.size > CACHE_BLOB_MAX_BYTES) return null;
        const size: usize = @intCast(stat.size);
        const buffer = self.allocator.alloc(u8, size) catch return null;
        errdefer self.allocator.free(buffer);
        const read = file.readAll(buffer) catch {
            self.allocator.free(buffer);
            return null;
        };
        if (read != size) {
            self.allocator.free(buffer);
            return null;
        }
        return buffer;
    }

    pub fn deinit(self: *VulkanPipelineCache, device: c.VkDevice) void {
        if (self.handle == c.VK_NULL_U64 or device == null or self.device != device) return;
        self.flush(device);
        c.vkDestroyPipelineCache(device, self.handle, null);
        self.handle = c.VK_NULL_U64;
        self.device = null;
        self.state = .disabled;
        self.warmup = .{};
    }

    pub fn flush(self: *VulkanPipelineCache, device: c.VkDevice) void {
        if (self.handle == c.VK_NULL_U64 or device == null or self.device != device) return;
        if (self.cachePath()) |path| {
            self.tryWriteCacheBlob(device, self.handle, path) catch {};
        }
    }

    fn tryWriteCacheBlob(
        self: *VulkanPipelineCache,
        device: c.VkDevice,
        cache: c.VkPipelineCache,
        path: []const u8,
    ) !void {
        var size: usize = 0;
        const query_result = c.vkGetPipelineCacheData(device, cache, &size, null);
        if (query_result != c.VK_SUCCESS or size == 0 or size > CACHE_BLOB_MAX_BYTES) return;
        const buffer = try self.allocator.alloc(u8, size);
        defer self.allocator.free(buffer);
        var written: usize = size;
        const fetch_result = c.vkGetPipelineCacheData(device, cache, &written, @ptrCast(buffer.ptr));
        if (fetch_result != c.VK_SUCCESS or written == 0) return;

        if (std.fs.path.dirname(path)) |directory| {
            if (std.fs.path.isAbsolute(path)) {
                std.fs.makeDirAbsolute(directory) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };
            } else {
                try std.fs.cwd().makePath(directory);
            }
        }

        var temporary_path_buffer: [520]u8 = undefined;
        if (path.len + 4 >= temporary_path_buffer.len) return;
        @memcpy(temporary_path_buffer[0..path.len], path);
        @memcpy(temporary_path_buffer[path.len..][0..4], ".tmp");
        const temporary_path = temporary_path_buffer[0 .. path.len + 4];

        const temporary_file = if (std.fs.path.isAbsolute(path))
            std.fs.createFileAbsolute(temporary_path, .{ .truncate = true }) catch return
        else
            std.fs.cwd().createFile(temporary_path, .{ .truncate = true }) catch return;
        var keep_temporary_file = false;
        defer if (!keep_temporary_file) {
            if (std.fs.path.isAbsolute(path)) {
                std.fs.deleteFileAbsolute(temporary_path) catch {};
            } else {
                std.fs.cwd().deleteFile(temporary_path) catch {};
            }
        };
        defer temporary_file.close();
        temporary_file.writeAll(buffer[0..written]) catch return;
        if (std.fs.path.isAbsolute(path)) {
            std.fs.renameAbsolute(temporary_path, path) catch return;
        } else {
            std.fs.cwd().rename(temporary_path, path) catch return;
        }
        keep_temporary_file = true;
    }

    pub fn handleForPipelineCreation(self: *const VulkanPipelineCache) c.VkPipelineCache {
        if (!self.enabled) return c.VK_NULL_U64;
        return self.handle;
    }

    pub fn active(self: *const VulkanPipelineCache) bool {
        return self.enabled and self.handle != c.VK_NULL_U64 and self.state != .disabled;
    }

    pub fn warmupTelemetry(self: *const VulkanPipelineCache) WarmupTelemetry {
        return self.warmup;
    }
};

test "disabled flag suppresses cache creation" {
    const cache = VulkanPipelineCache.init(std.testing.allocator, .{ .enabled = false });
    try std.testing.expectEqual(@as(c.VkPipelineCache, c.VK_NULL_U64), cache.handleForPipelineCreation());
    try std.testing.expect(!cache.active());
}

test "default state is disabled handle" {
    const cache = VulkanPipelineCache.init(std.testing.allocator, .{});
    try std.testing.expectEqual(@as(c.VkPipelineCache, c.VK_NULL_U64), cache.handleForPipelineCreation());
    try std.testing.expect(!cache.active());
}

test "cache configuration is isolated per provider instance" {
    var first = VulkanPipelineCache.init(std.testing.allocator, .{
        .enabled = false,
        .directory = "cache/first/",
    });
    const second = VulkanPipelineCache.init(std.testing.allocator, .{
        .enabled = true,
        .directory = "cache/second",
    });

    first.handle = 17;
    first.state = .enabled;
    try std.testing.expect(!first.active());
    try std.testing.expectEqual(@as(c.VkPipelineCache, c.VK_NULL_U64), first.handleForPipelineCreation());
    try std.testing.expectEqualStrings(
        "cache/first/doe-vulkan-pipeline-cache.blob",
        first.cachePath().?,
    );
    try std.testing.expectEqualStrings(
        "cache/second/doe-vulkan-pipeline-cache.blob",
        second.cachePath().?,
    );
    try std.testing.expect(!second.active());
}
