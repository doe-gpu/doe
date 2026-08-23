//! Hexagonal composition plane module.
//!
//! Owns provider assembly and execution-session lifetime.

pub const backend_factory = @import("backend_factory.zig");
pub const execution_session = @import("execution_session.zig");

pub const BackendPortBundle = backend_factory.BackendPortBundle;
pub const ExecutionSession = execution_session.ExecutionSession;
pub const ExecutionSessionOptions = execution_session.Options;
