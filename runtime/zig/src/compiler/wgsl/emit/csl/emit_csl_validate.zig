// emit_csl_validate.zig — Pattern-specific CSL output validation and opt-in
// cslc toolchain checks.
//
// The structural validator stays deterministic and fake-tool-friendly. The
// opt-in toolchain lane mirrors the DXIL config flow: explicit config,
// environment-backed discovery, and a PATH sentinel for explicit lookup.

const builtin = @import("builtin");
const std = @import("std");
const spec = @import("csl_spec.zig");

pub const Error = error{
    OutputTooLarge,
    InvalidIr,
    OutOfMemory,
    ShaderToolchainUnavailable,
};

pub const CSLC_ENV_VAR: []const u8 = "DOE_WGSL_CSLC";
pub const CSLC_PATH_SENTINEL: []const u8 = "PATH";

const MAX_ERRORS: usize = 16;
const LAST_ERROR_CAP: usize = 1024;
const MAX_CSLC_OUTPUT_BYTES: usize = 64 * 1024;

pub const ToolchainDiscovery = enum {
    explicit_config,
    env_path,
    env_path_lookup,
    implicit_path_lookup,
};

pub const ToolchainConfig = struct {
    executable: []const u8,
    discovery: ToolchainDiscovery = .explicit_config,
    owned_value: ?[]u8 = null,

    pub fn deinit(self: *ToolchainConfig, alloc: std.mem.Allocator) void {
        if (self.owned_value) |value| {
            alloc.free(value);
            self.owned_value = null;
        }
    }
};

pub const ValidationResult = struct {
    valid: bool,
    errors: [MAX_ERRORS][]const u8,
    error_count: u32,

    pub fn ok() ValidationResult {
        return .{ .valid = true, .errors = undefined, .error_count = 0 };
    }

    pub fn firstError(self: ValidationResult) ?[]const u8 {
        if (self.error_count == 0) return null;
        return self.errors[0];
    }
};

var last_error_buf: [LAST_ERROR_CAP]u8 = undefined;
var last_error_len: usize = 0;

pub fn lastErrorMessage() []const u8 {
    return last_error_buf[0..last_error_len];
}

pub fn loadToolchainConfig(alloc: std.mem.Allocator) Error!ToolchainConfig {
    clearLastError();
    const env_value = std.process.getEnvVarOwned(alloc, CSLC_ENV_VAR) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return .{
            .executable = defaultCslcExecutable(),
            .discovery = .implicit_path_lookup,
        },
        else => {
            setLastErrorFmt("failed to read {s}: {s}", .{ CSLC_ENV_VAR, @errorName(err) });
            return error.ShaderToolchainUnavailable;
        },
    };
    errdefer alloc.free(env_value);
    return toolchainConfigFromEnvValue(alloc, env_value);
}

pub fn toolchainConfigFromEnvValue(alloc: std.mem.Allocator, raw_value: []const u8) Error!ToolchainConfig {
    clearLastError();
    const owned = try alloc.dupe(u8, raw_value);
    errdefer alloc.free(owned);

    const trimmed = std.mem.trim(u8, owned, " \t\r\n");
    if (trimmed.len == 0) {
        setLastErrorFmt(
            "{s} is set but empty; set it to a cslc path or `{s}` to opt into PATH lookup explicitly",
            .{ CSLC_ENV_VAR, CSLC_PATH_SENTINEL },
        );
        return error.ShaderToolchainUnavailable;
    }

    if (std.ascii.eqlIgnoreCase(trimmed, CSLC_PATH_SENTINEL)) {
        return .{
            .executable = defaultCslcExecutable(),
            .discovery = .env_path_lookup,
            .owned_value = owned,
        };
    }

    return .{
        .executable = trimmed,
        .discovery = .env_path,
        .owned_value = owned,
    };
}

