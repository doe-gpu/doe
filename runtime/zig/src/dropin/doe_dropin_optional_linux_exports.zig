const std = @import("std");
const wgsl_compiler = @import("../compiler/wgsl/mod.zig");

comptime {
    _ = @import("../native/command/doe_encoder_native.zig");
    _ = @import("../native/resource/doe_command_texture_native.zig");
}

const LAST_ERROR_CAP: usize = 512;
const LAST_ERROR_META_CAP: usize = 64;
const MAGIC_SHADER: u32 = 0xD0E1_0006;
const MAX_SHADER_BINDINGS: usize = wgsl_compiler.MAX_BINDINGS;

const BindingInfo = extern struct {
    group: u32,
    binding: u32,
    kind: u32,
    addr_space: u32,
    access: u32,
};

const DoeShaderModule = extern struct {
    magic: u32,
    mtl_library: ?*anyopaque,
    bindings: [MAX_SHADER_BINDINGS]BindingInfo,
    binding_count: u32,
    wg_x: u32,
    wg_y: u32,
    wg_z: u32,
    needs_sizes_buf: bool,
};

var last_error_buf: [LAST_ERROR_CAP]u8 = undefined;
var last_error_len: usize = 0;
var last_error_stage_buf: [LAST_ERROR_META_CAP]u8 = undefined;
var last_error_stage_len: usize = 0;
var last_error_kind_buf: [LAST_ERROR_META_CAP]u8 = undefined;
var last_error_kind_len: usize = 0;
var last_error_line: u32 = 0;
var last_error_col: u32 = 0;

fn clear_last_error() void {
    last_error_len = 0;
    last_error_stage_len = 0;
    last_error_kind_len = 0;
    last_error_line = 0;
    last_error_col = 0;
}

fn set_last_error(message: []const u8) void {
    const len = @min(message.len, last_error_buf.len - 1);
    @memcpy(last_error_buf[0..len], message[0..len]);
    last_error_buf[len] = 0;
    last_error_len = len;
}

fn set_last_error_fmt(comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.bufPrint(&last_error_buf, fmt, args) catch {
        last_error_len = 0;
        return;
    };
    last_error_len = text.len;
}

fn set_last_error_meta(buf: []u8, len_out: *usize, text: []const u8) void {
    const len = @min(text.len, buf.len - 1);
    @memcpy(buf[0..len], text[0..len]);
    buf[len] = 0;
    len_out.* = len;
}

fn set_last_error_stage_name(stage: []const u8) void {
    set_last_error_meta(&last_error_stage_buf, &last_error_stage_len, stage);
}

fn set_last_error_stage(stage: wgsl_compiler.CompilationStage) void {
    if (stage == .none) {
        last_error_stage_len = 0;
        return;
    }
    set_last_error_stage_name(@tagName(stage));
}

fn set_last_error_kind(kind: []const u8) void {
    set_last_error_meta(&last_error_kind_buf, &last_error_kind_len, kind);
}

fn capture_wgsl_error_location() void {
    last_error_line = wgsl_compiler.lastErrorLine();
    last_error_col = wgsl_compiler.lastErrorColumn();
}

pub export fn doeNativeCopyLastErrorMessage(out_ptr: ?[*]u8, out_len: usize) callconv(.c) usize {
    if (out_ptr == null or out_len == 0 or last_error_len == 0) return last_error_len;
    const dst = out_ptr.?[0..out_len];
    const copy_len = @min(last_error_len, out_len - 1);
    @memcpy(dst[0..copy_len], last_error_buf[0..copy_len]);
    dst[copy_len] = 0;
    return last_error_len;
}

pub export fn doeNativeCopyLastErrorStage(out_ptr: ?[*]u8, out_len: usize) callconv(.c) usize {
    if (out_ptr == null or out_len == 0 or last_error_stage_len == 0) return last_error_stage_len;
    const dst = out_ptr.?[0..out_len];
    const copy_len = @min(last_error_stage_len, out_len - 1);
    @memcpy(dst[0..copy_len], last_error_stage_buf[0..copy_len]);
    dst[copy_len] = 0;
    return last_error_stage_len;
}

pub export fn doeNativeCopyLastErrorKind(out_ptr: ?[*]u8, out_len: usize) callconv(.c) usize {
    if (out_ptr == null or out_len == 0 or last_error_kind_len == 0) return last_error_kind_len;
    const dst = out_ptr.?[0..out_len];
    const copy_len = @min(last_error_kind_len, out_len - 1);
    @memcpy(dst[0..copy_len], last_error_kind_buf[0..copy_len]);
    dst[copy_len] = 0;
    return last_error_kind_len;
}

pub export fn doeNativeGetLastErrorLine() callconv(.c) u32 {
    return last_error_line;
}

