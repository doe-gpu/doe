const std = @import("std");
const compute_services = @import("../../src/full/modules/services/compute_services.zig");
const effects_pipeline = @import("../../src/full/modules/rendering/effects_pipeline.zig");
const path_engine = @import("../../src/full/modules/rendering/path_engine.zig");
const resource_scheduler = @import("../../src/full/modules/services/resource_scheduler.zig");
const sdf_renderer = @import("../../src/full/modules/rendering/sdf_renderer.zig");
const artifact = @import("../../src/contracts/artifact.zig");

fn readRepoFile(allocator: std.mem.Allocator, root_relative: []const u8) ![]u8 {
    const local_path = try std.fmt.allocPrint(allocator, "../{s}", .{root_relative});
    defer allocator.free(local_path);
    return std.fs.cwd().readFileAlloc(allocator, local_path, 1 << 20) catch
        std.fs.cwd().readFileAlloc(allocator, root_relative, 1 << 20);
}

fn chdirRepoRoot() !std.fs.Dir {
    const original_dir = try std.fs.cwd().openDir(".", .{});
    try std.posix.chdir("..");
    return original_dir;
}

test "fawn_compute_services determinism" {
    var original_dir = try chdirRepoRoot();
    defer {
        std.posix.fchdir(original_dir.fd) catch unreachable;
        original_dir.close();
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const request_bytes = try readRepoFile(
        allocator,
        "browser/chromium/module-incubation/fixtures/fawn-compute-services.request.json",
    );
    const policy_bytes = try readRepoFile(
        allocator,
        "config/compute-services.policy.json",
    );
    const parsed_request = try compute_services.parseRequest(allocator, request_bytes);
    const parsed_policy = try compute_services.parsePolicy(allocator, policy_bytes);

    const result = try compute_services.execute(allocator, parsed_request.value, parsed_policy.value);
    const result_hash = try artifact.stableHashJsonAlloc(allocator, result);
    try std.testing.expectEqualStrings(
        "c25048d78ffb065ebe75aa715059851e7152812674a65a4a3479da8c82289a98",
        result_hash,
    );
}

test "fawn_resource_scheduler determinism" {
    var original_dir = try chdirRepoRoot();
    defer {
        std.posix.fchdir(original_dir.fd) catch unreachable;
        original_dir.close();
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const request_bytes = try readRepoFile(
        allocator,
        "browser/chromium/module-incubation/fixtures/fawn-resource-scheduler.request.json",
    );
    const policy_bytes = try readRepoFile(
        allocator,
        "config/resource-scheduler.policy.json",
    );
    const parsed_request = try resource_scheduler.parseRequest(allocator, request_bytes);
    const parsed_policy = try resource_scheduler.parsePolicy(allocator, policy_bytes);

    const result = try resource_scheduler.execute(allocator, parsed_request.value, parsed_policy.value);
    const result_hash = try artifact.stableHashJsonAlloc(allocator, result);
    try std.testing.expectEqualStrings(
        "6ddf79a67b264b4d8c87ce03b3189b5ee022ada09c1a3ea648d824c97efb5140",
        result_hash,
    );
}

test "fawn_effects_pipeline determinism" {
    var original_dir = try chdirRepoRoot();
    defer {
        std.posix.fchdir(original_dir.fd) catch unreachable;
        original_dir.close();
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const request_bytes = try readRepoFile(
        allocator,
        "browser/chromium/module-incubation/fixtures/fawn-effects-pipeline.request.json",
    );
    const policy_bytes = try readRepoFile(
        allocator,
        "config/effects-pipeline.policy.json",
    );
    const parsed_request = try effects_pipeline.parseRequest(allocator, request_bytes);
    const parsed_policy = try effects_pipeline.parsePolicy(allocator, policy_bytes);

    const result = try effects_pipeline.execute(allocator, parsed_request.value, parsed_policy.value);
    const result_hash = try artifact.stableHashJsonAlloc(allocator, result);
    try std.testing.expectEqualStrings(
        "475f0bd093ac90d925d78ea58cc7f42147ada1be938e3d8a60df2dd16c2ddb20",
        result_hash,
    );
}

test "fawn_path_engine determinism" {
    var original_dir = try chdirRepoRoot();
    defer {
        std.posix.fchdir(original_dir.fd) catch unreachable;
        original_dir.close();
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const request_bytes = try readRepoFile(
        allocator,
        "browser/chromium/module-incubation/fixtures/fawn-path-engine.request.json",
    );
    const policy_bytes = try readRepoFile(
        allocator,
        "config/path-engine.policy.json",
    );
    const parsed_request = try path_engine.parseRequest(allocator, request_bytes);
    const parsed_policy = try path_engine.parsePolicy(allocator, policy_bytes);

    const result = try path_engine.execute(allocator, parsed_request.value, parsed_policy.value);
    const result_hash = try artifact.stableHashJsonAlloc(allocator, result);
    try std.testing.expectEqualStrings(
        "1e700704ac444c8e5453831ae84b4aafde49e99509b29ae195bb87a14783a4f5",
        result_hash,
    );
}

test "fawn_2d_sdf_renderer determinism" {
    var original_dir = try chdirRepoRoot();
    defer {
        std.posix.fchdir(original_dir.fd) catch unreachable;
        original_dir.close();
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const request_bytes = try readRepoFile(
        allocator,
        "browser/chromium/module-incubation/fixtures/fawn-2d-sdf-renderer.request.json",
    );
    const policy_bytes = try readRepoFile(
        allocator,
        "config/sdf-renderer.policy.json",
    );
    const parsed_request = try sdf_renderer.parseRequest(allocator, request_bytes);
    const parsed_policy = try sdf_renderer.parsePolicy(allocator, policy_bytes);

    const result = try sdf_renderer.execute(allocator, parsed_request.value, parsed_policy.value);
    const result_hash = try artifact.stableHashJsonAlloc(allocator, result);
    try std.testing.expectEqualStrings(
        "85a0f35ec66dce2ee7e017cddc1461a53c920a328f66949ab78ed01e6499c135",
        result_hash,
    );
}
