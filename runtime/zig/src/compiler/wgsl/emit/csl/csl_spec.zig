// csl_spec.zig — Cerebras CSL target constants, limits, and enums.
//
// Reference: https://sdk.cerebras.net/csl/language_index (SDK 2.10.0)
// This file is the single source of truth for CSL target constraints
// used by the emit_csl_* backend modules.

/// Fabric routing directions available on each PE's router.
pub const Direction = enum {
    NORTH,
    SOUTH,
    EAST,
    WEST,
    RAMP,
};

/// WSE hardware generation. Affects color count, microthread model, and
/// queue initialization requirements.
pub const Arch = enum {
    wse2,
    wse3,
};

// ---------------------------------------------------------------------------
// Hardware limits
// ---------------------------------------------------------------------------

/// Maximum routable colors on WSE-2. WSE-3 may allow more but 24 is the
/// conservative ceiling used by the current CSL lane.
pub const MAX_COLORS: u8 = 24;

/// Colors reserved by the memcpy framework for host↔device transfers.
/// The PE program must not allocate these for application routing.
pub const MEMCPY_RESERVED_COLORS: u8 = 4;

/// Usable application colors after memcpy reservation.
pub const APP_COLORS: u8 = MAX_COLORS - MEMCPY_RESERVED_COLORS;

/// Per-PE SRAM on WSE-2 (bytes). WSE-3 is similar but not publicly documented
/// at a per-PE granularity; use this as the conservative floor.
pub const PE_SRAM_BYTES: usize = 48 * 1024;

/// Maximum PE grid dimension (width or height) for SDK rectangle programs.
/// The full WSE-2 mesh is ~750×1180 but practical SDK programs use smaller
/// rectangles to leave room for memcpy routing infrastructure.
pub const MAX_RECT_DIM: u16 = 512;

// ---------------------------------------------------------------------------
// Output format markers
// ---------------------------------------------------------------------------

/// Section separator emitted between layout.csl and pe_program.csl in the
/// combined output buffer. The host splits on this marker to extract files.
pub const SECTION_SEPARATOR: []const u8 = "\n//--- ";
pub const SECTION_SEPARATOR_END: []const u8 = " ---\n";

/// Standard file names for the two mandatory sections.
pub const LAYOUT_FILENAME: []const u8 = "layout.csl";
pub const PE_PROGRAM_FILENAME: []const u8 = "pe_program.csl";

// ---------------------------------------------------------------------------
// CSL host-plan and toolchain metadata
// ---------------------------------------------------------------------------

pub const HOST_PLAN_SCHEMA_VERSION: u32 = 3;
pub const HOST_PLAN_ARTIFACT_KIND: []const u8 = "csl_host_plan";
pub const HOST_PLAN_TARGET: []const u8 = "wse3";
pub const HOST_PLAN_CONTRACT: []const u8 = "explicit_host_plan";
pub const HOST_PLAN_DISCOVERY_EXPLICIT_CONFIG: []const u8 = "explicit_config";
pub const HOST_PLAN_DISCOVERY_IMPLICIT_PATH_LOOKUP: []const u8 = "implicit_path_lookup";
pub const CSLC_SDK_MIN_VERSION: []const u8 = "2.10.0";
pub const CSLC_VERSION_ARG: []const u8 = "--version";
pub const SIMULATOR_PLAN_SCHEMA_VERSION: u32 = 2;
pub const SIMULATOR_PLAN_ARTIFACT_KIND: []const u8 = "csl_simulator_plan";
pub const SIMULATOR_PLAN_TARGET: []const u8 = "wse3";
pub const SIMULATOR_PLAN_CONTRACT: []const u8 = "explicit_simulator_launch";
pub const SIMULATOR_DRIVER_PROTOCOL: []const u8 = "doe.csl.simulator/v1";
pub const SIMULATOR_DRIVER_ENV_VAR: []const u8 = "DOE_CSL_SIM_EXECUTABLE";
pub const SIMULATOR_RESULT_SCHEMA_VERSION: u32 = 1;
pub const SIMULATOR_RESULT_ARTIFACT_KIND: []const u8 = "csl_simulator_result";
pub const SIMULATOR_RESULT_TARGET: []const u8 = "wse3";
pub const SIMULATOR_RESULT_CONTRACT: []const u8 = "explicit_simulator_outcome";
pub const MEMORY_PLAN_SCHEMA_VERSION: u32 = 1;
pub const MEMORY_PLAN_ARTIFACT_KIND: []const u8 = "csl_memory_plan";
pub const MEMORY_PLAN_TARGET: []const u8 = "wse3";
pub const MEMORY_PLAN_CONTRACT: []const u8 = "explicit_memory_plan";
pub const RUNTIME_CONFIG_SCHEMA_VERSION: u32 = 1;
pub const RUNTIME_CONFIG_ARTIFACT_KIND: []const u8 = "csl_runtime_config";
pub const RUNTIME_CONFIG_TARGET: []const u8 = "wse3";
pub const RUNTIME_CONFIG_CONTRACT: []const u8 = "explicit_runtime_config";

