const std = @import("std");
const model_policy = @import("../contracts/model/model_policy.zig");
const model_quirks = @import("../contracts/model/model_quirks.zig");

const Allocator = std.mem.Allocator;

const model = struct {
    pub const CURRENT_SCHEMA_VERSION = model_policy.CURRENT_SCHEMA_VERSION;
    pub const Quirk = model_quirks.Quirk;
    pub const QuirkAction = model_quirks.QuirkAction;
    pub const ToggleAction = model_quirks.ToggleAction;
    pub const UseTemporaryBufferAction = model_quirks.UseTemporaryBufferAction;
    pub const UseTemporaryRenderTextureAction = model_quirks.UseTemporaryRenderTextureAction;
    pub const parse_api = model_policy.parse_api;
    pub const parse_proof_level = model_policy.parse_proof_level;
    pub const parse_safety = model_policy.parse_safety;
    pub const parse_scope = model_policy.parse_scope;
    pub const parse_verification_mode = model_policy.parse_verification_mode;
};

const ParseError = error{
    UnsupportedActionKind,
    InvalidSchemaVersion,
    InvalidPayload,
};

const RawMatchSpec = struct {
    vendor: []const u8,
    api: []const u8,
    deviceFamily: ?[]const u8 = null,
    driverRange: ?[]const u8 = null,
};

const RawAction = struct {
    kind: []const u8,
    params: ?std.json.Value = null,
};

const RawProvenance = struct {
    sourceRepo: []const u8,
    sourcePath: []const u8,
    sourceCommit: []const u8,
    observedAt: []const u8,
};

const RawQuirk = struct {
    schemaVersion: u8,
    quirkId: []const u8,
    scope: []const u8,
    match: RawMatchSpec,
    action: RawAction,
    safetyClass: []const u8,
    verificationMode: []const u8,
    proofLevel: []const u8,
    provenance: RawProvenance,
};

pub fn parseQuirks(allocator: Allocator, text: []const u8) ![]model.Quirk {
    if (std.mem.eql(u8, std.mem.trim(u8, text, " \n\r\t"), "[]")) {
        return &[_]model.Quirk{};
    }

    const parsed = std.json.parseFromSlice([]const RawQuirk, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.UnexpectedToken => return parseSingleQuirk(allocator, text),
        else => return err,
    };
    defer parsed.deinit();

    var list = std.ArrayList(model.Quirk).empty;
    errdefer {
        for (list.items) |quirk| {
            freeQuirkFields(allocator, quirk);
        }
        list.deinit(allocator);
    }
    try list.ensureTotalCapacity(allocator, parsed.value.len);

    for (parsed.value) |raw| {
        const q = try materializeQuirk(allocator, raw);
        list.appendAssumeCapacity(q);
    }
    return list.toOwnedSlice(allocator);
}

