// emit_csl_host_plan.zig — Schema-backed HostPlan artifact emission.
//
// This module serializes and validates the explicit host-plan artifact used by
// the CSL toolchain emitter. It keeps the schema deterministic and checks the
// emitted JSON shape before it leaves the Zig runtime path.

const std = @import("std");
const host = @import("emit_csl_host.zig");
const spec = @import("csl_spec.zig");

const PHASE_TARGET_SUFFIXES = [_][]const u8{ "_prefill", "_decode" };
const PHASE_SPECIALIZED_KERNELS = [_][]const u8{ "rmsnorm", "residual", "gelu", "gelu_gated", "silu_gated", "sigmoid_gated" };
const DENSE_GEMV_COMPILE_TILE_MARKER: []const u8 = "_width_tile_x";

pub const EmitError = error{
    OutputTooLarge,
    InvalidIr,
    InvalidSchema,
    UnsupportedSchemaVersion,
};

pub const CompileTarget = struct {
    kernel_name: []const u8,
    pattern: []const u8,
    layout_path: []const u8,
    pe_program_path: []const u8,
    metadata: ?CompileTargetMetadata = null,
    compile_params: []const CompileParam = &.{},
    compile_blocked_reason: ?[]const u8 = null,
    /// "prefill" / "decode" when the target was produced as a phase variant
    /// of a phase-specialized kernel; null for base targets.
    phase: ?[]const u8 = null,
    /// Base kernel name when this target is a phase variant; equal to
    /// `kernel_name` for base targets.
    base_kernel: ?[]const u8 = null,
};

pub const CompileParam = struct {
    name: []const u8,
    value: u32,
};

pub const CompileTargetMetadata = struct {
    target_phase: []const u8,
    bindings: []const BindingMetadata,
};

pub const BindingMetadata = struct {
    symbol: []const u8,
    access: []const u8,
    elem_type: []const u8,
    binding_shape: BindingShape,
    per_pe_shape: BindingShape,
    staging_transform: ?BindingTransform = null,
    detile_transform: ?BindingTransform = null,
    weight_source: ?[]const u8 = null,
};

pub const BindingShape = struct {
    kind: []const u8 = "csl_array",
    elements: []const u8,
};

pub const BindingTransform = struct {
    kind: []const u8,
    matrix_role: ?[]const u8 = null,
    rows_from_input: ?[]const u8 = null,
};

pub const DiscoveryMode = enum {
    explicit_config,
    implicit_path_lookup,
};

pub const CslcPlan = struct {
    executable: []const u8,
    discovery: DiscoveryMode,
    minimum_version: []const u8 = spec.CSLC_SDK_MIN_VERSION,
};

pub fn makeCslcPlan(executable: ?[]const u8) EmitError!CslcPlan {
    if (executable) |path| {
        if (path.len == 0) return error.InvalidIr;
        return .{
            .executable = path,
            .discovery = .explicit_config,
        };
    }

    return .{
        .executable = "cslc",
        .discovery = .implicit_path_lookup,
    };
}

pub fn discoveryLabel(discovery: DiscoveryMode) []const u8 {
    return switch (discovery) {
        .explicit_config => spec.HOST_PLAN_DISCOVERY_EXPLICIT_CONFIG,
        .implicit_path_lookup => spec.HOST_PLAN_DISCOVERY_IMPLICIT_PATH_LOOKUP,
    };
}

