// LLVM 3.7 bitcode stream writer for DXIL emission.
//
// Implements the LLVM bitstream format: variable-width integers, VBR encoding,
// block enter/exit, unabbreviated records, and blob data. Operates on a fixed
// output buffer without heap allocation for the stream itself.

const std = @import("std");
const spec = @import("dxil_spec.zig");

pub const EmitError = spec.EmitError;

const INITIAL_ABBREV_WIDTH: u5 = 2;
const MIN_ABBREV_WIDTH: u5 = 2;

pub const Writer = struct {
    buf: []u8,
    byte_pos: usize = 0,
    bit_pos: u3 = 0,

    block_stack: [16]BlockFrame = undefined,
    block_depth: u4 = 0,

    current_abbrev_width: u5 = INITIAL_ABBREV_WIDTH,

    const BlockFrame = struct {
        prev_abbrev_width: u5,
        start_byte: usize,
        start_bit: u3,
        block_id: u32,
    };

    pub fn init(buf: []u8) Writer {
        return .{ .buf = buf };
    }

    pub fn position(self: *const Writer) usize {
        return self.byte_pos;
    }

    pub fn emit_raw_bytes(self: *Writer, data: []const u8) EmitError!void {
        self.flush_to_byte_boundary();
        if (self.byte_pos + data.len > self.buf.len) return error.OutputTooLarge;
        @memcpy(self.buf[self.byte_pos .. self.byte_pos + data.len], data);
        self.byte_pos += data.len;
    }

    pub fn emit_bits(self: *Writer, value: u64, num_bits: u6) EmitError!void {
        var remaining = num_bits;
        var val = value;
        while (remaining > 0) {
            if (self.byte_pos >= self.buf.len) return error.OutputTooLarge;
            const bits_in_byte: u3 = @intCast(@min(remaining, @as(u6, 8) - @as(u6, self.bit_pos)));
            const mask: u8 = @intCast((@as(u16, 1) << bits_in_byte) - 1);
            self.buf[self.byte_pos] &= ~(@as(u8, mask) << self.bit_pos);
            self.buf[self.byte_pos] |= @as(u8, @intCast(val & mask)) << self.bit_pos;
            val >>= bits_in_byte;
            remaining -= bits_in_byte;
            const new_bit: u4 = @as(u4, self.bit_pos) + @as(u4, bits_in_byte);
            if (new_bit >= 8) {
                self.byte_pos += 1;
                self.bit_pos = 0;
            } else {
                self.bit_pos = @intCast(new_bit);
            }
        }
    }

    pub fn emit_vbr(self: *Writer, value: u64, width: u5) EmitError!void {
        if (width < 2) return error.InvalidIr;
        const data_bits: u5 = width - 1;
        const data_mask: u64 = (@as(u64, 1) << data_bits) - 1;
        const continue_bit: u64 = @as(u64, 1) << data_bits;
        var val = value;
        while (true) {
            const chunk = val & data_mask;
            val >>= data_bits;
            if (val == 0) {
                try self.emit_bits(chunk, @intCast(width));
                break;
            } else {
                try self.emit_bits(chunk | continue_bit, @intCast(width));
            }
        }
    }

    pub fn emit_signed_vbr(self: *Writer, value: i64, width: u5) EmitError!void {
        // LLVM signed VBR: rotate sign bit to LSB
        const unsigned: u64 = if (value >= 0)
            @as(u64, @intCast(value)) << 1
        else
            (@as(u64, @intCast(-value - 1)) << 1) | 1;
        try self.emit_vbr(unsigned, width);
    }

    pub fn enter_block(self: *Writer, block_id: u32, new_abbrev_width: u5) EmitError!void {
        try self.emit_bits(spec.AbbrevId.ENTER_SUBBLOCK, @intCast(self.current_abbrev_width));
        try self.emit_vbr(block_id, 8);
        try self.emit_vbr(new_abbrev_width, 4);
        self.align_to_32();

        if (self.block_depth >= 16) return error.OutputTooLarge;
        self.block_stack[self.block_depth] = .{
            .prev_abbrev_width = self.current_abbrev_width,
            .start_byte = self.byte_pos,
            .start_bit = self.bit_pos,
            .block_id = block_id,
        };
        self.block_depth += 1;
        self.current_abbrev_width = new_abbrev_width;

        // Reserve space for block length (32-bit word count)
        if (self.byte_pos + 4 > self.buf.len) return error.OutputTooLarge;
        @memset(self.buf[self.byte_pos .. self.byte_pos + 4], 0);
        self.byte_pos += 4;
    }

    pub fn exit_block(self: *Writer) EmitError!void {
        try self.emit_bits(spec.AbbrevId.END_BLOCK, @intCast(self.current_abbrev_width));
        self.align_to_32();

        if (self.block_depth == 0) return error.InvalidIr;
        self.block_depth -= 1;
        const frame = self.block_stack[self.block_depth];

        // Patch the block length word
        const content_start = frame.start_byte + 4;
        const content_bytes = self.byte_pos - content_start;
        const word_count: u32 = @intCast((content_bytes + 3) / 4);
        std.mem.writeInt(u32, @as(*[4]u8, @ptrCast(self.buf[frame.start_byte .. frame.start_byte + 4].ptr)), word_count, .little);

        self.current_abbrev_width = frame.prev_abbrev_width;
    }

    pub fn emit_record(self: *Writer, code: u32, operands: []const u64) EmitError!void {
        try self.emit_bits(spec.AbbrevId.UNABBREV_RECORD, @intCast(self.current_abbrev_width));
        try self.emit_vbr(code, 6);
        try self.emit_vbr(operands.len, 6);
        for (operands) |op| {
            try self.emit_vbr(op, 6);
        }
    }

    pub fn emit_record_with_string(self: *Writer, code: u32, prefix_ops: []const u64, text: []const u8) EmitError!void {
        try self.emit_bits(spec.AbbrevId.UNABBREV_RECORD, @intCast(self.current_abbrev_width));
        try self.emit_vbr(code, 6);
        try self.emit_vbr(prefix_ops.len + text.len, 6);
        for (prefix_ops) |op| {
            try self.emit_vbr(op, 6);
        }
        for (text) |ch| {
            try self.emit_vbr(ch, 6);
        }
    }

    pub fn emit_string_record(self: *Writer, code: u32, text: []const u8) EmitError!void {
        try self.emit_record_with_string(code, &.{}, text);
    }

    pub fn flush_to_byte_boundary(self: *Writer) void {
        if (self.bit_pos != 0) {
            self.byte_pos += 1;
            self.bit_pos = 0;
        }
    }

    fn align_to_32(self: *Writer) void {
        self.flush_to_byte_boundary();
        const remainder = self.byte_pos % 4;
        if (remainder != 0) {
            const padding = 4 - remainder;
            if (self.byte_pos + padding <= self.buf.len) {
                @memset(self.buf[self.byte_pos .. self.byte_pos + padding], 0);
                self.byte_pos += padding;
            }
        }
    }

    pub fn finalize(self: *Writer) usize {
        self.flush_to_byte_boundary();
        return self.byte_pos;
    }
};

test "bitcode writer emits magic and simple record" {
    var buf: [256]u8 = .{0} ** 256;
    var w = Writer.init(&buf);

    try w.emit_raw_bytes(&spec.LLVM_IR_MAGIC);
    try std.testing.expectEqual(@as(usize, 4), w.position());

    try w.enter_block(spec.BlockId.MODULE, 3);
    try w.emit_record(spec.ModuleCode.VERSION, &.{1});
    try w.exit_block();

    const size = w.finalize();
    try std.testing.expect(size > 4);
    try std.testing.expectEqualSlices(u8, &spec.LLVM_IR_MAGIC, buf[0..4]);
}

test "vbr encodes small and large values" {
    var buf: [64]u8 = .{0} ** 64;
    var w = Writer.init(&buf);

    try w.emit_vbr(5, 4);
    const pos1 = w.byte_pos;
    try std.testing.expect(pos1 <= 2);

    try w.emit_vbr(0x1234, 4);
    const pos2 = w.byte_pos;
    try std.testing.expect(pos2 > pos1);
}
