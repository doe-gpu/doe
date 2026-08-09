const std = @import("std");
const exec_v1 = @import("../../src/compiler/wgsl/emit/csl/emit_csl_exec_v1.zig");
const host = @import("../../src/compiler/wgsl/emit/csl/emit_csl_host.zig");
const host_plan = @import("../../src/compiler/wgsl/emit/csl/emit_csl_host_plan.zig");
const artifact = @import("../../src/contracts/artifact.zig");

const TEST_ARTIFACT_CAPACITY: usize = 32 * 1024;

fn expectHostPlanEqual(allocator: std.mem.Allocator, expected_artifact: []const u8, actual_artifact: []const u8) !void {
    const expected = try std.json.parseFromSlice(std.json.Value, allocator, expected_artifact, .{});
    defer expected.deinit();
    const actual = try std.json.parseFromSlice(std.json.Value, allocator, actual_artifact, .{});
    defer actual.deinit();
    const expected_host_plan = expected.value.object.get("hostPlan") orelse return error.TestUnexpectedResult;
    const actual_host_plan = actual.value.object.get("hostPlan") orelse return error.TestUnexpectedResult;
    const expected_json = try artifact.jsonStringifyAlloc(allocator, expected_host_plan);
    defer allocator.free(expected_json);
    const actual_json = try artifact.jsonStringifyAlloc(allocator, actual_host_plan);
    defer allocator.free(actual_json);
    try std.testing.expectEqualStrings(expected_json, actual_json);
}

test "opToPattern maps known ops" {
    try std.testing.expectEqualStrings("gather", exec_v1.opToPattern("embed").?);
    try std.testing.expectEqualStrings("attention_decode", exec_v1.opToPattern("attention").?);
    try std.testing.expectEqualStrings("gelu", exec_v1.opToPattern("gelu").?);
    try std.testing.expectEqualStrings("rms_norm", exec_v1.opToPattern("rmsnorm").?);
    try std.testing.expectEqualStrings("residual", exec_v1.opToPattern("residual").?);
    try std.testing.expectEqualStrings("fused_ffn", exec_v1.opToPattern("ffn").?);
    try std.testing.expectEqualStrings("kv_write", exec_v1.opToPattern("kv_write").?);
    try std.testing.expect(exec_v1.opToPattern("unknown_op") == null);
}

test "opToPattern maps Gemma 4 PLE ops" {
    try std.testing.expectEqualStrings("gather", exec_v1.opToPattern("ple_gather").?);
    try std.testing.expectEqualStrings("tiled_matmul", exec_v1.opToPattern("ple_project").?);
    try std.testing.expectEqualStrings("reduction", exec_v1.opToPattern("ple_norm").?);
    try std.testing.expectEqualStrings("element_wise", exec_v1.opToPattern("ple_modulate").?);
}

test "opToPattern maps Gemma 4 hybrid attention and shared KV ops" {
    try std.testing.expectEqualStrings("attention_decode", exec_v1.opToPattern("attention_sliding").?);
    try std.testing.expectEqualStrings("kv_write", exec_v1.opToPattern("kv_write_shared").?);
}

test "ExecStep carries sliding metadata and kv cache alias" {
    const step = exec_v1.ExecStep{
        .phase = .decode,
        .kind = .compute,
        .op = "attention_sliding",
        .kernel_key = "attn_sliding",
        .attention_type = .sliding,
        .sliding_window_size = 512,
        .kv_cache_alias = "layer.0.kv",
    };
    try std.testing.expect(step.attention_type.? == .sliding);
    try std.testing.expectEqual(@as(?u32, 512), step.sliding_window_size);
    try std.testing.expectEqualStrings("layer.0.kv", step.kv_cache_alias.?);
}