// ---------------------------------------------------------------------------
// CSL scalar type names
// ---------------------------------------------------------------------------

pub fn scalarTypeName(scalar: @import("../../ir/ir.zig").ScalarType) []const u8 {
    return switch (scalar) {
        .void => "void",
        .bool => "bool",
        .i32, .abstract_int => "i32",
        .u32 => "u32",
        .f32, .abstract_float => "f32",
        .f16 => "f16",
    };
}

// ---------------------------------------------------------------------------
// Quantization format constants
// ---------------------------------------------------------------------------

/// Q4K super-block: 256 weights per block.
pub const Q4K_BLOCK_SIZE: u32 = 256;

/// Q4K block byte layout: 2 (d) + 2 (dmin) + 12 (scales) + 128 (nibbles) = 144.
pub const Q4K_BLOCK_BYTES: u32 = 144;

/// Q4K sub-blocks per super-block.
pub const Q4K_SUB_BLOCKS: u32 = 8;

/// Q4K elements per sub-block.
pub const Q4K_SUB_BLOCK_SIZE: u32 = 32;

/// Q8_0 block: 32 weights per block.
pub const Q8_0_BLOCK_SIZE: u32 = 32;

/// Q8_0 block byte layout: 2 (scale f16) + 32 (i8 quants) = 34.
pub const Q8_0_BLOCK_BYTES: u32 = 34;

/// Validate that a weight buffer size is consistent with Q4K format.
/// Returns null if valid, or an error message.
pub fn validateQ4kBufferSize(byte_count: u64) ?[]const u8 {
    if (byte_count == 0) return "Q4K buffer size is zero";
    if (byte_count % Q4K_BLOCK_BYTES != 0) return "Q4K buffer size not a multiple of block size (144)";
    return null;
}

/// Validate that a weight buffer size is consistent with Q8_0 format.
pub fn validateQ8_0BufferSize(byte_count: u64) ?[]const u8 {
    if (byte_count == 0) return "Q8_0 buffer size is zero";
    if (byte_count % Q8_0_BLOCK_BYTES != 0) return "Q8_0 buffer size not a multiple of block size (34)";
    return null;
}

/// Compute the number of dequantized elements from a Q4K buffer size.
pub fn q4kElementCount(byte_count: u64) ?u64 {
    if (byte_count % Q4K_BLOCK_BYTES != 0) return null;
    return (byte_count / Q4K_BLOCK_BYTES) * Q4K_BLOCK_SIZE;
}

/// Compute the number of dequantized elements from a Q8_0 buffer size.
pub fn q8_0ElementCount(byte_count: u64) ?u64 {
    if (byte_count % Q8_0_BLOCK_BYTES != 0) return null;
    return (byte_count / Q8_0_BLOCK_BYTES) * Q8_0_BLOCK_SIZE;
}