pub fn validatePattern(csl: []const u8, pattern: PatternKind) ValidationResult {
    clearLastError();
    var result = ValidationResult.ok();

    if (spec.validateOutput(csl)) |base_err| {
        addError(&result, base_err.message);
        return result;
    }
    validateSdk210Compatibility(csl, &result);
    if (!result.valid) return result;

    switch (pattern) {
        .element_wise => validateElementWise(csl, &result),
        .reduction => validateReduction(csl, &result),
        .gather => validateGather(csl, &result),
        .attention_decode => validateAttention(csl, &result),
        .attention_tiled => validateAttention(csl, &result),
        .attention_linear => validateAttention(csl, &result),
        .attention_streaming => validateAttention(csl, &result),
        .tiled_matmul => validateTiledMatmul(csl, &result),
        .tiled_matmul_q4k_dequant_b => validateTiledMatmulQ4k(csl, &result),
        .fused_gemv_dequant => validateFusedGemvDequant(csl, &result),
        .dense_gemv => validateDenseGemv(csl, &result),
        .dequant => validateDequant(csl, &result),
        .rope => validateRope(csl, &result),
        .sample => validateSample(csl, &result),
        .kv_write => validateKvWrite(csl, &result),
        .kv_read => validateKvRead(csl, &result),
        .fused_ffn => validateFusedFfn(csl, &result),
    }

    result.valid = result.error_count == 0;
    return result;
}

pub fn validatePatternWithToolchainConfig(
    csl: []const u8,
    pattern: PatternKind,
    config: ToolchainConfig,
) Error!ValidationResult {
    const result = validatePattern(csl, pattern);
    if (!result.valid) return result;
    try validateToolchainConfig(config);
    return result;
}

pub fn validateToolchainConfig(config: ToolchainConfig) Error!void {
    clearLastError();
    if (config.executable.len == 0) {
        setLastErrorFmt(
            "cslc executable path is empty; pass ToolchainConfig{{ .executable = ... }} or set {s} to a cslc path or {s}",
            .{ CSLC_ENV_VAR, CSLC_PATH_SENTINEL },
        );
        return error.ShaderToolchainUnavailable;
    }

    const alloc = std.heap.page_allocator;
    const argv = [_][]const u8{ config.executable, "--version" };
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &argv,
        .max_output_bytes = MAX_CSLC_OUTPUT_BYTES,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            setMissingToolchainError(config);
            return error.ShaderToolchainUnavailable;
        },
        else => {
            setLastErrorFmt(
                "failed to start cslc via {s} `{s}`: {s}",
                .{ discoveryLabel(config.discovery), config.executable, @errorName(err) },
            );
            return error.ShaderToolchainUnavailable;
        },
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                const detail = trimmedDiagnostic(result.stderr, result.stdout);
                if (detail.len == 0) {
                    setLastErrorFmt(
                        "cslc failed via {s} `{s}` with exit code {d}",
                        .{ discoveryLabel(config.discovery), config.executable, code },
                    );
                } else {
                    setLastErrorFmt(
                        "cslc failed via {s} `{s}` with exit code {d}: {s}",
                        .{ discoveryLabel(config.discovery), config.executable, code, detail },
                    );
                }
                return error.InvalidIr;
            }
        },
        else => {
            setLastErrorFmt(
                "cslc terminated unexpectedly via {s} `{s}`",
                .{ discoveryLabel(config.discovery), config.executable },
            );
            return error.InvalidIr;
        },
    }
}

pub const PatternKind = enum {
    element_wise,
    reduction,
    gather,
    attention_decode,
    attention_tiled,
    attention_linear,
    attention_streaming,
    tiled_matmul,
    tiled_matmul_q4k_dequant_b,
    fused_gemv_dequant,
    dense_gemv,
    dequant,
    rope,
    sample,
    kv_write,
    kv_read,
    fused_ffn,
};

fn validateElementWise(csl: []const u8, result: *ValidationResult) void {
    if (std.mem.indexOf(u8, csl, "fabin_dsd") != null) {
        addError(result, "element_wise pattern should not use fabric input DSDs");
    }
    if (std.mem.indexOf(u8, csl, "fabout_dsd") != null) {
        addError(result, "element_wise pattern should not use fabric output DSDs");
    }
    requireContains(csl, result, "@range", "element_wise missing compute loop (@range)");
}

fn validateReduction(csl: []const u8, result: *ValidationResult) void {
    // Two admissible reduction shapes map to the same PatternKind:
    //
    //   1. Distributed reduction (info.distributed == true) — reduces
    //      across the fabric via reduce_out_dsd / bcast_out_dsd. Emitted
    //      by emit_csl_reduce_dist.zig and ships both fabin_dsd and
    //      fabout_dsd declarations in the PE program.
    //
    //   2. Workgroup-local reduction (info.distributed == false) — one
    //      workgroup per PE, shared memory becomes PE-local. Emitted by
    //      emit_csl_reduction.zig; the marker comment
    //      `// Workgroup shared → PE-local` is written by
    //      emit_csl_ir_walk.workgroupBuffers when the kernel has any
    //      workgroup-space global.
    //
    // Requiring both fabric DSDs unconditionally would reject legitimate
    // workgroup-local reductions (rmsnorm-shape, reduce-sum-workgroup).
    // Accept either shape — but insist on something that signals this is
    // a reduction rather than an accidentally-empty emission.
    const has_distributed = std.mem.indexOf(u8, csl, "fabout_dsd") != null and
        std.mem.indexOf(u8, csl, "fabin_dsd") != null;
    const has_local = std.mem.indexOf(u8, csl, "PE-local") != null;
    if (!has_distributed and !has_local) {
        addError(
            result,
            "reduction must emit either fabric DSDs (distributed) or a PE-local workgroup marker",
        );
    }
}

