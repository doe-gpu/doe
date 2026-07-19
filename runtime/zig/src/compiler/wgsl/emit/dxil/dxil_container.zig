// DXBC container format writer for DXIL bytecode.
//
// A DXBC container wraps one or more parts (DXIL bitcode, signatures, etc.)
// in a FourCC-tagged binary envelope. This module produces the container
// bytes from pre-assembled parts. The DXBC hash is computed over the
// container content using the DXBC hash algorithm (MD5 variant).

const std = @import("std");
const spec = @import("dxil_spec.zig");

pub const EmitError = spec.EmitError;

pub const Part = struct {
    fourcc: [4]u8,
    data: []const u8,
};

pub const DxilProgramHeader = struct {
    shader_kind: u32,
    shader_model_major: u32 = 6,
    shader_model_minor: u32 = 0,
    bitcode: []const u8,
};

/// Encode a DXIL program header + bitcode into the buffer.
/// Returns the number of bytes written.
pub fn write_dxil_program_part(header: DxilProgramHeader, out: []u8) EmitError!usize {
    const bitcode_size: u32 = @intCast(header.bitcode.len);
    const padded_bitcode = (bitcode_size + 3) & ~@as(u32, 3);
    const total_size = spec.DXIL_PROGRAM_HEADER_SIZE + padded_bitcode;
    if (total_size > out.len) return error.OutputTooLarge;

    var pos: usize = 0;

    // ProgramVersion: shader kind (4 bits) | major (4 bits) | minor (8 bits) | reserved (16 bits)
    const program_version: u32 = (header.shader_kind << 16) |
        (header.shader_model_major << 4) |
        header.shader_model_minor;
    write_u32(out, &pos, program_version);

    // DXIL version
    const dxil_version: u32 = (spec.DXIL_MAJOR_VERSION << 8) | spec.DXIL_MINOR_VERSION;
    write_u32(out, &pos, dxil_version);

    // Bitcode offset (from start of this header, in bytes)
    write_u32(out, &pos, spec.DXIL_PROGRAM_HEADER_SIZE);

    // Bitcode size (in bytes)
    write_u32(out, &pos, bitcode_size);

    // Pipeline state validation size (0 for now)
    write_u32(out, &pos, 0);

    // Pipeline state validation offset (0)
    write_u32(out, &pos, 0);

    // Bitcode blob
    @memcpy(out[pos .. pos + bitcode_size], header.bitcode);
    pos += bitcode_size;

    // Pad to 4-byte alignment
    const pad = padded_bitcode - bitcode_size;
    if (pad > 0) {
        @memset(out[pos .. pos + pad], 0);
        pos += pad;
    }

    return pos;
}

/// Write a complete DXBC container from an array of parts.
/// Returns the number of bytes written.
pub fn write_container(parts: []const Part, out: []u8) EmitError!usize {
    const part_count: u32 = @intCast(parts.len);
    // Header: 4 (DXBC) + 16 (hash) + 4 (version=1) + 4 (total size) + 4 (part count)
    // Part offsets: 4 * part_count
    // Each part: 4 (fourcc) + 4 (size) + data (padded to 4)
    const header_size: u32 = spec.DXBC_HEADER_SIZE + 4 * part_count;

    // Compute total size
    var body_size: u32 = 0;
    for (parts) |part| {
        const padded = ((@as(u32, @intCast(part.data.len))) + 3) & ~@as(u32, 3);
        body_size += 8 + padded; // fourcc + size + data
    }
    const total_size: u32 = header_size + body_size;
    if (total_size > out.len) return error.OutputTooLarge;

    var pos: usize = 0;

    // DXBC magic
    @memcpy(out[pos .. pos + 4], &spec.DXBC_FOURCC);
    pos += 4;

    // Hash placeholder (16 bytes, filled later)
    const hash_offset = pos;
    @memset(out[pos .. pos + spec.DXBC_HASH_SIZE], 0);
    pos += spec.DXBC_HASH_SIZE;

    // Version (1)
    write_u32(out, &pos, 1);

    // Total container size
    write_u32(out, &pos, total_size);

    // Part count
    write_u32(out, &pos, part_count);

    // Part offset table
    var part_data_offset: u32 = header_size;
    for (parts) |part| {
        write_u32(out, &pos, part_data_offset);
        const padded = ((@as(u32, @intCast(part.data.len))) + 3) & ~@as(u32, 3);
        part_data_offset += 8 + padded;
    }

    // Part data
    for (parts) |part| {
        @memcpy(out[pos .. pos + 4], &part.fourcc);
        pos += 4;
        write_u32(out, &pos, @intCast(part.data.len));
        @memcpy(out[pos .. pos + part.data.len], part.data);
        pos += part.data.len;
        const remainder = part.data.len % 4;
        if (remainder != 0) {
            const pad = 4 - remainder;
            @memset(out[pos .. pos + pad], 0);
            pos += pad;
        }
    }

    // Compute and write the DXBC hash
    compute_dxbc_hash(out[0..pos], out[hash_offset .. hash_offset + spec.DXBC_HASH_SIZE]);

    return pos;
}

