const builtin = @import("builtin");
const std = @import("std");
const doe = @import("doe");
const byte_scan = doe.runtime.simd.byteScan();
const f32_ops = doe.runtime.simd.f32Ops();

pub const DEFAULT_ITERATIONS: u32 = 200;
pub const DEFAULT_WARMUP: u32 = 20;
pub const JSON_ESCAPE_MAX_EXPANSION: usize = 6;
pub const LINKED_QUEUE_WORK_ITEMS: usize = 4096;
pub const SINGLEFLIGHT_WAITERS: usize = 512;
pub const NUMERIC_VECTOR_LEN: usize = 4096;
pub const ATTENTION_SEQ_LEN: usize = 128;
pub const ATTENTION_HEAD_DIM: usize = 64;
pub const ATTENTION_VALUE_DIM: usize = 64;

pub const Config = struct {
    iterations: u32 = DEFAULT_ITERATIONS,
    warmup: u32 = DEFAULT_WARMUP,
    out_path: ?[]const u8 = null,
};

pub const Stats = struct {
    min_ns: u64,
    max_ns: u64,
    mean_ns: u64,
    p50_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    checksum: u64,
};

pub const VariantResult = struct {
    variant: []const u8,
    iterations: u32,
    warmup: u32,
    input_bytes: usize,
    work_items: usize,
    min_ns: u64,
    max_ns: u64,
    mean_ns: u64,
    p50_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    checksum: u64,
    output_hash: u64,
};

pub const CaseComparison = struct {
    baseline_variant: []const u8,
    candidate_variant: []const u8,
    speedup: f64,
    output_hash_match: bool,
    max_abs_diff: ?f64 = null,
    max_rel_diff: ?f64 = null,
};

pub const CaseResult = struct {
    category: []const u8,
    case_id: []const u8,
    description: []const u8,
    variants: []const VariantResult,
    comparison: CaseComparison,
};

pub const HostMetadata = struct {
    cpu_arch: []const u8,
    cpu_model: []const u8,
    os: []const u8,
    abi: []const u8,
    target_triple: []const u8,
    byte_scan_lanes: usize,
    f32_lanes: usize,
};

pub const Artifact = struct {
    schema_version: u32 = 1,
    kind: []const u8 = "doe_host_hotpath_bench",
    tool: []const u8 = "doe-host-hotpath-bench",
    host: HostMetadata,
    cases: []const CaseResult,
};

pub const SMALL_WGSL =
    \\// Small representative shader body with comments and identifiers.
    \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
    \\@group(0) @binding(1) var<uniform> dims: vec4u;
    \\@compute @workgroup_size(64) fn main(@builtin(global_invocation_id) gid: vec3u) {
    \\    // comment path for scalar/SIMD whitespace scanning
    \\    let idx = gid.x;
    \\    if (idx >= dims.x) { return; }
    \\    data[idx] = data[idx] * 2.0 + f32(dims.y);
    \\}
;

pub fn parseArgs(allocator: std.mem.Allocator) !Config {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var cfg = Config{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--iterations") and index + 1 < args.len) {
            index += 1;
            cfg.iterations = try std.fmt.parseInt(u32, args[index], 10);
        } else if (std.mem.eql(u8, args[index], "--warmup") and index + 1 < args.len) {
            index += 1;
            cfg.warmup = try std.fmt.parseInt(u32, args[index], 10);
        } else if (std.mem.eql(u8, args[index], "--out") and index + 1 < args.len) {
            index += 1;
            cfg.out_path = try allocator.dupe(u8, args[index]);
        }
    }
    return cfg;
}

fn computeStats(samples: []u64, checksum: u64) Stats {
    std.sort.block(u64, samples, {}, std.sort.asc(u64));
    const count = samples.len;
    var sum: u128 = 0;
    for (samples) |sample| sum += sample;
    return .{
        .min_ns = samples[0],
        .max_ns = samples[count - 1],
        .mean_ns = @intCast(sum / count),
        .p50_ns = samples[count / 2],
        .p95_ns = samples[@min((count * 95) / 100, count - 1)],
        .p99_ns = samples[@min((count * 99) / 100, count - 1)],
        .checksum = checksum,
    };
}

pub fn measure(
    comptime Context: type,
    allocator: std.mem.Allocator,
    iterations: u32,
    warmup: u32,
    ctx: *Context,
    run: *const fn (*Context) anyerror!u64,
) !Stats {
    const sample_count = @max(iterations, 1);
    const samples = try allocator.alloc(u64, @intCast(sample_count));
    defer allocator.free(samples);

    var warmup_index: u32 = 0;
    while (warmup_index < warmup) : (warmup_index += 1) {
        _ = try run(ctx);
    }

    var checksum: u64 = 0;
    var sample_index: usize = 0;
    while (sample_index < sample_count) : (sample_index += 1) {
        const start = std.time.nanoTimestamp();
        checksum ^= try run(ctx);
        const end = std.time.nanoTimestamp();
        samples[sample_index] = @intCast(end - start);
    }
    return computeStats(samples, checksum);
}

