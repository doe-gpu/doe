const std = @import("std");
const doe = @import("doe");
const simulator = doe.compiler.wgsl_csl.simulator();
const spec = doe.compiler.wgsl_csl.spec();

const RunnerError = error{
    MissingValue,
    MissingPlan,
    MissingDriverExecutable,
    InvalidPlan,
    OutputTooLarge,
};

const MAX_PLAN_BYTES: usize = 4 * 1024 * 1024;
const MAX_PROCESS_OUTPUT_BYTES: usize = 16 * 1024 * 1024;
const MAX_RESULT_BYTES: usize = 8 * 1024;

fn printUsage(stdout: anytype) !void {
    try stdout.writeAll(
        \\doe-csl-sim-runner --plan <path> [--driver-executable <path>] [--result-json <path>]
        \\Reads a Doe CSL simulator plan artifact, validates it, and launches the explicit simulator driver.
        \\Driver resolution order:
        \\  1. --driver-executable
        \\  2. plan.driver.executablePath
        \\  3. $DOE_CSL_SIM_EXECUTABLE
        \\The runner writes stdout/stderr to the paths declared by the simulator plan and emits a result artifact.
        \\
    );
}

fn getOptionValue(args: [][:0]u8, index: *usize) RunnerError![]const u8 {
    if (index.* + 1 >= args.len) return error.MissingValue;
    index.* += 1;
    return args[index.*];
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.fs.cwd().readFileAlloc(allocator, path, MAX_PLAN_BYTES);
}

fn ensureParentPath(path: []const u8) !void {
    const dir_name = std.fs.path.dirname(path) orelse return;
    try std.fs.cwd().makePath(dir_name);
}

fn writeFileEnsured(path: []const u8, data: []const u8) !void {
    try ensureParentPath(path);
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(data);
}

fn resolveArtifactPath(
    allocator: std.mem.Allocator,
    plan_path: []const u8,
    raw_path: []const u8,
) ![]const u8 {
    if (std.fs.path.isAbsolute(raw_path)) return raw_path;
    const plan_dir = std.fs.path.dirname(plan_path) orelse ".";
    return try std.fs.path.join(allocator, &.{ plan_dir, raw_path });
}

fn defaultResultPath(allocator: std.mem.Allocator, trace_path: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}.result.json", .{trace_path});
}

fn resolveDriverExecutable(
    allocator: std.mem.Allocator,
    plan_path: []const u8,
    cli_value: ?[]const u8,
    plan_value: ?[]const u8,
) RunnerError![]const u8 {
    if (cli_value) |value| return value;
    if (plan_value) |value| return resolveArtifactPath(allocator, plan_path, value) catch return error.MissingDriverExecutable;
    return std.process.getEnvVarOwned(allocator, spec.SIMULATOR_DRIVER_ENV_VAR) catch return error.MissingDriverExecutable;
}

fn makeResult(
    plan_path: []const u8,
    driver_executable: []const u8,
    stdout_path: []const u8,
    stderr_path: []const u8,
    trace_path: []const u8,
    term: std.process.Child.Term,
) simulator.SimulatorResult {
    return switch (term) {
        .Exited => |code| .{
            .simulator_plan_path = plan_path,
            .driver_executable = driver_executable,
            .status = if (code == 0) .simulator_succeeded else .simulator_failed,
            .termination = .exited,
            .exit_code = code,
            .stdout_path = stdout_path,
            .stderr_path = stderr_path,
            .trace_path = trace_path,
            .trace_produced = traceExists(trace_path),
        },
        .Signal => .{
            .simulator_plan_path = plan_path,
            .driver_executable = driver_executable,
            .status = .simulator_failed,
            .termination = .signal,
            .exit_code = null,
            .stdout_path = stdout_path,
            .stderr_path = stderr_path,
            .trace_path = trace_path,
            .trace_produced = traceExists(trace_path),
        },
        .Stopped => .{
            .simulator_plan_path = plan_path,
            .driver_executable = driver_executable,
            .status = .simulator_failed,
            .termination = .stopped,
            .exit_code = null,
            .stdout_path = stdout_path,
            .stderr_path = stderr_path,
            .trace_path = trace_path,
            .trace_produced = traceExists(trace_path),
        },
        else => .{
            .simulator_plan_path = plan_path,
            .driver_executable = driver_executable,
            .status = .simulator_failed,
            .termination = .unknown,
            .exit_code = null,
            .stdout_path = stdout_path,
            .stderr_path = stderr_path,
            .trace_path = trace_path,
            .trace_produced = traceExists(trace_path),
        },
    };
}

