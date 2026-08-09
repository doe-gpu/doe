//! Canonical semantic digest for Doe WGSL IR.
//!
//! The digest intentionally excludes allocator identity and spare container
//! capacity. It includes declaration order, field names, union tags, scalar
//! values, and the logical contents of every IR collection. This makes the
//! result stable across processes and allocation strategies while changing
//! whenever the lowered semantic program changes.

const std = @import("std");
const ir = @import("ir.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Digest = [Sha256.digest_length]u8;

pub fn compute(module: *const ir.Module) Digest {
    var hasher = Sha256.init(.{});
    hasher.update("doe-wgsl-ir-v1\x00");
    hashValue(ir.Module, &hasher, module.*);
    var output: Digest = undefined;
    hasher.final(&output);
    return output;
}

pub fn computeHex(module: *const ir.Module) [Sha256.digest_length * 2]u8 {
    return std.fmt.bytesToHex(compute(module), .lower);
}

fn frame(hasher: *Sha256, label: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, label.len, .little);
    hasher.update(&length);
    hasher.update(label);
}

fn hashInt(comptime T: type, hasher: *Sha256, value: T) void {
    const Unsigned = std.meta.Int(.unsigned, @bitSizeOf(T));
    const bits: Unsigned = @bitCast(value);
    var remaining: u128 = @intCast(bits);
    var bytes: [@sizeOf(T)]u8 = undefined;
    for (&bytes) |*byte| {
        byte.* = @truncate(remaining);
        remaining >>= 8;
    }
    hasher.update(&bytes);
}

fn hashValue(comptime T: type, hasher: *Sha256, value: T) void {
    frame(hasher, @typeName(T));
    switch (@typeInfo(T)) {
        .bool => hasher.update(if (value) "\x01" else "\x00"),
        .int => hashInt(T, hasher, value),
        .float => {
            const Bits = std.meta.Int(.unsigned, @bitSizeOf(T));
            hashInt(Bits, hasher, @as(Bits, @bitCast(value)));
        },
        .@"enum" => {
            frame(hasher, @tagName(value));
            hashInt(@TypeOf(@intFromEnum(value)), hasher, @intFromEnum(value));
        },
        .optional => |optional| {
            if (value) |present| {
                hasher.update("some");
                hashValue(optional.child, hasher, present);
            } else {
                hasher.update("none");
            }
        },
        .array => |array| {
            hashInt(usize, hasher, array.len);
            for (value) |item| hashValue(array.child, hasher, item);
        },
        .pointer => |pointer| switch (pointer.size) {
            .slice => {
                hashInt(usize, hasher, value.len);
                if (pointer.child == u8) {
                    hasher.update(value);
                } else {
                    for (value) |item| hashValue(pointer.child, hasher, item);
                }
            },
            .one => hashValue(pointer.child, hasher, value.*),
            else => @compileError("WGSL IR digest does not admit non-semantic pointer type " ++ @typeName(T)),
        },
        .@"struct" => |structure| {
            inline for (structure.fields) |field| {
                if (comptime !std.mem.eql(u8, field.name, "allocator") and
                    !std.mem.eql(u8, field.name, "capacity"))
                {
                    frame(hasher, field.name);
                    hashValue(field.type, hasher, @field(value, field.name));
                }
            }
        },
        .@"union" => |union_info| {
            const active = std.meta.activeTag(value);
            frame(hasher, @tagName(active));
            inline for (union_info.fields) |field| {
                if (active == @field(union_info.tag_type.?, field.name)) {
                    hashValue(field.type, hasher, @field(value, field.name));
                }
            }
        },
        .void => {},
        else => @compileError("WGSL IR digest has no semantic encoding for " ++ @typeName(T)),
    }
}

test "canonical IR digest is allocation independent and semantic" {
    var first = ir.Module.init(std.testing.allocator);
    defer first.deinit();
    var second = ir.Module.init(std.testing.allocator);
    defer second.deinit();
    try first.types.items.append(std.testing.allocator, .{ .scalar = .u32 });
    try second.types.items.append(std.testing.allocator, .{ .scalar = .u32 });

    try std.testing.expectEqualSlices(u8, &compute(&first), &compute(&second));
    const before = compute(&first);
    first.types.items.items[0] = .{ .scalar = .f32 };
    const after = compute(&first);
    try std.testing.expect(!std.mem.eql(u8, &before, &after));
}
