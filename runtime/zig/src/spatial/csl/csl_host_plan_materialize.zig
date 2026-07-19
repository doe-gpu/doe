const std = @import("std");
const doe = @import("doe");
const wgsl = doe.compiler.wgsl();
const host = wgsl.emit_csl_host;
const host_plan = wgsl.emit_csl_host_plan;
const host_runtime = wgsl.emit_csl_host_runtime;
const mem_plan = wgsl.emit_csl_mem_plan;
const simulator = wgsl.emit_csl_simulator;
const compile_source = doe.compiler.wgsl_csl.hostCompileSource();
const pe_program_metadata = @import("csl_pe_program_metadata.zig");

const HOST_PLAN_CAPACITY: usize = 128 * 1024;
const RUNTIME_CONFIG_CAPACITY: usize = 128 * 1024;
const MEMORY_PLAN_CAPACITY: usize = 64 * 1024;
const SIMULATOR_PLAN_CAPACITY: usize = 64 * 1024;
const LAUNCHER_CAPACITY: usize = 8 * 1024;
const PE_PROGRAM_METADATA_CAPACITY: usize = 16 * 1024;
const TARGET_DESCRIPTOR_CAPACITY: usize = 128;
const COMPILE_ROOT_NAME: []const u8 = "compile";

pub fn emitHostPlanFile(
    path: []const u8,
    plan: host.HostPlan,
    targets: []const host_plan.CompileTarget,
    cslc_plan: host_plan.CslcPlan,
) !void {
    var buf: [HOST_PLAN_CAPACITY]u8 = undefined;
    var pos: usize = 0;
    try host_plan.emitHostPlanArtifactJson(&buf, &pos, plan, targets, cslc_plan);
    try host_plan.validateHostPlanArtifactJson(std.heap.page_allocator, buf[0..pos]);
    try writeFile(path, buf[0..pos]);
}

pub fn emitMemoryPlanFile(path: []const u8, memory: mem_plan.MemoryPlan) !void {
    var buf: [MEMORY_PLAN_CAPACITY]u8 = undefined;
    var pos: usize = 0;
    try mem_plan.emitPlanJson(&buf, &pos, memory);
    try writeFile(path, buf[0..pos]);
}

pub fn emitRuntimeConfigFile(path: []const u8, runtime: host_runtime.RuntimeConfig) !void {
    var buf: [RUNTIME_CONFIG_CAPACITY]u8 = undefined;
    var pos: usize = 0;
    try host_runtime.emitRuntimeConfigJson(&buf, &pos, runtime);
    try writeFile(path, buf[0..pos]);
}

pub fn emitSimulatorPlanFile(
    path: []const u8,
    runtime: host_runtime.RuntimeConfig,
    targets: []const host_plan.CompileTarget,
    driver: simulator.DriverConfig,
) !void {
    var buf: [SIMULATOR_PLAN_CAPACITY]u8 = undefined;
    var pos: usize = 0;
    try simulator.emitSimulatorPlanArtifactJson(&buf, &pos, runtime, targets, .{
        .host_plan_artifact_path = "host-plan.json",
        .runtime_config_path = "runtime-config.json",
        .compile_root_path = COMPILE_ROOT_NAME,
        .stdout_path = "stdout.log",
        .stderr_path = "stderr.log",
        .trace_path = "trace.json",
    }, driver);
    try simulator.validateSimulatorPlanArtifactJson(std.heap.page_allocator, buf[0..pos]);
    try writeFile(path, buf[0..pos]);
}

pub fn emitLauncherFile(path: []const u8, driver: simulator.DriverConfig) !void {
    var buf: [LAUNCHER_CAPACITY]u8 = undefined;
    var pos: usize = 0;
    try simulator.emitLauncherScript(&buf, &pos, "simulator-plan.json", driver);
    try writeExecutableFile(path, buf[0..pos]);
}

pub fn defaultDriverPath(allocator: std.mem.Allocator, bundle_root: []const u8) ![]const u8 {
    _ = bundle_root;
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);
    const repo_root_driver = try std.fs.path.join(allocator, &.{ cwd, "runtime", "zig", "tools", "csl_sdk_driver.py" });
    if (pathExistsAbsolute(repo_root_driver)) return repo_root_driver;
    allocator.free(repo_root_driver);
    return try std.fs.path.join(allocator, &.{ cwd, "tools", "csl_sdk_driver.py" });
}

