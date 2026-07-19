const std = @import("std");
const command_stream = @import("../command/command_stream.zig");
const model_commands = @import("../contracts/model/model_commands.zig");
const model_quirks = @import("../contracts/model/model_quirks.zig");
const quirk = @import("../quirk/mod.zig");
const replay = @import("../runtime/trace/replay.zig");
const tooling_io_context = @import("../tooling/tooling_io_context.zig");
const runtime_cli_args = @import("runtime_cli_args.zig");
const samples = @import("runtime_cli_samples.zig");

const MAX_INPUT_BYTES: usize = 16 * 1024 * 1024;
var next_test_file_id = std.atomic.Value(u64).init(0);

pub const LoadTimings = struct {
    host_input_read_total_ns: u64 = 0,
    host_input_parse_total_ns: u64 = 0,
};

pub const LoadedInputs = struct {
    quirks: []model_quirks.Quirk,
    replay_expectations: ?replay.ReplayExpectationSet = null,
    commands: []const model_commands.Command,
    command_metadata: []command_stream.CommandMetadata,
    owned_stream: ?command_stream.ParsedCommandStream = null,
    owned_quirks_bytes: ?[]const u8 = null,

    pub fn deinit(self: *LoadedInputs, allocator: std.mem.Allocator) void {
        defer quirk.parser.freeQuirks(allocator, self.quirks);
        if (self.owned_quirks_bytes) |bytes| {
            allocator.free(bytes);
        }
        if (self.replay_expectations) |*expectations| {
            expectations.deinit(allocator);
        }
        if (self.owned_stream) |parsed_stream| {
            parsed_stream.deinit(allocator);
        } else {
            allocator.free(self.command_metadata);
        }
    }
};

pub const LoadResult = struct {
    inputs: LoadedInputs,
    timings: LoadTimings,
};

fn nowNs() u64 {
    return @as(u64, @intCast(std.time.nanoTimestamp()));
}

fn elapsedSince(start_ns: u64) u64 {
    return nowNs() - start_ns;
}

fn allocTestPath(allocator: std.mem.Allocator, stem: []const u8) ![]u8 {
    const unique_id = next_test_file_id.fetchAdd(1, .monotonic);
    return std.fmt.allocPrint(
        allocator,
        ".tmp-{s}-{d}-{d}.json",
        .{ stem, unique_id, std.time.nanoTimestamp() },
    );
}

pub fn load(
    allocator: std.mem.Allocator,
    options: runtime_cli_args.RunOptions,
) !LoadResult {
    return loadWithIo(allocator, tooling_io_context.IoContext.sync(), options);
}

pub fn loadWithIo(
    allocator: std.mem.Allocator,
    io_context: tooling_io_context.IoContext,
    options: runtime_cli_args.RunOptions,
) !LoadResult {
    var timings = LoadTimings{};

    const quirks_read_start_ns = nowNs();
    const quirks_bytes = if (options.quirk_mode.loadsQuirks())
        (if (options.quirks_path) |path| try io_context.readFileAlloc(allocator, path, MAX_INPUT_BYTES) else samples.sample_quirks)
    else
        "[]";
    timings.host_input_read_total_ns += elapsedSince(quirks_read_start_ns);
    const owns_quirks_bytes = options.quirks_path != null and options.quirk_mode.loadsQuirks();

    const quirks_parse_start_ns = nowNs();
    const quirks = try quirk.parser.parseQuirks(allocator, quirks_bytes);
    timings.host_input_parse_total_ns += elapsedSince(quirks_parse_start_ns);

    var replay_expectations: ?replay.ReplayExpectationSet = null;
    errdefer if (replay_expectations) |*expectations| expectations.deinit(allocator);

    if (options.replay_path) |path| {
        const replay_parse_start_ns = nowNs();
        replay_expectations = try replay.loadReplayExpectationsWithIo(allocator, io_context, path);
        timings.host_input_parse_total_ns += elapsedSince(replay_parse_start_ns);
    }

    const default_metadata_start_ns = nowNs();
    var command_metadata = try command_stream.metadata_for_slice(allocator, samples.default_commands[0..]);
    errdefer allocator.free(command_metadata);
    timings.host_input_parse_total_ns += elapsedSince(default_metadata_start_ns);

    var commands: []const model_commands.Command = samples.default_commands[0..];
    var owned_stream: ?command_stream.ParsedCommandStream = null;

    if (options.commands_path) |commands_path| {
        const commands_read_start_ns = nowNs();
        const commands_bytes = try io_context.readFileAlloc(allocator, commands_path, MAX_INPUT_BYTES);
        defer allocator.free(commands_bytes);
        timings.host_input_read_total_ns += elapsedSince(commands_read_start_ns);

        const commands_parse_start_ns = nowNs();
        const parsed_stream = try command_stream.parse_command_stream(allocator, commands_bytes);
        timings.host_input_parse_total_ns += elapsedSince(commands_parse_start_ns);

        allocator.free(command_metadata);
        commands = parsed_stream.commands;
        command_metadata = parsed_stream.metadata;
        owned_stream = parsed_stream;
    }

    var loaded = LoadedInputs{
        .quirks = quirks,
        .replay_expectations = replay_expectations,
        .commands = commands,
        .command_metadata = command_metadata,
        .owned_stream = owned_stream,
        .owned_quirks_bytes = if (owns_quirks_bytes) quirks_bytes else null,
    };
    errdefer loaded.deinit(allocator);

    return .{
        .inputs = loaded,
        .timings = timings,
    };
}

test "loadWithIo supports cooperative same-thread mode for command streams" {
    const path = try allocTestPath(std.testing.allocator, "runtime-cli-inputs");
    defer std.testing.allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    try std.fs.cwd().writeFile(.{
        .sub_path = path,
        .data = "[{\"command\":\"barrier\",\"dependency_count\":2}]",
    });

    var result = try loadWithIo(
        std.testing.allocator,
        tooling_io_context.IoContext.cooperativeSameThread(),
        .{
            .commands_path = path,
            .quirk_mode = .off,
        },
    );
    defer result.inputs.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.inputs.commands.len);
    try std.testing.expectEqual(@as(u32, 2), result.inputs.commands[0].barrier.dependency_count);
}
