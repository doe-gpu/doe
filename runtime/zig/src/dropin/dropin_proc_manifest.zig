const std = @import("std");
const dropin_ext_b = @import("wgpu_dropin_ext_b.zig");
const dropin_ext_c = @import("wgpu_dropin_ext_c.zig");
const dropin_symbol_ownership = @import("dropin_symbol_ownership.zig");

const build_options = @import("build_options");
const TIER = build_options.build_tier;
const N = @import("../native/mod.zig");

const CORE_PROC_ENTRIES = .{
    .{ .symbol = "wgpuCreateInstance", .proc = &N.doeNativeCreateInstance },
    .{ .symbol = "wgpuInstanceAddRef", .proc = &N.doeNativeInstanceAddRef },
    .{ .symbol = "wgpuInstanceRelease", .proc = &N.doeNativeInstanceRelease },
    .{ .symbol = "wgpuInstanceWaitAny", .proc = &N.doeNativeInstanceWaitAny },
    .{ .symbol = "wgpuInstanceProcessEvents", .proc = &N.doeNativeInstanceProcessEvents },
    .{ .symbol = "wgpuInstanceRequestAdapter", .proc = &N.doeNativeInstanceRequestAdapter },
    .{ .symbol = "wgpuAdapterAddRef", .proc = &N.doeNativeAdapterAddRef },
    .{ .symbol = "wgpuAdapterGetInstance", .proc = &N.doeNativeAdapterGetInstance },
    .{ .symbol = "wgpuAdapterRequestDevice", .proc = &N.doeNativeAdapterRequestDevice },
    .{ .symbol = "wgpuAdapterRelease", .proc = &N.doeNativeAdapterRelease },
    .{ .symbol = "wgpuDeviceAddRef", .proc = &N.doeNativeDeviceAddRef },
    .{ .symbol = "wgpuDeviceRelease", .proc = &N.doeNativeDeviceRelease },
    .{ .symbol = "wgpuDeviceGetAdapter", .proc = &N.doeNativeDeviceGetAdapter },
    .{ .symbol = "wgpuDeviceGetQueue", .proc = &N.doeNativeDeviceGetQueue },
    .{ .symbol = "wgpuDeviceCreateBuffer", .proc = &N.doeNativeDeviceCreateBuffer },
    .{ .symbol = "wgpuBufferRelease", .proc = &N.doeNativeBufferRelease },
    .{ .symbol = "wgpuBufferUnmap", .proc = &N.doeNativeBufferUnmap },
    .{ .symbol = "wgpuBufferMapAsync", .proc = &N.doeNativeBufferMapAsync },
    .{ .symbol = "wgpuBufferGetConstMappedRange", .proc = &N.doeNativeBufferGetConstMappedRange },
    .{ .symbol = "wgpuBufferGetMappedRange", .proc = &N.doeNativeBufferGetMappedRange },
    .{ .symbol = "wgpuDeviceCreateShaderModule", .proc = &N.doeNativeDeviceCreateShaderModule },
    .{ .symbol = "wgpuShaderModuleRelease", .proc = &N.doeNativeShaderModuleRelease },
    .{ .symbol = "wgpuDeviceCreateComputePipeline", .proc = &N.doeNativeDeviceCreateComputePipeline },
    .{ .symbol = "wgpuComputePipelineGetBindGroupLayout", .proc = &N.doeNativeComputePipelineGetBindGroupLayout },
    .{ .symbol = "wgpuComputePipelineRelease", .proc = &N.doeNativeComputePipelineRelease },
    .{ .symbol = "wgpuDeviceCreateBindGroupLayout", .proc = &N.doeNativeDeviceCreateBindGroupLayout },
    .{ .symbol = "wgpuBindGroupLayoutRelease", .proc = &N.doeNativeBindGroupLayoutRelease },
    .{ .symbol = "wgpuDeviceCreateBindGroup", .proc = &N.doeNativeDeviceCreateBindGroup },
    .{ .symbol = "wgpuBindGroupRelease", .proc = &N.doeNativeBindGroupRelease },
    .{ .symbol = "wgpuDeviceCreatePipelineLayout", .proc = &N.doeNativeDeviceCreatePipelineLayout },
    .{ .symbol = "wgpuPipelineLayoutRelease", .proc = &N.doeNativePipelineLayoutRelease },
    .{ .symbol = "wgpuDeviceCreateCommandEncoder", .proc = &N.doeNativeDeviceCreateCommandEncoder },
    .{ .symbol = "wgpuCommandEncoderRelease", .proc = &N.doeNativeCommandEncoderRelease },
    .{ .symbol = "wgpuCommandEncoderBeginComputePass", .proc = &N.doeNativeCommandEncoderBeginComputePass },
    .{ .symbol = "wgpuComputePassEncoderSetPipeline", .proc = &N.doeNativeComputePassSetPipeline },
    .{ .symbol = "wgpuComputePassEncoderSetBindGroup", .proc = &N.doeNativeComputePassSetBindGroup },
    .{ .symbol = "wgpuComputePassEncoderDispatchWorkgroups", .proc = &N.doeNativeComputePassDispatch },
    .{ .symbol = "wgpuComputePassEncoderEnd", .proc = &N.doeNativeComputePassEnd },
    .{ .symbol = "wgpuComputePassEncoderRelease", .proc = &N.doeNativeComputePassRelease },
    .{ .symbol = "wgpuComputePassEncoderDispatchWorkgroupsIndirect", .proc = &N.doeNativeComputePassDispatchIndirect },
    .{ .symbol = "wgpuComputePassEncoderInsertDebugMarker", .proc = &N.doeNativeComputePassInsertDebugMarker },
    .{ .symbol = "wgpuComputePassEncoderPushDebugGroup", .proc = &N.doeNativeComputePassPushDebugGroup },
    .{ .symbol = "wgpuComputePassEncoderPopDebugGroup", .proc = &N.doeNativeComputePassPopDebugGroup },
    .{ .symbol = "wgpuCommandEncoderCopyBufferToBuffer", .proc = &N.doeNativeCopyBufferToBuffer },
    .{ .symbol = "wgpuCommandEncoderCopyBufferToTexture", .proc = &dropin_ext_b.doeAbiBridgeCopyBufferToTexture },
    .{ .symbol = "wgpuCommandEncoderCopyTextureToBuffer", .proc = &dropin_ext_b.doeAbiBridgeCopyTextureToBuffer },
    .{ .symbol = "wgpuCommandEncoderCopyTextureToTexture", .proc = &dropin_ext_b.doeAbiBridgeCopyTextureToTexture },
    .{ .symbol = "wgpuCommandEncoderFinish", .proc = &N.doeNativeCommandEncoderFinish },
    .{ .symbol = "wgpuCommandBufferRelease", .proc = &N.doeNativeCommandBufferRelease },
    .{ .symbol = "wgpuQueueAddRef", .proc = &N.doeNativeQueueAddRef },
    .{ .symbol = "wgpuQueueSubmit", .proc = &N.doeNativeQueueSubmit },
    .{ .symbol = "wgpuQueueWriteBuffer", .proc = &N.doeNativeQueueWriteBuffer },
    .{ .symbol = "wgpuQueueWriteTexture", .proc = &dropin_ext_c.doeAbiBridgeQueueWriteTexture },
    .{ .symbol = "wgpuQueueRelease", .proc = &N.doeNativeQueueRelease },
    .{ .symbol = "wgpuQueueOnSubmittedWorkDone", .proc = &N.doeNativeQueueOnSubmittedWorkDone },
    .{ .symbol = "wgpuQueueCopyExternalImageToTexture", .proc = &N.doeNativeQueueCopyExternalImageToTexture },
    .{ .symbol = "wgpuQueueCopyTextureForBrowser", .proc = &dropin_ext_c.wgpuQueueCopyTextureForBrowser },
    .{ .symbol = "wgpuQueueCopyExternalTextureForBrowser", .proc = &dropin_ext_c.wgpuQueueCopyExternalTextureForBrowser },
    .{ .symbol = "wgpuAdapterHasFeature", .proc = &N.doeNativeAdapterHasFeature },
    .{ .symbol = "wgpuDeviceHasFeature", .proc = &N.doeNativeDeviceHasFeature },
    .{ .symbol = "wgpuDeviceGetLimits", .proc = &N.doeNativeDeviceGetLimits },
    .{ .symbol = "wgpuAdapterGetLimits", .proc = &N.doeNativeAdapterGetLimits },
    .{ .symbol = "wgpuQuerySetDestroy", .proc = &N.doeNativeQuerySetDestroy },
    .{ .symbol = "wgpuQuerySetRelease", .proc = &N.doeNativeQuerySetRelease },
    .{ .symbol = "wgpuQuerySetGetCount", .proc = &N.doeNativeQuerySetGetCount },
    .{ .symbol = "wgpuQuerySetGetType", .proc = &N.doeNativeQuerySetGetType },
    .{ .symbol = "wgpuCommandEncoderWriteTimestamp", .proc = &N.doeNativeCommandEncoderWriteTimestamp },
    .{ .symbol = "wgpuCommandEncoderResolveQuerySet", .proc = &N.doeNativeCommandEncoderResolveQuerySet },
    .{ .symbol = "wgpuDevicePushErrorScope", .proc = &N.doeNativeDevicePushErrorScope },
};

