const std = @import("std");

const Allocator = std.mem.Allocator;
const Json = std.json;

pub const PlanLoadError = error{
    InvalidPlan,
    MissingField,
    UnsupportedCommand,
    InvalidField,
    OutOfMemory,
};

pub const BufferWriteCommand = struct {
    handle: u64,
    offset: u64,
    buffer_size: u64,
    data: []u32,
};

pub const BufferLoadCommand = struct {
    handle: u64,
    offset: u64,
    buffer_size: u64,
    cache_namespace: []const u8,
    cache_key: []const u8,
    asset_key: ?[]const u8,
    generator: []const u8,
    seed: u64,
    scale: f64,
    byte_length: u64,
};

pub const BufferBindingType = enum {
    uniform,
    storage,
    read_only_storage,
};

pub const KernelBinding = struct {
    group: u32,
    binding: u32,
    resource_handle: u64,
    buffer_size: u64,
    buffer_type: BufferBindingType,
};

pub const KernelDispatchCommand = struct {
    kernel: []const u8,
    entry_point: []const u8,
    x: u32,
    y: u32,
    z: u32,
    initialize_buffers_on_create: bool,
    bindings: []KernelBinding,
};

pub const Command = union(enum) {
    buffer_write: BufferWriteCommand,
    buffer_load: BufferLoadCommand,
    kernel_dispatch: KernelDispatchCommand,
};

pub const Plan = struct {
    schema_version: u32,
    plan_kind: []const u8,
    workload_id: []const u8,
    ir_path: []const u8,
    ir_scenario: []const u8,
    description: ?[]const u8,
    plan_path: ?[]const u8,
    commands_path: ?[]const u8,
    command_count: u32,
    buffer_write_count: u32,
    buffer_load_count: u32,
    dispatch_count: u32,
    source_ir_sha256: []const u8,
    compatibility_commands_sha256: []const u8,
    plan_sha256: []const u8,
    commands: []Command,
};

pub const LoadedPlan = struct {
    arena: std.heap.ArenaAllocator,
    plan: Plan,

    pub fn deinit(self: *LoadedPlan) void {
        self.arena.deinit();
    }
};

fn expectObject(value: Json.Value) PlanLoadError!Json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.InvalidPlan,
    };
}

fn expectArray(value: Json.Value) PlanLoadError!Json.Array {
    return switch (value) {
        .array => |array| array,
        else => error.InvalidPlan,
    };
}

fn expectString(value: Json.Value) PlanLoadError![]const u8 {
    return switch (value) {
        .string => |string| string,
        else => error.InvalidPlan,
    };
}

fn expectBool(value: Json.Value) PlanLoadError!bool {
    return switch (value) {
        .bool => |flag| flag,
        else => error.InvalidPlan,
    };
}

fn expectU64(value: Json.Value) PlanLoadError!u64 {
    return switch (value) {
        .integer => |number| std.math.cast(u64, number) orelse error.InvalidPlan,
        .float => |number| {
            if (number < 0.0 or number > @as(f64, @floatFromInt(std.math.maxInt(u64)))) return error.InvalidPlan;
            if (@trunc(number) != number) return error.InvalidPlan;
            return @as(u64, @intFromFloat(number));
        },
        else => error.InvalidPlan,
    };
}

fn expectU32(value: Json.Value) PlanLoadError!u32 {
    return std.math.cast(u32, try expectU64(value)) orelse error.InvalidPlan;
}

fn expectF64(value: Json.Value) PlanLoadError!f64 {
    return switch (value) {
        .integer => |number| @as(f64, @floatFromInt(number)),
        .float => |number| number,
        else => error.InvalidPlan,
    };
}

fn fieldValue(object: Json.ObjectMap, names: []const []const u8) ?Json.Value {
    for (names) |name| {
        if (object.get(name)) |value| return value;
    }
    return null;
}

fn requiredField(object: Json.ObjectMap, names: []const []const u8) PlanLoadError!Json.Value {
    return fieldValue(object, names) orelse error.MissingField;
}

