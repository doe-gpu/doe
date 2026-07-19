const std = @import("std");
const model_commands = @import("../contracts/model/model_commands.zig");
const model_policy = @import("../contracts/model/model_policy.zig");
const model_profile = @import("../contracts/model/model_profile.zig");
const model_quirks = @import("../contracts/model/model_quirks.zig");
const toggle_registry = @import("toggle_registry.zig");
const quirk_actions = @import("quirk_actions.zig");
const lean_proof = @import("../verification/lean_proof.zig");

const model = struct {
    pub const Command = model_commands.Command;
    pub const CommandKind = model_commands.CommandKind;
    pub const DeviceProfile = model_profile.DeviceProfile;
    pub const ProofLevel = model_policy.ProofLevel;
    pub const Quirk = model_quirks.Quirk;
    pub const QuirkAction = model_quirks.QuirkAction;
    pub const SafetyClass = model_policy.SafetyClass;
    pub const Scope = model_policy.Scope;
    pub const SemVer = model_profile.SemVer;
    pub const VerificationMode = model_policy.VerificationMode;
    pub const command_kind = model_commands.command_kind;
    pub const requiresProof = model_policy.requiresProof;
};

pub const DispatchDecision = struct {
    matched_quirk_id: ?[]const u8,
    action: ?model.QuirkAction,
    score: u32,
    matched_count: u32,
    requires_lean: bool,
    is_blocking: bool,
    proof_level: ?model.ProofLevel,
    verification_mode: ?model.VerificationMode,
    applied_toggle: ?[]const u8,
    matched_scope: ?model.Scope,
    matched_safety_class: ?model.SafetyClass,
};

const ScoredQuirk = struct {
    quirk: model.Quirk,
    score: u32,
};

pub const CommandDispatchBucket = struct {
    best: ?model.Quirk = null,
    best_score: u32 = 0,
    matched_count: u32 = 0,
    requires_lean: bool = false,
    is_blocking: bool = false,
    action_is_identity: bool = true,
};

pub const DispatchContext = struct {
    allocator: std.mem.Allocator,
    upload: CommandDispatchBucket,
    copy_buffer_to_texture: CommandDispatchBucket,
    barrier: CommandDispatchBucket,
    dispatch: CommandDispatchBucket,
    kernel_dispatch: CommandDispatchBucket,
    render_draw: CommandDispatchBucket,
    sampler_create: CommandDispatchBucket,
    sampler_destroy: CommandDispatchBucket,
    texture_write: CommandDispatchBucket,
    texture_query: CommandDispatchBucket,
    texture_destroy: CommandDispatchBucket,
    surface_create: CommandDispatchBucket,
    surface_capabilities: CommandDispatchBucket,
    surface_configure: CommandDispatchBucket,
    surface_acquire: CommandDispatchBucket,
    surface_present: CommandDispatchBucket,
    surface_unconfigure: CommandDispatchBucket,
    surface_release: CommandDispatchBucket,
    async_diagnostics: CommandDispatchBucket,
    map_async: CommandDispatchBucket,

    pub fn deinit(self: DispatchContext) void {
        _ = self;
    }
};

pub fn emptyDecision(context: DispatchContext, command: model.Command) DispatchDecision {
    const kind = model.command_kind(command);
    const bucket = bucketForKind(context, kind);
    return .{
        .matched_quirk_id = null,
        .action = null,
        .score = 0,
        .matched_count = bucket.matched_count,
        .requires_lean = false,
        .is_blocking = false,
        .proof_level = null,
        .verification_mode = null,
        .applied_toggle = null,
        .matched_scope = null,
        .matched_safety_class = null,
    };
}

