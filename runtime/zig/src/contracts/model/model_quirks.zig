const policy = @import("model_policy.zig");

pub const UseTemporaryBufferAction = struct {
    alignment_bytes: u32,
};

pub const UseTemporaryRenderTextureAction = struct {
    min_mip_level: u32,
};

pub const ToggleAction = struct {
    toggle_name: []const u8,
};

pub const QuirkAction = union(enum) {
    use_temporary_buffer: UseTemporaryBufferAction,
    use_temporary_render_texture: UseTemporaryRenderTextureAction,
    toggle: ToggleAction,
    no_op: void,
};

pub const MatchSpec = struct {
    vendor: []const u8,
    api: policy.Api,
    device_family: ?[]const u8 = null,
    driver_range: ?[]const u8 = null,
};

pub const Provenance = struct {
    source_repo: []const u8,
    source_path: []const u8,
    source_commit: []const u8,
    observed_at: []const u8,
};

pub const Quirk = struct {
    schema_version: policy.SchemaVersion,
    quirk_id: []const u8,
    scope: policy.Scope,
    match_spec: MatchSpec,
    action: QuirkAction,
    safety_class: policy.SafetyClass,
    verification_mode: policy.VerificationMode,
    proof_level: policy.ProofLevel,
    provenance: Provenance,
    priority: u32 = 0,
};