fn traceExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn writeResultArtifact(path: []const u8, result: simulator.SimulatorResult) !void {
    var buf: [MAX_RESULT_BYTES]u8 = undefined;
    var pos: usize = 0;
    try simulator.emitSimulatorResultArtifactJson(&buf, &pos, result);
    try writeFileEnsured(path, buf[0..pos]);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    var plan_path: ?[]const u8 = null;
    var driver_executable_arg: ?[]const u8 = null;
    var result_json_path: ?[]const u8 = null;

    var idx: usize = 1;
    while (idx < argv.len) : (idx += 1) {
        if (std.mem.eql(u8, argv[idx], "--plan")) {
            plan_path = try getOptionValue(argv, &idx);
        } else if (std.mem.eql(u8, argv[idx], "--driver-executable")) {
            driver_executable_arg = try getOptionValue(argv, &idx);
        } else if (std.mem.eql(u8, argv[idx], "--result-json")) {
            result_json_path = try getOptionValue(argv, &idx);
        } else if (std.mem.eql(u8, argv[idx], "--help")) {
            try printUsage(std.fs.File.stdout().deprecatedWriter());
            return;
        }
    }

    const resolved_plan_path = plan_path orelse return error.MissingPlan;
    const plan_bytes = readFileAlloc(allocator, resolved_plan_path) catch return error.InvalidPlan;
    var parsed = simulator.parseSimulatorPlanArtifact(allocator, plan_bytes) catch return error.InvalidPlan;
    defer parsed.deinit();

    const driver_executable = try resolveDriverExecutable(allocator, resolved_plan_path, driver_executable_arg, parsed.value.driver.executablePath);
    const plan = parsed.value;
    const resolved_stdout_path = try resolveArtifactPath(allocator, resolved_plan_path, plan.outputs.stdoutPath);
    const resolved_stderr_path = try resolveArtifactPath(allocator, resolved_plan_path, plan.outputs.stderrPath);
    const resolved_trace_path = try resolveArtifactPath(allocator, resolved_plan_path, plan.outputs.tracePath);
    const resolved_result_path = if (result_json_path) |path| path else try defaultResultPath(allocator, resolved_trace_path);

    const argv_child = [_][]const u8{ driver_executable, resolved_plan_path };
    const process_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &argv_child,
        .max_output_bytes = MAX_PROCESS_OUTPUT_BYTES,
    }) catch |err| {
        const launch_failed = simulator.SimulatorResult{
            .simulator_plan_path = resolved_plan_path,
            .driver_executable = driver_executable,
            .status = .launch_failed,
            .termination = .unknown,
            .exit_code = null,
            .stdout_path = resolved_stdout_path,
            .stderr_path = resolved_stderr_path,
            .trace_path = resolved_trace_path,
            .trace_produced = false,
        };
        try writeFileEnsured(resolved_stderr_path, @errorName(err));
        try writeFileEnsured(resolved_stdout_path, "");
        try writeResultArtifact(resolved_result_path, launch_failed);
        return error.MissingDriverExecutable;
    };
    defer allocator.free(process_result.stdout);
    defer allocator.free(process_result.stderr);

    try writeFileEnsured(resolved_stdout_path, process_result.stdout);
    try writeFileEnsured(resolved_stderr_path, process_result.stderr);

    const result = makeResult(
        resolved_plan_path,
        driver_executable,
        resolved_stdout_path,
        resolved_stderr_path,
        resolved_trace_path,
        process_result.term,
    );
    try writeResultArtifact(resolved_result_path, result);

    switch (process_result.term) {
        .Exited => |code| {
            if (code != 0) std.process.exit(code);
        },
        else => std.process.exit(1),
    }
}