pub export fn doeNativeGetLastErrorColumn() callconv(.c) u32 {
    return last_error_col;
}

pub export fn doeNativeCheckShaderSource(code_ptr: ?[*]const u8, code_len: usize) callconv(.c) u32 {
    clear_last_error();
    const ptr = code_ptr orelse {
        set_last_error_stage_name("native_check");
        set_last_error_kind("InvalidInput");
        set_last_error("shader check failed: WGSL source pointer is null");
        return 0;
    };
    const wgsl = ptr[0..code_len];
    var msl_buf: [wgsl_compiler.MAX_OUTPUT]u8 = undefined;
    _ = wgsl_compiler.translateToMsl(std.heap.page_allocator, wgsl, &msl_buf) catch |err| {
        set_last_error_stage(wgsl_compiler.lastErrorStage());
        set_last_error_kind(@errorName(err));
        capture_wgsl_error_location();
        const detail = wgsl_compiler.lastErrorMessage();
        if (detail.len > 0) {
            set_last_error(detail);
        } else {
            set_last_error_fmt("{s}: {s}", .{ @tagName(wgsl_compiler.lastErrorStage()), @errorName(err) });
        }
        return 0;
    };
    return 1;
}

pub export fn doeNativeShaderModuleGetBindings(
    raw: ?*anyopaque,
    out_ptr: ?[*]BindingInfo,
    out_len: usize,
) callconv(.c) usize {
    const ptr = raw orelse return 0;
    const sm: *DoeShaderModule = @ptrCast(@alignCast(ptr));
    if (sm.magic != MAGIC_SHADER) return 0;
    const count: usize = @intCast(sm.binding_count);
    if (out_ptr) |out| {
        const copy_len = @min(count, out_len);
        @memcpy(out[0..copy_len], sm.bindings[0..copy_len]);
    }
    return count;
}

pub export fn doeNativeComputePassSetImmediates(
    pass_raw: ?*anyopaque,
    index: u32,
    data_ptr: ?[*]const u8,
    data_len: usize,
) callconv(.c) void {
    _ = pass_raw;
    _ = index;
    _ = data_ptr;
    _ = data_len;
}

pub export fn doeNativeRenderPassSetImmediates(
    pass_raw: ?*anyopaque,
    index: u32,
    data_ptr: ?[*]const u8,
    data_len: usize,
) callconv(.c) void {
    _ = pass_raw;
    _ = index;
    _ = data_ptr;
    _ = data_len;
}

pub export fn doeNativeRenderBundleEncoderSetImmediates(
    encoder_raw: ?*anyopaque,
    index: u32,
    data_ptr: ?[*]const u8,
    data_len: usize,
) callconv(.c) void {
    _ = encoder_raw;
    _ = index;
    _ = data_ptr;
    _ = data_len;
}

pub export fn doeNativeRenderPassSetViewport(
    pass_raw: ?*anyopaque,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    min_depth: f64,
    max_depth: f64,
) callconv(.c) void {
    _ = pass_raw;
    _ = x;
    _ = y;
    _ = width;
    _ = height;
    _ = min_depth;
    _ = max_depth;
}

pub export fn doeNativeRenderPassSetScissorRect(
    pass_raw: ?*anyopaque,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
) callconv(.c) void {
    _ = pass_raw;
    _ = x;
    _ = y;
    _ = width;
    _ = height;
}

pub export fn doeNativeRenderPassSetBlendConstant(
    pass_raw: ?*anyopaque,
    r: f64,
    g: f64,
    b: f64,
    a: f64,
) callconv(.c) void {
    _ = pass_raw;
    _ = r;
    _ = g;
    _ = b;
    _ = a;
}

pub export fn doeNativeRenderPassSetStencilReference(
    pass_raw: ?*anyopaque,
    reference: u32,
) callconv(.c) void {
    _ = pass_raw;
    _ = reference;
}

pub export fn doeNativeRenderPassBeginOcclusionQuery(
    pass_raw: ?*anyopaque,
    query_index: u32,
) callconv(.c) void {
    _ = pass_raw;
    _ = query_index;
}

pub export fn doeNativeRenderPassEndOcclusionQuery(pass_raw: ?*anyopaque) callconv(.c) void {
    _ = pass_raw;
}

pub export fn doeNativeQuerySetDestroy(qs_raw: ?*anyopaque) callconv(.c) void {
    _ = qs_raw;
}

pub export fn doeNativeQuerySetGetCount(qs_raw: ?*anyopaque) callconv(.c) u32 {
    _ = qs_raw;
    return 0;
}

pub export fn doeNativeQuerySetGetType(qs_raw: ?*anyopaque) callconv(.c) u32 {
    _ = qs_raw;
    return 0;
}
