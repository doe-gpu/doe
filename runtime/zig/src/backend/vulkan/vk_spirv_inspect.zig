const SPIRV_OP_EXECUTION_MODE: u16 = 16;
const SPIRV_OP_VARIABLE: u16 = 59;
const SPIRV_EXECUTION_MODE_LOCAL_SIZE: u32 = 17;
const SPIRV_STORAGE_CLASS_WORKGROUP: u32 = 4;

pub const LocalSize = struct {
    x: u32,
    y: u32,
    z: u32,
};

pub fn compute_local_size(words: []const u32) ?LocalSize {
    if (words.len < 5) return null;
    var i: usize = 5;
    while (i < words.len) {
        const word = words[i];
        const opcode: u16 = @truncate(word & 0xFFFF);
        const word_count: u16 = @truncate((word >> 16) & 0xFFFF);
        if (word_count == 0) break;
        if (opcode == SPIRV_OP_EXECUTION_MODE and word_count >= 6 and i + word_count <= words.len and
            words[i + 2] == SPIRV_EXECUTION_MODE_LOCAL_SIZE)
        {
            return .{
                .x = words[i + 3],
                .y = words[i + 4],
                .z = words[i + 5],
            };
        }
        i += word_count;
    }
    return null;
}

pub fn compute_local_size_x(words: []const u32) ?u32 {
    return if (compute_local_size(words)) |local_size| local_size.x else null;
}

pub fn has_workgroup_storage(words: []const u32) bool {
    if (words.len < 5) return false;
    var i: usize = 5;
    while (i < words.len) {
        const word = words[i];
        const opcode: u16 = @truncate(word & 0xFFFF);
        const word_count: u16 = @truncate((word >> 16) & 0xFFFF);
        if (word_count == 0) break;
        if (opcode == SPIRV_OP_VARIABLE and word_count >= 4 and i + word_count <= words.len and
            words[i + 3] == SPIRV_STORAGE_CLASS_WORKGROUP)
        {
            return true;
        }
        i += word_count;
    }
    return false;
}
