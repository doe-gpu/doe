const std = @import("std");
const token = @import("../frontend/token.zig");

pub const TranslateError = error{
    InvalidWgsl,
    InvalidIr,
    DuplicateSymbol,
    InvalidAttribute,
    InvalidType,
    OutputTooLarge,
    OutOfMemory,
    ShaderToolchainUnavailable,
    UnexpectedToken,
    TypeMismatch,
    UnknownIdentifier,
    UnknownType,
    UnsupportedBuiltin,
    UnsupportedConstruct,
    UnsupportedPattern,
    UnsupportedWgsl,
};

pub const CompilationStage = enum {
    none,
    parser,
    sema,
    ir_builder,
    ir_validate,
    ir_transform,
    msl_emit,
    hlsl_emit,
    spirv_emit,
    dxil_emit,
    csl_emit,
};

pub const SourceLocation = struct {
    line: u32,
    column: u32,
};

pub const LastErrorInfo = struct {
    stage: CompilationStage,
    kind: ?TranslateError,
    location: ?SourceLocation,
    context: []const u8,
};

const LAST_ERROR_CAP: usize = 256;
const LAST_CONTEXT_CAP: usize = 96;

/// Value-owned, allocation-free diagnostic; views live as long as this value.
pub const Diagnostic = struct {
    last_error_buf: [LAST_ERROR_CAP]u8 = undefined,
    last_error_len: usize = 0,
    last_error_stage: CompilationStage = .none,
    last_error_kind: ?TranslateError = null,
    last_error_line: u32 = 0,
    last_error_column: u32 = 0,
    last_error_context_buf: [LAST_CONTEXT_CAP]u8 = undefined,
    last_error_context_len: usize = 0,

    /// Start a new diagnostic lifetime before a native compile or cache lookup.
    pub fn clearLastError(self: *Diagnostic) void {
        self.last_error_stage = .none;
        self.last_error_kind = null;
        self.last_error_len = 0;
        self.last_error_line = 0;
        self.last_error_column = 0;
        self.last_error_context_len = 0;
    }

    pub fn setLastError(self: *Diagnostic, stage: CompilationStage, kind: TranslateError, source: ?[]const u8, loc: ?token.Token.Loc) void {
        self.last_error_stage = stage;
        self.last_error_kind = kind;
        self.recordSourceContext(source, loc);
        const text = (if (self.last_error_line != 0 and self.last_error_context_len != 0)
            std.fmt.bufPrint(&self.last_error_buf, "{s}: {s} at {d}:{d} near `{s}`", .{
                @tagName(stage),
                @errorName(kind),
                self.last_error_line,
                self.last_error_column,
                self.last_error_context_buf[0..self.last_error_context_len],
            })
        else
            std.fmt.bufPrint(&self.last_error_buf, "{s}: {s}", .{
                @tagName(stage),
                @errorName(kind),
            })) catch {
            self.last_error_len = 0;
            return;
        };
        self.last_error_len = text.len;
    }

    pub fn setLastErrorDetailPublic(self: *Diagnostic, stage: CompilationStage, kind: TranslateError, detail: []const u8) void {
        self.setLastErrorDetail(stage, kind, detail);
    }

    fn setLastErrorDetail(self: *Diagnostic, stage: CompilationStage, kind: TranslateError, detail: []const u8) void {
        self.last_error_stage = stage;
        self.last_error_kind = kind;
        self.last_error_line = 0;
        self.last_error_column = 0;
        self.last_error_context_len = 0;
        var writer = std.Io.Writer.fixed(&self.last_error_buf);
        writer.print("{s}: {s}: {s}", .{ @tagName(stage), @errorName(kind), detail }) catch {};
        self.last_error_len = writer.buffered().len;
    }

    fn recordSourceContext(self: *Diagnostic, source: ?[]const u8, loc: ?token.Token.Loc) void {
        self.last_error_line = 0;
        self.last_error_column = 0;
        self.last_error_context_len = 0;

        const src = source orelse return;
        const span = loc orelse return;
        if (span.start > src.len or span.end > src.len or span.start > span.end) return;

        var line: u32 = 1;
        var column: u32 = 1;
        var line_start: usize = 0;
        var i: usize = 0;
        while (i < span.start) : (i += 1) {
            if (src[i] == '\n') {
                line += 1;
                column = 1;
                line_start = i + 1;
            } else {
                column += 1;
            }
        }

        var line_end = span.end;
        while (line_end < src.len and src[line_end] != '\n' and src[line_end] != '\r') : (line_end += 1) {}
        const full_line = src[line_start..line_end];
        const token_rel = span.start - line_start;

        var snippet_start: usize = 0;
        if (full_line.len > LAST_CONTEXT_CAP and token_rel > LAST_CONTEXT_CAP / 2) {
            snippet_start = token_rel - LAST_CONTEXT_CAP / 2;
            if (snippet_start + LAST_CONTEXT_CAP > full_line.len) {
                snippet_start = full_line.len - LAST_CONTEXT_CAP;
            }
        }
        const snippet = full_line[snippet_start..@min(full_line.len, snippet_start + LAST_CONTEXT_CAP)];
        @memcpy(self.last_error_context_buf[0..snippet.len], snippet);
        self.last_error_context_len = snippet.len;
        self.last_error_line = line;
        self.last_error_column = column;
    }

    pub fn lastErrorKind(self: *Diagnostic) ?TranslateError {
        return self.last_error_kind;
    }

    pub fn lastErrorContext(self: *Diagnostic) []const u8 {
        return self.last_error_context_buf[0..self.last_error_context_len];
    }

    pub fn lastErrorInfo(self: *Diagnostic) LastErrorInfo {
        return .{
            .stage = self.last_error_stage,
            .kind = self.last_error_kind,
            .location = if (self.last_error_line == 0) null else .{
                .line = self.last_error_line,
                .column = self.last_error_column,
            },
            .context = self.last_error_context_buf[0..self.last_error_context_len],
        };
    }

    pub fn lastErrorStage(self: *Diagnostic) CompilationStage {
        return self.last_error_stage;
    }

    pub fn lastErrorMessage(self: *Diagnostic) []const u8 {
        return self.last_error_buf[0..self.last_error_len];
    }

    pub fn lastErrorLine(self: *Diagnostic) u32 {
        return self.last_error_line;
    }

    pub fn lastErrorColumn(self: *Diagnostic) u32 {
        return self.last_error_column;
    }
};