fn optionalString(object: Json.ObjectMap, names: []const []const u8) PlanLoadError!?[]const u8 {
    if (fieldValue(object, names)) |value| {
        if (value == .null) return null;
        return try expectString(value);
    }
    return null;
}

fn optionalBool(object: Json.ObjectMap, names: []const []const u8) PlanLoadError!?bool {
    if (fieldValue(object, names)) |value| {
        if (value == .null) return null;
        return try expectBool(value);
    }
    return null;
}

fn optionalU64(object: Json.ObjectMap, names: []const []const u8) PlanLoadError!?u64 {
    if (fieldValue(object, names)) |value| {
        if (value == .null) return null;
        return try expectU64(value);
    }
    return null;
}

fn parseBufferBindingType(value: []const u8) PlanLoadError!BufferBindingType {
    if (std.ascii.eqlIgnoreCase(value, "uniform")) return .uniform;
    if (std.ascii.eqlIgnoreCase(value, "storage")) return .storage;
    if (std.ascii.eqlIgnoreCase(value, "readonly") or
        std.ascii.eqlIgnoreCase(value, "read_only_storage") or
        std.ascii.eqlIgnoreCase(value, "read-only-storage") or
        std.ascii.eqlIgnoreCase(value, "readonly_storage"))
    {
        return .read_only_storage;
    }
    return error.InvalidField;
}

fn parseU32Array(allocator: Allocator, value: Json.Value) PlanLoadError![]u32 {
    const array = try expectArray(value);
    const out = try allocator.alloc(u32, array.items.len);
    for (array.items, 0..) |item, idx| {
        out[idx] = try expectU32(item);
    }
    return out;
}

fn parseBufferWrite(allocator: Allocator, object: Json.ObjectMap) PlanLoadError!BufferWriteCommand {
    const handle = try expectU64(try requiredField(object, &.{ "handle", "resource_handle", "resourceHandle" }));
    const offset = if (fieldValue(object, &.{ "offset", "buffer_offset", "bufferOffset" })) |value|
        try expectU64(value)
    else
        0;
    const buffer_size = if (fieldValue(object, &.{ "bufferSize", "buffer_size" })) |value|
        try expectU64(value)
    else
        0;
    const data = try parseU32Array(allocator, try requiredField(object, &.{"data"}));
    return .{
        .handle = handle,
        .offset = offset,
        .buffer_size = buffer_size,
        .data = data,
    };
}

fn parseBufferLoad(allocator: Allocator, object: Json.ObjectMap) PlanLoadError!BufferLoadCommand {
    const handle = try expectU64(try requiredField(object, &.{ "handle", "resource_handle", "resourceHandle" }));
    const offset = if (fieldValue(object, &.{ "offset", "buffer_offset", "bufferOffset" })) |value|
        try expectU64(value)
    else
        0;
    const byte_length = try expectU64(try requiredField(object, &.{ "byteLength", "byte_length", "bufferSize", "buffer_size" }));
    const buffer_size = if (fieldValue(object, &.{ "bufferSize", "buffer_size" })) |value|
        try expectU64(value)
    else
        byte_length;
    const cache_namespace = try allocator.dupe(u8, try expectString(try requiredField(object, &.{ "cacheNamespace", "cache_namespace" })));
    const cache_key = try allocator.dupe(u8, try expectString(try requiredField(object, &.{ "cacheKey", "cache_key" })));
    const asset_key = if (try optionalString(object, &.{ "assetKey", "asset_key" })) |value|
        try allocator.dupe(u8, value)
    else
        null;
    const generator = try allocator.dupe(u8, try expectString(try requiredField(object, &.{"generator"})));
    const seed = try expectU64(try requiredField(object, &.{"seed"}));
    const scale = try expectF64(try requiredField(object, &.{"scale"}));
    return .{
        .handle = handle,
        .offset = offset,
        .buffer_size = buffer_size,
        .cache_namespace = cache_namespace,
        .cache_key = cache_key,
        .asset_key = asset_key,
        .generator = generator,
        .seed = seed,
        .scale = scale,
        .byte_length = byte_length,
    };
}