test "lowerToHostPlan builds valid plan" {
    const steps = [_]exec_v1.ExecStep{
        .{ .phase = .prefill, .kind = .compute, .op = "embed", .kernel_key = "embed_gather" },
        .{ .phase = .prefill, .kind = .compute, .op = "rmsnorm", .kernel_key = "norm_0" },
        .{ .phase = .decode, .kind = .compute, .op = "attention", .kernel_key = "attn_0" },
        .{ .phase = .decode, .kind = .compute, .name = "lm_head", .op = "matmul", .kernel_key = "lm_head", .weights_key = "lm_head" },
        .{ .phase = .decode, .kind = .sample, .op = "sample", .kernel_key = "sampler" },
    };

    var kernels: [16]host.KernelSpec = undefined;
    var prefill: [16]host.LaunchSpec = undefined;
    var decode: [16]host.LaunchSpec = undefined;

    const plan = try exec_v1.lowerToHostPlan(&steps, .{ .width = 32, .height = 4 }, &kernels, &prefill, &decode);

    try std.testing.expectEqual(@as(u32, 32), plan.pe_grid_width);
    try std.testing.expectEqual(@as(u32, 4), plan.pe_grid_height);
    try std.testing.expect(plan.kernels.len == 5);
    try std.testing.expect(plan.prefill_launches.len == 2);
    try std.testing.expect(plan.decode_launches.len == 3);
}

test "lowerToHostPlan rejects decode before prefill" {
    const steps = [_]exec_v1.ExecStep{
        .{ .phase = .decode, .kind = .compute, .op = "attention", .kernel_key = "attn_0" },
    };

    var kernels: [4]host.KernelSpec = undefined;
    var prefill: [4]host.LaunchSpec = undefined;
    var decode: [4]host.LaunchSpec = undefined;

    try std.testing.expectError(
        error.MalformedStep,
        exec_v1.lowerToHostPlan(&steps, .{ .width = 32, .height = 1 }, &kernels, &prefill, &decode),
    );
}

test "lowerJsonToHostPlan builds valid plan from object steps" {
    const json_payload =
        \\{
        \\  "grid": { "width": 16, "height": 2 },
        \\  "eosTokenId": 7,
        \\  "steps": [
        \\    { "phase": "prefill", "op": "embed", "kernelKey": "embed_gather" },
        \\    { "phase": "prefill", "op": "rmsnorm", "kernelKey": "norm_0" },
        \\    { "phase": "decode", "op": "attention", "kernelKey": "attn_0" },
        \\    { "name": "lm_head", "phase": "decode", "op": "matmul", "kernelKey": "lm_head", "weightsKey": "lm_head" },
        \\    { "phase": "decode", "op": "sample", "kernelKey": "sampler", "kind": "sample" }
        \\  ]
        \\}
    ;

    var kernels: [16]host.KernelSpec = undefined;
    var prefill: [16]host.LaunchSpec = undefined;
    var decode: [16]host.LaunchSpec = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const plan = try exec_v1.lowerJsonToHostPlan(arena.allocator(), json_payload, &kernels, &prefill, &decode);

    try std.testing.expectEqual(@as(u32, 16), plan.pe_grid_width);
    try std.testing.expectEqual(@as(u32, 2), plan.pe_grid_height);
    try std.testing.expectEqual(@as(?u32, 7), plan.eos_token_id);
    try std.testing.expect(plan.kernels.len == 5);
    try std.testing.expect(plan.prefill_launches.len == 2);
    try std.testing.expect(plan.decode_launches.len == 3);
}

test "lowerJsonToHostPlan accepts tuple steps" {
    const json_payload =
        \\{
        \\  "grid": { "width": 8, "height": 1 },
        \\  "steps": [
        \\    ["prefill", "embed", "embed_gather"],
        \\    ["decode", "attention", "attn_0"],
        \\    ["decode", "matmul", "lm_head"],
        \\    ["decode", "sample", "sampler", null, "sample"]
        \\  ]
        \\}
    ;

    var kernels: [16]host.KernelSpec = undefined;
    var prefill: [16]host.LaunchSpec = undefined;
    var decode: [16]host.LaunchSpec = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const plan = try exec_v1.lowerJsonToHostPlan(arena.allocator(), json_payload, &kernels, &prefill, &decode);

    try std.testing.expectEqual(@as(u32, 8), plan.pe_grid_width);
    try std.testing.expectEqual(@as(u32, 1), plan.pe_grid_height);
    try std.testing.expectEqual(@as(?u32, null), plan.eos_token_id);
    try std.testing.expect(plan.prefill_launches.len == 1);
    try std.testing.expect(plan.decode_launches.len == 3);
}

