const std = @import("std");
const doe = @import("doe");
const f32_ops = doe.runtime.simd.f32Ops();
const lexer_bench = @import("host_hotpath_bench_lexer.zig");
const support = @import("host_hotpath_bench_support.zig");
const trace_text = doe.runtime.traceText();

const VariantResult = support.VariantResult;
const CaseResult = support.CaseResult;
const JSON_ESCAPE_MAX_EXPANSION = support.JSON_ESCAPE_MAX_EXPANSION;
const LINKED_QUEUE_WORK_ITEMS = support.LINKED_QUEUE_WORK_ITEMS;
const SINGLEFLIGHT_WAITERS = support.SINGLEFLIGHT_WAITERS;
const ATTENTION_SEQ_LEN = support.ATTENTION_SEQ_LEN;
const ATTENTION_HEAD_DIM = support.ATTENTION_HEAD_DIM;
const ATTENTION_VALUE_DIM = support.ATTENTION_VALUE_DIM;

const EscapeBench = struct {
    input: []const u8,
    scratch: []u8,

    fn runScalar(self: *EscapeBench) !u64 {
        var stream = std.io.fixedBufferStream(self.scratch);
        try support.writeJsonStringScalar(stream.writer(), self.input);
        const written = stream.getWritten();
        return @as(u64, written.len) ^ (if (written.len == 0) 0 else written[written.len - 1]);
    }

    fn runSimd(self: *EscapeBench) !u64 {
        var stream = std.io.fixedBufferStream(self.scratch);
        try trace_text.writeJsonString(stream.writer(), self.input);
        const written = stream.getWritten();
        return @as(u64, written.len) ^ (if (written.len == 0) 0 else written[written.len - 1]);
    }

    fn hashScalar(self: *EscapeBench) !u64 {
        var stream = std.io.fixedBufferStream(self.scratch);
        try support.writeJsonStringScalar(stream.writer(), self.input);
        return support.checksumSlice(stream.getWritten());
    }

    fn hashSimd(self: *EscapeBench) !u64 {
        var stream = std.io.fixedBufferStream(self.scratch);
        try trace_text.writeJsonString(stream.writer(), self.input);
        return support.checksumSlice(stream.getWritten());
    }
};

const StatusBench = struct {
    input: []const u8,
    fallback: []const u8,

    fn runScalar(self: *StatusBench) !u64 {
        var buffer: [160]u8 = undefined;
        const normalized = support.normalizeExecutionStatusCodeScalar(self.input, self.fallback, &buffer);
        return support.checksumSlice(normalized);
    }

    fn runRuntime(self: *StatusBench) !u64 {
        var buffer: [160]u8 = undefined;
        const normalized = trace_text.normalizeExecutionStatusCode(self.input, self.fallback, &buffer);
        return support.checksumSlice(normalized);
    }

    fn hashScalar(self: *StatusBench) u64 {
        var buffer: [160]u8 = undefined;
        return support.checksumSlice(support.normalizeExecutionStatusCodeScalar(self.input, self.fallback, &buffer));
    }

    fn hashRuntime(self: *StatusBench) u64 {
        var buffer: [160]u8 = undefined;
        return support.checksumSlice(trace_text.normalizeExecutionStatusCode(self.input, self.fallback, &buffer));
    }
};

const DotBench = struct {
    lhs: []const f64,
    rhs: []const f64,

    fn runScalar(self: *DotBench) !u64 {
        const bits: u32 = @bitCast(f32_ops.dotF64Scalar(self.lhs, self.rhs));
        return bits;
    }

    fn runSimd(self: *DotBench) !u64 {
        const bits: u32 = @bitCast(f32_ops.dotF64(self.lhs, self.rhs));
        return bits;
    }

    fn scalarValue(self: *DotBench) f32 {
        return f32_ops.dotF64Scalar(self.lhs, self.rhs);
    }

    fn simdValue(self: *DotBench) f32 {
        return f32_ops.dotF64(self.lhs, self.rhs);
    }
};

const SumBench = struct {
    values: []const f64,

    fn runScalar(self: *SumBench) !u64 {
        const bits: u32 = @bitCast(f32_ops.sumF64Scalar(self.values));
        return bits;
    }

    fn runSimd(self: *SumBench) !u64 {
        const bits: u32 = @bitCast(f32_ops.sumF64(self.values));
        return bits;
    }

    fn scalarValue(self: *SumBench) f32 {
        return f32_ops.sumF64Scalar(self.values);
    }

    fn simdValue(self: *SumBench) f32 {
        return f32_ops.sumF64(self.values);
    }
};

