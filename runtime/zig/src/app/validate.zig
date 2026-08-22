//! Request validation module.
//!
//! Enforces WebGPU and Doe dispatch limits, buffer bounds, and entry point rules.

const std = @import("std");
const request = @import("request.zig");
const error_contract = @import("../contracts/error.zig");

pub const ValidationLimits = struct {
    max_workgroup_count_x: u32 = 65535,
    max_workgroup_count_y: u32 = 65535,
    max_workgroup_count_z: u32 = 65535,
    max_buffer_size: u64 = 1024 * 1024 * 1024, // 1GB
};

pub fn validateComputeRequest(req: request.ComputeRequest, limits: ValidationLimits) ?error_contract.DoeError {
    if (req.kernel_source.len == 0) {
        return error.InvalidArgument;
    }
    if (req.workgroups.x > limits.max_workgroup_count_x or
        req.workgroups.y > limits.max_workgroup_count_y or
        req.workgroups.z > limits.max_workgroup_count_z)
    {
        return error.UnsupportedCapability;
    }
    return null;
}

pub fn validateTransferRequest(req: request.TransferRequest, limits: ValidationLimits) ?error_contract.DoeError {
    if (req.size_bytes > limits.max_buffer_size) {
        return error.UnsupportedCapability;
    }
    if (req.data.len < req.size_bytes) {
        return error.BoundsViolation;
    }
    return null;
}
