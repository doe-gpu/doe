// doe_wgsl/bench_compilation.zig — shader compilation latency benchmark.
//
// Measures full WGSL-to-target translation time (the metric that matters for
// pipeline creation and first-frame UX). Targets: MSL, HLSL, SPIR-V.
//
// Shader corpus spans four complexity tiers so results can be compared against
// Tint/Dawn on equivalent workloads. Outputs NDJSON with p50/p95/p99 and a
// final summary line per target.
//
// Usage:
//   zig-out/bin/doe-compilation-bench [--iterations N] [--warmup N] [--out path] [--filter name] [--target msl|hlsl|spirv|all]
//
// Methodology notes for Tint comparison:
//   - Doe measures WGSL source -> target text/binary, including parse+sema+IR+emit.
//   - Tint equivalent: `tint --format=msl shader.wgsl` measures the same scope.
//   - Tint must be built in Release mode (Chrome build or standalone cmake -DCMAKE_BUILD_TYPE=Release).
//   - Both sides must use the same shader source verbatim (no preprocessing).
//   - Report hardware, OS, and compiler versions alongside results.
//   - Doe is single-threaded; confirm Tint is not using thread-pool internally.

const std = @import("std");
const mod = @import("doe").compiler.wgsl();
const translateToMsl = mod.translateToMsl;
const translateToHlsl = mod.translateToHlsl;
const translateToSpirv = mod.translateToSpirv;

// ============================================================
// Constants
// ============================================================

const DEFAULT_ITERATIONS: u32 = 500;
const DEFAULT_WARMUP: u32 = 50;
const MAX_SAMPLES: u32 = 5000;
const MSL_BUF_SIZE: usize = mod.MAX_OUTPUT;
const HLSL_BUF_SIZE: usize = mod.MAX_HLSL_OUTPUT;
const SPIRV_BUF_SIZE: usize = mod.MAX_SPIRV_OUTPUT;
const BENCH_VERSION: u32 = 1;

// ============================================================
// Shader corpus — four complexity tiers
// ============================================================

const Shader = struct {
    name: []const u8,
    tier: []const u8,
    source: []const u8,
    source_lines: u32,
};

fn count_lines(src: []const u8) u32 {
    @setEvalBranchQuota(10_000);
    var n: u32 = 1;
    for (src) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

const SHADER_SOURCES = struct {
    // -- Tier: trivial --
    const empty_compute =
        \\@compute @workgroup_size(1)
        \\fn main() {}
    ;
    const passthrough_vertex =
        \\@vertex
        \\fn main(@location(0) pos: vec4f) -> @builtin(position) vec4f {
        \\    return pos;
        \\}
    ;

    // -- Tier: simple --
    const scale_compute =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = data[id.x] * 2.0;
        \\}
    ;
    const color_fragment =
        \\@fragment
        \\fn main(@location(0) uv: vec2f, @builtin(position) pos: vec4f) -> @location(0) vec4f {
        \\    let r = uv.x;
        \\    let g = uv.y;
        \\    let b = 1.0 - r * g;
        \\    let a = clamp(pos.z, 0.0, 1.0);
        \\    return vec4f(r, g, b, a);
        \\}
    ;

    // -- Tier: moderate --
    const matmul_compute =
        \\struct Dims { M: u32, N: u32, K: u32, }
        \\@group(0) @binding(0) var<storage, read> a: array<f32>;
        \\@group(0) @binding(1) var<storage, read> b: array<f32>;
        \\@group(0) @binding(2) var<storage, read_write> c: array<f32>;
        \\@group(0) @binding(3) var<uniform> dims: Dims;
        \\@compute @workgroup_size(8, 8) fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    let row = gid.y;
        \\    let col = gid.x;
        \\    if (row >= dims.M) { return; }
        \\    if (col >= dims.N) { return; }
        \\    var acc: f32 = 0.0;
        \\    for (var k: u32 = 0u; k < dims.K; k = k + 1u) {
        \\        acc = acc + a[row * dims.K + k] * b[k * dims.N + col];
        \\    }
        \\    c[row * dims.N + col] = acc;
        \\}
    ;
    const vertex_transform =
        \\@vertex
        \\fn main(
        \\    @builtin(vertex_index) vid: u32,
        \\    @builtin(instance_index) iid: u32,
        \\) -> @builtin(position) vec4f {
        \\    let x = f32(vid) * 0.1 - 1.0;
        \\    let y = f32(iid) * 0.1 - 1.0;
        \\    return vec4f(x, y, 0.0, 1.0);
        \\}
    ;

    // -- Tier: complex --
    const texture_compute =
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\@group(0) @binding(1) var out_tex: texture_storage_2d<rgba8unorm, write>;
        \\@group(0) @binding(2) var<storage, read_write> data: array<f32>;
        \\@compute @workgroup_size(8, 8)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let sample = textureLoad(tex, vec2u(id.xy), 0);
        \\    textureStore(out_tex, vec2u(id.xy), sample);
        \\    data[id.x] = sample.x;
        \\}
    ;
    const multi_binding_compute =
        \\struct Params { scale: f32, bias: f32, }
        \\@group(0) @binding(0) var<storage, read> input: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
        \\@group(0) @binding(2) var<uniform> params: Params;
        \\@group(0) @binding(3) var<storage, read> weights: array<f32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    let idx = gid.x;
        \\    let w = weights[idx];
        \\    let x = input[idx];
        \\    var acc: f32 = x * w * params.scale + params.bias;
        \\    acc = clamp(acc, 0.0, 1.0);
        \\    output[idx] = acc;
        \\}
    ;
    const fragment_discard =
        \\@fragment fn fs_main(@builtin(position) pos: vec4f, @builtin(front_facing) ff: bool) -> @location(0) vec4f {
        \\    if (!ff) { discard; }
        \\    return vec4f(pos.x, pos.y, 0.0, 1.0);
        \\}
    ;
};