pub fn buildDispatchContext(allocator: std.mem.Allocator, quirks: []const model.Quirk) !DispatchContext {
    if (quirks.len == 0) {
        return emptyContext(allocator);
    }

    const scoring_profile = model.DeviceProfile{
        .vendor = "",
        .api = quirks[0].match_spec.api,
        .device_family = null,
        .driver_version = .{ .major = 9999, .minor = 9999, .patch = 9999 },
    };

    var upload = std.ArrayList(ScoredQuirk).empty;
    var copy_buffer_to_texture = std.ArrayList(ScoredQuirk).empty;
    var barrier = std.ArrayList(ScoredQuirk).empty;
    var dispatch_commands = std.ArrayList(ScoredQuirk).empty;
    var kernel_dispatch = std.ArrayList(ScoredQuirk).empty;
    var render_draw = std.ArrayList(ScoredQuirk).empty;
    var sampler_create = std.ArrayList(ScoredQuirk).empty;
    var sampler_destroy = std.ArrayList(ScoredQuirk).empty;
    var texture_write = std.ArrayList(ScoredQuirk).empty;
    var texture_query = std.ArrayList(ScoredQuirk).empty;
    var texture_destroy = std.ArrayList(ScoredQuirk).empty;
    var surface_create = std.ArrayList(ScoredQuirk).empty;
    var surface_capabilities = std.ArrayList(ScoredQuirk).empty;
    var surface_configure = std.ArrayList(ScoredQuirk).empty;
    var surface_acquire = std.ArrayList(ScoredQuirk).empty;
    var surface_present = std.ArrayList(ScoredQuirk).empty;
    var surface_unconfigure = std.ArrayList(ScoredQuirk).empty;
    var surface_release = std.ArrayList(ScoredQuirk).empty;
    var async_diagnostics = std.ArrayList(ScoredQuirk).empty;
    var map_async = std.ArrayList(ScoredQuirk).empty;

    for (quirks) |quirk| {
        // Comptime table built from supportsCommand (correct by construction).
        // Lean scopeCommandTableComplete is a redundant second check (comptime_verified tier).
        const si = @intFromEnum(quirk.scope);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.upload)])
            try appendScored(allocator, &upload, quirk, .upload, scoring_profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.copy_buffer_to_texture)])
            try appendScored(allocator, &copy_buffer_to_texture, quirk, .copy_buffer_to_texture, scoring_profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.barrier)])
            try appendScored(allocator, &barrier, quirk, .barrier, scoring_profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.dispatch)])
            try appendScored(allocator, &dispatch_commands, quirk, .dispatch, scoring_profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.kernel_dispatch)])
            try appendScored(allocator, &kernel_dispatch, quirk, .kernel_dispatch, scoring_profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.render_draw)])
            try appendScored(allocator, &render_draw, quirk, .render_draw, scoring_profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.sampler_create)])
            try appendScored(allocator, &sampler_create, quirk, .sampler_create, scoring_profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.sampler_destroy)])
            try appendScored(allocator, &sampler_destroy, quirk, .sampler_destroy, scoring_profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.texture_write)])
            try appendScored(allocator, &texture_write, quirk, .texture_write, scoring_profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.texture_query)])
            try appendScored(allocator, &texture_query, quirk, .texture_query, scoring_profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.texture_destroy)])
            try appendScored(allocator, &texture_destroy, quirk, .texture_destroy, scoring_profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.surface_create)])
            try appendScored(allocator, &surface_create, quirk, .surface_create, scoring_profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.surface_capabilities)])
            try appendScored(allocator, &surface_capabilities, quirk, .surface_capabilities, scoring_profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.surface_configure)])
            try appendScored(allocator, &surface_configure, quirk, .surface_configure, scoring_profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.surface_acquire)])
            try appendScored(allocator, &surface_acquire, quirk, .surface_acquire, scoring_profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.surface_present)])
            try appendScored(allocator, &surface_present, quirk, .surface_present, scoring_profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.surface_unconfigure)])
            try appendScored(allocator, &surface_unconfigure, quirk, .surface_unconfigure, scoring_profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.surface_release)])
            try appendScored(allocator, &surface_release, quirk, .surface_release, scoring_profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.async_diagnostics)])
            try appendScored(allocator, &async_diagnostics, quirk, .async_diagnostics, scoring_profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.map_async)])
            try appendScored(allocator, &map_async, quirk, .map_async, scoring_profile);
    }

    return DispatchContext{
        .allocator = allocator,
        .upload = finalizeBucket(allocator, &upload),
        .copy_buffer_to_texture = finalizeBucket(allocator, &copy_buffer_to_texture),
        .barrier = finalizeBucket(allocator, &barrier),
        .dispatch = finalizeBucket(allocator, &dispatch_commands),
        .kernel_dispatch = finalizeBucket(allocator, &kernel_dispatch),
        .render_draw = finalizeBucket(allocator, &render_draw),
        .sampler_create = finalizeBucket(allocator, &sampler_create),
        .sampler_destroy = finalizeBucket(allocator, &sampler_destroy),
        .texture_write = finalizeBucket(allocator, &texture_write),
        .texture_query = finalizeBucket(allocator, &texture_query),
        .texture_destroy = finalizeBucket(allocator, &texture_destroy),
        .surface_create = finalizeBucket(allocator, &surface_create),
        .surface_capabilities = finalizeBucket(allocator, &surface_capabilities),
        .surface_configure = finalizeBucket(allocator, &surface_configure),
        .surface_acquire = finalizeBucket(allocator, &surface_acquire),
        .surface_present = finalizeBucket(allocator, &surface_present),
        .surface_unconfigure = finalizeBucket(allocator, &surface_unconfigure),
        .surface_release = finalizeBucket(allocator, &surface_release),
        .async_diagnostics = finalizeBucket(allocator, &async_diagnostics),
        .map_async = finalizeBucket(allocator, &map_async),
    };
}