pub fn materializeTargetsMetadata(
    allocator: std.mem.Allocator,
    bundle_root: []const u8,
    targets: []const host_plan.CompileTarget,
) !void {
    var descriptors: [TARGET_DESCRIPTOR_CAPACITY]pe_program_metadata.TargetDescriptor = undefined;
    var idx: usize = 0;
    for (targets) |target| {
        if (idx >= descriptors.len) return error.TooManyCompileTargets;
        descriptors[idx] = .{
            .name = target.kernel_name,
            .base_kernel = target.base_kernel orelse target.kernel_name,
            .phase = target.phase,
            .layout = target.layout_path,
            .pe_program = target.pe_program_path,
        };
        idx += 1;
    }
    const path = try std.fs.path.join(
        allocator,
        &.{ bundle_root, COMPILE_ROOT_NAME, "targets.metadata.json" },
    );
    var buf: [PE_PROGRAM_METADATA_CAPACITY]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try pe_program_metadata.emitTargetsJson(descriptors[0..idx], stream.writer());
    try writeFile(path, stream.getWritten());
}

pub fn materializeCompileSources(
    allocator: std.mem.Allocator,
    bundle_root: []const u8,
    plan: host.HostPlan,
    elem: wgsl.ir.ScalarType,
) !void {
    try pruneStaleCompileSourceDirs(allocator, bundle_root, plan.kernels);
    var csl_buf: [wgsl.MAX_CSL_OUTPUT]u8 = undefined;
    for (plan.kernels) |kernel| {
        const source_pattern = compileSourcePatternForPattern(kernel.pattern);
        const source_elem = compileSourceElemForPattern(kernel.pattern, elem);
        const sections = try compile_source.emitPatternSectionsForElem(
            allocator,
            source_pattern,
            source_elem,
            &csl_buf,
        );
        const layout_path = try std.fs.path.join(
            allocator,
            &.{ bundle_root, COMPILE_ROOT_NAME, kernel.name, "layout.csl" },
        );
        const pe_program_path = try std.fs.path.join(
            allocator,
            &.{ bundle_root, COMPILE_ROOT_NAME, kernel.name, "pe_program.csl" },
        );
        const metadata_path = try std.fs.path.join(
            allocator,
            &.{ bundle_root, COMPILE_ROOT_NAME, kernel.name, "pe_program.metadata.json" },
        );
        const layout_metadata_path = try std.fs.path.join(
            allocator,
            &.{ bundle_root, COMPILE_ROOT_NAME, kernel.name, "layout.metadata.json" },
        );
        try writeFile(layout_path, sections.layout);
        try writeFile(pe_program_path, sections.pe_program);
        try emitPeProgramMetadataFile(metadata_path, sections.pe_program);
        try emitLayoutMetadataFile(layout_metadata_path, sections.layout);
    }
}

fn compileSourceElemForPattern(pattern: []const u8, elem: wgsl.ir.ScalarType) wgsl.ir.ScalarType {
    if (std.mem.eql(u8, pattern, "dense_gemv")) return .f32;
    if (std.mem.eql(u8, pattern, "sample")) return .f32;
    return elem;
}

fn compileSourcePatternForPattern(pattern: []const u8) []const u8 {
    if (std.mem.eql(u8, pattern, "prefill_q4k_gemv")) return "fused_gemv_dequant";
    return pattern;
}

fn pruneStaleCompileSourceDirs(
    allocator: std.mem.Allocator,
    bundle_root: []const u8,
    kernels: []const host.KernelSpec,
) !void {
    const compile_root_path = try std.fs.path.join(allocator, &.{ bundle_root, COMPILE_ROOT_NAME });
    var compile_dir = openIterableDirAbsoluteAware(compile_root_path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer compile_dir.close();
    try pruneStaleCompileKernelDirs(&compile_dir, kernels);
}

fn openIterableDirAbsoluteAware(path: []const u8) !std.fs.Dir {
    if (std.fs.path.isAbsolute(path)) {
        return try std.fs.openDirAbsolute(path, .{ .iterate = true });
    }
    return try std.fs.cwd().openDir(path, .{ .iterate = true });
}

fn pruneStaleCompileKernelDirs(
    compile_dir: *std.fs.Dir,
    kernels: []const host.KernelSpec,
) !void {
    var iterator = compile_dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (isReservedCompileDir(entry.name)) continue;
        if (hasKernelName(kernels, entry.name)) continue;
        try compile_dir.deleteTree(entry.name);
    }
}

