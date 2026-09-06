const std = @import("std");
const analysis = @import("analysis.zig");
const ir = @import("../ir/ir.zig");
const float_fusion = @import("../ir/ir_transform_float_fusion.zig");
const ir_validate = @import("../ir/ir_validate.zig");
const build_options = @import("build_options");
pub const emitter = @import("../emit/spirv/emit_spirv.zig");
pub const MAX_OUTPUT: usize = emitter.MAX_OUTPUT;

pub fn prepareComputeIr(module: *ir.Module) analysis.TranslateError!void {
    if (!build_options.spirv_compute_fuse_trailing_add or module.entry_points.items.len == 0) return;
    for (module.entry_points.items) |entry| if (entry.stage != .compute) return;
    _ = float_fusion.apply(module) catch |err| {
        analysis.setLastErrorDetailPublic(.ir_transform, err, @errorName(err));
        return err;
    };
    ir_validate.validate(module) catch |err| {
        analysis.setLastErrorDetailPublic(.ir_transform, err, @errorName(err));
        return err;
    };
}

pub fn translateToSpirv(allocator: std.mem.Allocator, wgsl: []const u8, out: []u8) analysis.TranslateError!usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var module_ir = try analysis.analyzeToIr(arena.allocator(), wgsl);
    try prepareComputeIr(&module_ir);

    return emitter.emit(&module_ir, out) catch |err| {
        const kind = switch (err) {
            error.OutputTooLarge => analysis.TranslateError.OutputTooLarge,
            error.UnsupportedConstruct => analysis.TranslateError.UnsupportedConstruct,
            error.InvalidIr => analysis.TranslateError.InvalidIr,
            error.OutOfMemory => analysis.TranslateError.OutOfMemory,
        };
        analysis.setLastError(.spirv_emit, kind, null, null);
        return kind;
    };
}
