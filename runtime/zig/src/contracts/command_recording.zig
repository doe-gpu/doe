pub const Failure = error{ OutOfMemory, InvalidState, InvalidArgument };

pub const State = union(enum) {
    open,
    failed: Failure,
    finished,

    pub fn fail(self: *State, cause: Failure) bool {
        if (self.* == .failed) return false;
        self.* = .{ .failed = cause };
        return true;
    }
};
