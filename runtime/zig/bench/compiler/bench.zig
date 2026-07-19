// doe_wgsl/bench.zig — standalone microbenchmark for each stage of the WGSL compiler pipeline.
//
// Measures parse→sema→ir_build→ir_validate, each emit backend independently,
// and full end-to-end paths. Outputs NDJSON to stdout or --out file.

const std = @import("std");
const doe = @import("doe");
const parser_mod = doe.compiler.wgsl_frontend.parser();
const sema_mod = doe.compiler.wgsl_frontend.sema();
const ir_builder_mod = doe.compiler.wgsl_ir.builder();
const ir_opt_rewrite_mod = doe.compiler.wgsl_ir.optimize();
const ir_validate_mod = doe.compiler.wgsl_ir.validate();
const emit_msl_mod = doe.compiler.wgsl_emit.msl();
const emit_spirv_mod = doe.compiler.wgsl_emit.spirv();
const emit_hlsl_mod = doe.compiler.wgsl_emit.hlsl();
const ir_mod = doe.compiler.wgsl_ir.core();
const lean_proof = @import("lean_proof");

// ============================================================
// Constants
// ============================================================

const DEFAULT_ITERATIONS: u32 = 500;
const DEFAULT_WARMUP: u32 = 20;
const MAX_SAMPLES: u32 = 2000;

// Output buffer sizes sourced from the emit modules — no bare literals.
const MSL_BUF_SIZE: usize = emit_msl_mod.MAX_OUTPUT;
const SPIRV_BUF_SIZE: usize = emit_spirv_mod.MAX_OUTPUT;
const HLSL_BUF_SIZE: usize = emit_hlsl_mod.MAX_OUTPUT;

// ============================================================
// Shader corpus
// ============================================================

const Shader = struct {
    name: []const u8,
    source: []const u8,
};

const SHADERS = [_]Shader{
    .{
        .name = "compute_simple",
        .source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\@compute @workgroup_size(64) fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = data[id.x] * 2.0;
        \\}
        ,
    },
    .{
        // Struct-based uniform dims so sema recognises member access;
        // k = k + 1u avoids the ++ increment which is not yet in sema.
        .name = "compute_matmul",
        .source =
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
        ,
    },
    .{
        .name = "vertex_struct_io",
        .source =
        \\struct VertIn { @location(0) pos: vec4f, @location(1) uv: vec2f, }
        \\struct VertOut { @builtin(position) clip_pos: vec4f, @location(0) uv: vec2f, }
        \\@vertex fn vs_main(in: VertIn) -> VertOut {
        \\    var out: VertOut;
        \\    out.clip_pos = in.pos;
        \\    out.uv = in.uv;
        \\    return out;
        \\}
        ,
    },
    .{
        // textureSample works in compute-stage sema but the fragment-stage sampler+texture_2d
        // binding path raises UnsupportedBuiltin; replace with a math-only fragment shader for now.
        .name = "fragment_math",
        .source =
        \\@fragment fn fs_main(@location(0) uv: vec2f, @builtin(position) pos: vec4f) -> @location(0) vec4f {
        \\    let r = uv.x;
        \\    let g = uv.y;
        \\    let b = 1.0 - r * g;
        \\    let a = clamp(pos.z, 0.0, 1.0);
        \\    return vec4f(r, g, b, a);
        \\}
        ,
    },
    .{
        .name = "fragment_discard",
        .source =
        \\@fragment fn fs_main(@builtin(position) pos: vec4f, @builtin(front_facing) ff: bool) -> @location(0) vec4f {
        \\    if (!ff) { discard; }
        \\    return vec4f(pos.x, pos.y, 0.0, 1.0);
        \\}
        ,
    },
};

// ============================================================
// Stage identifiers
// ============================================================

const Stage = enum {
    analyze_to_ir,
    emit_msl,
    emit_spirv,
    emit_hlsl,
    e2e_msl,
    e2e_spirv,
    e2e_hlsl,
};

const STAGES = [_]Stage{
    .analyze_to_ir,
    .emit_msl,
    .emit_spirv,
    .emit_hlsl,
    .e2e_msl,
    .e2e_spirv,
    .e2e_hlsl,
};

// ============================================================
// CLI argument parsing
// ============================================================

const Config = struct {
    iterations: u32,
    warmup: u32,
    out_path: ?[]const u8,
    filter: ?[]const u8,
};

