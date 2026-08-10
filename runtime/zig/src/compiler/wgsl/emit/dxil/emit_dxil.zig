//! DXIL emission: native Zig DXIL bytecode generation with optional DXC fallback.
//!
//! The primary path generates DXIL bytecode natively from the Doe IR using the
//! dxil_builder/dxil_serialize/dxil_container modules. No external toolchain is
//! required. The DXC fallback path remains available via `emitWithToolchainConfig`
//! for validation against the reference compiler.
//!
//! Environment variable: `DOE_WGSL_DXC`
//!   - Unset or absent  → native emission (no external tool needed)
//!   - Set to `PATH`    → explicit system PATH lookup for DXC fallback
//!   - Set to a path    → use that DXC binary for fallback compilation
//!   - Set but empty    → `ShaderToolchainUnavailable` (explicit misconfiguration)

const builtin = @import("builtin");
const std = @import("std");
const ir = @import("../../ir/ir.zig");
const toolchain = @import("../toolchain.zig");
const emit_hlsl = @import("../hlsl/emit_hlsl.zig");
const emit_dxil_native = @import("emit_dxil_native.zig");
const dxil_validate = @import("dxil_validate.zig");

pub const MAX_OUTPUT: usize = 256 * 1024;
pub const DXC_ENV_VAR: []const u8 = "DOE_WGSL_DXC";
pub const DXC_PATH_SENTINEL: []const u8 = "PATH";

const DXIL_CACHE_DIR: []const u8 = ".zig-cache/doe_wgsl_dxil";
const MAX_DXC_OUTPUT_BYTES: usize = 64 * 1024;
const LAST_ERROR_CAP: usize = 1024;

pub const Error = error{
    OutputTooLarge,
    InvalidIr,
    UnsupportedBuiltin,
    UnsupportedConstruct,
    OutOfMemory,
    ShaderToolchainUnavailable,
};

pub const ShaderModel = struct {
    major: u8 = 6,
    minor: u8 = 0,
};

pub const Stage = enum {
    compute,
    vertex,
    fragment,
};

pub const EntryPoint = struct {
    stage: Stage = .compute,
    name: []const u8 = "main",
    workgroup_size: [3]u32 = .{ 1, 1, 1 },
};

pub const Module = struct {
    shader_model: ShaderModel = .{},
    entry_point: EntryPoint = .{},
};

pub const ToolchainDiscovery = toolchain.Discovery;
pub const ToolchainConfig = toolchain.Config;

var last_error_buf: [LAST_ERROR_CAP]u8 = undefined;
var last_error_len: usize = 0;

pub fn lastErrorMessage() []const u8 {
    return last_error_buf[0..last_error_len];
}

pub fn lower(module: *const ir.Module) Error!Module {
    if (module.entry_points.items.len == 0) return error.InvalidIr;
    const entry = module.entry_points.items[0];
    const function = module.functions.items[entry.function];
    return .{
        .entry_point = .{
            .stage = switch (entry.stage) {
                .compute => .compute,
                .vertex => .vertex,
                .fragment => .fragment,
            },
            .name = function.name,
            .workgroup_size = entry.workgroup_size,
        },
    };
}

/// Primary DXIL emission path: generates DXIL natively from the Doe IR.
pub fn emit(module: *const ir.Module, out: []u8) Error!usize {
    clearLastError();
    const len = try emit_dxil_native.emit(module, out);
    try validateOutput(out[0..len], "native emitter");
    return len;
}

