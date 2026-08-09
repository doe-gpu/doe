const std = @import("std");
const spec = @import("csl_spec.zig");
const host_plan = @import("emit_csl_host_plan.zig");
const host_runtime = @import("emit_csl_host_runtime.zig");
const text_buffer = @import("csl_text_buffer.zig");

const write = text_buffer.write;
const writeInt = text_buffer.writeInt;

pub const EmitError = error{
    OutputTooLarge,
    InvalidIr,
    InvalidSchema,
    OutOfMemory,
    UnsupportedSchemaVersion,
};

pub const ArtifactPaths = struct {
    host_plan_artifact_path: []const u8,
    runtime_config_path: []const u8,
    compile_root_path: []const u8,
    stdout_path: []const u8,
    stderr_path: []const u8,
    trace_path: []const u8,
};

pub const DriverConfig = struct {
    executable_path: ?[]const u8 = null,
};

pub const SimulatorPlan = struct {
    schemaVersion: u32,
    artifactKind: []const u8,
    target: []const u8,
    contract: []const u8,
    driver: Driver,
    inputs: Inputs,
    runtime: Runtime,
    outputs: Outputs,

    pub const Driver = struct {
        protocol: []const u8,
        executableEnvVar: []const u8,
        failClosedIfMissing: bool,
        executablePath: ?[]const u8 = null,
    };

    pub const Inputs = struct {
        hostPlanArtifactPath: []const u8,
        runtimeConfigPath: []const u8,
        compileRootPath: []const u8,
        compileTargets: []const CompileTarget,
    };

    pub const CompileTarget = struct {
        name: []const u8,
        pattern: ?[]const u8 = null,
        layout: []const u8,
        peProgram: []const u8,
        compileBlockedReason: ?[]const u8 = null,
    };

    pub const Runtime = struct {
        peGrid: PeGrid,
        prefillLaunchCount: u32,
        decodeLaunchCount: u32,
        weightMappingCount: u32,
        stateBufferCount: u32,
        maxDecodeTokens: u32,
        timeoutMs: u32,
        batchSize: u32,
        eosTokenId: ?u32,
    };

    pub const PeGrid = struct {
        width: u32,
        height: u32,
    };

    pub const Outputs = struct {
        stdoutPath: []const u8,
        stderrPath: []const u8,
        tracePath: []const u8,
    };
};

pub const SimulatorResultStatus = enum {
    launch_failed,
    simulator_failed,
    simulator_succeeded,
};

pub const SimulatorTermination = enum {
    exited,
    signal,
    stopped,
    unknown,
};

pub const SimulatorResult = struct {
    simulator_plan_path: []const u8,
    driver_executable: []const u8,
    status: SimulatorResultStatus,
    termination: SimulatorTermination,
    exit_code: ?u32,
    stdout_path: []const u8,
    stderr_path: []const u8,
    trace_path: []const u8,
    trace_produced: bool,
};

