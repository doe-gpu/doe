//! Evidence port interface for observing execution without changing behavior.
//!
//! Hexagonal rule: Evidence code observes requests, prepared operations, and execution
//! reports. It never alters provider selection, runtime kernels, or execution semantics.

const observer = @import("../contracts/evidence_observer.zig");

pub const EvidencePortVTable = observer.EvidenceObserverVTable;
pub const EvidencePort = observer.EvidenceObserver;
