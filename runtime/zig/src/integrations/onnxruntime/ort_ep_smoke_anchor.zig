const std = @import("std");

extern fn doeOrtEpSmokeMain(argc: c_int, argv: [*][*:0]u8) c_int;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const c_argv = try allocator.alloc([*:0]u8, args.len);
    defer allocator.free(c_argv);
    for (args, 0..) |arg, index| {
        c_argv[index] = arg.ptr;
    }

    const exit_code = doeOrtEpSmokeMain(@intCast(args.len), c_argv.ptr);
    if (exit_code != 0) {
        std.process.exit(1);
    }
}
