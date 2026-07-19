// doe_wgsl/token.zig — WGSL token definitions.

const std = @import("std");

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const Loc = struct {
        start: u32,
        end: u32,
    };

    pub fn slice(self: Token, source: []const u8) []const u8 {
        return source[self.loc.start..self.loc.end];
    }
};

pub const Tag = enum(u8) {
    // Literals and identifiers.
    ident,
    int_literal,
    float_literal,

    // Punctuation.
    @"(",
    @")",
    @"{",
    @"}",
    @"[",
    @"]",
    @";",
    @":",
    @",",
    @".",
    @"@",

    // Operators.
    @"+",
    @"-",
    @"*",
    @"/",
    @"%",
    @"&",
    @"|",
    @"^",
    @"~",
    @"!",
    @"<",
    @">",
    @"=",

    // Compound operators.
    arrow, // ->
    plus_plus, // ++
    minus_minus, // --
    plus_eq, // +=
    minus_eq, // -=
    star_eq, // *=
    slash_eq, // /=
    percent_eq, // %=
    amp_eq, // &=
    pipe_eq, // |=
    caret_eq, // ^=
    shift_left, // <<
    shift_right, // >>
    lte, // <=
    gte, // >=
    eq_eq, // ==
    not_eq, // !=
    and_and, // &&
    or_or, // ||

    // Keywords.
    kw_fn,
    kw_var,
    kw_let,
    kw_const,
    kw_override,
    kw_struct,
    kw_return,
    kw_if,
    kw_else,
    kw_for,
    kw_while,
    kw_loop,
    kw_break,
    kw_continue,
    kw_switch,
    kw_case,
    kw_default,
    kw_enable,
    kw_true,
    kw_false,
    kw_discard,
    kw_continuing,
    kw_diagnostic,
    kw_alias,
    kw_const_assert,

    // Type keywords.
    kw_bool,
    kw_f16,
    kw_f32,
    kw_i32,
    kw_u32,
    kw_vec2,
    kw_vec3,
    kw_vec4,
    kw_mat2x2,
    kw_mat3x3,
    kw_mat4x4,
    kw_mat2x3,
    kw_mat2x4,
    kw_mat3x2,
    kw_mat3x4,
    kw_mat4x2,
    kw_mat4x3,
    kw_array,
    kw_atomic,
    kw_ptr,
    kw_sampler,
    kw_texture_1d,
    kw_texture_2d,
    kw_texture_external,

    // Address-space / access keywords (contextual).
    kw_uniform,
    kw_storage,
    kw_workgroup,
    kw_private,
    kw_function,
    kw_read,
    kw_read_write,

    // Special.
    eof,
    invalid,

    // Shorthand type aliases (vec2f, vec3u, etc).
    kw_vec2f,
    kw_vec3f,
    kw_vec4f,
    kw_vec2h,
    kw_vec3h,
    kw_vec4h,
    kw_vec2i,
    kw_vec3i,
    kw_vec4i,
    kw_vec2u,
    kw_vec3u,
    kw_vec4u,
    kw_mat2x2f,
    kw_mat3x3f,
    kw_mat4x4f,
    kw_mat2x2h,
    kw_mat3x3h,
    kw_mat4x4h,
};

const KW = struct { []const u8, Tag };
const KEYWORDS = [_]KW{
    .{ "alias", .kw_alias },
    .{ "array", .kw_array },
    .{ "const_assert", .kw_const_assert },
    .{ "atomic", .kw_atomic },
    .{ "bool", .kw_bool },
    .{ "break", .kw_break },
    .{ "case", .kw_case },
    .{ "const", .kw_const },
    .{ "continue", .kw_continue },
    .{ "continuing", .kw_continuing },
    .{ "default", .kw_default },
    .{ "diagnostic", .kw_diagnostic },
    .{ "discard", .kw_discard },
    .{ "else", .kw_else },
    .{ "enable", .kw_enable },
    .{ "f16", .kw_f16 },
    .{ "f32", .kw_f32 },
    .{ "false", .kw_false },
    .{ "fn", .kw_fn },
    .{ "for", .kw_for },
    .{ "function", .kw_function },
    .{ "i32", .kw_i32 },
    .{ "if", .kw_if },
    .{ "let", .kw_let },
    .{ "loop", .kw_loop },
    .{ "mat2x2", .kw_mat2x2 },
    .{ "mat2x2f", .kw_mat2x2f },
    .{ "mat2x2h", .kw_mat2x2h },
    .{ "mat2x3", .kw_mat2x3 },
    .{ "mat2x4", .kw_mat2x4 },
    .{ "mat3x2", .kw_mat3x2 },
    .{ "mat3x3", .kw_mat3x3 },
    .{ "mat3x3f", .kw_mat3x3f },
    .{ "mat3x3h", .kw_mat3x3h },
    .{ "mat3x4", .kw_mat3x4 },
    .{ "mat4x2", .kw_mat4x2 },
    .{ "mat4x3", .kw_mat4x3 },
    .{ "mat4x4", .kw_mat4x4 },
    .{ "mat4x4f", .kw_mat4x4f },
    .{ "mat4x4h", .kw_mat4x4h },
    .{ "override", .kw_override },
    .{ "private", .kw_private },
    .{ "ptr", .kw_ptr },
    .{ "read", .kw_read },
    .{ "read_write", .kw_read_write },
    .{ "return", .kw_return },
    .{ "sampler", .kw_sampler },
    .{ "storage", .kw_storage },
    .{ "struct", .kw_struct },
    .{ "switch", .kw_switch },
    .{ "texture_1d", .kw_texture_1d },
    .{ "texture_2d", .kw_texture_2d },
    .{ "texture_external", .kw_texture_external },
    .{ "true", .kw_true },
    .{ "u32", .kw_u32 },
    .{ "uniform", .kw_uniform },
    .{ "var", .kw_var },
    .{ "vec2", .kw_vec2 },
    .{ "vec2f", .kw_vec2f },
    .{ "vec2h", .kw_vec2h },
    .{ "vec2i", .kw_vec2i },
    .{ "vec2u", .kw_vec2u },
    .{ "vec3", .kw_vec3 },
    .{ "vec3f", .kw_vec3f },
    .{ "vec3h", .kw_vec3h },
    .{ "vec3i", .kw_vec3i },
    .{ "vec3u", .kw_vec3u },
    .{ "vec4", .kw_vec4 },
    .{ "vec4f", .kw_vec4f },
    .{ "vec4h", .kw_vec4h },
    .{ "vec4i", .kw_vec4i },
    .{ "vec4u", .kw_vec4u },
    .{ "while", .kw_while },
    .{ "workgroup", .kw_workgroup },
};

pub fn lookupIdent(ident: []const u8) Tag {
    for (KEYWORDS) |kw| {
        if (std.mem.eql(u8, ident, kw[0])) return kw[1];
    }
    return .ident;
}
