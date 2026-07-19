const std = @import("std");
const wgsl = @import("doe").compiler.wgsl();

const host = wgsl.emit_csl_host;
const host_runtime = wgsl.emit_csl_host_runtime;

const SHA256_HEX_LEN: usize = 64;

const BundleConfigJson = struct {
    modelConfig: ?ModelConfigJson = null,
    session: ?SessionJson = null,

    const ModelConfigJson = struct {
        hiddenDim: u32,
        numHeads: u32,
        headDim: u32,
        linearKeyHeadDim: ?u32 = null,
        linearValueHeadDim: ?u32 = null,
        linearConvKernelDim: ?u32 = null,
        globalHeadDim: ?u32 = null,
        numKeyValueHeads: ?u32 = null,
        numLayers: u32,
        vocabSize: u32,
        maxSeqLen: u32,
        quantFormat: []const u8,
        ffnExpansionFactor: u32 = 4,
        ffnMatrixCount: u32 = 3,
        pleWidth: ?u32 = null,
        pleVocabSize: ?u32 = null,
        partialRotaryFactor: f32 = 1.0,
        mropeSection: ?[3]u32 = null,
    };

    const SessionJson = struct {
        compute: ?ComputeJson = null,

        const ComputeJson = struct {
            defaults: ?DefaultsJson = null,

            const DefaultsJson = struct {
                activationDtype: ?[]const u8 = null,
            };
        };
    };
};

pub fn parseBundleModelConfig(allocator: std.mem.Allocator, payload: []const u8) !?host.ModelConfig {
    const parsed = try std.json.parseFromSlice(BundleConfigJson, allocator, payload, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const model_config = parsed.value.modelConfig orelse return null;
    return .{
        .hidden_dim = model_config.hiddenDim,
        .num_heads = model_config.numHeads,
        .head_dim = model_config.headDim,
        .linear_key_head_dim = model_config.linearKeyHeadDim,
        .linear_value_head_dim = model_config.linearValueHeadDim,
        .linear_conv_kernel_dim = model_config.linearConvKernelDim,
        .global_head_dim = model_config.globalHeadDim,
        .num_key_value_heads = model_config.numKeyValueHeads,
        .num_layers = model_config.numLayers,
        .vocab_size = model_config.vocabSize,
        .max_seq_len = model_config.maxSeqLen,
        .quant_format = parseQuantFormat(model_config.quantFormat) orelse return error.InvalidArgument,
        .ffn_expansion_factor = model_config.ffnExpansionFactor,
        .ffn_matrix_count = model_config.ffnMatrixCount,
        .ple_width = model_config.pleWidth,
        .ple_vocab_size = model_config.pleVocabSize,
        .partial_rotary_factor = model_config.partialRotaryFactor,
        .mrope_section = model_config.mropeSection,
    };
}

pub fn parseBundleActivationDtype(allocator: std.mem.Allocator, payload: []const u8) !?[]const u8 {
    const parsed = try std.json.parseFromSlice(BundleConfigJson, allocator, payload, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const session = parsed.value.session orelse return null;
    const compute = session.compute orelse return null;
    const defaults = compute.defaults orelse return null;
    const dtype = defaults.activationDtype orelse return null;
    return try allocator.dupe(u8, dtype);
}

pub fn admitCslActivationDtype(dtype: ?[]const u8) !void {
    const raw = dtype orelse return;
    if (std.mem.eql(u8, raw, "f32")) return;
    if (std.mem.eql(u8, raw, "f16")) return;
    return error.InvalidArgument;
}

pub fn activationDtypeScalar(dtype: ?[]const u8) !wgsl.ir.ScalarType {
    const raw = dtype orelse return .f32;
    if (std.mem.eql(u8, raw, "f32")) return .f32;
    if (std.mem.eql(u8, raw, "f16")) return .f16;
    return error.InvalidArgument;
}

pub fn parseBundleWeightMappings(
    allocator: std.mem.Allocator,
    payload: []const u8,
) ![]const host_runtime.WeightMapping {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    const root = try jsonObject(parsed.value);
    const mappings_value = root.get("weightMappings") orelse return &.{};
    const mappings_array = try jsonArray(mappings_value);
    if (mappings_array.items.len == 0) return &.{};
    const mappings = try allocator.alloc(host_runtime.WeightMapping, mappings_array.items.len);
    errdefer allocator.free(mappings);
    for (mappings_array.items, 0..) |mapping_value, idx| {
        const mapping = try jsonObject(mapping_value);
        const pe_range = try parseWeightPeRange(mapping.get("peRange") orelse return error.InvalidArgument);
        const dtype_text = try jsonString(mapping.get("dtype") orelse return error.InvalidArgument);
        mappings[idx] = .{
            .shard_name = try allocator.dupe(u8, try jsonString(mapping.get("shard") orelse return error.InvalidArgument)),
            .shard_path = try allocator.dupe(u8, try jsonString(mapping.get("path") orelse return error.InvalidArgument)),
            .shard_sha256 = try allocator.dupe(u8, try parseSha256(try jsonString(mapping.get("sha256") orelse return error.InvalidArgument))),
            .pe_buffer = try allocator.dupe(u8, try jsonString(mapping.get("peBuffer") orelse return error.InvalidArgument)),
            .pe_start = pe_range.start,
            .pe_end = pe_range.end,
            .dtype = parseWeightDtype(dtype_text) orelse return error.InvalidArgument,
            .tensor_name = try allocator.dupe(u8, try jsonString(mapping.get("tensor") orelse return error.InvalidArgument)),
            .tensor_offset_bytes = try jsonU64(mapping.get("offsetBytes") orelse return error.InvalidArgument),
            .tensor_shape = try parseWeightShape(allocator, mapping.get("shape") orelse return error.InvalidArgument),
            .quant = try parseWeightQuant(allocator, mapping.get("quant") orelse return error.InvalidArgument),
        };
    }
    return mappings;
}

fn parseQuantFormat(raw: []const u8) ?host.ModelConfig.QuantFormat {
    if (std.mem.eql(u8, raw, "f16")) return .f16;
    if (std.mem.eql(u8, raw, "q4k")) return .q4k;
    if (std.mem.eql(u8, raw, "q8_0")) return .q8_0;
    return null;
}

fn parseWeightDtype(raw: []const u8) ?host_runtime.WeightMapping.Dtype {
    if (std.mem.eql(u8, raw, "f16")) return .f16;
    if (std.mem.eql(u8, raw, "u8_q4k")) return .u8_q4k;
    if (std.mem.eql(u8, raw, "u8_q8")) return .u8_q8;
    return null;
}

fn jsonObject(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.InvalidArgument,
    };
}

fn jsonArray(value: std.json.Value) !std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => error.InvalidArgument,
    };
}