pub fn emitCompileTargetMetadataJson(
    buf: []u8,
    pos: *usize,
    metadata: CompileTargetMetadata,
) EmitError!void {
    try write(buf, pos, "\"metadata\": {\n");
    try write(buf, pos, "        \"targetPhase\": ");
    try writeJsonString(buf, pos, metadata.target_phase);
    try write(buf, pos, ",\n        \"bindings\": [\n");
    for (metadata.bindings, 0..) |binding, idx| {
        try write(buf, pos, "          { \"symbol\": ");
        try writeJsonString(buf, pos, binding.symbol);
        try write(buf, pos, ", \"access\": ");
        try writeJsonString(buf, pos, binding.access);
        try write(buf, pos, ", \"elemType\": ");
        try writeJsonString(buf, pos, binding.elem_type);
        try write(buf, pos, ", \"bindingShape\": ");
        try emitBindingShapeJson(buf, pos, binding.binding_shape);
        try write(buf, pos, ", \"perPeShape\": ");
        try emitBindingShapeJson(buf, pos, binding.per_pe_shape);
        try write(buf, pos, ", \"stagingTransform\": ");
        try emitBindingTransformJson(buf, pos, binding.staging_transform);
        try write(buf, pos, ", \"detileTransform\": ");
        try emitBindingTransformJson(buf, pos, binding.detile_transform);
        try write(buf, pos, ", \"weightSource\": ");
        if (binding.weight_source) |weight_source| {
            try writeJsonString(buf, pos, weight_source);
        } else {
            try write(buf, pos, "null");
        }
        try write(buf, pos, " }");
        if (idx + 1 < metadata.bindings.len) try write(buf, pos, ",");
        try write(buf, pos, "\n");
    }
    try write(buf, pos, "        ]\n      }");
}

pub fn emitCompileParamsFieldJson(
    buf: []u8,
    pos: *usize,
    compile_params: []const CompileParam,
) EmitError!void {
    if (compile_params.len == 0) return;
    try write(buf, pos, ", \"compileParams\": {");
    for (compile_params, 0..) |param, idx| {
        if (idx > 0) try write(buf, pos, ",");
        try write(buf, pos, " ");
        try writeJsonString(buf, pos, param.name);
        try write(buf, pos, ": ");
        try writeInt(buf, pos, param.value);
    }
    try write(buf, pos, " }");
}

fn emitBindingShapeJson(buf: []u8, pos: *usize, shape: BindingShape) EmitError!void {
    try write(buf, pos, "{ \"kind\": ");
    try writeJsonString(buf, pos, shape.kind);
    try write(buf, pos, ", \"elements\": ");
    try writeJsonString(buf, pos, shape.elements);
    try write(buf, pos, " }");
}

fn emitBindingTransformJson(
    buf: []u8,
    pos: *usize,
    transform: ?BindingTransform,
) EmitError!void {
    if (transform) |value| {
        try write(buf, pos, "{ \"kind\": ");
        try writeJsonString(buf, pos, value.kind);
        if (value.matrix_role) |matrix_role| {
            try write(buf, pos, ", \"matrixRole\": ");
            try writeJsonString(buf, pos, matrix_role);
        }
        if (value.rows_from_input) |rows_from_input| {
            try write(buf, pos, ", \"rowsFromInput\": ");
            try writeJsonString(buf, pos, rows_from_input);
        }
        try write(buf, pos, " }");
    } else {
        try write(buf, pos, "null");
    }
}

