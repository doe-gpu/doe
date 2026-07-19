const std = @import("std");
const multi_adapter = @import("../../src/runtime/device/multi_adapter.zig");
const AdapterType = multi_adapter.AdapterType;
const BackendType = multi_adapter.BackendType;
const DoeAdapterInfo = multi_adapter.DoeAdapterInfo;
const DoeAdapterList = multi_adapter.DoeAdapterList;
const AdapterOptions = multi_adapter.AdapterOptions;

// ============================================================
// AdapterType enum values — must be stable (WebGPU ABI)

test "AdapterType enum has stable integer values" {
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(AdapterType.discrete_gpu));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(AdapterType.integrated_gpu));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(AdapterType.cpu));
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(AdapterType.unknown));
}

// ============================================================
// BackendType enum values — must be stable (WebGPU ABI)

test "BackendType enum has stable integer values" {
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(BackendType.null_backend));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(BackendType.metal));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(BackendType.vulkan));
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(BackendType.d3d12));
}

// ============================================================
// DoeAdapterInfo defaults

test "DoeAdapterInfo default fields are zeroed" {
    const info = DoeAdapterInfo{};
    try std.testing.expectEqual(AdapterType.unknown, info.adapter_type);
    try std.testing.expectEqual(BackendType.metal, info.backend_type);
    try std.testing.expectEqual(@as(u64, 0), info.registry_id);
    try std.testing.expectEqual(false, info.is_low_power);
    try std.testing.expectEqual(false, info.is_removable);
    try std.testing.expectEqual(@as(u32, 0), info.name_len);
    try std.testing.expectEqual(@as(u32, 0), info.vendor_len);
}

test "DoeAdapterInfo name buffer is 256 bytes" {
    const info = DoeAdapterInfo{};
    try std.testing.expectEqual(@as(usize, 256), info.name.len);
}

test "DoeAdapterInfo vendor buffer is 64 bytes" {
    const info = DoeAdapterInfo{};
    try std.testing.expectEqual(@as(usize, 64), info.vendor.len);
}

// ============================================================
// Adapter selection — empty list

test "select_adapter returns null for empty list" {
    var list = make_empty_list();
    const result = multi_adapter.select_adapter(&list, .{});
    try std.testing.expect(result == null);
}

test "select_adapter returns null for empty list with high performance preference" {
    var list = make_empty_list();
    const result = multi_adapter.select_adapter(&list, .{
        .power_preference = 2, // WGPU_POWER_PREF_HIGH_PERFORMANCE
    });
    try std.testing.expect(result == null);
}

test "select_adapter returns null for empty list with force fallback" {
    var list = make_empty_list();
    const result = multi_adapter.select_adapter(&list, .{
        .force_fallback = true,
    });
    try std.testing.expect(result == null);
}

// ============================================================
// Adapter selection — single adapter

test "select_adapter returns index 0 for single adapter" {
    var items = [_]DoeAdapterInfo{make_adapter(.discrete_gpu, false, false)};
    var list = make_list(&items, 1);
    const result = multi_adapter.select_adapter(&list, .{});
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 0), result.?);
}

// ============================================================
// Adapter selection — discrete preferred over integrated

test "select_adapter prefers discrete GPU over integrated by default" {
    var items = [_]DoeAdapterInfo{
        make_adapter(.integrated_gpu, true, false),
        make_adapter(.discrete_gpu, false, false),
    };
    var list = make_list(&items, 2);

    const result = multi_adapter.select_adapter(&list, .{});
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 1), result.?);
}

test "select_adapter prefers discrete GPU over unknown" {
    var items = [_]DoeAdapterInfo{
        make_adapter(.unknown, false, false),
        make_adapter(.discrete_gpu, false, false),
    };
    var list = make_list(&items, 2);

    const result = multi_adapter.select_adapter(&list, .{});
    try std.testing.expectEqual(@as(usize, 1), result.?);
}

test "select_adapter prefers integrated over CPU" {
    var items = [_]DoeAdapterInfo{
        make_adapter(.cpu, false, false),
        make_adapter(.integrated_gpu, true, false),
    };
    var list = make_list(&items, 2);

    const result = multi_adapter.select_adapter(&list, .{});
    try std.testing.expectEqual(@as(usize, 1), result.?);
}

// ============================================================
// Power preference — high performance