pub fn emitSimulatorPlanArtifactJson(
    buf: []u8,
    pos: *usize,
    runtime: host_runtime.RuntimeConfig,
    targets: []const host_plan.CompileTarget,
    paths: ArtifactPaths,
    driver: DriverConfig,
) EmitError!void {
    try validateArtifactInputs(runtime, targets, paths);

    try write(buf, pos, "{\n");
    try write(buf, pos, "  \"schemaVersion\": ");
    try writeInt(buf, pos, spec.SIMULATOR_PLAN_SCHEMA_VERSION);
    try write(buf, pos, ",\n  \"artifactKind\": ");
    try writeJsonString(buf, pos, spec.SIMULATOR_PLAN_ARTIFACT_KIND);
    try write(buf, pos, ",\n  \"target\": ");
    try writeJsonString(buf, pos, spec.SIMULATOR_PLAN_TARGET);
    try write(buf, pos, ",\n  \"contract\": ");
    try writeJsonString(buf, pos, spec.SIMULATOR_PLAN_CONTRACT);
    try write(buf, pos, ",\n  \"driver\": {\n");
    try write(buf, pos, "    \"protocol\": ");
    try writeJsonString(buf, pos, spec.SIMULATOR_DRIVER_PROTOCOL);
    try write(buf, pos, ",\n    \"executableEnvVar\": ");
    try writeJsonString(buf, pos, spec.SIMULATOR_DRIVER_ENV_VAR);
    try write(buf, pos, ",\n    \"failClosedIfMissing\": true");
    if (driver.executable_path) |executable_path| {
        try write(buf, pos, ",\n    \"executablePath\": ");
        try writeJsonString(buf, pos, executable_path);
    }
    try write(buf, pos, "\n  },\n");
    try write(buf, pos, "  \"inputs\": {\n");
    try write(buf, pos, "    \"hostPlanArtifactPath\": ");
    try writeJsonString(buf, pos, paths.host_plan_artifact_path);
    try write(buf, pos, ",\n    \"runtimeConfigPath\": ");
    try writeJsonString(buf, pos, paths.runtime_config_path);
    try write(buf, pos, ",\n    \"compileRootPath\": ");
    try writeJsonString(buf, pos, paths.compile_root_path);
    try write(buf, pos, ",\n    \"compileTargets\": [\n");
    for (targets, 0..) |target, idx| {
        try write(buf, pos, "      { \"name\": ");
        try writeJsonString(buf, pos, target.kernel_name);
        try write(buf, pos, ", \"pattern\": ");
        try writeJsonString(buf, pos, target.pattern);
        try write(buf, pos, ", \"layout\": ");
        try writeJsonString(buf, pos, target.layout_path);
        try write(buf, pos, ", \"peProgram\": ");
        try writeJsonString(buf, pos, target.pe_program_path);
        try host_plan.emitCompileParamsFieldJson(buf, pos, target.compile_params);
        if (target.compile_blocked_reason) |reason| {
            try write(buf, pos, ", \"compileBlockedReason\": ");
            try writeJsonString(buf, pos, reason);
        }
        if (target.metadata) |metadata| {
            try write(buf, pos, ", ");
            try host_plan.emitCompileTargetMetadataJson(buf, pos, metadata);
        }
        try write(buf, pos, " }");
        if (idx + 1 < targets.len) try write(buf, pos, ",");
        try write(buf, pos, "\n");
    }
    try write(buf, pos, "    ]\n  },\n");

    try write(buf, pos, "  \"runtime\": {\n");
    try write(buf, pos, "    \"peGrid\": { \"width\": ");
    try writeInt(buf, pos, runtime.plan.pe_grid_width);
    try write(buf, pos, ", \"height\": ");
    try writeInt(buf, pos, runtime.plan.pe_grid_height);
    try write(buf, pos, " },\n");
    try write(buf, pos, "    \"prefillLaunchCount\": ");
    try writeInt(buf, pos, runtime.plan.prefill_launches.len);
    try write(buf, pos, ",\n    \"decodeLaunchCount\": ");
    try writeInt(buf, pos, runtime.plan.decode_launches.len);
    try write(buf, pos, ",\n    \"weightMappingCount\": ");
    try writeInt(buf, pos, runtime.weight_mapping_count);
    try write(buf, pos, ",\n    \"stateBufferCount\": ");
    try writeInt(buf, pos, runtime.state_buffer_count);
    try write(buf, pos, ",\n    \"maxDecodeTokens\": ");
    try writeInt(buf, pos, runtime.max_decode_tokens);
    try write(buf, pos, ",\n    \"timeoutMs\": ");
    try writeInt(buf, pos, runtime.timeout_ms);
    try write(buf, pos, ",\n    \"batchSize\": ");
    try writeInt(buf, pos, runtime.batch_size);
    try write(buf, pos, ",\n    \"eosTokenId\": ");
    if (runtime.plan.eos_token_id) |eos| {
        try writeInt(buf, pos, eos);
    } else {
        try write(buf, pos, "null");
    }
    try write(buf, pos, "\n  },\n");

    try write(buf, pos, "  \"outputs\": {\n");
    try write(buf, pos, "    \"stdoutPath\": ");
    try writeJsonString(buf, pos, paths.stdout_path);
    try write(buf, pos, ",\n    \"stderrPath\": ");
    try writeJsonString(buf, pos, paths.stderr_path);
    try write(buf, pos, ",\n    \"tracePath\": ");
    try writeJsonString(buf, pos, paths.trace_path);
    try write(buf, pos, "\n  }\n}\n");
}