/// Emits the explicit HostPlan artifact schema used by the CSL toolchain.
pub fn emitHostPlanArtifactJson(
    buf: []u8,
    pos: *usize,
    plan: host.HostPlan,
    targets: []const CompileTarget,
    cslc_plan: ?CslcPlan,
) EmitError!void {
    try validateHostPlan(plan, targets, cslc_plan);

    try write(buf, pos, "{\n");
    try write(buf, pos, "  \"schemaVersion\": ");
    try writeInt(buf, pos, spec.HOST_PLAN_SCHEMA_VERSION);
    try write(buf, pos, ",\n  \"artifactKind\": ");
    try writeJsonString(buf, pos, spec.HOST_PLAN_ARTIFACT_KIND);
    try write(buf, pos, ",\n  \"target\": ");
    try writeJsonString(buf, pos, spec.HOST_PLAN_TARGET);
    try write(buf, pos, ",\n  \"contract\": ");
    try writeJsonString(buf, pos, spec.HOST_PLAN_CONTRACT);
    try write(buf, pos, ",\n");

    try write(buf, pos, "  \"hostPlan\": {\n");
    try write(buf, pos, "    \"peGrid\": { \"width\": ");
    try writeInt(buf, pos, plan.pe_grid_width);
    try write(buf, pos, ", \"height\": ");
    try writeInt(buf, pos, plan.pe_grid_height);
    try write(buf, pos, " },\n");

    try write(buf, pos, "    \"kernels\": [\n");
    for (plan.kernels, 0..) |kernel, idx| {
        try write(buf, pos, "      { \"name\": ");
        try writeJsonString(buf, pos, kernel.name);
        try write(buf, pos, ", \"pattern\": ");
        try writeJsonString(buf, pos, kernel.pattern);
        try write(buf, pos, ", \"count\": ");
        try writeInt(buf, pos, kernel.count);
        try write(buf, pos, " }");
        if (idx + 1 < plan.kernels.len) try write(buf, pos, ",");
        try write(buf, pos, "\n");
    }
    try write(buf, pos, "    ],\n");

    try write(buf, pos, "    \"phases\": {\n");
    try write(buf, pos, "      \"prefill\": [\n");
    try emitLaunchSpecsJson(buf, pos, plan.prefill_launches);
    try write(buf, pos, "      ],\n");
    try write(buf, pos, "      \"decode\": [\n");
    try emitLaunchSpecsJson(buf, pos, plan.decode_launches);
    try write(buf, pos, "      ]\n");
    try write(buf, pos, "    },\n");

    try write(buf, pos, "    \"eosTokenId\": ");
    if (plan.eos_token_id) |eos_token_id| {
        try writeInt(buf, pos, eos_token_id);
    } else {
        try write(buf, pos, "null");
    }
    try write(buf, pos, "\n  },\n");

    try write(buf, pos, "  \"compileTargets\": [\n");
    for (targets, 0..) |target, idx| {
        try write(buf, pos, "    { \"name\": ");
        try writeJsonString(buf, pos, target.kernel_name);
        try write(buf, pos, ", \"pattern\": ");
        try writeJsonString(buf, pos, target.pattern);
        try write(buf, pos, ", \"layout\": ");
        try writeJsonString(buf, pos, target.layout_path);
        try write(buf, pos, ", \"peProgram\": ");
        try writeJsonString(buf, pos, target.pe_program_path);
        try emitCompileParamsFieldJson(buf, pos, target.compile_params);
        try write(buf, pos, " }");
        if (idx + 1 < targets.len) try write(buf, pos, ",");
        try write(buf, pos, "\n");
    }
    try write(buf, pos, "  ]");

    if (cslc_plan) |plan_cslc| {
        try write(buf, pos, ",\n  \"cslc\": {\n");
        try write(buf, pos, "    \"executable\": ");
        try writeJsonString(buf, pos, plan_cslc.executable);
        try write(buf, pos, ",\n    \"discovery\": ");
        try writeJsonString(buf, pos, discoveryLabel(plan_cslc.discovery));
        try write(buf, pos, ",\n    \"validation\": {\n");
        try write(buf, pos, "      \"command\": [");
        try writeJsonString(buf, pos, plan_cslc.executable);
        try write(buf, pos, ", ");
        try writeJsonString(buf, pos, spec.CSLC_VERSION_ARG);
        try write(buf, pos, "],\n      \"minimumVersion\": ");
        try writeJsonString(buf, pos, plan_cslc.minimum_version);
        try write(buf, pos, "\n    }\n  }");
    }

    try write(buf, pos, "\n}\n");
}

pub fn validateHostPlanArtifactJson(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) EmitError!void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .ignore_unknown_fields = false,
    }) catch return error.InvalidSchema;
    defer parsed.deinit();

    try validateArtifactValue(parsed.value);
}

fn validateArtifactValue(root: std.json.Value) EmitError!void {
    const root_obj = expectObject(root, "root") orelse return error.InvalidSchema;

    const schema_version = jsonToU32(root_obj.get("schemaVersion")) orelse return error.InvalidSchema;
    if (schema_version != spec.HOST_PLAN_SCHEMA_VERSION) return error.UnsupportedSchemaVersion;

    const artifact_kind = expectString(root_obj.get("artifactKind"), "artifactKind") orelse return error.InvalidSchema;
    if (!std.mem.eql(u8, artifact_kind, spec.HOST_PLAN_ARTIFACT_KIND)) return error.InvalidSchema;

    const target = expectString(root_obj.get("target"), "target") orelse return error.InvalidSchema;
    if (!std.mem.eql(u8, target, spec.HOST_PLAN_TARGET)) return error.InvalidSchema;
    const contract = expectString(root_obj.get("contract"), "contract") orelse return error.InvalidSchema;
    if (!std.mem.eql(u8, contract, spec.HOST_PLAN_CONTRACT)) return error.InvalidSchema;

    try validateHostPlanValue(root_obj.get("hostPlan") orelse return error.InvalidSchema);
    try validateCompileTargetsValue(root_obj.get("compileTargets") orelse return error.InvalidSchema);

    if (root_obj.get("cslc")) |raw_cslc| {
        try validateCslcValue(raw_cslc);
    }
}