test "lowerJsonToHostPlan rejects mismatched explicit kind" {
    const json_payload =
        \\{
        \\  "grid": { "width": 8, "height": 1 },
        \\  "steps": [
        \\    { "phase": "prefill", "op": "embed", "kernelKey": "embed_gather", "kind": "sample" }
        \\  ]
        \\}
    ;

    var kernels: [4]host.KernelSpec = undefined;
    var prefill: [4]host.LaunchSpec = undefined;
    var decode: [4]host.LaunchSpec = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.MalformedStep, exec_v1.lowerJsonToHostPlan(arena.allocator(), json_payload, &kernels, &prefill, &decode));
}

test "lowerJsonToHostPlan rejects decode before prefill" {
    const json_payload =
        \\{
        \\  "grid": { "width": 8, "height": 1 },
        \\  "steps": [
        \\    { "phase": "decode", "op": "attention", "kernelKey": "attn_0" }
        \\  ]
        \\}
    ;

    var kernels: [4]host.KernelSpec = undefined;
    var prefill: [4]host.LaunchSpec = undefined;
    var decode: [4]host.LaunchSpec = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.MalformedStep, exec_v1.lowerJsonToHostPlan(arena.allocator(), json_payload, &kernels, &prefill, &decode));
}

test "lowerJsonToHostPlan rejects invalid attentionType" {
    const json_payload =
        \\{
        \\  "grid": { "width": 8, "height": 1 },
        \\  "steps": [
        \\    { "phase": "prefill", "op": "embed", "kernelKey": "embed_gather" },
        \\    { "phase": "decode", "op": "attention", "kernelKey": "attn_0", "attentionType": "local" }
        \\  ]
        \\}
    ;

    var kernels: [4]host.KernelSpec = undefined;
    var prefill: [4]host.LaunchSpec = undefined;
    var decode: [4]host.LaunchSpec = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidJson, exec_v1.lowerJsonToHostPlan(arena.allocator(), json_payload, &kernels, &prefill, &decode));
}

test "lowerJsonToHostPlan derives Gemma 4 routing from layerPattern and decode position state" {
    const json_payload =
        \\{
        \\  "grid": { "width": 8, "height": 1 },
        \\  "slidingWindowSize": 512,
        \\  "layerPattern": { "type": "every_n", "period": 2, "offset": 1 },
        \\  "steps": [
        \\    { "phase": "prefill", "op": "embed", "kernelKey": "embed_gather" },
        \\    { "phase": "decode", "op": "attention", "kernelKey": "attn_local" },
        \\    { "phase": "decode", "op": "kv_write", "kernelKey": "kv_write" },
        \\    { "phase": "decode", "op": "attention", "kernelKey": "attn_global" },
        \\    { "name": "lm_head", "phase": "decode", "op": "matmul", "kernelKey": "lm_head", "weightsKey": "lm_head" },
        \\    { "phase": "decode", "op": "sample", "kernelKey": "sampler", "kind": "sample" }
        \\  ]
        \\}
    ;

    var kernels: [8]host.KernelSpec = undefined;
    var prefill: [8]host.LaunchSpec = undefined;
    var decode: [8]host.LaunchSpec = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const plan = try exec_v1.lowerJsonToHostPlan(arena.allocator(), json_payload, &kernels, &prefill, &decode);

    try std.testing.expectEqual(@as(usize, 1), plan.prefill_launches.len);
    try std.testing.expectEqual(@as(usize, 5), plan.decode_launches.len);
    try std.testing.expect(plan.decode_launches[0].attention_type.? == .sliding);
    try std.testing.expectEqual(@as(?u32, 512), plan.decode_launches[0].sliding_window_size);
    try std.testing.expect(plan.decode_launches[0].current_pos_source.? == .decode_position);
    try std.testing.expect(plan.decode_launches[1].current_pos_source.? == .decode_position);
    try std.testing.expect(plan.decode_launches[2].attention_type.? == .global);
    try std.testing.expect(plan.decode_launches[2].sliding_window_size == null);
}