pub fn emitLauncherScript(
    buf: []u8,
    pos: *usize,
    simulator_plan_path: []const u8,
    driver: DriverConfig,
) EmitError!void {
    if (simulator_plan_path.len == 0) return error.InvalidIr;
    try write(buf, pos, "#!/usr/bin/env bash\nset -euo pipefail\n\n");
    if (driver.executable_path) |executable_path| {
        try write(buf, pos, "driver_executable=");
        try writeJsonStringShell(buf, pos, executable_path);
        try write(buf, pos, "\n");
        try write(buf, pos, "if [[ ! -x \"$driver_executable\" ]]; then\n");
        try write(buf, pos, "  echo \"Configured simulator driver is not executable: $driver_executable\" >&2\n");
        try write(buf, pos, "  exit 2\nfi\n\n");
        try write(buf, pos, "exec \"$driver_executable\" ");
    } else {
        try write(buf, pos, "if [[ -z \"${");
        try write(buf, pos, spec.SIMULATOR_DRIVER_ENV_VAR);
        try write(buf, pos, ":-}\" ]]; then\n");
        try write(buf, pos, "  echo \"Missing ");
        try write(buf, pos, spec.SIMULATOR_DRIVER_ENV_VAR);
        try write(buf, pos, "; Doe CSL simulator launch is explicit-only.\" >&2\n");
        try write(buf, pos, "  exit 2\nfi\n\n");
        try write(buf, pos, "exec \"${");
        try write(buf, pos, spec.SIMULATOR_DRIVER_ENV_VAR);
        try write(buf, pos, "}\" ");
    }
    try writeJsonStringShell(buf, pos, simulator_plan_path);
    try write(buf, pos, "\n");
}

pub fn validateSimulatorPlanArtifactJson(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) EmitError!void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .ignore_unknown_fields = false,
    }) catch return error.InvalidSchema;
    defer parsed.deinit();

    const root = expectObject(parsed.value) orelse return error.InvalidSchema;
    const schema_version = jsonToU32(root.get("schemaVersion")) orelse return error.InvalidSchema;
    if (schema_version != spec.SIMULATOR_PLAN_SCHEMA_VERSION) return error.UnsupportedSchemaVersion;
    if (!expectConstString(root.get("artifactKind"), spec.SIMULATOR_PLAN_ARTIFACT_KIND)) return error.InvalidSchema;
    if (!expectConstString(root.get("target"), spec.SIMULATOR_PLAN_TARGET)) return error.InvalidSchema;
    if (!expectConstString(root.get("contract"), spec.SIMULATOR_PLAN_CONTRACT)) return error.InvalidSchema;

    const driver = expectObject(root.get("driver")) orelse return error.InvalidSchema;
    if (!expectConstString(driver.get("protocol"), spec.SIMULATOR_DRIVER_PROTOCOL)) return error.InvalidSchema;
    if (!expectConstString(driver.get("executableEnvVar"), spec.SIMULATOR_DRIVER_ENV_VAR)) return error.InvalidSchema;
    if (!expectBool(driver.get("failClosedIfMissing"), true)) return error.InvalidSchema;
    if (driver.get("executablePath")) |raw_executable_path| {
        if (raw_executable_path == .null or !expectNonEmptyString(driver.get("executablePath"))) return error.InvalidSchema;
    }

    const inputs = expectObject(root.get("inputs")) orelse return error.InvalidSchema;
    if (!expectNonEmptyString(inputs.get("hostPlanArtifactPath"))) return error.InvalidSchema;
    if (!expectNonEmptyString(inputs.get("runtimeConfigPath"))) return error.InvalidSchema;
    if (!expectNonEmptyString(inputs.get("compileRootPath"))) return error.InvalidSchema;
    try validateCompileTargets(inputs.get("compileTargets") orelse return error.InvalidSchema);

    const runtime = expectObject(root.get("runtime")) orelse return error.InvalidSchema;
    const pe_grid = expectObject(runtime.get("peGrid")) orelse return error.InvalidSchema;
    if ((jsonToU32(pe_grid.get("width")) orelse 0) == 0) return error.InvalidSchema;
    if ((jsonToU32(pe_grid.get("height")) orelse 0) == 0) return error.InvalidSchema;
    if (jsonToU32(runtime.get("prefillLaunchCount")) == null) return error.InvalidSchema;
    if (jsonToU32(runtime.get("decodeLaunchCount")) == null) return error.InvalidSchema;
    if (jsonToU32(runtime.get("weightMappingCount")) == null) return error.InvalidSchema;
    if (jsonToU32(runtime.get("stateBufferCount")) == null) return error.InvalidSchema;
    if (jsonToU32(runtime.get("maxDecodeTokens")) == null) return error.InvalidSchema;
    if (jsonToU32(runtime.get("timeoutMs")) == null) return error.InvalidSchema;
    if (jsonToU32(runtime.get("batchSize")) == null) return error.InvalidSchema;
    if (runtime.get("eosTokenId")) |raw_eos| {
        if (raw_eos != .null and jsonToU32(raw_eos) == null) return error.InvalidSchema;
    } else return error.InvalidSchema;

    const outputs = expectObject(root.get("outputs")) orelse return error.InvalidSchema;
    if (!expectNonEmptyString(outputs.get("stdoutPath"))) return error.InvalidSchema;
    if (!expectNonEmptyString(outputs.get("stderrPath"))) return error.InvalidSchema;
    if (!expectNonEmptyString(outputs.get("tracePath"))) return error.InvalidSchema;
}

