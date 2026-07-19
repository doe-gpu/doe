const std = @import("std");
const build_options = @import("build_options");

pub const lean_verified: bool = build_options.lean_verified;
pub const comparability_obligations_sha256: []const u8 = build_options.comparability_obligations_sha256;
pub const lean_toolchain_ref: []const u8 = build_options.lean_toolchain_ref;
pub const lean_extract_program_sha256: []const u8 = build_options.lean_extract_program_sha256;
pub const lean_source_tree_sha256: []const u8 = build_options.lean_source_tree_sha256;
pub const generated_comparability_contract_sha256: []const u8 = build_options.generated_comparability_contract_sha256;
pub const proof_pattern_spec_sha256: []const u8 = build_options.proof_pattern_spec_sha256;
const JSON_SEARCH_BRANCH_QUOTA = 2_000_000;

const proof_json: ?[]const u8 = if (build_options.lean_verified)
    build_options.lean_proof_json
else
    null;

fn comptimeContains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.mem.eql(u8, haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

fn requireTheorem(comptime json: []const u8, comptime theorem: []const u8) void {
    if (!comptimeContains(json, theorem)) {
        @compileError("lean proof artifact: missing required theorem " ++ theorem);
    }
}

fn requireFieldValue(
    comptime json: []const u8,
    comptime key: []const u8,
    comptime value: []const u8,
    comptime context: []const u8,
) void {
    if (!comptimeContains(json, "\"" ++ key ++ "\": \"" ++ value ++ "\"")) {
        @compileError("lean proof artifact: " ++ context ++ " mismatch for field " ++ key);
    }
}

/// Validator elimination is available when -Dlean-verified=true AND the proof
/// artifact contains both the builder soundness theorem (builder_soundness)
/// and the combined redundancy theorem (ValidatorRedundant). These together
/// prove that ir_validate.validate() always returns Ok on any IR produced by
/// a sema-Ok + build-Ok pipeline, so the validate() call is a no-op and can
/// be removed from the hot path.
pub const validator_elimination_available: bool = blk: {
    if (!build_options.lean_verified) break :blk false;
    @setEvalBranchQuota(JSON_SEARCH_BRANCH_QUOTA);
    const json = proof_json.?;
    break :blk comptimeContains(json, "\"builder_soundness\"") and
        comptimeContains(json, "\"ValidatorRedundant\"");
};

/// Bounds elimination is available when -Dlean-verified=true AND the proof
/// artifact contains both the core theorem (gid_inbounds_when_dispatch_fits)
/// and the connecting theorem (clamp_noop_when_inbounds). These together
/// prove that min(gid, len-1) = gid when dispatch fits, so the clamp is a
/// no-op and can be elided.
pub const bounds_elimination_available: bool = blk: {
    if (!build_options.lean_verified) break :blk false;
    @setEvalBranchQuota(JSON_SEARCH_BRANCH_QUOTA);
    const json = proof_json.?;
    break :blk comptimeContains(json, "\"gid_inbounds_when_dispatch_fits\"") and
        comptimeContains(json, "\"clamp_noop_when_inbounds\"") and
        comptimeContains(json, "\"boundsEliminations\"");
};

/// Access pattern covered by a proven bounds elimination theorem.
pub const BoundsPattern = enum {
    /// buf[global_invocation_id.x] on a runtime-sized storage buffer.
    /// Theorem: gid_inbounds_when_dispatch_fits
    /// Precondition: workgroup_size.x * num_workgroups.x <= arrayLength(&buf)
    gid_1d_storage_buffer,

    /// buf[global_invocation_id.x + k] on a runtime-sized storage buffer.
    /// Theorem: gid_plus_offset_inbounds_when_dispatch_fits
    /// Precondition: workgroup_size.x * num_workgroups.x + k <= arrayLength(&buf)
    gid_1d_storage_buffer_offset,

    /// buf[global_invocation_id.x * stride + offset] on a runtime-sized
    /// storage buffer, where stride is a positive compile-time constant.
    /// Theorem: gid_stride_offset_matcher_contract_sound
    /// Precondition: workgroup_size.x * num_workgroups.x * stride + offset <= arrayLength(&buf)
    gid_1d_storage_buffer_stride,

    /// buf[global_invocation_id.x + i + offset] on a runtime-sized storage
    /// buffer, where `i` is the induction variable of a canonical
    /// `for (var i = 0; i < limit; i = i + 1)` loop.
    /// Theorem: gid_plus_bounded_loop_index_inbounds_when_dispatch_fits
    /// Precondition: workgroup_size.x * num_workgroups.x + limit + offset <= arrayLength(&buf)
    gid_1d_storage_buffer_loop_offset,

    /// buf[global_invocation_id.x * gid_stride + i * loop_stride + offset]
    /// on a runtime-sized storage buffer, where `i` is the induction variable
    /// of a supported counted loop and both scales are positive compile-time
    /// constants.
    /// Theorem: gid_affine_plus_scaled_loop_index_inbounds_when_dispatch_fits
    /// Precondition: workgroup_size.x * num_workgroups.x * gid_stride +
    ///               limit * loop_stride + offset <= arrayLength(&buf)
    gid_1d_storage_buffer_loop_affine,

    /// buf[i * loop_stride + offset] on a runtime-sized storage buffer with
    /// no gid term, where `i` is the induction variable of a supported
    /// counted loop and `loop_stride` is a positive compile-time constant.
    /// Covers the matvec `vectorData[col]` inner-loop load shape.
    /// Theorem: loop_affine_matcher_contract_sound_tight
    /// Precondition: (limit - 1) * loop_stride + offset + 1 <= arrayLength(&buf)
    loop_1d_storage_buffer_affine,

    /// buf[(global_invocation_id.x / tile_width) * tile_stride +
    ///     (global_invocation_id.x % tile_width) + offset] on a runtime-sized
    /// storage buffer, where tile_width and tile_stride are positive
    /// compile-time constants and tile_width <= tile_stride.
    /// Theorem: gid_tiled_index_plus_offset_inbounds_when_dispatch_fits
    /// Precondition: (((workgroup_size.x * num_workgroups.x - 1) / tile_width) + 1) *
    ///               tile_stride + offset <= arrayLength(&buf)
    gid_1d_storage_buffer_tiled,

    /// buf[gid.y * width + gid.x] on a runtime-sized storage buffer.
    /// Theorem: flat_index_2d_inbounds
    /// Precondition: ws.x * nwg.x <= width AND ws.y * nwg.y <= height
    ///               AND width * height <= arrayLength(&buf)
    gid_2d_flat_storage_buffer,

    /// buf[gid.y * width + gid.x + offset] on a runtime-sized storage buffer.
    /// Theorem: flat_index_2d_plus_offset_inbounds
    /// Precondition: ws.x * nwg.x <= width AND ws.y * nwg.y <= height
    ///               AND width * height + offset <= arrayLength(&buf)
    gid_2d_flat_storage_buffer_offset,

    /// buf[gid.z * (dispatch_height * dispatch_width) + gid.y * dispatch_width
    ///     + gid.x] on a runtime-sized storage buffer.
    /// Theorem: flat_index_3d_inbounds
    gid_3d_flat_storage_buffer,

    /// buf[gid.z * (dispatch_height * dispatch_width) + gid.y * dispatch_width
    ///     + gid.x + offset] on a runtime-sized storage buffer.
    /// Theorem: flat_index_3d_plus_offset_inbounds
    gid_3d_flat_storage_buffer_offset,

    /// textureLoad/textureStore with global_invocation_id.x scalar coord on a
    /// bound 1D texture when dispatch extent fits the validated mip level.
    gid_texture_1d_dispatch_fit,

    /// textureLoad/textureStore with global_invocation_id.xy coords on a bound
    /// 2D texture when dispatch extents fit the validated mip level.
    gid_texture_2d_dispatch_fit,

    /// textureLoad with global_invocation_id.xyz coords on a bound 3D texture
    /// when dispatch extents fit the validated mip level.
    gid_texture_3d_dispatch_fit,

    /// textureLoad/textureStore with affine gid-derived scalar coord on a
    /// bound 1D texture when the validated mip extent fits the affine axis.
    gid_texture_1d_affine_dispatch_fit,

    /// textureLoad/textureStore with affine gid-derived vec2 coord on a bound
    /// 2D texture when validated mip extents fit both affine axes.
    gid_texture_2d_affine_dispatch_fit,

    /// textureLoad with affine gid-derived vec3 coord on a bound 3D texture
    /// when validated mip extents fit all affine axes.
    gid_texture_3d_affine_dispatch_fit,

    /// textureLoad/textureStore with tiled gid-derived scalar coord on a
    /// bound 1D texture when validated mip extent fits the tiled axis.
    gid_texture_1d_tiled_dispatch_fit,

    /// textureLoad/textureStore with tiled gid-derived vec2 coord on a bound
    /// 2D texture when validated mip extents fit both tiled axes.
    gid_texture_2d_tiled_dispatch_fit,

    /// textureLoad with tiled gid-derived vec3 coord on a bound 3D texture
    /// when validated mip extents fit all tiled axes.
    gid_texture_3d_tiled_dispatch_fit,
};

/// Check whether a specific bounds pattern has a proven elimination.
/// Returns true only when the build was compiled with -Dlean-verified=true
/// and the proof artifact covers the requested pattern.
pub fn boundsProven(comptime pattern: BoundsPattern) bool {
    if (!bounds_elimination_available) return false;
    return switch (pattern) {
        .gid_1d_storage_buffer => true,
        .gid_1d_storage_buffer_offset => comptime blk: {
            @setEvalBranchQuota(JSON_SEARCH_BRANCH_QUOTA);
            break :blk comptimeContains(proof_json.?, "\"gid_offset_matcher_contract_sound\"");
        },
        .gid_1d_storage_buffer_stride => comptime blk: {
            @setEvalBranchQuota(JSON_SEARCH_BRANCH_QUOTA);
            break :blk comptimeContains(proof_json.?, "\"gid_stride_offset_matcher_contract_sound\"");
        },
        .gid_1d_storage_buffer_loop_offset => comptime blk: {
            @setEvalBranchQuota(JSON_SEARCH_BRANCH_QUOTA);
            break :blk comptimeContains(proof_json.?, "\"gid_loop_offset_matcher_contract_sound\"");
        },
        .gid_1d_storage_buffer_loop_affine => comptime blk: {
            @setEvalBranchQuota(JSON_SEARCH_BRANCH_QUOTA);
            // Require the tight-precondition contract so the runtime check in
            // dispatch_preconditions.required_buffer_bytes can use the tight
            // `(total-1)*gid_stride + (limit-1)*loop_stride + offset + 1`
            // formula. Without the tight theorem, matvec-shaped dispatches
            // packed to exactly `total*gid_stride` elements fail the fit
            // check even though the maximum accessed index is in range.
            break :blk comptimeContains(proof_json.?, "\"gid_loop_affine_matcher_contract_sound_tight\"");
        },
        .loop_1d_storage_buffer_affine => comptime blk: {
            @setEvalBranchQuota(JSON_SEARCH_BRANCH_QUOTA);
            break :blk comptimeContains(proof_json.?, "\"loop_affine_matcher_contract_sound_tight\"");
        },
        .gid_1d_storage_buffer_tiled => comptime blk: {
            @setEvalBranchQuota(JSON_SEARCH_BRANCH_QUOTA);
            break :blk comptimeContains(proof_json.?, "\"gid_tiled_matcher_contract_sound\"");
        },
        .gid_2d_flat_storage_buffer => comptime blk: {
            @setEvalBranchQuota(JSON_SEARCH_BRANCH_QUOTA);
            break :blk comptimeContains(proof_json.?, "\"flat_2d_matcher_contract_sound\"");
        },
        .gid_2d_flat_storage_buffer_offset => comptime blk: {
            @setEvalBranchQuota(JSON_SEARCH_BRANCH_QUOTA);
            break :blk comptimeContains(proof_json.?, "\"flat_2d_offset_matcher_contract_sound\"");
        },
        .gid_3d_flat_storage_buffer => comptime blk: {
            @setEvalBranchQuota(JSON_SEARCH_BRANCH_QUOTA);
            break :blk comptimeContains(proof_json.?, "\"flat_3d_matcher_contract_sound\"");
        },
        .gid_3d_flat_storage_buffer_offset => comptime blk: {
            @setEvalBranchQuota(JSON_SEARCH_BRANCH_QUOTA);
            break :blk comptimeContains(proof_json.?, "\"flat_3d_offset_matcher_contract_sound\"");
        },
        .gid_texture_1d_dispatch_fit => comptime blk: {
            @setEvalBranchQuota(JSON_SEARCH_BRANCH_QUOTA);
            break :blk comptimeContains(proof_json.?, "\"texture_1d_identity_matcher_contract_sound\"");
        },
        .gid_texture_2d_dispatch_fit => comptime blk: {
            @setEvalBranchQuota(JSON_SEARCH_BRANCH_QUOTA);
            break :blk comptimeContains(proof_json.?, "\"texture_2d_identity_matcher_contract_sound\"");
        },
        .gid_texture_3d_dispatch_fit => comptime blk: {
            @setEvalBranchQuota(JSON_SEARCH_BRANCH_QUOTA);
            break :blk comptimeContains(proof_json.?, "\"texture_3d_identity_matcher_contract_sound\"");
        },
        .gid_texture_1d_affine_dispatch_fit => comptime blk: {
            @setEvalBranchQuota(JSON_SEARCH_BRANCH_QUOTA);
            break :blk comptimeContains(proof_json.?, "\"texture_1d_affine_matcher_contract_sound\"");
        },
        .gid_texture_2d_affine_dispatch_fit => comptime blk: {
            @setEvalBranchQuota(JSON_SEARCH_BRANCH_QUOTA);
            break :blk comptimeContains(proof_json.?, "\"texture_2d_affine_matcher_contract_sound\"");
        },
        .gid_texture_3d_affine_dispatch_fit => comptime blk: {
            @setEvalBranchQuota(JSON_SEARCH_BRANCH_QUOTA);
            break :blk comptimeContains(proof_json.?, "\"texture_3d_affine_matcher_contract_sound\"");
        },
        .gid_texture_1d_tiled_dispatch_fit => comptime blk: {
            @setEvalBranchQuota(JSON_SEARCH_BRANCH_QUOTA);
            break :blk comptimeContains(proof_json.?, "\"texture_1d_tiled_matcher_contract_sound\"");
        },
        .gid_texture_2d_tiled_dispatch_fit => comptime blk: {
            @setEvalBranchQuota(JSON_SEARCH_BRANCH_QUOTA);
            break :blk comptimeContains(proof_json.?, "\"texture_2d_tiled_matcher_contract_sound\"");
        },
        .gid_texture_3d_tiled_dispatch_fit => comptime blk: {
            @setEvalBranchQuota(JSON_SEARCH_BRANCH_QUOTA);
            break :blk comptimeContains(proof_json.?, "\"texture_3d_tiled_matcher_contract_sound\"");
        },
    };
}

comptime {
    @setEvalBranchQuota(JSON_SEARCH_BRANCH_QUOTA);
    if (build_options.lean_verified) {
        const json = proof_json.?;

        if (!comptimeContains(json, "\"schemaVersion\": 1"))
            @compileError("lean proof artifact: schemaVersion is not 1");

        if (!comptimeContains(json, "\"status\": \"verified\""))
            @compileError("lean proof artifact: status is not 'verified'");

        if (!comptimeContains(json, "\"provenance\""))
            @compileError("lean proof artifact: provenance section missing");

        requireFieldValue(json, "leanToolchainRef", lean_toolchain_ref, "provenance");
        requireFieldValue(json, "extractProgramSha256", lean_extract_program_sha256, "provenance");
        requireFieldValue(json, "leanSourceTreeSha256", lean_source_tree_sha256, "provenance");
        requireFieldValue(json, "generatedComparabilityContractSha256", generated_comparability_contract_sha256, "provenance");
        requireFieldValue(json, "proofPatternSpecSha256", proof_pattern_spec_sha256, "provenance");

        if (!comptimeContains(json, "\"comparabilityObligationsSha256\": \"" ++ comparability_obligations_sha256 ++ "\""))
            @compileError("lean proof artifact: comparability obligation contract hash mismatch");

        if (!comptimeContains(json, "\"toggleAlwaysSupported\""))
            @compileError("lean proof artifact: missing required theorem toggleAlwaysSupported");

        if (!comptimeContains(json, "\"requiredProof_forbidden_reject_from_rank\""))
            @compileError("lean proof artifact: missing required theorem requiredProof_forbidden_reject_from_rank");

        if (!comptimeContains(json, "\"strongerSafetyRaisesProofDemand\""))
            @compileError("lean proof artifact: missing required theorem strongerSafetyRaisesProofDemand");

        if (!comptimeContains(json, "\"identityActionComplete\""))
            @compileError("lean proof artifact: missing required theorem identityActionComplete");

        if (!comptimeContains(json, "\"scopeCommandTableComplete\""))
            @compileError("lean proof artifact: missing required theorem scopeCommandTableComplete");

        if (!comptimeContains(json, "\"identityActionPreservesCommand\""))
            @compileError("lean proof artifact: missing required theorem identityActionPreservesCommand");

        requireTheorem(json, "\"gid_component_lt_total\"");
        requireTheorem(json, "\"gid_inbounds_when_dispatch_fits\"");
        requireTheorem(json, "\"gid_plus_offset_inbounds_when_dispatch_fits\"");
        requireTheorem(json, "\"gid_times_stride_plus_offset_inbounds_when_dispatch_fits\"");
        requireTheorem(json, "\"gid_offset_matcher_contract_sound\"");
        requireTheorem(json, "\"gid_stride_offset_matcher_contract_sound\"");
        requireTheorem(json, "\"gid_plus_bounded_loop_index_inbounds_when_dispatch_fits\"");
        requireTheorem(json, "\"gid_affine_plus_scaled_loop_index_inbounds_when_dispatch_fits\"");
        requireTheorem(json, "\"gid_tiled_index_plus_offset_inbounds_when_dispatch_fits\"");
        requireTheorem(json, "\"gid_loop_offset_matcher_contract_sound\"");
        requireTheorem(json, "\"gid_loop_affine_matcher_contract_sound\"");
        requireTheorem(json, "\"gid_tiled_matcher_contract_sound\"");
        requireTheorem(json, "\"clamp_noop_when_inbounds\"");
        requireTheorem(json, "\"gid_2d_inbounds\"");
        requireTheorem(json, "\"flat_index_2d_inbounds\"");
        requireTheorem(json, "\"flat_index_2d_plus_offset_inbounds\"");
        requireTheorem(json, "\"flat_index_3d_inbounds\"");
        requireTheorem(json, "\"flat_index_3d_plus_offset_inbounds\"");
        requireTheorem(json, "\"flat_2d_matcher_contract_sound\"");
        requireTheorem(json, "\"flat_2d_offset_matcher_contract_sound\"");
        requireTheorem(json, "\"flat_3d_matcher_contract_sound\"");
        requireTheorem(json, "\"flat_3d_offset_matcher_contract_sound\"");
        requireTheorem(json, "\"gid_texture_coord_1d_inbounds_when_dispatch_fits\"");
        requireTheorem(json, "\"gid_texture_coords_2d_inbounds_when_dispatch_fits\"");
        requireTheorem(json, "\"gid_texture_coord_1d_affine_inbounds_when_dispatch_fits\"");
        requireTheorem(json, "\"gid_texture_coords_2d_affine_inbounds_when_dispatch_fits\"");
        requireTheorem(json, "\"gid_texture_coords_3d_affine_inbounds_when_dispatch_fits\"");
        requireTheorem(json, "\"gid_texture_coord_1d_tiled_inbounds_when_dispatch_fits\"");
        requireTheorem(json, "\"gid_texture_coords_2d_tiled_inbounds_when_dispatch_fits\"");
        requireTheorem(json, "\"gid_texture_coords_3d_tiled_inbounds_when_dispatch_fits\"");
        requireTheorem(json, "\"gid_texture_coords_3d_inbounds_when_dispatch_fits\"");
        requireTheorem(json, "\"texture_1d_identity_matcher_contract_sound\"");
        requireTheorem(json, "\"texture_2d_identity_matcher_contract_sound\"");
        requireTheorem(json, "\"texture_3d_identity_matcher_contract_sound\"");
        requireTheorem(json, "\"texture_1d_affine_matcher_contract_sound\"");
        requireTheorem(json, "\"texture_2d_affine_matcher_contract_sound\"");
        requireTheorem(json, "\"texture_3d_affine_matcher_contract_sound\"");
        requireTheorem(json, "\"texture_1d_tiled_matcher_contract_sound\"");
        requireTheorem(json, "\"texture_2d_tiled_matcher_contract_sound\"");
        requireTheorem(json, "\"texture_3d_tiled_matcher_contract_sound\"");

        // Validate that bounds eliminations section is present when shader
        // bounds theorems are listed.
        if (!comptimeContains(json, "\"boundsEliminations\""))
            @compileError("lean proof artifact: shader bounds theorems present but boundsEliminations section missing");

        // IR builder soundness trilogy.
        requireTheorem(json, "\"ExprIdValid_mono\"");
        requireTheorem(json, "\"ExprArgRangeValid_mono\"");
        requireTheorem(json, "\"StmtIdValid_mono\"");
        requireTheorem(json, "\"StmtChildRangeValid_mono\"");
        requireTheorem(json, "\"SwitchCaseRangeValid_mono\"");
        requireTheorem(json, "\"builder_soundness\"");
        requireTheorem(json, "\"TypesCompatible_refl\"");
        requireTheorem(json, "\"IsBoolType_not_integer\"");
        requireTheorem(json, "\"builder_load_inner_is_ref\"");
        requireTheorem(json, "\"builder_assign_lhs_is_ref\"");
        requireTheorem(json, "\"bounds_checks_pre_satisfied\"");
        requireTheorem(json, "\"semantic_checks_pre_satisfied\"");
        requireTheorem(json, "\"ValidatorRedundant\"");
    }
}