const HEADLESS_PROC_ENTRIES = .{
    .{ .symbol = "wgpuDeviceCreateTexture", .proc = &N.doeNativeDeviceCreateTexture },
    .{ .symbol = "wgpuDeviceValidateTextureDescriptor", .proc = &N.doeNativeDeviceValidateTextureDescriptor },
    .{ .symbol = "wgpuTextureCreateView", .proc = &N.doeNativeTextureCreateView },
    .{ .symbol = "wgpuTextureDestroy", .proc = &N.doeNativeTextureDestroy },
    .{ .symbol = "wgpuTextureRelease", .proc = &N.doeNativeTextureRelease },
    .{ .symbol = "wgpuTextureViewRelease", .proc = &N.doeNativeTextureViewRelease },
    .{ .symbol = "wgpuDeviceCreateRenderPipeline", .proc = &N.doeNativeDeviceCreateRenderPipeline },
    .{ .symbol = "wgpuRenderPipelineGetBindGroupLayout", .proc = &N.doeNativeRenderPipelineGetBindGroupLayout },
    .{ .symbol = "wgpuRenderPipelineRelease", .proc = &N.doeNativeRenderPipelineRelease },
    .{ .symbol = "wgpuCommandEncoderBeginRenderPass", .proc = &N.doeNativeCommandEncoderBeginRenderPass },
    .{ .symbol = "wgpuRenderPassEncoderSetPipeline", .proc = &N.doeNativeRenderPassSetPipeline },
    .{ .symbol = "wgpuRenderPassEncoderSetBindGroup", .proc = &N.doeNativeRenderPassSetBindGroup },
    .{ .symbol = "wgpuRenderPassEncoderSetVertexBuffer", .proc = &N.doeNativeRenderPassSetVertexBuffer },
    .{ .symbol = "wgpuRenderPassEncoderSetIndexBuffer", .proc = &N.doeNativeRenderPassSetIndexBuffer },
    .{ .symbol = "wgpuRenderPassEncoderDraw", .proc = &N.doeNativeRenderPassDraw },
    .{ .symbol = "wgpuRenderPassEncoderDrawIndexed", .proc = &N.doeNativeRenderPassDrawIndexed },
    .{ .symbol = "wgpuRenderPassEncoderDrawIndirect", .proc = &N.doeNativeRenderPassDrawIndirect },
    .{ .symbol = "wgpuRenderPassEncoderDrawIndexedIndirect", .proc = &N.doeNativeRenderPassDrawIndexedIndirect },
    .{ .symbol = "wgpuRenderPassEncoderEnd", .proc = &N.doeNativeRenderPassEnd },
    .{ .symbol = "wgpuRenderPassEncoderRelease", .proc = &N.doeNativeRenderPassRelease },
    .{ .symbol = "wgpuDeviceCreateSampler", .proc = &N.doeNativeDeviceCreateSampler },
    .{ .symbol = "wgpuSamplerRelease", .proc = &N.doeNativeSamplerRelease },
    .{ .symbol = "wgpuDeviceCreateRenderBundleEncoder", .proc = &N.doeNativeDeviceCreateRenderBundleEncoder },
    .{ .symbol = "wgpuRenderBundleEncoderFinish", .proc = &N.doeNativeRenderBundleEncoderFinish },
    .{ .symbol = "wgpuRenderBundleRelease", .proc = &N.doeNativeRenderBundleRelease },
    .{ .symbol = "wgpuRenderBundleEncoderRelease", .proc = &N.doeNativeRenderBundleEncoderRelease },
    .{ .symbol = "wgpuRenderBundleEncoderSetPipeline", .proc = &N.doeNativeRenderBundleEncoderSetPipeline },
    .{ .symbol = "wgpuRenderBundleEncoderSetBindGroup", .proc = &N.doeNativeRenderBundleEncoderSetBindGroup },
    .{ .symbol = "wgpuRenderBundleEncoderSetVertexBuffer", .proc = &N.doeNativeRenderBundleEncoderSetVertexBuffer },
    .{ .symbol = "wgpuRenderBundleEncoderSetIndexBuffer", .proc = &N.doeNativeRenderBundleEncoderSetIndexBuffer },
    .{ .symbol = "wgpuRenderBundleEncoderDraw", .proc = &N.doeNativeRenderBundleEncoderDraw },
    .{ .symbol = "wgpuRenderBundleEncoderDrawIndexed", .proc = &N.doeNativeRenderBundleEncoderDrawIndexed },
    .{ .symbol = "wgpuRenderBundleEncoderDrawIndirect", .proc = &N.doeNativeRenderBundleEncoderDrawIndirect },
    .{ .symbol = "wgpuRenderBundleEncoderDrawIndexedIndirect", .proc = &N.doeNativeRenderBundleEncoderDrawIndexedIndirect },
    .{ .symbol = "wgpuRenderPassEncoderExecuteBundles", .proc = &N.doeNativeRenderPassExecuteBundles },
    .{ .symbol = "wgpuRenderPassEncoderBeginOcclusionQuery", .proc = &N.doeNativeRenderPassBeginOcclusionQuery },
    .{ .symbol = "wgpuRenderPassEncoderEndOcclusionQuery", .proc = &N.doeNativeRenderPassEndOcclusionQuery },
};

