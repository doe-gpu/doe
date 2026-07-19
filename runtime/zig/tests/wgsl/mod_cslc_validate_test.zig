const builtin = @import("builtin");
const std = @import("std");
const mod = @import("../../src/compiler/wgsl/mod.zig");

const csl_validate = mod.emit_csl_validate;

fn writeFakeCslcScript(dir: std.fs.Dir, sub_path: []const u8) !void {
    var file = try dir.createFile(sub_path, .{ .read = true, .truncate = true });
    defer file.close();
    try file.writeAll(
        \\#!/bin/sh
        \\if [ "$1" != "--version" ]; then
        \\  echo "unexpected args: $*" >&2
        \\  exit 91
        \\fi
        \\printf 'FAKE-CSLC 1.0\n'
        \\
    );
    try file.chmod(0o755);
}

test "csl toolchain config parses PATH sentinel" {
    const alloc = std.testing.allocator;
    var config = try csl_validate.toolchainConfigFromEnvValue(alloc, csl_validate.CSLC_PATH_SENTINEL);
    defer config.deinit(alloc);

    try std.testing.expectEqual(csl_validate.ToolchainDiscovery.env_path_lookup, config.discovery);
    try std.testing.expectEqualStrings(if (builtin.os.tag == .windows) "cslc.exe" else "cslc", config.executable);
}

test "csl validation accepts a fake toolchain config" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const source =
        \\//--- layout.csl ---
        \\@set_rectangle(16, 1)
        \\//--- pe_program.csl ---
        \\const sys = @import_module("<memcpy/memcpy>", .{});
        \\fn compute() void { for (@range(u32, 64)) |i| { buf[i] += 1; } sys.unblock_cmd_stream(); }
        \\comptime { @export_symbol(compute); }
    ;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try writeFakeCslcScript(tmp_dir.dir, "fake_cslc.sh");

    const script_path = try std.fs.path.join(std.testing.allocator, &.{
        ".zig-cache",
        "tmp",
        tmp_dir.sub_path[0..],
        "fake_cslc.sh",
    });
    defer std.testing.allocator.free(script_path);

    const config = csl_validate.ToolchainConfig{
        .executable = script_path,
        .discovery = .explicit_config,
    };
    const result = try csl_validate.validatePatternWithToolchainConfig(source, .element_wise, config);
    try std.testing.expect(result.valid);
}

test "csl validation reports explicit missing toolchain config path" {
    const source =
        \\//--- layout.csl ---
        \\@set_rectangle(16, 1)
        \\//--- pe_program.csl ---
        \\const sys = @import_module("<memcpy/memcpy>", .{});
        \\fn compute() void { for (@range(u32, 64)) |i| { buf[i] += 1; } sys.unblock_cmd_stream(); }
        \\comptime { @export_symbol(compute); }
    ;

    const config = csl_validate.ToolchainConfig{
        .executable = "zig-out/does-not-exist/cslc",
        .discovery = .explicit_config,
    };

    try std.testing.expectError(csl_validate.Error.ShaderToolchainUnavailable, csl_validate.validatePatternWithToolchainConfig(
        source,
        .element_wise,
        config,
    ));
    try std.testing.expect(std.mem.indexOf(u8, csl_validate.lastErrorMessage(), "zig-out/does-not-exist/cslc") != null);
    try std.testing.expect(std.mem.indexOf(u8, csl_validate.lastErrorMessage(), csl_validate.CSLC_ENV_VAR) != null);
}
