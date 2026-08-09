const std = @import("std");
const command = @import("../../src/contracts/command.zig");
const policy = @import("../../src/contracts/model/model_policy.zig");
const profile = @import("../../src/contracts/model/model_profile.zig");
const quirks = @import("../../src/contracts/model/model_quirks.zig");
const gpu = @import("../../src/contracts/model/model_gpu_types.zig");
const resource = @import("../../src/contracts/model/model_resource_types.zig");
const compute = @import("../../src/contracts/model/model_compute_types.zig");
const render_types = @import("../../src/contracts/model/model_render_types.zig");
const surface = @import("../../src/contracts/model/model_surface_control_types.zig");
const async_types = @import("../../src/contracts/model/model_async_types.zig");

// ============================================================
// Schema version stability
// ============================================================

test "CURRENT_SCHEMA_VERSION is 2" {
    try std.testing.expectEqual(@as(policy.SchemaVersion, 2), policy.CURRENT_SCHEMA_VERSION);
}

test "SchemaVersion is u8" {
    try std.testing.expect(@TypeOf(policy.CURRENT_SCHEMA_VERSION) == policy.SchemaVersion);
    try std.testing.expect(policy.SchemaVersion == u8);
}

// ============================================================
// Api enum — ordinal stability and exhaustiveness
// ============================================================

test "Api enum has exactly 4 variants" {
    const fields = @typeInfo(policy.Api).@"enum".fields;
    try std.testing.expectEqual(@as(usize, 4), fields.len);
}

test "Api enum ordinals are stable" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(policy.Api.vulkan));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(policy.Api.metal));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(policy.Api.d3d12));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(policy.Api.webgpu));
}

test "Api enum tag names match expected strings" {
    try std.testing.expectEqualStrings("vulkan", @tagName(policy.Api.vulkan));
    try std.testing.expectEqualStrings("metal", @tagName(policy.Api.metal));
    try std.testing.expectEqualStrings("d3d12", @tagName(policy.Api.d3d12));
    try std.testing.expectEqualStrings("webgpu", @tagName(policy.Api.webgpu));
}

// ============================================================
// Scope enum — ordinal stability and exhaustiveness
// ============================================================

test "Scope enum has exactly 5 variants" {
    const fields = @typeInfo(policy.Scope).@"enum".fields;
    try std.testing.expectEqual(@as(usize, 5), fields.len);
}

test "Scope enum ordinals are stable" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(policy.Scope.alignment));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(policy.Scope.barrier));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(policy.Scope.layout));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(policy.Scope.driver_toggle));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(policy.Scope.memory));
}

// ============================================================
// SafetyClass enum — ordinal stability and exhaustiveness
// ============================================================

test "SafetyClass enum has exactly 4 variants" {
    const fields = @typeInfo(policy.SafetyClass).@"enum".fields;
    try std.testing.expectEqual(@as(usize, 4), fields.len);
}

test "SafetyClass enum ordinals are stable" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(policy.SafetyClass.low));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(policy.SafetyClass.moderate));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(policy.SafetyClass.high));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(policy.SafetyClass.critical));
}

// ============================================================
// VerificationMode enum — ordinal stability and exhaustiveness
// ============================================================

test "VerificationMode enum has exactly 3 variants" {
    const fields = @typeInfo(policy.VerificationMode).@"enum".fields;
    try std.testing.expectEqual(@as(usize, 3), fields.len);
}

test "VerificationMode enum ordinals are stable" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(policy.VerificationMode.guard_only));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(policy.VerificationMode.lean_preferred));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(policy.VerificationMode.lean_required));
}

// ============================================================
// ProofLevel enum — ordinal stability and exhaustiveness
// ============================================================

test "ProofLevel enum has exactly 3 variants" {
    const fields = @typeInfo(policy.ProofLevel).@"enum".fields;
    try std.testing.expectEqual(@as(usize, 3), fields.len);
}

test "ProofLevel enum ordinals are stable" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(policy.ProofLevel.proven));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(policy.ProofLevel.guarded));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(policy.ProofLevel.rejected));
}

// ============================================================
// CommandKind enum — ordinal stability and count
// ============================================================

test "CommandKind enum has exactly 25 variants" {
    const fields = @typeInfo(command.CommandKind).@"enum".fields;
    try std.testing.expectEqual(@as(usize, 25), fields.len);
}

test "CommandKind ordinals for core commands are stable" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(command.CommandKind.upload));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(command.CommandKind.buffer_write));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(command.CommandKind.copy_buffer_to_texture));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(command.CommandKind.barrier));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(command.CommandKind.dispatch));
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(command.CommandKind.dispatch_indirect));
    try std.testing.expectEqual(@as(u8, 6), @intFromEnum(command.CommandKind.kernel_dispatch));
}

test "CommandKind ordinals for full commands are stable" {
    try std.testing.expectEqual(@as(u8, 7), @intFromEnum(command.CommandKind.render_draw));
    try std.testing.expectEqual(@as(u8, 8), @intFromEnum(command.CommandKind.draw_indirect));
    try std.testing.expectEqual(@as(u8, 9), @intFromEnum(command.CommandKind.draw_indexed_indirect));
    try std.testing.expectEqual(@as(u8, 10), @intFromEnum(command.CommandKind.render_pass));
    try std.testing.expectEqual(@as(u8, 11), @intFromEnum(command.CommandKind.sampler_create));
    try std.testing.expectEqual(@as(u8, 12), @intFromEnum(command.CommandKind.sampler_destroy));
    try std.testing.expectEqual(@as(u8, 13), @intFromEnum(command.CommandKind.texture_write));
    try std.testing.expectEqual(@as(u8, 14), @intFromEnum(command.CommandKind.texture_query));
    try std.testing.expectEqual(@as(u8, 15), @intFromEnum(command.CommandKind.texture_destroy));
    try std.testing.expectEqual(@as(u8, 16), @intFromEnum(command.CommandKind.surface_create));
    try std.testing.expectEqual(@as(u8, 17), @intFromEnum(command.CommandKind.surface_capabilities));
    try std.testing.expectEqual(@as(u8, 18), @intFromEnum(command.CommandKind.surface_configure));
    try std.testing.expectEqual(@as(u8, 19), @intFromEnum(command.CommandKind.surface_acquire));
    try std.testing.expectEqual(@as(u8, 20), @intFromEnum(command.CommandKind.surface_present));
    try std.testing.expectEqual(@as(u8, 21), @intFromEnum(command.CommandKind.surface_unconfigure));
    try std.testing.expectEqual(@as(u8, 22), @intFromEnum(command.CommandKind.surface_release));
    try std.testing.expectEqual(@as(u8, 23), @intFromEnum(command.CommandKind.async_diagnostics));
    try std.testing.expectEqual(@as(u8, 24), @intFromEnum(command.CommandKind.map_async));
}

// ============================================================
// Command union — variant count equals CommandKind count
// ============================================================

test "Command union variant count matches CommandKind field count" {
    const cmd_fields = @typeInfo(command.Command).@"union".fields;
    const kind_fields = @typeInfo(command.CommandKind).@"enum".fields;
    try std.testing.expectEqual(kind_fields.len, cmd_fields.len);
}

test "Command registry assigns every kind to one scope" {
    try std.testing.expectEqual(@as(usize, 25), command.metadata.len);
    var core_count: usize = 0;
    var full_count: usize = 0;
    for (command.metadata) |metadata| switch (metadata.scope) {
        .core => core_count += 1,
        .full => full_count += 1,
    };
    try std.testing.expectEqual(@as(usize, 11), core_count);
    try std.testing.expectEqual(@as(usize, 14), full_count);
}