fn validateGather(csl: []const u8, result: *ValidationResult) void {
    requireContains(csl, result, "indices", "gather missing indices reference");
}

fn validateAttention(csl: []const u8, result: *ValidationResult) void {
    const has_qkv = std.mem.indexOf(u8, csl, "q_") != null or
        std.mem.indexOf(u8, csl, "query") != null or
        std.mem.indexOf(u8, csl, "key") != null;
    if (!has_qkv) {
        addError(result, "attention pattern missing Q/K/V buffer references");
    }
    const has_sliding = std.mem.indexOf(u8, csl, "decode_sliding_window") != null;
    const has_pos = std.mem.indexOf(u8, csl, "decode_position") != null;
    if (has_sliding and !has_pos) {
        addError(result, "attention with sliding window state must also declare decode position state");
    }
}

fn validateTiledMatmul(csl: []const u8, result: *ValidationResult) void {
    requireContains(csl, result, "accum", "tiled_matmul missing accumulator");
}

fn validateTiledMatmulQ4k(csl: []const u8, result: *ValidationResult) void {
    // SUMMA shape (same as f32 path) plus Q4K-specific markers.
    // The dequant_b_tile() prologue and the Q4K block-byte constant
    // must both appear or the emit is missing the wedge.
    requireContains(csl, result, "QK_K_BLOCK_BYTES", "tiled_matmul_q4k_dequant_b missing Q4K block-byte constant");
    requireContains(csl, result, "dequant_b_tile", "tiled_matmul_q4k_dequant_b missing dequant prologue");
    if (std.mem.indexOf(u8, csl, "var B_ptr: [*]f32") != null) {
        addError(result, "tiled_matmul_q4k_dequant_b must export B_ptr as [*]u8 byte stream, not f32");
    }
}

fn validateFusedGemvDequant(csl: []const u8, result: *ValidationResult) void {
    requireContains(csl, result, "dequant", "fused_gemv_dequant missing dequantization");
}

fn validateDenseGemv(csl: []const u8, result: *ValidationResult) void {
    requireContains(csl, result, "dense GEMV", "dense_gemv missing dense GEMV marker");
    requireContains(csl, result, "var partial: [out_dim_per_pe]f32", "dense_gemv missing separate f32 partial buffer");
    requireContains(csl, result, "param pe_y: i16;", "dense_gemv missing row coordinate parameter");
    requireContains(csl, result, "<collectives_2d/pe>", "dense_gemv missing collectives_2d PE import");
    requireContains(csl, result, "c2d_params", "dense_gemv missing collectives_2d params");
    requireContains(csl, result, "unblock_completion_row", "dense_gemv missing single-row command-stream completion guard");
    requireContains(csl, result, "reduce_fadds", "dense_gemv missing collectives_2d row reduction");
    requireContains(csl, result, "out_dim_per_pe", "dense_gemv missing output shard parameter");
    requireContains(csl, result, "[*]f32", "dense_gemv must export f32 logits");
    if (std.mem.indexOf(u8, csl, "@mov32(reduce_out, scratch_out_dsd") != null) {
        addError(result, "dense_gemv must use collectives_2d reduce_fadds, not the hand-rolled row-chain send");
    }
}

fn validateDequant(csl: []const u8, result: *ValidationResult) void {
    const has_q4k = std.mem.indexOf(u8, csl, "QK_K") != null or
        std.mem.indexOf(u8, csl, "Q4K") != null;
    if (!has_q4k) {
        addError(result, "dequant missing Q4K format constants");
    }
}

fn validateRope(csl: []const u8, result: *ValidationResult) void {
    const has_rotation = std.mem.indexOf(u8, csl, "cos") != null or
        std.mem.indexOf(u8, csl, "sin") != null;
    if (!has_rotation) {
        addError(result, "rope missing cos/sin rotation references");
    }
}