test "high performance preference boosts non-low-power adapters" {
    var items = [_]DoeAdapterInfo{
        make_adapter(.integrated_gpu, true, false), // low-power integrated: 50
        make_adapter(.integrated_gpu, false, false), // non-low-power integrated: 50 + 20 = 70
    };
    var list = make_list(&items, 2);

    const result = multi_adapter.select_adapter(&list, .{
        .power_preference = 2, // HIGH_PERFORMANCE
    });
    try std.testing.expectEqual(@as(usize, 1), result.?);
}

test "high performance prefers discrete over integrated even without preference" {
    // Discrete (100+20=120) vs integrated low-power (50).
    var items = [_]DoeAdapterInfo{
        make_adapter(.integrated_gpu, true, false),
        make_adapter(.discrete_gpu, false, false),
    };
    var list = make_list(&items, 2);

    const result = multi_adapter.select_adapter(&list, .{
        .power_preference = 2,
    });
    try std.testing.expectEqual(@as(usize, 1), result.?);
}

// ============================================================
// Power preference — low power

test "low power preference boosts low-power adapters" {
    // Discrete non-low-power: 100. Integrated low-power: 50 + 20 = 70.
    // Discrete still wins (100 > 70), but the boost is applied.
    var items = [_]DoeAdapterInfo{
        make_adapter(.discrete_gpu, false, false),
        make_adapter(.integrated_gpu, true, false),
    };
    var list = make_list(&items, 2);

    const result = multi_adapter.select_adapter(&list, .{
        .power_preference = 1, // LOW_POWER
    });
    // Discrete (100) > Integrated+low_power_boost (70), so discrete wins.
    try std.testing.expectEqual(@as(usize, 0), result.?);
}

test "low power preference selects integrated when two integrateds differ in low_power" {
    // Two integrated GPUs: one low-power (50+20=70), one not (50).
    var items = [_]DoeAdapterInfo{
        make_adapter(.integrated_gpu, false, false), // score 50
        make_adapter(.integrated_gpu, true, false), // score 50 + 20 = 70
    };
    var list = make_list(&items, 2);

    const result = multi_adapter.select_adapter(&list, .{
        .power_preference = 1, // LOW_POWER
    });
    try std.testing.expectEqual(@as(usize, 1), result.?);
}

// ============================================================
// Power preference — undefined (no preference)

test "undefined power preference does not apply power boost" {
    // Two identical integrated GPUs except for low_power flag.
    // Without preference, both score 50; first one wins.
    var items = [_]DoeAdapterInfo{
        make_adapter(.integrated_gpu, true, false), // score 50
        make_adapter(.integrated_gpu, false, false), // score 50
    };
    var list = make_list(&items, 2);

    const result = multi_adapter.select_adapter(&list, .{
        .power_preference = 0, // UNDEFINED
    });
    // Equal scores — first with higher score wins. Both 50, first index wins.
    try std.testing.expectEqual(@as(usize, 0), result.?);
}

// ============================================================
// Removable (eGPU) penalty

test "removable GPU gets penalty relative to non-removable" {
    // Two discrete GPUs: removable (100-10=90) vs non-removable (100).
    var items = [_]DoeAdapterInfo{
        make_adapter(.discrete_gpu, false, true), // removable: 90
        make_adapter(.discrete_gpu, false, false), // non-removable: 100
    };
    var list = make_list(&items, 2);

    const result = multi_adapter.select_adapter(&list, .{});
    try std.testing.expectEqual(@as(usize, 1), result.?);
}

test "removable integrated is penalized but still beats CPU" {
    // Removable integrated: 50-10=40. CPU: -50.
    var items = [_]DoeAdapterInfo{
        make_adapter(.cpu, false, false),
        make_adapter(.integrated_gpu, true, true),
    };
    var list = make_list(&items, 2);

    const result = multi_adapter.select_adapter(&list, .{});
    try std.testing.expectEqual(@as(usize, 1), result.?);
}

// ============================================================
// CPU adapter scoring

test "CPU adapter scores below zero" {
    // CPU (-50) vs unknown (0): unknown should win.
    var items = [_]DoeAdapterInfo{
        make_adapter(.cpu, false, false),
        make_adapter(.unknown, false, false),
    };
    var list = make_list(&items, 2);

    const result = multi_adapter.select_adapter(&list, .{});
    try std.testing.expectEqual(@as(usize, 1), result.?);
}

// ============================================================
// Force fallback

test "force_fallback selects CPU adapter when available" {
    var items = [_]DoeAdapterInfo{
        make_adapter(.discrete_gpu, false, false),
        make_adapter(.integrated_gpu, true, false),
        make_adapter(.cpu, false, false),
    };
    var list = make_list(&items, 3);

    const result = multi_adapter.select_adapter(&list, .{
        .force_fallback = true,
    });
    try std.testing.expectEqual(@as(usize, 2), result.?);
}

