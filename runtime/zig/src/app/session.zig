//! Application execution session maintaining state across sequential requests.

const std = @import("std");
const request = @import("request.zig");
const prepare = @import("prepare.zig");
const runner = @import("runner.zig");
const compute_port = @import("../backend/ports/compute.zig");
const report = @import("../contracts/execution_report.zig");
const workload = @import("../contracts/workload_profile.zig");

pub const ApplicationSession = struct {
    session_id: u64,
    profile: workload.WorkloadProfile = .{},
    next_operation_id: u64 = 1,

    pub fn dispatch(self: *ApplicationSession, port: compute_port.ComputePort, req: request.ComputeRequest) !report.ExecutionReport {
        const op_id = self.next_operation_id;
        self.next_operation_id += 1;
        const op = prepare.prepareCompute(req, op_id);
        return runner.executeCompute(port, op);
    }
};
