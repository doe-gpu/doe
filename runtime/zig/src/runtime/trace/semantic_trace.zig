const std = @import("std");

pub const SemanticContext = struct {
    op_id: ?[]const u8 = null,
    stage: ?[]const u8 = null,
    phase: ?[]const u8 = null,
    token_index: ?u32 = null,
    layer_index: ?u32 = null,
    execution_plan_hash: ?[]const u8 = null,

    pub fn present(self: SemanticContext) bool {
        return self.op_id != null or
            self.stage != null or
            self.phase != null or
            self.token_index != null or
            self.layer_index != null or
            self.execution_plan_hash != null;
    }
};

pub const CaptureRequest = struct {
    buffer_handle: u64,
    offset: u64 = 0,
    size: u64,

    pub fn end_offset(self: CaptureRequest) !u64 {
        return std.math.add(u64, self.offset, self.size);
    }
};
