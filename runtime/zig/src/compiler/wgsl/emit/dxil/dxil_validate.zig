// DXBC container structural validation for DXIL bytecode.
//
// Validates the binary envelope without external tools: DXBC header magic,
// version, part table bounds, DXIL program sub-header, and LLVM bitcode
// magic. Does not validate shader semantics.

const std = @import("std");
const spec = @import("dxil_spec.zig");

const DXBC_MAGIC: [4]u8 = spec.DXBC_FOURCC;
const DXBC_HEADER_FIXED_SIZE: u32 = spec.DXBC_HEADER_SIZE; // magic(4)+hash(16)+ver(4)+size(4)+count(4)
const DXBC_VERSION: u32 = 1;
const MAX_PART_COUNT: u32 = 256;
const PART_HEADER_SIZE: u32 = 8; // fourcc(4)+size(4)
const DXIL_PROGRAM_HEADER_WORDS: u32 = 6;
const DXIL_PROGRAM_HEADER_SIZE: u32 = DXIL_PROGRAM_HEADER_WORDS * 4;
const BITCODE_MAGIC: [4]u8 = spec.LLVM_IR_MAGIC;
const FOURCC_DXIL = spec.PartFourCC.DXIL;
const FOURCC_HASH = spec.PartFourCC.HASH;

pub const ValidationError = error{
    TooSmall,
    BadMagic,
    BadVersion,
    SizeMismatch,
    PartOffsetOutOfBounds,
    PartCountTooLarge,
    NoDxilPart,
    DxilPartTooSmall,
    BadBitcodeMagic,
};

pub const ValidationResult = struct {
    valid: bool,
    container_size: u32,
    part_count: u32,
    has_dxil_part: bool,
    has_hash_part: bool,
    shader_model_kind: ?u32,
    dxil_major: ?u16,
    dxil_minor: ?u16,
    bitcode_size: ?u32,
    error_message: ?[]const u8,
};

/// Validate DXBC container structural integrity.
///
/// Checks: minimum size, DXBC magic, version, total-size consistency,
/// part-offset bounds, DXIL program sub-header, and LLVM bitcode magic.
/// Returns a result struct; callers inspect `valid` and `error_message`.
pub fn validate(data: []const u8) ValidationResult {
    return validateInner(data) catch |err| errResult(data, err);
}