pub fn buildProfileDispatchContext(
    allocator: std.mem.Allocator,
    profile: model.DeviceProfile,
    quirks: []const model.Quirk,
) !DispatchContext {
    var upload = std.ArrayList(ScoredQuirk).empty;
    var copy_buffer_to_texture = std.ArrayList(ScoredQuirk).empty;
    var barrier = std.ArrayList(ScoredQuirk).empty;
    var dispatch_commands = std.ArrayList(ScoredQuirk).empty;
    var kernel_dispatch = std.ArrayList(ScoredQuirk).empty;
    var render_draw = std.ArrayList(ScoredQuirk).empty;
    var sampler_create = std.ArrayList(ScoredQuirk).empty;
    var sampler_destroy = std.ArrayList(ScoredQuirk).empty;
    var texture_write = std.ArrayList(ScoredQuirk).empty;
    var texture_query = std.ArrayList(ScoredQuirk).empty;
    var texture_destroy = std.ArrayList(ScoredQuirk).empty;
    var surface_create = std.ArrayList(ScoredQuirk).empty;
    var surface_capabilities = std.ArrayList(ScoredQuirk).empty;
    var surface_configure = std.ArrayList(ScoredQuirk).empty;
    var surface_acquire = std.ArrayList(ScoredQuirk).empty;
    var surface_present = std.ArrayList(ScoredQuirk).empty;
    var surface_unconfigure = std.ArrayList(ScoredQuirk).empty;
    var surface_release = std.ArrayList(ScoredQuirk).empty;
    var async_diagnostics = std.ArrayList(ScoredQuirk).empty;
    var map_async = std.ArrayList(ScoredQuirk).empty;

    for (quirks) |quirk| {
        if (!matchesProfile(profile, quirk)) continue;
        const si = @intFromEnum(quirk.scope);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.upload)])
            try appendScored(allocator, &upload, quirk, .upload, profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.copy_buffer_to_texture)])
            try appendScored(allocator, &copy_buffer_to_texture, quirk, .copy_buffer_to_texture, profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.barrier)])
            try appendScored(allocator, &barrier, quirk, .barrier, profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.dispatch)])
            try appendScored(allocator, &dispatch_commands, quirk, .dispatch, profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.kernel_dispatch)])
            try appendScored(allocator, &kernel_dispatch, quirk, .kernel_dispatch, profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.render_draw)])
            try appendScored(allocator, &render_draw, quirk, .render_draw, profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.sampler_create)])
            try appendScored(allocator, &sampler_create, quirk, .sampler_create, profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.sampler_destroy)])
            try appendScored(allocator, &sampler_destroy, quirk, .sampler_destroy, profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.texture_write)])
            try appendScored(allocator, &texture_write, quirk, .texture_write, profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.texture_query)])
            try appendScored(allocator, &texture_query, quirk, .texture_query, profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.texture_destroy)])
            try appendScored(allocator, &texture_destroy, quirk, .texture_destroy, profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.surface_create)])
            try appendScored(allocator, &surface_create, quirk, .surface_create, profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.surface_capabilities)])
            try appendScored(allocator, &surface_capabilities, quirk, .surface_capabilities, profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.surface_configure)])
            try appendScored(allocator, &surface_configure, quirk, .surface_configure, profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.surface_acquire)])
            try appendScored(allocator, &surface_acquire, quirk, .surface_acquire, profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.surface_present)])
            try appendScored(allocator, &surface_present, quirk, .surface_present, profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.surface_unconfigure)])
            try appendScored(allocator, &surface_unconfigure, quirk, .surface_unconfigure, profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.surface_release)])
            try appendScored(allocator, &surface_release, quirk, .surface_release, profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.async_diagnostics)])
            try appendScored(allocator, &async_diagnostics, quirk, .async_diagnostics, profile);
        if (SCOPE_COMMAND_TABLE[si][@intFromEnum(model.CommandKind.map_async)])
            try appendScored(allocator, &map_async, quirk, .map_async, profile);
    }

    return DispatchContext{
        .allocator = allocator,
        .upload = finalizeBucket(allocator, &upload),
        .copy_buffer_to_texture = finalizeBucket(allocator, &copy_buffer_to_texture),
        .barrier = finalizeBucket(allocator, &barrier),
        .dispatch = finalizeBucket(allocator, &dispatch_commands),
        .kernel_dispatch = finalizeBucket(allocator, &kernel_dispatch),
        .render_draw = finalizeBucket(allocator, &render_draw),
        .sampler_create = finalizeBucket(allocator, &sampler_create),
        .sampler_destroy = finalizeBucket(allocator, &sampler_destroy),
        .texture_write = finalizeBucket(allocator, &texture_write),
        .texture_query = finalizeBucket(allocator, &texture_query),
        .texture_destroy = finalizeBucket(allocator, &texture_destroy),
        .surface_create = finalizeBucket(allocator, &surface_create),
        .surface_capabilities = finalizeBucket(allocator, &surface_capabilities),
        .surface_configure = finalizeBucket(allocator, &surface_configure),
        .surface_acquire = finalizeBucket(allocator, &surface_acquire),
        .surface_present = finalizeBucket(allocator, &surface_present),
        .surface_unconfigure = finalizeBucket(allocator, &surface_unconfigure),
        .surface_release = finalizeBucket(allocator, &surface_release),
        .async_diagnostics = finalizeBucket(allocator, &async_diagnostics),
        .map_async = finalizeBucket(allocator, &map_async),
    };
}