// ============================================================
// parse_api — valid, invalid, case-insensitive
// ============================================================

test "parse_api accepts lowercase variants" {
    try std.testing.expectEqual(policy.Api.vulkan, try policy.parse_api("vulkan"));
    try std.testing.expectEqual(policy.Api.metal, try policy.parse_api("metal"));
    try std.testing.expectEqual(policy.Api.d3d12, try policy.parse_api("d3d12"));
    try std.testing.expectEqual(policy.Api.webgpu, try policy.parse_api("webgpu"));
}

test "parse_api accepts uppercase variants" {
    try std.testing.expectEqual(policy.Api.vulkan, try policy.parse_api("VULKAN"));
    try std.testing.expectEqual(policy.Api.metal, try policy.parse_api("METAL"));
    try std.testing.expectEqual(policy.Api.d3d12, try policy.parse_api("D3D12"));
    try std.testing.expectEqual(policy.Api.webgpu, try policy.parse_api("WEBGPU"));
}

test "parse_api accepts mixed-case variants" {
    try std.testing.expectEqual(policy.Api.vulkan, try policy.parse_api("Vulkan"));
    try std.testing.expectEqual(policy.Api.metal, try policy.parse_api("Metal"));
}

test "parse_api rejects unknown strings" {
    try std.testing.expectError(error.InvalidApi, policy.parse_api("opengl"));
    try std.testing.expectError(error.InvalidApi, policy.parse_api(""));
    try std.testing.expectError(error.InvalidApi, policy.parse_api("dx12"));
    try std.testing.expectError(error.InvalidApi, policy.parse_api("vulkan "));
}

// ============================================================
// parse_scope — valid, invalid, case-insensitive
// ============================================================

test "parse_scope accepts all valid scopes" {
    try std.testing.expectEqual(policy.Scope.alignment, try policy.parse_scope("alignment"));
    try std.testing.expectEqual(policy.Scope.barrier, try policy.parse_scope("barrier"));
    try std.testing.expectEqual(policy.Scope.layout, try policy.parse_scope("layout"));
    try std.testing.expectEqual(policy.Scope.driver_toggle, try policy.parse_scope("driver_toggle"));
    try std.testing.expectEqual(policy.Scope.memory, try policy.parse_scope("memory"));
}

test "parse_scope is case-insensitive" {
    try std.testing.expectEqual(policy.Scope.alignment, try policy.parse_scope("ALIGNMENT"));
    try std.testing.expectEqual(policy.Scope.barrier, try policy.parse_scope("Barrier"));
    try std.testing.expectEqual(policy.Scope.memory, try policy.parse_scope("MEMORY"));
}

test "parse_scope rejects unknown strings" {
    try std.testing.expectError(error.InvalidScope, policy.parse_scope("unknown"));
    try std.testing.expectError(error.InvalidScope, policy.parse_scope(""));
    try std.testing.expectError(error.InvalidScope, policy.parse_scope("compute"));
}

// ============================================================
// parse_safety — valid, invalid, case-insensitive
// ============================================================

test "parse_safety accepts all valid classes" {
    try std.testing.expectEqual(policy.SafetyClass.low, try policy.parse_safety("low"));
    try std.testing.expectEqual(policy.SafetyClass.moderate, try policy.parse_safety("moderate"));
    try std.testing.expectEqual(policy.SafetyClass.high, try policy.parse_safety("high"));
    try std.testing.expectEqual(policy.SafetyClass.critical, try policy.parse_safety("critical"));
}

test "parse_safety is case-insensitive" {
    try std.testing.expectEqual(policy.SafetyClass.low, try policy.parse_safety("LOW"));
    try std.testing.expectEqual(policy.SafetyClass.critical, try policy.parse_safety("CRITICAL"));
}

test "parse_safety rejects unknown strings" {
    try std.testing.expectError(error.InvalidSafetyClass, policy.parse_safety("extreme"));
    try std.testing.expectError(error.InvalidSafetyClass, policy.parse_safety(""));
    try std.testing.expectError(error.InvalidSafetyClass, policy.parse_safety("medium"));
}

// ============================================================
// parse_verification_mode — valid, invalid, case-insensitive
// ============================================================

test "parse_verification_mode accepts all valid modes" {
    try std.testing.expectEqual(policy.VerificationMode.guard_only, try policy.parse_verification_mode("guard_only"));
    try std.testing.expectEqual(policy.VerificationMode.lean_preferred, try policy.parse_verification_mode("lean_preferred"));
    try std.testing.expectEqual(policy.VerificationMode.lean_required, try policy.parse_verification_mode("lean_required"));
}

test "parse_verification_mode is case-insensitive" {
    try std.testing.expectEqual(policy.VerificationMode.lean_required, try policy.parse_verification_mode("LEAN_REQUIRED"));
    try std.testing.expectEqual(policy.VerificationMode.guard_only, try policy.parse_verification_mode("Guard_Only"));
}

test "parse_verification_mode rejects unknown strings" {
    try std.testing.expectError(error.InvalidVerificationMode, policy.parse_verification_mode("auto"));
    try std.testing.expectError(error.InvalidVerificationMode, policy.parse_verification_mode(""));
    try std.testing.expectError(error.InvalidVerificationMode, policy.parse_verification_mode("lean"));
}

// ============================================================
// parse_proof_level — valid, invalid, case-insensitive
// ============================================================

test "parse_proof_level accepts all valid levels" {
    try std.testing.expectEqual(policy.ProofLevel.proven, try policy.parse_proof_level("proven"));
    try std.testing.expectEqual(policy.ProofLevel.guarded, try policy.parse_proof_level("guarded"));
    try std.testing.expectEqual(policy.ProofLevel.rejected, try policy.parse_proof_level("rejected"));
}

test "parse_proof_level is case-insensitive" {
    try std.testing.expectEqual(policy.ProofLevel.rejected, try policy.parse_proof_level("REJECTED"));
    try std.testing.expectEqual(policy.ProofLevel.proven, try policy.parse_proof_level("Proven"));
}

test "parse_proof_level rejects unknown strings" {
    try std.testing.expectError(error.InvalidProofLevel, policy.parse_proof_level("pending"));
    try std.testing.expectError(error.InvalidProofLevel, policy.parse_proof_level(""));
    try std.testing.expectError(error.InvalidProofLevel, policy.parse_proof_level("verified"));
}

// ============================================================
// Name functions — round-trip with parsers
// ============================================================

test "verification_mode_name round-trips for all variants" {
    const modes = [_]policy.VerificationMode{ .guard_only, .lean_preferred, .lean_required };
    for (modes) |mode| {
        const name = policy.verification_mode_name(mode);
        const parsed = try policy.parse_verification_mode(name);
        try std.testing.expectEqual(mode, parsed);
    }
}

test "proof_level_name round-trips for all variants" {
    const levels = [_]policy.ProofLevel{ .proven, .guarded, .rejected };
    for (levels) |level| {
        const name = policy.proof_level_name(level);
        const parsed = try policy.parse_proof_level(name);
        try std.testing.expectEqual(level, parsed);
    }
}