fn validateInner(data: []const u8) ValidationError!ValidationResult {
    if (data.len < DXBC_HEADER_FIXED_SIZE) return error.TooSmall;

    // Magic
    if (!std.mem.eql(u8, data[0..4], &DXBC_MAGIC)) return error.BadMagic;

    // Version at offset 20
    const version = readU32(data, 20);
    if (version != DXBC_VERSION) return error.BadVersion;

    // Total size at offset 24
    const container_size = readU32(data, 24);
    if (container_size != @as(u32, @intCast(data.len))) return error.SizeMismatch;

    // Part count at offset 28
    const part_count = readU32(data, 28);
    if (part_count >= MAX_PART_COUNT) return error.PartCountTooLarge;

    // Part offset table: starts at byte 32, each entry is 4 bytes
    const offset_table_end: u64 = @as(u64, DXBC_HEADER_FIXED_SIZE) + @as(u64, part_count) * 4;
    if (offset_table_end > data.len) return error.PartOffsetOutOfBounds;

    // Scan parts
    var has_dxil_part = false;
    var has_hash_part = false;
    var shader_model_kind: ?u32 = null;
    var dxil_major: ?u16 = null;
    var dxil_minor: ?u16 = null;
    var bitcode_size: ?u32 = null;

    var i: u32 = 0;
    while (i < part_count) : (i += 1) {
        const offset_pos = DXBC_HEADER_FIXED_SIZE + i * 4;
        const part_offset = readU32(data, offset_pos);

        // Each part needs at least fourcc(4) + size(4)
        if (@as(u64, part_offset) + PART_HEADER_SIZE > data.len) return error.PartOffsetOutOfBounds;

        const fourcc = data[part_offset .. part_offset + 4];
        const part_data_size = readU32(data, part_offset + 4);
        const part_data_start: u64 = @as(u64, part_offset) + PART_HEADER_SIZE;

        if (part_data_start + part_data_size > data.len) return error.PartOffsetOutOfBounds;

        if (std.mem.eql(u8, fourcc, &FOURCC_DXIL)) {
            has_dxil_part = true;

            if (part_data_size < DXIL_PROGRAM_HEADER_SIZE) return error.DxilPartTooSmall;

            const prog_base: u32 = @intCast(part_data_start);

            // Word 0: ProgramVersion — shader_kind(bits 19:16) | major(bits 7:4) | minor(bits 3:0)
            const program_version = readU32(data, prog_base);
            shader_model_kind = (program_version >> 16) & 0xF;
            dxil_major = @intCast((program_version >> 4) & 0xF);
            dxil_minor = @intCast(program_version & 0xF);

            // Word 2: bitcode offset from program header start
            const bc_offset_from_header = readU32(data, prog_base + 8);
            // Word 3: bitcode size
            const bc_size = readU32(data, prog_base + 12);
            bitcode_size = bc_size;

            // Verify bitcode region is within the part data
            const bc_abs: u64 = @as(u64, prog_base) + bc_offset_from_header;
            if (bc_abs + bc_size > part_data_start + part_data_size) return error.DxilPartTooSmall;

            // Verify LLVM bitcode magic if bitcode is non-empty
            if (bc_size >= 4) {
                const bc_start: usize = @intCast(bc_abs);
                if (!std.mem.eql(u8, data[bc_start .. bc_start + 4], &BITCODE_MAGIC)) {
                    return error.BadBitcodeMagic;
                }
            }
        }

        if (std.mem.eql(u8, fourcc, &FOURCC_HASH)) {
            has_hash_part = true;
        }
    }

    if (!has_dxil_part) return error.NoDxilPart;

    return .{
        .valid = true,
        .container_size = container_size,
        .part_count = part_count,
        .has_dxil_part = true,
        .has_hash_part = has_hash_part,
        .shader_model_kind = shader_model_kind,
        .dxil_major = dxil_major,
        .dxil_minor = dxil_minor,
        .bitcode_size = bitcode_size,
        .error_message = null,
    };
}

fn errResult(data: []const u8, err: ValidationError) ValidationResult {
    const container_size: u32 = if (data.len >= 28)
        readU32(data, 24)
    else
        @intCast(data.len);
    const part_count: u32 = if (data.len >= 32) readU32(data, 28) else 0;

    return .{
        .valid = false,
        .container_size = container_size,
        .part_count = part_count,
        .has_dxil_part = false,
        .has_hash_part = false,
        .shader_model_kind = null,
        .dxil_major = null,
        .dxil_minor = null,
        .bitcode_size = null,
        .error_message = switch (err) {
            error.TooSmall => "container too small for DXBC header",
            error.BadMagic => "invalid DXBC magic bytes",
            error.BadVersion => "unsupported DXBC version (expected 1)",
            error.SizeMismatch => "container size field does not match data length",
            error.PartOffsetOutOfBounds => "part offset exceeds container bounds",
            error.PartCountTooLarge => "part count exceeds maximum (256)",
            error.NoDxilPart => "no DXIL part found in container",
            error.DxilPartTooSmall => "DXIL part too small for program header or bitcode",
            error.BadBitcodeMagic => "LLVM bitcode magic (0x4243C0DE) not found",
        },
    };
}

