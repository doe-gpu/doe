//! Oracle comparison adapter verifying execution results against mathematical ground truth.

const std = @import("std");
const exactness = @import("../contracts/exactness.zig");

pub fn compareExactBytes(actual: []const u8, expected: []const u8) exactness.OracleResult {
    if (actual.len != expected.len) {
        return .{
            .passed = false,
            .exactness_class = .exact_bitwise,
            .message = "byte slice length mismatch",
        };
    }
    if (std.mem.eql(u8, actual, expected)) {
        return .{
            .passed = true,
            .exactness_class = .exact_bitwise,
            .max_absolute_error = 0.0,
        };
    }
    return .{
        .passed = false,
        .exactness_class = .exact_bitwise,
        .message = "byte mismatch detected",
    };
}

pub fn compareFloatsWithTolerance(actual: []const f32, expected: []const f32, policy: exactness.TolerancePolicy) exactness.OracleResult {
    if (actual.len != expected.len) {
        return .{
            .passed = false,
            .exactness_class = .relative_tolerance,
            .message = "float slice length mismatch",
        };
    }

    var max_abs_err: f64 = 0.0;
    var max_rel_err: f64 = 0.0;
    var divergent_count: u32 = 0;

    for (actual, expected) |a, e| {
        const abs_err = @abs(@as(f64, a) - @as(f64, e));
        if (abs_err > max_abs_err) max_abs_err = abs_err;

        const denom = @max(@abs(@as(f64, e)), 1e-12);
        const rel_err = abs_err / denom;
        if (rel_err > max_rel_err) max_rel_err = rel_err;

        if (abs_err > policy.atol and rel_err > policy.rtol) {
            divergent_count += 1;
        }
    }

    const passed = divergent_count <= policy.max_divergent_elements;
    return .{
        .passed = passed,
        .exactness_class = .relative_tolerance,
        .max_absolute_error = max_abs_err,
        .max_relative_error = max_rel_err,
        .divergent_elements_count = divergent_count,
        .message = if (passed) "" else "tolerance threshold exceeded",
    };
}