test "scope_name returns correct strings for all variants" {
    try std.testing.expectEqualStrings("alignment", policy.scope_name(.alignment));
    try std.testing.expectEqualStrings("barrier", policy.scope_name(.barrier));
    try std.testing.expectEqualStrings("layout", policy.scope_name(.layout));
    try std.testing.expectEqualStrings("driver_toggle", policy.scope_name(.driver_toggle));
    try std.testing.expectEqualStrings("memory", policy.scope_name(.memory));
}

test "safety_class_name returns correct strings for all variants" {
    try std.testing.expectEqualStrings("low", policy.safety_class_name(.low));
    try std.testing.expectEqualStrings("moderate", policy.safety_class_name(.moderate));
    try std.testing.expectEqualStrings("high", policy.safety_class_name(.high));
    try std.testing.expectEqualStrings("critical", policy.safety_class_name(.critical));
}

test "verification_mode_name returns correct strings for all variants" {
    try std.testing.expectEqualStrings("guard_only", policy.verification_mode_name(.guard_only));
    try std.testing.expectEqualStrings("lean_preferred", policy.verification_mode_name(.lean_preferred));
    try std.testing.expectEqualStrings("lean_required", policy.verification_mode_name(.lean_required));
}

test "proof_level_name returns correct strings for all variants" {
    try std.testing.expectEqualStrings("proven", policy.proof_level_name(.proven));
    try std.testing.expectEqualStrings("guarded", policy.proof_level_name(.guarded));
    try std.testing.expectEqualStrings("rejected", policy.proof_level_name(.rejected));
}

// ============================================================
// requiresProof / needsStrongestProof
// ============================================================

test "requiresProof is true only for lean_required" {
    try std.testing.expect(policy.requiresProof(.lean_required));
    try std.testing.expect(!policy.requiresProof(.lean_preferred));
    try std.testing.expect(!policy.requiresProof(.guard_only));
}

test "needsStrongestProof is true only for proven" {
    try std.testing.expect(policy.needsStrongestProof(.proven));
    try std.testing.expect(!policy.needsStrongestProof(.guarded));
    try std.testing.expect(!policy.needsStrongestProof(.rejected));
}

// ============================================================
// SemVer.parse — valid inputs
// ============================================================

test "SemVer.parse three-part version" {
    const v = try profile.SemVer.parse("1.2.3");
    try std.testing.expectEqual(@as(u32, 1), v.major);
    try std.testing.expectEqual(@as(u32, 2), v.minor);
    try std.testing.expectEqual(@as(u32, 3), v.patch);
}

test "SemVer.parse two-part version defaults patch to 0" {
    const v = try profile.SemVer.parse("10.20");
    try std.testing.expectEqual(@as(u32, 10), v.major);
    try std.testing.expectEqual(@as(u32, 20), v.minor);
    try std.testing.expectEqual(@as(u32, 0), v.patch);
}

test "SemVer.parse single number defaults minor and patch to 0" {
    const v = try profile.SemVer.parse("5");
    try std.testing.expectEqual(@as(u32, 5), v.major);
    try std.testing.expectEqual(@as(u32, 0), v.minor);
    try std.testing.expectEqual(@as(u32, 0), v.patch);
}

test "SemVer.parse zero version" {
    const v = try profile.SemVer.parse("0.0.0");
    try std.testing.expectEqual(@as(u32, 0), v.major);
    try std.testing.expectEqual(@as(u32, 0), v.minor);
    try std.testing.expectEqual(@as(u32, 0), v.patch);
}

test "SemVer.parse large numbers" {
    const v = try profile.SemVer.parse("999.888.777");
    try std.testing.expectEqual(@as(u32, 999), v.major);
    try std.testing.expectEqual(@as(u32, 888), v.minor);
    try std.testing.expectEqual(@as(u32, 777), v.patch);
}

// ============================================================
// SemVer.parse — invalid inputs
// ============================================================

test "SemVer.parse rejects empty part between dots" {
    try std.testing.expectError(error.InvalidVersion, profile.SemVer.parse("1..3"));
}

test "SemVer.parse rejects four-part version" {
    try std.testing.expectError(error.InvalidVersion, profile.SemVer.parse("1.2.3.4"));
}

test "SemVer.parse rejects non-numeric part" {
    try std.testing.expectError(error.InvalidVersion, profile.SemVer.parse("1.abc.3"));
}

test "SemVer.parse rejects trailing dot" {
    try std.testing.expectError(error.InvalidVersion, profile.SemVer.parse("1.2."));
}

test "SemVer.parse rejects leading dot" {
    try std.testing.expectError(error.InvalidVersion, profile.SemVer.parse(".1.2"));
}

test "SemVer.parse rejects negative numbers" {
    try std.testing.expectError(error.InvalidVersion, profile.SemVer.parse("-1.0.0"));
}

// ============================================================
// SemVer comparison — cmp, equals, ge, gt, lt
// ============================================================

test "SemVer.cmp returns eq for identical versions" {
    const v = profile.SemVer{ .major = 1, .minor = 2, .patch = 3 };
    try std.testing.expectEqual(std.math.Order.eq, v.cmp(v));
}

test "SemVer.cmp major dominates" {
    const a = profile.SemVer{ .major = 1, .minor = 99, .patch = 99 };
    const b = profile.SemVer{ .major = 2, .minor = 0, .patch = 0 };
    try std.testing.expectEqual(std.math.Order.lt, a.cmp(b));
    try std.testing.expectEqual(std.math.Order.gt, b.cmp(a));
}

test "SemVer.cmp minor breaks tie on major" {
    const a = profile.SemVer{ .major = 1, .minor = 0, .patch = 99 };
    const b = profile.SemVer{ .major = 1, .minor = 1, .patch = 0 };
    try std.testing.expectEqual(std.math.Order.lt, a.cmp(b));
}

test "SemVer.cmp patch breaks tie on major and minor" {
    const a = profile.SemVer{ .major = 1, .minor = 2, .patch = 3 };
    const b = profile.SemVer{ .major = 1, .minor = 2, .patch = 4 };
    try std.testing.expectEqual(std.math.Order.lt, a.cmp(b));
}

test "SemVer.equals returns true for identical versions" {
    const v = profile.SemVer{ .major = 3, .minor = 5, .patch = 7 };
    try std.testing.expect(v.equals(v));
}

test "SemVer.equals returns false for different versions" {
    const a = profile.SemVer{ .major = 1, .minor = 0, .patch = 0 };
    const b = profile.SemVer{ .major = 1, .minor = 0, .patch = 1 };
    try std.testing.expect(!a.equals(b));
}

test "SemVer.ge includes equal" {
    const v = profile.SemVer{ .major = 2, .minor = 0, .patch = 0 };
    try std.testing.expect(v.ge(v));
}

test "SemVer.ge includes greater" {
    const a = profile.SemVer{ .major = 2, .minor = 0, .patch = 0 };
    const b = profile.SemVer{ .major = 1, .minor = 0, .patch = 0 };
    try std.testing.expect(a.ge(b));
}

test "SemVer.ge returns false when less" {
    const a = profile.SemVer{ .major = 1, .minor = 0, .patch = 0 };
    const b = profile.SemVer{ .major = 2, .minor = 0, .patch = 0 };
    try std.testing.expect(!a.ge(b));
}

test "SemVer.gt excludes equal" {
    const v = profile.SemVer{ .major = 1, .minor = 1, .patch = 1 };
    try std.testing.expect(!v.gt(v));
}

test "SemVer.lt excludes equal" {
    const v = profile.SemVer{ .major = 1, .minor = 1, .patch = 1 };
    try std.testing.expect(!v.lt(v));
}

// ============================================================
// command_kind — tag extraction from Command union
// ============================================================

