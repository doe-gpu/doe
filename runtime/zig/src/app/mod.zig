//! Application orchestration layer for the Hexagonal runtime core.

pub const request = @import("request.zig");
pub const prepare = @import("prepare.zig");
pub const runner = @import("runner.zig");

pub const ApplicationRequest = request.ApplicationRequest;
pub const ComputeRequest = request.ComputeRequest;
pub const TransferRequest = request.TransferRequest;
pub const WorkgroupCount = request.WorkgroupCount;

pub const prepareCompute = prepare.prepareCompute;
pub const prepareComputeFromCommand = prepare.prepareComputeFromCommand;
pub const prepareTransfer = prepare.prepareTransfer;
pub const prepareCommand = prepare.prepareCommand;

pub const executePrepared = runner.execute;
pub const executeCompute = runner.executeCompute;
pub const executeTransfer = runner.executeTransfer;