fn validateSample(csl: []const u8, result: *ValidationResult) void {
    requireContains(csl, result, "logit", "sample missing logits reference");
}

fn validateKvWrite(csl: []const u8, result: *ValidationResult) void {
    const has_cache = std.mem.indexOf(u8, csl, "cache") != null or
        std.mem.indexOf(u8, csl, "kv_") != null;
    if (!has_cache) {
        addError(result, "kv_write missing cache buffer reference");
    }
}

fn validateKvRead(csl: []const u8, result: *ValidationResult) void {
    const has_cache = std.mem.indexOf(u8, csl, "cache") != null or
        std.mem.indexOf(u8, csl, "kv_") != null;
    if (!has_cache) {
        addError(result, "kv_read missing cache buffer reference");
    }
}

fn validateFusedFfn(csl: []const u8, result: *ValidationResult) void {
    const has_activation = std.mem.indexOf(u8, csl, "silu") != null or
        std.mem.indexOf(u8, csl, "gelu") != null;
    if (!has_activation) {
        addError(result, "fused_ffn missing activation function (silu/gelu)");
    }
    requireContains(csl, result, "c2d_params", "fused_ffn missing collectives_2d params");
    requireContains(csl, result, "reduce_fadds", "fused_ffn missing collectives_2d vector reduction");
    if (std.mem.indexOf(u8, csl, "param reduce_color") != null or
        std.mem.indexOf(u8, csl, "@fmovs(reduce_out") != null)
    {
        addError(result, "fused_ffn must use collectives_2d reduce_fadds, not the hand-routed row-chain reduce");
    }
}

fn validateSdk210Compatibility(csl: []const u8, result: *ValidationResult) void {
    if (std.mem.indexOf(u8, csl, "comptime_struct") != null) {
        addError(result, "CSL SDK 2.10 removed comptime_struct; emit untyped params or named structs");
    }
    if (std.mem.indexOf(u8, csl, "@concat_struct") != null) {
        addError(result, "CSL SDK 2.10 removed @concat_struct/@concat_structs; emit named struct composition");
    }

    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, csl, cursor, "@get_dsd(fabout_dsd")) |start| {
        const tail = csl[start..];
        const end_rel = std.mem.indexOf(u8, tail, ");") orelse tail.len;
        const call = tail[0..end_rel];
        if (std.mem.indexOf(u8, call, ".fabric_color") != null) {
            addError(result, "CSL SDK 2.10 fabric DSDs use queue-color binding, not fabric_color");
            return;
        }
        if (std.mem.indexOf(u8, call, ".output_queue") == null) {
            addError(result, "CSL SDK 2.10 requires explicit output_queue for fabout_dsd");
            return;
        }
        cursor = start + end_rel + 1;
    }

    cursor = 0;
    while (std.mem.indexOfPos(u8, csl, cursor, "@get_dsd(fabin_dsd")) |start| {
        const tail = csl[start..];
        const end_rel = std.mem.indexOf(u8, tail, ");") orelse tail.len;
        const call = tail[0..end_rel];
        if (std.mem.indexOf(u8, call, ".fabric_color") != null) {
            addError(result, "CSL SDK 2.10 fabric DSDs use queue-color binding, not fabric_color");
            return;
        }
        if (std.mem.indexOf(u8, call, ".input_queue") == null) {
            addError(result, "CSL SDK 2.10 requires explicit input_queue for fabin_dsd");
            return;
        }
        cursor = start + end_rel + 1;
    }
}

fn requireContains(csl: []const u8, result: *ValidationResult, needle: []const u8, msg: []const u8) void {
    if (std.mem.indexOf(u8, csl, needle) == null) {
        addError(result, msg);
    }
}

fn addError(result: *ValidationResult, msg: []const u8) void {
    if (result.error_count < MAX_ERRORS) {
        result.errors[result.error_count] = msg;
        result.error_count += 1;
        result.valid = false;
    }
}

fn clearLastError() void {
    last_error_len = 0;
}