fn parse_args(allocator: std.mem.Allocator) !Config {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var cfg = Config{
        .iterations = DEFAULT_ITERATIONS,
        .warmup = DEFAULT_WARMUP,
        .out_path = null,
        .filter = null,
    };

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--iterations") and i + 1 < args.len) {
            i += 1;
            cfg.iterations = std.fmt.parseInt(u32, args[i], 10) catch blk: {
                std.debug.print("warning: invalid --iterations value '{s}', using default {d}\n", .{ args[i], DEFAULT_ITERATIONS });
                break :blk DEFAULT_ITERATIONS;
            };
        } else if (std.mem.eql(u8, args[i], "--warmup") and i + 1 < args.len) {
            i += 1;
            cfg.warmup = std.fmt.parseInt(u32, args[i], 10) catch blk: {
                std.debug.print("warning: invalid --warmup value '{s}', using default {d}\n", .{ args[i], DEFAULT_WARMUP });
                break :blk DEFAULT_WARMUP;
            };
        } else if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
            i += 1;
            cfg.out_path = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, args[i], "--filter") and i + 1 < args.len) {
            i += 1;
            cfg.filter = try allocator.dupe(u8, args[i]);
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
};

fn compute_stats(samples: []u64) Stats {
    std.sort.block(u64, samples, {}, std.sort.asc(u64));

    const n = samples.len;
    var sum: u64 = 0;
    for (samples) |s| sum += s;

    const p50_idx = n / 2;
    const p95_idx = (n * 95) / 100;
    const p99_idx = (n * 99) / 100;

    return .{
        .min_ns = samples[0],
        .max_ns = samples[n - 1],
        .mean_ns = sum / n,
        .p50_ns = samples[p50_idx],
        .p95_ns = samples[p95_idx],
        .p99_ns = samples[p99_idx],
    };
}

// ============================================================
// Output
// ============================================================

fn write_result(
    writer: anytype,
    shader_name: []const u8,
    stage_name: []const u8,
    iterations: u32,
    warmup: u32,
    stats: Stats,
    bytes_out: usize,
) !void {
    try writer.print(
        "{{\"kind\":\"shader_bench\",\"shader\":\"{s}\",\"stage\":\"{s}\"," ++
            "\"iterations\":{d},\"warmup\":{d}," ++
            "\"p50_ns\":{d},\"p95_ns\":{d},\"p99_ns\":{d}," ++
            "\"min_ns\":{d},\"max_ns\":{d},\"mean_ns\":{d},\"bytes_out\":{d}}}\n",
        .{
            shader_name,
            stage_name,
            iterations,
            warmup,
            stats.p50_ns,
            stats.p95_ns,
            stats.p99_ns,
            stats.min_ns,
            stats.max_ns,
            stats.mean_ns,
            bytes_out,
        },
    );
}

// ============================================================
// Stage runners
// ============================================================

fn maybe_validate_module(module: *const ir_mod.Module, failure_label: []const u8) bool {
    if (lean_proof.validator_elimination_available) return true;
    ir_validate_mod.validate(module) catch |err| {
        std.debug.print("  {s}: {}\n", .{ failure_label, err });
        return false;
    };
    return true;
}

fn prepare_module_for_emit(module: *ir_mod.Module, failure_label: []const u8) bool {
    _ = ir_opt_rewrite_mod.apply(module.allocator, module) catch |err| {
        std.debug.print("  {s}: {}\n", .{ failure_label, err });
        return false;
    };
    return true;
}

// Returns null when the stage fails; caller skips this (shader, stage) pair.
fn run_analyze_to_ir(
    allocator: std.mem.Allocator,
    source: []const u8,
    samples: []u64,
) !?usize {
    for (samples) |*slot| {
        var timer = try std.time.Timer.start();
        var tree = parser_mod.parseSource(allocator, source) catch |err| {
            std.debug.print("  parse failed: {}\n", .{err});
            return null;
        };
        defer tree.deinit();
        var semantic = sema_mod.analyze(allocator, &tree) catch |err| {
            std.debug.print("  sema failed: {}\n", .{err});
            return null;
        };
        defer semantic.deinit();
        var module = ir_builder_mod.build(allocator, &tree, &semantic) catch |err| {
            std.debug.print("  ir_build failed: {}\n", .{err});
            return null;
        };
        defer module.deinit();
        if (!maybe_validate_module(&module, "ir_validate failed")) return null;
        slot.* = timer.read();
    }
    return 0;
}

