const std = @import("std");
const trace_text = @import("../../runtime/trace/trace_text.zig");

pub const TraceNumericStabilityDecisionCounts = struct {
    accept_fast: u32 = 0,
    prefer_stable: u32 = 0,
    abstain: u32 = 0,
};

pub const TraceNumericStabilitySummary = struct {
    policy_registry_path: []const u8,
    policy_registry_version: []const u8,
    route_taxonomy_version: []const u8,
    execution_profile_id: ?[]const u8 = null,
    receipt_path: []const u8,
    receipt_count: u32,
    decision_counts: TraceNumericStabilityDecisionCounts,
    first_divergence_present_count: u32,
    annotation_count: u32 = 0,
    auto_detect_count: u32 = 0,
    committed_stable_rewrite_count: u32 = 0,
    downstream_stop_count: u32 = 0,
};

const writeJsonString = trace_text.writeJsonString;

pub fn writeNumericStabilityMeta(writer: anytype, summary: TraceNumericStabilitySummary) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"policyRegistryPath\":");
    try writeJsonString(writer, summary.policy_registry_path);
    try writer.writeAll(",\"policyRegistryVersion\":");
    try writeJsonString(writer, summary.policy_registry_version);
    try writer.writeAll(",\"routeTaxonomyVersion\":");
    try writeJsonString(writer, summary.route_taxonomy_version);
    if (summary.execution_profile_id) |execution_profile_id| {
        try writer.writeAll(",\"executionProfileId\":");
        try writeJsonString(writer, execution_profile_id);
    }
    try writer.writeAll(",\"receiptPath\":");
    try writeJsonString(writer, summary.receipt_path);
    try writer.print(",\"receiptCount\":{}", .{summary.receipt_count});
    try writer.writeAll(",\"decisionCounts\":{");
    try writer.print("\"accept-fast\":{},\"prefer-stable\":{},\"abstain\":{}", .{
        summary.decision_counts.accept_fast,
        summary.decision_counts.prefer_stable,
        summary.decision_counts.abstain,
    });
    try writer.writeByte('}');
    try writer.print(",\"firstDivergencePresentCount\":{}", .{summary.first_divergence_present_count});
    try writer.print(",\"annotationCount\":{}", .{summary.annotation_count});
    try writer.print(",\"autoDetectCount\":{}", .{summary.auto_detect_count});
    try writer.print(",\"committedStableRewriteCount\":{}", .{summary.committed_stable_rewrite_count});
    try writer.print(",\"downstreamStopCount\":{}", .{summary.downstream_stop_count});
    try writer.writeByte('}');
}