fn parseSingleQuirk(allocator: Allocator, text: []const u8) ![]model.Quirk {
    const parsed = try std.json.parseFromSlice(RawQuirk, allocator, text, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    var list = std.ArrayList(model.Quirk).empty;
    errdefer {
        for (list.items) |quirk| {
            freeQuirkFields(allocator, quirk);
        }
        list.deinit(allocator);
    }

    try list.ensureTotalCapacity(allocator, 1);
    const q = try materializeQuirk(allocator, parsed.value);
    list.appendAssumeCapacity(q);
    return list.toOwnedSlice(allocator);
}

pub fn freeQuirks(allocator: Allocator, quirks: []model.Quirk) void {
    for (quirks) |quirk| {
        freeQuirkFields(allocator, quirk);
    }
    allocator.free(quirks);
}

fn materializeQuirk(allocator: Allocator, raw: RawQuirk) !model.Quirk {
    if (raw.schemaVersion != model.CURRENT_SCHEMA_VERSION) return ParseError.InvalidSchemaVersion;

    const scope = try model.parse_scope(raw.scope);
    const safety_class = try model.parse_safety(raw.safetyClass);
    const verification_mode = try model.parse_verification_mode(raw.verificationMode);
    const proof_level = try model.parse_proof_level(raw.proofLevel);
    const match_api = try model.parse_api(raw.match.api);

    const action = try parseAction(allocator, raw.action.kind, raw.action.params);
    errdefer freeAction(allocator, action);
    const match_vendor = try allocator.dupe(u8, raw.match.vendor);
    errdefer allocator.free(match_vendor);
    const match_device_family = if (raw.match.deviceFamily) |value| try allocator.dupe(u8, value) else null;
    errdefer if (match_device_family) |value| allocator.free(value);
    const match_driver_range = if (raw.match.driverRange) |value| try allocator.dupe(u8, value) else null;
    errdefer if (match_driver_range) |value| allocator.free(value);

    const source_repo = try allocator.dupe(u8, raw.provenance.sourceRepo);
    errdefer allocator.free(source_repo);
    const source_path = try allocator.dupe(u8, raw.provenance.sourcePath);
    errdefer allocator.free(source_path);
    const source_commit = try allocator.dupe(u8, raw.provenance.sourceCommit);
    errdefer allocator.free(source_commit);
    const observed_at = try allocator.dupe(u8, raw.provenance.observedAt);
    errdefer allocator.free(observed_at);
    const quirk_id = try allocator.dupe(u8, raw.quirkId);
    errdefer allocator.free(quirk_id);

    return model.Quirk{
        .schema_version = raw.schemaVersion,
        .quirk_id = quirk_id,
        .scope = scope,
        .match_spec = .{
            .vendor = match_vendor,
            .api = match_api,
            .device_family = match_device_family,
            .driver_range = match_driver_range,
        },
        .action = action,
        .safety_class = safety_class,
        .verification_mode = verification_mode,
        .proof_level = proof_level,
        .provenance = .{
            .source_repo = source_repo,
            .source_path = source_path,
            .source_commit = source_commit,
            .observed_at = observed_at,
        },
        .priority = inferPriority(raw.scope, raw.verificationMode, raw.safetyClass),
    };
}

fn parseAction(allocator: Allocator, kind: []const u8, params: ?std.json.Value) !model.QuirkAction {
    if (std.mem.eql(u8, kind, "use_temporary_buffer")) {
        const payload = params orelse return ParseError.InvalidPayload;
        const alignment = parseTemporaryBufferAlignment(payload) orelse return ParseError.InvalidPayload;
        if (alignment == 0) return ParseError.InvalidPayload;
        return model.QuirkAction{
            .use_temporary_buffer = model.UseTemporaryBufferAction{
                .alignment_bytes = alignment,
            },
        };
    }
    if (std.mem.eql(u8, kind, "use_temporary_render_texture")) {
        const payload = params orelse return ParseError.InvalidPayload;
        const min_mip = parseMinMipLevel(payload) orelse return ParseError.InvalidPayload;
        return model.QuirkAction{
            .use_temporary_render_texture = model.UseTemporaryRenderTextureAction{
                .min_mip_level = min_mip,
            },
        };
    }
    if (std.mem.eql(u8, kind, "toggle")) {
        const payload = params orelse return ParseError.InvalidPayload;
        const toggle_name = parseToggleName(payload) orelse return ParseError.InvalidPayload;
        return model.QuirkAction{
            .toggle = model.ToggleAction{
                .toggle_name = try allocator.dupe(u8, toggle_name),
            },
        };
    }
    if (std.mem.eql(u8, kind, "no_op")) {
        if (params != null) return ParseError.InvalidPayload;
        return model.QuirkAction{ .no_op = {} };
    }
    return ParseError.UnsupportedActionKind;
}

fn parseTemporaryBufferAlignment(raw: std.json.Value) ?u32 {
    switch (raw) {
        .object => |o| {
            if (o.get("bufferAlignmentBytes")) |field| {
                return jsonToU32(field);
            }
        },
        else => {},
    }
    return null;
}

fn parseToggleName(raw: std.json.Value) ?[]const u8 {
    switch (raw) {
        .object => |o| {
            if (o.get("toggle")) |field| {
                return jsonToString(field);
            }
        },
        else => {},
    }
    return null;
}

fn parseMinMipLevel(raw: std.json.Value) ?u32 {
    switch (raw) {
        .object => |o| {
            if (o.get("minMipLevel")) |field| {
                return jsonToU32(field);
            }
        },
        else => {},
    }
    return null;
}

fn jsonToString(raw: std.json.Value) ?[]const u8 {
    return switch (raw) {
        .string => |value| value,
        else => null,
    };
}

fn jsonToU32(raw: std.json.Value) ?u32 {
    return switch (raw) {
        .integer => |value| if (value < 0 or value > std.math.maxInt(u32))
            null
        else
            @as(u32, @intCast(value)),
        .float => |value| blk: {
            if (value < 0 or !std.math.isFinite(value)) break :blk null;
            const max_value = @as(f64, @floatFromInt(std.math.maxInt(u32)));
            if (value > max_value) break :blk null;
            if (value != @floor(value)) break :blk null;
            break :blk @as(u32, @intFromFloat(value));
        },
        else => null,
    };
}

fn freeAction(allocator: Allocator, action: model.QuirkAction) void {
    switch (action) {
        .toggle => |toggle| allocator.free(toggle.toggle_name),
        .use_temporary_buffer, .use_temporary_render_texture, .no_op => {},
    }
}

fn freeQuirkFields(allocator: Allocator, quirk: model.Quirk) void {
    allocator.free(quirk.quirk_id);
    allocator.free(quirk.match_spec.vendor);
    if (quirk.match_spec.device_family) |value| allocator.free(value);
    if (quirk.match_spec.driver_range) |value| allocator.free(value);
    freeAction(allocator, quirk.action);
    allocator.free(quirk.provenance.source_repo);
    allocator.free(quirk.provenance.source_path);
    allocator.free(quirk.provenance.source_commit);
    allocator.free(quirk.provenance.observed_at);
}

fn inferPriority(scope: []const u8, verification_mode: []const u8, safety: []const u8) u32 {
    var score: u32 = 0;
    if (std.mem.eql(u8, scope, "memory")) score += 30;
    if (std.mem.eql(u8, scope, "barrier")) score += 20;
    if (std.mem.eql(u8, verification_mode, "lean_required")) score += 10;
    if (std.mem.eql(u8, safety, "critical")) score += 100;
    return score;
}