fn validateHostPlanValue(raw: std.json.Value) EmitError!void {
    const obj = expectObject(raw, "hostPlan") orelse return error.InvalidSchema;

    const pe_grid = expectObject(obj.get("peGrid") orelse return error.InvalidSchema, "peGrid") orelse return error.InvalidSchema;
    const width = jsonToU32(pe_grid.get("width")) orelse return error.InvalidSchema;
    const height = jsonToU32(pe_grid.get("height")) orelse return error.InvalidSchema;
    if (width == 0 or height == 0) return error.InvalidSchema;

    try validateKernelArray(obj.get("kernels") orelse return error.InvalidSchema);

    const phases = expectObject(obj.get("phases") orelse return error.InvalidSchema, "phases") orelse return error.InvalidSchema;
    try validateLaunchArray(phases.get("prefill") orelse return error.InvalidSchema);
    try validateLaunchArray(phases.get("decode") orelse return error.InvalidSchema);

    if (obj.get("eosTokenId")) |raw_eos| {
        if (raw_eos != .null and jsonToU32(raw_eos) == null) return error.InvalidSchema;
    } else {
        return error.InvalidSchema;
    }
}

fn validateKernelArray(raw: std.json.Value) EmitError!void {
    switch (raw) {
        .array => |arr| {
            for (arr.items) |item| {
                const obj = expectObject(item, "kernel") orelse return error.InvalidSchema;
                const name = expectString(obj.get("name"), "kernel.name") orelse return error.InvalidSchema;
                const pattern = expectString(obj.get("pattern"), "kernel.pattern") orelse return error.InvalidSchema;
                const count = jsonToU32(obj.get("count")) orelse return error.InvalidSchema;
                if (name.len == 0 or pattern.len == 0 or count == 0) return error.InvalidSchema;
            }
        },
        else => return error.InvalidSchema,
    }
}

fn validateLaunchArray(raw: std.json.Value) EmitError!void {
    switch (raw) {
        .array => |arr| {
            for (arr.items) |item| {
                const obj = expectObject(item, "launch") orelse return error.InvalidSchema;
                const kernel_name = expectString(obj.get("kernelName"), "launch.kernelName") orelse return error.InvalidSchema;
                const repeat = jsonToU32(obj.get("repeat")) orelse return error.InvalidSchema;
                if (kernel_name.len == 0 or repeat == 0) return error.InvalidSchema;

                const attention_type = if (obj.get("attentionType")) |raw_attention_type|
                    expectString(raw_attention_type, "launch.attentionType") orelse return error.InvalidSchema
                else
                    null;
                if (attention_type) |value| {
                    const is_global = std.mem.eql(u8, value, @tagName(host.LaunchAttentionType.global));
                    const is_sliding = std.mem.eql(u8, value, @tagName(host.LaunchAttentionType.sliding));
                    if (!is_global and !is_sliding) return error.InvalidSchema;
                    if (is_sliding) {
                        const sliding_window_size = jsonToU32(obj.get("slidingWindowSize")) orelse return error.InvalidSchema;
                        if (sliding_window_size == 0) return error.InvalidSchema;
                        const current_pos_source = expectString(obj.get("currentPosSource"), "launch.currentPosSource") orelse return error.InvalidSchema;
                        if (!std.mem.eql(u8, current_pos_source, @tagName(host.CurrentPosSource.decode_position))) {
                            return error.InvalidSchema;
                        }
                    } else {
                        if (obj.get("slidingWindowSize") != null or obj.get("currentPosSource") != null) {
                            return error.InvalidSchema;
                        }
                    }
                } else {
                    if (obj.get("slidingWindowSize") != null) return error.InvalidSchema;
                    if (obj.get("currentPosSource")) |raw_current_pos_source| {
                        const current_pos_source = expectString(raw_current_pos_source, "launch.currentPosSource") orelse return error.InvalidSchema;
                        if (!std.mem.eql(u8, current_pos_source, @tagName(host.CurrentPosSource.decode_position))) {
                            return error.InvalidSchema;
                        }
                    }
                }

                if (obj.get("kvCacheAlias")) |raw_kv_cache_alias| {
                    const kv_cache_alias = expectString(raw_kv_cache_alias, "launch.kvCacheAlias") orelse return error.InvalidSchema;
                    if (kv_cache_alias.len == 0) return error.InvalidSchema;
                }
            }
        },
        else => return error.InvalidSchema,
    }
}

