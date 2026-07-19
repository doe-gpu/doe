const std = @import("std");
const host = @import("emit_csl_host.zig");
const host_plan = @import("emit_csl_host_plan.zig");
const host_runtime = @import("emit_csl_host_runtime.zig");
const simulator = @import("emit_csl_simulator.zig");
const spec = @import("csl_spec.zig");

pub const EmitError = error{
    OutputTooLarge,
    InvalidIr,
    InvalidSchema,
    OutOfMemory,
    UnsupportedSchemaVersion,
};

pub const CompileTarget = host_plan.CompileTarget;
pub const CslcPlan = host_plan.CslcPlan;
pub const SimulatorArtifactPaths = simulator.ArtifactPaths;

/// Emits a Makefile fragment that compiles all kernels in the host plan.
pub fn emitMakefile(
    buf: []u8,
    pos: *usize,
    plan: host.HostPlan,
    targets: []const CompileTarget,
    cslc_executable: ?[]const u8,
) EmitError!void {
    const cslc_plan = try host_plan.makeCslcPlan(cslc_executable);

    try write(buf, pos, "# Auto-generated CSL build targets.\n");
    try write(buf, pos, "# Requires: cslc from Cerebras SDK >= ");
    try write(buf, pos, spec.CSLC_SDK_MIN_VERSION);
    try write(buf, pos, "\n\n");
    try write(buf, pos, "# cslc discovery: ");
    try write(buf, pos, host_plan.discoveryLabel(cslc_plan.discovery));
    try write(buf, pos, "\n# cslc executable: ");
    try write(buf, pos, cslc_plan.executable);
    try write(buf, pos, "\n# cslc validation: ");
    try write(buf, pos, cslc_plan.executable);
    try write(buf, pos, " ");
    try write(buf, pos, spec.CSLC_VERSION_ARG);
    try write(buf, pos, "\n\n");

    try write(buf, pos, "FABRIC_WIDTH = ");
    try writeInt(buf, pos, plan.pe_grid_width);
    try write(buf, pos, "\nFABRIC_HEIGHT = ");
    try writeInt(buf, pos, plan.pe_grid_height);
    try write(buf, pos, "\n\n");

    // All target
    try write(buf, pos, "all:");
    for (targets) |t| {
        try write(buf, pos, " ");
        try write(buf, pos, t.kernel_name);
    }
    try write(buf, pos, "\n\n");

    // Per-kernel compile targets
    for (targets) |t| {
        try write(buf, pos, t.kernel_name);
        try write(buf, pos, ":\n");
        try write(buf, pos, "\t@mkdir -p ");
        try write(buf, pos, t.kernel_name);
        try write(buf, pos, "/out\n");
        try write(buf, pos, "\t");
        try write(buf, pos, cslc_plan.executable);
        try write(buf, pos, " ");
        try write(buf, pos, t.layout_path);
        try write(buf, pos, " \\\n");
        try write(buf, pos, "\t\t--fabric-dims=$(FABRIC_WIDTH),$(FABRIC_HEIGHT) \\\n");
        try write(buf, pos, "\t\t--params=width:$(FABRIC_WIDTH) \\\n");
        try write(buf, pos, "\t\t-o ");
        try write(buf, pos, t.kernel_name);
        try write(buf, pos, "/out \\\n");
        try write(buf, pos, "\t\t--memcpy --channels=1\n");
        try write(buf, pos, "\t@echo \"Compiled ");
        try write(buf, pos, t.kernel_name);
        try write(buf, pos, " → ");
        try write(buf, pos, t.kernel_name);
        try write(buf, pos, "/out/\"\n\n");
    }

    // Clean target
    try write(buf, pos, "clean:\n");
    for (targets) |t| {
        try write(buf, pos, "\trm -rf ");
        try write(buf, pos, t.kernel_name);
        try write(buf, pos, "/out\n");
    }
    try write(buf, pos, "\n");

    // Error recovery advice
    try write(buf, pos, "# Troubleshooting:\n");
    try write(buf, pos, "#   E: \"cslc: command not found\" → source /path/to/cerebras/sdk/env.sh\n");
    try write(buf, pos, "#   E: SRAM overflow → reduce FABRIC_WIDTH or shard weights differently\n");
    try write(buf, pos, "#   E: color conflict → check MAX_COLORS in csl_spec.zig\n");
}

/// Emits a JSON compilation plan for programmatic build systems.
pub fn emitCompilePlanJson(
    buf: []u8,
    pos: *usize,
    plan: host.HostPlan,
    targets: []const CompileTarget,
    cslc_executable: ?[]const u8,
) EmitError!void {
    const cslc_plan = try host_plan.makeCslcPlan(cslc_executable);
    try host_plan.emitHostPlanArtifactJson(buf, pos, plan, targets, cslc_plan);
}

pub fn emitSimulatorPlanJson(
    buf: []u8,
    pos: *usize,
    runtime: host_runtime.RuntimeConfig,
    targets: []const CompileTarget,
    paths: SimulatorArtifactPaths,
    driver: simulator.DriverConfig,
) EmitError!void {
    try simulator.emitSimulatorPlanArtifactJson(buf, pos, runtime, targets, paths, driver);
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

test "Makefile emits compile targets" {
    const targets = [_]CompileTarget{
        .{ .kernel_name = "gelu", .pattern = "gelu", .layout_path = "gelu/layout.csl", .pe_program_path = "gelu/pe_program.csl" },
    };
    const plan = host.HostPlan{
        .pe_grid_width = 16,
        .pe_grid_height = 1,
        .kernels = &[_]host.KernelSpec{},
        .prefill_launches = &[_]host.LaunchSpec{},
        .decode_launches = &[_]host.LaunchSpec{},
    };
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    try emitMakefile(&buf, &pos, plan, &targets, null);
    const text = buf[0..pos];
    try std.testing.expect(std.mem.indexOf(u8, text, "cslc") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "gelu") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "--fabric-dims") != null);
}

test "simulator plan wrapper emits JSON" {
    const runtime = host_runtime.RuntimeConfig{
        .plan = .{
            .pe_grid_width = 16,
            .pe_grid_height = 1,
            .kernels = &[_]host.KernelSpec{},
            .prefill_launches = &[_]host.LaunchSpec{},
            .decode_launches = &[_]host.LaunchSpec{},
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
    const targets = [_]CompileTarget{
        .{ .kernel_name = "gelu", .pattern = "gelu", .layout_path = "gelu/layout.csl", .pe_program_path = "gelu/pe_program.csl" },
    };
    const paths = SimulatorArtifactPaths{
        .host_plan_artifact_path = "artifacts/host-plan.json",
        .runtime_config_path = "artifacts/runtime.json",
        .compile_root_path = "artifacts/compile",
        .stdout_path = "artifacts/stdout.log",
        .stderr_path = "artifacts/stderr.log",
        .trace_path = "artifacts/trace.json",
    };
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    try emitSimulatorPlanJson(&buf, &pos, runtime, &targets, paths, .{});
    try std.testing.expect(std.mem.indexOf(u8, buf[0..pos], spec.SIMULATOR_DRIVER_ENV_VAR) != null);
}
