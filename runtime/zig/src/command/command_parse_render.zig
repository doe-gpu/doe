const std = @import("std");
const model_commands = @import("../contracts/command.zig");
const model_render_types = @import("../contracts/model/model_render_types.zig");
const parse_helpers = @import("command_parse_helpers.zig");
const parse_extra = @import("command_json_extra.zig");
const command_kind = @import("command_kind.zig");
const command_json_raw = @import("command_json_raw.zig");

const Allocator = std.mem.Allocator;
const RawCommand = command_json_raw.RawCommand;
pub const ParseError = command_json_raw.ParseError;

const model = struct {
    pub const Command = model_commands.Command;
    pub const DEFAULT_RENDER_TARGET_FORMAT = model_render_types.DEFAULT_RENDER_TARGET_FORMAT;
    pub const DEFAULT_RENDER_TARGET_HANDLE = model_render_types.DEFAULT_RENDER_TARGET_HANDLE;
    pub const DEFAULT_RENDER_TARGET_HEIGHT = model_render_types.DEFAULT_RENDER_TARGET_HEIGHT;
    pub const DEFAULT_RENDER_TARGET_WIDTH = model_render_types.DEFAULT_RENDER_TARGET_WIDTH;
    pub const RenderDrawCommand = model_render_types.RenderDrawCommand;
};

