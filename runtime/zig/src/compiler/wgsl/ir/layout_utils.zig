// layout_utils.zig — Struct layout computation for storage address space.
//
// Shared by MSL and HLSL emitters for computing byte offsets, sizes, and
// alignments of struct fields in storage (std430-compatible) layout.
// Used by arrayLength lowering when the runtime-sized array is a struct
// member rather than a direct global.

const ir = @import("ir.zig");

/// Walk a chain of member/load expressions to find the root global_ref index.
pub fn resolve_member_global(function: ir.Function, expr_id: ir.ExprId) ?ir.GlobalId {
    var current = expr_id;
    while (true) {
        switch (function.exprs.items[current].data) {
            .global_ref => |index| return index,
            .member => |m| current = m.base,
            .load => |inner| current = inner,
            else => return null,
        }
    }
}

/// Compute the byte offset of a field in a struct using storage address space
/// layout rules (std430-compatible: natural alignment, no vec3 rounding).
pub fn struct_field_offset(module: *const ir.Module, struct_def: ir.StructDef, target_field: u32) u32 {
    var offset: u32 = 0;
    for (struct_def.fields.items[0..target_field]) |field| {
        const field_align = type_alignment(module, field.ty);
        offset = round_up(offset, field_align);
        offset += type_size(module, field.ty);
    }
    const target_align = type_alignment(module, struct_def.fields.items[target_field].ty);
    return round_up(offset, target_align);
}

pub fn round_up(value: u32, alignment: u32) u32 {
    if (alignment <= 1) return value;
    const remainder = value % alignment;
    if (remainder == 0) return value;
    return value + alignment - remainder;
}

/// std430 vector/matrix lane-count alignment multiplier: vec2→2, vec3/vec4→4.
fn lane_align(count: u32) u32 {
    return switch (count) {
        2 => 2,
        3, 4 => 4,
        else => 1,
    };
}

/// Return the natural alignment of a type for storage address space layout.
pub fn type_alignment(module: *const ir.Module, ty: ir.TypeId) u32 {
    return switch (module.types.get(ty)) {
        .scalar => |s| switch (s) {
            .f16 => 2,
            .bool, .i32, .u32, .f32, .abstract_int, .abstract_float => 4,
            else => 4,
        },
        .vector => |v| type_alignment(module, v.elem) * lane_align(v.len),
        .matrix => |m| type_alignment(module, m.elem) * lane_align(m.rows),
        .array => |a| type_alignment(module, a.elem),
        .atomic => |inner| type_alignment(module, inner),
        .struct_ => |sid| blk: {
            var max_align: u32 = 1;
            for (module.structs.items[sid].fields.items) |field| {
                max_align = @max(max_align, type_alignment(module, field.ty));
            }
            break :blk max_align;
        },
        else => 4,
    };
}

/// Return the byte size of a type for storage address space layout.
pub fn type_size(module: *const ir.Module, ty: ir.TypeId) u32 {
    return switch (module.types.get(ty)) {
        .scalar => |s| switch (s) {
            .f16 => 2,
            .bool, .i32, .u32, .f32, .abstract_int, .abstract_float => 4,
            else => 4,
        },
        .vector => |v| type_size(module, v.elem) * v.len,
        .matrix => |m| blk: {
            const col_size = type_size(module, m.elem) * m.rows;
            const col_align = type_alignment(module, m.elem) * lane_align(m.rows);
            const stride = round_up(col_size, col_align);
            break :blk stride * m.columns;
        },
        .array => |a| blk: {
            if (a.len) |len| {
                const elem_size = type_size(module, a.elem);
                const elem_align = type_alignment(module, a.elem);
                const stride = round_up(elem_size, elem_align);
                break :blk stride * len;
            }
            break :blk 0; // runtime-sized array has no fixed size
        },
        .atomic => |inner| type_size(module, inner),
        .struct_ => |sid| blk: {
            var offset: u32 = 0;
            var max_align: u32 = 1;
            for (module.structs.items[sid].fields.items) |field| {
                const field_align = type_alignment(module, field.ty);
                offset = round_up(offset, field_align);
                offset += type_size(module, field.ty);
                max_align = @max(max_align, field_align);
            }
            break :blk round_up(offset, max_align);
        },
        else => 4,
    };
}