fn parseKernelBinding(value: Json.Value) PlanLoadError!KernelBinding {
    const object = try expectObject(value);
    const kind = try expectString(try requiredField(object, &.{"kind"}));
    if (!std.ascii.eqlIgnoreCase(kind, "buffer")) {
        return error.UnsupportedCommand;
    }

    const binding = try expectU32(try requiredField(object, &.{"binding"}));
    const group = if (fieldValue(object, &.{ "group", "group_index", "groupIndex" })) |group_value|
        try expectU32(group_value)
    else
        0;
    const resource_handle = try expectU64(try requiredField(object, &.{ "resource_handle", "resourceHandle", "handle" }));
    const buffer_size = try expectU64(try requiredField(object, &.{ "buffer_size", "bufferSize" }));
    const buffer_type_text = try expectString(try requiredField(object, &.{ "buffer_type", "bufferType" }));
    const buffer_type = try parseBufferBindingType(buffer_type_text);

    return .{
        .group = group,
        .binding = binding,
        .resource_handle = resource_handle,
        .buffer_size = buffer_size,
        .buffer_type = buffer_type,
    };
}

fn parseKernelDispatch(allocator: Allocator, object: Json.ObjectMap) PlanLoadError!KernelDispatchCommand {
    const kernel = try allocator.dupe(u8, try expectString(try requiredField(object, &.{ "kernel", "kernel_name", "kernelName" })));
    const entry_point = if (fieldValue(object, &.{ "entry_point", "entryPoint" })) |value|
        try allocator.dupe(u8, try expectString(value))
    else
        try allocator.dupe(u8, "main");

    const x = if (fieldValue(object, &.{"x"})) |value|
        try expectU32(value)
    else if (fieldValue(object, &.{ "workgroupCount", "workgroups" })) |value| blk: {
        const array = try expectArray(value);
        if (array.items.len != 3) return error.InvalidPlan;
        break :blk try expectU32(array.items[0]);
    } else 0;
    const y = if (fieldValue(object, &.{"y"})) |value|
        try expectU32(value)
    else if (fieldValue(object, &.{ "workgroupCount", "workgroups" })) |value| blk: {
        const array = try expectArray(value);
        if (array.items.len != 3) return error.InvalidPlan;
        break :blk try expectU32(array.items[1]);
    } else 0;
    const z = if (fieldValue(object, &.{"z"})) |value|
        try expectU32(value)
    else if (fieldValue(object, &.{ "workgroupCount", "workgroups" })) |value| blk: {
        const array = try expectArray(value);
        if (array.items.len != 3) return error.InvalidPlan;
        break :blk try expectU32(array.items[2]);
    } else 0;

    const initialize_buffers_on_create = if (fieldValue(object, &.{ "initialize_buffers_on_create", "initializeBuffersOnCreate" })) |value|
        try expectBool(value)
    else
        false;

    const bindings_value = try requiredField(object, &.{"bindings"});
    const bindings_array = try expectArray(bindings_value);
    const bindings = try allocator.alloc(KernelBinding, bindings_array.items.len);
    for (bindings_array.items, 0..) |binding_value, idx| {
        bindings[idx] = try parseKernelBinding(binding_value);
    }

    return .{
        .kernel = kernel,
        .entry_point = entry_point,
        .x = x,
        .y = y,
        .z = z,
        .initialize_buffers_on_create = initialize_buffers_on_create,
        .bindings = bindings,
    };
}

fn parseCommand(allocator: Allocator, value: Json.Value) PlanLoadError!Command {
    const object = try expectObject(value);
    const kind = try expectString(try requiredField(object, &.{"kind"}));
    if (std.ascii.eqlIgnoreCase(kind, "buffer_write") or
        std.ascii.eqlIgnoreCase(kind, "write_buffer") or
        std.ascii.eqlIgnoreCase(kind, "queue_write_buffer"))
    {
        return .{ .buffer_write = try parseBufferWrite(allocator, object) };
    }
    if (std.ascii.eqlIgnoreCase(kind, "buffer_load")) {
        return .{ .buffer_load = try parseBufferLoad(allocator, object) };
    }
    if (std.ascii.eqlIgnoreCase(kind, "kernel_dispatch")) {
        return .{ .kernel_dispatch = try parseKernelDispatch(allocator, object) };
    }
    return error.UnsupportedCommand;
}