fn runAttentionScalar(
    q: []const f64,
    k: []const f64,
    v: []const f64,
    scale: f64,
    weighted: []f64,
    output: []f64,
) void {
    var scores: [ATTENTION_SEQ_LEN]f64 = undefined;
    var position: usize = 0;
    while (position < ATTENTION_SEQ_LEN) : (position += 1) {
        const start = position * ATTENTION_HEAD_DIM;
        scores[position] = @as(f64, @floatCast(f32_ops.dotF64Scalar(q, k[start .. start + ATTENTION_HEAD_DIM]))) * scale;
    }

    var row_max = scores[0];
    for (scores[1..]) |score| {
        if (score > row_max) row_max = score;
    }

    var exps: [ATTENTION_SEQ_LEN]f64 = undefined;
    for (scores, 0..) |score, index| {
        exps[index] = @exp(@max(@min(score - row_max, 30.0), -30.0));
    }
    const total = @as(f64, @floatCast(f32_ops.sumF64Scalar(&exps)));

    var value_index: usize = 0;
    while (value_index < ATTENTION_VALUE_DIM) : (value_index += 1) {
        for (exps, 0..) |value, seq_index| {
            weighted[seq_index] = (value / total) * v[(seq_index * ATTENTION_VALUE_DIM) + value_index];
        }
        output[value_index] = @as(f64, @floatCast(f32_ops.sumF64Scalar(weighted)));
    }
}

fn runAttentionSimd(
    q: []const f64,
    k: []const f64,
    v: []const f64,
    scale: f64,
    weighted: []f64,
    output: []f64,
) void {
    var scores: [ATTENTION_SEQ_LEN]f64 = undefined;
    var position: usize = 0;
    while (position < ATTENTION_SEQ_LEN) : (position += 1) {
        const start = position * ATTENTION_HEAD_DIM;
        scores[position] = @as(f64, @floatCast(f32_ops.dotF64(q, k[start .. start + ATTENTION_HEAD_DIM]))) * scale;
    }

    var row_max = scores[0];
    for (scores[1..]) |score| {
        if (score > row_max) row_max = score;
    }

    var exps: [ATTENTION_SEQ_LEN]f64 = undefined;
    for (scores, 0..) |score, index| {
        exps[index] = @exp(@max(@min(score - row_max, 30.0), -30.0));
    }
    const total = @as(f64, @floatCast(f32_ops.sumF64(&exps)));

    var value_index: usize = 0;
    while (value_index < ATTENTION_VALUE_DIM) : (value_index += 1) {
        for (exps, 0..) |value, seq_index| {
            weighted[seq_index] = (value / total) * v[(seq_index * ATTENTION_VALUE_DIM) + value_index];
        }
        output[value_index] = @as(f64, @floatCast(f32_ops.sumF64(weighted)));
    }
}

pub const AttentionBench = struct {
    q: []const f64,
    k: []const f64,
    v: []const f64,
    scalar_weighted: []f64,
    simd_weighted: []f64,
    scalar_output: []f64,
    simd_output: []f64,
    scale: f64,

    fn runScalar(self: *AttentionBench) !u64 {
        runAttentionScalar(self.q, self.k, self.v, self.scale, self.scalar_weighted, self.scalar_output);
        return support.checksumSlice(std.mem.sliceAsBytes(self.scalar_output));
    }

    fn runSimd(self: *AttentionBench) !u64 {
        runAttentionSimd(self.q, self.k, self.v, self.scale, self.simd_weighted, self.simd_output);
        return support.checksumSlice(std.mem.sliceAsBytes(self.simd_output));
    }
};

fn diffEnvelope(lhs: []const f64, rhs: []const f64) struct { max_abs: f64, max_rel: f64 } {
    var max_abs: f64 = 0;
    var max_rel: f64 = 0;
    for (lhs, rhs) |left, right| {
        const abs_diff = @abs(left - right);
        const denom = @max(@abs(left), 1e-12);
        const rel_diff = abs_diff / denom;
        if (abs_diff > max_abs) max_abs = abs_diff;
        if (rel_diff > max_rel) max_rel = rel_diff;
    }
    return .{ .max_abs = max_abs, .max_rel = max_rel };
}

