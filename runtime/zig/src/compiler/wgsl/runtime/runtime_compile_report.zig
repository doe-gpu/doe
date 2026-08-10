const std = @import("std");
const lean_proof = @import("../../../verification/lean_proof.zig");
const msl_translation = @import("../pipeline/translate_msl.zig");
const spirv_translation = @import("../pipeline/translate_spirv.zig");
const runtime_compile = @import("runtime_compile.zig");

const Config = struct {
    shader_path: []const u8,
    shader_name: ?[]const u8 = null,
    out_path: ?[]const u8 = null,
    target: Target = .msl,
    emit_msl_path: ?[]const u8 = null,
    emit_spirv_path: ?[]const u8 = null,
};

const Target = enum {
    msl,
    spirv,
};

fn parseTarget(value: []const u8) !Target {
    if (std.mem.eql(u8, value, "msl")) return .msl;
    if (std.mem.eql(u8, value, "spirv")) return .spirv;
    return error.InvalidTarget;
}

fn targetText(value: Target) []const u8 {
    return switch (value) {
        .msl => "msl",
        .spirv => "spirv",
    };
}

fn parseArgs(allocator: std.mem.Allocator) !Config {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var config = Config{
        .shader_path = "",
    };

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--shader-path") and i + 1 < args.len) {
            i += 1;
            config.shader_path = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, args[i], "--shader-name") and i + 1 < args.len) {
            i += 1;
            config.shader_name = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
            i += 1;
            config.out_path = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, args[i], "--target") and i + 1 < args.len) {
            i += 1;
            config.target = try parseTarget(args[i]);
        } else if (std.mem.eql(u8, args[i], "--emit-msl") and i + 1 < args.len) {
            i += 1;
            config.emit_msl_path = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, args[i], "--emit-spirv") and i + 1 < args.len) {
            i += 1;
            config.emit_spirv_path = try allocator.dupe(u8, args[i]);
        }
    }

    if (config.shader_path.len == 0) return error.MissingShaderPath;
    return config;
}

fn countSubstring(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0 or haystack.len < needle.len) return 0;
    var count: usize = 0;
    var start: usize = 0;
    while (start <= haystack.len - needle.len) {
        if (std.mem.indexOfPos(u8, haystack, start, needle)) |pos| {
            count += 1;
            start = pos + needle.len;
        } else {
            break;
        }
    }
    return count;
}

fn boolText(value: bool) []const u8 {
    return if (value) "true" else "false";
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = parseArgs(allocator) catch |err| {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print(
            "usage: doe-runtime-compile-report --shader-path <path> [--shader-name <name>] [--out <path>] [--target msl|spirv] [--emit-msl <path>] [--emit-spirv <path>]\nerror: {s}\n",
            .{@errorName(err)},
        );
        std.process.exit(1);
    };
    defer allocator.free(config.shader_path);
    defer if (config.shader_name) |value| allocator.free(value);
    defer if (config.out_path) |value| allocator.free(value);
    defer if (config.emit_msl_path) |value| allocator.free(value);
    defer if (config.emit_spirv_path) |value| allocator.free(value);

    const shader_source = try std.fs.cwd().readFileAlloc(allocator, config.shader_path, 8 * 1024 * 1024);
    defer allocator.free(shader_source);

    const shader_name = if (config.shader_name) |name|
        name
    else
        std.fs.path.stem(std.fs.path.basename(config.shader_path));

    const out_buf_len = switch (config.target) {
        .msl => msl_translation.MAX_OUTPUT,
        .spirv => spirv_translation.MAX_OUTPUT,
    };
    var out_buf = try allocator.alloc(u8, out_buf_len);
    defer allocator.free(out_buf);

    var translation = switch (config.target) {
        .msl => try runtime_compile.translateToMslForComputeRuntimeTimed(
            allocator,
            shader_source,
            out_buf,
            null,
            0,
        ),
        .spirv => try runtime_compile.translateToSpirvTimed(
            allocator,
            shader_source,
            out_buf,
        ),
    };
    defer translation.info.deinit(allocator);

    const output = out_buf[0..translation.len];
    const min_count = if (config.target == .msl) countSubstring(output, "min(") else 0;
    const doe_sizes_present = config.target == .msl and std.mem.indexOf(u8, output, "_doe_sizes") != null;

    if (config.emit_msl_path) |path| {
        if (config.target != .msl) return error.EmitTargetMismatch;
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(output);
    }
    if (config.emit_spirv_path) |path| {
        if (config.target != .spirv) return error.EmitTargetMismatch;
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(output);
    }

    const msl_bytes = if (config.target == .msl) translation.len else 0;
    const spirv_bytes = if (config.target == .spirv) translation.len else 0;
    const report_fmt = "{{\"kind\":\"runtime_compile_report\",\"schemaVersion\":1,\"shader\":\"{s}\",\"shaderPath\":\"{s}\",\"target\":\"{s}\",\"leanVerified\":{s},\"outputBytes\":{d},\"mslBytes\":{d},\"spirvBytes\":{d},\"minCount\":{d},\"doeSizesPresent\":{s},\"needsSizesBuf\":{s},\"dispatchPreconditions\":{d},\"textureDispatchPreconditions\":{d},\"workgroupSize\":[{d},{d},{d}],\"phaseTimingsNs\":{{\"parse\":{d},\"sema\":{d},\"lower\":{d},\"emit\":{d},\"total\":{d}}}}}\n";
    const report_args = .{
        shader_name,
        config.shader_path,
        targetText(config.target),
        boolText(lean_proof.lean_verified),
        translation.len,
        msl_bytes,
        spirv_bytes,
        min_count,
        boolText(doe_sizes_present),
        boolText(translation.info.needs_sizes_buf),
        translation.info.dispatch_preconditions.len,
        translation.info.texture_dispatch_preconditions.len,
        translation.info.workgroup_size[0],
        translation.info.workgroup_size[1],
        translation.info.workgroup_size[2],
        translation.phase_timings_ns.parse,
        translation.phase_timings_ns.sema,
        translation.phase_timings_ns.lower,
        translation.phase_timings_ns.emit,
        translation.phase_timings_ns.total,
    };

    if (config.out_path) |path| {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.deprecatedWriter().print(report_fmt, report_args);
    } else {
        try std.fs.File.stdout().deprecatedWriter().print(report_fmt, report_args);
    }
}