const FULL_PROC_ENTRIES = .{
    .{ .symbol = "wgpuInstanceCreateSurface", .proc = &N.doeAbiBridgeInstanceCreateSurface },
    .{ .symbol = "wgpuSurfaceConfigure", .proc = &N.doeAbiBridgeSurfaceConfigure },
    .{ .symbol = "wgpuSurfaceGetCurrentTexture", .proc = &N.doeAbiBridgeSurfaceGetCurrentTexture },
    .{ .symbol = "wgpuSurfacePresent", .proc = &N.doeAbiBridgeSurfacePresent },
    .{ .symbol = "wgpuSurfaceUnconfigure", .proc = &N.doeNativeSurfaceUnconfigure },
    .{ .symbol = "wgpuSurfaceRelease", .proc = &N.doeNativeSurfaceRelease },
    .{ .symbol = "wgpuSurfaceGetCapabilities", .proc = &N.doeNativeSurfaceGetCapabilities },
    .{ .symbol = "wgpuSurfaceCapabilitiesFreeMembers", .proc = &N.doeNativeSurfaceCapabilitiesFreeMembers },
};

fn resolveEntryProc(comptime FnType: type, comptime entry: anytype) FnType {
    if (@TypeOf(entry.proc) != FnType) {
        @compileError(std.fmt.comptimePrint(
            "drop-in proc manifest type mismatch for {s}: expected {s}, found {s}",
            .{
                entry.symbol,
                @typeName(FnType),
                @typeName(@TypeOf(entry.proc)),
            },
        ));
    }
    return entry.proc;
}