/// DXC fallback path: generates HLSL, then invokes DXC to compile to DXIL.
pub fn emitWithToolchainConfig(module: *const ir.Module, out: []u8, config: ToolchainConfig) Error!usize {
    clearLastError();
    if (config.executable.len == 0) {
        setLastErrorFmt(
            "DXC executable path is empty; pass ToolchainConfig{{ .executable = ... }} or set {s} to a DXC path or {s}",
            .{ DXC_ENV_VAR, DXC_PATH_SENTINEL },
        );
        return error.ShaderToolchainUnavailable;
    }

    const lowered = try lower(module);
    var hlsl_buf: [emit_hlsl.MAX_OUTPUT]u8 = undefined;
    const hlsl_len = emit_hlsl.emit(module, &hlsl_buf) catch |err| switch (err) {
        error.OutputTooLarge => return error.OutputTooLarge,
        error.InvalidIr => return error.InvalidIr,
        error.UnsupportedBuiltin => return error.UnsupportedBuiltin,
    };

    const alloc = std.heap.page_allocator;
    std.fs.cwd().makePath(DXIL_CACHE_DIR) catch return error.InvalidIr;
    const nonce = std.time.nanoTimestamp();
    const hlsl_path = try std.fmt.allocPrint(alloc, "{s}/{d}.hlsl", .{ DXIL_CACHE_DIR, nonce });
    defer alloc.free(hlsl_path);
    const dxil_path = try std.fmt.allocPrint(alloc, "{s}/{d}.dxil", .{ DXIL_CACHE_DIR, nonce });
    defer alloc.free(dxil_path);
    defer std.fs.cwd().deleteFile(hlsl_path) catch {};
    defer std.fs.cwd().deleteFile(dxil_path) catch {};

    std.fs.cwd().writeFile(.{ .sub_path = hlsl_path, .data = hlsl_buf[0..hlsl_len] }) catch |err| {
        setLastErrorFmt("failed to write temporary HLSL input `{s}`: {s}", .{ hlsl_path, @errorName(err) });
        return error.InvalidIr;
    };
    try runDxc(alloc, hlsl_path, dxil_path, lowered, config);

    const bytes = std.fs.cwd().readFileAlloc(alloc, dxil_path, MAX_OUTPUT) catch |err| switch (err) {
        error.FileNotFound => {
            setLastErrorFmt(
                "DXC reported success via {s} `{s}` but did not write `{s}`",
                .{ toolchain.discoveryLabel(config.discovery), config.executable, dxil_path },
            );
            return error.InvalidIr;
        },
        error.FileTooBig => {
            setLastErrorFmt("DXIL output `{s}` exceeded the {d}-byte contract", .{ dxil_path, MAX_OUTPUT });
            return error.OutputTooLarge;
        },
        else => {
            setLastErrorFmt("failed to read DXIL output `{s}`: {s}", .{ dxil_path, @errorName(err) });
            return error.InvalidIr;
        },
    };
    defer alloc.free(bytes);
    if (bytes.len > out.len) return error.OutputTooLarge;
    try validateOutput(bytes, "DXC");
    @memcpy(out[0..bytes.len], bytes);
    return bytes.len;
}

fn validateOutput(bytes: []const u8, producer: []const u8) Error!void {
    const result = dxil_validate.validate(bytes);
    if (result.valid) return;
    setLastErrorFmt(
        "{s} produced a structurally invalid DXIL container: {s}",
        .{ producer, result.error_message orelse "unknown validation failure" },
    );
    return error.InvalidIr;
}

pub fn loadToolchainConfig(alloc: std.mem.Allocator) Error!ToolchainConfig {
    clearLastError();
    const env_value = std.process.getEnvVarOwned(alloc, DXC_ENV_VAR) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return .{
            .executable = defaultDxcExecutable(),
            .discovery = .implicit_path_lookup,
        },
        else => {
            setLastErrorFmt("failed to read {s}: {s}", .{ DXC_ENV_VAR, @errorName(err) });
            return error.ShaderToolchainUnavailable;
        },
    };
    errdefer alloc.free(env_value);
    return toolchainConfigFromEnvValue(alloc, env_value);
}

