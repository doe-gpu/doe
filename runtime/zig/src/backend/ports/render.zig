//! Outbound port interface for graphics render pass execution.

const std = @import("std");
const render_contract = @import("../../contracts/render_command.zig");
const report_contract = @import("../../contracts/execution_report.zig");

pub const RenderPortVTable = struct {
    execute_render_pass: *const fn (ctx: *anyopaque, op: render_contract.PreparedRenderPassOperation) anyerror!report_contract.ExecutionReport,
    create_pipeline: *const fn (ctx: *anyopaque, op: render_contract.PreparedPipelineOperation) anyerror!report_contract.ExecutionReport,
};

pub const RenderPort = struct {
    context: *anyopaque,
    vtable: *const RenderPortVTable,

    pub fn executeRenderPass(self: RenderPort, op: render_contract.PreparedRenderPassOperation) !report_contract.ExecutionReport {
        return self.vtable.execute_render_pass(self.context, op);
    }

    pub fn createPipeline(self: RenderPort, op: render_contract.PreparedPipelineOperation) !report_contract.ExecutionReport {
        return self.vtable.create_pipeline(self.context, op);
    }
};