pub fn dispatch(profile: model.DeviceProfile, context: DispatchContext, command: model.Command) struct {
    command: model.Command,
    decision: DispatchDecision,
} {
    _ = profile;
    const kind = model.command_kind(command);
    const bucket = bucketForKind(context, kind);

    if (bucket.best == null) {
        return .{
            .command = command,
            .decision = .{
                .matched_quirk_id = null,
                .action = null,
                .score = 0,
                .matched_count = bucket.matched_count,
                .requires_lean = false,
                .is_blocking = false,
                .proof_level = null,
                .verification_mode = null,
                .applied_toggle = null,
                .matched_scope = null,
                .matched_safety_class = null,
            },
        };
    }

    const quirk = bucket.best.?;

    // Identity action skip (comptime_verified tier): action_is_identity resolved at init time.
    // Lean identityActionPreservesCommand is a redundant second check.
    const applied_command = if (lean_proof.lean_verified and bucket.action_is_identity)
        command
    else
        applyAction(quirk, command);

    return .{
        .command = applied_command,
        .decision = .{
            .matched_quirk_id = quirk.quirk_id,
            .action = quirk.action,
            .score = bucket.best_score,
            .matched_count = bucket.matched_count,
            .requires_lean = bucket.requires_lean,
            .is_blocking = bucket.is_blocking,
            .proof_level = quirk.proof_level,
            .verification_mode = quirk.verification_mode,
            .applied_toggle = switch (quirk.action) {
                .toggle => |payload| payload.toggle_name,
                else => null,
            },
            .matched_scope = quirk.scope,
            .matched_safety_class = quirk.safety_class,
        },
    };
}

