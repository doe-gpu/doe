pub const TraceDeterminismSummary = struct {
    mode: []const u8,
    policy_registry_path: []const u8,
    policy_registry_version: []const u8,
    comparator: []const u8,
    logits_sha256: []const u8,
    token: u32,
    proof_artifact_path: []const u8,
    proof_theorems: []const []const u8,
    policy_id: ?[]const u8 = null,
    review_policy_id: ?[]const u8 = null,
    base_rule_id: ?[]const u8 = null,
    tie_break_rule: ?[]const u8 = null,
    evaluator_kind: ?[]const u8 = null,
    trigger_policy_id: ?[]const u8 = null,
    candidate_set_id: ?[]const u8 = null,
    candidate_set_source: ?[]const u8 = null,
    selected_by: ?[]const u8 = null,
    ambiguity_triggered: ?bool = null,
    ambiguity_top_gap: ?f64 = null,
    stable_token_token: ?u32 = null,
    decision_accepted: ?bool = null,
    decision_acceptance_reason: ?[]const u8 = null,
    decision_token: ?u32 = null,
    decision_reviewer_id: ?[]const u8 = null,
    decision_id: ?[]const u8 = null,
    decision_ref: ?[]const u8 = null,
    decision_signature: ?[]const u8 = null,
};

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0...8, 11...12, 14...31 => try writer.print("\\u00{x:0>2}", .{byte}),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

fn writeOptionalString(writer: anytype, key: []const u8, value: ?[]const u8) !void {
    if (value) |text| {
        try writer.writeByte(',');
        try writeJsonString(writer, key);
        try writer.writeByte(':');
        try writeJsonString(writer, text);
    }
}

fn writeOptionalBool(writer: anytype, key: []const u8, value: ?bool) !void {
    if (value) |flag| {
        try writer.print(",\"{s}\":{}", .{ key, flag });
    }
}

fn writeOptionalU32(writer: anytype, key: []const u8, value: ?u32) !void {
    if (value) |number| {
        try writer.print(",\"{s}\":{}", .{ key, number });
    }
}

fn writeOptionalF64(writer: anytype, key: []const u8, value: ?f64) !void {
    if (value) |number| {
        try writer.print(",\"{s}\":{d}", .{ key, number });
    }
}

pub fn writeDeterminismMeta(writer: anytype, summary: TraceDeterminismSummary) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"mode\":");
    try writeJsonString(writer, summary.mode);
    try writer.writeAll(",\"policyRegistryPath\":");
    try writeJsonString(writer, summary.policy_registry_path);
    try writer.writeAll(",\"policyRegistryVersion\":");
    try writeJsonString(writer, summary.policy_registry_version);
    try writer.writeAll(",\"comparator\":");
    try writeJsonString(writer, summary.comparator);
    try writer.writeAll(",\"logitsSha256\":");
    try writeJsonString(writer, summary.logits_sha256);
    try writer.print(",\"token\":{}", .{summary.token});
    try writer.writeAll(",\"proofArtifactPath\":");
    try writeJsonString(writer, summary.proof_artifact_path);
    try writer.writeAll(",\"proofTheorems\":[");
    for (summary.proof_theorems, 0..) |theorem, index| {
        if (index != 0) try writer.writeByte(',');
        try writeJsonString(writer, theorem);
    }
    try writer.writeByte(']');
    try writeOptionalString(writer, "policyId", summary.policy_id);
    try writeOptionalString(writer, "reviewPolicyId", summary.review_policy_id);
    try writeOptionalString(writer, "baseRuleId", summary.base_rule_id);
    try writeOptionalString(writer, "tieBreakRule", summary.tie_break_rule);
    try writeOptionalString(writer, "evaluatorKind", summary.evaluator_kind);
    try writeOptionalString(writer, "triggerPolicyId", summary.trigger_policy_id);
    try writeOptionalString(writer, "candidateSetId", summary.candidate_set_id);
    try writeOptionalString(writer, "candidateSetSource", summary.candidate_set_source);
    try writeOptionalString(writer, "selectedBy", summary.selected_by);
    try writeOptionalBool(writer, "ambiguityTriggered", summary.ambiguity_triggered);
    try writeOptionalF64(writer, "ambiguityTopGap", summary.ambiguity_top_gap);
    try writeOptionalU32(writer, "stableTokenToken", summary.stable_token_token);
    try writeOptionalBool(writer, "decisionAccepted", summary.decision_accepted);
    try writeOptionalString(writer, "decisionAcceptanceReason", summary.decision_acceptance_reason);
    try writeOptionalU32(writer, "decisionToken", summary.decision_token);
    try writeOptionalString(writer, "decisionReviewerId", summary.decision_reviewer_id);
    try writeOptionalString(writer, "decisionId", summary.decision_id);
    try writeOptionalString(writer, "decisionRef", summary.decision_ref);
    try writeOptionalString(writer, "decisionSignature", summary.decision_signature);
    try writer.writeByte('}');
}
