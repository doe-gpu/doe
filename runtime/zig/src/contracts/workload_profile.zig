//! Workload profile contracts governing application optimization intent.
//!
//! Allows inbound products (such as Fawn or local AI runners) to declare execution
//! priorities and memory budgets without coupling to concrete runtime internals.

const std = @import("std");

pub const LatencyPriority = enum {
    interactive_lowest_latency,
    balanced,
    throughput_maximized,
};

pub const MemoryBudgetMb = struct {
    working_set_max_mb: u32 = 1024,
    cache_pool_max_mb: u32 = 256,
};

pub const ExecutionDomain = enum {
    agent_browser_interactive,
    local_model_inference,
    vision_preprocessing,
    compute_kernel_dispatch,
    general_webgpu,
};

pub const WorkloadProfile = struct {
    name: []const u8 = "default",
    domain: ExecutionDomain = .general_webgpu,
    priority: LatencyPriority = .balanced,
    memory_budget: MemoryBudgetMb = .{},
    allow_bounds_elision: bool = true,
    require_deterministic_replay: bool = false,
};
