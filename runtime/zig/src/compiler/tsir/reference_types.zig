const schema = @import("schema.zig");

pub const InterpretError = error{
    OutOfMemory,
    NotImplemented,
    RejectedBySemantic,
};

pub const Result = struct {
    /// SHA-256 over the canonical byte image of all output buffers
    /// in their declared order. This is the parity hash every backend
    /// is compared against.
    reference_hash: [32]u8,
    /// Per-output-buffer raw bytes in declared order. Caller owns.
    /// Empty slice when interpretation was rejected.
    outputs: [][]const u8,
    rejections: []const schema.RejectionEntry,
};
