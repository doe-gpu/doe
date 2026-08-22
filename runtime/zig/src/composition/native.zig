//! Composition root wiring WebGPU native object API adapters.

const std = @import("std");
const runtime_factory = @import("runtime_factory.zig");
const app = @import("../app/mod.zig");
const model_compute = @import("../contracts/model/model_compute_types.zig");
const report = @import("../contracts/execution_report.zig");

pub fn executeNativeDispatch(composition: runtime_factory.RuntimeComposition, cmd: model_compute.KernelDispatchCommand, operation_id: u64) !report.ExecutionReport {
    const op = app.prepareComputeFromCommand(cmd, operation_id);
    return composition.executeCompute(op);
}