test "lowerJsonToHostPlan derives grid from model config when grid is omitted" {
    const json_payload =
        \\{
        \\  "modelConfig": {
        \\    "hiddenDim": 1536,
        \\    "numHeads": 8,
        \\    "headDim": 512,
        \\    "numLayers": 35,
        \\    "vocabSize": 262144,
        \\    "maxSeqLen": 4096,
        \\    "quantFormat": "q4k",
        \\    "ffnExpansionFactor": 4,
        \\    "ffnMatrixCount": 3,
        \\    "pleWidth": 256,
        \\    "pleVocabSize": 262144
        \\  },
        \\  "slidingWindowSize": 512,
        \\  "steps": [
        \\    { "phase": "prefill", "op": "embed", "kernelKey": "embed_gather" },
        \\    { "phase": "decode", "op": "attention_sliding", "kernelKey": "attn_local", "attentionType": "sliding" },
        \\    { "phase": "decode", "op": "kv_write", "kernelKey": "kv_write" },
        \\    { "name": "lm_head", "phase": "decode", "op": "matmul", "kernelKey": "lm_head", "weightsKey": "lm_head" },
        \\    { "phase": "decode", "op": "sample", "kernelKey": "sampler", "kind": "sample" }
        \\  ]
        \\}
    ;

    var kernels: [8]host.KernelSpec = undefined;
    var prefill: [8]host.LaunchSpec = undefined;
    var decode: [8]host.LaunchSpec = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const plan = try exec_v1.lowerJsonToHostPlan(arena.allocator(), json_payload, &kernels, &prefill, &decode);
    try std.testing.expectEqual(@as(u32, 141), plan.pe_grid_width);
    try std.testing.expectEqual(@as(u32, 120), plan.pe_grid_height);
}

test "lowerJsonToHostPlan lowers shared kv launch metadata" {
    const json_payload =
        \\{
        \\  "grid": { "width": 8, "height": 1 },
        \\  "slidingWindowSize": 512,
        \\  "numKvSharedLayers": 4,
        \\  "steps": [
        \\    { "phase": "prefill", "op": "embed", "kernelKey": "embed_gather" },
        \\    { "phase": "decode", "op": "attention_sliding", "kernelKey": "attn_local", "attentionType": "sliding" },
        \\    { "phase": "decode", "op": "kv_write_shared", "kernelKey": "kv_shared", "kvCacheAlias": "layer.0.kv" },
        \\    { "name": "lm_head", "phase": "decode", "op": "matmul", "kernelKey": "lm_head", "weightsKey": "lm_head" },
        \\    { "phase": "decode", "op": "sample", "kernelKey": "sampler", "kind": "sample" }
        \\  ]
        \\}
    ;

    var kernels: [8]host.KernelSpec = undefined;
    var prefill: [8]host.LaunchSpec = undefined;
    var decode: [8]host.LaunchSpec = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const plan = try exec_v1.lowerJsonToHostPlan(arena.allocator(), json_payload, &kernels, &prefill, &decode);

    try std.testing.expectEqual(@as(usize, 5), plan.kernels.len);
    try std.testing.expectEqual(@as(usize, 1), plan.prefill_launches.len);
    try std.testing.expectEqual(@as(usize, 4), plan.decode_launches.len);
    try std.testing.expect(plan.decode_launches[0].attention_type.? == .sliding);
    try std.testing.expectEqual(@as(?u32, 512), plan.decode_launches[0].sliding_window_size);
    try std.testing.expect(plan.decode_launches[0].current_pos_source.? == .decode_position);
    try std.testing.expect(plan.decode_launches[1].current_pos_source.? == .decode_position);
    try std.testing.expectEqualStrings("layer.0.kv", plan.decode_launches[1].kv_cache_alias.?);
}

