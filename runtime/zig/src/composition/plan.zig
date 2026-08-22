//! Composition root wiring plan execution and replay adapters.

const std = @import("std");
const runtime_factory = @import("runtime_factory.zig");
const app = @import("../app/mod.zig");
const report = @import("../contracts/execution_report.zig");

pub fn executePlanCompute(composition: runtime_factory.RuntimeComposition, req: app.ComputeRequest, operation_id: u64) !report.ExecutionReport {
    const op = app.prepareCompute(req, operation_id);
    return composition.executeCompute(op);
}