// ---------------------------------------------------------------------------
// Fabric DSD type names
// ---------------------------------------------------------------------------

pub const FABIN_DSD: []const u8 = "fabin_dsd";
pub const FABOUT_DSD: []const u8 = "fabout_dsd";
pub const MEM1D_DSD: []const u8 = "mem1d_dsd";
pub const MEM4D_DSD: []const u8 = "mem4d_dsd";

// ---------------------------------------------------------------------------
// Structural validation
// ---------------------------------------------------------------------------

pub const ValidationError = struct {
    message: []const u8,
};

/// Validate structural correctness of emitted CSL output.
/// Returns null if valid, or a ValidationError describing the problem.
/// This is a static check — it validates structure, not semantics.
/// Full semantic validation requires the `cslc` compiler.
pub fn validateOutput(csl: []const u8) ?ValidationError {
    const std = @import("std");

    const required_markers = [_]struct { marker: []const u8, message: []const u8 }{
        .{ .marker = LAYOUT_FILENAME, .message = "missing layout.csl section" },
        .{ .marker = PE_PROGRAM_FILENAME, .message = "missing pe_program.csl section" },
        .{ .marker = "@set_rectangle", .message = "layout missing @set_rectangle" },
        .{ .marker = "<memcpy/memcpy>", .message = "PE program missing memcpy import" },
        .{ .marker = "@export_symbol(compute)", .message = "PE program missing @export_symbol(compute)" },
    };
    for (required_markers) |entry| {
        if (std.mem.indexOf(u8, csl, entry.marker) == null) {
            return .{ .message = entry.message };
        }
    }

    // PE program must have sys_mod.unblock_cmd_stream() or @activate for exit.
    const has_unblock = std.mem.indexOf(u8, csl, "unblock_cmd_stream") != null;
    const has_exit_task = std.mem.indexOf(u8, csl, "exit_task") != null;
    if (!has_unblock and !has_exit_task) {
        return .{ .message = "PE program missing completion signal (unblock_cmd_stream or exit_task)" };
    }

    // Check for balanced braces (basic syntax sanity).
    var brace_depth: i32 = 0;
    for (csl) |ch| {
        if (ch == '{') brace_depth += 1;
        if (ch == '}') brace_depth -= 1;
        if (brace_depth < 0) {
            return .{ .message = "unbalanced closing brace" };
        }
    }
    if (brace_depth != 0) {
        return .{ .message = "unbalanced braces" };
    }

    // Check that layout section comes before PE program section.
    const layout_pos = std.mem.indexOf(u8, csl, LAYOUT_FILENAME) orelse 0;
    const pe_pos = std.mem.indexOf(u8, csl, PE_PROGRAM_FILENAME) orelse 0;
    if (pe_pos <= layout_pos) {
        return .{ .message = "layout.csl must precede pe_program.csl" };
    }

    return null;
}

test "Q4K validation accepts valid sizes" {
    const std_test = @import("std").testing;
    try std_test.expect(validateQ4kBufferSize(144) == null);
    try std_test.expect(validateQ4kBufferSize(144 * 10) == null);
    try std_test.expect(validateQ4kBufferSize(0) != null);
    try std_test.expect(validateQ4kBufferSize(143) != null);
    try std_test.expect(validateQ4kBufferSize(145) != null);
}

test "Q4K element count" {
    const std_test = @import("std").testing;
    try std_test.expectEqual(@as(u64, 256), q4kElementCount(144).?);
    try std_test.expectEqual(@as(u64, 2560), q4kElementCount(1440).?);
    try std_test.expect(q4kElementCount(143) == null);
}

test "Q8_0 validation accepts valid sizes" {
    const std_test = @import("std").testing;
    try std_test.expect(validateQ8_0BufferSize(34) == null);
    try std_test.expect(validateQ8_0BufferSize(34 * 5) == null);
    try std_test.expect(validateQ8_0BufferSize(0) != null);
    try std_test.expect(validateQ8_0BufferSize(33) != null);
}