test "lowerJsonToHostPlan rejects shared kv without shared-kv metadata" {
    const json_payload =
        \\{
        \\  "grid": { "width": 8, "height": 1 },
        \\  "steps": [
        \\    { "phase": "prefill", "op": "embed", "kernelKey": "embed_gather" },
        \\    { "phase": "decode", "op": "kv_write_shared", "kernelKey": "kv_shared", "kvCacheAlias": "layer.0.kv" },
        \\    { "phase": "decode", "op": "sample", "kernelKey": "sampler", "kind": "sample" }
        \\  ]
        \\}
    ;

    var kernels: [8]host.KernelSpec = undefined;
    var prefill: [8]host.LaunchSpec = undefined;
    var decode: [8]host.LaunchSpec = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.MalformedStep, exec_v1.lowerJsonToHostPlan(arena.allocator(), json_payload, &kernels, &prefill, &decode));
}

test "lowerManifestExecutionToHostPlan accepts Gemma 4 launch metadata" {
    const json_payload =
        \\{
        \\  "grid": { "width": 8, "height": 1 },
        \\  "slidingWindowSize": 512,
        \\  "numKvSharedLayers": 4,
        \\  "layerPattern": { "type": "every_n", "period": 5, "offset": 4 },
        \\  "steps": [
        \\    { "phase": "prefill", "op": "embed", "kernelKey": "embed" },
        \\    { "phase": "decode", "op": "attention_sliding", "kernelKey": "attn_decode_sliding", "attentionType": "sliding" },
        \\    { "phase": "decode", "op": "kv_write_shared", "kernelKey": "kv_write_shared", "kvCacheAlias": "layer.0.kv" },
        \\    { "name": "lm_head", "phase": "decode", "op": "matmul", "kernelKey": "lm_head", "weightsKey": "lm_head" },
        \\    { "phase": "decode", "op": "sample", "kernelKey": "sample", "kind": "sample" }
        \\  ]
        \\}
    ;

    var kernels: [8]host.KernelSpec = undefined;
    var prefill: [8]host.LaunchSpec = undefined;
    var decode: [8]host.LaunchSpec = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const plan = try exec_v1.lowerManifestExecutionToHostPlan(arena.allocator(), json_payload, &kernels, &prefill, &decode);
    try std.testing.expectEqual(@as(usize, 1), plan.prefill_launches.len);
    try std.testing.expectEqual(@as(usize, 4), plan.decode_launches.len);
    try std.testing.expect(plan.decode_launches[0].attention_type.? == .sliding);
    try std.testing.expectEqual(@as(?u32, 512), plan.decode_launches[0].sliding_window_size);
    try std.testing.expectEqualStrings("layer.0.kv", plan.decode_launches[1].kv_cache_alias.?);
}

