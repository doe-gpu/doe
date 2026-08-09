//! Emit the canonical SHA-256 digest of Doe's lowered WGSL IR.

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
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--shader-path") and index + 1 < args.len) {
            index += 1;
            shader_path = args[index];
        } else if (std.mem.eql(u8, args[index], "--help")) {
            try usage();
            return;
        }
    }

    const path = shader_path orelse {
        try usage();
        return error.InvalidArgument;
    };
    const source = try std.fs.cwd().readFileAlloc(allocator, path, MAX_SOURCE_BYTES);
    defer allocator.free(source);
    var module = try wgsl.analyzeToIr(allocator, source);
    defer module.deinit();
    const digest = wgsl.ir_digest.computeHex(&module);
    try std.fs.File.stdout().deprecatedWriter().print("{s}\n", .{digest});
}

fn usage() !void {
    try std.fs.File.stderr().deprecatedWriter().writeAll(
        \\doe-emit-ir-digest --shader-path <path>
        \\
        \\Lower WGSL to Doe IR and write its canonical SHA-256 digest.
        \\
    );
}
