//! Metadata attached to canonical commands without making the command parser
//! an owner of runtime or evidence semantics.

const semantic = @import("semantic.zig");
const numeric_stability = @import("numeric_stability/annotation.zig");

pub const CommandMetadata = struct {
    semantic: semantic.SemanticContext = .{},
    capture: ?semantic.CaptureRequest = null,
    numeric_stability: ?numeric_stability.Annotation = null,
};