test "Gemma 3 smoke fixture lowers to golden host plan artifact" {
    const fixture_json = @embedFile("../../examples/execution-v1/gemma-3-270m-smoke.json");
    const golden_artifact = @embedFile("../../examples/doe-wgsl-host-plan.gemma-3-270m-smoke.json");

    var kernels: [32]host.KernelSpec = undefined;
    var prefill: [32]host.LaunchSpec = undefined;
    var decode: [32]host.LaunchSpec = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const plan = try exec_v1.lowerJsonToHostPlan(arena.allocator(), fixture_json, &kernels, &prefill, &decode);

    const targets = [_]host_plan.CompileTarget{
        .{ .kernel_name = "embed", .pattern = "gather", .layout_path = "embed/layout.csl", .pe_program_path = "embed/pe_program.csl" },
        .{ .kernel_name = "rmsnorm", .pattern = "rms_norm", .layout_path = "rmsnorm/layout.csl", .pe_program_path = "rmsnorm/pe_program.csl" },
        .{ .kernel_name = "rmsnorm_prefill", .pattern = "rms_norm", .layout_path = "rmsnorm/layout.csl", .pe_program_path = "rmsnorm/pe_program.csl" },
        .{ .kernel_name = "rmsnorm_decode", .pattern = "rms_norm", .layout_path = "rmsnorm/layout.csl", .pe_program_path = "rmsnorm/pe_program.csl" },
        .{ .kernel_name = "tiled", .pattern = "tiled_matmul", .layout_path = "tiled/layout.csl", .pe_program_path = "tiled/pe_program.csl" },
        .{ .kernel_name = "rope", .pattern = "rope", .layout_path = "rope/layout.csl", .pe_program_path = "rope/pe_program.csl" },
        .{ .kernel_name = "attn_small", .pattern = "attention_tiled", .layout_path = "attn_small/layout.csl", .pe_program_path = "attn_small/pe_program.csl" },
        .{ .kernel_name = "residual", .pattern = "residual", .layout_path = "residual/layout.csl", .pe_program_path = "residual/pe_program.csl" },
        .{ .kernel_name = "residual_prefill", .pattern = "residual", .layout_path = "residual/layout.csl", .pe_program_path = "residual/pe_program.csl" },
        .{ .kernel_name = "residual_decode", .pattern = "residual", .layout_path = "residual/layout.csl", .pe_program_path = "residual/pe_program.csl" },
        .{ .kernel_name = "gelu", .pattern = "gelu", .layout_path = "gelu/layout.csl", .pe_program_path = "gelu/pe_program.csl" },
        .{ .kernel_name = "gelu_prefill", .pattern = "gelu", .layout_path = "gelu/layout.csl", .pe_program_path = "gelu/pe_program.csl" },
        .{ .kernel_name = "gelu_decode", .pattern = "gelu", .layout_path = "gelu/layout.csl", .pe_program_path = "gelu/pe_program.csl" },
        .{ .kernel_name = "gemv", .pattern = "fused_gemv_dequant", .layout_path = "gemv/layout.csl", .pe_program_path = "gemv/pe_program.csl" },
        .{ .kernel_name = "attn_decode", .pattern = "attention_decode", .layout_path = "attn_decode/layout.csl", .pe_program_path = "attn_decode/pe_program.csl" },
        .{ .kernel_name = "sample", .pattern = "sample", .layout_path = "sample/layout.csl", .pe_program_path = "sample/pe_program.csl" },
    };
    const cslc_plan = try host_plan.makeCslcPlan(null);

    var artifact_buf: [TEST_ARTIFACT_CAPACITY]u8 = undefined;
    var artifact_pos: usize = 0;
    try host_plan.emitHostPlanArtifactJson(&artifact_buf, &artifact_pos, plan, &targets, cslc_plan);
    try host_plan.validateHostPlanArtifactJson(std.testing.allocator, artifact_buf[0..artifact_pos]);
    try host_plan.validateHostPlanArtifactJson(std.testing.allocator, golden_artifact);
    try expectHostPlanEqual(std.testing.allocator, golden_artifact, artifact_buf[0..artifact_pos]);
}