fn setMissingToolchainError(config: ToolchainConfig) void {
    switch (config.discovery) {
        .explicit_config => setLastErrorFmt(
            "cslc executable from explicit CSL toolchain config was not found at `{s}`; pass a valid ToolchainConfig path or set {s} to a valid cslc path",
            .{ config.executable, CSLC_ENV_VAR },
        ),
        .env_path => setLastErrorFmt(
            "{s} points to `{s}`, but that cslc executable was not found; fix {s} or use `{s}` to opt into PATH lookup",
            .{ CSLC_ENV_VAR, config.executable, CSLC_ENV_VAR, CSLC_PATH_SENTINEL },
        ),
        .env_path_lookup => setLastErrorFmt(
            "{s}={s} requested explicit PATH lookup, but `{s}` was not found on PATH",
            .{ CSLC_ENV_VAR, CSLC_PATH_SENTINEL, config.executable },
        ),
        .implicit_path_lookup => setLastErrorFmt(
            "cslc was not found on PATH (`{s}`); set {s} to an absolute/workspace-relative cslc path or `{s}` to make PATH lookup explicit",
            .{ config.executable, CSLC_ENV_VAR, CSLC_PATH_SENTINEL },
        ),
    }
}

fn setLastErrorFmt(comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.bufPrint(last_error_buf[0..], fmt, args) catch {
        last_error_len = 0;
        return;
    };
    last_error_len = text.len;
}

fn defaultCslcExecutable() []const u8 {
    return if (builtin.os.tag == .windows) "cslc.exe" else "cslc";
}

fn discoveryLabel(discovery: ToolchainDiscovery) []const u8 {
    return switch (discovery) {
        .explicit_config => "explicit-config",
        .env_path => "environment-path",
        .env_path_lookup => "environment-PATH",
        .implicit_path_lookup => "implicit-PATH",
    };
}

fn trimmedDiagnostic(stderr: []const u8, stdout: []const u8) []const u8 {
    const trimmed_stderr = std.mem.trim(u8, stderr, " \t\r\n");
    if (trimmed_stderr.len != 0) return trimmed_stderr;
    return std.mem.trim(u8, stdout, " \t\r\n");
}

test "element_wise pattern rejects fabric usage" {
    const csl =
        \\//--- layout.csl ---
        \\@set_rectangle(16, 1)
        \\//--- pe_program.csl ---
        \\const sys = @import_module("<memcpy/memcpy>", .{});
        \\fn compute() void { for (@range(u32, 64)) |i| { buf[i] += 1; } sys.unblock_cmd_stream(); }
        \\comptime { @export_symbol(compute); }
    ;
    const result = validatePattern(csl, .element_wise);
    try std.testing.expect(result.valid);
}

test "element_wise pattern catches fabric DSD" {
    const csl =
        \\//--- layout.csl ---
        \\@set_rectangle(16, 1)
        \\//--- pe_program.csl ---
        \\const sys = @import_module("<memcpy/memcpy>", .{});
        \\const in_q = @get_input_queue(2);
        \\var fab = @get_dsd(fabin_dsd, .{ .input_queue = in_q });
        \\fn compute() void { for (@range(u32, 64)) |i| { buf[i] += 1; } sys.unblock_cmd_stream(); }
        \\comptime { @export_symbol(compute); }
    ;
    const result = validatePattern(csl, .element_wise);
    try std.testing.expect(!result.valid);
    try std.testing.expect(result.error_count == 1);
}

test "reduction pattern rejects emission with neither fabric DSDs nor PE-local marker" {
    const csl_empty =
        \\//--- layout.csl ---
        \\@set_rectangle(16, 1)
        \\//--- pe_program.csl ---
        \\const sys = @import_module("<memcpy/memcpy>", .{});
        \\fn compute() void { sys.unblock_cmd_stream(); }
        \\comptime { @export_symbol(compute); }
    ;
    const result = validatePattern(csl_empty, .reduction);
    try std.testing.expect(!result.valid);
    try std.testing.expect(result.error_count >= 1);
}

test "reduction pattern accepts distributed-fabric shape" {
    const csl_dist =
        \\//--- layout.csl ---
        \\@set_rectangle(16, 1)
        \\//--- pe_program.csl ---
        \\const sys = @import_module("<memcpy/memcpy>", .{});
        \\const in_q = @get_input_queue(2);
        \\const out_q = @get_output_queue(2);
        \\const reduce_out_dsd = @get_dsd(fabout_dsd, .{ .output_queue = out_q });
        \\const reduce_in_dsd  = @get_dsd(fabin_dsd, .{ .input_queue = in_q });
        \\fn compute() void { sys.unblock_cmd_stream(); }
        \\comptime { @export_symbol(compute); }
    ;
    const result = validatePattern(csl_dist, .reduction);
    try std.testing.expect(result.valid);
}

