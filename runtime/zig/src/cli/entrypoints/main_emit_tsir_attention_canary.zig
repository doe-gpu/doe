// doe-emit-tsir-attention-canary
//
// Mitigates attention-canary fixture rewire from
// docs/cerebras-model-ledgers.md by exercising the TSIR-CSL attention
// emit path (runtime/zig/src/compiler/tsir/emit_kernel_body_attention.zig)
// end-to-end and writing layout.csl + pe_program.csl files that
// downstream cslc + chain_step_adapter can compile and dispatch.
//
// Until this lands, the attention canary kernels at
// bench/out/csl-real-canary-source/attention_head{256,512}_f16kv/
// were hand-authored bootstrap-shape CSL (zero-in zero-out) closing
// the canary lane via hash equivalence rather than via the new
// TSIR-CSL emit body. This tool routes the SAME hash-equivalence
// claim through emitCslAttentionScores so the receipt cites the
// emitter source digest instead of hand-authored CSL.
//
// Usage:
//   doe-emit-tsir-attention-canary --head-dim 256 --out-dir <dir>
//   doe-emit-tsir-attention-canary --head-dim 512 --out-dir <dir>
//
// Multi-PE kv-axis-sharded variant (attention-canary follow-up):
//   doe-emit-tsir-attention-canary --head-dim 512 \
//       --pe-strategy kv_axis_sharded --slots-per-pe 8 \
//       --out-dir <dir>
//
// The sharded variant emits a partials-only kernel: each PE writes
// `[head_dim + 2]f32` (local_O + local_max + local_sum_exp); the host
// plan stitches with log-sum-exp distributed softmax. Required for
// head_dim=512 at kv_len ≥ 15 because a single PE cannot hold the
// full K/V buffers within the WSE-3 48 KiB SRAM budget.