fn readU32(data: []const u8, offset: anytype) u32 {
    const off: usize = @intCast(offset);
    return std.mem.readInt(u32, @as(*const [4]u8, @ptrCast(data[off .. off + 4].ptr)), .little);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const container_mod = @import("dxil_container.zig");

/// Build a minimal valid DXBC container with a DXIL part containing LLVM
/// bitcode magic. Returns the number of bytes written.
fn buildMinimalContainer(buf: []u8) !usize {
    // Construct a tiny bitcode blob: just the 4-byte LLVM magic.
    const bitcode = spec.LLVM_IR_MAGIC;

    // Build the DXIL program part data into a scratch area.
    var dxil_part_buf: [256]u8 = undefined;
    const dxil_part_len = try container_mod.write_dxil_program_part(.{
        .shader_kind = spec.ShaderKind.COMPUTE,
        .bitcode = &bitcode,
    }, &dxil_part_buf);

    const parts = [_]container_mod.Part{
        .{ .fourcc = spec.PartFourCC.DXIL, .data = dxil_part_buf[0..dxil_part_len] },
    };
    return container_mod.write_container(&parts, buf);
}

test "valid minimal DXBC container" {
    var buf: [1024]u8 = undefined;
    const size = try buildMinimalContainer(&buf);
    const result = validate(buf[0..size]);

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u32, @intCast(size)), result.container_size);
    try std.testing.expectEqual(@as(u32, 1), result.part_count);
    try std.testing.expect(result.has_dxil_part);
    try std.testing.expectEqual(@as(u32, spec.ShaderKind.COMPUTE), result.shader_model_kind.?);
    try std.testing.expect(result.bitcode_size.? >= 4);
    try std.testing.expect(result.error_message == null);
}

test "too-small data" {
    const tiny = [_]u8{ 'D', 'X', 'B', 'C', 0, 0, 0, 0 };
    const result = validate(&tiny);
    try std.testing.expect(!result.valid);
    try std.testing.expect(result.error_message != null);
    try std.testing.expect(std.mem.indexOf(u8, result.error_message.?, "too small") != null);
}

test "bad magic" {
    var buf: [1024]u8 = undefined;
    const size = try buildMinimalContainer(&buf);
    buf[0] = 'X'; // corrupt magic
    const result = validate(buf[0..size]);
    try std.testing.expect(!result.valid);
    try std.testing.expect(std.mem.indexOf(u8, result.error_message.?, "magic") != null);
}

test "bad version" {
    var buf: [1024]u8 = undefined;
    const size = try buildMinimalContainer(&buf);
    // Version is at offset 20; overwrite to 2
    std.mem.writeInt(u32, @as(*[4]u8, @ptrCast(buf[20..24].ptr)), 2, .little);
    const result = validate(buf[0..size]);
    try std.testing.expect(!result.valid);
    try std.testing.expect(std.mem.indexOf(u8, result.error_message.?, "version") != null);
}

test "size mismatch" {
    var buf: [1024]u8 = undefined;
    const size = try buildMinimalContainer(&buf);
    // Corrupt the size field (offset 24) to be larger than actual data
    std.mem.writeInt(u32, @as(*[4]u8, @ptrCast(buf[24..28].ptr)), @as(u32, @intCast(size)) + 100, .little);
    const result = validate(buf[0..size]);
    try std.testing.expect(!result.valid);
    try std.testing.expect(std.mem.indexOf(u8, result.error_message.?, "size") != null);
}

test "container with HASH part" {
    var dxil_part_buf: [256]u8 = undefined;
    const dxil_part_len = try container_mod.write_dxil_program_part(.{
        .shader_kind = spec.ShaderKind.VERTEX,
        .bitcode = &spec.LLVM_IR_MAGIC,
    }, &dxil_part_buf);

    // Minimal 20-byte hash part: 4 flags + 16 digest
    var hash_data: [20]u8 = undefined;
    @memset(&hash_data, 0);

    const parts = [_]container_mod.Part{
        .{ .fourcc = spec.PartFourCC.DXIL, .data = dxil_part_buf[0..dxil_part_len] },
        .{ .fourcc = spec.PartFourCC.HASH, .data = &hash_data },
    };
    var buf: [1024]u8 = undefined;
    const size = try container_mod.write_container(&parts, &buf);
    const result = validate(buf[0..size]);

    try std.testing.expect(result.valid);
    try std.testing.expect(result.has_hash_part);
    try std.testing.expectEqual(@as(u32, 2), result.part_count);
    try std.testing.expectEqual(@as(u32, spec.ShaderKind.VERTEX), result.shader_model_kind.?);
}