pub fn emptyContext(allocator: std.mem.Allocator) DispatchContext {
    return .{
        .allocator = allocator,
        .upload = .{},
        .copy_buffer_to_texture = .{},
        .barrier = .{},
        .dispatch = .{},
        .kernel_dispatch = .{},
        .render_draw = .{},
        .sampler_create = .{},
        .sampler_destroy = .{},
        .texture_write = .{},
        .texture_query = .{},
        .texture_destroy = .{},
        .surface_create = .{},
        .surface_capabilities = .{},
        .surface_configure = .{},
        .surface_acquire = .{},
        .surface_present = .{},
        .surface_unconfigure = .{},
        .surface_release = .{},
        .async_diagnostics = .{},
        .map_async = .{},
    };
}

fn appendScored(
    allocator: std.mem.Allocator,
    storage: *std.ArrayList(ScoredQuirk),
    quirk: model.Quirk,
    command_kind: model.CommandKind,
    profile: model.DeviceProfile,
) !void {
    try storage.append(allocator, .{
        .quirk = quirk,
        .score = scoreRule(quirk, command_kind, profile),
    });
}

fn finalizeBucket(
    allocator: std.mem.Allocator,
    storage: *std.ArrayList(ScoredQuirk),
) CommandDispatchBucket {
    if (storage.items.len == 0) {
        storage.deinit(allocator);
        return CommandDispatchBucket{};
    }

    std.mem.sort(ScoredQuirk, storage.items, {}, compareScoredQuirk);
    const best = storage.items[0];
    const requires_lean = model.requiresProof(best.quirk.verification_mode);
    const is_blocking = if (lean_proof.lean_verified) blk: {
        // Blocking shortcuts (comptime_verified tier — verifiable by enum exhaustion).
        if (best.quirk.proof_level == .rejected) break :blk true;
        if (best.quirk.safety_class == .critical) break :blk best.quirk.proof_level != .proven;
        break :blk requires_lean and best.quirk.proof_level != .proven;
    } else requires_lean and best.quirk.proof_level != .proven;

    const action_is_identity = switch (best.quirk.action) {
        .no_op => true,
        .toggle => |payload| toggle_registry.effect(payload.toggle_name) != .behavioral,
        .use_temporary_buffer => false,
        .use_temporary_render_texture => false,
    };

    const result = CommandDispatchBucket{
        .best = best.quirk,
        .best_score = best.score,
        .matched_count = @intCast(storage.items.len),
        .requires_lean = requires_lean,
        .is_blocking = is_blocking,
        .action_is_identity = action_is_identity,
    };
    storage.deinit(allocator);
    return result;
}

fn compareScoredQuirk(_: void, a: ScoredQuirk, b: ScoredQuirk) bool {
    if (a.score != b.score) return a.score > b.score;
    if (proofPriority(a.quirk.proof_level) != proofPriority(b.quirk.proof_level)) {
        return proofPriority(a.quirk.proof_level) > proofPriority(b.quirk.proof_level);
    }
    if (a.quirk.priority != b.quirk.priority) return a.quirk.priority > b.quirk.priority;
    return std.mem.lessThan(u8, a.quirk.quirk_id, b.quirk.quirk_id);
}

fn proofPriority(level: model.ProofLevel) u8 {
    return switch (level) {
        .proven => 3,
        .guarded => 2,
        .rejected => 1,
    };
}