fn run_emit_msl(
    allocator: std.mem.Allocator,
    module: *const ir_mod.Module,
    samples: []u64,
) !?usize {
    const out_buf = try allocator.alloc(u8, MSL_BUF_SIZE);
    defer allocator.free(out_buf);

    var last_bytes: usize = 0;
    for (samples) |*slot| {
        var timer = try std.time.Timer.start();
        const n = emit_msl_mod.emit(module, out_buf) catch |err| {
            std.debug.print("  emit_msl failed: {}\n", .{err});
            return null;
        };
        slot.* = timer.read();
        last_bytes = n;
    }
    return last_bytes;
}

fn run_emit_spirv(
    allocator: std.mem.Allocator,
    module: *const ir_mod.Module,
    samples: []u64,
) !?usize {
    const out_buf = try allocator.alloc(u8, SPIRV_BUF_SIZE);
    defer allocator.free(out_buf);

    var last_bytes: usize = 0;
    for (samples) |*slot| {
        var timer = try std.time.Timer.start();
        const n = emit_spirv_mod.emit(module, out_buf) catch |err| {
            std.debug.print("  emit_spirv failed: {}\n", .{err});
            return null;
        };
        slot.* = timer.read();
        last_bytes = n;
    }
    return last_bytes;
}

fn run_emit_hlsl(
    allocator: std.mem.Allocator,
    module: *const ir_mod.Module,
    samples: []u64,
) !?usize {
    const out_buf = try allocator.alloc(u8, HLSL_BUF_SIZE);
    defer allocator.free(out_buf);

    var last_bytes: usize = 0;
    for (samples) |*slot| {
        var timer = try std.time.Timer.start();
        const n = emit_hlsl_mod.emit(module, out_buf) catch |err| {
            std.debug.print("  emit_hlsl failed: {}\n", .{err});
            return null;
        };
        slot.* = timer.read();
        last_bytes = n;
    }
    return last_bytes;
}

fn run_e2e_msl(
    allocator: std.mem.Allocator,
    source: []const u8,
    samples: []u64,
) !?usize {
    const out_buf = try allocator.alloc(u8, MSL_BUF_SIZE);
    defer allocator.free(out_buf);

    var last_bytes: usize = 0;
    for (samples) |*slot| {
        var timer = try std.time.Timer.start();
        var tree = parser_mod.parseSource(allocator, source) catch |err| {
            std.debug.print("  parse failed: {}\n", .{err});
            return null;
        };
        defer tree.deinit();
        var semantic = sema_mod.analyze(allocator, &tree) catch |err| {
            std.debug.print("  sema failed: {}\n", .{err});
            return null;
        };
        defer semantic.deinit();
        var module = ir_builder_mod.build(allocator, &tree, &semantic) catch |err| {
            std.debug.print("  ir_build failed: {}\n", .{err});
            return null;
        };
        defer module.deinit();
        if (!maybe_validate_module(&module, "ir_validate failed")) return null;
        if (!prepare_module_for_emit(&module, "ir_opt_rewrite failed")) return null;
        const n = emit_msl_mod.emit(&module, out_buf) catch |err| {
            std.debug.print("  emit_msl failed: {}\n", .{err});
            return null;
        };
        slot.* = timer.read();
        last_bytes = n;
    }
    return last_bytes;
}

fn run_e2e_spirv(
    allocator: std.mem.Allocator,
    source: []const u8,
    samples: []u64,
) !?usize {
    const out_buf = try allocator.alloc(u8, SPIRV_BUF_SIZE);
    defer allocator.free(out_buf);

    var last_bytes: usize = 0;
    for (samples) |*slot| {
        var timer = try std.time.Timer.start();
        var tree = parser_mod.parseSource(allocator, source) catch |err| {
            std.debug.print("  parse failed: {}\n", .{err});
            return null;
        };
        defer tree.deinit();
        var semantic = sema_mod.analyze(allocator, &tree) catch |err| {
            std.debug.print("  sema failed: {}\n", .{err});
            return null;
        };
        defer semantic.deinit();
        var module = ir_builder_mod.build(allocator, &tree, &semantic) catch |err| {
            std.debug.print("  ir_build failed: {}\n", .{err});
            return null;
        };
        defer module.deinit();
        if (!maybe_validate_module(&module, "ir_validate failed")) return null;
        if (!prepare_module_for_emit(&module, "ir_opt_rewrite failed")) return null;
        const n = emit_spirv_mod.emit(&module, out_buf) catch |err| {
            std.debug.print("  emit_spirv failed: {}\n", .{err});
            return null;
        };
        slot.* = timer.read();
        last_bytes = n;
    }
    return last_bytes;
}