const LinkedJobNode = struct {
    next: ?*LinkedJobNode = null,
    value: usize,
};

pub const LinkedQueueBench = struct {
    allocator: std.mem.Allocator,

    pub fn run(self: *LinkedQueueBench) !u64 {
        var head: ?*LinkedJobNode = null;
        var tail: ?*LinkedJobNode = null;

        var enqueue_index: usize = 0;
        while (enqueue_index < LINKED_QUEUE_WORK_ITEMS) : (enqueue_index += 1) {
            const node = try self.allocator.create(LinkedJobNode);
            node.* = .{ .value = enqueue_index };
            if (tail) |existing| {
                existing.next = node;
            } else {
                head = node;
            }
            tail = node;
        }

        var checksum: u64 = 0;
        var current = head;
        while (current) |node| {
            checksum +%= node.value;
            const next = node.next;
            self.allocator.destroy(node);
            current = next;
        }
        return checksum;
    }
};

pub const RingQueueBench = struct {
    items: []usize,
    head: usize = 0,
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !RingQueueBench {
        return .{ .items = try allocator.alloc(usize, LINKED_QUEUE_WORK_ITEMS) };
    }

    pub fn deinit(self: *RingQueueBench, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
    }

    pub fn run(self: *RingQueueBench) !u64 {
        self.head = 0;
        self.count = 0;

        var index: usize = 0;
        while (index < LINKED_QUEUE_WORK_ITEMS) : (index += 1) {
            const tail = (self.head + self.count) % self.items.len;
            self.items[tail] = index;
            self.count += 1;
        }

        var checksum: u64 = 0;
        while (self.count > 0) {
            checksum +%= self.items[self.head];
            self.head = (self.head + 1) % self.items.len;
            self.count -= 1;
        }
        return checksum;
    }
};

pub const BenchWaitNode = struct {
    next: ?*BenchWaitNode = null,
    id: usize,
};

pub const IntrusiveSingleflightBench = struct {
    nodes: []BenchWaitNode,

    pub fn run(self: *IntrusiveSingleflightBench) !u64 {
        var head: ?*BenchWaitNode = null;
        var tail: ?*BenchWaitNode = null;
        for (self.nodes) |*node| {
            node.next = null;
            if (tail) |last| {
                last.next = node;
            } else {
                head = node;
            }
            tail = node;
        }

        var checksum: u64 = 0;
        var current = head;
        while (current) |node| {
            checksum +%= node.id;
            current = node.next;
        }
        return checksum;
    }
};

pub const FlatSingleflightBench = struct {
    allocator: std.mem.Allocator,
    nodes: []BenchWaitNode,
    waiters: std.ArrayListUnmanaged(*BenchWaitNode) = .{},

    pub fn deinit(self: *FlatSingleflightBench) void {
        self.waiters.deinit(self.allocator);
    }

    pub fn run(self: *FlatSingleflightBench) !u64 {
        self.waiters.clearRetainingCapacity();
        try self.waiters.ensureUnusedCapacity(self.allocator, self.nodes.len);
        for (self.nodes) |*node| {
            try self.waiters.append(self.allocator, node);
        }

        var head: ?*BenchWaitNode = null;
        var index = self.waiters.items.len;
        while (index > 0) {
            index -= 1;
            const node = self.waiters.items[index];
            node.next = head;
            head = node;
        }

        var checksum: u64 = 0;
        var current = head;
        while (current) |node| {
            checksum +%= node.id;
            current = node.next;
        }
        return checksum;
    }
};

