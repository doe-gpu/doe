const std = @import("std");
const analysis = @import("analysis.zig");
const ir = @import("../ir/ir.zig");
const binding_contract = @import("../../../contracts/binding.zig");

pub const MAX_BINDINGS: usize = binding_contract.MAX_SHADER_BINDINGS;
pub const BindingKind = binding_contract.ShaderKind;

pub const BindingMeta = struct {
    group: u32,
    binding: u32,
    kind: BindingKind,
    addr_space: ir.AddressSpace,
    access: ir.AccessMode,
};

fn bindingMeta(module_ir: *const ir.Module, global: ir.Global) BindingMeta {
    const binding_type, const binding_access = switch (module_ir.types.get(global.ty)) {
        .sampler, .sampler_comparison => .{ BindingKind.sampler, ir.AccessMode.read },
        .texture_2d, .texture_2d_array, .texture_cube, .texture_multisampled_2d, .texture_depth_2d, .texture_depth_cube, .texture_3d => .{ BindingKind.texture, ir.AccessMode.read },
        .storage_texture_2d => |storage_tex| .{ BindingKind.storage_texture, storage_tex.access },
        else => .{ BindingKind.buffer, global.access orelse switch (global.addr_space orelse .private) {
            .uniform => ir.AccessMode.read,
            .storage => ir.AccessMode.read_write,
            else => ir.AccessMode.read,
        } },
    };
    return .{
        .group = global.binding.?.group,
        .binding = global.binding.?.binding,
        .kind = binding_type,
        .addr_space = global.addr_space orelse .handle,
        .access = binding_access,
    };
}

fn markFunctionResources(module_ir: *const ir.Module, function_id: usize, visited: []bool, globals: []bool) void {
    if (visited[function_id]) return;
    visited[function_id] = true;
    const function = module_ir.functions.items[function_id];
    for (function.exprs.items) |expr| switch (expr.data) {
        .global_ref => |global_id| globals[global_id] = true,
        .call => |call| if (call.kind == .user) {
            for (module_ir.functions.items, 0..) |candidate, candidate_id| {
                if (std.mem.eql(u8, candidate.name, call.name)) {
                    markFunctionResources(module_ir, candidate_id, visited, globals);
                    break;
                }
            }
        },
        else => {},
    };
}

pub fn extractBindingsForEntryPoint(allocator: std.mem.Allocator, wgsl: []const u8, entry_point: []const u8, out: []BindingMeta) analysis.TranslateError!usize {
    var module_ir = try analysis.analyzeToIr(allocator, wgsl);
    defer module_ir.deinit();
    const visited = try allocator.alloc(bool, module_ir.functions.items.len);
    defer allocator.free(visited);
    @memset(visited, false);
    const globals = try allocator.alloc(bool, module_ir.globals.items.len);
    defer allocator.free(globals);
    @memset(globals, false);

    var found_entry_point = false;
    for (module_ir.functions.items, 0..) |function, function_id| {
        if (std.mem.eql(u8, function.name, entry_point)) {
            found_entry_point = true;
            markFunctionResources(&module_ir, function_id, visited, globals);
            break;
        }
    }
    if (!found_entry_point) return analysis.TranslateError.UnknownIdentifier;

    var count: usize = 0;
    for (module_ir.globals.items, globals) |global, used| {
        if (!used or global.binding == null) continue;
        if (count >= out.len) break;
        out[count] = bindingMeta(&module_ir, global);
        count += 1;
    }
    return count;
}

pub fn extractBindings(allocator: std.mem.Allocator, wgsl: []const u8, out: []BindingMeta) analysis.TranslateError!usize {
    var module_ir = try analysis.analyzeToIr(allocator, wgsl);
    defer module_ir.deinit();
    var count: usize = 0;
    for (module_ir.globals.items) |global| {
        if (global.binding == null) continue;
        if (count >= out.len) break;
        out[count] = bindingMeta(&module_ir, global);
        count += 1;
    }
    return count;
}
