const std = @import("std");
const doe = @import("doe");
const wgsl = doe.compiler.wgsl();
const runtime_compile = doe.compiler.wgsl_runtime.compile();

const MAX_SOURCE_BYTES: usize = 2 * 1024 * 1024;

const CompilerMode = enum {
    default,
    vulkan_compute_runtime,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var shader_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var mode: CompilerMode = .default;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--shader-path") and i + 1 < args.len) {
            i += 1;
            shader_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
            i += 1;
            out_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--mode") and i + 1 < args.len) {
            i += 1;
            if (std.mem.eql(u8, args[i], "default")) {
                mode = .default;
            } else if (std.mem.eql(u8, args[i], "vulkan-compute-runtime")) {
                mode = .vulkan_compute_runtime;
            } else {
                try printUsage();
                return error.InvalidArgument;
            }
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

    const out_buf = try allocator.alloc(u8, wgsl.MAX_SPIRV_OUTPUT);
    defer allocator.free(out_buf);

    const spirv_len = translate(allocator, source, out_buf, mode) catch |err| {
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
        try file.writeAll(out_buf[0..spirv_len]);
        return;
    }

    try std.fs.File.stdout().writeAll(out_buf[0..spirv_len]);
}

fn translate(
    allocator: std.mem.Allocator,
    source: []const u8,
    out_buf: []u8,
    mode: CompilerMode,
) wgsl.TranslateError!usize {
    return switch (mode) {
        .default => wgsl.translateToSpirv(allocator, source, out_buf),
        .vulkan_compute_runtime => blk: {
            var result = try runtime_compile.translateToSpirvForVulkanComputeRuntime(allocator, source, out_buf);
            defer result.info.deinit(allocator);
            break :blk result.len;
        },
    };
}

fn printUsage() !void {
    try std.fs.File.stderr().deprecatedWriter().writeAll(
        \\doe-emit-spirv --shader-path <path> [--out <path>] [--mode default|vulkan-compute-runtime]
        \\
        \\Translate one WGSL shader to SPIR-V using Doe's WGSL compiler.
        \\If --out is omitted, writes SPIR-V bytes to stdout.
        \\
    );
}
