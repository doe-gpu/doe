//! Composition-owned lifetime for a selected backend and its runtime ports.
//!
//! The application/runtime layers borrow a PortBundle. Only this composition
//! root constructs and destroys a concrete provider behind narrow ports.

const std = @import("std");
const model_profile = @import("../contracts/model/model_profile.zig");
const backend_contract = @import("../contracts/backend.zig");
const backend_policy = @import("../backend/backend_policy.zig");
const backend_runtime_telemetry = @import("../backend/backend_runtime_telemetry.zig");
const execution = @import("../runtime/execution.zig");
const backend_factory = @import("backend_factory.zig");
const evidence_observer = @import("../contracts/evidence_observer.zig");

pub const Options = struct {
    no_pipeline_cache: bool = false,
    /// Mutable provider cache storage. This is never inferred from kernel_root,
    /// which identifies immutable shader inputs.
    pipeline_cache_dir: []const u8 = "",
    observer: ?evidence_observer.EvidenceObserver = null,
};

const OwnedBackend = struct {
    allocator: std.mem.Allocator,
    provider: backend_factory.OwnedProvider,
    policy_hash: []u8,

    fn init(
        allocator: std.mem.Allocator,
        profile: model_profile.DeviceProfile,
        kernel_root: ?[]const u8,
        pipeline_cache_dir: []const u8,
        lane: backend_policy.BackendLane,
    ) !OwnedBackend {
        const loaded_policy = try backend_policy.load_policy_for_lane(
            allocator,
            backend_policy.DEFAULT_RUNTIME_POLICY_PATH,
            lane,
        );
        errdefer allocator.free(loaded_policy.owned_policy_hash);
        const selection = backend_contract.select(profile, loaded_policy.policy);
        const provider = try backend_factory.initProvider(
            allocator,
            loaded_policy.policy,
            selection.backend_id,
            profile,
            kernel_root,
            pipeline_cache_dir,
            selection.reason,
            selection.fallback_used,
        );
        return .{
            .allocator = allocator,
            .provider = provider,
            .policy_hash = loaded_policy.owned_policy_hash,
        };
    }

    fn deinit(self: *OwnedBackend) void {
        self.provider.deinit();
        self.allocator.free(self.policy_hash);
    }
};

pub const ExecutionSession = struct {
    allocator: std.mem.Allocator,
    owned_backend: ?*OwnedBackend,
    context: execution.ExecutionContext,

    pub fn init(
        allocator: std.mem.Allocator,
        mode: execution.BackendMode,
        profile: model_profile.DeviceProfile,
        kernel_root: ?[]const u8,
        lane: backend_policy.BackendLane,
        options: Options,
    ) !ExecutionSession {
        if (mode == .trace) {
            var context = execution.ExecutionContext.initTrace(lane);
            context.setEvidenceObserver(options.observer);
            return .{
                .allocator = allocator,
                .owned_backend = null,
                .context = context,
            };
        }

        backend_runtime_telemetry.set_metal_pipeline_cache_disabled(options.no_pipeline_cache);
        backend_runtime_telemetry.set_vulkan_pipeline_cache_disabled(options.no_pipeline_cache);
        backend_runtime_telemetry.set_vulkan_pipeline_cache_dir(options.pipeline_cache_dir);

        const owned_backend = try allocator.create(OwnedBackend);
        errdefer allocator.destroy(owned_backend);
        owned_backend.* = try OwnedBackend.init(
            allocator,
            profile,
            kernel_root,
            options.pipeline_cache_dir,
            lane,
        );
        errdefer owned_backend.deinit();
        var context = execution.ExecutionContext.initNative(lane, owned_backend.provider.ports);
        context.setEvidenceObserver(options.observer);
        return .{
            .allocator = allocator,
            .owned_backend = owned_backend,
            .context = context,
        };
    }

    pub fn deinit(self: *ExecutionSession) void {
        self.context.deinit();
        if (self.owned_backend) |owned_backend| {
            owned_backend.deinit();
            self.allocator.destroy(owned_backend);
            self.owned_backend = null;
        }
    }

    pub fn contextPtr(self: *ExecutionSession) *execution.ExecutionContext {
        return &self.context;
    }
};

pub fn needsLibraryLifetimeGuard(lane: backend_policy.BackendLane) bool {
    return switch (backend_policy.default_policy_for_lane(lane).default_backend) {
        .dawn_delegate, .webkit_delegate => true,
        else => false,
    };
}

test "library lifetime guard applies only to delegate lanes" {
    try std.testing.expect(needsLibraryLifetimeGuard(.vulkan_dawn_release));
    try std.testing.expect(needsLibraryLifetimeGuard(.metal_webkit_release));
    try std.testing.expect(!needsLibraryLifetimeGuard(.vulkan_doe_comparable));
}
