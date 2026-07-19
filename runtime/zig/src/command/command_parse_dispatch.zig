const std = @import("std");
const model_commands = @import("../contracts/model/model_commands.zig");
const model_compute_types = @import("../contracts/model/model_compute_types.zig");
const model_binding_types = @import("../contracts/model/model_binding_value_types.zig");
const model_texture_types = @import("../contracts/model/model_texture_value_types.zig");
const parse_helpers = @import("command_parse_helpers.zig");
const command_kind = @import("command_kind.zig");
const command_json_raw = @import("command_json_raw.zig");

const Allocator = std.mem.Allocator;
const RawCommand = command_json_raw.RawCommand;
const RawKernelBinding = command_json_raw.RawKernelBinding;
pub const ParseError = command_json_raw.ParseError;

const model = struct {
    pub const Command = model_commands.Command;
    pub const DispatchCommand = model_compute_types.DispatchCommand;
    pub const KernelBinding = model_compute_types.KernelBinding;
    pub const WGPUShaderStage_Compute = model_binding_types.WGPUShaderStage_Compute;
    pub const WGPUWholeSize = model_texture_types.WGPUWholeSize;
};

fn parseDispatchDimensions(raw: RawCommand) !model.DispatchCommand {
    const dims: [3]u32 = raw.workgroupCount orelse raw.workgroups orelse .{
        raw.x orelse 1,
        raw.y orelse 1,
        raw.z orelse 1,
    };

    if (dims[0] == 0 or dims[1] == 0 or dims[2] == 0) {
        return ParseError.InvalidCommandPayload;
    }

    return .{ .x = dims[0], .y = dims[1], .z = dims[2] };
}

fn parseKernelBindings(allocator: Allocator, raw_bindings: []const RawKernelBinding) ![]const model.KernelBinding {
    var bindings = try std.ArrayList(model.KernelBinding).initCapacity(allocator, raw_bindings.len);
    errdefer bindings.deinit(allocator);

    for (raw_bindings) |raw_binding| {
        const binding_index = raw_binding.binding orelse return ParseError.InvalidCommandPayload;
        const group = raw_binding.group orelse raw_binding.groupIndex orelse raw_binding.group_index orelse 0;
        const handle = raw_binding.handle orelse raw_binding.resource_handle orelse raw_binding.resourceHandle orelse return ParseError.InvalidCommandPayload;
        const kind = parse_helpers.parseKernelBindingKind(raw_binding.kind orelse raw_binding.resource_kind orelse raw_binding.resourceKind) orelse return ParseError.InvalidCommandPayload;
        const visibility = parse_helpers.parseShaderStage(raw_binding.visibility) orelse parse_helpers.parseWGPUBits(raw_binding.visibilityMask) orelse model.WGPUShaderStage_Compute;
        const buffer_offset = raw_binding.buffer_offset orelse raw_binding.bufferOffset orelse 0;
        const buffer_size = raw_binding.buffer_size orelse raw_binding.bufferSize orelse model.WGPUWholeSize;

        try bindings.append(allocator, .{
            .binding = binding_index,
            .group = group,
            .resource_kind = kind,
            .resource_handle = handle,
            .visibility = visibility,
            .buffer_offset = buffer_offset,
            .buffer_size = buffer_size,
            .buffer_type = parse_helpers.parseBufferBindingType(raw_binding.buffer_type orelse raw_binding.bufferType),
            .texture_sample_type = parse_helpers.parseTextureSampleType(raw_binding.texture_sample_type orelse raw_binding.textureSampleType),
            .texture_view_dimension = parse_helpers.parseTextureViewDimension(raw_binding.texture_view_dimension orelse raw_binding.textureViewDimension),
            .storage_texture_access = parse_helpers.parseStorageTextureAccess(raw_binding.storage_access orelse raw_binding.storageAccess),
            .texture_aspect = parse_helpers.parseTextureAspect(raw_binding.texture_aspect orelse raw_binding.textureAspect),
            .texture_format = if (raw_binding.texture_format orelse raw_binding.textureFormat) |raw_format|
                parse_helpers.parseTextureFormat(raw_format) catch return ParseError.InvalidCommandPayload
            else
                0,
            .texture_multisampled = raw_binding.multisampled orelse false,
        });
    }

    return bindings.toOwnedSlice(allocator);
}

pub fn parseDispatchCommand(allocator: Allocator, kind: command_kind.NormalizedKind, raw: RawCommand) !model.Command {
    const dispatch = try parseDispatchDimensions(raw);
    if (kind == .kernel_dispatch) {
        const repeat_count = raw.repeat orelse raw.dispatch_count orelse raw.dispatchCount orelse 1;
        if (repeat_count == 0) return ParseError.InvalidCommandPayload;
        const kernel_name = try allocator.dupe(u8, raw.kernel orelse raw.kernel_name orelse return ParseError.InvalidCommandPayload);
        errdefer allocator.free(kernel_name);
        const entry_point = if (raw.entry_point) |entry|
            try allocator.dupe(u8, entry)
        else if (raw.entryPoint) |entry|
            try allocator.dupe(u8, entry)
        else
            null;
        errdefer if (entry_point) |entry| allocator.free(entry);
        const kernel_bindings = if (raw.bindings) |raw_bindings| try parseKernelBindings(allocator, raw_bindings) else null;
        errdefer if (kernel_bindings) |bindings| allocator.free(bindings);
        const repeat_synchronization = parse_helpers.parseKernelDispatchRepeatSynchronization(
            raw.repeat_synchronization orelse raw.repeatSynchronization,
        ) catch return ParseError.InvalidCommandPayload;
        return .{
            .kernel_dispatch = .{
                .kernel = kernel_name,
                .entry_point = entry_point,
                .x = dispatch.x,
                .y = dispatch.y,
                .z = dispatch.z,
                .repeat = repeat_count,
                .repeat_synchronization = repeat_synchronization,
                .warmup_dispatch_count = raw.warmup_dispatch_count orelse raw.warmupDispatchCount orelse 0,
                .initialize_buffers_on_create = raw.initialize_buffers_on_create orelse raw.initializeBuffersOnCreate orelse false,
                .bindings = kernel_bindings,
            },
        };
    }
    if (kind == .dispatch_indirect) {
        return .{ .dispatch_indirect = dispatch };
    }
    return .{ .dispatch = dispatch };
}