fn resolveFromEntries(comptime FnType: type, comptime symbol_name: [:0]const u8, comptime entries: anytype) ?FnType {
    inline for (entries) |entry| {
        if (comptime std.mem.eql(u8, symbol_name, entry.symbol)) {
            return resolveEntryProc(FnType, entry);
        }
    }
    return null;
}

fn hasSymbolInEntries(symbol_name: []const u8, comptime entries: anytype) bool {
    inline for (entries) |entry| {
        if (std.mem.eql(u8, symbol_name, entry.symbol)) {
            return true;
        }
    }
    return false;
}

fn assertUniqueEntryGroups(comptime groups: anytype) void {
    inline for (groups, 0..) |group_a, group_a_index| {
        inline for (group_a, 0..) |entry_a, entry_a_index| {
            inline for (groups, 0..) |group_b, group_b_index| {
                inline for (group_b, 0..) |entry_b, entry_b_index| {
                    if (group_a_index > group_b_index) continue;
                    if (group_a_index == group_b_index and entry_a_index >= entry_b_index) continue;
                    if (std.mem.eql(u8, entry_a.symbol, entry_b.symbol)) {
                        @compileError(std.fmt.comptimePrint(
                            "duplicate drop-in proc manifest symbol: {s}",
                            .{entry_a.symbol},
                        ));
                    }
                }
            }
        }
    }
}