const SHADERS = [_]Shader{
    .{ .name = "empty_compute", .tier = "trivial", .source = SHADER_SOURCES.empty_compute, .source_lines = count_lines(SHADER_SOURCES.empty_compute) },
    .{ .name = "passthrough_vertex", .tier = "trivial", .source = SHADER_SOURCES.passthrough_vertex, .source_lines = count_lines(SHADER_SOURCES.passthrough_vertex) },
    .{ .name = "scale_compute", .tier = "simple", .source = SHADER_SOURCES.scale_compute, .source_lines = count_lines(SHADER_SOURCES.scale_compute) },
    .{ .name = "color_fragment", .tier = "simple", .source = SHADER_SOURCES.color_fragment, .source_lines = count_lines(SHADER_SOURCES.color_fragment) },
    .{ .name = "matmul_compute", .tier = "moderate", .source = SHADER_SOURCES.matmul_compute, .source_lines = count_lines(SHADER_SOURCES.matmul_compute) },
    .{ .name = "vertex_transform", .tier = "moderate", .source = SHADER_SOURCES.vertex_transform, .source_lines = count_lines(SHADER_SOURCES.vertex_transform) },
    .{ .name = "texture_compute", .tier = "complex", .source = SHADER_SOURCES.texture_compute, .source_lines = count_lines(SHADER_SOURCES.texture_compute) },
    .{ .name = "multi_binding_compute", .tier = "complex", .source = SHADER_SOURCES.multi_binding_compute, .source_lines = count_lines(SHADER_SOURCES.multi_binding_compute) },
    .{ .name = "fragment_discard", .tier = "complex", .source = SHADER_SOURCES.fragment_discard, .source_lines = count_lines(SHADER_SOURCES.fragment_discard) },
};

// ============================================================
// Target selection
// ============================================================

const Target = enum {
    msl,
    hlsl,
    spirv,
};

const ALL_TARGETS = [_]Target{ .msl, .hlsl, .spirv };

// ============================================================
// CLI argument parsing
// ============================================================

const Config = struct {
    iterations: u32,
    warmup: u32,
    out_path: ?[]const u8,
    filter: ?[]const u8,
    shader_path: ?[]const u8,
    shader_name: ?[]const u8,
    shader_tier: ?[]const u8,
    targets: []const Target,
};