fn parsePlanObject(allocator: Allocator, object: Json.ObjectMap, plan_sha256: []const u8) PlanLoadError!Plan {
    const commands_value = try requiredField(object, &.{"commands"});
    const commands_array = try expectArray(commands_value);
    const commands = try allocator.alloc(Command, commands_array.items.len);
    for (commands_array.items, 0..) |command_value, idx| {
        commands[idx] = try parseCommand(allocator, command_value);
    }

    const schema_version = try expectU32(try requiredField(object, &.{"schemaVersion"}));
    const command_count = try expectU32(try requiredField(object, &.{"commandCount"}));
    const buffer_write_count = try expectU32(try requiredField(object, &.{"bufferWriteCount"}));
    const buffer_load_count = if (fieldValue(object, &.{"bufferLoadCount"})) |value|
        try expectU32(value)
    else
        0;
    const dispatch_count = try expectU32(try requiredField(object, &.{"dispatchCount"}));

    return .{
        .schema_version = schema_version,
        .plan_kind = try expectString(try requiredField(object, &.{"planKind"})),
        .workload_id = try expectString(try requiredField(object, &.{"workloadId"})),
        .ir_path = try expectString(try requiredField(object, &.{"irPath"})),
        .ir_scenario = try expectString(try requiredField(object, &.{"irScenario"})),
        .description = try optionalString(object, &.{"description"}),
        .plan_path = try optionalString(object, &.{"planPath"}),
        .commands_path = try optionalString(object, &.{"commandsPath"}),
        .command_count = command_count,
        .buffer_write_count = buffer_write_count,
        .buffer_load_count = buffer_load_count,
        .dispatch_count = dispatch_count,
        .source_ir_sha256 = try expectString(try requiredField(object, &.{"sourceIrSha256"})),
        .compatibility_commands_sha256 = try expectString(try requiredField(object, &.{"compatibilityCommandsSha256"})),
        .plan_sha256 = plan_sha256,
        .commands = commands,
    };
}

pub fn parsePlanBytes(allocator: Allocator, bytes: []const u8) !LoadedPlan {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const parsed = try Json.parseFromSlice(Json.Value, arena.allocator(), bytes, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const root = try expectObject(parsed.value);
    const plan_sha256_value = try expectString(try requiredField(root, &.{"planSha256"}));
    const plan = try parsePlanObject(arena.allocator(), root, plan_sha256_value);
    return .{
        .arena = arena,
        .plan = plan,
    };
}

pub fn readPlanBytes(allocator: Allocator, path: []const u8) ![]u8 {
    return try std.fs.cwd().readFileAlloc(allocator, path, 32 * 1024 * 1024);
}

pub fn loadPlanFromPath(allocator: Allocator, path: []const u8) !LoadedPlan {
    const bytes = try readPlanBytes(allocator, path);
    defer allocator.free(bytes);
    return try parsePlanBytes(allocator, bytes);
}

test "loadPlanFromPath parses a generated Gemma plan" {
    const allocator = std.testing.allocator;
    var loaded = try loadPlanFromPath(allocator, "bench/plans/generated/inference_gemma3_270m_prefill_32tok.plan.json");
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u32, 1), loaded.plan.schema_version);
    try std.testing.expectEqualStrings("inference_gemma3_270m_prefill_32tok", loaded.plan.workload_id);
    try std.testing.expectEqual(@as(u32, 10), loaded.plan.buffer_load_count);
    try std.testing.expectEqual(@as(usize, 35), loaded.plan.commands.len);
    try std.testing.expectEqualStrings("510bf6c94457473704e9829a97bf8b7114985f0884542aa1f5cc908ca640467a", loaded.plan.plan_sha256);
}
