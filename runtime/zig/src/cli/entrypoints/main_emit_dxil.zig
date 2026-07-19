const std = @import("std");
const wgsl = @import("doe").compiler.wgsl();

const MAX_SOURCE_BYTES: usize = 2 * 1024 * 1024;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var shader_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--shader-path") and i + 1 < args.len) {
            i += 1;
            shader_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
            i += 1;
            out_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--help")) {
            try printUsage();
            return;
        }
    }

    const shader_path_value = shader_path orelse {
        try printUsage();
        return error.InvalidArgument;
    };

    const source = try std.fs.cwd().readFileAlloc(allocator, shader_path_value, MAX_SOURCE_BYTES);
    defer allocator.free(source);

    const out_buf = try allocator.alloc(u8, wgsl.MAX_DXIL_OUTPUT);
    defer allocator.free(out_buf);

    const dxil_len = wgsl.translateToDxil(allocator, source, out_buf) catch |err| {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        const detail = wgsl.lastErrorMessage();
        if (detail.len > 0) {
            try stderr.print("{s}: {s}\n", .{ @errorName(err), detail });
        } else {
            try stderr.print("{s}\n", .{@errorName(err)});
        }
        return err;
    };

    if (out_path) |path| {
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(out_buf[0..dxil_len]);
        return;
    }

    try std.fs.File.stdout().writeAll(out_buf[0..dxil_len]);
}

fn printUsage() !void {
    try std.fs.File.stderr().deprecatedWriter().writeAll(
        \\doe-emit-dxil --shader-path <path> [--out <path>]
        \\
        \\Translate one WGSL shader to native DXIL using Doe's WGSL compiler.
        \\If --out is omitted, writes DXIL container bytes to stdout.
        \\
    );
}