test "sdk 2.10 validation rejects removed comptime_struct" {
    const csl =
        \\//--- layout.csl ---
        \\@set_rectangle(16, 1)
        \\//--- pe_program.csl ---
        \\param memcpy_params: comptime_struct;
        \\const sys = @import_module("<memcpy/memcpy>", .{});
        \\fn compute() void { sys.unblock_cmd_stream(); }
        \\comptime { @export_symbol(compute); }
    ;
    const result = validatePattern(csl, .element_wise);
    try std.testing.expect(!result.valid);
    try std.testing.expect(std.mem.indexOf(u8, result.firstError().?, "comptime_struct") != null);
}

test "sdk 2.10 validation rejects removed concat struct builtin" {
    const csl =
        \\//--- layout.csl ---
        \\@set_rectangle(16, 1)
        \\//--- pe_program.csl ---
        \\const sys = @import_module("<memcpy/memcpy>", .{});
        \\const params = @concat_structs(.{}, .{ .bar = 42 });
        \\fn compute() void { _ = params; sys.unblock_cmd_stream(); }
        \\comptime { @export_symbol(compute); }
    ;
    const result = validatePattern(csl, .element_wise);
    try std.testing.expect(!result.valid);
    try std.testing.expect(std.mem.indexOf(u8, result.firstError().?, "@concat_struct") != null);
}

test "sdk 2.10 validation rejects fabin_dsd without input_queue" {
    const csl =
        \\//--- layout.csl ---
        \\@set_rectangle(16, 1)
        \\//--- pe_program.csl ---
        \\const sys = @import_module("<memcpy/memcpy>", .{});
        \\const out_q = @get_output_queue(2);
        \\const reduce_out_dsd = @get_dsd(fabout_dsd, .{ .output_queue = out_q });
        \\const reduce_in_dsd = @get_dsd(fabin_dsd, .{ .extent = 1 });
        \\fn compute() void { sys.unblock_cmd_stream(); }
        \\comptime { @export_symbol(compute); }
    ;
    const result = validatePattern(csl, .reduction);
    try std.testing.expect(!result.valid);
    try std.testing.expect(std.mem.indexOf(u8, result.firstError().?, "input_queue") != null);
}

test "sdk 2.10 validation rejects fabric_color on fabric DSDs" {
    const csl =
        \\//--- layout.csl ---
        \\@set_rectangle(16, 1)
        \\//--- pe_program.csl ---
        \\const sys = @import_module("<memcpy/memcpy>", .{});
        \\const in_q = @get_input_queue(2);
        \\const reduce_in_dsd = @get_dsd(fabin_dsd, .{
        \\  .extent = 1,
        \\  .fabric_color = reduce_color,
        \\  .input_queue = in_q,
        \\});
        \\fn compute() void { sys.unblock_cmd_stream(); }
        \\comptime { @export_symbol(compute); }
    ;
    const result = validatePattern(csl, .reduction);
    try std.testing.expect(!result.valid);
    try std.testing.expect(std.mem.indexOf(u8, result.firstError().?, "fabric_color") != null);
}

test "reduction pattern accepts workgroup-local PE-local shape" {
    // reduce-sum-workgroup WGSL lowers to a local reduction: one
    // workgroup per PE, shared memory becomes PE-local. The emitter
    // writes a marker comment that is the validator's signal this is a
    // legitimate reduction, even without fabric DSDs.
    const csl_local =
        \\//--- layout.csl ---
        \\@set_rectangle(16, 1)
        \\//--- pe_program.csl ---
        \\const sys = @import_module("<memcpy/memcpy>", .{});
        \\// Workgroup shared → PE-local in single-PE mode.
        \\var scratch: [256]f32 = @as([256]f32, .{0.0} ** 256);
        \\fn compute() void { sys.unblock_cmd_stream(); }
        \\comptime { @export_symbol(compute); }
    ;
    const result = validatePattern(csl_local, .reduction);
    try std.testing.expect(result.valid);
}

test "dequant pattern requires Q4K constants" {
    const csl_with_q4k =
        \\//--- layout.csl ---
        \\@set_rectangle(16, 1)
        \\//--- pe_program.csl ---
        \\const sys = @import_module("<memcpy/memcpy>", .{});
        \\const QK_K: u32 = 256;
        \\fn compute() void { sys.unblock_cmd_stream(); }
        \\comptime { @export_symbol(compute); }
    ;
    const result = validatePattern(csl_with_q4k, .dequant);
    try std.testing.expect(result.valid);
}

test "base validation catches missing sections" {
    const bad_csl = "just some random text";
    const result = validatePattern(bad_csl, .element_wise);
    try std.testing.expect(!result.valid);
    try std.testing.expect(result.error_count == 1);
}