pub fn parseSimulatorPlanArtifact(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) EmitError!std.json.Parsed(SimulatorPlan) {
    // Unknown fields are tolerated here because the schema is shared with the
    // Python driver, which consumes extra compileTarget metadata (e.g.
    // sourceWgslPath for emitter-driven fixtures, compileParams for kernels
    // that declare additional top-level cslc params like tiled_matmul's
    // P/Mt/Kt/Nt). The Zig sim runner only needs the fields in SimulatorPlan
    // and must not reject plans the driver-side gates already accept.
    const parsed = std.json.parseFromSlice(SimulatorPlan, allocator, bytes, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSchema,
    };
    errdefer parsed.deinit();
    try validateSimulatorPlanArtifactJson(allocator, bytes);
    return parsed;
}

pub fn emitSimulatorResultArtifactJson(
    buf: []u8,
    pos: *usize,
    result: SimulatorResult,
) EmitError!void {
    if (result.simulator_plan_path.len == 0 or
        result.driver_executable.len == 0 or
        result.stdout_path.len == 0 or
        result.stderr_path.len == 0 or
        result.trace_path.len == 0) return error.InvalidIr;

    try write(buf, pos, "{\n");
    try write(buf, pos, "  \"schemaVersion\": ");
    try writeInt(buf, pos, spec.SIMULATOR_RESULT_SCHEMA_VERSION);
    try write(buf, pos, ",\n  \"artifactKind\": ");
    try writeJsonString(buf, pos, spec.SIMULATOR_RESULT_ARTIFACT_KIND);
    try write(buf, pos, ",\n  \"target\": ");
    try writeJsonString(buf, pos, spec.SIMULATOR_RESULT_TARGET);
    try write(buf, pos, ",\n  \"contract\": ");
    try writeJsonString(buf, pos, spec.SIMULATOR_RESULT_CONTRACT);
    try write(buf, pos, ",\n  \"simulatorPlanPath\": ");
    try writeJsonString(buf, pos, result.simulator_plan_path);
    try write(buf, pos, ",\n  \"driverExecutable\": ");
    try writeJsonString(buf, pos, result.driver_executable);
    try write(buf, pos, ",\n  \"status\": ");
    try writeJsonString(buf, pos, @tagName(result.status));
    try write(buf, pos, ",\n  \"termination\": ");
    try writeJsonString(buf, pos, @tagName(result.termination));
    try write(buf, pos, ",\n  \"exitCode\": ");
    if (result.exit_code) |code| {
        try writeInt(buf, pos, code);
    } else {
        try write(buf, pos, "null");
    }
    try write(buf, pos, ",\n  \"stdoutPath\": ");
    try writeJsonString(buf, pos, result.stdout_path);
    try write(buf, pos, ",\n  \"stderrPath\": ");
    try writeJsonString(buf, pos, result.stderr_path);
    try write(buf, pos, ",\n  \"tracePath\": ");
    try writeJsonString(buf, pos, result.trace_path);
    try write(buf, pos, ",\n  \"traceProduced\": ");
    try write(buf, pos, if (result.trace_produced) "true" else "false");
    try write(buf, pos, "\n}\n");
}

