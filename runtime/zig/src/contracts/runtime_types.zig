//! Canonical runtime configuration and result type aggregation.

const execution = @import("execution.zig");
const configuration = @import("runtime_configuration.zig");
const backend = @import("backend.zig");

pub const NativeExecutionStatus = execution.NativeExecutionStatus;
pub const NativeExecutionResult = execution.NativeExecutionResult;
pub const UploadBufferUsageMode = configuration.UploadBufferUsageMode;
pub const QueueWaitMode = configuration.QueueWaitMode;
pub const QueueSyncMode = configuration.QueueSyncMode;
pub const GpuTimestampMode = configuration.GpuTimestampMode;
pub const QueueFamilyPolicy = backend.QueueFamilyPolicy;
pub const QueueFamilyKind = backend.QueueFamilyKind;
pub const DeferredSubmissionSyncPolicy = backend.DeferredSubmissionSyncPolicy;