fn jsonString(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |string| string,
        else => error.InvalidArgument,
    };
}

fn jsonU32(value: std.json.Value) !u32 {
    return switch (value) {
        .integer => |integer| std.math.cast(u32, integer) orelse error.InvalidArgument,
        else => error.InvalidArgument,
    };
}

fn jsonU64(value: std.json.Value) !u64 {
    return switch (value) {
        .integer => |integer| std.math.cast(u64, integer) orelse error.InvalidArgument,
        else => error.InvalidArgument,
    };
}

fn optionalJsonStringDup(allocator: std.mem.Allocator, value: ?std.json.Value) !?[]const u8 {
    const raw = value orelse return null;
    return switch (raw) {
        .null => null,
        else => try allocator.dupe(u8, try jsonString(raw)),
    };
}

fn optionalJsonU32(value: ?std.json.Value) !?u32 {
    const raw = value orelse return null;
    return switch (raw) {
        .null => null,
        else => try jsonU32(raw),
    };
}

fn parseSha256(raw: []const u8) ![]const u8 {
    if (raw.len != SHA256_HEX_LEN) return error.InvalidArgument;
    for (raw) |char| {
        const is_digit = char >= '0' and char <= '9';
        const is_lower_hex = char >= 'a' and char <= 'f';
        if (!is_digit and !is_lower_hex) return error.InvalidArgument;
    }
    return raw;
}

fn parseWeightPeRange(value: std.json.Value) !struct { start: u32, end: u32 } {
    const array = try jsonArray(value);
    if (array.items.len != 2) return error.InvalidArgument;
    const start = try jsonU32(array.items[0]);
    const end = try jsonU32(array.items[1]);
    if (end <= start) return error.InvalidArgument;
    return .{ .start = start, .end = end };
}

fn parseWeightShape(allocator: std.mem.Allocator, value: std.json.Value) ![]const u64 {
    const array = try jsonArray(value);
    if (array.items.len == 0) return error.InvalidArgument;
    const shape = try allocator.alloc(u64, array.items.len);
    errdefer allocator.free(shape);
    for (array.items, 0..) |item, idx| {
        const dim = try jsonU64(item);
        if (dim == 0) return error.InvalidArgument;
        shape[idx] = dim;
    }
    return shape;
}

fn parseWeightQuant(allocator: std.mem.Allocator, value: std.json.Value) !host_runtime.WeightMapping.QuantMetadata {
    const object = try jsonObject(value);
    return .{
        .format = try allocator.dupe(u8, try jsonString(object.get("format") orelse return error.InvalidArgument)),
        .storage_dtype = try allocator.dupe(u8, try jsonString(object.get("storageDtype") orelse return error.InvalidArgument)),
        .source_dtype = try optionalJsonStringDup(allocator, object.get("sourceDtype")),
        .block_size_elements = try optionalJsonU32(object.get("blockSizeElements")),
        .block_size_bytes = try optionalJsonU32(object.get("blockSizeBytes")),
        .encoding = try optionalJsonStringDup(allocator, object.get("encoding")),
    };
}
