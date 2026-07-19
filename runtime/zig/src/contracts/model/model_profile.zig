const std = @import("std");
const policy = @import("model_policy.zig");

pub const DeviceProfile = struct {
    vendor: []const u8,
    api: policy.Api,
    device_family: ?[]const u8 = null,
    driver_version: SemVer,
};

pub const SemVer = struct {
    major: u32,
    minor: u32,
    patch: u32,

    pub fn parse(text: []const u8) !SemVer {
        var major: u32 = 0;
        var minor: u32 = 0;
        var patch: u32 = 0;
        var numbers_seen: u32 = 0;
        var it = std.mem.splitScalar(u8, text, '.');
        while (it.next()) |part| {
            if (part.len == 0) return error.InvalidVersion;
            const value = std.fmt.parseInt(u32, part, 10) catch return error.InvalidVersion;
            switch (numbers_seen) {
                0 => major = value,
                1 => minor = value,
                2 => patch = value,
                else => return error.InvalidVersion,
            }
            numbers_seen += 1;
        }

        return SemVer{ .major = major, .minor = minor, .patch = patch };
    }

    pub fn cmp(self: SemVer, other: SemVer) std.math.Order {
        const major = std.math.order(self.major, other.major);
        if (major != .eq) return major;
        const minor = std.math.order(self.minor, other.minor);
        if (minor != .eq) return minor;
        return std.math.order(self.patch, other.patch);
    }

    pub fn equals(self: SemVer, other: SemVer) bool {
        return self.cmp(other) == .eq;
    }

    pub fn ge(self: SemVer, other: SemVer) bool {
        return self.cmp(other) != .lt;
    }

    pub fn gt(self: SemVer, other: SemVer) bool {
        return self.cmp(other) == .gt;
    }

    pub fn lt(self: SemVer, other: SemVer) bool {
        return self.cmp(other) == .lt;
    }
};

const testing = std.testing;

test "SemVer.parse valid three-part version" {
    const v = try SemVer.parse("1.2.3");
    try testing.expectEqual(@as(u32, 1), v.major);
    try testing.expectEqual(@as(u32, 2), v.minor);
    try testing.expectEqual(@as(u32, 3), v.patch);
}

test "SemVer.parse single number yields major only" {
    const v = try SemVer.parse("5");
    try testing.expectEqual(@as(u32, 5), v.major);
    try testing.expectEqual(@as(u32, 0), v.minor);
    try testing.expectEqual(@as(u32, 0), v.patch);
}

test "SemVer.parse two-part version" {
    const v = try SemVer.parse("10.20");
    try testing.expectEqual(@as(u32, 10), v.major);
    try testing.expectEqual(@as(u32, 20), v.minor);
    try testing.expectEqual(@as(u32, 0), v.patch);
}

test "SemVer.parse rejects empty part" {
    try testing.expectError(error.InvalidVersion, SemVer.parse("1..3"));
}

test "SemVer.parse rejects four-part version" {
    try testing.expectError(error.InvalidVersion, SemVer.parse("1.2.3.4"));
}

test "SemVer.parse rejects non-numeric part" {
    try testing.expectError(error.InvalidVersion, SemVer.parse("1.abc.3"));
}

test "SemVer comparison ordering" {
    const v1 = SemVer{ .major = 1, .minor = 0, .patch = 0 };
    const v2 = SemVer{ .major = 2, .minor = 0, .patch = 0 };
    const v1_1 = SemVer{ .major = 1, .minor = 1, .patch = 0 };
    const v1_0_1 = SemVer{ .major = 1, .minor = 0, .patch = 1 };

    try testing.expect(v1.lt(v2));
    try testing.expect(v2.gt(v1));
    try testing.expect(v1.lt(v1_1));
    try testing.expect(v1.lt(v1_0_1));
    try testing.expect(v1.equals(v1));
    try testing.expect(v1.ge(v1));
    try testing.expect(v2.ge(v1));
    try testing.expect(!v1.gt(v1));
    try testing.expectEqual(std.math.Order.eq, v1.cmp(v1));
}