fn validateCompileTargetsValue(raw: std.json.Value) EmitError!void {
    switch (raw) {
        .array => |arr| {
            for (arr.items) |item| {
                const obj = expectObject(item, "compileTarget") orelse return error.InvalidSchema;
                const name = expectString(obj.get("name"), "compileTarget.name") orelse return error.InvalidSchema;
                if (obj.get("pattern")) |raw_pattern| {
                    const pattern = expectString(raw_pattern, "compileTarget.pattern") orelse return error.InvalidSchema;
                    if (pattern.len == 0) return error.InvalidSchema;
                }
                const layout = expectString(obj.get("layout"), "compileTarget.layout") orelse return error.InvalidSchema;
                const pe_program = expectString(obj.get("peProgram"), "compileTarget.peProgram") orelse return error.InvalidSchema;
                if (name.len == 0 or layout.len == 0 or pe_program.len == 0) return error.InvalidSchema;
            }
        },
        else => return error.InvalidSchema,
    }
}

fn validateCslcValue(raw: std.json.Value) EmitError!void {
    const obj = expectObject(raw, "cslc") orelse return error.InvalidSchema;
    const executable = expectString(obj.get("executable"), "cslc.executable") orelse return error.InvalidSchema;
    if (executable.len == 0) return error.InvalidSchema;

    const discovery = expectString(obj.get("discovery"), "cslc.discovery") orelse return error.InvalidSchema;
    if (!std.mem.eql(u8, discovery, spec.HOST_PLAN_DISCOVERY_EXPLICIT_CONFIG) and
        !std.mem.eql(u8, discovery, spec.HOST_PLAN_DISCOVERY_IMPLICIT_PATH_LOOKUP))
    {
        return error.InvalidSchema;
    }

    const validation = expectObject(obj.get("validation") orelse return error.InvalidSchema, "validation") orelse return error.InvalidSchema;
    switch (validation.get("command") orelse return error.InvalidSchema) {
        .array => |command| {
            if (command.items.len != 2) return error.InvalidSchema;
            const first = expectString(command.items[0], "validation.command[0]") orelse return error.InvalidSchema;
            const second = expectString(command.items[1], "validation.command[1]") orelse return error.InvalidSchema;
            if (!std.mem.eql(u8, first, executable) or !std.mem.eql(u8, second, spec.CSLC_VERSION_ARG)) return error.InvalidSchema;
        },
        else => return error.InvalidSchema,
    }

    const minimum_version = expectString(validation.get("minimumVersion"), "validation.minimumVersion") orelse return error.InvalidSchema;
    if (minimum_version.len == 0) return error.InvalidSchema;
}

fn validateHostPlan(
    plan: host.HostPlan,
    targets: []const CompileTarget,
    cslc_plan: ?CslcPlan,
) EmitError!void {
    if (plan.pe_grid_width == 0 or plan.pe_grid_height == 0) return error.InvalidIr;

    for (plan.kernels) |kernel| {
        if (kernel.name.len == 0 or kernel.pattern.len == 0 or kernel.count == 0) return error.InvalidIr;
    }
    for (plan.prefill_launches) |launch| {
        try validateLaunch(plan.kernels, launch, .prefill);
    }
    for (plan.decode_launches) |launch| {
        try validateLaunch(plan.kernels, launch, .decode);
    }

    for (targets) |target| {
        if (target.kernel_name.len == 0 or target.pattern.len == 0 or target.layout_path.len == 0 or target.pe_program_path.len == 0) {
            return error.InvalidIr;
        }
        const kernel = findKernel(plan.kernels, kernelNameForTarget(target.kernel_name)) orelse return error.InvalidIr;
        if (!std.mem.eql(u8, kernel.pattern, target.pattern)) return error.InvalidIr;
    }

    if (cslc_plan) |plan_cslc| {
        if (plan_cslc.executable.len == 0 or plan_cslc.minimum_version.len == 0) return error.InvalidIr;
    }
}

