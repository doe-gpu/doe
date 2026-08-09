const artifact_meta = @import("../../contracts/artifact.zig");
const common_errors = @import("../../contracts/execution.zig");
const shared_manifest = @import("../common/shader_artifact_manifest.zig");

const SPEC = shared_manifest.ManifestSpec{
    .backend_id = "doe_metal",
    .file_prefix = "metal",
    .stages = &.{
        .{ .stage = "sema", .hash_label = "sema" },
        .{ .stage = "ir_build", .hash_label = "ir_build", .manifest_field = "irSha256" },
        .{ .stage = "ir_validate", .hash_label = "ir_validate" },
        .{ .stage = "ir_to_msl", .hash_label = "ir_to_msl", .manifest_field = "mslSha256" },
        .{
            .stage = "msl_compile",
            .hash_label = "msl_compile",
            .implementation = .external_tool,
            .tool = "xcrun",
            .version = "32023.x",
            .args = &.{ "metal", "-std=metal3.1" },
        },
        .{
            .stage = "metallib_link",
            .hash_label = "metallib_link",
            .manifest_field = "metallibSha256",
            .implementation = .external_tool,
            .tool = "xcrun",
            .version = "32023.x",
            .args = &.{"metallib"},
        },
    },
};

pub fn manifest_path(self: anytype) ?[]const u8 {
    return shared_manifest.manifest_path(self);
}

pub fn manifest_hash(self: anytype) ?[]const u8 {
    return shared_manifest.manifest_hash(self);
}

pub fn flush_pending_artifact(self: anytype) void {
    shared_manifest.flush_pending_artifact(self, SPEC);
}

pub fn emit_shader_artifact_manifest_for_signature(
    self: anytype,
    module: []const u8,
    meta: artifact_meta.ArtifactMeta,
    status_code: []const u8,
) common_errors.BackendNativeError!void {
    return shared_manifest.emit_shader_artifact_manifest_for_signature(self, SPEC, module, meta, status_code);
}