fn supportsCommand(scope: model.Scope, command_kind: model.CommandKind) bool {
    return switch (scope) {
        .alignment => command_kind == .upload or command_kind == .copy_buffer_to_texture,
        .layout => command_kind == .dispatch or
            command_kind == .dispatch_indirect or
            command_kind == .kernel_dispatch or
            command_kind == .render_draw or
            command_kind == .draw_indirect or
            command_kind == .draw_indexed_indirect or
            command_kind == .render_pass or
            command_kind == .copy_buffer_to_texture or
            command_kind == .sampler_create or
            command_kind == .sampler_destroy or
            command_kind == .texture_write or
            command_kind == .texture_query or
            command_kind == .texture_destroy or
            command_kind == .surface_create or
            command_kind == .surface_capabilities or
            command_kind == .surface_configure or
            command_kind == .surface_acquire or
            command_kind == .surface_present or
            command_kind == .surface_unconfigure or
            command_kind == .surface_release or
            command_kind == .async_diagnostics,
        .barrier => command_kind == .barrier or
            command_kind == .dispatch or
            command_kind == .dispatch_indirect or
            command_kind == .kernel_dispatch or
            command_kind == .render_draw or
            command_kind == .draw_indirect or
            command_kind == .draw_indexed_indirect or
            command_kind == .render_pass or
            command_kind == .surface_present,
        .driver_toggle => true,
        .memory => command_kind == .buffer_write or command_kind == .copy_buffer_to_texture or command_kind == .upload or command_kind == .texture_write or command_kind == .texture_query or command_kind == .texture_destroy,
    };
}

fn scoreRule(quirk: model.Quirk, command_kind: model.CommandKind, profile: model.DeviceProfile) u32 {
    var score: u32 = quirk.priority;

    if (quirk.match_spec.device_family) |required_family| {
        if (profile.device_family) |actual_family| {
            if (std.mem.eql(u8, required_family, actual_family)) score += 50;
        }
    } else {
        score += 1;
    }

    if (quirk.match_spec.driver_range) |_| score += 10;
    if (quirk.safety_class == .critical) score += 15;
    if (quirk.safety_class == .high) score += 8;
    if (quirk.verification_mode == .lean_required) score += 12;
    if (quirk.scope == .memory and profile.device_family != null and quirk.match_spec.device_family != null) score += 20;

    switch (command_kind) {
        .buffer_write, .upload => {
            if (quirk.scope == .alignment) score += 5;
            if (quirk.scope == .memory) score += 3;
        },
        .copy_buffer_to_texture => {
            if (quirk.scope == .memory) score += 8;
            if (quirk.scope == .alignment) score += 4;
        },
        .dispatch => {
            if (quirk.scope == .layout) score += 4;
            if (quirk.scope == .barrier) score += 6;
        },
        .dispatch_indirect => {
            if (quirk.scope == .layout) score += 4;
            if (quirk.scope == .barrier) score += 6;
        },
        .barrier => {
            if (quirk.scope == .barrier) score += 8;
        },
        .kernel_dispatch => {
            if (quirk.scope == .layout) score += 7;
            if (quirk.scope == .barrier) score += 2;
        },
        .render_draw, .draw_indirect, .draw_indexed_indirect, .render_pass => {
            if (quirk.scope == .layout) score += 6;
            if (quirk.scope == .barrier) score += 3;
        },
        .sampler_create, .sampler_destroy => {
            if (quirk.scope == .layout) score += 3;
        },
        .texture_write, .texture_query, .texture_destroy => {
            if (quirk.scope == .memory) score += 6;
            if (quirk.scope == .layout) score += 2;
        },
        .surface_create, .surface_capabilities, .surface_configure, .surface_acquire, .surface_present, .surface_unconfigure, .surface_release => {
            if (quirk.scope == .memory) score += 5;
        },
        .async_diagnostics => {
            if (quirk.scope == .memory) score += 5;
        },
        .map_async => {
            if (quirk.scope == .memory) score += 6;
        },
    }

    return score;
}

fn matchesProfile(profile: model.DeviceProfile, quirk: model.Quirk) bool {
    if (!eqIgnoreCase(profile.vendor, quirk.match_spec.vendor)) return false;
    if (profile.api != quirk.match_spec.api) return false;

    if (quirk.match_spec.device_family) |required_family| {
        const actual = profile.device_family orelse return false;
        if (!std.mem.eql(u8, required_family, actual)) return false;
    }

    if (quirk.match_spec.driver_range) |range_expr| {
        if (!matchesDriverRange(profile.driver_version, range_expr)) return false;
    }

    return true;
}