pub fn writeJsonStringScalar(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0...8, 11...12, 14...31 => try writer.print("\\u00{x:0>2}", .{byte}),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

pub fn normalizeExecutionStatusCodeScalar(message: []const u8, fallback: []const u8, buffer: *[160]u8) []const u8 {
    const source = if (message.len > 0) message else fallback;
    var out_len: usize = 0;
    var last_was_separator = true;

    for (source) |byte| {
        if (std.ascii.isAlphabetic(byte) or std.ascii.isDigit(byte)) {
            if (out_len < buffer.len) {
                buffer[out_len] = std.ascii.toLower(byte);
                out_len += 1;
            }
            last_was_separator = false;
            continue;
        }
        if (!last_was_separator and out_len < buffer.len) {
            buffer[out_len] = '_';
            out_len += 1;
            last_was_separator = true;
        }
    }

    while (out_len > 0 and buffer[out_len - 1] == '_') {
        out_len -= 1;
    }
    if (out_len == 0) {
        const fallback_len = @min(fallback.len, buffer.len);
        std.mem.copyForwards(u8, buffer[0..fallback_len], fallback[0..fallback_len]);
        return buffer[0..fallback_len];
    }
    return buffer[0..out_len];
}

pub fn checksumSlice(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0, bytes);
}

pub fn speedup(baseline: u64, candidate: u64) f64 {
    return @as(f64, @floatFromInt(baseline)) / @as(f64, @floatFromInt(candidate));
}

pub fn appendCase(list: *std.ArrayList(CaseResult), allocator: std.mem.Allocator, case_result: CaseResult) !void {
    try list.append(allocator, case_result);
}

pub fn buildLargeWgsl(allocator: std.mem.Allocator) ![]u8 {
    var list = try std.ArrayList(u8).initCapacity(allocator, 0);
    for (0..48) |index| {
        try list.writer(allocator).print("// shader block {d}\n{s}\n", .{ index, SMALL_WGSL });
        if ((index % 3) == 0) {
            try list.appendSlice(allocator, "/* nested /* comment */ tail */\n");
        }
    }
    return list.toOwnedSlice(allocator);
}

pub fn buildLongEscapeInput(allocator: std.mem.Allocator) ![]u8 {
    var list = try std.ArrayList(u8).initCapacity(allocator, 0);
    for (0..256) |index| {
        try list.writer(allocator).print("segment-{d}:value=\"quoted\"\\path\t", .{index});
        if ((index % 4) == 0) try list.append(allocator, '\n');
    }
    return list.toOwnedSlice(allocator);
}

pub fn fillNumericData(lhs: []f64, rhs: []f64, values: []f64, q: []f64, k: []f64, v: []f64) void {
    for (lhs, 0..) |*slot, index| {
        slot.* = @sin(@as(f64, @floatFromInt(index)) * 0.013) + 0.25;
    }
    for (rhs, 0..) |*slot, index| {
        slot.* = @cos(@as(f64, @floatFromInt(index)) * 0.017) + 0.5;
    }
    for (values, 0..) |*slot, index| {
        slot.* = (@as(f64, @floatFromInt((index % 23) + 1)) / 23.0) - 0.4;
    }
    for (q, 0..) |*slot, index| {
        slot.* = @sin(@as(f64, @floatFromInt(index)) * 0.021) * 0.5;
    }
    for (k, 0..) |*slot, index| {
        slot.* = @cos(@as(f64, @floatFromInt(index)) * 0.009) * 0.25;
    }
    for (v, 0..) |*slot, index| {
        slot.* = @sin(@as(f64, @floatFromInt(index)) * 0.015) * 0.75;
    }
}

pub fn makeHostMetadata(allocator: std.mem.Allocator) !HostMetadata {
    const target_triple = try std.fmt.allocPrint(
        allocator,
        "{s}-{s}-{s}",
        .{ @tagName(builtin.cpu.arch), @tagName(builtin.os.tag), @tagName(builtin.abi) },
    );
    return .{
        .cpu_arch = @tagName(builtin.cpu.arch),
        .cpu_model = builtin.cpu.model.name,
        .os = @tagName(builtin.os.tag),
        .abi = @tagName(builtin.abi),
        .target_triple = target_triple,
        .byte_scan_lanes = byte_scan.BYTE_LANES,
        .f32_lanes = f32_ops.F32_LANES,
    };
}

pub fn writeArtifact(artifact: Artifact, out_path: ?[]const u8) !void {
    var payload_writer: std.io.Writer.Allocating = .init(std.heap.page_allocator);
    defer payload_writer.deinit();
    try std.json.Stringify.value(artifact, .{ .whitespace = .indent_2 }, &payload_writer.writer);
    const payload = try payload_writer.toOwnedSlice();
    defer std.heap.page_allocator.free(payload);

    if (out_path) |path| {
        if (std.fs.path.dirname(path)) |dir| {
            try std.fs.cwd().makePath(dir);
        }
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(payload);
        try file.writeAll("\n");
        return;
    }
    const stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.writeAll(payload);
    try stdout.writeByte('\n');
}
