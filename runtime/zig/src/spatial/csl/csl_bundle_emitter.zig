const std = @import("std");
const doe_wgsl = @import("doe").compiler.wgsl();

const LAYOUT_MARKER = "//--- layout.csl ---\n";
const PE_PROGRAM_MARKER = "//--- pe_program.csl ---\n";

const Error = error{
    MissingOptionValue,
    MissingRequiredOption,
    InvalidBundle,
} || std.fs.Dir.MakeError || std.fs.File.OpenError || std.fs.File.WriteError || std.mem.Allocator.Error || doe_wgsl.TranslateError;

fn optionValue(args: []const []const u8, name: []const u8) Error![]const u8 {
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (!std.mem.eql(u8, args[index], name)) continue;
        if (index + 1 >= args.len) return error.MissingOptionValue;
        return args[index + 1];
    }
    return error.MissingRequiredOption;
}

fn usage() void {
    std.debug.print(
        "usage: doe-csl-bundle-emitter --wgsl <source.wgsl> --out-dir <dir>\n",
        .{},
    );
}

fn splitBundle(bundle: []const u8) Error!struct { layout: []const u8, pe_program: []const u8 } {
    const layout_start = std.mem.indexOf(u8, bundle, LAYOUT_MARKER) orelse return error.InvalidBundle;
    const pe_start = std.mem.indexOf(u8, bundle, PE_PROGRAM_MARKER) orelse return error.InvalidBundle;
    if (pe_start <= layout_start + LAYOUT_MARKER.len) return error.InvalidBundle;

    const layout_raw = bundle[layout_start + LAYOUT_MARKER.len .. pe_start];
    const pe_raw = bundle[pe_start + PE_PROGRAM_MARKER.len ..];
    const layout = std.mem.trim(u8, layout_raw, "\n\r ");
    const pe_program = std.mem.trim(u8, pe_raw, "\n\r ");
    if (layout.len == 0 or pe_program.len == 0) return error.InvalidBundle;
    return .{ .layout = layout, .pe_program = pe_program };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) @panic("memory leak in doe-csl-bundle-emitter");
    }
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const wgsl_path = optionValue(args, "--wgsl") catch {
        usage();
        return error.MissingRequiredOption;
    };
    const out_dir_path = optionValue(args, "--out-dir") catch {
        usage();
        return error.MissingRequiredOption;
    };

    const wgsl_source = try std.fs.cwd().readFileAlloc(allocator, wgsl_path, 1024 * 1024);
    defer allocator.free(wgsl_source);

    var csl_buf: [doe_wgsl.MAX_CSL_OUTPUT]u8 = undefined;
    const csl_len = try doe_wgsl.translateToCsl(allocator, wgsl_source, &csl_buf);
    const bundle = csl_buf[0..csl_len];
    const split = try splitBundle(bundle);

    try std.fs.cwd().makePath(out_dir_path);

    const layout_path = try std.fs.path.join(allocator, &.{ out_dir_path, "layout.csl" });
    defer allocator.free(layout_path);
    const pe_program_path = try std.fs.path.join(allocator, &.{ out_dir_path, "pe_program.csl" });
    defer allocator.free(pe_program_path);

    try std.fs.cwd().writeFile(.{ .sub_path = layout_path, .data = split.layout });
    try std.fs.cwd().writeFile(.{ .sub_path = pe_program_path, .data = split.pe_program });

    std.debug.print(
        "emitted CSL bundle: {s} -> {s}\n",
        .{ wgsl_path, out_dir_path },
    );
}