fn matchesDriverRange(version: model.SemVer, expr: []const u8) bool {
    var it = std.mem.splitScalar(u8, expr, ',');
    while (it.next()) |raw| {
        const token = std.mem.trim(u8, raw, " ");
        if (token.len == 0) continue;

        if (std.mem.startsWith(u8, token, ">=")) {
            const rhs = parseVersion(token[2..]) orelse return false;
            if (!version.ge(rhs)) return false;
        } else if (std.mem.startsWith(u8, token, "<=")) {
            const rhs = parseVersion(token[2..]) orelse return false;
            if (version.gt(rhs)) return false;
        } else if (std.mem.startsWith(u8, token, ">")) {
            const rhs = parseVersion(token[1..]) orelse return false;
            if (!version.gt(rhs)) return false;
        } else if (std.mem.startsWith(u8, token, "<")) {
            const rhs = parseVersion(token[1..]) orelse return false;
            if (!version.lt(rhs)) return false;
        } else if (std.mem.startsWith(u8, token, "==")) {
            const rhs = parseVersion(token[2..]) orelse return false;
            if (!version.equals(rhs)) return false;
        } else {
            const rhs = parseVersion(token) orelse return false;
            if (!version.equals(rhs)) return false;
        }
    }
    return true;
}

fn parseVersion(text: []const u8) ?model.SemVer {
    return model.SemVer.parse(text) catch null;
}

fn eqIgnoreCase(lhs: []const u8, rhs: []const u8) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, 0..) |lhs_byte, idx| {
        if (std.ascii.toLower(lhs_byte) != std.ascii.toLower(rhs[idx])) return false;
    }
    return true;
}

fn bucketForKind(context: DispatchContext, kind: model.CommandKind) CommandDispatchBucket {
    return switch (kind) {
        .buffer_write => context.upload,
        .upload => context.upload,
        .copy_buffer_to_texture => context.copy_buffer_to_texture,
        .barrier => context.barrier,
        .dispatch => context.dispatch,
        .dispatch_indirect => context.dispatch,
        .kernel_dispatch => context.kernel_dispatch,
        .render_draw => context.render_draw,
        .draw_indirect => context.render_draw,
        .draw_indexed_indirect => context.render_draw,
        .render_pass => context.render_draw,
        .sampler_create => context.sampler_create,
        .sampler_destroy => context.sampler_destroy,
        .texture_write => context.texture_write,
        .texture_query => context.texture_query,
        .texture_destroy => context.texture_destroy,
        .surface_create => context.surface_create,
        .surface_capabilities => context.surface_capabilities,
        .surface_configure => context.surface_configure,
        .surface_acquire => context.surface_acquire,
        .surface_present => context.surface_present,
        .surface_unconfigure => context.surface_unconfigure,
        .surface_release => context.surface_release,
        .async_diagnostics => context.async_diagnostics,
        .map_async => context.map_async,
    };
}

// Comptime scope×command support table (correct by construction — built from supportsCommand).
// Lean scopeCommandTableComplete is a redundant second check (comptime_verified tier).
const SCOPE_COUNT = @typeInfo(model.Scope).@"enum".fields.len;
const COMMAND_KIND_COUNT = @typeInfo(model.CommandKind).@"enum".fields.len;
const SCOPE_COMMAND_TABLE: [SCOPE_COUNT][COMMAND_KIND_COUNT]bool = blk: {
    var table: [SCOPE_COUNT][COMMAND_KIND_COUNT]bool = undefined;
    for (0..SCOPE_COUNT) |si| {
        for (0..COMMAND_KIND_COUNT) |ci| {
            table[si][ci] = supportsCommand(@enumFromInt(si), @enumFromInt(ci));
        }
    }
    break :blk table;
};

pub const applyAction = quirk_actions.applyAction;

test "vendor comparison ignores case" {
    try std.testing.expect(std.ascii.eqlIgnoreCase("Intel", "intel"));
}

test "proof priority ordering prefers proven over guarded" {
    try std.testing.expect(proofPriority(.proven) > proofPriority(.guarded));
}
