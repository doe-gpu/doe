const std = @import("std");

pub const BYTE_LANES: usize = 16;
const ByteVec = @Vector(BYTE_LANES, u8);
const BoolVec = @Vector(BYTE_LANES, bool);

fn splatByte(value: u8) ByteVec {
    return @splat(value);
}

fn loadChunk(source: []const u8, start: usize) ByteVec {
    const array: [BYTE_LANES]u8 = source[start..][0..BYTE_LANES].*;
    return @bitCast(array);
}

fn firstTrue(mask: BoolVec) ?usize {
    inline for (0..BYTE_LANES) |lane| {
        if (mask[lane]) return lane;
    }
    return null;
}

fn firstFalse(mask: BoolVec) usize {
    inline for (0..BYTE_LANES) |lane| {
        if (!mask[lane]) return lane;
    }
    return BYTE_LANES;
}

fn isWhitespaceChunk(chunk: ByteVec) BoolVec {
    return (chunk == splatByte(' ')) |
        (chunk == splatByte('\t')) |
        (chunk == splatByte('\n')) |
        (chunk == splatByte('\r'));
}

fn isDigitChunk(chunk: ByteVec) BoolVec {
    return (chunk >= splatByte('0')) & (chunk <= splatByte('9'));
}

fn isHexDigitChunk(chunk: ByteVec) BoolVec {
    const is_digit = isDigitChunk(chunk);
    const lower = chunk | splatByte(0x20);
    const is_hex_alpha = (lower >= splatByte('a')) & (lower <= splatByte('f'));
    return is_digit | is_hex_alpha;
}

fn isIdentStartChunk(chunk: ByteVec) BoolVec {
    const lower = chunk | splatByte(0x20);
    return ((lower >= splatByte('a')) & (lower <= splatByte('z'))) |
        (chunk == splatByte('_'));
}

fn isIdentContinueChunk(chunk: ByteVec) BoolVec {
    return isIdentStartChunk(chunk) | isDigitChunk(chunk);
}

fn isAlnumChunk(chunk: ByteVec) BoolVec {
    const lower = chunk | splatByte(0x20);
    return ((lower >= splatByte('a')) & (lower <= splatByte('z'))) | isDigitChunk(chunk);
}

fn isJsonEscapeOrControlChunk(chunk: ByteVec) BoolVec {
    return (chunk == splatByte('"')) |
        (chunk == splatByte('\\')) |
        (chunk == splatByte('\n')) |
        (chunk == splatByte('\r')) |
        (chunk == splatByte('\t')) |
        (chunk < splatByte(0x20));
}

pub fn countLeadingWhitespaceScalar(source: []const u8) usize {
    var index: usize = 0;
    while (index < source.len and std.ascii.isWhitespace(source[index])) : (index += 1) {}
    return index;
}

pub fn countLeadingWhitespace(source: []const u8) usize {
    if (source.len < BYTE_LANES) return countLeadingWhitespaceScalar(source);
    var index: usize = 0;
    while (index + BYTE_LANES <= source.len) : (index += BYTE_LANES) {
        const mask = isWhitespaceChunk(loadChunk(source, index));
        if (@reduce(.And, mask)) continue;
        return index + firstFalse(mask);
    }
    index += countLeadingWhitespaceScalar(source[index..]);
    return index;
}

pub fn countLeadingDigitsScalar(source: []const u8) usize {
    var index: usize = 0;
    while (index < source.len and std.ascii.isDigit(source[index])) : (index += 1) {}
    return index;
}

pub fn countLeadingDigits(source: []const u8) usize {
    if (source.len < BYTE_LANES) return countLeadingDigitsScalar(source);
    var index: usize = 0;
    while (index + BYTE_LANES <= source.len) : (index += BYTE_LANES) {
        const mask = isDigitChunk(loadChunk(source, index));
        if (@reduce(.And, mask)) continue;
        return index + firstFalse(mask);
    }
    index += countLeadingDigitsScalar(source[index..]);
    return index;
}

pub fn countLeadingHexDigitsScalar(source: []const u8) usize {
    var index: usize = 0;
    while (index < source.len and std.ascii.isHex(source[index])) : (index += 1) {}
    return index;
}

pub fn countLeadingHexDigits(source: []const u8) usize {
    if (source.len < BYTE_LANES) return countLeadingHexDigitsScalar(source);
    var index: usize = 0;
    while (index + BYTE_LANES <= source.len) : (index += BYTE_LANES) {
        const mask = isHexDigitChunk(loadChunk(source, index));
        if (@reduce(.And, mask)) continue;
        return index + firstFalse(mask);
    }
    index += countLeadingHexDigitsScalar(source[index..]);
    return index;
}

