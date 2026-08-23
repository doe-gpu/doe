const std = @import("std");
const abi_base = @import("../core/abi/wgpu_handle_types.zig");
const backend_contract = @import("../contracts/backend.zig");
const dropin_behavior_policy = @import("dropin_behavior_policy.zig");
const dropin_proc_manifest = @import("dropin_proc_manifest.zig");
const dropin_router = @import("dropin_router.zig");
const dropin_symbol_ownership = @import("dropin_symbol_ownership.zig");

const build_options = @import("build_options");
const DROPIN_BEHAVIOR_CONFIG_JSON = build_options.dropin_behavior_config_json;
const DROPIN_SYMBOL_OWNERSHIP_CONFIG_JSON = build_options.dropin_symbol_ownership_config_json;
const DROPIN_BEHAVIOR_DEFAULT_MODE: dropin_behavior_policy.BehaviorMode = .dawn_ownership;
const DROPIN_BEHAVIOR_DEFAULT_STRICT_NO_FALLBACK = true;

pub const ParsedDropinBehaviorConfig = struct {
    mode: dropin_behavior_policy.BehaviorMode,
    strict_no_fallback: bool,
};

var g_behavior_config = ParsedDropinBehaviorConfig{
    .mode = DROPIN_BEHAVIOR_DEFAULT_MODE,
    .strict_no_fallback = DROPIN_BEHAVIOR_DEFAULT_STRICT_NO_FALLBACK,
};
var g_behavior_ready: std.atomic.Value(u8) = .init(0);
var g_behavior_lock: std.Thread.Mutex = .{};
var g_symbol_ownership_config: []const dropin_symbol_ownership.SymbolOwnership = &.{};
var g_symbol_ownership_ready: std.atomic.Value(u8) = .init(0);
var g_symbol_ownership_lock: std.Thread.Mutex = .{};

fn parseModeValue(raw_mode: ?std.json.Value) ?dropin_behavior_policy.BehaviorMode {
    if (raw_mode == null) return null;
    return switch (raw_mode.?) {
        .string => |value| dropin_behavior_policy.parse_behavior_mode(value),
        else => null,
    };
}

fn validateModeStrings(root_obj: std.json.ObjectMap) void {
    if (root_obj.get("defaultMode")) |raw| {
        if (raw == .string and dropin_behavior_policy.parse_behavior_mode(raw.string) == null) {
            @panic("dropin-abi-behavior.json: unrecognized defaultMode value");
        }
    }
    const lane_modes = root_obj.get("laneModes") orelse return;
    if (lane_modes != .object) return;
    var iter = lane_modes.object.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.* == .string and dropin_behavior_policy.parse_behavior_mode(entry.value_ptr.string) == null) {
            @panic("dropin-abi-behavior.json: unrecognized laneModes value");
        }
    }
}

fn resolveModeFromLane(
    raw_lane_modes: ?std.json.Value,
    fallback: dropin_behavior_policy.BehaviorMode,
) dropin_behavior_policy.BehaviorMode {
    const lane_modes = raw_lane_modes orelse return fallback;
    if (lane_modes != .object) return fallback;

    const lane_value = std.process.getEnvVarOwned(std.heap.page_allocator, "FAWN_BACKEND_LANE") catch return fallback;
    defer std.heap.page_allocator.free(lane_value);

    const lane = backend_contract.parseLane(lane_value) orelse return fallback;
    const lane_key = backend_contract.laneName(lane);
    const lane_mode = lane_modes.object.get(lane_key) orelse return fallback;
    return parseModeValue(lane_mode) orelse fallback;
}

