//! Composition root wiring WebGPU drop-in C ABI symbol routing.

const std = @import("std");
const runtime_factory = @import("runtime_factory.zig");
const app = @import("../app/mod.zig");
const report = @import("../contracts/execution_report.zig");

pub fn executeDropinWriteBuffer(composition: runtime_factory.RuntimeComposition, handle: u64, offset: u64, size: u64, data: []const u8, operation_id: u64) !report.ExecutionReport {
    const op = app.prepareTransfer(.{
        .buffer_handle = handle,
        .offset_bytes = offset,
        .size_bytes = size,
        .data = data,
    }, operation_id);
    return composition.executeTransfer(op);
}