test "command_kind extracts upload tag" {
    const cmd = command.Command{ .upload = .{ .bytes = 64, .align_bytes = 4 } };
    try std.testing.expectEqual(command.CommandKind.upload, command.command_kind(cmd));
}

test "command_kind extracts dispatch tag" {
    const cmd = command.Command{ .dispatch = .{ .x = 1, .y = 2, .z = 3 } };
    try std.testing.expectEqual(command.CommandKind.dispatch, command.command_kind(cmd));
}

test "command_kind extracts render_draw tag" {
    const cmd = command.Command{ .render_draw = .{ .draw_count = 1 } };
    try std.testing.expectEqual(command.CommandKind.render_draw, command.command_kind(cmd));
}

test "command_kind extracts sampler_create tag" {
    const cmd = command.Command{ .sampler_create = .{ .handle = 42 } };
    try std.testing.expectEqual(command.CommandKind.sampler_create, command.command_kind(cmd));
}

test "command_kind extracts map_async tag" {
    const cmd = command.Command{ .map_async = .{ .bytes = 256 } };
    try std.testing.expectEqual(command.CommandKind.map_async, command.command_kind(cmd));
}

// ============================================================
// command_kind_name — string representation
// ============================================================

test "command_kind_name returns correct strings for all variants" {
    const expected = [_]struct { kind: command.CommandKind, name: []const u8 }{
        .{ .kind = .upload, .name = "upload" },
        .{ .kind = .copy_buffer_to_texture, .name = "copy_buffer_to_texture" },
        .{ .kind = .barrier, .name = "barrier" },
        .{ .kind = .dispatch, .name = "dispatch" },
        .{ .kind = .dispatch_indirect, .name = "dispatch_indirect" },
        .{ .kind = .kernel_dispatch, .name = "kernel_dispatch" },
        .{ .kind = .render_draw, .name = "render_draw" },
        .{ .kind = .draw_indirect, .name = "draw_indirect" },
        .{ .kind = .draw_indexed_indirect, .name = "draw_indexed_indirect" },
        .{ .kind = .render_pass, .name = "render_pass" },
        .{ .kind = .sampler_create, .name = "sampler_create" },
        .{ .kind = .sampler_destroy, .name = "sampler_destroy" },
        .{ .kind = .texture_write, .name = "texture_write" },
        .{ .kind = .texture_query, .name = "texture_query" },
        .{ .kind = .texture_destroy, .name = "texture_destroy" },
        .{ .kind = .surface_create, .name = "surface_create" },
        .{ .kind = .surface_capabilities, .name = "surface_capabilities" },
        .{ .kind = .surface_configure, .name = "surface_configure" },
        .{ .kind = .surface_acquire, .name = "surface_acquire" },
        .{ .kind = .surface_present, .name = "surface_present" },
        .{ .kind = .surface_unconfigure, .name = "surface_unconfigure" },
        .{ .kind = .surface_release, .name = "surface_release" },
        .{ .kind = .async_diagnostics, .name = "async_diagnostics" },
        .{ .kind = .map_async, .name = "map_async" },
    };
    for (expected) |entry| {
        try std.testing.expectEqualStrings(entry.name, command.command_kind_name(entry.kind));
    }
}

// ============================================================
// is_core_command_kind / is_full_command_kind — scope correctness
// ============================================================

test "core commands are classified as core and not full" {
    const core_kinds = [_]command.CommandKind{
        .upload,
        .copy_buffer_to_texture,
        .barrier,
        .dispatch,
        .dispatch_indirect,
        .kernel_dispatch,
        .texture_write,
        .texture_query,
        .texture_destroy,
        .map_async,
    };
    for (core_kinds) |kind| {
        try std.testing.expect(command.is_core_command_kind(kind));
        try std.testing.expect(!command.is_full_command_kind(kind));
    }
}

test "full commands are classified as full and not core" {
    const full_kinds = [_]command.CommandKind{
        .render_draw,
        .draw_indirect,
        .draw_indexed_indirect,
        .render_pass,
        .sampler_create,
        .sampler_destroy,
        .surface_create,
        .surface_capabilities,
        .surface_configure,
        .surface_acquire,
        .surface_present,
        .surface_unconfigure,
        .surface_release,
        .async_diagnostics,
    };
    for (full_kinds) |kind| {
        try std.testing.expect(command.is_full_command_kind(kind));
        try std.testing.expect(!command.is_core_command_kind(kind));
    }
}

test "every CommandKind is either core or full" {
    const all_fields = @typeInfo(command.CommandKind).@"enum".fields;
    inline for (all_fields) |field| {
        const kind: command.CommandKind = @enumFromInt(field.value);
        const is_core = command.is_core_command_kind(kind);
        const is_full = command.is_full_command_kind(kind);
        // Exactly one must be true
        try std.testing.expect(is_core != is_full);
    }
}

// ============================================================
// Command scope — no duplicate projected unions
// ============================================================

test "command scope preserves the canonical payload" {
    const upload = command.Command{ .upload = .{ .bytes = 512, .align_bytes = 16 } };
    try std.testing.expect(command.is_core_command_kind(command.command_kind(upload)));
    try std.testing.expectEqual(@as(usize, 512), upload.upload.bytes);
    try std.testing.expectEqual(@as(u32, 16), upload.upload.align_bytes);

    const render = command.Command{ .render_draw = .{ .draw_count = 10 } };
    try std.testing.expect(command.is_full_command_kind(command.command_kind(render)));
    try std.testing.expectEqual(@as(u32, 10), render.render_draw.draw_count);
}

// ============================================================
// Struct default values — UploadCommand
// ============================================================

test "UploadCommand has no defaults — both fields required" {
    const fields = @typeInfo(resource.UploadCommand).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    // Verify field names
    try std.testing.expectEqualStrings("bytes", fields[0].name);
    try std.testing.expectEqualStrings("align_bytes", fields[1].name);
}

// ============================================================
// Struct default values — DispatchCommand
// ============================================================

test "DispatchCommand has 3 required fields" {
    const fields = @typeInfo(compute.DispatchCommand).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 3), fields.len);
    try std.testing.expectEqualStrings("x", fields[0].name);
    try std.testing.expectEqualStrings("y", fields[1].name);
    try std.testing.expectEqualStrings("z", fields[2].name);
}

// ============================================================
// Struct default values — RenderDrawCommand
// ============================================================

test "RenderDrawCommand default draw_count is required, vertex_count defaults to 3" {
    const cmd = render_types.RenderDrawCommand{ .draw_count = 1 };
    try std.testing.expectEqual(@as(u32, 1), cmd.draw_count);
    try std.testing.expectEqual(@as(u32, 3), cmd.vertex_count);
    try std.testing.expectEqual(@as(u32, 1), cmd.instance_count);
    try std.testing.expectEqual(@as(u32, 0), cmd.first_vertex);
    try std.testing.expectEqual(@as(u32, 0), cmd.first_instance);
}

test "RenderDrawCommand default target matches render target constants" {
    const cmd = render_types.RenderDrawCommand{ .draw_count = 1 };
    try std.testing.expectEqual(render_types.DEFAULT_RENDER_TARGET_HANDLE, cmd.target_handle);
    try std.testing.expectEqual(render_types.DEFAULT_RENDER_TARGET_WIDTH, cmd.target_width);
    try std.testing.expectEqual(render_types.DEFAULT_RENDER_TARGET_HEIGHT, cmd.target_height);
    try std.testing.expectEqual(render_types.DEFAULT_RENDER_TARGET_FORMAT, cmd.target_format);
}