fn hasKernel(kernels: []const host.KernelSpec, kernel_name: []const u8) bool {
    for (kernels) |kernel| {
        if (std.mem.eql(u8, kernel.name, kernel_name)) return true;
    }
    return false;
}

fn kernelNameForTarget(target_name: []const u8) []const u8 {
    if (std.mem.indexOf(u8, target_name, DENSE_GEMV_COMPILE_TILE_MARKER)) |marker_start| {
        return target_name[0..marker_start];
    }
    for (PHASE_TARGET_SUFFIXES) |suffix| {
        if (std.mem.endsWith(u8, target_name, suffix)) {
            const base_name = target_name[0 .. target_name.len - suffix.len];
            if (isPhaseSpecializedKernel(base_name)) return base_name;
        }
    }
    return target_name;
}

fn isPhaseSpecializedKernel(name: []const u8) bool {
    for (PHASE_SPECIALIZED_KERNELS) |kernel_name| {
        if (std.mem.eql(u8, name, kernel_name)) return true;
    }
    return false;
}

const Phase = enum {
    prefill,
    decode,
};

fn validateLaunch(kernels: []const host.KernelSpec, launch: host.LaunchSpec, phase: Phase) EmitError!void {
    if (launch.kernel_name.len == 0 or launch.repeat == 0) return error.InvalidIr;
    const kernel = findKernel(kernels, launch.kernel_name) orelse return error.InvalidIr;

    if (launch.attention_type) |attention_type| {
        if (!std.mem.eql(u8, kernel.pattern, "attention_decode")) return error.InvalidIr;
        switch (attention_type) {
            .global => {
                if (launch.sliding_window_size != null or launch.current_pos_source != null) return error.InvalidIr;
            },
            .sliding => {
                if (phase != .decode) return error.InvalidIr;
                if ((launch.sliding_window_size orelse 0) == 0) return error.InvalidIr;
                if (launch.current_pos_source != .decode_position) return error.InvalidIr;
            },
        }
    } else {
        if (launch.sliding_window_size != null) return error.InvalidIr;
        if (launch.current_pos_source) |current_pos_source| {
            if (current_pos_source != .decode_position) return error.InvalidIr;
            if (phase != .decode) return error.InvalidIr;
            if (!std.mem.eql(u8, kernel.pattern, "kv_write")) return error.InvalidIr;
        }
    }

    if (launch.kv_cache_alias) |kv_cache_alias| {
        if (kv_cache_alias.len == 0) return error.InvalidIr;
        if (!std.mem.eql(u8, kernel.pattern, "kv_write")) return error.InvalidIr;
    }
}

fn findKernel(kernels: []const host.KernelSpec, kernel_name: []const u8) ?host.KernelSpec {
    for (kernels) |kernel| {
        if (std.mem.eql(u8, kernel.name, kernel_name)) return kernel;
    }
    return null;
}

fn emitLaunchSpecsJson(buf: []u8, pos: *usize, launches: []const host.LaunchSpec) EmitError!void {
    for (launches, 0..) |launch, idx| {
        try write(buf, pos, "        { \"kernelName\": ");
        try writeJsonString(buf, pos, launch.kernel_name);
        try write(buf, pos, ", \"repeat\": ");
        try writeInt(buf, pos, launch.repeat);
        if (launch.attention_type) |attention_type| {
            try write(buf, pos, ", \"attentionType\": ");
            try writeJsonString(buf, pos, @tagName(attention_type));
        }
        if (launch.sliding_window_size) |sliding_window_size| {
            try write(buf, pos, ", \"slidingWindowSize\": ");
            try writeInt(buf, pos, sliding_window_size);
        }
        if (launch.current_pos_source) |current_pos_source| {
            try write(buf, pos, ", \"currentPosSource\": ");
            try writeJsonString(buf, pos, @tagName(current_pos_source));
        }
        if (launch.kv_cache_alias) |kv_cache_alias| {
            try write(buf, pos, ", \"kvCacheAlias\": ");
            try writeJsonString(buf, pos, kv_cache_alias);
        }
        try write(buf, pos, " }");
        if (idx + 1 < launches.len) try write(buf, pos, ",");
        try write(buf, pos, "\n");
    }
}