fn parse_args(allocator: std.mem.Allocator) !Config {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var cfg = Config{
        .iterations = DEFAULT_ITERATIONS,
        .warmup = DEFAULT_WARMUP,
        .out_path = null,
        .filter = null,
        .shader_path = null,
        .shader_name = null,
        .shader_tier = null,
        .targets = &ALL_TARGETS,
    };

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--iterations") and i + 1 < args.len) {
            i += 1;
            cfg.iterations = std.fmt.parseInt(u32, args[i], 10) catch blk: {
                std.debug.print("warning: invalid --iterations '{s}', using default {d}\n", .{ args[i], DEFAULT_ITERATIONS });
                break :blk DEFAULT_ITERATIONS;
            };
        } else if (std.mem.eql(u8, args[i], "--warmup") and i + 1 < args.len) {
            i += 1;
            cfg.warmup = std.fmt.parseInt(u32, args[i], 10) catch blk: {
                std.debug.print("warning: invalid --warmup '{s}', using default {d}\n", .{ args[i], DEFAULT_WARMUP });
                break :blk DEFAULT_WARMUP;
            };
        } else if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
            i += 1;
            cfg.out_path = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, args[i], "--filter") and i + 1 < args.len) {
            i += 1;
            cfg.filter = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, args[i], "--shader-path") and i + 1 < args.len) {
            i += 1;
            cfg.shader_path = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, args[i], "--shader-name") and i + 1 < args.len) {
            i += 1;
            cfg.shader_name = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, args[i], "--shader-tier") and i + 1 < args.len) {
            i += 1;
            cfg.shader_tier = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, args[i], "--target") and i + 1 < args.len) {
            i += 1;
            if (std.mem.eql(u8, args[i], "msl")) {
                cfg.targets = &[_]Target{.msl};
            } else if (std.mem.eql(u8, args[i], "hlsl")) {
                cfg.targets = &[_]Target{.hlsl};
            } else if (std.mem.eql(u8, args[i], "spirv")) {
                cfg.targets = &[_]Target{.spirv};
            } else if (std.mem.eql(u8, args[i], "all")) {
                cfg.targets = &ALL_TARGETS;
            } else {
                std.debug.print("warning: unknown --target '{s}', using all\n", .{args[i]});
            }
        }
    }

    return cfg;
}

// ============================================================
// Statistics
// ============================================================

const Stats = struct {
    min_ns: u64,
    max_ns: u64,
    mean_ns: u64,
    p50_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    stddev_ns: u64,
};

fn compute_stats(samples: []u64) Stats {
    std.sort.block(u64, samples, {}, std.sort.asc(u64));

    const n = samples.len;
    var sum: u64 = 0;
    for (samples) |s| sum += s;
    const mean = sum / n;

    // stddev via two-pass
    var var_sum: u128 = 0;
    for (samples) |s| {
        const diff: i128 = @as(i128, @intCast(s)) - @as(i128, @intCast(mean));
        var_sum += @intCast(@as(u128, @bitCast(diff * diff)));
    }
    const variance = var_sum / n;
    const stddev: u64 = @intCast(std.math.sqrt(variance));

    return .{
        .min_ns = samples[0],
        .max_ns = samples[n - 1],
        .mean_ns = mean,
        .p50_ns = samples[n / 2],
        .p95_ns = samples[(n * 95) / 100],
        .p99_ns = samples[(n * 99) / 100],
        .stddev_ns = stddev,
    };
}

// ============================================================
// Translation runner
// ============================================================

const TranslateResult = struct {
    bytes_out: usize,
    succeeded: bool,
};

fn translate_once(
    allocator: std.mem.Allocator,
    source: []const u8,
    target: Target,
    out_buf: []u8,
) TranslateResult {
    const result = switch (target) {
        .msl => translateToMsl(allocator, source, out_buf),
        .hlsl => translateToHlsl(allocator, source, out_buf),
        .spirv => translateToSpirv(allocator, source, out_buf),
    };
    if (result) |n| {
        return .{ .bytes_out = n, .succeeded = true };
    } else |_| {
        return .{ .bytes_out = 0, .succeeded = false };
    }
}

fn buf_size_for(target: Target) usize {
    return switch (target) {
        .msl => MSL_BUF_SIZE,
        .hlsl => HLSL_BUF_SIZE,
        .spirv => SPIRV_BUF_SIZE,
    };
}

// ============================================================
// NDJSON output
// ============================================================

fn write_result(
    writer: anytype,
    shader: Shader,
    target: Target,
    iterations: u32,
    warmup: u32,
    stats: Stats,
    bytes_out: usize,
) !void {
    try writer.print(
        "{{\"kind\":\"compilation_bench\",\"version\":{d}," ++
            "\"shader\":\"{s}\",\"tier\":\"{s}\"," ++
            "\"target\":\"{s}\",\"sourceLines\":{d}," ++
            "\"iterations\":{d},\"warmup\":{d}," ++
            "\"p50_ns\":{d},\"p95_ns\":{d},\"p99_ns\":{d}," ++
            "\"min_ns\":{d},\"max_ns\":{d},\"mean_ns\":{d}," ++
            "\"stddev_ns\":{d},\"bytesOut\":{d}," ++
            "\"p50_us\":{d}.{d:0>3},\"compiler\":\"doe_wgsl\",\"compilerLoc\":18000}}\n",
        .{
            BENCH_VERSION,
            shader.name,
            shader.tier,
            @tagName(target),
            shader.source_lines,
            iterations,
            warmup,
            stats.p50_ns,
            stats.p95_ns,
            stats.p99_ns,
            stats.min_ns,
            stats.max_ns,
            stats.mean_ns,
            stats.stddev_ns,
            bytes_out,
            stats.p50_ns / 1000,
            stats.p50_ns % 1000,
        },
    );
}

