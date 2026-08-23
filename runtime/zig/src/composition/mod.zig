//! Hexagonal composition plane module.
//!
//! Owns assembly of backend ports, runtime composition, and inbound adapter wiring.

pub const backend_factory = @import("backend_factory.zig");
pub const runtime_factory = @import("runtime_factory.zig");
pub const execution_session = @import("execution_session.zig");
pub const cli = @import("cli.zig");
pub const native = @import("native.zig");
pub const dropin = @import("dropin.zig");
pub const plan = @import("plan.zig");

pub const BackendPortBundle = backend_factory.BackendPortBundle;
pub const RuntimeComposition = runtime_factory.RuntimeComposition;
pub const ExecutionSession = execution_session.ExecutionSession;
pub const ExecutionSessionOptions = execution_session.Options;

pub const executeComputeCli = cli.executeComputeCli;
pub const executeNativeDispatch = native.executeNativeDispatch;
pub const executeDropinWriteBuffer = dropin.executeDropinWriteBuffer;
pub const executePlanCompute = plan.executePlanCompute;
