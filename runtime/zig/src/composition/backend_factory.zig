//! Composition root for physical backend construction and ownership.
//!
//! Concrete providers expose capability-specific ports. This module is the
//! only ordinary production owner allowed to select one provider, retain its
//! lifetime, and hand a backend-neutral `PortBundle` to the runtime.

const std = @import("std");
const builtin = @import("builtin");
const model_profile = @import("../contracts/model/model_profile.zig");
const backend_contract = @import("../contracts/backend.zig");
const runtime_configuration = @import("../contracts/runtime_configuration.zig");
const backend_policy = @import("../backend/backend_policy.zig");
const port_factory = @import("../backend/ports/factory.zig");
const dawn_delegate_backend = @import("../backend/dawn_delegate_backend.zig");
const metal_backend = if (builtin.os.tag == .macos) @import("../backend/metal/mod.zig") else struct {};
const vulkan_backend = if (builtin.os.tag == .linux) @import("../backend/vulkan/mod.zig") else struct {};
const d3d12_backend = if (builtin.os.tag == .windows) @import("../backend/d3d12/mod.zig") else struct {};

pub const BackendPortBundle = port_factory.PortBundle;

pub const ProviderConfiguration = struct {
    /// Immutable shader/kernel source root.
    kernel_root: ?[]const u8 = null,
    /// Mutable cache policy and storage, copied by providers that retain it.
    pipeline_cache: runtime_configuration.PipelineCacheConfiguration = .{},
};

pub const OwnedProvider = struct {
    context: *anyopaque,
    destroy_context: *const fn (context: *anyopaque) void,
    ports: port_factory.PortBundle,

    pub fn deinit(self: *OwnedProvider) void {
        self.destroy_context(self.context);
        self.context = undefined;
    }
};

fn own(
    comptime Backend: type,
    backend: *Backend,
    destroy_context: *const fn (context: *anyopaque) void,
    reason: []const u8,
    policy_hash: []const u8,
    fallback_used: bool,
) OwnedProvider {
    return .{
        .context = backend,
        .destroy_context = destroy_context,
        .ports = backend.asPorts(reason, policy_hash, fallback_used),
    };
}

pub fn initProvider(
    allocator: std.mem.Allocator,
    policy: backend_policy.SelectionPolicy,
    backend_id: backend_contract.BackendId,
    profile: model_profile.DeviceProfile,
    configuration: ProviderConfiguration,
    reason: []const u8,
    fallback_used: bool,
) !OwnedProvider {
    return switch (backend_id) {
        .dawn_delegate, .webkit_delegate => blk: {
            const backend = try dawn_delegate_backend.DawnDelegateBackend.init_with_id(
                allocator,
                profile,
                configuration.kernel_root,
                backend_id,
            );
            break :blk own(
                dawn_delegate_backend.DawnDelegateBackend,
                backend,
                dawn_delegate_backend.destroyContext,
                reason,
                policy.policy_hash,
                fallback_used,
            );
        },
        .doe_metal => if (comptime builtin.os.tag == .macos) blk: {
            const backend = try metal_backend.ZigMetalBackend.init_with_selection_policy_and_cache_configuration(
                allocator,
                profile,
                configuration.kernel_root,
                configuration.pipeline_cache,
                policy,
            );
            break :blk own(
                metal_backend.ZigMetalBackend,
                backend,
                metal_backend.destroyContext,
                reason,
                policy.policy_hash,
                fallback_used,
            );
        } else error.UnsupportedBackend,
        .doe_vulkan => if (comptime builtin.os.tag == .linux) blk: {
            const backend = try vulkan_backend.ZigVulkanBackend.init_with_selection_policy_and_cache_configuration(
                allocator,
                profile,
                configuration.kernel_root,
                configuration.pipeline_cache,
                policy,
            );
            break :blk own(
                vulkan_backend.ZigVulkanBackend,
                backend,
                vulkan_backend.destroyContext,
                reason,
                policy.policy_hash,
                fallback_used,
            );
        } else error.UnsupportedBackend,
        .doe_d3d12 => if (comptime builtin.os.tag == .windows) blk: {
            const backend = try d3d12_backend.ZigD3D12Backend.init(
                allocator,
                profile,
                configuration.kernel_root,
            );
            break :blk own(
                d3d12_backend.ZigD3D12Backend,
                backend,
                d3d12_backend.destroyContext,
                reason,
                policy.policy_hash,
                fallback_used,
            );
        } else error.UnsupportedBackend,
    };
}
