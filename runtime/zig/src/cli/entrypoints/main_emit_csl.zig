// doe-emit-csl — translate one WGSL shader to CSL via Doe's WGSL compiler
// and split the combined output into separate layout.csl / pe_program.csl
// files written to a target directory.
//
// Mirrors the MSL emitter entrypoint in shape; the section split is needed
// because cslc consumes layout.csl and pe_program.csl as separate inputs
// even though translateToCsl emits both in one buffer with section
// markers.

const std = @import("std");
const doe = @import("doe");
const wgsl = doe.compiler.wgsl();
const spec = doe.compiler.wgsl_csl.spec();
const host = doe.compiler.wgsl_csl.hostCompileSource();

const MAX_SOURCE_BYTES: usize = 2 * 1024 * 1024;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var shader_path: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var combined_path: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--shader-path") and i + 1 < args.len) {
            i += 1;
            shader_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--out-dir") and i + 1 < args.len) {
            i += 1;
            out_dir = args[i];
        } else if (std.mem.eql(u8, args[i], "--combined-out") and i + 1 < args.len) {
            i += 1;
            combined_path = args[i];
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

    const out_buf = try allocator.alloc(u8, wgsl.MAX_OUTPUT);
    defer allocator.free(out_buf);

    const csl_len = wgsl.translateToCsl(allocator, source, out_buf) catch |err| {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        const detail = wgsl.lastErrorMessage();
        if (detail.len > 0) {
            try stderr.print("{s}: {s}\n", .{ @errorName(err), detail });
        } else {
            try stderr.print("{s}\n", .{@errorName(err)});
        }
        return err;
    };

    const csl = out_buf[0..csl_len];

    if (combined_path) |path| {
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(csl);
    }

    if (out_dir) |dir| {
        var d = try std.fs.cwd().makeOpenPath(dir, .{});
        defer d.close();

        const layout = host.sectionBody(csl, spec.LAYOUT_FILENAME) orelse {
            try std.fs.File.stderr().deprecatedWriter().writeAll(
                "missing layout.csl section in emitted CSL\n",
            );
            return error.InvalidIr;
        };
        const pe_program = host.sectionBody(csl, spec.PE_PROGRAM_FILENAME) orelse {
            try std.fs.File.stderr().deprecatedWriter().writeAll(
                "missing pe_program.csl section in emitted CSL\n",
            );
            return error.InvalidIr;
        };

        const layout_file = try d.createFile(spec.LAYOUT_FILENAME, .{ .truncate = true });
        defer layout_file.close();
        try layout_file.writeAll(layout);

        const pe_file = try d.createFile(spec.PE_PROGRAM_FILENAME, .{ .truncate = true });
        defer pe_file.close();
        try pe_file.writeAll(pe_program);
        return;
    }

    if (combined_path == null) {
        try std.fs.File.stdout().deprecatedWriter().writeAll(csl);
    }
}

fn printUsage() !void {
    try std.fs.File.stderr().deprecatedWriter().writeAll(
        \\doe-emit-csl --shader-path <path> [--out-dir <dir>] [--combined-out <path>]
        \\
        \\Translate one WGSL shader to CSL using Doe's WGSL compiler.
        \\With --out-dir, splits the combined output into layout.csl and
        \\pe_program.csl in the target directory. With --combined-out,
        \\writes the section-marker-delimited combined buffer to one file.
        \\If neither is given, writes the combined buffer to stdout.
        \\
    );
}