test "Gemma 3 manifest fixture lowers to the same golden host plan artifact" {
    const fixture_json = @embedFile("../../examples/execution-v1/gemma-3-270m-manifest-smoke.json");
    const golden_artifact = @embedFile("../../examples/doe-wgsl-host-plan.gemma-3-270m-manifest-smoke.json");

    var kernels: [32]host.KernelSpec = undefined;
    var prefill: [32]host.LaunchSpec = undefined;
    var decode: [32]host.LaunchSpec = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const plan = try exec_v1.lowerManifestExecutionToHostPlan(arena.allocator(), fixture_json, &kernels, &prefill, &decode);

    const targets = [_]host_plan.CompileTarget{
        .{ .kernel_name = "embed", .pattern = "gather", .layout_path = "embed/layout.csl", .pe_program_path = "embed/pe_program.csl" },
        .{ .kernel_name = "rmsnorm", .pattern = "rms_norm", .layout_path = "rmsnorm/layout.csl", .pe_program_path = "rmsnorm/pe_program.csl" },
        .{ .kernel_name = "rmsnorm_prefill", .pattern = "rms_norm", .layout_path = "rmsnorm/layout.csl", .pe_program_path = "rmsnorm/pe_program.csl" },
        .{ .kernel_name = "rmsnorm_decode", .pattern = "rms_norm", .layout_path = "rmsnorm/layout.csl", .pe_program_path = "rmsnorm/pe_program.csl" },
        .{ .kernel_name = "tiled", .pattern = "tiled_matmul", .layout_path = "tiled/layout.csl", .pe_program_path = "tiled/pe_program.csl" },
        .{ .kernel_name = "rope", .pattern = "rope", .layout_path = "rope/layout.csl", .pe_program_path = "rope/pe_program.csl" },
        .{ .kernel_name = "attn_small", .pattern = "attention_tiled", .layout_path = "attn_small/layout.csl", .pe_program_path = "attn_small/pe_program.csl" },
        .{ .kernel_name = "residual", .pattern = "residual", .layout_path = "residual/layout.csl", .pe_program_path = "residual/pe_program.csl" },
        .{ .kernel_name = "residual_prefill", .pattern = "residual", .layout_path = "residual/layout.csl", .pe_program_path = "residual/pe_program.csl" },
        .{ .kernel_name = "residual_decode", .pattern = "residual", .layout_path = "residual/layout.csl", .pe_program_path = "residual/pe_program.csl" },
        .{ .kernel_name = "gelu", .pattern = "gelu", .layout_path = "gelu/layout.csl", .pe_program_path = "gelu/pe_program.csl" },
        .{ .kernel_name = "gelu_prefill", .pattern = "gelu", .layout_path = "gelu/layout.csl", .pe_program_path = "gelu/pe_program.csl" },
        .{ .kernel_name = "gelu_decode", .pattern = "gelu", .layout_path = "gelu/layout.csl", .pe_program_path = "gelu/pe_program.csl" },
        .{ .kernel_name = "gemv", .pattern = "fused_gemv_dequant", .layout_path = "gemv/layout.csl", .pe_program_path = "gemv/pe_program.csl" },
        .{ .kernel_name = "attn_decode", .pattern = "attention_decode", .layout_path = "attn_decode/layout.csl", .pe_program_path = "attn_decode/pe_program.csl" },
        .{ .kernel_name = "sample", .pattern = "sample", .layout_path = "sample/layout.csl", .pe_program_path = "sample/pe_program.csl" },
    };
    const cslc_plan = try host_plan.makeCslcPlan(null);

    var artifact_buf: [TEST_ARTIFACT_CAPACITY]u8 = undefined;
    var artifact_pos: usize = 0;
    try host_plan.emitHostPlanArtifactJson(&artifact_buf, &artifact_pos, plan, &targets, cslc_plan);
    try host_plan.validateHostPlanArtifactJson(std.testing.allocator, artifact_buf[0..artifact_pos]);
    try host_plan.validateHostPlanArtifactJson(std.testing.allocator, golden_artifact);
    try expectHostPlanEqual(std.testing.allocator, golden_artifact, artifact_buf[0..artifact_pos]);
}

