//! Application orchestration layer for the Hexagonal runtime core.

pub const request = @import("request.zig");
pub const normalize = @import("normalize.zig");
pub const validate = @import("validate.zig");
pub const specialize = @import("specialize.zig");
pub const compile = @import("compile.zig");
pub const bind = @import("bind.zig");
pub const schedule = @import("schedule.zig");
pub const prepare = @import("prepare.zig");
pub const execute = @import("execute.zig");
pub const runner = @import("runner.zig");
pub const session = @import("session.zig");

pub const ApplicationRequest = request.ApplicationRequest;
pub const ComputeRequest = request.ComputeRequest;
pub const TransferRequest = request.TransferRequest;
pub const WorkgroupCount = request.WorkgroupCount;

pub const normalizeWorkgroups = normalize.normalizeWorkgroups;
pub const normalizeOffset = normalize.normalizeOffset;

pub const validateComputeRequest = validate.validateComputeRequest;
pub const validateTransferRequest = validate.validateTransferRequest;

pub const evaluateSpecialization = specialize.evaluateSpecialization;
pub const compileKernelSource = compile.compileKernelSource;

pub const prepareCompute = prepare.prepareCompute;
pub const prepareComputeFromCommand = prepare.prepareComputeFromCommand;
pub const prepareTransfer = prepare.prepareTransfer;

pub const executeCompute = runner.executeCompute;
pub const executeTransfer = runner.executeTransfer;
pub const executeComputeDirect = execute.executeComputeDirect;
pub const executeTransferDirect = execute.executeTransferDirect;

pub const ApplicationSession = session.ApplicationSession;
