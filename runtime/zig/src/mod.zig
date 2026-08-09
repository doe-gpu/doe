pub const backend = @import("backend/mod.zig");

pub const cli = struct {
    pub fn doePlanExecutor() type {
        return @import("cli/doe_plan_executor_cli.zig");
    }

    pub fn moduleRunner() type {
        return @import("cli/module_runner_cli.zig");
    }

    pub fn runtime() type {
        return @import("cli/runtime_cli.zig");
    }
};

pub const compiler = @import("compiler/mod.zig");
pub const contracts = @import("contracts/mod.zig");

pub fn dropin() type {
    return @import("dropin/wgpu_dropin_lib.zig");
}

pub const plan = @import("plan/mod.zig");
pub const runtime = @import("runtime/mod.zig");

pub const verification = struct {
    pub fn leanProof() type {
        return @import("verification/lean_proof.zig");
    }
};