test "Gemma 4 smoke fixture lowers to golden host plan artifact" {
    const fixture_json = @embedFile("../../examples/execution-v1/gemma-4-e2b-smoke.json");
    const golden_artifact = @embedFile("../../examples/doe-wgsl-host-plan.gemma-4-e2b-smoke.json");

    var kernels: [48]host.KernelSpec = undefined;
    var prefill: [48]host.LaunchSpec = undefined;
    var decode: [48]host.LaunchSpec = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const plan = try exec_v1.lowerJsonToHostPlan(arena.allocator(), fixture_json, &kernels, &prefill, &decode);

    const targets = [_]host_plan.CompileTarget{
        .{ .kernel_name = "embed", .pattern = "gather", .layout_path = "embed/layout.csl", .pe_program_path = "embed/pe_program.csl" },
        .{ .kernel_name = "ple_embed", .pattern = "gather", .layout_path = "ple_embed/layout.csl", .pe_program_path = "ple_embed/pe_program.csl" },
        .{ .kernel_name = "ple_proj", .pattern = "tiled_matmul", .layout_path = "ple_proj/layout.csl", .pe_program_path = "ple_proj/pe_program.csl" },
        .{ .kernel_name = "ple_rmsnorm", .pattern = "reduction", .layout_path = "ple_rmsnorm/layout.csl", .pe_program_path = "ple_rmsnorm/pe_program.csl" },
        .{ .kernel_name = "ple_residual", .pattern = "element_wise", .layout_path = "ple_residual/layout.csl", .pe_program_path = "ple_residual/pe_program.csl" },
        .{ .kernel_name = "rmsnorm", .pattern = "rms_norm", .layout_path = "rmsnorm/layout.csl", .pe_program_path = "rmsnorm/pe_program.csl" },
        .{ .kernel_name = "rmsnorm_prefill", .pattern = "rms_norm", .layout_path = "rmsnorm/layout.csl", .pe_program_path = "rmsnorm/pe_program.csl" },
        .{ .kernel_name = "rmsnorm_decode", .pattern = "rms_norm", .layout_path = "rmsnorm/layout.csl", .pe_program_path = "rmsnorm/pe_program.csl" },
        .{ .kernel_name = "tiled", .pattern = "tiled_matmul", .layout_path = "tiled/layout.csl", .pe_program_path = "tiled/pe_program.csl" },
        .{ .kernel_name = "rope", .pattern = "rope", .layout_path = "rope/layout.csl", .pe_program_path = "rope/pe_program.csl" },
        .{ .kernel_name = "attn_small", .pattern = "attention_tiled", .layout_path = "attn_small/layout.csl", .pe_program_path = "attn_small/pe_program.csl" },
        .{ .kernel_name = "residual", .pattern = "residual", .layout_path = "residual/layout.csl", .pe_program_path = "residual/pe_program.csl" },
        .{ .kernel_name = "residual_prefill", .pattern = "residual", .layout_path = "residual/layout.csl", .pe_program_path = "residual/pe_program.csl" },
        .{ .kernel_name = "residual_decode", .pattern = "residual", .layout_path = "residual/layout.csl", .pe_program_path = "residual/pe_program.csl" },
        .{ .kernel_name = "gelu", .pattern = "gelu", .layout_path = "gelu/layout.csl", .pe_program_path = "gelu/pe_program.csl" },
        .{ .kernel_name = "gelu_prefill", .pattern = "gelu", .layout_path = "gelu/layout.csl", .pe_program_path = "gelu/pe_program.csl" },
        .{ .kernel_name = "gelu_decode", .pattern = "gelu", .layout_path = "gelu/layout.csl", .pe_program_path = "gelu/pe_program.csl" },
        .{ .kernel_name = "gemv", .pattern = "fused_gemv_dequant", .layout_path = "gemv/layout.csl", .pe_program_path = "gemv/pe_program.csl" },
        .{ .kernel_name = "kv_write", .pattern = "kv_write", .layout_path = "kv_write/layout.csl", .pe_program_path = "kv_write/pe_program.csl" },
        .{ .kernel_name = "attn_decode_sliding", .pattern = "attention_decode", .layout_path = "attn_decode_sliding/layout.csl", .pe_program_path = "attn_decode_sliding/pe_program.csl" },
        .{ .kernel_name = "kv_write_shared", .pattern = "kv_write", .layout_path = "kv_write_shared/layout.csl", .pe_program_path = "kv_write_shared/pe_program.csl" },
        .{ .kernel_name = "attn_decode", .pattern = "attention_decode", .layout_path = "attn_decode/layout.csl", .pe_program_path = "attn_decode/pe_program.csl" },
        .{ .kernel_name = "sample", .pattern = "sample", .layout_path = "sample/layout.csl", .pe_program_path = "sample/pe_program.csl" },
    };
    const cslc_plan = try host_plan.makeCslcPlan(null);

    var artifact_buf: [TEST_ARTIFACT_CAPACITY]u8 = undefined;
    var artifact_pos: usize = 0;
    try host_plan.emitHostPlanArtifactJson(&artifact_buf, &artifact_pos, plan, &targets, cslc_plan);
    try host_plan.validateHostPlanArtifactJson(std.testing.allocator, artifact_buf[0..artifact_pos]);
    try host_plan.validateHostPlanArtifactJson(std.testing.allocator, golden_artifact);
    try expectHostPlanEqual(std.testing.allocator, golden_artifact, artifact_buf[0..artifact_pos]);
}