fn buildVariants(
    allocator: std.mem.Allocator,
    iterations: u32,
    warmup: u32,
    input_bytes: usize,
    work_items: usize,
    baseline_name: []const u8,
    baseline: support.Stats,
    baseline_hash: u64,
    candidate_name: []const u8,
    candidate: support.Stats,
    candidate_hash: u64,
) ![]const VariantResult {
    return allocator.dupe(VariantResult, &[_]VariantResult{
        .{
            .variant = baseline_name,
            .iterations = iterations,
            .warmup = warmup,
            .input_bytes = input_bytes,
            .work_items = work_items,
            .min_ns = baseline.min_ns,
            .max_ns = baseline.max_ns,
            .mean_ns = baseline.mean_ns,
            .p50_ns = baseline.p50_ns,
            .p95_ns = baseline.p95_ns,
            .p99_ns = baseline.p99_ns,
            .checksum = baseline.checksum,
            .output_hash = baseline_hash,
        },
        .{
            .variant = candidate_name,
            .iterations = iterations,
            .warmup = warmup,
            .input_bytes = input_bytes,
            .work_items = work_items,
            .min_ns = candidate.min_ns,
            .max_ns = candidate.max_ns,
            .mean_ns = candidate.mean_ns,
            .p50_ns = candidate.p50_ns,
            .p95_ns = candidate.p95_ns,
            .p99_ns = candidate.p99_ns,
            .checksum = candidate.checksum,
            .output_hash = candidate_hash,
        },
    });
}

pub fn createTraceCase(
    allocator: std.mem.Allocator,
    cfg: support.Config,
    case_id: []const u8,
    description: []const u8,
    input: []const u8,
) !CaseResult {
    const scratch = try allocator.alloc(u8, (input.len * JSON_ESCAPE_MAX_EXPANSION) + 2);
    var bench = EscapeBench{ .input = input, .scratch = scratch };
    const scalar = try support.measure(EscapeBench, allocator, cfg.iterations, cfg.warmup, &bench, EscapeBench.runScalar);
    const simd = try support.measure(EscapeBench, allocator, cfg.iterations, cfg.warmup, &bench, EscapeBench.runSimd);
    const scalar_hash = try bench.hashScalar();
    const simd_hash = try bench.hashSimd();
    return .{
        .category = "trace",
        .case_id = case_id,
        .description = description,
        .variants = try buildVariants(allocator, cfg.iterations, cfg.warmup, input.len, input.len, "scalar", scalar, scalar_hash, "simd", simd, simd_hash),
        .comparison = .{
            .baseline_variant = "scalar",
            .candidate_variant = "simd",
            .speedup = support.speedup(scalar.mean_ns, simd.mean_ns),
            .output_hash_match = scalar_hash == simd_hash,
        },
    };
}

pub fn createStatusCase(
    allocator: std.mem.Allocator,
    cfg: support.Config,
    case_id: []const u8,
    description: []const u8,
    input: []const u8,
    fallback: []const u8,
) !CaseResult {
    var bench = StatusBench{ .input = input, .fallback = fallback };
    const scalar = try support.measure(StatusBench, allocator, cfg.iterations, cfg.warmup, &bench, StatusBench.runScalar);
    const runtime = try support.measure(StatusBench, allocator, cfg.iterations, cfg.warmup, &bench, StatusBench.runRuntime);
    const scalar_hash = bench.hashScalar();
    const runtime_hash = bench.hashRuntime();
    return .{
        .category = "trace",
        .case_id = case_id,
        .description = description,
        .variants = try buildVariants(allocator, cfg.iterations, cfg.warmup, input.len, input.len, "scalar_reference", scalar, scalar_hash, "runtime", runtime, runtime_hash),
        .comparison = .{
            .baseline_variant = "scalar_reference",
            .candidate_variant = "runtime",
            .speedup = support.speedup(scalar.mean_ns, runtime.mean_ns),
            .output_hash_match = scalar_hash == runtime_hash,
        },
    };
}

pub fn createLexerCase(
    allocator: std.mem.Allocator,
    cfg: support.Config,
    case_id: []const u8,
    description: []const u8,
    source: []const u8,
) !CaseResult {
    var bench = lexer_bench.LexerBench{ .source = source };
    const scalar = try support.measure(lexer_bench.LexerBench, allocator, cfg.iterations, cfg.warmup, &bench, lexer_bench.LexerBench.runScalar);
    const simd = try support.measure(lexer_bench.LexerBench, allocator, cfg.iterations, cfg.warmup, &bench, lexer_bench.LexerBench.runSimd);
    const scalar_digest = lexer_bench.lexWithScalar(source);
    const simd_digest = lexer_bench.lexWithSimd(source);
    return .{
        .category = "lexer",
        .case_id = case_id,
        .description = description,
        .variants = try buildVariants(allocator, cfg.iterations, cfg.warmup, source.len, scalar_digest.count, "scalar", scalar, scalar_digest.hash, "simd", simd, simd_digest.hash),
        .comparison = .{
            .baseline_variant = "scalar",
            .candidate_variant = "simd",
            .speedup = support.speedup(scalar.mean_ns, simd.mean_ns),
            .output_hash_match = scalar_digest.hash == simd_digest.hash and scalar_digest.count == simd_digest.count,
        },
    };
}

