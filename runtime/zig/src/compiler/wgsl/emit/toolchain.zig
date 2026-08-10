const std = @import("std");

pub const Discovery = enum {
    explicit_config,
    env_path,
    env_path_lookup,
    implicit_path_lookup,
};

pub const Config = struct {
    executable: []const u8,
    discovery: Discovery = .explicit_config,
    owned_value: ?[]u8 = null,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.owned_value) |value| {
            allocator.free(value);
            self.owned_value = null;
        }
    }
};

pub fn discoveryLabel(discovery: Discovery) []const u8 {
    return switch (discovery) {
        .explicit_config => "explicit-config",
        .env_path => "environment-path",
        .env_path_lookup => "environment-PATH",
        .implicit_path_lookup => "implicit-PATH",
    };
}

pub fn diagnosticOutput(stderr: []const u8, stdout: []const u8) []const u8 {
    const trimmed_stderr = std.mem.trim(u8, stderr, " \t\r\n");
    if (trimmed_stderr.len != 0) return trimmed_stderr;
    return std.mem.trim(u8, stdout, " \t\r\n");
}

test "toolchain config owns discovery labels, diagnostics, and allocated paths" {
    const allocator = std.testing.allocator;
    const owned_path = try allocator.dupe(u8, "compiler");
    var config = Config{
        .executable = owned_path,
        .discovery = .env_path,
        .owned_value = owned_path,
    };

    try std.testing.expectEqualStrings("environment-path", discoveryLabel(config.discovery));
    try std.testing.expectEqualStrings("stderr", diagnosticOutput("  stderr\n", "stdout"));
    try std.testing.expectEqualStrings("stdout", diagnosticOutput("\n", " stdout "));
    config.deinit(allocator);
    try std.testing.expectEqual(@as(?[]u8, null), config.owned_value);
}