fn run_e2e_hlsl(
    allocator: std.mem.Allocator,
    source: []const u8,
    samples: []u64,
) !?usize {
    const out_buf = try allocator.alloc(u8, HLSL_BUF_SIZE);
    defer allocator.free(out_buf);

    var last_bytes: usize = 0;
    for (samples) |*slot| {
        var timer = try std.time.Timer.start();
        var tree = parser_mod.parseSource(allocator, source) catch |err| {
            std.debug.print("  parse failed: {}\n", .{err});
            return null;
        };
        defer tree.deinit();
        var semantic = sema_mod.analyze(allocator, &tree) catch |err| {
            std.debug.print("  sema failed: {}\n", .{err});
            return null;
        };
        defer semantic.deinit();
        var module = ir_builder_mod.build(allocator, &tree, &semantic) catch |err| {
            std.debug.print("  ir_build failed: {}\n", .{err});
            return null;
        };
        defer module.deinit();
        if (!maybe_validate_module(&module, "ir_validate failed")) return null;
        if (!prepare_module_for_emit(&module, "ir_opt_rewrite failed")) return null;
        const n = emit_hlsl_mod.emit(&module, out_buf) catch |err| {
            std.debug.print("  emit_hlsl failed: {}\n", .{err});
            return null;
        };
        slot.* = timer.read();
        last_bytes = n;
    }
    return last_bytes;
}

// ============================================================
// Per-shader benchmark driver
// ============================================================

// Builds a pre-compiled IR module for emit-only stages.
// Returns null when analysis fails during warmup — emit stages are skipped.
fn build_reference_module(
    allocator: std.mem.Allocator,
    source: []const u8,
) !?ir_mod.Module {
    var tree = parser_mod.parseSource(allocator, source) catch |err| {
        std.debug.print("  warmup parse failed: {}\n", .{err});
        return null;
    };
    defer tree.deinit();

    var semantic = sema_mod.analyze(allocator, &tree) catch |err| {
        std.debug.print("  warmup sema failed: {}\n", .{err});
        return null;
    };
    defer semantic.deinit();

    var module = ir_builder_mod.build(allocator, &tree, &semantic) catch |err| {
        std.debug.print("  warmup ir_build failed: {}\n", .{err});
        return null;
    };
    if (!maybe_validate_module(&module, "warmup ir_validate failed")) {
        module.deinit();
        return null;
    }
    if (!prepare_module_for_emit(&module, "warmup ir_opt_rewrite failed")) {
        module.deinit();
        return null;
    }
    return module;
}

fn bench_shader(
    allocator: std.mem.Allocator,
    shader: Shader,
    cfg: Config,
    writer: anytype,
) !void {
    const capped = @min(cfg.iterations, MAX_SAMPLES);
    const samples = try allocator.alloc(u64, capped);
    defer allocator.free(samples);

    // A single reference module is built once and reused for emit-only stages.
    // It must be kept alive for the duration of the emit benchmarks.
    const maybe_module = try build_reference_module(allocator, shader.source);

    for (STAGES) |stage| {
        const stage_name = @tagName(stage);

        // Warmup: run warmup iterations; discard timings. Stop if stage fails.
        var warmup_ok = true;
        {
            var wi: u32 = 0;
            while (wi < cfg.warmup) : (wi += 1) {
                const ok = run_warmup_iteration(allocator, shader.source, stage, maybe_module) catch |err| {
                    std.debug.print("bench: {s}/{s} warmup error: {}\n", .{ shader.name, stage_name, err });
                    warmup_ok = false;
                    break;
                };
                if (!ok) {
                    std.debug.print("bench: {s}/{s} failed during warmup — skipping\n", .{ shader.name, stage_name });
                    warmup_ok = false;
                    break;
                }
            }
        }
        if (!warmup_ok) continue;

        // Timed runs.
        const maybe_bytes: ?usize = blk: {
            switch (stage) {
                .analyze_to_ir => break :blk try run_analyze_to_ir(allocator, shader.source, samples),
                .emit_msl => {
                    const m = maybe_module orelse break :blk null;
                    break :blk try run_emit_msl(allocator, &m, samples);
                },
                .emit_spirv => {
                    const m = maybe_module orelse break :blk null;
                    break :blk try run_emit_spirv(allocator, &m, samples);
                },
                .emit_hlsl => {
                    const m = maybe_module orelse break :blk null;
                    break :blk try run_emit_hlsl(allocator, &m, samples);
                },
                .e2e_msl => break :blk try run_e2e_msl(allocator, shader.source, samples),
                .e2e_spirv => break :blk try run_e2e_spirv(allocator, shader.source, samples),
                .e2e_hlsl => break :blk try run_e2e_hlsl(allocator, shader.source, samples),
            }
        };

        const bytes_out = maybe_bytes orelse {
            std.debug.print("bench: {s}/{s} failed during timed run — skipping\n", .{ shader.name, stage_name });
            continue;
        };

        const stats = compute_stats(samples);
        try write_result(writer, shader.name, stage_name, capped, cfg.warmup, stats, bytes_out);
    }

    // Release the reference module after all emit stages are done.
    if (maybe_module) |*m| {
        const mut_m: *ir_mod.Module = @constCast(m);
        mut_m.deinit();
    }
}

