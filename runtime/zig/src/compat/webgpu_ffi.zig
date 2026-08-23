const runtime_types = @import("../contracts/runtime_types.zig");
const backend = @import("../backend/webgpu_backend.zig");

pub const NativeExecutionStatus = runtime_types.NativeExecutionStatus;
pub const NativeExecutionResult = runtime_types.NativeExecutionResult;
pub const UploadBufferUsageMode = runtime_types.UploadBufferUsageMode;
pub const QueueWaitMode = runtime_types.QueueWaitMode;
pub const QueueSyncMode = runtime_types.QueueSyncMode;
pub const QueueFamilyPolicy = runtime_types.QueueFamilyPolicy;
pub const QueueFamilyKind = runtime_types.QueueFamilyKind;
pub const GpuTimestampMode = runtime_types.GpuTimestampMode;

pub const ManagedSurface = backend.ManagedSurface;
pub const CoreWebGPUBackend = backend.CoreWebGPUBackend;
pub const FullWebGPUBackendState = backend.FullWebGPUBackendState;
pub const WebGPUBackend = backend.WebGPUBackend;
