const std = @import("std");
const artifact_meta = @import("../../contracts/artifact.zig");

pub fn persist_value(storage: []u8, len: *usize, value: []const u8) void {
    if (value.len > storage.len) {
        len.* = 0;
        return;
    }
    std.mem.copyForwards(u8, storage[0..value.len], value);
    len.* = value.len;
}

pub fn manifest_signature_matches(
    last_meta: ?artifact_meta.ArtifactMeta,
    last_module: []const u8,
    last_status_code: []const u8,
    module: []const u8,
    meta: artifact_meta.ArtifactMeta,
    status_code: []const u8,
) bool {
    const persisted_meta = last_meta orelse return false;
    if (persisted_meta.backend_kind != meta.backend_kind or
        persisted_meta.timing_source != meta.timing_source or
        persisted_meta.comparability != meta.comparability)
    {
        return false;
    }
    if (!std.mem.eql(u8, last_module, module)) return false;
    if (!std.mem.eql(u8, last_status_code, status_code)) return false;
    return true;
}

pub fn persist_manifest_signature(
    last_meta: *?artifact_meta.ArtifactMeta,
    module_storage: []u8,
    module_len: *usize,
    status_storage: []u8,
    status_len: *usize,
    module: []const u8,
    meta: artifact_meta.ArtifactMeta,
    status_code: []const u8,
) void {
    last_meta.* = meta;
    persist_value(module_storage, module_len, module);
    persist_value(status_storage, status_len, status_code);
}

test "persist_value stores value and sets length" {
    var storage: [64]u8 = undefined;
    var len: usize = 0;
    persist_value(&storage, &len, "hello");
    try std.testing.expectEqual(@as(usize, 5), len);
    try std.testing.expect(std.mem.eql(u8, storage[0..len], "hello"));
}

test "persist_value truncates when value exceeds storage" {
    var storage: [4]u8 = undefined;
    var len: usize = 99;
    persist_value(&storage, &len, "too long for buffer");
    try std.testing.expectEqual(@as(usize, 0), len);
}

test "manifest_signature_matches returns false when no last meta" {
    const meta = artifact_meta.ArtifactMeta{
        .backend_kind = .native_metal,
        .timing_source = .gpu_timestamp,
        .comparability = .strict,
    };
    try std.testing.expect(!manifest_signature_matches(
        null,
        "mod",
        "ok",
        "mod",
        meta,
        "ok",
    ));
}

test "manifest_signature_matches returns false on module mismatch" {
    const meta = artifact_meta.ArtifactMeta{
        .backend_kind = .native_metal,
        .timing_source = .gpu_timestamp,
        .comparability = .strict,
    };
    try std.testing.expect(!manifest_signature_matches(
        meta,
        "module_a",
        "ok",
        "module_b",
        meta,
        "ok",
    ));
}

test "manifest_signature_matches returns true on full match" {
    const meta = artifact_meta.ArtifactMeta{
        .backend_kind = .native_vulkan,
        .timing_source = .cpu_submit_wait,
        .comparability = .directional,
    };
    try std.testing.expect(manifest_signature_matches(
        meta,
        "my_module",
        "success",
        "my_module",
        meta,
        "success",
    ));
}

test "persist_manifest_signature round-trips with manifest_signature_matches" {
    const meta = artifact_meta.ArtifactMeta{
        .backend_kind = .native_metal,
        .timing_source = .gpu_timestamp,
        .comparability = .strict,
    };
    var last_meta: ?artifact_meta.ArtifactMeta = null;
    var module_storage: [128]u8 = undefined;
    var module_len: usize = 0;
    var status_storage: [128]u8 = undefined;
    var status_len: usize = 0;

    persist_manifest_signature(
        &last_meta,
        &module_storage,
        &module_len,
        &status_storage,
        &status_len,
        "test_module",
        meta,
        "ok",
    );

    try std.testing.expect(manifest_signature_matches(
        last_meta,
        module_storage[0..module_len],
        status_storage[0..status_len],
        "test_module",
        meta,
        "ok",
    ));

    // Different module should not match
    try std.testing.expect(!manifest_signature_matches(
        last_meta,
        module_storage[0..module_len],
        status_storage[0..status_len],
        "other_module",
        meta,
        "ok",
    ));
}
