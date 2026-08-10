const std = @import("std");
const ir = @import("../ir/ir.zig");

pub fn applyOverrides(module: *ir.Module, overrides: []const ir.OverrideEntry) void {
    for (overrides) |entry| {
        // Try numeric id match first.
        const numeric_id = std.fmt.parseInt(u32, entry.key, 10) catch null;
        for (module.globals.items) |*global| {
            if (global.class != .override_) continue;
            const matched = if (numeric_id) |id|
                (global.override_id != null and global.override_id.? == id)
            else
                std.mem.eql(u8, global.name, entry.key);
            if (!matched) continue;
            // Replace the initializer with the override value.
            const scalar_type = switch (module.types.get(global.ty)) {
                .scalar => |s| s,
                else => continue,
            };
            global.initializer = switch (scalar_type) {
                .bool => .{ .bool = entry.value != 0.0 },
                .i32, .abstract_int => .{ .int = @bitCast(@as(i64, @intFromFloat(entry.value))) },
                .u32 => .{ .int = @intFromFloat(entry.value) },
                .f32, .f16, .abstract_float => .{ .float = entry.value },
                else => continue,
            };
            // Demote to const so emitter outputs a fixed constant.
            global.class = .const_;
            break;
        }
    }
}
