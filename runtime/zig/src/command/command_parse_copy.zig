const std = @import("std");
const model_commands = @import("../contracts/model/model_commands.zig");
const model_resource_types = @import("../contracts/model/model_resource_types.zig");
const model_texture_types = @import("../contracts/model/model_texture_value_types.zig");
const parse_helpers = @import("command_parse_helpers.zig");
const command_kind = @import("command_kind.zig");
const command_json_raw = @import("command_json_raw.zig");

const RawCommand = command_json_raw.RawCommand;
pub const ParseError = command_json_raw.ParseError;

const model = struct {
    pub const Command = model_commands.Command;
    pub const CopyDirection = model_resource_types.CopyDirection;
    pub const CopyResourceKind = model_resource_types.CopyResourceKind;
    pub const CopyTextureResource = model_resource_types.CopyTextureResource;
    pub const WGPUTextureFormat_Undefined = model_texture_types.WGPUTextureFormat_Undefined;
};

fn parseCopyResource(
    side: []const u8,
    raw: RawCommand,
    default_kind: model.CopyResourceKind,
    direction_default_to_texture: bool,
) !model.CopyTextureResource {
    const handle = if (std.mem.eql(u8, side, "src"))
        (raw.src_handle orelse raw.srcHandle)
    else
        (raw.dst_handle orelse raw.dstHandle);

    if (handle == null) return ParseError.InvalidCommandPayload;

    const kind = parse_helpers.parseCopyResourceKind(if (std.mem.eql(u8, side, "src")) raw.src_kind orelse raw.srcKind else raw.dst_kind orelse raw.dstKind) orelse default_kind;
    const width = if (std.mem.eql(u8, side, "src"))
        (raw.src_width orelse raw.srcWidth orelse 1)
    else
        (raw.dst_width orelse raw.dstWidth orelse 1);
    const height = if (std.mem.eql(u8, side, "src"))
        (raw.src_height orelse raw.srcHeight orelse 1)
    else
        (raw.dst_height orelse raw.dstHeight orelse 1);
    const depth = if (std.mem.eql(u8, side, "src"))
        (raw.src_depth_or_array_layers orelse raw.srcDepthOrArrayLayers orelse raw.src_depth orelse 1)
    else
        (raw.dst_depth_or_array_layers orelse raw.dstDepthOrArrayLayers orelse raw.dst_depth orelse 1);
    const format_raw = if (std.mem.eql(u8, side, "src"))
        (raw.src_format orelse raw.srcFormat)
    else
        (raw.dst_format orelse raw.dstFormat);
    const usage = if (std.mem.eql(u8, side, "src"))
        (raw.src_usage orelse raw.srcUsage orelse 0)
    else
        (raw.dst_usage orelse raw.dstUsage orelse 0);
    const dimension = if (std.mem.eql(u8, side, "src"))
        parse_helpers.parseTextureDimension(raw.src_dimension orelse raw.srcDimension)
    else
        parse_helpers.parseTextureDimension(raw.dst_dimension orelse raw.dstDimension);
    const view_dimension = if (std.mem.eql(u8, side, "src"))
        parse_helpers.parseTextureViewDimension(raw.src_view_dimension orelse raw.srcViewDimension)
    else
        parse_helpers.parseTextureViewDimension(raw.dst_view_dimension orelse raw.dstViewDimension);
    const mip_level = if (std.mem.eql(u8, side, "src"))
        (raw.src_mip_level orelse raw.srcMipLevel orelse 0)
    else
        (raw.dst_mip_level orelse raw.dstMipLevel orelse 0);
    const sample_count = if (std.mem.eql(u8, side, "src"))
        (raw.src_sample_count orelse raw.srcSampleCount orelse 1)
    else
        (raw.dst_sample_count orelse raw.dstSampleCount orelse 1);
    const aspect = if (std.mem.eql(u8, side, "src"))
        parse_helpers.parseTextureAspect(raw.src_aspect orelse raw.srcAspect)
    else
        parse_helpers.parseTextureAspect(raw.dst_aspect orelse raw.dstAspect);
    const bytes_per_row = if (std.mem.eql(u8, side, "src"))
        (raw.src_bytes_per_row orelse raw.srcBytesPerRow orelse 0)
    else
        (raw.dst_bytes_per_row orelse raw.dstBytesPerRow orelse 0);
    const rows_per_image = if (std.mem.eql(u8, side, "src"))
        (raw.src_rows_per_image orelse raw.srcRowsPerImage orelse 0)
    else
        (raw.dst_rows_per_image orelse raw.dstRowsPerImage orelse 0);
    const offset = if (std.mem.eql(u8, side, "src"))
        (raw.src_offset orelse raw.srcOffset orelse 0)
    else
        (raw.dst_offset orelse raw.dstOffset orelse 0);

    var effective_kind = kind;
    if (kind == .buffer and direction_default_to_texture) {
        effective_kind = .texture;
    }

    var texture_format: u32 = model.WGPUTextureFormat_Undefined;
    if (format_raw) |raw_format| {
        texture_format = parse_helpers.parseTextureFormat(raw_format) catch return ParseError.InvalidCommandPayload;
    }

    return .{
        .handle = handle.?,
        .kind = effective_kind,
        .width = width,
        .height = height,
        .depth_or_array_layers = depth,
        .format = texture_format,
        .usage = usage,
        .dimension = dimension,
        .view_dimension = view_dimension,
        .mip_level = mip_level,
        .sample_count = sample_count,
        .aspect = aspect,
        .bytes_per_row = bytes_per_row,
        .rows_per_image = rows_per_image,
        .offset = offset,
    };
}

pub fn parseCopyCommand(raw: RawCommand) !model.Command {
    const bytes = raw.bytes orelse return ParseError.InvalidCommandPayload;
    const direction = parse_helpers.parseCopyDirection(raw.direction, command_kind.getCommandName(raw)) catch return ParseError.InvalidCommandPayload;
    const default_src_kind: model.CopyResourceKind = switch (direction) {
        .buffer_to_buffer, .buffer_to_texture => .buffer,
        .texture_to_buffer, .texture_to_texture => .texture,
    };
    const default_dst_kind: model.CopyResourceKind = switch (direction) {
        .buffer_to_buffer, .texture_to_buffer => .buffer,
        .buffer_to_texture, .texture_to_texture => .texture,
    };

    const src = try parseCopyResource("src", raw, default_src_kind, direction == .texture_to_buffer or direction == .texture_to_texture);
    const dst = try parseCopyResource("dst", raw, default_dst_kind, direction == .buffer_to_texture or direction == .texture_to_texture);

    return .{
        .copy_buffer_to_texture = .{
            .direction = direction,
            .src = src,
            .dst = dst,
            .bytes = bytes,
        },
    };
}
