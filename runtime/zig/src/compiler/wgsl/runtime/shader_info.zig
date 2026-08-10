const std = @import("std");
const analysis = @import("../pipeline/analysis.zig");
const robustness = @import("../ir/ir_transform_robustness.zig");
const emit_msl = @import("../emit/msl/emit_msl.zig");

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
) analysis.TranslateError!bool {
    return mslNeedsSizesBufferWithConfig(
        allocator,
        wgsl,
        analysis.default_translation_robustness_config(),
    );
}

pub fn mslNeedsSizesBufferWithConfig(
    allocator: std.mem.Allocator,
    wgsl: []const u8,
    config: robustness.Config,
) analysis.TranslateError!bool {
    var module = try analysis.analyzeToIrWithConfig(allocator, wgsl, config);
    defer module.deinit();
    return emit_msl.moduleNeedsSizesParam(&module);
}
