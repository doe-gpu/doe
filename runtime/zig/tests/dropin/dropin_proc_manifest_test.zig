const std = @import("std");
const build_options = @import("build_options");
const abi_core = @import("../../src/core/abi/wgpu_core_base_types.zig");
const capability_procs = @import("../../src/core/abi/procs/wgpu_p1_capability_procs.zig");
const manifest = @import("../../src/dropin/dropin_proc_manifest.zig");
const ownership = @import("../../src/dropin/dropin_symbol_ownership.zig");

pub export fn wgpuGetProcAddress(_: abi_core.WGPUStringView) callconv(.c) capability_procs.WGPUProc {
    return null;
}

pub export fn doeWgpuDropinAbortMissingRequiredSymbol(_: abi_core.WGPUStringView) callconv(.c) noreturn {
    @panic("required drop-in symbol invoked by manifest-only test");
}

test "manifest ownership covers exported shared queue submit symbol" {
    try std.testing.expectEqual(ownership.SymbolOwner.shared, manifest.manifestOwnerForSymbol("wgpuQueueSubmit").?);
}

test "symbol ownership config agrees with manifest-covered symbols" {
    const owned = try ownership.parse_symbol_ownership_config(std.testing.allocator, build_options.dropin_symbol_ownership_config_json);
    defer {
        for (owned) |entry| {
            std.testing.allocator.free(entry.symbol);
        }
        std.testing.allocator.free(owned);
    }

    for (owned) |entry| {
        if (manifest.manifestOwnerForSymbol(entry.symbol)) |owner| {
            try std.testing.expectEqual(owner, entry.owner);
        }
    }
}
