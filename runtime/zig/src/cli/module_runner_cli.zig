const std = @import("std");
const compute_services = @import("../full/modules/services/compute_services.zig");
const effects_pipeline = @import("../full/modules/rendering/effects_pipeline.zig");
const numeric_stability = @import("../experimental/numeric_stability/mod.zig");
const path_engine = @import("../full/modules/rendering/path_engine.zig");
const resource_scheduler = @import("../full/modules/services/resource_scheduler.zig");
const sdf_renderer = @import("../full/modules/rendering/sdf_renderer.zig");
const common = @import("../full/modules/common.zig");

const Allocator = std.mem.Allocator;
const ModuleRunFn = *const fn (Allocator, []const u8, []const u8, []const u8) anyerror![]u8;

pub const RunnerError = error{
    MissingValue,
    MissingRequest,
    MissingPolicy,
    UnsupportedModule,
};

const ModuleAdapter = struct {
    module_id: []const u8,
    run: ModuleRunFn,
};

const RunOptions = struct {
    request_path: []const u8,
    policy_path: []const u8,
    module_id: []const u8,
};

fn readFileAlloc(allocator: Allocator, path: []const u8) ![]u8 {
    const max_bytes = 16 * 1024 * 1024;
    if (std.fs.path.isAbsolute(path)) {
        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        return try file.readToEndAlloc(allocator, max_bytes);
    }
    return try std.fs.cwd().readFileAlloc(allocator, path, max_bytes);
}

fn getOptionValue(args: [][:0]u8, index: *usize) ![]const u8 {
    if (index.* + 1 >= args.len) return RunnerError.MissingValue;
    index.* += 1;
    return args[index.*];
}

fn getOwnedOptionValue(allocator: Allocator, args: [][:0]u8, index: *usize) ![]const u8 {
    const value = try getOptionValue(args, index);
    return try allocator.dupe(u8, value);
}

fn simpleModuleRunner(comptime Module: type) ModuleRunFn {
    return struct {
        fn run(
            allocator: Allocator,
            request_bytes: []const u8,
            _: []const u8,
            policy_bytes: []const u8,
        ) ![]u8 {
            var parsed_request = try Module.parseRequest(allocator, request_bytes);
            defer parsed_request.deinit();
            var parsed_policy = try Module.parsePolicy(allocator, policy_bytes);
            defer parsed_policy.deinit();
            const result = try Module.execute(allocator, parsed_request.value, parsed_policy.value);
            return try common.jsonStringifyAlloc(allocator, result);
        }
    }.run;
}

fn runNumericStabilityModule(
    allocator: Allocator,
    request_bytes: []const u8,
    policy_path: []const u8,
    policy_bytes: []const u8,
) ![]u8 {
    var parsed_request = try numeric_stability.service.parseRequest(allocator, request_bytes);
    defer parsed_request.deinit();
    var parsed_policy = try numeric_stability.service.parsePolicy(allocator, policy_path, policy_bytes);
    defer parsed_policy.deinit(allocator);
    const result = try numeric_stability.service.execute(allocator, parsed_request.value, parsed_policy.value);
    return try common.jsonStringifyAlloc(allocator, result);
}

const MODULE_ADAPTERS = [_]ModuleAdapter{
    .{ .module_id = compute_services.MODULE_ID, .run = simpleModuleRunner(compute_services) },
    .{ .module_id = numeric_stability.service.MODULE_ID, .run = runNumericStabilityModule },
    .{ .module_id = effects_pipeline.MODULE_ID, .run = simpleModuleRunner(effects_pipeline) },
    .{ .module_id = path_engine.MODULE_ID, .run = simpleModuleRunner(path_engine) },
    .{ .module_id = resource_scheduler.MODULE_ID, .run = simpleModuleRunner(resource_scheduler) },
    .{ .module_id = sdf_renderer.MODULE_ID, .run = simpleModuleRunner(sdf_renderer) },
};

fn parseArgs(allocator: Allocator) !RunOptions {
    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    var request_path: ?[]const u8 = null;
    var policy_path: ?[]const u8 = null;
    var module_id: ?[]const u8 = null;

    var idx: usize = 1;
    while (idx < argv.len) : (idx += 1) {
        if (std.mem.eql(u8, argv[idx], "--request")) {
            request_path = try getOwnedOptionValue(allocator, argv, &idx);
        } else if (std.mem.eql(u8, argv[idx], "--policy")) {
            policy_path = try getOwnedOptionValue(allocator, argv, &idx);
        } else if (std.mem.eql(u8, argv[idx], "--module")) {
            module_id = try getOwnedOptionValue(allocator, argv, &idx);
        }
    }

    return .{
        .request_path = request_path orelse return RunnerError.MissingRequest,
        .policy_path = policy_path orelse return RunnerError.MissingPolicy,
        .module_id = module_id orelse return RunnerError.UnsupportedModule,
    };
}

fn findModuleRunner(module_id: []const u8) ?ModuleRunFn {
    for (MODULE_ADAPTERS) |adapter| {
        if (std.mem.eql(u8, adapter.module_id, module_id)) {
            return adapter.run;
        }
    }
    return null;
}

pub fn runCli() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const options = try parseArgs(allocator);
    const request_bytes = try readFileAlloc(allocator, options.request_path);
    defer allocator.free(request_bytes);
    const policy_bytes = try readFileAlloc(allocator, options.policy_path);
    defer allocator.free(policy_bytes);

    const runner = findModuleRunner(options.module_id) orelse return RunnerError.UnsupportedModule;
    const payload = try runner(allocator, request_bytes, options.policy_path, policy_bytes);
    defer allocator.free(payload);

    var stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.writeAll(payload);
    try stdout.writeAll("\n");
}
