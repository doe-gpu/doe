// mod_dxil_test.zig — DXIL toolchain and translation contract tests.

const builtin = @import("builtin");
const std = @import("std");
const mod = @import("../../src/compiler/wgsl/mod.zig");
const translateToDxil = mod.translateToDxil;
const translateToDxilWithToolchainConfig = mod.translateToDxilWithToolchainConfig;
const TranslateError = mod.TranslateError;
const CompilationStage = mod.CompilationStage;
const DXIL_DXC_ENV_VAR = mod.DXIL_DXC_ENV_VAR;
const lastErrorStage = mod.lastErrorStage;
const lastErrorMessage = mod.lastErrorMessage;
const DxilToolchainConfig = mod.DxilToolchainConfig;
const MAX_DXIL_OUTPUT = mod.MAX_DXIL_OUTPUT;

fn writeFakeDxcScript(dir: std.fs.Dir, sub_path: []const u8) !void {
    var file = try dir.createFile(sub_path, .{ .read = true, .truncate = true });
    defer file.close();
    try file.writeAll(
        \\#!/bin/sh
        \\out=""
        \\while [ "$#" -gt 0 ]; do
        \\  if [ "$1" = "-Fo" ]; then
        \\    shift
        \\    out="$1"
        \\  fi
        \\  shift
        \\done
        \\if [ -z "$out" ]; then
        \\  echo "missing -Fo output path" >&2
        \\  exit 91
        \\fi
        \\printf 'FAKE-DXIL' > "$out"
        \\
    );
    try file.chmod(0o755);
}

test "translate DXIL with explicit fake toolchain config" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = 1.0;
        \\}
    ;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try writeFakeDxcScript(tmp_dir.dir, "fake_dxc.sh");

    const script_path = try std.fs.path.join(std.testing.allocator, &.{
        ".zig-cache",
        "tmp",
        tmp_dir.sub_path[0..],
        "fake_dxc.sh",
    });
    defer std.testing.allocator.free(script_path);

    var out: [MAX_DXIL_OUTPUT]u8 = undefined;
    const len = try translateToDxilWithToolchainConfig(std.testing.allocator, source, &out, DxilToolchainConfig{
        .executable = script_path,
        .discovery = .explicit_config,
    });
    try std.testing.expectEqualStrings("FAKE-DXIL", out[0..len]);
}

test "translate DXIL reports explicit missing toolchain config path" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = 1.0;
        \\}
    ;

    var out: [MAX_DXIL_OUTPUT]u8 = undefined;
    try std.testing.expectError(TranslateError.ShaderToolchainUnavailable, translateToDxilWithToolchainConfig(
        std.testing.allocator,
        source,
        &out,
        DxilToolchainConfig{
            .executable = "zig-out/does-not-exist/dxc",
            .discovery = .explicit_config,
        },
    ));
    try std.testing.expectEqual(CompilationStage.dxil_emit, lastErrorStage());
    try std.testing.expect(std.mem.indexOf(u8, lastErrorMessage(), "zig-out/does-not-exist/dxc") != null);
    try std.testing.expect(std.mem.indexOf(u8, lastErrorMessage(), DXIL_DXC_ENV_VAR) != null);
}

test "translate compute shader to DXIL or report missing toolchain" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = 1.0;
        \\}
    ;

    var out: [MAX_DXIL_OUTPUT]u8 = undefined;
    const len = translateToDxil(std.testing.allocator, source, &out) catch |err| switch (err) {
        TranslateError.ShaderToolchainUnavailable => {
            try std.testing.expectEqual(CompilationStage.dxil_emit, lastErrorStage());
            try std.testing.expect(std.mem.indexOf(u8, lastErrorMessage(), DXIL_DXC_ENV_VAR) != null);
            return;
        },
        else => return err,
    };
    try std.testing.expect(len > 0);
}

test "translate vertex shader to DXIL or report missing toolchain" {
    const source =
        \\@vertex
        \\fn main(@location(0) uv: vec2f) -> @builtin(position) vec4f {
        \\    return vec4f(uv, 0.0, 1.0);
        \\}
    ;

    var out: [MAX_DXIL_OUTPUT]u8 = undefined;
    const len = translateToDxil(std.testing.allocator, source, &out) catch |err| switch (err) {
        TranslateError.ShaderToolchainUnavailable => {
            try std.testing.expectEqual(CompilationStage.dxil_emit, lastErrorStage());
            try std.testing.expect(std.mem.indexOf(u8, lastErrorMessage(), DXIL_DXC_ENV_VAR) != null);
            return;
        },
        else => return err,
    };
    try std.testing.expect(len > 0);
}