// Returns true when a single warmup iteration succeeds, false when it fails gracefully.
fn run_warmup_iteration(
    allocator: std.mem.Allocator,
    source: []const u8,
    stage: Stage,
    maybe_module: ?ir_mod.Module,
) !bool {
    switch (stage) {
        .analyze_to_ir, .e2e_msl, .e2e_spirv, .e2e_hlsl => {
            // Compile from source — verify the full pipeline parses successfully.
            var tree = parser_mod.parseSource(allocator, source) catch return false;
            defer tree.deinit();
            var semantic = sema_mod.analyze(allocator, &tree) catch return false;
            defer semantic.deinit();
            var module = ir_builder_mod.build(allocator, &tree, &semantic) catch return false;
            defer module.deinit();
            if (!maybe_validate_module(&module, "warmup ir_validate failed")) return false;
            if (!prepare_module_for_emit(&module, "warmup ir_opt_rewrite failed")) return false;

            if (stage == .e2e_msl) {
                const buf = try allocator.alloc(u8, MSL_BUF_SIZE);
                defer allocator.free(buf);
                _ = emit_msl_mod.emit(&module, buf) catch return false;
            } else if (stage == .e2e_spirv) {
                const buf = try allocator.alloc(u8, SPIRV_BUF_SIZE);
                defer allocator.free(buf);
                _ = emit_spirv_mod.emit(&module, buf) catch return false;
            } else if (stage == .e2e_hlsl) {
                const buf = try allocator.alloc(u8, HLSL_BUF_SIZE);
                defer allocator.free(buf);
                _ = emit_hlsl_mod.emit(&module, buf) catch return false;
            }
            return true;
        },
        .emit_msl => {
            const m = maybe_module orelse return false;
            const buf = try allocator.alloc(u8, MSL_BUF_SIZE);
            defer allocator.free(buf);
            _ = emit_msl_mod.emit(&m, buf) catch return false;
            return true;
        },
        .emit_spirv => {
            const m = maybe_module orelse return false;
            const buf = try allocator.alloc(u8, SPIRV_BUF_SIZE);
            defer allocator.free(buf);
            _ = emit_spirv_mod.emit(&m, buf) catch return false;
            return true;
        },
        .emit_hlsl => {
            const m = maybe_module orelse return false;
            const buf = try allocator.alloc(u8, HLSL_BUF_SIZE);
            defer allocator.free(buf);
            _ = emit_hlsl_mod.emit(&m, buf) catch return false;
            return true;
        },
    }
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

    if (cfg.iterations > MAX_SAMPLES) {
        std.debug.print(
            "warning: --iterations {d} exceeds cap {d}; capped at {d}\n",
            .{ cfg.iterations, MAX_SAMPLES, MAX_SAMPLES },
        );
    }

    // Open output destination — use deprecatedWriter which is the idiomatic pattern in this codebase.
    if (cfg.out_path) |path| {
        const out_file = try std.fs.cwd().createFile(path, .{});
        defer out_file.close();
        const writer = out_file.deprecatedWriter();
        for (SHADERS) |shader| {
            if (cfg.filter) |f| {
                if (!std.mem.eql(u8, f, shader.name)) continue;
            }
            std.debug.print("bench: {s}\n", .{shader.name});
            try bench_shader(allocator, shader, cfg, writer);
        }
    } else {
        const writer = std.fs.File.stdout().deprecatedWriter();
        for (SHADERS) |shader| {
            if (cfg.filter) |f| {
                if (!std.mem.eql(u8, f, shader.name)) continue;
            }
            std.debug.print("bench: {s}\n", .{shader.name});
            try bench_shader(allocator, shader, cfg, writer);
        }
    }
}