fn write_summary_line(
    writer: anytype,
    target: Target,
    shader_count: u32,
    total_p50_ns: u64,
    min_p50_ns: u64,
    max_p50_ns: u64,
) !void {
    try writer.print(
        "{{\"kind\":\"compilation_bench_summary\",\"version\":{d}," ++
            "\"target\":\"{s}\",\"shaderCount\":{d}," ++
            "\"totalP50_ns\":{d},\"avgP50_ns\":{d}," ++
            "\"minP50_ns\":{d},\"maxP50_ns\":{d}," ++
            "\"totalP50_us\":{d}.{d:0>3}," ++
            "\"compiler\":\"doe_wgsl\",\"compilerLoc\":18000}}\n",
        .{
            BENCH_VERSION,
            @tagName(target),
            shader_count,
            total_p50_ns,
            if (shader_count > 0) total_p50_ns / shader_count else 0,
            min_p50_ns,
            max_p50_ns,
            total_p50_ns / 1000,
            total_p50_ns % 1000,
        },
    );
}

// ============================================================
// Benchmark driver
// ============================================================

fn bench_shader_target(
    allocator: std.mem.Allocator,
    shader: Shader,
    target: Target,
    cfg: Config,
    writer: anytype,
) !?u64 {
    const capped = @min(cfg.iterations, MAX_SAMPLES);
    const samples = try allocator.alloc(u64, capped);
    defer allocator.free(samples);

    const out_buf = try allocator.alloc(u8, buf_size_for(target));
    defer allocator.free(out_buf);

    // Warmup — verify shader compiles and prime caches.
    {
        var wi: u32 = 0;
        while (wi < cfg.warmup) : (wi += 1) {
            const r = translate_once(allocator, shader.source, target, out_buf);
            if (!r.succeeded) {
                std.debug.print("  {s}/{s}: compilation failed during warmup — skipping\n", .{ shader.name, @tagName(target) });
                return null;
            }
        }
    }

    // Timed iterations.
    var last_bytes: usize = 0;
    for (samples) |*slot| {
        var timer = try std.time.Timer.start();
        const r = translate_once(allocator, shader.source, target, out_buf);
        slot.* = timer.read();
        if (!r.succeeded) {
            std.debug.print("  {s}/{s}: compilation failed during timed run — skipping\n", .{ shader.name, @tagName(target) });
            return null;
        }
        last_bytes = r.bytes_out;
    }

    const stats = compute_stats(samples);
    try write_result(writer, shader, target, capped, cfg.warmup, stats, last_bytes);
    return stats.p50_ns;
}

// ============================================================
// Human-readable stderr summary
// ============================================================

fn print_stderr_header() void {
    std.debug.print("\n{s:<25} {s:<8} {s:>10} {s:>10} {s:>10} {s:>8}\n", .{
        "shader", "target", "p50(us)", "p95(us)", "p99(us)", "out(B)",
    });
    std.debug.print("{s}\n", .{"-" ** 78});
}

fn print_stderr_row(name: []const u8, target: Target, stats: Stats, bytes: usize) void {
    std.debug.print("{s:<25} {s:<8} {d:>7}.{d:0>3} {d:>7}.{d:0>3} {d:>7}.{d:0>3} {d:>8}\n", .{
        name,
        @tagName(target),
        stats.p50_ns / 1000,
        stats.p50_ns % 1000,
        stats.p95_ns / 1000,
        stats.p95_ns % 1000,
        stats.p99_ns / 1000,
        stats.p99_ns % 1000,
        bytes,
    });
}