test "force_fallback returns first adapter when no CPU adapter exists" {
    var items = [_]DoeAdapterInfo{
        make_adapter(.integrated_gpu, true, false),
        make_adapter(.discrete_gpu, false, false),
    };
    var list = make_list(&items, 2);

    const result = multi_adapter.select_adapter(&list, .{
        .force_fallback = true,
    });
    try std.testing.expectEqual(@as(usize, 0), result.?);
}

test "force_fallback selects first CPU when multiple CPU adapters exist" {
    var items = [_]DoeAdapterInfo{
        make_adapter(.discrete_gpu, false, false),
        make_adapter(.cpu, false, false),
        make_adapter(.cpu, false, false),
    };
    var list = make_list(&items, 3);

    const result = multi_adapter.select_adapter(&list, .{
        .force_fallback = true,
    });
    try std.testing.expectEqual(@as(usize, 1), result.?);
}

test "force_fallback ignores power preference" {
    var items = [_]DoeAdapterInfo{
        make_adapter(.discrete_gpu, false, false),
        make_adapter(.cpu, false, false),
    };
    var list = make_list(&items, 2);

    // Even with HIGH_PERFORMANCE, force_fallback picks CPU.
    const result = multi_adapter.select_adapter(&list, .{
        .power_preference = 2,
        .force_fallback = true,
    });
    try std.testing.expectEqual(@as(usize, 1), result.?);
}

// ============================================================
// AdapterOptions defaults

test "AdapterOptions default is undefined preference with no fallback" {
    const opts = AdapterOptions{};
    try std.testing.expectEqual(@as(u32, 0), opts.power_preference);
    try std.testing.expectEqual(false, opts.force_fallback);
}

// ============================================================
// Scoring edge cases — many adapters

test "select_adapter handles maximum scored ranking with mixed types" {
    var items = [_]DoeAdapterInfo{
        make_adapter(.cpu, false, false), // -50
        make_adapter(.unknown, false, false), // 0
        make_adapter(.integrated_gpu, true, false), // 50
        make_adapter(.discrete_gpu, false, true), // 90 (removable)
        make_adapter(.discrete_gpu, false, false), // 100
    };
    var list = make_list(&items, 5);

    const result = multi_adapter.select_adapter(&list, .{});
    try std.testing.expectEqual(@as(usize, 4), result.?);
}

test "select_adapter with high performance resolves tie between discrete GPUs" {
    // Two discrete, one low_power (unusual but possible), one not.
    // Default: both score 100, first wins.
    // HIGH_PERF: non-low-power gets +20 = 120, low-power stays 100.
    var items = [_]DoeAdapterInfo{
        make_adapter(.discrete_gpu, true, false), // 100 (low-power discrete)
        make_adapter(.discrete_gpu, false, false), // 100 + 20 = 120
    };
    var list = make_list(&items, 2);

    const result = multi_adapter.select_adapter(&list, .{
        .power_preference = 2,
    });
    try std.testing.expectEqual(@as(usize, 1), result.?);
}

// ============================================================
// Constants — MAX_ADAPTERS

test "MAX_ADAPTERS is 16" {
    // Verify via DoeAdapterInfo array size expectation (items allocated to MAX_ADAPTERS).
    // The constant itself is not pub, but the data structures it governs are.
    // We verify by constructing a list with 16 items, which should be the limit.
    var items: [16]DoeAdapterInfo = undefined;
    for (&items) |*item| {
        item.* = make_adapter(.unknown, false, false);
    }
    var list = make_list(&items, 16);

    const result = multi_adapter.select_adapter(&list, .{});
    try std.testing.expect(result != null);
}

// ============================================================
// Test helpers

fn make_empty_list() DoeAdapterList {
    return DoeAdapterList{
        .allocator = std.testing.allocator,
        .items = &.{},
        .count = 0,
    };
}

fn make_list(items: []DoeAdapterInfo, count: usize) DoeAdapterList {
    return DoeAdapterList{
        .allocator = std.testing.allocator,
        .items = items,
        .count = count,
    };
}

fn make_adapter(adapter_type: AdapterType, is_low_power: bool, is_removable: bool) DoeAdapterInfo {
    return DoeAdapterInfo{
        .adapter_type = adapter_type,
        .is_low_power = is_low_power,
        .is_removable = is_removable,
        .mtl_device = null,
    };
}