pub fn countLeadingIdentContinueScalar(source: []const u8) usize {
    var index: usize = 0;
    while (index < source.len) : (index += 1) {
        const byte = source[index];
        if (!((std.ascii.isAlphabetic(byte)) or std.ascii.isDigit(byte) or byte == '_')) break;
    }
    return index;
}

pub fn countLeadingIdentContinue(source: []const u8) usize {
    if (source.len < BYTE_LANES) return countLeadingIdentContinueScalar(source);
    var index: usize = 0;
    while (index + BYTE_LANES <= source.len) : (index += BYTE_LANES) {
        const mask = isIdentContinueChunk(loadChunk(source, index));
        if (@reduce(.And, mask)) continue;
        return index + firstFalse(mask);
    }
    index += countLeadingIdentContinueScalar(source[index..]);
    return index;
}

pub fn countLeadingAlnumScalar(source: []const u8) usize {
    var index: usize = 0;
    while (index < source.len) : (index += 1) {
        const byte = source[index];
        if (!(std.ascii.isAlphabetic(byte) or std.ascii.isDigit(byte))) break;
    }
    return index;
}

pub fn countLeadingAlnum(source: []const u8) usize {
    if (source.len < BYTE_LANES) return countLeadingAlnumScalar(source);
    var index: usize = 0;
    while (index + BYTE_LANES <= source.len) : (index += BYTE_LANES) {
        const mask = isAlnumChunk(loadChunk(source, index));
        if (@reduce(.And, mask)) continue;
        return index + firstFalse(mask);
    }
    index += countLeadingAlnumScalar(source[index..]);
    return index;
}

pub fn findFirstByteScalar(source: []const u8, needle: u8) ?usize {
    var index: usize = 0;
    while (index < source.len) : (index += 1) {
        if (source[index] == needle) return index;
    }
    return null;
}

pub fn findFirstByte(source: []const u8, needle: u8) ?usize {
    if (source.len < BYTE_LANES) return findFirstByteScalar(source, needle);
    var index: usize = 0;
    while (index + BYTE_LANES <= source.len) : (index += BYTE_LANES) {
        const mask = loadChunk(source, index) == splatByte(needle);
        if (firstTrue(mask)) |offset| return index + offset;
    }
    if (findFirstByteScalar(source[index..], needle)) |offset| return index + offset;
    return null;
}

pub fn findFirstJsonEscapeOrControlScalar(source: []const u8) ?usize {
    var index: usize = 0;
    while (index < source.len) : (index += 1) {
        const byte = source[index];
        if (byte == '"' or byte == '\\' or byte == '\n' or byte == '\r' or byte == '\t' or byte < 0x20) {
            return index;
        }
    }
    return null;
}

pub fn findFirstJsonEscapeOrControl(source: []const u8) ?usize {
    if (source.len < BYTE_LANES) return findFirstJsonEscapeOrControlScalar(source);
    var index: usize = 0;
    while (index + BYTE_LANES <= source.len) : (index += BYTE_LANES) {
        const mask = isJsonEscapeOrControlChunk(loadChunk(source, index));
        if (firstTrue(mask)) |offset| return index + offset;
    }
    if (findFirstJsonEscapeOrControlScalar(source[index..])) |offset| return index + offset;
    return null;
}

test "countLeadingWhitespace handles scalar and vector spans" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 0), countLeadingWhitespace("abc"));
    try testing.expectEqual(@as(usize, 4), countLeadingWhitespace(" \t\r\nabc"));
    try testing.expectEqual(@as(usize, 20), countLeadingWhitespace("                    tail"));
}

test "digit and identifier scans stop at first non-matching byte" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 6), countLeadingDigits("123456x"));
    try testing.expectEqual(@as(usize, 8), countLeadingHexDigits("deadBEEF!"));
    try testing.expectEqual(@as(usize, 11), countLeadingIdentContinue("alpha_12345!"));
    try testing.expectEqual(@as(usize, 10), countLeadingAlnum("alpha12345!"));
}

test "findFirstByte and json escape scan find expected boundaries" {
    const testing = std.testing;
    try testing.expectEqual(@as(?usize, 5), findFirstByte("hello\nworld", '\n'));
    try testing.expectEqual(@as(?usize, 4), findFirstJsonEscapeOrControl("safe\\tail"));
    try testing.expectEqual(@as(?usize, 4), findFirstJsonEscapeOrControl("safe\"tail"));
    try testing.expectEqual(@as(?usize, 4), findFirstJsonEscapeOrControl("safe\n"));
    try testing.expectEqual(@as(?usize, null), findFirstJsonEscapeOrControl("plain ascii text"));
}