test "RenderDrawCommand default pipeline/bind/encode modes" {
    const cmd = render_types.RenderDrawCommand{ .draw_count = 1 };
    try std.testing.expectEqual(render_types.RenderDrawPipelineMode.static, cmd.pipeline_mode);
    try std.testing.expectEqual(render_types.RenderDrawBindGroupMode.no_change, cmd.bind_group_mode);
    try std.testing.expectEqual(render_types.RenderDrawEncodeMode.render_bundle, cmd.encode_mode);
}

test "RenderDrawCommand default viewport depth range is 0 to 1" {
    const cmd = render_types.RenderDrawCommand{ .draw_count = 1 };
    try std.testing.expectEqual(@as(f32, 0), cmd.viewport_min_depth);
    try std.testing.expectEqual(@as(f32, 1), cmd.viewport_max_depth);
}

test "RenderDrawCommand default optional fields are null" {
    const cmd = render_types.RenderDrawCommand{ .draw_count = 1 };
    try std.testing.expect(cmd.index_count == null);
    try std.testing.expect(cmd.index_data == null);
    try std.testing.expect(cmd.viewport_width == null);
    try std.testing.expect(cmd.viewport_height == null);
    try std.testing.expect(cmd.scissor_width == null);
    try std.testing.expect(cmd.scissor_height == null);
    try std.testing.expect(cmd.vertex_layouts == null);
    try std.testing.expect(cmd.vertex_bindings == null);
    try std.testing.expect(cmd.index_binding == null);
    try std.testing.expect(cmd.occlusion_query_index == null);
    try std.testing.expect(cmd.bind_group_dynamic_offsets == null);
    try std.testing.expect(cmd.vertex_spirv == null);
    try std.testing.expect(cmd.fragment_spirv == null);
    try std.testing.expect(cmd.vertex_entry_point == null);
    try std.testing.expect(cmd.fragment_entry_point == null);
}

test "RenderDrawCommand default blend is disabled" {
    const cmd = render_types.RenderDrawCommand{ .draw_count = 1 };
    try std.testing.expect(!cmd.blend_enabled);
    try std.testing.expectEqual(@as(u32, 0xF), cmd.color_write_mask);
    try std.testing.expectEqual(@as(u32, 1), cmd.sample_count);
}

test "RenderDrawCommand default clear_color alpha is 1" {
    const cmd = render_types.RenderDrawCommand{ .draw_count = 1 };
    try std.testing.expectEqual(@as(f32, 0), cmd.clear_color[0]);
    try std.testing.expectEqual(@as(f32, 0), cmd.clear_color[1]);
    try std.testing.expectEqual(@as(f32, 0), cmd.clear_color[2]);
    try std.testing.expectEqual(@as(f32, 1), cmd.clear_color[3]);
}

test "RenderDrawCommand default depth-stencil state" {
    const cmd = render_types.RenderDrawCommand{ .draw_count = 1 };
    try std.testing.expectEqual(gpu.WGPUTextureFormat_Undefined, cmd.depth_stencil_format);
    try std.testing.expect(!cmd.depth_write_enabled);
    try std.testing.expect(!cmd.unclipped_depth);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), cmd.stencil_read_mask);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), cmd.stencil_write_mask);
}

// ============================================================
// Struct default values — SamplerCreateCommand
// ============================================================

test "SamplerCreateCommand defaults" {
    const cmd = render_types.SamplerCreateCommand{ .handle = 1 };
    try std.testing.expectEqual(@as(u64, 1), cmd.handle);
    try std.testing.expectEqual(@as(u32, 2), cmd.address_mode_u);
    try std.testing.expectEqual(@as(u32, 2), cmd.address_mode_v);
    try std.testing.expectEqual(@as(u32, 2), cmd.address_mode_w);
    try std.testing.expectEqual(@as(u32, 1), cmd.mag_filter);
    try std.testing.expectEqual(@as(u32, 1), cmd.min_filter);
    try std.testing.expectEqual(@as(u32, 1), cmd.mipmap_filter);
    try std.testing.expectEqual(@as(f32, 0), cmd.lod_min_clamp);
    try std.testing.expectEqual(@as(f32, 32), cmd.lod_max_clamp);
    try std.testing.expectEqual(@as(u32, 0), cmd.compare);
    try std.testing.expectEqual(@as(u16, 1), cmd.max_anisotropy);
}

// ============================================================
// Struct default values — SurfaceConfigureCommand
// ============================================================

test "SurfaceConfigureCommand defaults" {
    const cmd = surface.SurfaceConfigureCommand{ .handle = 1, .width = 640, .height = 480 };
    try std.testing.expectEqual(gpu.WGPUTextureFormat_RGBA8Unorm, cmd.format);
    try std.testing.expectEqual(gpu.WGPUTextureUsage_RenderAttachment, cmd.usage);
    try std.testing.expectEqual(@as(u32, 0x00000001), cmd.alpha_mode);
    try std.testing.expectEqual(@as(u32, 0x00000002), cmd.present_mode);
    try std.testing.expectEqual(surface.WGPUCanvasToneMappingMode_Standard, cmd.tone_mapping_mode);
    try std.testing.expectEqual(@as(u32, 2), cmd.desired_maximum_frame_latency);
}

// ============================================================
// Struct default values — AsyncDiagnosticsCommand
// ============================================================

test "AsyncDiagnosticsCommand defaults" {
    const cmd = async_types.AsyncDiagnosticsCommand{};
    try std.testing.expectEqual(gpu.WGPUTextureFormat_RGBA8Unorm, cmd.target_format);
    try std.testing.expectEqual(async_types.AsyncDiagnosticsMode.pipeline_async, cmd.mode);
    try std.testing.expectEqual(@as(u32, 1), cmd.iterations);
    try std.testing.expectEqual(async_types.AsyncDiagnosticsFeaturePolicy.strict, cmd.feature_policy);
}

// ============================================================
// Struct default values — MapAsyncCommand
// ============================================================

test "MapAsyncCommand default mode is write" {
    const cmd = async_types.MapAsyncCommand{ .bytes = 64 };
    try std.testing.expectEqual(async_types.MapAsyncMode.write, cmd.mode);
}

// ============================================================
// Struct default values — KernelDispatchCommand
// ============================================================

test "KernelDispatchCommand defaults" {
    const cmd = compute.KernelDispatchCommand{ .kernel = "test.wgsl", .x = 1, .y = 1, .z = 1 };
    try std.testing.expect(cmd.entry_point == null);
    try std.testing.expectEqual(@as(u32, 1), cmd.repeat);
    try std.testing.expectEqual(compute.KernelDispatchRepeatSynchronization.dependent, cmd.repeat_synchronization);
    try std.testing.expectEqual(@as(u32, 0), cmd.warmup_dispatch_count);
    try std.testing.expect(!cmd.initialize_buffers_on_create);
    try std.testing.expect(cmd.bindings == null);
}

// ============================================================
// Struct default values — KernelBinding
// ============================================================