fn expectObject(raw: ?std.json.Value, label: []const u8) ?std.json.ObjectMap {
    const value = raw orelse return null;
    return switch (value) {
        .object => |obj| obj,
        else => {
            _ = label;
            return null;
        },
    };
}

fn expectString(raw: ?std.json.Value, label: []const u8) ?[]const u8 {
    const value = raw orelse return null;
    return switch (value) {
        .string => |text| text,
        else => {
            _ = label;
            return null;
        },
    };
}

fn jsonToU32(raw: ?std.json.Value) ?u32 {
    const value = raw orelse return null;
    return switch (value) {
        .integer => |int_value| if (int_value < 0 or int_value > std.math.maxInt(u32))
            null
        else
            @as(u32, @intCast(int_value)),
        .float => |float_value| blk: {
            if (float_value < 0 or !std.math.isFinite(float_value)) break :blk null;
            const max_value = @as(f64, @floatFromInt(std.math.maxInt(u32)));
            if (float_value > max_value) break :blk null;
            if (float_value != @floor(float_value)) break :blk null;
            break :blk @as(u32, @intFromFloat(float_value));
        },
        else => null,
    };
}

fn writeJsonString(buf: []u8, pos: *usize, value: []const u8) EmitError!void {
    try write(buf, pos, "\"");
    for (value) |ch| {
        switch (ch) {
            '"' => try write(buf, pos, "\\\""),
            '\\' => try write(buf, pos, "\\\\"),
            '\n' => try write(buf, pos, "\\n"),
            '\r' => try write(buf, pos, "\\r"),
            '\t' => try write(buf, pos, "\\t"),
            else => {
                if (pos.* + 1 > buf.len) return error.OutputTooLarge;
                buf[pos.*] = ch;
                pos.* += 1;
            },
        }
    }
    try write(buf, pos, "\"");
}

fn write(buf: []u8, pos: *usize, text: []const u8) EmitError!void {
    if (pos.* + text.len > buf.len) return error.OutputTooLarge;
    @memcpy(buf[pos.*..][0..text.len], text);
    pos.* += text.len;
}

fn writeInt(buf: []u8, pos: *usize, value: anytype) EmitError!void {
    var tmp: [20]u8 = undefined;
    const slice = std.fmt.bufPrint(&tmp, "{d}", .{value}) catch return error.OutputTooLarge;
    try write(buf, pos, slice);
}

test "host plan artifact emits schema and cslc plan" {
    const targets = [_]CompileTarget{
        .{ .kernel_name = "attn_decode", .pattern = "attention_decode", .layout_path = "attn_decode/layout.csl", .pe_program_path = "attn_decode/pe_program.csl" },
    };
    const plan = host.HostPlan{
        .pe_grid_width = 16,
        .pe_grid_height = 1,
        .kernels = &[_]host.KernelSpec{
            .{ .name = "attn_decode", .pattern = "attention_decode", .count = 1 },
        },
        .prefill_launches = &[_]host.LaunchSpec{
            .{ .kernel_name = "attn_decode", .repeat = 1, .attention_type = .global },
        },
        .decode_launches = &[_]host.LaunchSpec{
            .{
                .kernel_name = "attn_decode",
                .repeat = 1,
                .attention_type = .sliding,
                .sliding_window_size = 512,
                .current_pos_source = .decode_position,
            },
        },
    };
    var buf: [8192]u8 = undefined;
    var pos: usize = 0;
    const cslc_plan = try makeCslcPlan(null);
    try emitHostPlanArtifactJson(&buf, &pos, plan, &targets, cslc_plan);
    const text = buf[0..pos];
    try std.testing.expect(std.mem.indexOf(u8, text, "\"schemaVersion\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"artifactKind\": \"csl_host_plan\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"discovery\": \"implicit_path_lookup\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"slidingWindowSize\": 512") != null);
    try validateHostPlanArtifactJson(std.testing.allocator, text);
}

