const std = @import("std");
const model_transfer_types = @import("../../contracts/model/model_compute_types.zig");
const hash_utils = @import("../common/hash_utils.zig");
const doe_wgsl = @import("../../compiler/wgsl/mod.zig");
const host = @import("../../compiler/wgsl/emit/csl/emit_csl_host.zig");
const host_plan = @import("../../compiler/wgsl/emit/csl/emit_csl_host_plan.zig");
const csl_spec = @import("../../compiler/wgsl/emit/csl/csl_spec.zig");

const DEFAULT_KERNEL_ROOT: []const u8 = "bench/kernels";
const HOST_PLAN_ARTIFACT_DIR: []const u8 = "bench/out/csl-host-plans";
const ARTIFACT_JSON_FILENAME: []const u8 = "host-plan.json";
const MAX_WGSL_SOURCE_BYTES: usize = 2 * 1024 * 1024;

const model = struct {
    pub const KernelDispatchCommand = model_transfer_types.KernelDispatchCommand;
};

pub fn hostPlanPath(self: anytype) ?[]const u8 {
    if (self.host_plan_path_len == 0) return null;
    return self.host_plan_path_storage[0..self.host_plan_path_len];
}

pub fn hostPlanHash(self: anytype) ?[]const u8 {
    if (self.host_plan_hash_len == 0) return null;
    return self.host_plan_hash_storage[0..self.host_plan_hash_len];
}

pub fn clearHostPlanArtifact(self: anytype) void {
    self.host_plan_path_len = 0;
    self.host_plan_hash_len = 0;
}