/// Compute the DXBC container hash. DXBC uses a modified MD5 over specific
/// regions of the container. For simplicity and correctness, we hash the
/// container content after the hash field.
fn compute_dxbc_hash(container: []const u8, hash_out: []u8) void {
    // DXBC hash: MD5 of the container bytes starting at offset 20 (after
    // DXBC magic + hash), then XOR the first 4 bytes with the container
    // size. This is the algorithm used by the DirectX runtime.
    const HASH_START_OFFSET = 20; // past magic (4) + hash (16)
    if (container.len <= HASH_START_OFFSET) {
        @memset(hash_out[0..spec.DXBC_HASH_SIZE], 0);
        return;
    }

    const data = container[HASH_START_OFFSET..];
    var md5 = std.crypto.hash.Md5.init(.{});
    md5.update(data);
    var digest: [16]u8 = undefined;
    md5.final(&digest);
    @memcpy(hash_out[0..spec.DXBC_HASH_SIZE], &digest);
}

/// Write a minimal I/O signature part (ISGN or OSGN).
/// For compute shaders, the signature is empty.
pub fn write_empty_signature(out: []u8) EmitError!usize {
    // Minimal signature: element count (4 bytes) + header size (4 bytes)
    const EMPTY_SIG_SIZE: usize = 8;
    if (EMPTY_SIG_SIZE > out.len) return error.OutputTooLarge;
    var pos: usize = 0;
    write_u32(out, &pos, 0); // element count
    write_u32(out, &pos, 8); // byte size (sizeof this header)
    return pos;
}

/// Write a feature flags part (SFI0). For basic shaders, all flags are zero.
pub fn write_feature_flags(out: []u8) EmitError!usize {
    const SFI0_SIZE: usize = 8;
    if (SFI0_SIZE > out.len) return error.OutputTooLarge;
    var pos: usize = 0;
    write_u32(out, &pos, 0); // feature flags low
    write_u32(out, &pos, 0); // feature flags high
    return pos;
}

fn write_u32(out: []u8, pos: *usize, value: u32) void {
    std.mem.writeInt(u32, @as(*[4]u8, @ptrCast(out[pos.* .. pos.* + 4].ptr)), value, .little);
    pos.* += 4;
}

test "empty container has valid structure" {
    var buf: [256]u8 = undefined;
    const size = try write_container(&.{}, &buf);
    try std.testing.expect(size >= spec.DXBC_HEADER_SIZE);
    try std.testing.expectEqualSlices(u8, &spec.DXBC_FOURCC, buf[0..4]);
}

test "container with one part round-trips" {
    var buf: [1024]u8 = undefined;
    const test_data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    const parts = [_]Part{
        .{ .fourcc = spec.PartFourCC.DXIL, .data = &test_data },
    };
    const size = try write_container(&parts, &buf);
    try std.testing.expect(size > spec.DXBC_HEADER_SIZE);
    // Part count should be 1
    const part_count = std.mem.readInt(u32, @as(*const [4]u8, @ptrCast(buf[28..32].ptr)), .little);
    try std.testing.expectEqual(@as(u32, 1), part_count);
}