fn isReservedCompileDir(name: []const u8) bool {
    return std.mem.eql(u8, name, "compiled") or std.mem.eql(u8, name, "driver-logs");
}

fn hasKernelName(kernels: []const host.KernelSpec, name: []const u8) bool {
    for (kernels) |kernel| {
        if (std.mem.eql(u8, kernel.name, name)) return true;
    }
    return false;
}

fn emitPeProgramMetadataFile(path: []const u8, pe_program_source: []const u8) !void {
    var buf: [PE_PROGRAM_METADATA_CAPACITY]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try pe_program_metadata.emitJson(pe_program_source, stream.writer());
    try writeFile(path, stream.getWritten());
}

fn emitLayoutMetadataFile(path: []const u8, layout_source: []const u8) !void {
    var buf: [PE_PROGRAM_METADATA_CAPACITY]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try pe_program_metadata.emitLayoutJson(layout_source, stream.writer());
    try writeFile(path, stream.getWritten());
}

fn ensureParent(path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir_name| {
        if (std.fs.path.isAbsolute(dir_name)) {
            var root = try std.fs.openDirAbsolute("/", .{});
            defer root.close();
            const relative = std.mem.trimLeft(u8, dir_name, "/");
            if (relative.len > 0) {
                try root.makePath(relative);
            }
        } else {
            try std.fs.cwd().makePath(dir_name);
        }
    }
}

fn createFileAbsoluteAware(path: []const u8) !std.fs.File {
    const resolved_path = if (std.fs.path.isAbsolute(path))
        path
    else blk: {
        const cwd = try std.process.getCwdAlloc(std.heap.page_allocator);
        defer std.heap.page_allocator.free(cwd);
        break :blk try std.fs.path.join(std.heap.page_allocator, &.{ cwd, path });
    };
    defer if (!std.fs.path.isAbsolute(path)) std.heap.page_allocator.free(resolved_path);
    return try std.fs.createFileAbsolute(resolved_path, .{ .truncate = true });
}

fn writeFile(path: []const u8, data: []const u8) !void {
    try ensureParent(path);
    const file = try createFileAbsoluteAware(path);
    defer file.close();
    try file.writeAll(data);
}

fn writeExecutableFile(path: []const u8, data: []const u8) !void {
    try ensureParent(path);
    const file = try createFileAbsoluteAware(path);
    defer file.close();
    try file.writeAll(data);
    try file.chmod(0o755);
}

fn pathExistsAbsolute(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

test "materialize compile source cleanup prunes stale kernel dirs only" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("compile/current");
    try tmp_dir.dir.makePath("compile/stale");
    try tmp_dir.dir.makePath("compile/compiled");
    try tmp_dir.dir.makePath("compile/driver-logs");
    const metadata = try tmp_dir.dir.createFile("compile/targets.metadata.json", .{});
    metadata.close();
    var compile_dir = try tmp_dir.dir.openDir("compile", .{ .iterate = true });
    defer compile_dir.close();
    const kernels = [_]host.KernelSpec{
        .{ .name = "current", .pattern = "element_wise", .count = 1 },
    };
    try pruneStaleCompileKernelDirs(&compile_dir, &kernels);
    try compile_dir.access("current", .{});
    try compile_dir.access("compiled", .{});
    try compile_dir.access("driver-logs", .{});
    try compile_dir.access("targets.metadata.json", .{});
    try std.testing.expectError(error.FileNotFound, compile_dir.access("stale", .{}));
}

test "defaultDriverPath resolves checked-in CSL SDK driver" {
    const path = try defaultDriverPath(std.testing.allocator, "unused");
    defer std.testing.allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "runtime/zig/tools/csl_sdk_driver.py"));
    try std.fs.accessAbsolute(path, .{});
}
