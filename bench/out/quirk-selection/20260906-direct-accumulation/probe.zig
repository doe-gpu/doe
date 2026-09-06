const std = @import("std");
const runtime = @import("src/quirk/runtime.zig");
const quirks_model = @import("src/contracts/model/model_quirks.zig");
const policy = @import("src/contracts/model/model_policy.zig");
const profile_model = @import("src/contracts/model/model_profile.zig");

const QUIRK_COUNT = 120;
const WARMUP_COUNT = 20;
const REPEAT_COUNT = 2000;
const SAMPLE_COUNT = 7;

pub fn main() !void {
    var quirks: [QUIRK_COUNT]quirks_model.Quirk = undefined;
    const ids = [_][]const u8{ "z", "a", "same" };
    const scopes = std.enums.values(policy.Scope);
    const proofs = std.enums.values(policy.ProofLevel);
    const safeties = std.enums.values(policy.SafetyClass);
    const modes = std.enums.values(policy.VerificationMode);
    for (&quirks, 0..) |*quirk, i| {
        quirk.* = .{
            .schema_version = policy.CURRENT_SCHEMA_VERSION,
            .quirk_id = ids[i % ids.len],
            .scope = scopes[i % scopes.len],
            .match_spec = .{ .vendor = "amd", .api = .vulkan },
            .action = .{ .use_temporary_buffer = .{ .alignment_bytes = @intCast(i + 1) } },
            .safety_class = safeties[i % safeties.len],
            .verification_mode = modes[(i / 3) % modes.len],
            .proof_level = proofs[i % proofs.len],
            .priority = @intCast(i % 11),
            .provenance = .{ .source_repo = "test", .source_path = "probe.zig", .source_commit = "fixture", .observed_at = "test" },
        };
        switch (i % 9) {
            0 => quirk.match_spec.vendor = "intel",
            1 => quirk.match_spec.api = .metal,
            2 => quirk.match_spec.device_family = "other-family",
            3 => quirk.match_spec.device_family = "test-family",
            4 => quirk.match_spec.driver_range = ">=2.0.0,<3.0.0",
            5 => quirk.match_spec.driver_range = ">=3.0.0",
            6 => quirk.match_spec.driver_range = "invalid",
            else => {},
        }
    }
    const profile: profile_model.DeviceProfile = .{
        .vendor = "AMD", .api = .vulkan, .device_family = "test-family",
        .driver_version = .{ .major = 2, .minor = 3, .patch = 4 },
    };
    inline for (.{ false, true }) |filter| {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        var scratch: [65536]u8 = undefined;
        for (0..quirks.len + 1) |len| {
            const context = if (filter)
                try runtime.buildProfileDispatchContext(std.heap.c_allocator, profile, quirks[0..len])
            else
                try runtime.buildDispatchContext(std.heap.c_allocator, quirks[0..len]);
            defer context.deinit();
            inline for (std.meta.fields(runtime.DispatchContext)) |field| {
                if (field.type == runtime.CommandDispatchBucket) {
                    hash.update(field.name);
                    hash.update(try std.fmt.bufPrint(&scratch, "{any}", .{@field(context, field.name)}));
                }
            }
        }
        std.debug.print("decisions\t{}\t{x}\n", .{ filter, hash.finalResult() });
        var counter = std.testing.FailingAllocator.init(std.heap.c_allocator, .{});
        var checksum: u64 = 0;
        for (0..WARMUP_COUNT) |_| {
            const context = if (filter)
                try runtime.buildProfileDispatchContext(counter.allocator(), profile, &quirks)
            else
                try runtime.buildDispatchContext(counter.allocator(), &quirks);
            checksum +%= context.upload.best_score;
            context.deinit();
        }
        for (0..SAMPLE_COUNT) |sample| {
            const allocations_before = counter.allocations;
            const bytes_before = counter.allocated_bytes;
            var timer = try std.time.Timer.start();
            for (0..REPEAT_COUNT) |_| {
                const context = if (filter)
                    try runtime.buildProfileDispatchContext(counter.allocator(), profile, &quirks)
                else
                    try runtime.buildDispatchContext(counter.allocator(), &quirks);
                checksum +%= context.upload.best_score;
                std.mem.doNotOptimizeAway(context);
                context.deinit();
            }
            const elapsed = timer.read();
            std.debug.print("sample\t{}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
                filter, sample, REPEAT_COUNT, elapsed, counter.allocations - allocations_before, counter.allocated_bytes - bytes_before,
            });
        }
        std.debug.print("cleanup\t{}\t{d}\t{d}\t{d}\n", .{ filter, counter.allocated_bytes, counter.freed_bytes, checksum });
    }
}
