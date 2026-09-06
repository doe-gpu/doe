const std = @import("std");
const wgsl_analysis = @import("../../compiler/wgsl/pipeline/analysis.zig");
const LAST_ERROR_CAP: usize = 512;
const LAST_ERROR_META_CAP: usize = 64;

pub const ShaderDiagnostic = struct {
    compiler: wgsl_analysis.Diagnostic = .{},
    last_error_buf: [LAST_ERROR_CAP]u8 = undefined,
    last_error_len: usize = 0,
    last_error_stage_buf: [LAST_ERROR_META_CAP]u8 = undefined,
    last_error_stage_len: usize = 0,
    last_error_kind_buf: [LAST_ERROR_META_CAP]u8 = undefined,
    last_error_kind_len: usize = 0,
    last_error_line: u32 = 0,
    last_error_col: u32 = 0,

    pub fn clear_last_error(self: *ShaderDiagnostic) void {
        self.compiler.clearLastError();
        self.last_error_len = 0;
        self.last_error_stage_len = 0;
        self.last_error_kind_len = 0;
        self.last_error_line = 0;
        self.last_error_col = 0;
    }

    pub fn set_last_error(self: *ShaderDiagnostic, message: []const u8) void {
        const len = @min(message.len, self.last_error_buf.len - 1);
        @memcpy(self.last_error_buf[0..len], message[0..len]);
        self.last_error_buf[len] = 0;
        self.last_error_len = len;
    }

    pub fn set_last_error_fmt(self: *ShaderDiagnostic, comptime fmt: []const u8, args: anytype) void {
        var writer = std.Io.Writer.fixed(&self.last_error_buf);
        writer.print(fmt, args) catch {};
        self.last_error_len = writer.buffered().len;
    }

    fn set_last_error_meta(buf: []u8, len_out: *usize, text: []const u8) void {
        const len = @min(text.len, buf.len - 1);
        @memcpy(buf[0..len], text[0..len]);
        buf[len] = 0;
        len_out.* = len;
    }

    pub fn set_last_error_stage_name(self: *ShaderDiagnostic, stage: []const u8) void {
        set_last_error_meta(&self.last_error_stage_buf, &self.last_error_stage_len, stage);
    }

    pub fn set_last_error_stage(self: *ShaderDiagnostic, stage: wgsl_analysis.CompilationStage) void {
        if (stage == .none) {
            self.last_error_stage_len = 0;
            return;
        }
        self.set_last_error_stage_name(@tagName(stage));
    }

    pub fn set_last_error_kind(self: *ShaderDiagnostic, kind: []const u8) void {
        set_last_error_meta(&self.last_error_kind_buf, &self.last_error_kind_len, kind);
    }

    pub fn capture_wgsl_error_location(self: *ShaderDiagnostic) void {
        self.last_error_line = self.compiler.lastErrorLine();
        self.last_error_col = self.compiler.lastErrorColumn();
    }

    pub fn capture_compile_error(self: *ShaderDiagnostic, err: anyerror, stage: []const u8, context: []const u8) void {
        self.set_last_error_kind(@errorName(err));
        const compiler_error = if (self.compiler.lastErrorKind()) |kind| kind == err else false;
        if (compiler_error and self.compiler.lastErrorStage() != .none) {
            self.set_last_error_stage(self.compiler.lastErrorStage());
            self.capture_wgsl_error_location();
            self.set_last_error_fmt("{s}: {s}", .{ context, self.compiler.lastErrorMessage() });
        } else {
            self.set_last_error_stage_name(stage);
            self.set_last_error_fmt("{s}: {s}", .{ context, @errorName(err) });
        }
    }
};