pub fn validateSimulatorResultArtifactJson(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) EmitError!void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .ignore_unknown_fields = false,
    }) catch return error.InvalidSchema;
    defer parsed.deinit();

    const root = expectObject(parsed.value) orelse return error.InvalidSchema;
    const schema_version = jsonToU32(root.get("schemaVersion")) orelse return error.InvalidSchema;
    if (schema_version != spec.SIMULATOR_RESULT_SCHEMA_VERSION) return error.UnsupportedSchemaVersion;
    if (!expectConstString(root.get("artifactKind"), spec.SIMULATOR_RESULT_ARTIFACT_KIND)) return error.InvalidSchema;
    if (!expectConstString(root.get("target"), spec.SIMULATOR_RESULT_TARGET)) return error.InvalidSchema;
    if (!expectConstString(root.get("contract"), spec.SIMULATOR_RESULT_CONTRACT)) return error.InvalidSchema;
    if (!expectNonEmptyString(root.get("simulatorPlanPath"))) return error.InvalidSchema;
    if (!expectNonEmptyString(root.get("driverExecutable"))) return error.InvalidSchema;
    if (!expectEnumString(root.get("status"), &.{ "launch_failed", "simulator_failed", "simulator_succeeded" })) return error.InvalidSchema;
    if (!expectEnumString(root.get("termination"), &.{ "exited", "signal", "stopped", "unknown" })) return error.InvalidSchema;
    if (root.get("exitCode")) |raw_exit| {
        if (raw_exit != .null and jsonToU32(raw_exit) == null) return error.InvalidSchema;
    } else return error.InvalidSchema;
    if (!expectNonEmptyString(root.get("stdoutPath"))) return error.InvalidSchema;
    if (!expectNonEmptyString(root.get("stderrPath"))) return error.InvalidSchema;
    if (!expectNonEmptyString(root.get("tracePath"))) return error.InvalidSchema;
    if (!expectBoolValue(root.get("traceProduced"))) return error.InvalidSchema;
}

fn validateArtifactInputs(
    runtime: host_runtime.RuntimeConfig,
    targets: []const host_plan.CompileTarget,
    paths: ArtifactPaths,
) EmitError!void {
    if (runtime.plan.pe_grid_width == 0 or runtime.plan.pe_grid_height == 0) return error.InvalidIr;
    if (targets.len == 0) return error.InvalidIr;
    if (paths.host_plan_artifact_path.len == 0 or
        paths.runtime_config_path.len == 0 or
        paths.compile_root_path.len == 0 or
        paths.stdout_path.len == 0 or
        paths.stderr_path.len == 0 or
        paths.trace_path.len == 0) return error.InvalidIr;
}

fn validateCompileTargets(raw: std.json.Value) EmitError!void {
    switch (raw) {
        .array => |arr| {
            if (arr.items.len == 0) return error.InvalidSchema;
            for (arr.items) |item| {
                const obj = expectObject(item) orelse return error.InvalidSchema;
                if (!expectNonEmptyString(obj.get("name"))) return error.InvalidSchema;
                if (obj.get("pattern")) |raw_pattern| {
                    if (!expectNonEmptyString(raw_pattern)) return error.InvalidSchema;
                }
                if (!expectNonEmptyString(obj.get("layout"))) return error.InvalidSchema;
                if (!expectNonEmptyString(obj.get("peProgram"))) return error.InvalidSchema;
                if (obj.get("compileBlockedReason")) |raw_reason| {
                    if (!expectNonEmptyString(raw_reason)) return error.InvalidSchema;
                }
            }
        },
        else => return error.InvalidSchema,
    }
}

