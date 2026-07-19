const std = @import("std");
const mod = @import("../mod.zig");

// Extract @workgroup_size(x[,y[,z]]) from WGSL source via string search.
pub fn extractWorkgroupSize(wgsl: []const u8) struct { x: u32, y: u32, z: u32 } {
    const needle = "@workgroup_size(";
    const idx = std.mem.indexOf(u8, wgsl, needle) orelse return .{ .x = 0, .y = 0, .z = 0 };
    const start = idx + needle.len;
    const end = std.mem.indexOfPos(u8, wgsl, start, ")") orelse return .{ .x = 0, .y = 0, .z = 0 };
    const args = wgsl[start..end];
    var vals = [3]u32{ 0, 0, 0 };
    var vi: usize = 0;
    for (args) |c| {
        if (c >= '0' and c <= '9') {
            vals[vi] = vals[vi] * 10 + @as(u32, c - '0');
        } else if (c == ',' and vi < 2) {
            vi += 1;
        }
    }
    return .{
        .x = if (vals[0] > 0) vals[0] else 1,
        .y = if (vals[1] > 0) vals[1] else 1,
        .z = if (vals[2] > 0) vals[2] else 1,
    };
}

pub fn mslNeedsSizesBuffer(
    allocator: std.mem.Allocator,
    wgsl: []const u8,
) mod.TranslateError!bool {
    return mslNeedsSizesBufferWithConfig(
        allocator,
        wgsl,
        mod.default_translation_robustness_config(),
    );
}

pub fn mslNeedsSizesBufferWithConfig(
    allocator: std.mem.Allocator,
    wgsl: []const u8,
    config: mod.ir_transform_robustness.Config,
) mod.TranslateError!bool {
    var module = try mod.analyzeToIrWithConfig(allocator, wgsl, config);
    defer module.deinit();
    return mod.emit_msl.moduleNeedsSizesParam(&module);
}