const std = @import("std");
const doe = @import("doe");
const tsir = doe.compiler.tsir();
const targets = doe.compiler.targets();

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("doe-emit-tsir-attention-canary: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

fn parseHeadDim(arg: []const u8) ?u32 {
    return std.fmt.parseInt(u32, arg, 10) catch null;
}

fn buildSemantic(head_dim: u32) tsir.schema.SemanticFunction {
    // Mirrors `attentionScoresSemantic()` in
    // runtime/zig/tests/wgsl/tsir_emit_kernel_body_test.zig but
    // parameterized on head_dim so the same emitter handles both
    // canary kernels (head_dim=256 and head_dim=512).
    const Static = struct {
        var axes_storage: [2]tsir.schema.IterationAxis = undefined;
        var bindings_storage: [4]tsir.schema.BufferBinding = undefined;
        var body_bindings_storage: [4]tsir.schema.SemanticBodyBinding = undefined;
        var body_axes_storage: [2]tsir.schema.SemanticBodyAxis = undefined;
    };
    Static.axes_storage = .{
        .{ .name = "k", .lower_bound = "0", .upper_bound = "kv_len", .step = "1" },
        .{ .name = "d", .lower_bound = "0", .upper_bound = "head_dim", .step = "1" },
    };
    Static.bindings_storage = .{
        .{ .name = "query", .group = 0, .binding = 0, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
        .{ .name = "key", .group = 0, .binding = 1, .logical_shape = &.{ 0, 0 }, .elem = .f32, .read_write = false },
        .{ .name = "value", .group = 0, .binding = 2, .logical_shape = &.{ 0, 0 }, .elem = .f32, .read_write = false },
        .{ .name = "output", .group = 0, .binding = 3, .logical_shape = &.{0}, .elem = .f32, .read_write = true },
    };
    Static.body_bindings_storage = .{
        .{ .binding_index = 0, .role = .query },
        .{ .binding_index = 1, .role = .key },
        .{ .binding_index = 2, .role = .value },
        .{ .binding_index = 3, .role = .output },
    };
    Static.body_axes_storage = .{
        .{ .axis_index = 0, .role = .token },
        .{ .axis_index = 1, .role = .hidden },
    };
    return .{
        .name = "main",
        .family_hint = .attention_decode,
        .axes = &Static.axes_storage,
        .bindings = &Static.bindings_storage,
        .reductions = &.{},
        .collectives = &.{},
        .body = .{
            .op = .attention_scores,
            .binding_roles = &Static.body_bindings_storage,
            .axis_roles = &Static.body_axes_storage,
            .attention_scores = .{
                .softmax_mode = .two_pass_stable,
                .head_dim = head_dim,
                .key_sequence_axis = 0,
                .scale_source = .literal_f32,
                .scale_literal_f32 = 1.0,
                .has_softcap = false,
                .causal_mode = .none,
            },
        },
        .source_digest = [_]u8{0} ** 32,
    };
}

fn buildRealizationFunction(descriptor: targets.TargetDescriptor) tsir.schema.RealizationFunction {
    // Minimal RealizationFunction mirroring fixtureFunction() in
    // runtime/zig/tests/wgsl/tsir_emit_kernel_body_test.zig:869
    // (semantic_index=0, empty residency/reductions/collectives,
    // descriptor_hash bound to wse3). emitter_params_json is "{}" so
    // the emitter doesn't try to interpret anything.
    return .{
        .semantic_index = 0,
        .tiles = .{ .per_axis = &.{} },
        .pe_grid = .{ .width = 1, .height = 1 },
        .residency = &.{},
        .collectives = &.{},
        .reductions = &.{},
        .emitter_params_json = "{}",
        .target_descriptor_hash = targets.descriptorHash(descriptor),
    };
}

const LAYOUT_MARKER = "//--- layout.csl ---\n";
const PE_PROGRAM_MARKER = "//--- pe_program.csl ---\n";

fn splitBundle(bundle: []const u8) ?struct { layout: []const u8, pe_program: []const u8 } {
    const layout_start = std.mem.indexOf(u8, bundle, LAYOUT_MARKER) orelse return null;
    const pe_start = std.mem.indexOf(u8, bundle, PE_PROGRAM_MARKER) orelse return null;
    if (pe_start <= layout_start + LAYOUT_MARKER.len) return null;
    const layout = std.mem.trim(u8, bundle[layout_start + LAYOUT_MARKER.len .. pe_start], "\n\r ");
    const pe_program = std.mem.trim(u8, bundle[pe_start + PE_PROGRAM_MARKER.len ..], "\n\r ");
    return .{ .layout = layout, .pe_program = pe_program };
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args_iter = std.process.args();
    _ = args_iter.next(); // skip binary name
    var head_dim: u32 = 0;
    var out_dir: []const u8 = "";
    var pe_strategy: tsir.emit_kernel_body.AttentionPeStrategy = .full_per_pe;
    var slots_per_pe: ?u32 = null;
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--head-dim")) {
            const next = args_iter.next() orelse die("--head-dim requires a value", .{});
            head_dim = parseHeadDim(next) orelse die("invalid --head-dim {s}", .{next});
        } else if (std.mem.eql(u8, arg, "--out-dir")) {
            out_dir = args_iter.next() orelse die("--out-dir requires a value", .{});
        } else if (std.mem.eql(u8, arg, "--pe-strategy")) {
            const next = args_iter.next() orelse die("--pe-strategy requires a value", .{});
            if (std.mem.eql(u8, next, "full_per_pe")) {
                pe_strategy = .full_per_pe;
            } else if (std.mem.eql(u8, next, "kv_axis_sharded")) {
                pe_strategy = .kv_axis_sharded;
            } else {
                die("invalid --pe-strategy {s} (expected full_per_pe or kv_axis_sharded)", .{next});
            }
        } else if (std.mem.eql(u8, arg, "--slots-per-pe")) {
            const next = args_iter.next() orelse die("--slots-per-pe requires a value", .{});
            slots_per_pe = parseHeadDim(next) orelse die("invalid --slots-per-pe {s}", .{next});
        } else {
            die("unknown arg {s}", .{arg});
        }
    }
    if (head_dim == 0) die("--head-dim is required (256 or 512)", .{});
    if (out_dir.len == 0) die("--out-dir is required", .{});
    if (pe_strategy == .kv_axis_sharded and slots_per_pe == null) {
        die("--pe-strategy kv_axis_sharded requires --slots-per-pe <N>", .{});
    }

    const semantic = buildSemantic(head_dim);
    const descriptor = targets.wse3.descriptor;
    const function = buildRealizationFunction(descriptor);
    const config = tsir.emit_kernel_body.Config{
        .var_prefix = "tsir_",
        .attention_pe_strategy = pe_strategy,
        .attention_slots_per_pe_default = slots_per_pe,
    };

    const csl = try tsir.emit_csl.emitSemanticFunctionWithConfig(
        allocator,
        semantic,
        function,
        descriptor,
        &config,
    );

    const split = splitBundle(csl) orelse die("emitter output missing layout/pe_program markers", .{});

    var dir = try std.fs.cwd().makeOpenPath(out_dir, .{});
    defer dir.close();

    {
        var file = try dir.createFile("layout.csl", .{ .truncate = true });
        defer file.close();
        try file.writeAll(split.layout);
        try file.writeAll("\n");
    }
    {
        var file = try dir.createFile("pe_program.csl", .{ .truncate = true });
        defer file.close();
        try file.writeAll(split.pe_program);
        try file.writeAll("\n");
    }

    const stdout_file = std.fs.File.stdout();
    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = stdout_file.writer(&stdout_buf);
    const strategy_name = switch (pe_strategy) {
        .full_per_pe => "full_per_pe",
        .kv_axis_sharded => "kv_axis_sharded",
    };
    try stdout_writer.interface.print(
        "wrote {s}/layout.csl and {s}/pe_program.csl (head_dim={d}, pe_strategy={s})\n",
        .{ out_dir, out_dir, head_dim, strategy_name },
    );
    try stdout_writer.interface.flush();
}