pub fn emitForKernelDispatch(self: anytype, kd: model.KernelDispatchCommand) !void {
    const kernel_base = stripKnownExtension(kd.kernel);
    const kernel_root = self.kernel_root_owned orelse DEFAULT_KERNEL_ROOT;
    const wgsl_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.wgsl", .{ kernel_root, kernel_base });
    defer self.allocator.free(wgsl_path);

    const wgsl_source = try std.fs.cwd().readFileAlloc(self.allocator, wgsl_path, MAX_WGSL_SOURCE_BYTES);
    defer self.allocator.free(wgsl_source);

    self.host_plan_emit_count +|= 1;
    const artifact_dir = try std.fmt.allocPrint(
        self.allocator,
        "{s}/{s}_{d}",
        .{ HOST_PLAN_ARTIFACT_DIR, kernel_base, self.host_plan_emit_count },
    );
    defer self.allocator.free(artifact_dir);
    try std.fs.cwd().makePath(artifact_dir);

    var csl_output: [doe_wgsl.MAX_CSL_OUTPUT]u8 = undefined;
    var layout_stub: [512]u8 = undefined;
    var pe_program_stub: [512]u8 = undefined;
    var kernel_pattern: []const u8 = "kernel_dispatch_translated";
    var layout_body: []const u8 = undefined;
    var pe_program_body: []const u8 = undefined;
    var csl_len: usize = 0;
    csl_len = doe_wgsl.translateToCsl(self.allocator, wgsl_source, csl_output[0..]) catch |err| blk: {
        kernel_pattern = "kernel_dispatch_translation_unavailable";
        const layout_text = try std.fmt.bufPrint(
            &layout_stub,
            "// translationStatus: unavailable\n// sourceKernel: {s}\n// translateError: {s}\n",
            .{ kd.kernel, @errorName(err) },
        );
        const pe_program_text = try std.fmt.bufPrint(
            &pe_program_stub,
            "// translationStatus: unavailable\n// sourceKernel: {s}\n// translateError: {s}\n",
            .{ kd.kernel, @errorName(err) },
        );
        layout_body = layout_text;
        pe_program_body = pe_program_text;
        break :blk 0;
    };
    if (std.mem.eql(u8, kernel_pattern, "kernel_dispatch_translated")) {
        const csl = csl_output[0..csl_len];
        layout_body = extractSectionBody(csl, csl_spec.LAYOUT_FILENAME) orelse return error.InvalidIr;
        pe_program_body = extractSectionBody(csl, csl_spec.PE_PROGRAM_FILENAME) orelse return error.InvalidIr;
    }

    const layout_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ artifact_dir, csl_spec.LAYOUT_FILENAME });
    defer self.allocator.free(layout_path);
    try std.fs.cwd().writeFile(.{ .sub_path = layout_path, .data = layout_body });

    const pe_program_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ artifact_dir, csl_spec.PE_PROGRAM_FILENAME });
    defer self.allocator.free(pe_program_path);
    try std.fs.cwd().writeFile(.{ .sub_path = pe_program_path, .data = pe_program_body });

    const repeat_count: u32 = if (kd.repeat == 0) 1 else kd.repeat;
    const kernels = [_]host.KernelSpec{
        .{ .name = kernel_base, .pattern = kernel_pattern, .count = 1 },
    };
    const prefill = [_]host.LaunchSpec{
        .{ .kernel_name = kernel_base, .repeat = repeat_count },
    };
    const decode = [_]host.LaunchSpec{};
    const plan = host.HostPlan{
        .pe_grid_width = 1,
        .pe_grid_height = 1,
        .kernels = &kernels,
        .prefill_launches = &prefill,
        .decode_launches = &decode,
        .eos_token_id = null,
    };
    const targets = [_]host_plan.CompileTarget{
        .{
            .kernel_name = kernel_base,
            .pattern = kernel_pattern,
            .layout_path = layout_path,
            .pe_program_path = pe_program_path,
        },
    };
    const cslc_plan = try host_plan.makeCslcPlan(null);

    var artifact_json: [doe_wgsl.MAX_OUTPUT]u8 = undefined;
    var artifact_pos: usize = 0;
    try host_plan.emitHostPlanArtifactJson(artifact_json[0..], &artifact_pos, plan, &targets, cslc_plan);
    const artifact_bytes = artifact_json[0..artifact_pos];

    const artifact_json_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ artifact_dir, ARTIFACT_JSON_FILENAME });
    defer self.allocator.free(artifact_json_path);
    try std.fs.cwd().writeFile(.{ .sub_path = artifact_json_path, .data = artifact_bytes });

    const artifact_json_realpath = try std.fs.cwd().realpathAlloc(self.allocator, artifact_json_path);
    defer self.allocator.free(artifact_json_realpath);
    persistValue(self.host_plan_path_storage[0..], &self.host_plan_path_len, artifact_json_realpath);

    const artifact_hash = hash_utils.sha256_hex(artifact_bytes);
    persistValue(self.host_plan_hash_storage[0..], &self.host_plan_hash_len, artifact_hash[0..]);
}

fn persistValue(storage: []u8, len_out: *usize, value: []const u8) void {
    const copy_len = @min(storage.len, value.len);
    std.mem.copyForwards(u8, storage[0..copy_len], value[0..copy_len]);
    len_out.* = copy_len;
}

fn stripKnownExtension(kernel: []const u8) []const u8 {
    const suffixes = [_][]const u8{ ".wgsl", ".metal", ".spv" };
    inline for (suffixes) |suffix| {
        if (std.mem.endsWith(u8, kernel, suffix)) {
            return kernel[0 .. kernel.len - suffix.len];
        }
    }
    return kernel;
}

fn extractSectionBody(csl: []const u8, filename: []const u8) ?[]const u8 {
    var marker_buf: [128]u8 = undefined;
    const marker = std.fmt.bufPrint(
        &marker_buf,
        "{s}{s}{s}",
        .{ csl_spec.SECTION_SEPARATOR, filename, csl_spec.SECTION_SEPARATOR_END },
    ) catch return null;

    const header_index = std.mem.indexOf(u8, csl, marker) orelse return null;
    const body_start = header_index + marker.len;
    const next_header = std.mem.indexOfPos(u8, csl, body_start, csl_spec.SECTION_SEPARATOR) orelse csl.len;
    return csl[body_start..next_header];
}
