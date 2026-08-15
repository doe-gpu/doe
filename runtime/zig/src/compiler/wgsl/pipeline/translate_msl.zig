const std = @import("std");
const analysis = @import("analysis.zig");
const ir = @import("../ir/ir.zig");
pub const emitter = @import("../emit/msl/emit_msl.zig");
const override_values = @import("overrides.zig");

pub const MAX_OUTPUT: usize = emitter.MAX_OUTPUT;

pub fn translateToMsl(allocator: std.mem.Allocator, wgsl: []const u8, out: []u8) analysis.TranslateError!usize {
    return translateToMslWithOverrides(allocator, wgsl, out, null, 0);
}

pub fn translateToMslWithOverrides(allocator: std.mem.Allocator, wgsl: []const u8, out: []u8, overrides: ?[*]const ir.OverrideEntry, override_count: usize) analysis.TranslateError!usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const override_slice = if (overrides != null and override_count > 0)
        overrides.?[0..override_count]
    else
        &.{};
    var module_ir = try analysis.analyzeToIrWithConfigAndOverrides(
        arena.allocator(),
        wgsl,
        analysis.default_translation_robustness_config(),
        override_slice,
    );

    if (override_slice.len > 0) override_values.applyOverrides(&module_ir, override_slice);

    return emitter.emit(&module_ir, out) catch |err| {
        const kind = switch (err) {
            error.OutputTooLarge => analysis.TranslateError.OutputTooLarge,
            error.InvalidIr => analysis.TranslateError.InvalidIr,
        };
        analysis.setLastError(.msl_emit, kind, null, null);
        return kind;
    };
}
