//! Oracle exactness and tolerance classification contracts.

const std = @import("std");

pub const ExactnessClass = enum {
    exact_bitwise,
    relative_tolerance,
    top_k_argmax,
    structural_identity,
};

pub const TolerancePolicy = struct {
    atol: f64 = 1e-5,
    rtol: f64 = 1e-3,
    max_divergent_elements: u32 = 0,
};

pub const OracleResult = struct {
    passed: bool = true,
    exactness_class: ExactnessClass = .exact_bitwise,
    max_absolute_error: f64 = 0.0,
    max_relative_error: f64 = 0.0,
    divergent_elements_count: u32 = 0,
    message: []const u8 = "",
};