// ============================================================
// Entry point
// ============================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cfg = parse_args(allocator) catch |err| {
        std.debug.print("error parsing args: {}\n", .{err});
        std.process.exit(1);
    };
    defer if (cfg.out_path) |p| allocator.free(p);
    defer if (cfg.filter) |f| allocator.free(f);
    defer if (cfg.shader_path) |p| allocator.free(p);
    defer if (cfg.shader_name) |n| allocator.free(n);
    defer if (cfg.shader_tier) |t| allocator.free(t);

    if (cfg.iterations > MAX_SAMPLES) {
        std.debug.print(
            "warning: --iterations {d} exceeds cap {d}; capped\n",
            .{ cfg.iterations, MAX_SAMPLES },
        );
    }

    std.debug.print("doe_wgsl compilation benchmark v{d}\n", .{BENCH_VERSION});
    std.debug.print("  iterations={d} warmup={d} targets={d} shaders={d}\n", .{
        @min(cfg.iterations, MAX_SAMPLES),
        cfg.warmup,
        cfg.targets.len,
        SHADERS.len,
    });

    // Determine output writer.
    if (cfg.out_path) |path| {
        const out_file = try std.fs.cwd().createFile(path, .{});
        defer out_file.close();
        const writer = out_file.deprecatedWriter();
        try run_all(allocator, cfg, writer);
    } else {
        const writer = std.fs.File.stdout().deprecatedWriter();
        try run_all(allocator, cfg, writer);
    }
}

const TIMER_CALIBRATION_ITERATIONS: u32 = 1000;

fn measure_timer_overhead_ns(allocator: std.mem.Allocator) !u64 {
    const samples = try allocator.alloc(u64, TIMER_CALIBRATION_ITERATIONS);
    defer allocator.free(samples);
    for (samples) |*slot| {
        var t = try std.time.Timer.start();
        slot.* = t.read();
    }
    std.sort.block(u64, samples, {}, std.sort.asc(u64));
    return samples[samples.len / 2];
}

fn write_calibration(writer: anytype, timer_overhead_ns: u64) !void {
    try writer.print(
        "{{\"kind\":\"compilation_bench_calibration\",\"version\":{d}," ++
            "\"timerOverheadP50Ns\":{d}," ++
            "\"timerOverheadIterations\":{d}," ++
            "\"timerSource\":\"std.time.Timer\"," ++
            "\"timerScope\":\"per-translation in-process\"}}\n",
        .{ BENCH_VERSION, timer_overhead_ns, TIMER_CALIBRATION_ITERATIONS },
    );
}

fn run_all(allocator: std.mem.Allocator, cfg: Config, writer: anytype) !void {
    print_stderr_header();

    const timer_overhead_ns = try measure_timer_overhead_ns(allocator);
    try write_calibration(writer, timer_overhead_ns);

    var dynamic_source: ?[]u8 = null;
    defer if (dynamic_source) |buf| allocator.free(buf);
    var dynamic_name: ?[]u8 = null;
    defer if (dynamic_name) |buf| allocator.free(buf);
    var dynamic_tier: ?[]u8 = null;
    defer if (dynamic_tier) |buf| allocator.free(buf);

    const shader_slice = blk: {
        if (cfg.shader_path) |shader_path| {
            const source = try std.fs.cwd().readFileAlloc(allocator, shader_path, 8 * 1024 * 1024);
            dynamic_source = source;
            const name = if (cfg.shader_name) |shader_name| name_blk: {
                break :name_blk try allocator.dupe(u8, shader_name);
            } else stem_blk: {
                const basename = std.fs.path.basename(shader_path);
                const stem = std.fs.path.stem(basename);
                break :stem_blk try allocator.dupe(u8, stem);
            };
            dynamic_name = name;
            const tier = if (cfg.shader_tier) |shader_tier|
                try allocator.dupe(u8, shader_tier)
            else
                try allocator.dupe(u8, "external");
            dynamic_tier = tier;
            const external_shader = try allocator.alloc(Shader, 1);
            external_shader[0] = .{
                .name = name,
                .tier = tier,
                .source = source,
                .source_lines = count_lines(source),
            };
            break :blk external_shader;
        }
        break :blk SHADERS[0..];
    };
    defer if (cfg.shader_path != null) allocator.free(shader_slice);

    for (cfg.targets) |target| {
        var total_p50: u64 = 0;
        var min_p50: u64 = std.math.maxInt(u64);
        var max_p50: u64 = 0;
        var shader_count: u32 = 0;

        for (shader_slice) |shader| {
            if (cfg.filter) |f| {
                if (!std.mem.eql(u8, f, shader.name)) continue;
            }

            const maybe_p50 = try bench_shader_target(allocator, shader, target, cfg, writer);
            if (maybe_p50) |p50| {
                total_p50 += p50;
                min_p50 = @min(min_p50, p50);
                max_p50 = @max(max_p50, p50);
                shader_count += 1;
            }
        }

        if (shader_count > 0) {
            try write_summary_line(writer, target, shader_count, total_p50, min_p50, max_p50);
        }
    }

    std.debug.print("\ndone.\n", .{});
}
