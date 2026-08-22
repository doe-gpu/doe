//! Application binding layout resolution.

const std = @import("std");

pub const BufferBinding = struct {
    group: u32,
    binding: u32,
    buffer_handle: u64,
    offset_bytes: u64 = 0,
    size_bytes: u64 = 0,
};

pub const BindingSet = struct {
    bindings: []const BufferBinding = &.{},
};