fn loadBehaviorConfig() ParsedDropinBehaviorConfig {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), DROPIN_BEHAVIOR_CONFIG_JSON, .{
        .ignore_unknown_fields = false,
    }) catch return g_behavior_config;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return g_behavior_config;

    const root_obj = root.object;
    const default_mode = parseModeValue(root_obj.get("defaultMode")) orelse DROPIN_BEHAVIOR_DEFAULT_MODE;
    var strict_no_fallback = DROPIN_BEHAVIOR_DEFAULT_STRICT_NO_FALLBACK;
    if (root_obj.get("strictFallbackForbidden")) |raw| {
        switch (raw) {
            .bool => |value| strict_no_fallback = value,
            else => return g_behavior_config,
        }
    }
    if (strict_no_fallback) {
        validateModeStrings(root_obj);
    }
    return .{
        .mode = resolveModeFromLane(root_obj.get("laneModes"), default_mode),
        .strict_no_fallback = strict_no_fallback,
    };
}

fn validateSymbolOwnershipConfig(entries: []const dropin_symbol_ownership.SymbolOwnership) void {
    for (entries) |entry| {
        if (dropin_proc_manifest.manifestOwnerForSymbol(entry.symbol)) |owner| {
            if (owner != entry.owner) {
                @panic("drop-in symbol ownership config disagrees with the proc manifest");
            }
        }
    }
}

pub fn activeBehaviorConfig() ParsedDropinBehaviorConfig {
    if (g_behavior_ready.load(.acquire) != 0) {
        return g_behavior_config;
    }

    g_behavior_lock.lock();
    defer g_behavior_lock.unlock();

    if (g_behavior_ready.load(.acquire) != 0) {
        return g_behavior_config;
    }

    g_behavior_config = loadBehaviorConfig();
    g_behavior_ready.store(1, .release);
    return g_behavior_config;
}

pub fn activeBehaviorMode() dropin_behavior_policy.BehaviorMode {
    return activeBehaviorConfig().mode;
}

pub fn activeStrictNoFallback() bool {
    return activeBehaviorConfig().strict_no_fallback;
}

pub fn activeSymbolOwnershipConfig() []const dropin_symbol_ownership.SymbolOwnership {
    if (g_symbol_ownership_ready.load(.acquire) != 0) {
        return g_symbol_ownership_config;
    }

    g_symbol_ownership_lock.lock();
    defer g_symbol_ownership_lock.unlock();

    if (g_symbol_ownership_ready.load(.acquire) != 0) {
        return g_symbol_ownership_config;
    }

    g_symbol_ownership_config = dropin_symbol_ownership.parse_symbol_ownership_config(
        std.heap.page_allocator,
        DROPIN_SYMBOL_OWNERSHIP_CONFIG_JSON,
    ) catch &.{};
    validateSymbolOwnershipConfig(g_symbol_ownership_config);
    g_symbol_ownership_ready.store(1, .release);
    return g_symbol_ownership_config;
}

pub fn symbolOwnerForName(symbol: []const u8) dropin_symbol_ownership.SymbolOwner {
    if (dropin_proc_manifest.manifestOwnerForSymbol(symbol)) |owner| {
        return owner;
    }
    if (dropin_symbol_ownership.find_symbol_ownership(activeSymbolOwnershipConfig(), symbol)) |entry| {
        return entry.owner;
    }
    return .shared;
}

pub fn symbolRouteForName(symbol: []const u8) dropin_router.RouteDecision {
    return dropin_router.decide_symbol_route(
        symbolOwnerForName(symbol),
        activeBehaviorMode(),
        activeStrictNoFallback(),
    );
}

pub fn symbolNameSlice(name: abi_base.WGPUStringView) ?[]const u8 {
    const data = name.data orelse return null;
    if (name.length == abi_base.WGPU_STRLEN) {
        const z = @as([*:0]const u8, @ptrCast(data));
        return std.mem.sliceTo(z, 0);
    }
    if (name.length == 0) return null;
    return data[0..name.length];
}

pub fn symbolRouteForView(name: abi_base.WGPUStringView) dropin_router.RouteDecision {
    if (symbolNameSlice(name)) |symbol| {
        return symbolRouteForName(symbol);
    }
    return dropin_router.decide_symbol_route(.shared, activeBehaviorMode(), false);
}