pub fn parseRenderCommand(allocator: Allocator, kind: command_kind.NormalizedKind, raw: RawCommand) !model.Command {
    const draw_count = raw.draw_count orelse raw.drawCount orelse return ParseError.InvalidCommandPayload;
    const vertex_count = raw.vertex_count orelse raw.vertexCount orelse 3;
    const instance_count = raw.instance_count orelse raw.instanceCount orelse 1;
    const first_vertex = raw.first_vertex orelse raw.firstVertex orelse 0;
    const first_instance = raw.first_instance orelse raw.firstInstance orelse 0;
    const parsed_index_count = raw.index_count orelse raw.indexCount;
    const is_draw_indexed = blk: {
        const command_name = command_kind.getCommandName(raw) orelse break :blk false;
        break :blk command_kind.commandKindEquals(command_name, "draw_indexed") or command_kind.commandKindEquals(command_name, "draw_indexed_indirect");
    };
    const raw_index_data = raw.index_data orelse raw.indexData orelse raw.indices;
    const indexed_draw = is_draw_indexed or parsed_index_count != null or raw_index_data != null;
    const requested_index_format = parse_helpers.parseRenderIndexFormat(raw.index_format orelse raw.indexFormat) catch return ParseError.InvalidCommandPayload;
    const index_data = if (indexed_draw) blk: {
        const provided = raw_index_data orelse return ParseError.InvalidCommandPayload;
        if (provided.len == 0) return ParseError.InvalidCommandPayload;
        break :blk parse_helpers.parseRenderIndexData(allocator, provided, requested_index_format) catch return ParseError.InvalidCommandPayload;
    } else null;
    errdefer if (index_data) |values| switch (values) {
        .uint16 => |items| allocator.free(items),
        .uint32 => |items| allocator.free(items),
    };
    const index_data_len_u32 = if (index_data) |values| switch (values) {
        .uint16 => |items| std.math.cast(u32, items.len) orelse return ParseError.InvalidCommandPayload,
        .uint32 => |items| std.math.cast(u32, items.len) orelse return ParseError.InvalidCommandPayload,
    } else 0;
    const index_count = if (parsed_index_count) |count| count else if (indexed_draw) index_data_len_u32 else null;
    const first_index = raw.first_index orelse raw.firstIndex orelse 0;
    const base_vertex = raw.base_vertex orelse raw.baseVertex orelse 0;
    const target_handle = raw.target_handle orelse raw.targetHandle orelse model.DEFAULT_RENDER_TARGET_HANDLE;
    const target_width = raw.target_width orelse raw.targetWidth orelse model.DEFAULT_RENDER_TARGET_WIDTH;
    const target_height = raw.target_height orelse raw.targetHeight orelse model.DEFAULT_RENDER_TARGET_HEIGHT;
    const target_format = if (raw.target_format orelse raw.targetFormat) |raw_format|
        parse_helpers.parseTextureFormat(raw_format) catch return ParseError.InvalidCommandPayload
    else
        model.DEFAULT_RENDER_TARGET_FORMAT;
    const pipeline_mode = parse_helpers.parseRenderDrawPipelineMode(raw.pipeline_mode orelse raw.pipelineMode) catch return ParseError.InvalidCommandPayload;
    const bind_group_mode = parse_helpers.parseRenderDrawBindGroupMode(raw.bind_group_mode orelse raw.bindGroupMode) catch return ParseError.InvalidCommandPayload;
    const encode_mode = parse_extra.parseRenderDrawEncodeMode(raw.encode_mode orelse raw.encodeMode) catch return ParseError.InvalidCommandPayload;
    const viewport_x = raw.viewport_x orelse raw.viewportX orelse 0;
    const viewport_y = raw.viewport_y orelse raw.viewportY orelse 0;
    const viewport_width = raw.viewport_width orelse raw.viewportWidth;
    const viewport_height = raw.viewport_height orelse raw.viewportHeight;
    const viewport_min_depth = raw.viewport_min_depth orelse raw.viewportMinDepth orelse 0;
    const viewport_max_depth = raw.viewport_max_depth orelse raw.viewportMaxDepth orelse 1;
    const scissor_x = raw.scissor_x orelse raw.scissorX orelse 0;
    const scissor_y = raw.scissor_y orelse raw.scissorY orelse 0;
    const scissor_width = raw.scissor_width orelse raw.scissorWidth;
    const scissor_height = raw.scissor_height orelse raw.scissorHeight;
    const blend_r = raw.blend_r orelse raw.blendR orelse 0;
    const blend_g = raw.blend_g orelse raw.blendG orelse 0;
    const blend_b = raw.blend_b orelse raw.blendB orelse 0;
    const blend_a = raw.blend_a orelse raw.blendA orelse 0;
    const stencil_reference = raw.stencil_reference orelse raw.stencilReference orelse 0;
    const dynamic_offsets = if (raw.bind_group_dynamic_offsets orelse raw.bindGroupDynamicOffsets) |offsets| blk: {
        const copied = try allocator.alloc(u32, offsets.len);
        errdefer allocator.free(copied);
        @memcpy(copied, offsets);
        break :blk copied;
    } else null;
    errdefer if (dynamic_offsets) |offsets| allocator.free(offsets);

    if (draw_count == 0 or vertex_count == 0 or instance_count == 0 or target_width == 0 or target_height == 0) {
        return ParseError.InvalidCommandPayload;
    }
    if (viewport_min_depth < 0 or viewport_min_depth > 1 or viewport_max_depth < 0 or viewport_max_depth > 1 or viewport_max_depth < viewport_min_depth) {
        return ParseError.InvalidCommandPayload;
    }
    if (index_count != null and index_count.? == 0) return ParseError.InvalidCommandPayload;
    if (index_count != null) {
        const index_end = std.math.add(u32, first_index, index_count.?) catch return ParseError.InvalidCommandPayload;
        if (index_end > index_data_len_u32) return ParseError.InvalidCommandPayload;
    }

    const render_command: model.RenderDrawCommand = .{
        .draw_count = draw_count,
        .vertex_count = vertex_count,
        .instance_count = instance_count,
        .first_vertex = first_vertex,
        .first_instance = first_instance,
        .index_count = index_count,
        .first_index = first_index,
        .base_vertex = base_vertex,
        .index_data = index_data,
        .target_handle = target_handle,
        .target_width = target_width,
        .target_height = target_height,
        .target_format = target_format,
        .pipeline_mode = pipeline_mode,
        .bind_group_mode = bind_group_mode,
        .encode_mode = encode_mode,
        .viewport_x = viewport_x,
        .viewport_y = viewport_y,
        .viewport_width = viewport_width,
        .viewport_height = viewport_height,
        .viewport_min_depth = viewport_min_depth,
        .viewport_max_depth = viewport_max_depth,
        .scissor_x = scissor_x,
        .scissor_y = scissor_y,
        .scissor_width = scissor_width,
        .scissor_height = scissor_height,
        .blend_constant = .{ blend_r, blend_g, blend_b, blend_a },
        .stencil_reference = stencil_reference,
        .bind_group_dynamic_offsets = dynamic_offsets,
    };
    return switch (kind) {
        .render_draw => .{ .render_draw = render_command },
        .draw_indirect => .{ .draw_indirect = render_command },
        .draw_indexed_indirect => .{ .draw_indexed_indirect = render_command },
        .render_pass => .{ .render_pass = render_command },
        else => unreachable,
    };
}
