const std = @import("std");
const doe = @import("doe");
const lexer_mod = doe.compiler.wgsl_frontend.lexer();
const token_mod = doe.compiler.wgsl_frontend.token();
const byte_scan = doe.runtime.simd.byteScan();

pub const LexDigest = struct {
    count: usize,
    hash: u64,
};

pub const LexerBench = struct {
    source: []const u8,

    pub fn runScalar(self: *LexerBench) !u64 {
        const digest = lexWithScalar(self.source);
        return digest.hash ^ @as(u64, digest.count);
    }

    pub fn runSimd(self: *LexerBench) !u64 {
        const digest = lexWithSimd(self.source);
        return digest.hash ^ @as(u64, digest.count);
    }
};

const ScalarLexer = struct {
    source: []const u8,
    pos: u32,

    fn init(source: []const u8) ScalarLexer {
        return .{ .source = source, .pos = 0 };
    }

    fn next(self: *ScalarLexer) token_mod.Token {
        self.skipWhitespaceAndComments();
        const start = self.pos;
        if (start >= self.source.len) {
            return .{ .tag = .eof, .loc = .{ .start = start, .end = start } };
        }
        const c = self.source[start];

        switch (c) {
            '(' => return self.single(.@"("),
            ')' => return self.single(.@")"),
            '{' => return self.single(.@"{"),
            '}' => return self.single(.@"}"),
            '[' => return self.single(.@"["),
            ']' => return self.single(.@"]"),
            ';' => return self.single(.@";"),
            ':' => return self.single(.@":"),
            ',' => return self.single(.@","),
            '.' => return self.single(.@"."),
            '@' => return self.single(.@"@"),
            '~' => return self.single(.@"~"),
            else => {},
        }

        switch (c) {
            '+' => return self.compoundOrSingle('=', .plus_eq, .@"+"),
            '*' => return self.compoundOrSingle('=', .star_eq, .@"*"),
            '%' => return self.compoundOrSingle('=', .percent_eq, .@"%"),
            '^' => return self.compoundOrSingle('=', .caret_eq, .@"^"),
            '-' => {
                if (self.peek(1) == '>') return self.double(.arrow);
                if (self.peek(1) == '=') return self.double(.minus_eq);
                return self.single(.@"-");
            },
            '/' => {
                if (self.peek(1) == '=') return self.double(.slash_eq);
                return self.single(.@"/");
            },
            '&' => {
                if (self.peek(1) == '&') return self.double(.and_and);
                if (self.peek(1) == '=') return self.double(.amp_eq);
                return self.single(.@"&");
            },
            '|' => {
                if (self.peek(1) == '|') return self.double(.or_or);
                if (self.peek(1) == '=') return self.double(.pipe_eq);
                return self.single(.@"|");
            },
            '<' => {
                if (self.peek(1) == '<') return self.double(.shift_left);
                if (self.peek(1) == '=') return self.double(.lte);
                return self.single(.@"<");
            },
            '>' => {
                if (self.peek(1) == '>') return self.double(.shift_right);
                if (self.peek(1) == '=') return self.double(.gte);
                return self.single(.@">");
            },
            '=' => {
                if (self.peek(1) == '=') return self.double(.eq_eq);
                return self.single(.@"=");
            },
            '!' => {
                if (self.peek(1) == '=') return self.double(.not_eq);
                return self.single(.@"!");
            },
            else => {},
        }

        if (isDigit(c) or (c == '.' and self.pos + 1 < self.source.len and isDigit(self.source[self.pos + 1]))) {
            return self.lexNumber();
        }
        if (isIdentStart(c)) return self.lexIdent();

        self.pos += 1;
        return .{ .tag = .invalid, .loc = .{ .start = start, .end = self.pos } };
    }

    fn single(self: *ScalarLexer, tag: token_mod.Tag) token_mod.Token {
        const start = self.pos;
        self.pos += 1;
        return .{ .tag = tag, .loc = .{ .start = start, .end = self.pos } };
    }

    fn double(self: *ScalarLexer, tag: token_mod.Tag) token_mod.Token {
        const start = self.pos;
        self.pos += 2;
        return .{ .tag = tag, .loc = .{ .start = start, .end = self.pos } };
    }

    fn compoundOrSingle(self: *ScalarLexer, next_char: u8, compound: token_mod.Tag, simple: token_mod.Tag) token_mod.Token {
        if (self.peek(1) == next_char) return self.double(compound);
        return self.single(simple);
    }

    fn peek(self: *const ScalarLexer, offset: u32) u8 {
        const idx = self.pos + offset;
        if (idx >= self.source.len) return 0;
        return self.source[idx];
    }

    fn skipWhitespaceAndComments(self: *ScalarLexer) void {
        while (self.pos < self.source.len) {
            const whitespace_len = byte_scan.countLeadingWhitespaceScalar(self.source[self.pos..]);
            if (whitespace_len > 0) {
                self.pos += @intCast(whitespace_len);
                continue;
            }
            const c = self.source[self.pos];
            if (c == '/' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '/') {
                const remaining = self.source[self.pos + 2 ..];
                if (byte_scan.findFirstByteScalar(remaining, '\n')) |newline_offset| {
                    self.pos += @intCast(2 + newline_offset);
                } else {
                    self.pos = @intCast(self.source.len);
                }
                continue;
            }
            if (c == '/' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '*') {
                self.pos += 2;
                var depth: u32 = 1;
                while (depth > 0 and self.pos + 1 < self.source.len) {
                    if (self.source[self.pos] == '/' and self.source[self.pos + 1] == '*') {
                        depth += 1;
                        self.pos += 2;
                    } else if (self.source[self.pos] == '*' and self.source[self.pos + 1] == '/') {
                        depth -= 1;
                        self.pos += 2;
                    } else {
                        self.pos += 1;
                    }
                }
                continue;
            }
            break;
        }
    }

    fn lexNumber(self: *ScalarLexer) token_mod.Token {
        const start = self.pos;
        var is_float = false;

        if (self.source[self.pos] == '0' and self.pos + 1 < self.source.len and
            (self.source[self.pos + 1] == 'x' or self.source[self.pos + 1] == 'X'))
        {
            self.pos += 2;
            self.pos += @intCast(byte_scan.countLeadingHexDigitsScalar(self.source[self.pos..]));
            if (self.pos < self.source.len and (self.source[self.pos] == 'p' or self.source[self.pos] == 'P')) {
                is_float = true;
                self.pos += 1;
                if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) {
                    self.pos += 1;
                }
                self.pos += @intCast(byte_scan.countLeadingDigitsScalar(self.source[self.pos..]));
            }
            self.consumeNumericSuffix(&is_float, false);
            return .{ .tag = if (is_float) .float_literal else .int_literal, .loc = .{ .start = start, .end = self.pos } };
        }

        self.pos += @intCast(byte_scan.countLeadingDigitsScalar(self.source[self.pos..]));
        if (self.pos < self.source.len and self.source[self.pos] == '.') {
            if (self.pos + 1 < self.source.len and isDigit(self.source[self.pos + 1])) {
                is_float = true;
                self.pos += 1;
                self.pos += @intCast(byte_scan.countLeadingDigitsScalar(self.source[self.pos..]));
            } else if (self.pos + 1 >= self.source.len or !isIdentStart(self.source[self.pos + 1])) {
                is_float = true;
                self.pos += 1;
            }
        }
        if (self.pos < self.source.len and (self.source[self.pos] == 'e' or self.source[self.pos] == 'E')) {
            is_float = true;
            self.pos += 1;
            if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) {
                self.pos += 1;
            }
            self.pos += @intCast(byte_scan.countLeadingDigitsScalar(self.source[self.pos..]));
        }
        self.consumeNumericSuffix(&is_float, true);
        return .{ .tag = if (is_float) .float_literal else .int_literal, .loc = .{ .start = start, .end = self.pos } };
    }

    fn consumeNumericSuffix(self: *ScalarLexer, is_float: *bool, allow_float_promotion: bool) void {
        if (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if ((c == 'f' or c == 'h') and (allow_float_promotion or is_float.*)) {
                is_float.* = true;
            }
            if (c == 'i' or c == 'u' or c == 'f' or c == 'h') {
                self.pos += 1;
            }
        }
    }

    fn lexIdent(self: *ScalarLexer) token_mod.Token {
        const start = self.pos;
        self.pos += @intCast(byte_scan.countLeadingIdentContinueScalar(self.source[self.pos..]));
        const ident = self.source[start..self.pos];
        return .{ .tag = token_mod.lookupIdent(ident), .loc = .{ .start = start, .end = self.pos } };
    }
};

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn digestToken(current: u64, token: token_mod.Token) u64 {
    var hash = current ^ @as(u64, @intFromEnum(token.tag));
    hash = hash *% 1099511628211;
    hash ^= token.loc.start;
    hash = hash *% 1099511628211;
    hash ^= token.loc.end;
    return hash *% 1099511628211;
}

pub fn lexWithSimd(source: []const u8) LexDigest {
    var lexer = lexer_mod.Lexer.init(source);
    var count: usize = 0;
    var hash: u64 = 0xcbf29ce484222325;
    while (true) {
        const token = lexer.next();
        count += 1;
        hash = digestToken(hash, token);
        if (token.tag == .eof) break;
    }
    return .{ .count = count, .hash = hash };
}

pub fn lexWithScalar(source: []const u8) LexDigest {
    var lexer = ScalarLexer.init(source);
    var count: usize = 0;
    var hash: u64 = 0xcbf29ce484222325;
    while (true) {
        const token = lexer.next();
        count += 1;
        hash = digestToken(hash, token);
        if (token.tag == .eof) break;
    }
    return .{ .count = count, .hash = hash };
}
