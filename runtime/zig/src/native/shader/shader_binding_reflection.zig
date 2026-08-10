//! One-way WGSL binding reflection shared by shader creation and native
//! backend pipeline preparation.

const std = @import("std");
const wgsl_analysis = @import("../../compiler/wgsl/pipeline/analysis.zig");
const wgsl_bindings = @import("../../compiler/wgsl/pipeline/binding_reflection.zig");
const native_types = @import("../support/doe_native_object_types.zig");
const native_shared = @import("../support/doe_native_shared_types.zig");
const native_helpers = @import("../support/doe_native_object_helpers.zig");

const alloc = native_helpers.alloc;
const DoeShaderModule = native_types.DoeShaderModule;

pub fn ensureShaderBindings(sm: *DoeShaderModule) void {
    if (sm.bindings_ready) return;
    const wgsl = sm.wgsl_source orelse return;
    sm.bindings_ready = true;
    sm.binding_count = 0;
    var bind_meta: [native_shared.MAX_SHADER_BINDINGS]wgsl_bindings.BindingMeta = undefined;
    const bind_count = wgsl_bindings.extractBindings(alloc, wgsl, &bind_meta) catch |bind_err| blk: {
        std.log.warn("doe: createShaderModule: lazy binding extraction failed ({s}); proceeding with 0 bindings", .{@errorName(bind_err)});
        setCompilerWarning(sm, "binding extraction failed after successful shader compilation");
        break :blk 0;
    };
    for (0..bind_count) |i| {
        sm.bindings[i] = .{
            .group = bind_meta[i].group,
            .binding = bind_meta[i].binding,
            .kind = @intFromEnum(bind_meta[i].kind),
            .addr_space = @intFromEnum(bind_meta[i].addr_space),
            .access = @intFromEnum(bind_meta[i].access),
        };
    }
    sm.binding_count = @intCast(bind_count);
}

fn setCompilerWarning(sm: *DoeShaderModule, fallback_message: []const u8) void {
    const detail = wgsl_analysis.lastErrorMessage();
    const message = if (detail.len > 0) detail else fallback_message;
    if (sm.compilation_message) |existing| alloc.free(existing);
    sm.compilation_message = alloc.dupe(u8, message) catch null;
    sm.compilation_message_kind = .warning;
    sm.compilation_message_line = wgsl_analysis.lastErrorLine();
    sm.compilation_message_column = wgsl_analysis.lastErrorColumn();
}
