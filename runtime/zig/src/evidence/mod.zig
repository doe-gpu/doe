//! Evidence plane root module.
//!
//! Hexagonal boundary: Evidence observes operations and results without altering execution.

pub const port = @import("port.zig");
pub const trace = @import("trace.zig");
pub const receipt = @import("receipt.zig");
pub const oracle = @import("oracle.zig");
pub const replay = @import("replay.zig");

pub const EvidencePort = port.EvidencePort;
pub const EvidencePortVTable = port.EvidencePortVTable;

pub const TraceCollector = trace.TraceCollector;
pub const TraceEvent = trace.TraceEvent;

pub const ExecutionReceipt = receipt.ExecutionReceipt;
pub const createExecutionReceipt = receipt.createExecutionReceipt;

pub const compareExactBytes = oracle.compareExactBytes;
pub const compareFloatsWithTolerance = oracle.compareFloatsWithTolerance;

pub const validateReplayHashes = replay.validateReplayHashes;
pub const ReplayValidationResult = replay.ReplayValidationResult;