test "KernelBinding defaults" {
    const kb = compute.KernelBinding{ .binding = 0, .resource_kind = .buffer, .resource_handle = 1 };
    try std.testing.expectEqual(@as(u32, 0), kb.group);
    try std.testing.expectEqual(gpu.WGPUShaderStage_Compute, kb.visibility);
    try std.testing.expectEqual(@as(u64, 0), kb.buffer_offset);
    try std.testing.expectEqual(gpu.WGPUWholeSize, kb.buffer_size);
    try std.testing.expectEqual(gpu.WGPUBufferBindingType_Undefined, kb.buffer_type);
    try std.testing.expectEqual(gpu.WGPUTextureSampleType_Undefined, kb.texture_sample_type);
    try std.testing.expectEqual(gpu.WGPUTextureViewDimension_Undefined, kb.texture_view_dimension);
    try std.testing.expectEqual(gpu.WGPUStorageTextureAccess_Undefined, kb.storage_texture_access);
    try std.testing.expectEqual(gpu.WGPUTextureAspect_Undefined, kb.texture_aspect);
    try std.testing.expectEqual(gpu.WGPUTextureFormat_Undefined, kb.texture_format);
    try std.testing.expect(!kb.texture_multisampled);
}

// ============================================================
// Struct default values — CopyTextureResource
// ============================================================

test "CopyTextureResource defaults" {
    const r = resource.CopyTextureResource{ .handle = 1 };
    try std.testing.expectEqual(resource.CopyResourceKind.buffer, r.kind);
    try std.testing.expectEqual(@as(u32, 1), r.width);
    try std.testing.expectEqual(@as(u32, 1), r.height);
    try std.testing.expectEqual(@as(u32, 1), r.depth_or_array_layers);
    try std.testing.expectEqual(gpu.WGPUTextureFormat_Undefined, r.format);
    try std.testing.expectEqual(@as(gpu.WGPUFlags, 0), r.usage);
    try std.testing.expectEqual(gpu.WGPUTextureDimension_Undefined, r.dimension);
    try std.testing.expectEqual(gpu.WGPUTextureViewDimension_Undefined, r.view_dimension);
    try std.testing.expectEqual(@as(u32, 0), r.mip_level);
    try std.testing.expectEqual(@as(u32, 1), r.sample_count);
    try std.testing.expectEqual(gpu.WGPUTextureAspect_Undefined, r.aspect);
    try std.testing.expectEqual(@as(u32, 0), r.bytes_per_row);
    try std.testing.expectEqual(@as(u32, 0), r.rows_per_image);
    try std.testing.expectEqual(@as(u64, 0), r.offset);
}

// ============================================================
// Struct default values — CopyCommand
// ============================================================

test "CopyCommand defaults for temporary buffer" {
    const src = resource.CopyTextureResource{ .handle = 1 };
    const dst = resource.CopyTextureResource{ .handle = 2 };
    const cmd = resource.CopyCommand{ .direction = .buffer_to_texture, .src = src, .dst = dst, .bytes = 256 };
    try std.testing.expect(!cmd.uses_temporary_buffer);
    try std.testing.expectEqual(@as(u32, 0), cmd.temporary_buffer_alignment);
}

// ============================================================
// Struct default values — Quirk
// ============================================================

test "Quirk default priority is 0" {
    const q = quirks.Quirk{
        .schema_version = 2,
        .quirk_id = "test-quirk",
        .scope = .alignment,
        .match_spec = .{ .vendor = "test", .api = .vulkan },
        .action = .no_op,
        .safety_class = .low,
        .verification_mode = .guard_only,
        .proof_level = .guarded,
        .provenance = .{ .source_repo = "r", .source_path = "p", .source_commit = "c", .observed_at = "d" },
    };
    try std.testing.expectEqual(@as(u32, 0), q.priority);
}

// ============================================================
// Struct default values — MatchSpec
// ============================================================

test "MatchSpec optional fields default to null" {
    const ms = quirks.MatchSpec{ .vendor = "nvidia", .api = .vulkan };
    try std.testing.expect(ms.device_family == null);
    try std.testing.expect(ms.driver_range == null);
}

// ============================================================
// Struct default values — DeviceProfile
// ============================================================

test "DeviceProfile optional device_family defaults to null" {
    const dp = profile.DeviceProfile{
        .vendor = "intel",
        .api = .d3d12,
        .driver_version = .{ .major = 1, .minor = 0, .patch = 0 },
    };
    try std.testing.expect(dp.device_family == null);
}

// ============================================================
// WGPUFlags constant stability — texture usage (FFI ABI)
// ============================================================

test "WGPUTextureUsage flag values are ABI-stable" {
    try std.testing.expectEqual(@as(gpu.WGPUFlags, 0), gpu.WGPUTextureUsage_None);
    try std.testing.expectEqual(@as(gpu.WGPUFlags, 0x01), gpu.WGPUTextureUsage_CopySrc);
    try std.testing.expectEqual(@as(gpu.WGPUFlags, 0x02), gpu.WGPUTextureUsage_CopyDst);
    try std.testing.expectEqual(@as(gpu.WGPUFlags, 0x04), gpu.WGPUTextureUsage_TextureBinding);
    try std.testing.expectEqual(@as(gpu.WGPUFlags, 0x08), gpu.WGPUTextureUsage_StorageBinding);
    try std.testing.expectEqual(@as(gpu.WGPUFlags, 0x10), gpu.WGPUTextureUsage_RenderAttachment);
}

test "texture usage flags are distinct powers of two" {
    const flags = [_]gpu.WGPUFlags{
        gpu.WGPUTextureUsage_CopySrc,
        gpu.WGPUTextureUsage_CopyDst,
        gpu.WGPUTextureUsage_TextureBinding,
        gpu.WGPUTextureUsage_StorageBinding,
        gpu.WGPUTextureUsage_RenderAttachment,
    };
    for (flags, 0..) |a, i| {
        try std.testing.expect(a != 0);
        try std.testing.expect(a & (a - 1) == 0);
        for (flags[i + 1 ..]) |b| {
            try std.testing.expect(a != b);
            try std.testing.expect(a & b == 0);
        }
    }
}

// ============================================================
// WGPUFlags constant stability — shader stages (FFI ABI)
// ============================================================

test "WGPUShaderStage flag values are ABI-stable" {
    try std.testing.expectEqual(@as(gpu.WGPUFlags, 0x00), gpu.WGPUShaderStage_None);
    try std.testing.expectEqual(@as(gpu.WGPUFlags, 0x01), gpu.WGPUShaderStage_Vertex);
    try std.testing.expectEqual(@as(gpu.WGPUFlags, 0x02), gpu.WGPUShaderStage_Fragment);
    try std.testing.expectEqual(@as(gpu.WGPUFlags, 0x04), gpu.WGPUShaderStage_Compute);
}

// ============================================================
// Sentinel constants (FFI ABI)
// ============================================================

test "WGPUCopyStrideUndefined is 0xFFFFFFFF" {
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), gpu.WGPUCopyStrideUndefined);
}

test "WGPUWholeSize is 0xFFFFFFFFFFFFFFFF" {
    try std.testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), gpu.WGPUWholeSize);
}

// ============================================================
// Render target defaults (FFI ABI)
// ============================================================

test "DEFAULT_RENDER_TARGET_HANDLE is 0xFFFFFFFFFFFFFFFE" {
    try std.testing.expectEqual(@as(u64, 0xFFFF_FFFF_FFFF_FFFE), render_types.DEFAULT_RENDER_TARGET_HANDLE);
}

test "DEFAULT_RENDER_TARGET_WIDTH is 64" {
    try std.testing.expectEqual(@as(u32, 64), render_types.DEFAULT_RENDER_TARGET_WIDTH);
}

test "DEFAULT_RENDER_TARGET_HEIGHT is 64" {
    try std.testing.expectEqual(@as(u32, 64), render_types.DEFAULT_RENDER_TARGET_HEIGHT);
}

