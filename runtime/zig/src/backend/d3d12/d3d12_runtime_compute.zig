const std = @import("std");
const builtin = @import("builtin");
const common_timing = @import("../common/timing.zig");
const path_utils = @import("../common/path_utils.zig");
const webgpu = @import("../runtime_types.zig");
const doe_wgsl = @import("../../compiler/wgsl/mod.zig");
const hlsl_dispatch_contract = @import("../../compiler/wgsl/emit/hlsl/hlsl_dispatch_contract.zig");
const d3d12_descriptors = @import("d3d12_descriptors.zig");
const dc = @import("d3d12_constants.zig");
const bridge = @import("d3d12_bridge_decls.zig");

pub const MAX_KERNEL_SOURCE_BYTES: usize = 2 * 1024 * 1024;
pub const DEFAULT_KERNEL_ROOT: []const u8 = "bench/kernels";
pub const GENERATED_SHADER_DIR: []const u8 = "bench/out/shader-artifacts/generated";
pub const MAX_DXC_OUTPUT_BYTES: usize = 64 * 1024;
pub const DXC_PROFILE: []const u8 = "cs_6_0";
pub const DXC_ENTRYPOINT: []const u8 = "main";

const D3D12_DESCRIPTOR_RANGE_TYPE_CBV = dc.DESCRIPTOR_RANGE_TYPE_CBV;

const DispatchInfoWords = extern struct {
    x: u32,
    y: u32,
    z: u32,
    _pad: u32,
};

pub const DispatchMetrics = struct {
    encode_ns: u64 = 0,
    submit_wait_ns: u64 = 0,
    dispatch_count: u32 = 0,
};

pub fn loadKernelCso(self: anytype, alloc: std.mem.Allocator, kernel_name: []const u8) ![]u8 {
    if (kernel_name.len == 0) return error.InvalidArgument;
    const root = self.kernel_root orelse DEFAULT_KERNEL_ROOT;

    const dxil_path = try std.fmt.allocPrint(alloc, "{s}/{s}.dxil", .{ root, stripExtension(kernel_name) });
    defer alloc.free(dxil_path);
    if (path_utils.file_exists(dxil_path)) {
        return std.fs.cwd().readFileAlloc(alloc, dxil_path, MAX_KERNEL_SOURCE_BYTES) catch return error.ShaderCompileFailed;
    }

    const cso_path = try std.fmt.allocPrint(alloc, "{s}/{s}.cso", .{ root, stripExtension(kernel_name) });
    defer alloc.free(cso_path);
    if (path_utils.file_exists(cso_path)) {
        return std.fs.cwd().readFileAlloc(alloc, cso_path, MAX_KERNEL_SOURCE_BYTES) catch return error.ShaderCompileFailed;
    }

    const dxbc_path = try std.fmt.allocPrint(alloc, "{s}/{s}.dxbc", .{ root, stripExtension(kernel_name) });
    defer alloc.free(dxbc_path);
    if (path_utils.file_exists(dxbc_path)) {
        return std.fs.cwd().readFileAlloc(alloc, dxbc_path, MAX_KERNEL_SOURCE_BYTES) catch return error.ShaderCompileFailed;
    }

    const source_path = resolveKernelSourcePath(self, alloc, kernel_name) catch return error.ShaderCompileFailed;
    defer alloc.free(source_path);

    const source = std.fs.cwd().readFileAlloc(alloc, source_path, MAX_KERNEL_SOURCE_BYTES) catch return error.ShaderCompileFailed;
    defer alloc.free(source);

    if (std.mem.endsWith(u8, source_path, ".dxil") or
        std.mem.endsWith(u8, source_path, ".cso") or
        std.mem.endsWith(u8, source_path, ".dxbc"))
    {
        return try alloc.dupe(u8, source);
    }

    if (std.mem.endsWith(u8, source_path, ".wgsl")) {
        return try compileWgslSource(self, alloc, source);
    }

    if (std.mem.endsWith(u8, source_path, ".hlsl")) {
        return try compileHlslSource(self, alloc, source);
    }

    return error.ShaderCompileFailed;
}

pub fn setComputeShader(self: anytype, bytecode: []const u8) !void {
    if (bytecode.len == 0) return error.ShaderCompileFailed;
    const hash = std.hash.Wyhash.hash(0, bytecode);
    if (self.has_compute_pipeline and hash == self.current_shader_hash) return;
    try buildComputePipeline(self, bytecode, hash);
}