comptime {
    @setEvalBranchQuota(100_000);
    const active_groups = switch (TIER) {
        .compute => .{CORE_PROC_ENTRIES},
        .headless => .{ CORE_PROC_ENTRIES, HEADLESS_PROC_ENTRIES },
        .full => .{ CORE_PROC_ENTRIES, HEADLESS_PROC_ENTRIES, FULL_PROC_ENTRIES },
    };
    assertUniqueEntryGroups(active_groups);
}

pub fn resolveDoeNativeProc(comptime FnType: type, comptime symbol_name: [:0]const u8) ?FnType {
    if (resolveFromEntries(FnType, symbol_name, CORE_PROC_ENTRIES)) |proc| {
        return proc;
    }
    if (comptime TIER != .compute) {
        if (resolveFromEntries(FnType, symbol_name, HEADLESS_PROC_ENTRIES)) |proc| {
            return proc;
        }
    }
    if (comptime TIER == .full) {
        if (resolveFromEntries(FnType, symbol_name, FULL_PROC_ENTRIES)) |proc| {
            return proc;
        }
    }
    return null;
}

pub fn manifestOwnerForSymbol(symbol_name: []const u8) ?dropin_symbol_ownership.SymbolOwner {
    if (hasSymbolInEntries(symbol_name, CORE_PROC_ENTRIES)) return .shared;
    if (comptime TIER != .compute) {
        if (hasSymbolInEntries(symbol_name, HEADLESS_PROC_ENTRIES)) return .shared;
    }
    if (comptime TIER == .full) {
        if (hasSymbolInEntries(symbol_name, FULL_PROC_ENTRIES)) return .shared;
    }
    return null;
}

test "manifest owner reports shared ownership for mapped native procs" {
    try std.testing.expectEqual(
        dropin_symbol_ownership.SymbolOwner.shared,
        manifestOwnerForSymbol("wgpuCreateInstance").?,
    );
    try std.testing.expect(manifestOwnerForSymbol("wgpuDefinitelyMissing") == null);
}