test "DEFAULT_RENDER_TARGET_FORMAT is RGBA8Unorm" {
    try std.testing.expectEqual(gpu.WGPUTextureFormat_RGBA8Unorm, render_types.DEFAULT_RENDER_TARGET_FORMAT);
}

// ============================================================
// Vertex/bind limits (FFI ABI)
// ============================================================

test "MAX_VERTEX_BUFFERS is 8" {
    try std.testing.expectEqual(@as(usize, 8), render_types.MAX_VERTEX_BUFFERS);
}

test "MAX_VERTEX_ATTRIBUTES is 16" {
    try std.testing.expectEqual(@as(usize, 16), render_types.MAX_VERTEX_ATTRIBUTES);
}

test "MAX_RENDER_BIND_ENTRIES is 16" {
    try std.testing.expectEqual(@as(usize, 16), render_types.MAX_RENDER_BIND_ENTRIES);
}

// ============================================================
// Vertex step mode constants (FFI ABI)
// ============================================================

test "WGPUVertexStepMode constants are ABI-stable" {
    try std.testing.expectEqual(@as(u32, 0x00000001), render_types.WGPUVertexStepMode_Vertex);
    try std.testing.expectEqual(@as(u32, 0x00000002), render_types.WGPUVertexStepMode_Instance);
}

// ============================================================
// Texture dimension constants (FFI ABI)
// ============================================================

test "WGPUTextureDimension constants are sequential from 0" {
    try std.testing.expectEqual(@as(u32, 0), gpu.WGPUTextureDimension_Undefined);
    try std.testing.expectEqual(@as(u32, 1), gpu.WGPUTextureDimension_1D);
    try std.testing.expectEqual(@as(u32, 2), gpu.WGPUTextureDimension_2D);
    try std.testing.expectEqual(@as(u32, 3), gpu.WGPUTextureDimension_3D);
}

// ============================================================
// Texture view dimension constants (FFI ABI)
// ============================================================

test "WGPUTextureViewDimension constants are sequential from 0" {
    try std.testing.expectEqual(@as(u32, 0), gpu.WGPUTextureViewDimension_Undefined);
    try std.testing.expectEqual(@as(u32, 1), gpu.WGPUTextureViewDimension_1D);
    try std.testing.expectEqual(@as(u32, 2), gpu.WGPUTextureViewDimension_2D);
    try std.testing.expectEqual(@as(u32, 3), gpu.WGPUTextureViewDimension_2DArray);
    try std.testing.expectEqual(@as(u32, 4), gpu.WGPUTextureViewDimension_Cube);
    try std.testing.expectEqual(@as(u32, 5), gpu.WGPUTextureViewDimension_CubeArray);
    try std.testing.expectEqual(@as(u32, 6), gpu.WGPUTextureViewDimension_3D);
}

// ============================================================
// Texture aspect constants (FFI ABI)
// ============================================================

test "WGPUTextureAspect constants are sequential from 0" {
    try std.testing.expectEqual(@as(u32, 0), gpu.WGPUTextureAspect_Undefined);
    try std.testing.expectEqual(@as(u32, 1), gpu.WGPUTextureAspect_All);
    try std.testing.expectEqual(@as(u32, 2), gpu.WGPUTextureAspect_StencilOnly);
    try std.testing.expectEqual(@as(u32, 3), gpu.WGPUTextureAspect_DepthOnly);
}

// ============================================================
// Buffer binding type constants (FFI ABI)
// ============================================================

test "WGPUBufferBindingType constants are sequential from 1" {
    try std.testing.expectEqual(@as(u32, 1), gpu.WGPUBufferBindingType_Undefined);
    try std.testing.expectEqual(@as(u32, 2), gpu.WGPUBufferBindingType_Uniform);
    try std.testing.expectEqual(@as(u32, 3), gpu.WGPUBufferBindingType_Storage);
    try std.testing.expectEqual(@as(u32, 4), gpu.WGPUBufferBindingType_ReadOnlyStorage);
}

// ============================================================
// Texture sample type constants (FFI ABI)
// ============================================================

test "WGPUTextureSampleType constants are sequential from 1" {
    try std.testing.expectEqual(@as(u32, 1), gpu.WGPUTextureSampleType_Undefined);
    try std.testing.expectEqual(@as(u32, 2), gpu.WGPUTextureSampleType_Float);
    try std.testing.expectEqual(@as(u32, 3), gpu.WGPUTextureSampleType_UnfilterableFloat);
    try std.testing.expectEqual(@as(u32, 4), gpu.WGPUTextureSampleType_Depth);
    try std.testing.expectEqual(@as(u32, 5), gpu.WGPUTextureSampleType_Sint);
    try std.testing.expectEqual(@as(u32, 6), gpu.WGPUTextureSampleType_Uint);
}

// ============================================================
// Storage texture access constants (FFI ABI)
// ============================================================

test "WGPUStorageTextureAccess constants are sequential from 1" {
    try std.testing.expectEqual(@as(u32, 1), gpu.WGPUStorageTextureAccess_Undefined);
    try std.testing.expectEqual(@as(u32, 2), gpu.WGPUStorageTextureAccess_WriteOnly);
    try std.testing.expectEqual(@as(u32, 3), gpu.WGPUStorageTextureAccess_ReadOnly);
    try std.testing.expectEqual(@as(u32, 4), gpu.WGPUStorageTextureAccess_ReadWrite);
}

// ============================================================
// Canvas tone mapping constants (FFI ABI)
// ============================================================

test "WGPUCanvasToneMappingMode constants are ABI-stable" {
    try std.testing.expectEqual(@as(u32, 0x00000001), surface.WGPUCanvasToneMappingMode_Standard);
    try std.testing.expectEqual(@as(u32, 0x00000002), surface.WGPUCanvasToneMappingMode_Extended);
}

// ============================================================
// Texture format constants — spot checks for ABI stability
// ============================================================

test "WGPUTextureFormat_Undefined is 0" {
    try std.testing.expectEqual(@as(gpu.WGPUTextureFormat, 0), gpu.WGPUTextureFormat_Undefined);
}

test "WGPUTextureFormat_R8Unorm is 1" {
    try std.testing.expectEqual(@as(gpu.WGPUTextureFormat, 1), gpu.WGPUTextureFormat_R8Unorm);
}

test "WGPUTextureFormat_RGBA8Unorm is 0x16" {
    try std.testing.expectEqual(@as(gpu.WGPUTextureFormat, 0x16), gpu.WGPUTextureFormat_RGBA8Unorm);
}

test "WGPUTextureFormat_BGRA8Unorm is 0x1B" {
    try std.testing.expectEqual(@as(gpu.WGPUTextureFormat, 0x1B), gpu.WGPUTextureFormat_BGRA8Unorm);
}

test "WGPUTextureFormat_Depth32Float is 0x30" {
    try std.testing.expectEqual(@as(gpu.WGPUTextureFormat, 0x30), gpu.WGPUTextureFormat_Depth32Float);
}

test "WGPUTextureFormat_Depth32FloatStencil8 is 0x31" {
    try std.testing.expectEqual(@as(gpu.WGPUTextureFormat, 0x31), gpu.WGPUTextureFormat_Depth32FloatStencil8);
}

test "WGPUTextureFormat_BC1RGBAUnorm starts compressed block at 0x32" {
    try std.testing.expectEqual(@as(gpu.WGPUTextureFormat, 0x32), gpu.WGPUTextureFormat_BC1RGBAUnorm);
}