pub fn runDispatch(self: anytype, x: u32, y: u32, z: u32, repeat: u32, queue_sync_mode: webgpu.QueueSyncMode) !DispatchMetrics {
    if (x == 0 or y == 0 or z == 0) return error.InvalidArgument;
    if (!self.has_compute_pipeline) return error.Unsupported;

    const run_count: u32 = if (repeat == 0) 1 else repeat;
    var compute_allocator = self.compute_allocator;
    var compute_cmd_list = self.compute_cmd_list;
    var retained_handles: std.ArrayListUnmanaged(?*anyopaque) = .{};
    var owns_retained_handles = true;
    defer if (owns_retained_handles) {
        for (retained_handles.items) |maybe_handle| {
            if (maybe_handle) |handle| bridge.c.d3d12_bridge_release(handle);
        }
        retained_handles.deinit(self.allocator);
    };
    if (queue_sync_mode != .per_command) {
        compute_allocator = bridge.c.d3d12_bridge_device_create_command_allocator(self.device) orelse return error.InvalidState;
        errdefer bridge.c.d3d12_bridge_release(compute_allocator);
        compute_cmd_list = bridge.c.d3d12_bridge_device_create_command_list(self.device, compute_allocator) orelse return error.InvalidState;
        errdefer bridge.c.d3d12_bridge_release(compute_cmd_list);
        bridge.c.d3d12_bridge_command_list_close(compute_cmd_list);
    }
    const encode_start = common_timing.now_ns();

    if (bridge.c.d3d12_bridge_command_allocator_reset(compute_allocator) != 0) return error.InvalidState;
    if (bridge.c.d3d12_bridge_command_list_reset(compute_cmd_list, compute_allocator) != 0) return error.InvalidState;

    bridge.c.d3d12_bridge_command_list_set_compute_root_signature(compute_cmd_list, self.root_signature);
    bridge.c.d3d12_bridge_command_list_set_pipeline_state(compute_cmd_list, self.compute_pipeline);
    try bindDispatchInfo(self, compute_cmd_list, x, y, z, queue_sync_mode, &retained_handles);

    var i: u32 = 0;
    while (i < run_count) : (i += 1) {
        bridge.c.d3d12_bridge_command_list_dispatch(compute_cmd_list, x, y, z);
    }
    bridge.c.d3d12_bridge_command_list_close(compute_cmd_list);
    const encode_ns = common_timing.ns_delta(common_timing.now_ns(), encode_start);

    bridge.c.d3d12_bridge_queue_execute_command_list(self.queue, compute_cmd_list);
    self.fence_value +|= 1;
    bridge.c.d3d12_bridge_queue_signal(self.queue, self.fence, self.fence_value);
    if (queue_sync_mode == .per_command) {
        const submit_start = common_timing.now_ns();
        bridge.c.d3d12_bridge_fence_wait(self.fence, self.fence_value);
        const submit_wait_ns = common_timing.ns_delta(common_timing.now_ns(), submit_start);
        self.noteCompletedFenceWait();
        return .{ .encode_ns = encode_ns, .submit_wait_ns = submit_wait_ns, .dispatch_count = run_count };
    }

    try self.trackDropinSubmission(compute_allocator, compute_cmd_list, &retained_handles);
    owns_retained_handles = false;

    return .{ .encode_ns = encode_ns, .submit_wait_ns = 0, .dispatch_count = run_count };
}

pub fn destroyComputeObjects(self: anytype) void {
    if (self.has_compute_cmd) {
        bridge.c.d3d12_bridge_release(self.compute_cmd_list);
        bridge.c.d3d12_bridge_release(self.compute_allocator);
        self.compute_cmd_list = null;
        self.compute_allocator = null;
        self.has_compute_cmd = false;
    }
    if (self.has_compute_pipeline) {
        bridge.c.d3d12_bridge_release(self.compute_pipeline);
        self.compute_pipeline = null;
        self.has_compute_pipeline = false;
    }
    if (self.has_root_signature) {
        bridge.c.d3d12_bridge_release(self.root_signature);
        self.root_signature = null;
        self.has_root_signature = false;
    }
}

fn resolveKernelSourcePath(self: anytype, alloc: std.mem.Allocator, kernel_name: []const u8) ![]u8 {
    const direct = try alloc.dupe(u8, kernel_name);
    if (path_utils.file_exists(direct)) return direct;
    alloc.free(direct);

    const root = self.kernel_root orelse DEFAULT_KERNEL_ROOT;
    const rooted = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ root, kernel_name });
    if (path_utils.file_exists(rooted)) return rooted;
    alloc.free(rooted);

    if (!std.mem.endsWith(u8, kernel_name, ".wgsl")) {
        const wgsl_path = try std.fmt.allocPrint(alloc, "{s}/{s}.wgsl", .{ root, kernel_name });
        if (path_utils.file_exists(wgsl_path)) return wgsl_path;
        alloc.free(wgsl_path);
    }

    if (!std.mem.endsWith(u8, kernel_name, ".hlsl")) {
        const hlsl_path = try std.fmt.allocPrint(alloc, "{s}/{s}.hlsl", .{ root, kernel_name });
        if (path_utils.file_exists(hlsl_path)) return hlsl_path;
        alloc.free(hlsl_path);
    }

    return error.ShaderCompileFailed;
}