pub fn createDotCase(allocator: std.mem.Allocator, cfg: support.Config, lhs: []const f64, rhs: []const f64) !CaseResult {
    var bench = DotBench{ .lhs = lhs, .rhs = rhs };
    const scalar = try support.measure(DotBench, allocator, cfg.iterations, cfg.warmup, &bench, DotBench.runScalar);
    const simd = try support.measure(DotBench, allocator, cfg.iterations, cfg.warmup, &bench, DotBench.runSimd);
    const scalar_value = bench.scalarValue();
    const simd_value = bench.simdValue();
    const diff = @abs(@as(f64, scalar_value) - @as(f64, simd_value));
    const rel = diff / @max(@abs(@as(f64, scalar_value)), 1e-12);
    return .{
        .category = "numeric",
        .case_id = "numeric_dot_4096",
        .description = "Scalar versus SIMD f32 dot accumulation over deterministic f64 inputs.",
        .variants = try buildVariants(
            allocator,
            cfg.iterations,
            cfg.warmup,
            lhs.len * @sizeOf(f64) * 2,
            lhs.len,
            "scalar",
            scalar,
            @as(u64, @as(u32, @bitCast(scalar_value))),
            "simd",
            simd,
            @as(u64, @as(u32, @bitCast(simd_value))),
        ),
        .comparison = .{
            .baseline_variant = "scalar",
            .candidate_variant = "simd",
            .speedup = support.speedup(scalar.mean_ns, simd.mean_ns),
            .output_hash_match = scalar_value == simd_value,
            .max_abs_diff = diff,
            .max_rel_diff = rel,
        },
    };
}

pub fn createSumCase(allocator: std.mem.Allocator, cfg: support.Config, values: []const f64) !CaseResult {
    var bench = SumBench{ .values = values };
    const scalar = try support.measure(SumBench, allocator, cfg.iterations, cfg.warmup, &bench, SumBench.runScalar);
    const simd = try support.measure(SumBench, allocator, cfg.iterations, cfg.warmup, &bench, SumBench.runSimd);
    const scalar_value = bench.scalarValue();
    const simd_value = bench.simdValue();
    const diff = @abs(@as(f64, scalar_value) - @as(f64, simd_value));
    const rel = diff / @max(@abs(@as(f64, scalar_value)), 1e-12);
    return .{
        .category = "numeric",
        .case_id = "numeric_reduce_4096",
        .description = "Scalar versus SIMD f32 reduction over deterministic f64 inputs.",
        .variants = try buildVariants(
            allocator,
            cfg.iterations,
            cfg.warmup,
            values.len * @sizeOf(f64),
            values.len,
            "scalar",
            scalar,
            @as(u64, @as(u32, @bitCast(scalar_value))),
            "simd",
            simd,
            @as(u64, @as(u32, @bitCast(simd_value))),
        ),
        .comparison = .{
            .baseline_variant = "scalar",
            .candidate_variant = "simd",
            .speedup = support.speedup(scalar.mean_ns, simd.mean_ns),
            .output_hash_match = scalar_value == simd_value,
            .max_abs_diff = diff,
            .max_rel_diff = rel,
        },
    };
}

