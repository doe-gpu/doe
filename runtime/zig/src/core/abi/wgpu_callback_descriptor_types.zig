const std = @import("std");
const base = @import("wgpu_core_base_types.zig");
const feature = @import("wgpu_feature_base_types.zig");
const callback_types = @import("wgpu_type_callbacks.zig").definitions(base);
const upstream = @import("generated/webgpu_upstream.zig");

pub const WGPUCallbackMode = callback_types.WGPUCallbackMode;
pub const WGPUCallbackMode_WaitAnyOnly = callback_types.WGPUCallbackMode_WaitAnyOnly;
pub const WGPUCallbackMode_AllowProcessEvents = callback_types.WGPUCallbackMode_AllowProcessEvents;
pub const WGPUCallbackMode_AllowSpontaneous = callback_types.WGPUCallbackMode_AllowSpontaneous;
pub const WGPUWaitStatus = callback_types.WGPUWaitStatus;
pub const WGPURequestAdapterStatus = callback_types.WGPURequestAdapterStatus;
pub const WGPURequestDeviceStatus = callback_types.WGPURequestDeviceStatus;
pub const WGPUQueueWorkDoneStatus = callback_types.WGPUQueueWorkDoneStatus;
pub const WGPUPowerPreference = callback_types.WGPUPowerPreference;
pub const WGPUFeatureLevel = callback_types.WGPUFeatureLevel;
pub const WGPUBackendType = callback_types.WGPUBackendType;
pub const WGPURequestAdapterCallback = callback_types.WGPURequestAdapterCallback;
pub const WGPURequestDeviceCallback = callback_types.WGPURequestDeviceCallback;
pub const WGPUQueueWorkDoneCallback = callback_types.WGPUQueueWorkDoneCallback;
pub const WGPUDeviceLostReason = callback_types.WGPUDeviceLostReason;
pub const WGPUErrorType = callback_types.WGPUErrorType;
pub const WGPUDeviceLostCallback = callback_types.WGPUDeviceLostCallback;
pub const WGPUUncapturedErrorCallback = callback_types.WGPUUncapturedErrorCallback;
pub const WGPURequestAdapterCallbackInfo = callback_types.WGPURequestAdapterCallbackInfo;
pub const WGPURequestDeviceCallbackInfo = callback_types.WGPURequestDeviceCallbackInfo;
pub const WGPUQueueWorkDoneCallbackInfo = callback_types.WGPUQueueWorkDoneCallbackInfo;
pub const WGPUDeviceLostCallbackInfo = callback_types.WGPUDeviceLostCallbackInfo;
pub const WGPUUncapturedErrorCallbackInfo = callback_types.WGPUUncapturedErrorCallbackInfo;

pub const WGPUChainedStruct = upstream.WGPUChainedStruct;
pub const WGPURequestAdapterOptions = upstream.WGPURequestAdapterOptions;
pub const WGPUQueueDescriptor = upstream.WGPUQueueDescriptor;
pub const WGPULimits = upstream.WGPULimits;
pub const WGPUDeviceDescriptor = upstream.WGPUDeviceDescriptor;
pub const WGPUBufferMapCallbackInfo = upstream.WGPUBufferMapCallbackInfo;
pub const WGPUBufferMapCallback = upstream.WGPUBufferMapCallback;
pub const WGPUFutureWaitInfo = upstream.WGPUFutureWaitInfo;

pub fn initLimits() WGPULimits {
    var limits = std.mem.zeroes(WGPULimits);
    limits.nextInChain = null;
    return limits;
}