test "WGPUTextureFormat_ASTC12x12UnormSrgb is 0x65" {
    try std.testing.expectEqual(@as(gpu.WGPUTextureFormat, 0x65), gpu.WGPUTextureFormat_ASTC12x12UnormSrgb);
}

// ============================================================
// QuirkAction union — variant exhaustiveness
// ============================================================

test "QuirkAction has exactly 4 variants" {
    const fields = @typeInfo(quirks.QuirkAction).@"union".fields;
    try std.testing.expectEqual(@as(usize, 4), fields.len);
}

test "QuirkAction no_op can be constructed" {
    const action: quirks.QuirkAction = .no_op;
    try std.testing.expectEqual(
        @as(usize, @intFromEnum(std.meta.activeTag(action))),
        @as(usize, @intFromEnum(@as(std.meta.Tag(quirks.QuirkAction), .no_op))),
    );
}

test "QuirkAction use_temporary_buffer carries alignment_bytes" {
    const action = quirks.QuirkAction{ .use_temporary_buffer = .{ .alignment_bytes = 256 } };
    try std.testing.expectEqual(@as(u32, 256), action.use_temporary_buffer.alignment_bytes);
}

test "QuirkAction use_temporary_render_texture carries min_mip_level" {
    const action = quirks.QuirkAction{ .use_temporary_render_texture = .{ .min_mip_level = 3 } };
    try std.testing.expectEqual(@as(u32, 3), action.use_temporary_render_texture.min_mip_level);
}

test "QuirkAction toggle carries toggle_name" {
    const action = quirks.QuirkAction{ .toggle = .{ .toggle_name = "some_toggle" } };
    try std.testing.expectEqualStrings("some_toggle", action.toggle.toggle_name);
}

// ============================================================
// CopyResourceKind enum
// ============================================================

test "CopyResourceKind has exactly 2 variants" {
    const fields = @typeInfo(resource.CopyResourceKind).@"enum".fields;
    try std.testing.expectEqual(@as(usize, 2), fields.len);
}

test "CopyResourceKind ordinals are stable" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(resource.CopyResourceKind.buffer));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(resource.CopyResourceKind.texture));
}

// ============================================================
// CopyDirection enum
// ============================================================

test "CopyDirection has exactly 4 variants" {
    const fields = @typeInfo(resource.CopyDirection).@"enum".fields;
    try std.testing.expectEqual(@as(usize, 4), fields.len);
}

test "CopyDirection ordinals are stable" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(resource.CopyDirection.buffer_to_buffer));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(resource.CopyDirection.buffer_to_texture));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(resource.CopyDirection.texture_to_buffer));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(resource.CopyDirection.texture_to_texture));
}

// ============================================================
// KernelBindingResourceKind enum
// ============================================================

test "KernelBindingResourceKind has exactly 4 variants" {
    const fields = @typeInfo(compute.KernelBindingResourceKind).@"enum".fields;
    try std.testing.expectEqual(@as(usize, 4), fields.len);
}

test "KernelBindingResourceKind ordinals are stable" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(compute.KernelBindingResourceKind.buffer));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(compute.KernelBindingResourceKind.texture));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(compute.KernelBindingResourceKind.storage_texture));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(compute.KernelBindingResourceKind.sampler));
}

// ============================================================
// RenderDrawPipelineMode enum
// ============================================================

test "RenderDrawPipelineMode has exactly 2 variants" {
    const fields = @typeInfo(render_types.RenderDrawPipelineMode).@"enum".fields;
    try std.testing.expectEqual(@as(usize, 2), fields.len);
}

// ============================================================
// RenderDrawBindGroupMode enum
// ============================================================

test "RenderDrawBindGroupMode has exactly 2 variants" {
    const fields = @typeInfo(render_types.RenderDrawBindGroupMode).@"enum".fields;
    try std.testing.expectEqual(@as(usize, 2), fields.len);
}

// ============================================================
// RenderDrawEncodeMode enum
// ============================================================

test "RenderDrawEncodeMode has exactly 2 variants" {
    const fields = @typeInfo(render_types.RenderDrawEncodeMode).@"enum".fields;
    try std.testing.expectEqual(@as(usize, 2), fields.len);
}

// ============================================================
// RenderIndexFormat enum
// ============================================================

test "RenderIndexFormat has exactly 2 variants" {
    const fields = @typeInfo(render_types.RenderIndexFormat).@"enum".fields;
    try std.testing.expectEqual(@as(usize, 2), fields.len);
}

// ============================================================
// AsyncDiagnosticsMode enum
// ============================================================

test "AsyncDiagnosticsMode has exactly 6 variants" {
    const fields = @typeInfo(async_types.AsyncDiagnosticsMode).@"enum".fields;
    try std.testing.expectEqual(@as(usize, 6), fields.len);
}

// ============================================================
// AsyncDiagnosticsFeaturePolicy enum
// ============================================================

test "AsyncDiagnosticsFeaturePolicy has exactly 2 variants" {
    const fields = @typeInfo(async_types.AsyncDiagnosticsFeaturePolicy).@"enum".fields;
    try std.testing.expectEqual(@as(usize, 2), fields.len);
}

// ============================================================
// MapAsyncMode enum
// ============================================================

test "MapAsyncMode has exactly 2 variants" {
    const fields = @typeInfo(async_types.MapAsyncMode).@"enum".fields;
    try std.testing.expectEqual(@as(usize, 2), fields.len);
}

// ============================================================
// Type alias stability — WGPUFlags, WGPUSType, WGPUTextureFormat
// ============================================================

test "WGPUFlags is u64" {
    try std.testing.expect(gpu.WGPUFlags == u64);
}

test "WGPUSType is u32" {
    try std.testing.expect(gpu.WGPUSType == u32);
}

test "WGPUTextureFormat is u32" {
    try std.testing.expect(gpu.WGPUTextureFormat == u32);
}

// ============================================================
// DrawIndirectCommand and DrawIndexedIndirectCommand are type
// aliases for RenderDrawCommand (structural equivalence)
// ============================================================

test "DrawIndirectCommand is same type as RenderDrawCommand" {
    try std.testing.expect(render_types.DrawIndirectCommand == render_types.RenderDrawCommand);
}

test "DrawIndexedIndirectCommand is same type as RenderDrawCommand" {
    try std.testing.expect(render_types.DrawIndexedIndirectCommand == render_types.RenderDrawCommand);
}

test "RenderPassCommand is same type as RenderDrawCommand" {
    try std.testing.expect(render_types.RenderPassCommand == render_types.RenderDrawCommand);
}

test "DispatchIndirectCommand is same type as DispatchCommand" {
    try std.testing.expect(compute.DispatchIndirectCommand == compute.DispatchCommand);
}

// ============================================================
// Canonical command scope metadata
// ============================================================

test "command scope metadata partitions representative kinds" {
    try std.testing.expect(command.is_core_command_kind(.upload));
    try std.testing.expect(command.is_core_command_kind(.dispatch));
    try std.testing.expect(command.is_core_command_kind(.map_async));
    try std.testing.expect(!command.is_full_command_kind(.upload));

    try std.testing.expect(command.is_full_command_kind(.render_draw));
    try std.testing.expect(command.is_full_command_kind(.surface_present));
    try std.testing.expect(command.is_full_command_kind(.async_diagnostics));
    try std.testing.expect(!command.is_core_command_kind(.render_draw));
}