fn toolchainConfigFromEnvValue(alloc: std.mem.Allocator, raw_value: []const u8) Error!ToolchainConfig {
    clearLastError();
    const owned = try alloc.dupe(u8, raw_value);
    errdefer alloc.free(owned);

    const trimmed = std.mem.trim(u8, owned, " \t\r\n");
    if (trimmed.len == 0) {
        setLastErrorFmt(
            "{s} is set but empty; set it to a DXC path or `{s}` to opt into PATH lookup explicitly",
            .{ DXC_ENV_VAR, DXC_PATH_SENTINEL },
        );
        return error.ShaderToolchainUnavailable;
    }

    if (std.ascii.eqlIgnoreCase(trimmed, DXC_PATH_SENTINEL)) {
        return .{
            .executable = defaultDxcExecutable(),
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

fn runDxc(
    alloc: std.mem.Allocator,
    input_path: []const u8,
    output_path: []const u8,
    lowered: Module,
    config: ToolchainConfig,
) Error!void {
    var profile_buf: [16]u8 = undefined;
    const profile = std.fmt.bufPrint(&profile_buf, "{s}_{d}_{d}", .{
        switch (lowered.entry_point.stage) {
            .compute => "cs",
            .vertex => "vs",
            .fragment => "ps",
        },
        lowered.shader_model.major,
        lowered.shader_model.minor,
    }) catch return error.InvalidIr;
    const argv = [_][]const u8{
        config.executable,
        "-T",
        profile,
        "-E",
        lowered.entry_point.name,
        "-Fo",
        output_path,
        input_path,
    };
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &argv,
        .max_output_bytes = MAX_DXC_OUTPUT_BYTES,
    }) catch |err| return switch (err) {
        error.FileNotFound => {
            setMissingToolchainError(config);
            return error.ShaderToolchainUnavailable;
        },
        else => {
            setLastErrorFmt(
                "failed to start DXC via {s} `{s}`: {s}",
                .{ toolchain.discoveryLabel(config.discovery), config.executable, @errorName(err) },
            );
            return error.ShaderToolchainUnavailable;
        },
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                const detail = toolchain.diagnosticOutput(result.stderr, result.stdout);
                if (detail.len == 0) {
                    setLastErrorFmt(
                        "DXC failed via {s} `{s}` with exit code {d} for profile `{s}` and entry `{s}`",
                        .{ toolchain.discoveryLabel(config.discovery), config.executable, code, profile, lowered.entry_point.name },
                    );
                } else {
                    setLastErrorFmt(
                        "DXC failed via {s} `{s}` with exit code {d} for profile `{s}` and entry `{s}`: {s}",
                        .{ toolchain.discoveryLabel(config.discovery), config.executable, code, profile, lowered.entry_point.name, detail },
                    );
                }
                return error.InvalidIr;
            }
        },
        else => {
            setLastErrorFmt(
                "DXC terminated unexpectedly via {s} `{s}` for profile `{s}` and entry `{s}`",
                .{ toolchain.discoveryLabel(config.discovery), config.executable, profile, lowered.entry_point.name },
            );
            return error.InvalidIr;
        },
    }
}

fn setMissingToolchainError(config: ToolchainConfig) void {
    switch (config.discovery) {
        .explicit_config => setLastErrorFmt(
            "DXC executable from explicit DXIL toolchain config was not found at `{s}`; pass a valid ToolchainConfig path or set {s} to a valid DXC path",
            .{ config.executable, DXC_ENV_VAR },
        ),
        .env_path => setLastErrorFmt(
            "{s} points to `{s}`, but that DXC executable was not found; fix {s} or use `{s}` to opt into PATH lookup",
            .{ DXC_ENV_VAR, config.executable, DXC_ENV_VAR, DXC_PATH_SENTINEL },
        ),
        .env_path_lookup => setLastErrorFmt(
            "{s}={s} requested explicit PATH lookup, but `{s}` was not found on PATH",
            .{ DXC_ENV_VAR, DXC_PATH_SENTINEL, config.executable },
        ),
        .implicit_path_lookup => setLastErrorFmt(
            "DXC was not found on PATH (`{s}`); set {s} to an absolute/workspace-relative DXC path or `{s}` to make PATH lookup explicit",
            .{ config.executable, DXC_ENV_VAR, DXC_PATH_SENTINEL },
        ),
    }
}

fn clearLastError() void {
    last_error_len = 0;
}

fn setLastErrorFmt(comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.bufPrint(last_error_buf[0..], fmt, args) catch {
        last_error_len = 0;
        return;
    };
    last_error_len = text.len;
}

fn defaultDxcExecutable() []const u8 {
    return if (builtin.os.tag == .windows) "dxc.exe" else "dxc";
}

test "toolchain config parses explicit env contract" {
    const alloc = std.testing.allocator;

    {
        var config = try toolchainConfigFromEnvValue(alloc, DXC_PATH_SENTINEL);
        defer config.deinit(alloc);
        try std.testing.expectEqual(ToolchainDiscovery.env_path_lookup, config.discovery);
        try std.testing.expectEqualStrings(defaultDxcExecutable(), config.executable);
    }

    {
        var config = try toolchainConfigFromEnvValue(alloc, "/opt/dxc/bin/dxc");
        defer config.deinit(alloc);
        try std.testing.expectEqual(ToolchainDiscovery.env_path, config.discovery);
        try std.testing.expectEqualStrings("/opt/dxc/bin/dxc", config.executable);
    }
}

test "toolchain config rejects empty env override with detail" {
    try std.testing.expectError(error.ShaderToolchainUnavailable, toolchainConfigFromEnvValue(std.testing.allocator, "   "));
    try std.testing.expect(std.mem.indexOf(u8, lastErrorMessage(), DXC_ENV_VAR) != null);
    try std.testing.expect(std.mem.indexOf(u8, lastErrorMessage(), DXC_PATH_SENTINEL) != null);
}