pub fn createAttentionCase(allocator: std.mem.Allocator, cfg: support.Config, bench: *AttentionBench) !CaseResult {
    const iterations = @max(cfg.iterations / 4, 20);
    const warmup = @max(cfg.warmup / 2, 5);
    const scalar = try support.measure(AttentionBench, allocator, iterations, warmup, bench, AttentionBench.runScalar);
    const simd = try support.measure(AttentionBench, allocator, iterations, warmup, bench, AttentionBench.runSimd);
    runAttentionScalar(bench.q, bench.k, bench.v, bench.scale, bench.scalar_weighted, bench.scalar_output);
    runAttentionSimd(bench.q, bench.k, bench.v, bench.scale, bench.simd_weighted, bench.simd_output);
    const envelope = diffEnvelope(bench.scalar_output, bench.simd_output);
    const scalar_hash = support.checksumSlice(std.mem.sliceAsBytes(bench.scalar_output));
    const simd_hash = support.checksumSlice(std.mem.sliceAsBytes(bench.simd_output));
    return .{
        .category = "numeric",
        .case_id = "numeric_attention_seq128_head64",
        .description = "Scalar versus SIMD attention-style weighted reduction with explicit scratch reuse.",
        .variants = try buildVariants(
            allocator,
            iterations,
            warmup,
            (bench.q.len + bench.k.len + bench.v.len) * @sizeOf(f64),
            ATTENTION_SEQ_LEN * ATTENTION_HEAD_DIM,
            "scalar",
            scalar,
            scalar_hash,
            "simd",
            simd,
            simd_hash,
        ),
        .comparison = .{
            .baseline_variant = "scalar",
            .candidate_variant = "simd",
            .speedup = support.speedup(scalar.mean_ns, simd.mean_ns),
            .output_hash_match = scalar_hash == simd_hash,
            .max_abs_diff = envelope.max_abs,
            .max_rel_diff = envelope.max_rel,
        },
    };
}

pub fn createQueueCase(
    allocator: std.mem.Allocator,
    cfg: support.Config,
    linked: *LinkedQueueBench,
    ring: *RingQueueBench,
) !CaseResult {
    const iterations = @max(cfg.iterations / 4, 20);
    const warmup = @max(cfg.warmup / 2, 5);
    const linked_stats = try support.measure(LinkedQueueBench, allocator, iterations, warmup, linked, LinkedQueueBench.run);
    const ring_stats = try support.measure(RingQueueBench, allocator, iterations, warmup, ring, RingQueueBench.run);
    return .{
        .category = "coordination",
        .case_id = "task_queue_submit_drain_4096",
        .description = "Linked per-job heap nodes versus flat ring storage for task-pool-style enqueue and drain.",
        .variants = try buildVariants(
            allocator,
            iterations,
            warmup,
            LINKED_QUEUE_WORK_ITEMS * @sizeOf(usize),
            LINKED_QUEUE_WORK_ITEMS,
            "linked",
            linked_stats,
            linked_stats.checksum,
            "flat_ring",
            ring_stats,
            ring_stats.checksum,
        ),
        .comparison = .{
            .baseline_variant = "linked",
            .candidate_variant = "flat_ring",
            .speedup = support.speedup(linked_stats.mean_ns, ring_stats.mean_ns),
            .output_hash_match = linked_stats.checksum == ring_stats.checksum,
        },
    };
}

pub fn makeWaiterNodes(allocator: std.mem.Allocator) ![]BenchWaitNode {
    const nodes = try allocator.alloc(BenchWaitNode, SINGLEFLIGHT_WAITERS);
    for (nodes, 0..) |*node, index| {
        node.* = .{ .id = index };
    }
    return nodes;
}

pub fn createSingleflightCase(
    allocator: std.mem.Allocator,
    cfg: support.Config,
    flat: *FlatSingleflightBench,
    intrusive: *IntrusiveSingleflightBench,
) !CaseResult {
    const flat_stats = try support.measure(FlatSingleflightBench, allocator, cfg.iterations, cfg.warmup, flat, FlatSingleflightBench.run);
    const intrusive_stats = try support.measure(IntrusiveSingleflightBench, allocator, cfg.iterations, cfg.warmup, intrusive, IntrusiveSingleflightBench.run);
    return .{
        .category = "coordination",
        .case_id = "singleflight_join_take_512",
        .description = "Flat waiter storage versus intrusive waiter chains for join/take reconstruction.",
        .variants = try buildVariants(
            allocator,
            cfg.iterations,
            cfg.warmup,
            SINGLEFLIGHT_WAITERS * @sizeOf(BenchWaitNode),
            SINGLEFLIGHT_WAITERS,
            "flat_waiters",
            flat_stats,
            flat_stats.checksum,
            "intrusive_waiters",
            intrusive_stats,
            intrusive_stats.checksum,
        ),
        .comparison = .{
            .baseline_variant = "flat_waiters",
            .candidate_variant = "intrusive_waiters",
            .speedup = support.speedup(flat_stats.mean_ns, intrusive_stats.mean_ns),
            .output_hash_match = flat_stats.checksum == intrusive_stats.checksum,
        },
    };
}
