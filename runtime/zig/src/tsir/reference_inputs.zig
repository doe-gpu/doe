const std = @import("std");
const schema = @import("schema.zig");

pub fn countReadOnlyBindings(func: schema.SemanticFunction) usize {
    var count: usize = 0;
    for (func.bindings) |binding| {
        if (!binding.read_write) count += 1;
    }
    return count;
}

pub fn inputBytesForReadOnlyBinding(
    func: schema.SemanticFunction,
    inputs: []const []const u8,
    binding_index: u32,
) ?[]const u8 {
    const idx: usize = std.math.cast(usize, binding_index) orelse return null;
    if (idx >= func.bindings.len) return null;
    if (func.bindings[idx].read_write) return null;
    var input_slot: usize = 0;
    for (func.bindings[0..idx]) |binding| {
        if (!binding.read_write) input_slot += 1;
    }
    if (input_slot >= inputs.len) return null;
    return inputs[input_slot];
}