test "host plan accepts decode position state on kv writes" {
    const plan = host.HostPlan{
        .pe_grid_width = 16,
        .pe_grid_height = 1,
        .kernels = &[_]host.KernelSpec{
            .{ .name = "kv_write", .pattern = "kv_write", .count = 1 },
        },
        .prefill_launches = &[_]host.LaunchSpec{},
        .decode_launches = &[_]host.LaunchSpec{
            .{
                .kernel_name = "kv_write",
                .repeat = 1,
                .current_pos_source = .decode_position,
            },
        },
    };
    const targets = [_]CompileTarget{
        .{ .kernel_name = "kv_write", .pattern = "kv_write", .layout_path = "kv_write/layout.csl", .pe_program_path = "kv_write/pe_program.csl" },
    };
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    try emitHostPlanArtifactJson(&buf, &pos, plan, &targets, null);
    try validateHostPlanArtifactJson(std.testing.allocator, buf[0..pos]);
}

test "host plan accepts phase-specific compile targets backed by base kernel" {
    const plan = host.HostPlan{
        .pe_grid_width = 16,
        .pe_grid_height = 1,
        .kernels = &[_]host.KernelSpec{
            .{ .name = "rmsnorm", .pattern = "element_wise", .count = 1 },
        },
        .prefill_launches = &[_]host.LaunchSpec{
            .{ .kernel_name = "rmsnorm", .repeat = 1 },
        },
        .decode_launches = &[_]host.LaunchSpec{
            .{ .kernel_name = "rmsnorm", .repeat = 1 },
        },
    };
    const targets = [_]CompileTarget{
        .{ .kernel_name = "rmsnorm", .pattern = "element_wise", .layout_path = "rmsnorm/layout.csl", .pe_program_path = "rmsnorm/pe_program.csl" },
        .{ .kernel_name = "rmsnorm_prefill", .pattern = "element_wise", .layout_path = "rmsnorm/layout.csl", .pe_program_path = "rmsnorm/pe_program.csl" },
        .{ .kernel_name = "rmsnorm_decode", .pattern = "element_wise", .layout_path = "rmsnorm/layout.csl", .pe_program_path = "rmsnorm/pe_program.csl" },
    };
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    try emitHostPlanArtifactJson(&buf, &pos, plan, &targets, null);
    try validateHostPlanArtifactJson(std.testing.allocator, buf[0..pos]);
}

test "host plan rejects phase suffixes for unspecialized kernels" {
    const plan = host.HostPlan{
        .pe_grid_width = 16,
        .pe_grid_height = 1,
        .kernels = &[_]host.KernelSpec{
            .{ .name = "sample", .pattern = "sample", .count = 1 },
        },
        .prefill_launches = &[_]host.LaunchSpec{},
        .decode_launches = &[_]host.LaunchSpec{},
    };
    const targets = [_]CompileTarget{
        .{ .kernel_name = "sample_decode", .pattern = "sample", .layout_path = "sample/layout.csl", .pe_program_path = "sample/pe_program.csl" },
    };
    try std.testing.expectError(error.InvalidIr, validateHostPlan(plan, &targets, null));
}

test "host plan rejects sliding attention in prefill" {
    const plan = host.HostPlan{
        .pe_grid_width = 16,
        .pe_grid_height = 1,
        .kernels = &[_]host.KernelSpec{
            .{ .name = "attn_decode", .pattern = "attention_decode", .count = 1 },
        },
        .prefill_launches = &[_]host.LaunchSpec{
            .{
                .kernel_name = "attn_decode",
                .repeat = 1,
                .attention_type = .sliding,
                .sliding_window_size = 512,
                .current_pos_source = .decode_position,
            },
        },
        .decode_launches = &[_]host.LaunchSpec{},
    };
    const targets = [_]CompileTarget{
        .{ .kernel_name = "attn_decode", .pattern = "attention_decode", .layout_path = "attn_decode/layout.csl", .pe_program_path = "attn_decode/pe_program.csl" },
    };
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    try std.testing.expectError(error.InvalidIr, emitHostPlanArtifactJson(&buf, &pos, plan, &targets, null));
}