fn compileHlslSource(self: anytype, alloc: std.mem.Allocator, hlsl_source: []const u8) ![]u8 {
    _ = self;
    return try compileHlslToBytecode(alloc, hlsl_source);
}

fn compileWgslSource(self: anytype, alloc: std.mem.Allocator, wgsl_source: []const u8) ![]u8 {
    var hlsl_buf = try alloc.alloc(u8, doe_wgsl.MAX_HLSL_OUTPUT);
    defer alloc.free(hlsl_buf);
    const hlsl_len = doe_wgsl.translateToHlsl(alloc, wgsl_source, hlsl_buf) catch return error.ShaderCompileFailed;
    return try compileHlslSource(self, alloc, hlsl_buf[0..hlsl_len]);
}

fn buildComputePipeline(self: anytype, bytecode: []const u8, shader_hash: u64) !void {
    if (!self.has_root_signature) {
        const range = d3d12_descriptors.DescriptorRangeDesc{
            .range_type = D3D12_DESCRIPTOR_RANGE_TYPE_CBV,
            .num_descriptors = 1,
            .base_shader_register = hlsl_dispatch_contract.DISPATCH_INFO_REGISTER_SLOT,
            .register_space = hlsl_dispatch_contract.DISPATCH_INFO_REGISTER_SPACE,
        };
        self.root_signature = bridge.c.d3d12_bridge_device_create_root_signature_with_tables(self.device, @ptrCast(&range), 1, 0) orelse return error.InvalidState;
        self.has_root_signature = true;
    }

    if (self.has_compute_pipeline) {
        bridge.c.d3d12_bridge_release(self.compute_pipeline);
        self.compute_pipeline = null;
        self.has_compute_pipeline = false;
    }

    self.compute_pipeline = bridge.c.d3d12_bridge_device_create_compute_pipeline(
        self.device,
        self.root_signature,
        bytecode.ptr,
        bytecode.len,
    ) orelse return error.ShaderCompileFailed;
    self.has_compute_pipeline = true;
    self.current_shader_hash = shader_hash;

    if (!self.has_compute_cmd) {
        self.compute_allocator = bridge.c.d3d12_bridge_device_create_command_allocator(self.device) orelse return error.InvalidState;
        self.compute_cmd_list = bridge.c.d3d12_bridge_device_create_command_list(self.device, self.compute_allocator) orelse return error.InvalidState;
        bridge.c.d3d12_bridge_command_list_close(self.compute_cmd_list);
        self.has_compute_cmd = true;
    }
}

const TransientDispatchInfoBinding = struct {
    buffer: ?*anyopaque,
    heap: ?*anyopaque,
    descriptor_index: u32,
};

fn bindDispatchInfo(
    self: anytype,
    cmd_list: ?*anyopaque,
    x: u32,
    y: u32,
    z: u32,
    queue_sync_mode: webgpu.QueueSyncMode,
    retained_handles: *std.ArrayListUnmanaged(?*anyopaque),
) !void {
    const binding = if (queue_sync_mode == .per_command)
        try ensureSharedDispatchInfoBinding(self, x, y, z)
    else
        try createTransientDispatchInfoBinding(self, x, y, z, retained_handles);

    bridge.c.d3d12_bridge_command_list_set_descriptor_heaps(
        cmd_list,
        binding.heap,
        self.descriptor_state.sampler_heap,
    );
    bridge.c.d3d12_bridge_command_list_set_compute_root_descriptor_table(
        cmd_list,
        hlsl_dispatch_contract.DISPATCH_INFO_ROOT_PARAMETER_INDEX,
        binding.heap,
        binding.descriptor_index,
    );
}

fn ensureSharedDispatchInfoBinding(self: anytype, x: u32, y: u32, z: u32) !TransientDispatchInfoBinding {
    if (self.dispatch_info_buffer == null) {
        self.dispatch_info_buffer = bridge.c.d3d12_bridge_device_create_buffer(
            self.device,
            @intCast(hlsl_dispatch_contract.DISPATCH_INFO_BUFFER_BYTES),
            dc.HEAP_TYPE_UPLOAD,
        ) orelse return error.InvalidState;
    }
    if (!self.has_dispatch_info_cbv) {
        self.dispatch_info_cbv_index = try self.descriptor_state.allocate_cbv(
            self.device,
            self.dispatch_info_buffer,
            hlsl_dispatch_contract.DISPATCH_INFO_BUFFER_BYTES,
        );
        self.has_dispatch_info_cbv = true;
    }
    try writeDispatchInfoWords(self.dispatch_info_buffer, x, y, z);
    return .{
        .buffer = self.dispatch_info_buffer,
        .heap = self.descriptor_state.cbv_srv_uav_heap,
        .descriptor_index = self.dispatch_info_cbv_index,
    };
}