fn writeJsonString(buf: []u8, pos: *usize, text: []const u8) EmitError!void {
    try write(buf, pos, "\"");
    for (text) |ch| switch (ch) {
        '\\' => try write(buf, pos, "\\\\"),
        '"' => try write(buf, pos, "\\\""),
        '\n' => try write(buf, pos, "\\n"),
        '\r' => try write(buf, pos, "\\r"),
        '\t' => try write(buf, pos, "\\t"),
        else => {
            if (pos.* + 1 > buf.len) return error.OutputTooLarge;
            buf[pos.*] = ch;
            pos.* += 1;
        },
    };
    try write(buf, pos, "\"");
}

fn writeJsonStringShell(buf: []u8, pos: *usize, text: []const u8) EmitError!void {
    try write(buf, pos, "'");
    for (text) |ch| {
        if (ch == '\'') {
            try write(buf, pos, "'\\''");
        } else {
            if (pos.* + 1 > buf.len) return error.OutputTooLarge;
            buf[pos.*] = ch;
            pos.* += 1;
        }
    }
    try write(buf, pos, "'");
}

fn expectObject(raw: ?std.json.Value) ?std.json.ObjectMap {
    const value = raw orelse return null;
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

fn expectConstString(raw: ?std.json.Value, expected: []const u8) bool {
    const value = raw orelse return false;
    return switch (value) {
        .string => |text| std.mem.eql(u8, text, expected),
        else => false,
    };
}

fn expectNonEmptyString(raw: ?std.json.Value) bool {
    const value = raw orelse return false;
    return switch (value) {
        .string => |text| text.len != 0,
        else => false,
    };
}

fn expectBool(raw: ?std.json.Value, expected: bool) bool {
    const value = raw orelse return false;
    return switch (value) {
        .bool => |flag| flag == expected,
        else => false,
    };
}

fn expectBoolValue(raw: ?std.json.Value) bool {
    const value = raw orelse return false;
    return switch (value) {
        .bool => true,
        else => false,
    };
}

fn expectEnumString(raw: ?std.json.Value, allowed: []const []const u8) bool {
    const value = raw orelse return false;
    return switch (value) {
        .string => |text| blk: {
            for (allowed) |candidate| {
                if (std.mem.eql(u8, text, candidate)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn jsonToU32(raw: ?std.json.Value) ?u32 {
    const value = raw orelse return null;
    return switch (value) {
        .integer => |integer| std.math.cast(u32, integer),
        else => null,
    };
}

test "simulator plan artifact emits and validates" {
    const plan = host_runtime.RuntimeConfig{
        .plan = .{
            .pe_grid_width = 16,
            .pe_grid_height = 1,
            .kernels = &[_]@import("emit_csl_host.zig").KernelSpec{
                .{ .name = "gelu", .pattern = "gelu", .count = 1 },
            },
            .prefill_launches = &[_]@import("emit_csl_host.zig").LaunchSpec{
                .{ .kernel_name = "gelu", .repeat = 1 },
            },
            .decode_launches = &[_]@import("emit_csl_host.zig").LaunchSpec{
                .{ .kernel_name = "gelu", .repeat = 1 },
            },
        },
        .config = .{
            .hidden_dim = 256,
            .num_heads = 4,
            .head_dim = 64,
            .num_layers = 1,
            .vocab_size = 1024,
            .max_seq_len = 128,
            .quant_format = .f16,
        },
        .weight_mappings = &[_]host_runtime.WeightMapping{},
        .weight_mapping_count = 0,
        .state_buffers = &[_]host_runtime.StateBuffer{},
        .state_buffer_count = 0,
    };
    const targets = [_]host_plan.CompileTarget{
        .{
            .kernel_name = "gelu",
            .pattern = "gelu",
            .layout_path = "gelu/layout.csl",
            .pe_program_path = "gelu/pe_program.csl",
            .compile_blocked_reason = "fixture_compile_blocked",
        },
    };
    const paths = ArtifactPaths{
        .host_plan_artifact_path = "artifacts/host-plan.json",
        .runtime_config_path = "artifacts/runtime.json",
        .compile_root_path = "artifacts/compile",
        .stdout_path = "artifacts/stdout.log",
        .stderr_path = "artifacts/stderr.log",
        .trace_path = "artifacts/trace.json",
    };
    var buf: [8192]u8 = undefined;
    var pos: usize = 0;
    try emitSimulatorPlanArtifactJson(&buf, &pos, plan, &targets, paths, .{});
    try std.testing.expect(std.mem.indexOf(u8, buf[0..pos], "\"compileBlockedReason\": \"fixture_compile_blocked\"") != null);
    try validateSimulatorPlanArtifactJson(std.testing.allocator, buf[0..pos]);
}

test "launcher script fails closed on missing driver env var" {
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;
    try emitLauncherScript(&buf, &pos, "artifacts/simulator-plan.json", .{});
    const text = buf[0..pos];
    try std.testing.expect(std.mem.indexOf(u8, text, spec.SIMULATOR_DRIVER_ENV_VAR) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "explicit-only") != null);
}

test "simulator plan artifact parses to typed contract" {
    const sample =
        \\{
        \\  "schemaVersion": 2,
        \\  "artifactKind": "csl_simulator_plan",
        \\  "target": "wse3",
        \\  "contract": "explicit_simulator_launch",
        \\  "driver": {
        \\    "protocol": "doe.csl.simulator/v1",
        \\    "executableEnvVar": "DOE_CSL_SIM_EXECUTABLE",
        \\    "failClosedIfMissing": true
        \\  },
        \\  "inputs": {
        \\    "hostPlanArtifactPath": "artifacts/host-plan.json",
        \\    "runtimeConfigPath": "artifacts/runtime.json",
        \\    "compileRootPath": "artifacts/compile",
        \\    "compileTargets": [
        \\      { "name": "gelu", "layout": "gelu/layout.csl", "peProgram": "gelu/pe_program.csl" }
        \\    ]
        \\  },
        \\  "runtime": {
        \\    "peGrid": { "width": 16, "height": 1 },
        \\    "prefillLaunchCount": 1,
        \\    "decodeLaunchCount": 1,
        \\    "weightMappingCount": 0,
        \\    "stateBufferCount": 0,
        \\    "maxDecodeTokens": 128,
        \\    "timeoutMs": 30000,
        \\    "batchSize": 1,
        \\    "eosTokenId": null
        \\  },
        \\  "outputs": {
        \\    "stdoutPath": "artifacts/stdout.log",
        \\    "stderrPath": "artifacts/stderr.log",
        \\    "tracePath": "artifacts/trace.json"
        \\  }
        \\}
    ;
    var parsed = try parseSimulatorPlanArtifact(std.testing.allocator, sample);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("artifacts/trace.json", parsed.value.outputs.tracePath);
}

test "launcher script uses explicit driver path when configured" {
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;
    try emitLauncherScript(&buf, &pos, "artifacts/simulator-plan.json", .{
        .executable_path = "/opt/doe/runtime/zig/tools/csl_sdk_driver.py",
    });
    const text = buf[0..pos];
    try std.testing.expect(std.mem.indexOf(u8, text, "driver_executable=") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "csl_sdk_driver.py") != null);
}

test "simulator result artifact emits and validates" {
    const result = SimulatorResult{
        .simulator_plan_path = "artifacts/simulator-plan.json",
        .driver_executable = "/usr/local/bin/csl-sim",
        .status = .simulator_succeeded,
        .termination = .exited,
        .exit_code = 0,
        .stdout_path = "artifacts/stdout.log",
        .stderr_path = "artifacts/stderr.log",
        .trace_path = "artifacts/trace.json",
        .trace_produced = true,
    };
    var buf: [2048]u8 = undefined;
    var pos: usize = 0;
    try emitSimulatorResultArtifactJson(&buf, &pos, result);
    try validateSimulatorResultArtifactJson(std.testing.allocator, buf[0..pos]);
}
