const execution_types = @import("../core/abi/wgpu_execution_types.zig");
const backend_contract = @import("../contracts/backend.zig");

pub const NativeExecutionStatus = execution_types.NativeExecutionStatus;
pub const NativeExecutionResult = execution_types.NativeExecutionResult;

pub const UploadBufferUsageMode = enum {
    copy_dst_copy_src,
    copy_dst,
};

pub const QueueWaitMode = enum {
    process_events,
    wait_any,
};

pub const QueueSyncMode = enum {
    per_command,
    deferred,
};

pub const QueueFamilyPolicy = backend_contract.QueueFamilyPolicy;
pub const QueueFamilyKind = backend_contract.QueueFamilyKind;
pub const DeferredSubmissionSyncPolicy = backend_contract.DeferredSubmissionSyncPolicy;

pub const GpuTimestampMode = enum {
    auto,
    off,
    require,
};