fn createTransientDispatchInfoBinding(
    self: anytype,
    x: u32,
    y: u32,
    z: u32,
    retained_handles: *std.ArrayListUnmanaged(?*anyopaque),
) !TransientDispatchInfoBinding {
    const buffer = bridge.c.d3d12_bridge_device_create_buffer(
        self.device,
        @intCast(hlsl_dispatch_contract.DISPATCH_INFO_BUFFER_BYTES),
        dc.HEAP_TYPE_UPLOAD,
    ) orelse return error.InvalidState;
    errdefer bridge.c.d3d12_bridge_release(buffer);

    const heap = bridge.c.d3d12_bridge_device_create_cbv_srv_uav_heap(self.device, 1) orelse return error.InvalidState;
    errdefer bridge.c.d3d12_bridge_release(heap);

    try writeDispatchInfoWords(buffer, x, y, z);
    bridge.c.d3d12_bridge_device_create_cbv(
        self.device,
        heap,
        0,
        buffer,
        0,
        @intCast(hlsl_dispatch_contract.DISPATCH_INFO_BUFFER_BYTES),
    );
    try retained_handles.append(self.allocator, buffer);
    try retained_handles.append(self.allocator, heap);
    return .{
        .buffer = buffer,
        .heap = heap,
        .descriptor_index = 0,
    };
}

fn writeDispatchInfoWords(buffer: ?*anyopaque, x: u32, y: u32, z: u32) !void {
    const mapped = bridge.c.d3d12_bridge_resource_map(buffer) orelse return error.InvalidState;
    const words: *DispatchInfoWords = @ptrCast(@alignCast(mapped));
    words.* = .{ .x = x, .y = y, .z = z, ._pad = 0 };
    bridge.c.d3d12_bridge_resource_unmap(buffer);
}

pub fn stripExtension(name: []const u8) []const u8 {
    const suffixes = [_][]const u8{ ".wgsl", ".hlsl", ".dxil", ".cso", ".dxbc" };
    for (suffixes) |sfx| {
        if (std.mem.endsWith(u8, name, sfx)) return name[0 .. name.len - sfx.len];
    }
    return name;
}

fn compileHlslToBytecode(alloc: std.mem.Allocator, hlsl_source: []const u8) ![]u8 {
    std.fs.cwd().makePath(GENERATED_SHADER_DIR) catch return error.ShaderCompileFailed;

    const source_hash = std.hash.Wyhash.hash(0, hlsl_source);
    const stem = try std.fmt.allocPrint(alloc, "{s}/d3d12_{x}", .{ GENERATED_SHADER_DIR, source_hash });
    defer alloc.free(stem);
    const hlsl_path = try std.fmt.allocPrint(alloc, "{s}.generated.hlsl", .{stem});
    defer alloc.free(hlsl_path);
    const cso_path = try std.fmt.allocPrint(alloc, "{s}.generated.cso", .{stem});
    defer alloc.free(cso_path);

    if (!path_utils.file_exists(cso_path)) {
        const file = std.fs.cwd().createFile(hlsl_path, .{ .truncate = true }) catch return error.ShaderCompileFailed;
        defer file.close();
        file.writeAll(hlsl_source) catch return error.ShaderCompileFailed;
        try runDxc(alloc, hlsl_path, cso_path, DXC_ENTRYPOINT);
    }

    return std.fs.cwd().readFileAlloc(alloc, cso_path, MAX_KERNEL_SOURCE_BYTES) catch return error.ShaderCompileFailed;
}

fn runDxc(alloc: std.mem.Allocator, input_path: []const u8, output_path: []const u8, entrypoint: []const u8) !void {
    const exe = if (builtin.os.tag == .windows) "dxc.exe" else "dxc";
    const argv = [_][]const u8{
        exe,
        "-T",
        DXC_PROFILE,
        "-E",
        entrypoint,
        "-Fo",
        output_path,
        input_path,
    };
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &argv,
        .max_output_bytes = MAX_DXC_OUTPUT_BYTES,
    }) catch |err| return switch (err) {
        error.FileNotFound => error.ShaderToolchainUnavailable,
        else => error.ShaderCompileFailed,
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) return error.ShaderCompileFailed,
        else => return error.ShaderCompileFailed,
    }
}
