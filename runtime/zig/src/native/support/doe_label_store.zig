// doe_label_store.zig — Global label store for WebGPU object debug labels.
// Maps opaque object handles (pointer addresses) to heap-copied label strings.
// Thread-safety: single-threaded (Doe runtime is single-threaded per device).

const std = @import("std");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const alloc = gpa.allocator();

// Label storage: pointer address -> heap-allocated label copy.
var labels: std.AutoHashMapUnmanaged(usize, []const u8) = .{};

/// Store a label for the given object handle. Overwrites any existing label.
/// The label string is copied to the heap; the caller's memory is not retained.
pub fn set(handle: ?*anyopaque, data: ?[*]const u8, len: usize) void {
    const key = @intFromPtr(handle orelse return);
    if (len == 0 or data == null) return;
    // Remove old label if present.
    if (labels.fetchRemove(key)) |old| {
        alloc.free(old.value);
    }
    const copy = alloc.alloc(u8, len) catch return;
    @memcpy(copy, data.?[0..len]);
    labels.put(alloc, key, copy) catch {
        alloc.free(copy);
    };
}

/// Retrieve the label for the given object handle.
/// Returns the label slice, or an empty slice if no label is set.
pub fn get(handle: ?*anyopaque) []const u8 {
    const key = @intFromPtr(handle orelse return "");
    return labels.get(key) orelse "";
}

/// Remove the label for the given object handle (call on object release).
pub fn remove(handle: ?*anyopaque) void {
    const key = @intFromPtr(handle orelse return);
    if (labels.fetchRemove(key)) |old| {
        alloc.free(old.value);
    }
}

// ============================================================
// C ABI exports
// ============================================================

/// Set the debug label on any Doe GPU object handle.
pub export fn doeNativeObjectSetLabel(handle: ?*anyopaque, data: ?[*]const u8, len: usize) callconv(.c) void {
    set(handle, data, len);
}

/// Get the debug label for any Doe GPU object handle.
/// Returns the label pointer and writes the length to out_len.
/// The returned pointer is valid until the label is changed or the object is released.
pub export fn doeNativeObjectGetLabel(handle: ?*anyopaque, out_len: ?*usize) callconv(.c) ?[*]const u8 {
    const label = get(handle);
    if (out_len) |p| p.* = label.len;
    if (label.len == 0) return null;
    return label.ptr;
}

/// Remove the debug label for any Doe GPU object handle.
pub export fn doeNativeObjectRemoveLabel(handle: ?*anyopaque) callconv(.c) void {
    remove(handle);
}
