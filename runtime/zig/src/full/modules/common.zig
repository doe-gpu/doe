const builtin = @import("builtin");
const std = @import("std");
const model_policy = @import("../../contracts/model/model_policy.zig");
const model_profile = @import("../../contracts/model/model_profile.zig");
const backend_policy = @import("../../backend/backend_policy.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

pub const HostRuntimeError = error{
    UnsupportedHost,
};

pub const TraceLink = struct {
    moduleIdentity: []const u8,
    requestHash: []const u8,
    policyHash: []const u8,
    resultHash: []const u8,
};

pub fn hostProfile() HostRuntimeError!model_profile.DeviceProfile {
    return switch (builtin.os.tag) {
        .macos => .{
            .vendor = "apple",
            .api = .metal,
            .device_family = "apple-gpu",
            .driver_version = .{ .major = 1, .minor = 0, .patch = 0 },
        },
        .linux => .{
            .vendor = "host",
            .api = .vulkan,
            .device_family = "linux-gpu",
            .driver_version = .{ .major = 1, .minor = 0, .patch = 0 },
        },
        .windows => .{
            .vendor = "host",
            .api = .d3d12,
            .device_family = "windows-gpu",
            .driver_version = .{ .major = 1, .minor = 0, .patch = 0 },
        },
        else => HostRuntimeError.UnsupportedHost,
    };
}

pub fn jsonStringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return try out.toOwnedSlice();
}

pub fn sha256HexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const alphabet = "0123456789abcdef";
    var out = try allocator.alloc(u8, digest.len * 2);
    for (digest, 0..) |byte, idx| {
        out[idx * 2] = alphabet[byte >> 4];
        out[idx * 2 + 1] = alphabet[byte & 0x0F];
    }
    return out;
}

pub fn stableHashJsonAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    const encoded = try jsonStringifyAlloc(allocator, value);
    defer allocator.free(encoded);
    return try sha256HexAlloc(allocator, encoded);
}

pub fn duplicateString(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    return try allocator.dupe(u8, value);
}

pub fn ensureLocalLibrarySearchPath(allocator: std.mem.Allocator) !void {
    switch (builtin.os.tag) {
        .macos, .linux => {},
        else => return,
    }

    const candidates = [_][]const u8{
        "zig-out/lib",
        "runtime/zig/zig-out/lib",
    };
    for (candidates) |candidate| {
        const real = std.fs.cwd().realpathAlloc(allocator, candidate) catch continue;
        defer allocator.free(real);

        const z = try allocator.allocSentinel(u8, real.len, 0);
        defer allocator.free(z);
        @memcpy(z[0..real.len], real);
        switch (builtin.os.tag) {
            .macos => {
                _ = setenv("DYLD_LIBRARY_PATH", z.ptr, 1);
                _ = setenv("DYLD_FALLBACK_LIBRARY_PATH", z.ptr, 1);
            },
            .linux => {
                _ = setenv("LD_LIBRARY_PATH", z.ptr, 1);
            },
            else => {},
        }
        return;
    }
}

pub fn runtimePolicyPath() []const u8 {
    std.fs.cwd().access("config/backend-runtime-policy.json", .{}) catch {
        return "../config/backend-runtime-policy.json";
    };
    return "config/backend-runtime-policy.json";
}

pub fn kernelRootPath() []const u8 {
    std.fs.cwd().access("bench/kernels", .{}) catch {
        return "../bench/kernels";
    };
    return "bench/kernels";
}

pub fn hostBackendLane(api: model_policy.Api) backend_policy.BackendLane {
    return switch (api) {
        .metal => .metal_doe_app,
        .d3d12 => .d3d12_doe_app,
        else => .vulkan_doe_app,
    };
}
