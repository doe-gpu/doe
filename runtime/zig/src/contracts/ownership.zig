//! Resource lifetime and memory ownership contracts.

const std = @import("std");

pub const ResourceOwnership = enum {
    runtime_owned,
    caller_owned,
    shared_refcounted,
};

pub const LifecycleState = enum {
    uninitialized,
    active,
    suspended,
    released,
    lost,
};
