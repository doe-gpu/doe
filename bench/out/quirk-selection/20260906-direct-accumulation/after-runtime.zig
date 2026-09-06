const std = @import("std");
const model_commands = @import("../contracts/command.zig");
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

/// Borrows quirk payloads. The allocator field and deinit retain the existing caller contract.
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

pub fn buildDispatchContext(allocator: std.mem.Allocator, quirks: []const model.Quirk) std.mem.Allocator.Error!DispatchContext {
    if (quirks.len == 0) {
        return emptyContext(allocator);
    }

    const scoring_profile = model.DeviceProfile{
        .vendor = "",
        .api = quirks[0].match_spec.api,
        .device_family = null,
        .driver_version = .{ .major = 9999, .minor = 9999, .patch = 9999 },
    };

    var context = emptyContext(allocator);
    for (quirks) |quirk| accumulateQuirk(&context, quirk, scoring_profile);
    finalizeContext(&context);
    return context;
}

pub fn buildProfileDispatchContext(
    allocator: std.mem.Allocator,
    profile: model.DeviceProfile,
    quirks: []const model.Quirk,
) std.mem.Allocator.Error!DispatchContext {
    var context = emptyContext(allocator);
    for (quirks) |quirk| {
        if (matchesProfile(profile, quirk)) accumulateQuirk(&context, quirk, profile);
    }
    finalizeContext(&context);
    return context;
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

fn accumulateQuirk(context: *DispatchContext, quirk: model.Quirk, profile: model.DeviceProfile) void {
    const si = @intFromEnum(quirk.scope);
    inline for (std.meta.fields(DispatchContext)) |field| {
        if (field.type == CommandDispatchBucket) {
            const kind = @field(model.CommandKind, field.name);
            if (SCOPE_COMMAND_TABLE[si][@intFromEnum(kind)]) {
                const bucket = &@field(context, field.name);
                const candidate = ScoredQuirk{ .quirk = quirk, .score = scoreRule(quirk, kind, profile) };
                bucket.matched_count += 1;
                // Strict improvement preserves the stable sort's first-input tie rule.
                if (bucket.best == null or compareScoredQuirk({}, candidate, .{ .quirk = bucket.best.?, .score = bucket.best_score })) {
                    bucket.best = quirk;
                    bucket.best_score = candidate.score;
                }
            }
        }
    }
}

fn finalizeContext(context: *DispatchContext) void {
    inline for (std.meta.fields(DispatchContext)) |field| {
        if (field.type == CommandDispatchBucket) finalizeBucket(&@field(context, field.name));
    }
}

fn finalizeBucket(bucket: *CommandDispatchBucket) void {
    const quirk = bucket.best orelse return;
    const requires_lean = model.requiresProof(quirk.verification_mode);
    const is_blocking = if (lean_proof.lean_verified) blk: {
        // Blocking shortcuts (comptime_verified tier — verifiable by enum exhaustion).
        if (quirk.proof_level == .rejected) break :blk true;
        if (quirk.safety_class == .critical) break :blk quirk.proof_level != .proven;
        break :blk requires_lean and quirk.proof_level != .proven;
    } else requires_lean and quirk.proof_level != .proven;

    bucket.requires_lean = requires_lean;
    bucket.is_blocking = is_blocking;
    bucket.action_is_identity = switch (quirk.action) {
        .no_op => true,
        .toggle => |payload| toggle_registry.effect(payload.toggle_name) != .behavioral,
        .use_temporary_buffer => false,
        .use_temporary_render_texture => false,
    };
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

test "quirk builders retain their public allocator error contract" {
    const plain = @typeInfo(@TypeOf(buildDispatchContext)).@"fn".return_type.?;
    const filtered = @typeInfo(@TypeOf(buildProfileDispatchContext)).@"fn".return_type.?;
    try std.testing.expect(@typeInfo(plain).error_union.error_set == std.mem.Allocator.Error);
    try std.testing.expect(@typeInfo(filtered).error_union.error_set == std.mem.Allocator.Error);
}

const TEST_PROFILE = model.DeviceProfile{
    .vendor = "AMD",
    .api = .vulkan,
    .device_family = "test-family",
    .driver_version = .{ .major = 2, .minor = 3, .patch = 4 },
};

fn testQuirk(id: []const u8) model.Quirk {
    return .{
        .schema_version = model_policy.CURRENT_SCHEMA_VERSION,
        .quirk_id = id,
        .scope = .driver_toggle,
        .match_spec = .{ .vendor = "amd", .api = .vulkan },
        .action = .no_op,
        .safety_class = .moderate,
        .verification_mode = .guard_only,
        .proof_level = .guarded,
        .provenance = .{ .source_repo = "test", .source_path = "test", .source_commit = "test", .observed_at = "test" },
    };
}

test "quirk selection ranks score then proof then priority then identifier" {
    const base = ScoredQuirk{ .quirk = testQuirk("middle"), .score = 100 };
    var better = base;
    better.score += 1;
    better.quirk.proof_level = .rejected;
    try std.testing.expect(compareScoredQuirk({}, better, base));
    better = base;
    better.quirk.proof_level = .proven;
    better.quirk.quirk_id = "z";
    try std.testing.expect(compareScoredQuirk({}, better, base));
    better = base;
    better.quirk.priority += 1;
    better.quirk.quirk_id = "z";
    try std.testing.expect(compareScoredQuirk({}, better, base));
    better = base;
    better.quirk.quirk_id = "a";
    try std.testing.expect(compareScoredQuirk({}, better, base));
    try std.testing.expect(!compareScoredQuirk({}, base, better));
    try std.testing.expect(!compareScoredQuirk({}, base, base));
}

test "quirk selection exact ties retain first input including its action" {
    var quirks = [_]model.Quirk{testQuirk("same")} ** 48;
    for (&quirks, 0..) |*quirk, i| {
        quirk.action = .{ .use_temporary_buffer = .{ .alignment_bytes = @intCast(i + 1) } };
    }
    for (0..quirks.len) |_| {
        const plain = try buildDispatchContext(std.testing.allocator, &quirks);
        defer plain.deinit();
        const filtered = try buildProfileDispatchContext(std.testing.allocator, TEST_PROFILE, &quirks);
        defer filtered.deinit();
        inline for (@typeInfo(DispatchContext).@"struct".fields) |field| {
            if (field.type == CommandDispatchBucket) {
                for ([_]DispatchContext{ plain, filtered }) |context| {
                    const bucket = @field(context, field.name);
                    try std.testing.expectEqualDeep(quirks[0], bucket.best.?);
                    try std.testing.expectEqual(quirks.len, bucket.matched_count);
                }
            }
        }
        std.mem.rotate(model.Quirk, &quirks, 1);
    }
}

// The historical list/sort algorithm remains only as an oracle for the bounded
// selector. Scope, scoring and ranking still have one production owner.
fn expectSortedContext(context: DispatchContext, quirks: []const model.Quirk, profile: model.DeviceProfile, filter_profile: bool) !void {
    inline for (@typeInfo(DispatchContext).@"struct".fields) |field| {
        if (field.type == CommandDispatchBucket) {
            const kind = @field(model.CommandKind, field.name);
            var matches = std.ArrayList(ScoredQuirk).empty;
            defer matches.deinit(std.testing.allocator);
            for (quirks) |quirk| {
                if (filter_profile and !matchesProfile(profile, quirk)) continue;
                if (!supportsCommand(quirk.scope, kind)) continue;
                try matches.append(std.testing.allocator, .{ .quirk = quirk, .score = scoreRule(quirk, kind, profile) });
            }
            std.mem.sort(ScoredQuirk, matches.items, {}, compareScoredQuirk);
            const bucket = @field(context, field.name);
            try std.testing.expectEqual(matches.items.len, bucket.matched_count);
            if (matches.items.len == 0) {
                try std.testing.expectEqualDeep(CommandDispatchBucket{}, bucket);
            } else {
                const winner = matches.items[0];
                try std.testing.expectEqualDeep(winner.quirk, bucket.best.?);
                try std.testing.expectEqual(winner.score, bucket.best_score);
                const required = winner.quirk.verification_mode == .lean_required;
                const blocked = if (lean_proof.lean_verified)
                    winner.quirk.proof_level == .rejected or ((required or winner.quirk.safety_class == .critical) and winner.quirk.proof_level != .proven)
                else
                    required and winner.quirk.proof_level != .proven;
                try std.testing.expectEqual(required, bucket.requires_lean);
                try std.testing.expectEqual(blocked, bucket.is_blocking);
            }
        }
    }
}

test "quirk selection matches stable sort across scopes profiles and input orders" {
    var quirks: [120]model.Quirk = undefined;
    const ids = [_][]const u8{ "z", "a", "same" };
    const scopes = std.enums.values(model.Scope);
    const proofs = std.enums.values(model.ProofLevel);
    const safety = std.enums.values(model.SafetyClass);
    const modes = std.enums.values(model.VerificationMode);
    for (&quirks, 0..) |*quirk, i| {
        quirk.* = testQuirk(ids[i % ids.len]);
        quirk.scope = scopes[i % scopes.len];
        quirk.priority = @intCast(i % 11);
        quirk.proof_level = proofs[i % proofs.len];
        quirk.safety_class = safety[i % safety.len];
        quirk.verification_mode = modes[(i / 3) % modes.len];
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
    const scoring_profile = model.DeviceProfile{
        .vendor = "",
        .api = quirks[0].match_spec.api,
        .driver_version = .{ .major = 9999, .minor = 9999, .patch = 9999 },
    };
    for (0..quirks.len + 1) |len| {
        const plain = try buildDispatchContext(std.testing.allocator, quirks[0..len]);
        defer plain.deinit();
        try expectSortedContext(plain, quirks[0..len], scoring_profile, false);
        const filtered = try buildProfileDispatchContext(std.testing.allocator, TEST_PROFILE, quirks[0..len]);
        defer filtered.deinit();
        try expectSortedContext(filtered, quirks[0..len], TEST_PROFILE, true);
        std.mem.rotate(model.Quirk, &quirks, 1);
    }
}

fn expectAllocationFreeContext(comptime filter_profile: bool) !void {
    // The backing arena cleans up even a regression that strands an allocation;
    // the wrapper independently accounts for frees made by the actual builder.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var failing = std.testing.FailingAllocator.init(arena.allocator(), .{ .fail_index = 1 });
    const quirks = [_]model.Quirk{testQuirk("all-commands")};
    const result = if (filter_profile)
        buildProfileDispatchContext(failing.allocator(), TEST_PROFILE, &quirks)
    else
        buildDispatchContext(failing.allocator(), &quirks);
    if (result) |context| context.deinit() else |_| {}
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    _ = try result;
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expect(!failing.has_induced_failure);
}

test "quirk unfiltered context construction does not allocate or strand partial state" {
    try expectAllocationFreeContext(false);
}

test "quirk profile context construction does not allocate or strand partial state" {
    try expectAllocationFreeContext(true);
}

test "quirk context profile filters remain separate from prefiltered construction" {
    const base = testQuirk("match");
    var quirks = [_]model.Quirk{base} ** 8;
    quirks[1].match_spec.vendor = "intel";
    quirks[2].match_spec.api = .metal;
    quirks[3].match_spec.device_family = "different-family";
    quirks[4].match_spec.driver_range = ">=3.0.0";
    quirks[5].match_spec.driver_range = "invalid";
    quirks[6].match_spec.driver_range = ">=2.0.0,<3.0.0";
    quirks[7].match_spec.device_family = TEST_PROFILE.device_family;

    const filtered = try buildProfileDispatchContext(std.testing.allocator, TEST_PROFILE, &quirks);
    defer filtered.deinit();
    try std.testing.expectEqual(@as(u32, 3), filtered.upload.matched_count);
    try std.testing.expectEqualDeep(quirks[7], filtered.upload.best.?);
    const prefiltered = try buildDispatchContext(std.testing.allocator, &quirks);
    defer prefiltered.deinit();
    try std.testing.expectEqual(quirks.len, prefiltered.upload.matched_count);
    try std.testing.expectEqualDeep(quirks[4], prefiltered.upload.best.?);
}

test "quirk context bucket metadata preserves proof blocking and identity decisions" {
    inline for (std.meta.tags(model.ProofLevel)) |proof| {
        inline for (std.meta.tags(model.VerificationMode)) |mode| {
            inline for (std.meta.tags(model.SafetyClass)) |safety| {
                var quirk = testQuirk("metadata");
                quirk.proof_level = proof;
                quirk.verification_mode = mode;
                quirk.safety_class = safety;
                const context = try buildProfileDispatchContext(std.testing.allocator, TEST_PROFILE, &.{quirk});
                defer context.deinit();
                const required = mode == .lean_required;
                const blocking = proof != .proven and (required or (lean_proof.lean_verified and (proof == .rejected or safety == .critical)));
                try std.testing.expectEqual(required, context.upload.requires_lean);
                try std.testing.expectEqual(blocking, context.upload.is_blocking);
                try std.testing.expect(context.upload.action_is_identity);
            }
        }
    }
    const actions = [_]model.QuirkAction{
        .no_op,
        .{ .toggle = .{ .toggle_name = "unknown-informational-toggle" } },
        .{ .use_temporary_buffer = .{ .alignment_bytes = 256 } },
        .{ .use_temporary_render_texture = .{ .min_mip_level = 1 } },
    };
    for (actions, [_]bool{ true, true, false, false }) |action, identity| {
        var quirk = testQuirk("action");
        quirk.action = action;
        const context = try buildDispatchContext(std.testing.allocator, &.{quirk});
        defer context.deinit();
        try std.testing.expectEqual(identity, context.upload.action_is_identity);
    }
}
