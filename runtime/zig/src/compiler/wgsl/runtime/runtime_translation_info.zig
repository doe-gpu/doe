const std = @import("std");
const ir = @import("../ir/ir.zig");
const analysis = @import("../pipeline/analysis.zig");
const emit_msl = @import("../emit/msl/emit_msl.zig");

pub const TranslationInfo = struct {
    workgroup_size: [3]u32 = .{ 1, 1, 1 },
    needs_sizes_buf: bool = false,
    dispatch_preconditions: []const ir.DispatchPrecondition = &.{},
    texture_dispatch_preconditions: []const ir.TextureDispatchPrecondition = &.{},

    pub fn clone(self: *const TranslationInfo, allocator: std.mem.Allocator) error{OutOfMemory}!TranslationInfo {
        var result = TranslationInfo{ .workgroup_size = self.workgroup_size, .needs_sizes_buf = self.needs_sizes_buf };
        errdefer result.deinit(allocator);
        if (self.dispatch_preconditions.len > 0) result.dispatch_preconditions = try allocator.dupe(ir.DispatchPrecondition, self.dispatch_preconditions);
        if (self.texture_dispatch_preconditions.len > 0) result.texture_dispatch_preconditions = try allocator.dupe(ir.TextureDispatchPrecondition, self.texture_dispatch_preconditions);
        return result;
    }

    pub fn deinit(self: *TranslationInfo, allocator: std.mem.Allocator) void {
        if (self.dispatch_preconditions.len > 0) allocator.free(self.dispatch_preconditions);
        if (self.texture_dispatch_preconditions.len > 0) allocator.free(self.texture_dispatch_preconditions);
        self.* = .{};
    }
};

pub const TranslationResult = struct {
    len: usize,
    info: TranslationInfo,
};

pub const TimedTranslationResult = struct {
    len: usize,
    info: TranslationInfo,
    phase_timings_ns: analysis.CompilePhaseTimingsNs,
};

pub fn buildTranslationInfo(
    allocator: std.mem.Allocator,
    module_ir: *const ir.Module,
) analysis.TranslateError!TranslationInfo {
    const borrowed = TranslationInfo{
        .workgroup_size = compute_workgroup_size(module_ir),
        .needs_sizes_buf = emit_msl.moduleNeedsSizesParam(module_ir),
        .dispatch_preconditions = module_ir.dispatch_preconditions.items,
        .texture_dispatch_preconditions = module_ir.texture_dispatch_preconditions.items,
    };
    return borrowed.clone(allocator);
}

fn compute_workgroup_size(module_ir: *const ir.Module) [3]u32 {
    for (module_ir.entry_points.items) |entry| {
        if (entry.stage == .compute) return entry.workgroup_size;
    }
    return .{ 1, 1, 1 };
}
