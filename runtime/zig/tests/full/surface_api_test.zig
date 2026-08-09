const std = @import("std");
const model = @import("../../src/contracts/command.zig");
const full_surface_api = @import("../../src/full/surface_api.zig");
const core_surface = @import("../../src/core/surface.zig");
const builtin = @import("builtin");
const instance_device = @import("../../src/native/lifecycle/doe_instance_device_native.zig");
const native_helpers = @import("../../src/native/support/doe_native_object_helpers.zig");
const native_types = @import("../../src/native/support/doe_native_object_types.zig");
const surface_native = @import("../../src/native/surface/doe_surface_native.zig");
const surface_procs = @import("../../src/full/surface/wgpu_surface_procs.zig");

test "full surface ID and version" {
    try std.testing.expectEqualStrings("doe-full", full_surface_api.SURFACE_ID);
    try std.testing.expectEqual(@as(u32, 1), full_surface_api.SURFACE_VERSION);
}

test "native surface C ABI creates unconfigured surface before device binding" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    const inst_raw = instance_device.doeNativeCreateInstance(null) orelse return error.TestExpectedEqual;
    const inst = native_helpers.cast(native_types.DoeInstance, inst_raw) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u32, 1), inst.ref_count);

    var desc = surface_procs.SurfaceDescriptor{
        .nextInChain = null,
        .label = .{ .data = null, .length = 0 },
    };
    const surf_raw = surface_native.doeAbiBridgeInstanceCreateSurface(inst_raw, &desc) orelse return error.TestExpectedEqual;
    const surf = native_helpers.cast(surface_native.DoeSurface, surf_raw) orelse return error.TestExpectedEqual;

    try std.testing.expectEqual(@as(u32, 2), inst.ref_count);
    try std.testing.expect(surf.vk_runtime_ref == null);

    surface_native.doeNativeSurfaceRelease(surf_raw);
    try std.testing.expectEqual(@as(u32, 1), inst.ref_count);
    instance_device.doeNativeInstanceRelease(inst_raw);
}

test "full surface accepts all commands" {
    const upload = model.Command{ .upload = .{ .bytes = 64, .align_bytes = 4 } };
    try std.testing.expect(full_surface_api.accepts(upload));

    const render = model.Command{ .render_draw = .{ .draw_count = 1 } };
    try std.testing.expect(full_surface_api.accepts(render));

    const sampler = model.Command{ .sampler_create = .{ .handle = 42 } };
    try std.testing.expect(full_surface_api.accepts(sampler));

    const surface = model.Command{ .surface_present = .{ .handle = 1 } };
    try std.testing.expect(full_surface_api.accepts(surface));

    const diag = model.Command{ .async_diagnostics = .{} };
    try std.testing.expect(full_surface_api.accepts(diag));
}

test "full surface classify distinguishes core vs full-only" {
    const upload = model.Command{ .upload = .{ .bytes = 64, .align_bytes = 4 } };
    const class_upload = full_surface_api.classify(upload);
    try std.testing.expect(class_upload == .core);

    const dispatch = model.Command{ .dispatch = .{ .x = 1, .y = 1, .z = 1 } };
    const class_dispatch = full_surface_api.classify(dispatch);
    try std.testing.expect(class_dispatch == .core);

    const render = model.Command{ .render_draw = .{ .draw_count = 1 } };
    const class_render = full_surface_api.classify(render);
    try std.testing.expect(class_render == .full_only);

    const surface = model.Command{ .surface_create = .{ .handle = 1 } };
    const class_surface = full_surface_api.classify(surface);
    try std.testing.expect(class_surface == .full_only);
}

test "full surface accepts_kind covers all combined command kinds" {
    const fields = @typeInfo(model.CommandKind).@"enum".fields;
    inline for (fields) |field| {
        const kind: model.CommandKind = @enumFromInt(field.value);
        try std.testing.expect(full_surface_api.accepts_kind(kind));
    }
}

test "full surface command counts are consistent" {
    try std.testing.expectEqual(@as(u32, 11), core_surface.CORE_COMMAND_COUNT);
    try std.testing.expectEqual(@as(u32, 14), full_surface_api.FULL_ONLY_COMMAND_COUNT);
    try std.testing.expectEqual(@as(u32, 25), full_surface_api.TOTAL_COMMAND_COUNT);

    const combined_kinds = @typeInfo(model.CommandKind).@"enum".fields.len;
    try std.testing.expectEqual(combined_kinds, full_surface_api.TOTAL_COMMAND_COUNT);
}

test "full surface full_only_command_kind_names returns correct names" {
    const names = full_surface_api.full_only_command_kind_names();
    try std.testing.expectEqual(@as(usize, 14), names.len);
    try std.testing.expectEqualStrings("render_draw", names[0]);
    try std.testing.expectEqualStrings("async_diagnostics", names[names.len - 1]);
}

test "full surface combined_coverage_ledger is exhaustive" {
    const ledger = full_surface_api.combined_coverage_ledger();
    try std.testing.expectEqual(full_surface_api.TOTAL_COMMAND_COUNT, ledger.len);
    for (ledger) |entry| {
        try std.testing.expect(entry.command_kind.len > 0);
        try std.testing.expect(entry.domain.len > 0);
    }
}

test "full surface domain classification" {
    try std.testing.expectEqualStrings("render", full_surface_api.domain_for_kind(.render_draw));
    try std.testing.expectEqualStrings("render", full_surface_api.domain_for_kind(.draw_indirect));
    try std.testing.expectEqualStrings("render", full_surface_api.domain_for_kind(.draw_indexed_indirect));
    try std.testing.expectEqualStrings("render", full_surface_api.domain_for_kind(.render_pass));
    try std.testing.expectEqualStrings("resource", full_surface_api.domain_for_kind(.sampler_create));
    try std.testing.expectEqualStrings("resource", full_surface_api.domain_for_kind(.sampler_destroy));
    try std.testing.expectEqualStrings("surface", full_surface_api.domain_for_kind(.surface_create));
    try std.testing.expectEqualStrings("surface", full_surface_api.domain_for_kind(.surface_capabilities));
    try std.testing.expectEqualStrings("surface", full_surface_api.domain_for_kind(.surface_configure));
    try std.testing.expectEqualStrings("surface", full_surface_api.domain_for_kind(.surface_acquire));
    try std.testing.expectEqualStrings("surface", full_surface_api.domain_for_kind(.surface_present));
    try std.testing.expectEqualStrings("surface", full_surface_api.domain_for_kind(.surface_unconfigure));
    try std.testing.expectEqualStrings("surface", full_surface_api.domain_for_kind(.surface_release));
    try std.testing.expectEqualStrings("lifecycle", full_surface_api.domain_for_kind(.async_diagnostics));
}

test "full surface core and full-only partitions are disjoint" {
    const core_names = core_surface.command_kind_names();
    const full_names = full_surface_api.full_only_command_kind_names();
    for (core_names) |core_name| {
        for (full_names) |full_name| {
            try std.testing.expect(!std.mem.eql(u8, core_name, full_name));
        }
    }
}

test "full surface is strict superset of core surface" {
    const core_ledger = core_surface.coverage_ledger();
    const combined_ledger = full_surface_api.combined_coverage_ledger();

    for (core_ledger) |core_entry| {
        var found = false;
        for (combined_ledger) |combined_entry| {
            if (std.mem.eql(u8, core_entry.command_kind, combined_entry.command_kind)) {
                try std.testing.expectEqualStrings(core_entry.domain, combined_entry.domain);
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}
