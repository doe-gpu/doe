const builtin = @import("builtin");
const std = @import("std");
const build_options = @import("build_options");
const pipeline_cache = @import("../../runtime/cache/pipeline_cache.zig");
const wgsl_runtime_compile = @import("../../compiler/wgsl/runtime/runtime_compute_translation.zig");
const ir = @import("../../compiler/wgsl/ir/ir.zig");

const PipelineCache = pipeline_cache.PipelineCache;
const PipelineCacheKey = pipeline_cache.PipelineCacheKey;
const TranslationInfo = wgsl_runtime_compile.TranslationInfo;
const Sha256 = std.crypto.hash.sha2.Sha256;

const CACHE_MAGIC: u32 = 0xD0E5_CACE;
const CACHE_VERSION: u32 = 6;
const FLAG_NEEDS_SIZES_BUF: u32 = 1 << 0;
const FLAG_BOUNDS_ELISION: u32 = 1 << 1;
const FLAG_TEXTURE_BOUNDS_ELISION: u32 = 1 << 2;
const FLAG_DISPATCH_VALIDATED_BOUNDS_ELISION: u32 = 1 << 3;
const FLAG_UNIFORM_VALIDATED_BOUNDS_ELISION: u32 = 1 << 4;
const FLAG_DISPATCH_VALIDATED_GLOBAL_BOUNDS_ELISION: u32 = 1 << 5;
const DEFAULT_CACHE_DIR_SUFFIX = "doe/shader_translation_cache";
const TRANSLATION_CONTRACT_DOMAIN = "doe.shader_translation_cache.contract.v1";
const TRANSLATION_KEY_DOMAIN = "doe.shader_translation_cache.key.v1";

const PayloadKind = enum(u32) {
    msl = 1,
    spirv = 2,
};

const Header = extern struct {
    magic: u32,
    version: u32,
    flags: u32,
    payload_kind: u32,
    workgroup_x: u32,
    workgroup_y: u32,
    workgroup_z: u32,
    dispatch_count: u32,
    texture_dispatch_count: u32,
    dispatch_stride: u32,
    texture_dispatch_stride: u32,
    payload_len: u32,
    contract_digest: [32]u8,
};

pub const CachedTranslation = struct {
    msl: []u8,
    info: TranslationInfo,

    pub fn deinit(self: *CachedTranslation, allocator: std.mem.Allocator) void {
        allocator.free(self.msl);
        self.info.deinit(allocator);
        self.* = undefined;
    }
};

pub const CachedSpirvTranslation = struct {
    spirv: []u8,
    info: TranslationInfo,

    pub fn deinit(self: *CachedSpirvTranslation, allocator: std.mem.Allocator) void {
        allocator.free(self.spirv);
        self.info.deinit(allocator);
        self.* = undefined;
    }
};

const CachedPayload = struct {
    payload: []u8,
    info: TranslationInfo,

    pub fn deinit(self: *CachedPayload, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        self.info.deinit(allocator);
        self.* = undefined;
    }
};

var global_cache: ?*PipelineCache = null;
var init_attempted: bool = false;
var cache_mutex: std.Thread.Mutex = .{};

pub fn lookupComputeTranslation(
    allocator: std.mem.Allocator,
    wgsl_source: []const u8,
) ?CachedTranslation {
    const cached = lookupComputePayload(allocator, wgsl_source, .msl) orelse return null;
    return .{
        .msl = cached.payload,
        .info = cached.info,
    };
}

pub fn storeComputeTranslation(
    allocator: std.mem.Allocator,
    wgsl_source: []const u8,
    msl_source: []const u8,
    info: *const TranslationInfo,
) void {
    storeComputePayload(allocator, wgsl_source, msl_source, info, .msl);
}

pub fn lookupComputeSpirvTranslation(
    allocator: std.mem.Allocator,
    wgsl_source: []const u8,
) ?CachedSpirvTranslation {
    const cached = lookupComputePayload(allocator, wgsl_source, .spirv) orelse return null;
    return .{
        .spirv = cached.payload,
        .info = cached.info,
    };
}

pub fn storeComputeSpirvTranslation(
    allocator: std.mem.Allocator,
    wgsl_source: []const u8,
    spirv_bytes: []const u8,
    info: *const TranslationInfo,
) void {
    storeComputePayload(allocator, wgsl_source, spirv_bytes, info, .spirv);
}

fn lookupComputePayload(
    allocator: std.mem.Allocator,
    wgsl_source: []const u8,
    expected_kind: PayloadKind,
) ?CachedPayload {
    cache_mutex.lock();
    defer cache_mutex.unlock();
    const cache = ensureGlobalCache() orelse return null;
    const payload = cache.lookup(&buildComputeKey(wgsl_source, expected_kind)) orelse return null;
    return decodePayload(allocator, payload, expected_kind);
}

fn storeComputePayload(
    allocator: std.mem.Allocator,
    wgsl_source: []const u8,
    payload_source: []const u8,
    info: *const TranslationInfo,
    payload_kind: PayloadKind,
) void {
    const payload = encodePayload(allocator, payload_source, info, payload_kind) catch return;
    defer allocator.free(payload);
    cache_mutex.lock();
    defer cache_mutex.unlock();
    const cache = ensureGlobalCache() orelse return;
    cache.store(&buildComputeKey(wgsl_source, payload_kind), payload);
}

fn ensureGlobalCache() ?*PipelineCache {
    if (global_cache) |cache| return cache;
    if (init_attempted) return null;
    init_attempted = true;
    const cache_dir = resolveDefaultCacheDir(std.heap.c_allocator) catch return null;
    defer std.heap.c_allocator.free(cache_dir);
    global_cache = PipelineCache.init(std.heap.c_allocator, cache_dir) catch null;
    return global_cache;
}

fn resolveDefaultCacheDir(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .macos or builtin.os.tag == .linux) {
        if (std.posix.getenv("HOME")) |home| {
            return std.fmt.allocPrint(allocator, "{s}/.cache/{s}", .{ home, DEFAULT_CACHE_DIR_SUFFIX });
        }
    }
    return allocator.dupe(u8, "cache/" ++ DEFAULT_CACHE_DIR_SUFFIX);
}

fn buildComputeKey(wgsl_source: []const u8, payload_kind: PayloadKind) PipelineCacheKey {
    return .{
        .wgsl_hash = translationKeyHash(wgsl_source, payload_kind),
        .kind = .compute,
        .pixel_format = 0,
        .vertex_entry_hash = 0,
        .fragment_entry_hash = 0,
        .sample_count = 1,
        .color_attachment_count = 0,
    };
}

fn translationKeyHash(wgsl_source: []const u8, payload_kind: PayloadKind) [32]u8 {
    var hasher = Sha256.init(.{});
    hashString(&hasher, "domain", TRANSLATION_KEY_DOMAIN);
    hashU32(&hasher, @intFromEnum(payload_kind));
    const source_hash = pipeline_cache.hash_wgsl(wgsl_source);
    hasher.update(source_hash[0..]);
    const contract_digest = translationContractDigest(payload_kind);
    hasher.update(contract_digest[0..]);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn translationContractDigest(payload_kind: PayloadKind) [32]u8 {
    var hasher = Sha256.init(.{});
    hashString(&hasher, "domain", TRANSLATION_CONTRACT_DOMAIN);
    hashU32(&hasher, CACHE_VERSION);
    hashU32(&hasher, @intFromEnum(payload_kind));
    hashU32(&hasher, compilerModeFlags(payload_kind));
    hashString(&hasher, "wgsl_compiler_source_sha256", build_options.wgsl_compiler_source_sha256);
    hashString(&hasher, "shader_translation_cache_source_sha256", build_options.shader_translation_cache_source_sha256);
    hashString(&hasher, "pipeline_cache_source_sha256", build_options.pipeline_cache_source_sha256);
    hashBool(&hasher, "lean_verified", build_options.lean_verified);
    if (build_options.lean_verified) {
        hashString(&hasher, "lean_source_tree_sha256", build_options.lean_source_tree_sha256);
        hashString(&hasher, "proof_pattern_spec_sha256", build_options.proof_pattern_spec_sha256);
        hashString(&hasher, "proof_artifact_sha256", build_options.proof_artifact_sha256);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn hashString(hasher: *Sha256, label: []const u8, value: []const u8) void {
    hasher.update(label);
    hasher.update(&[_]u8{0});
    hashU32(hasher, @intCast(value.len));
    hasher.update(value);
    hasher.update(&[_]u8{0});
}

fn hashBool(hasher: *Sha256, label: []const u8, value: bool) void {
    hasher.update(label);
    hasher.update(&[_]u8{0});
    hasher.update(&[_]u8{if (value) 1 else 0});
}

fn hashU32(hasher: *Sha256, value: u32) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    hasher.update(&bytes);
}

fn currentFlags(info: ?*const TranslationInfo, payload_kind: PayloadKind) u32 {
    var flags = compilerModeFlags(payload_kind);
    if (info != null and info.?.needs_sizes_buf) flags |= FLAG_NEEDS_SIZES_BUF;
    return flags;
}

fn compilerModeFlags(payload_kind: PayloadKind) u32 {
    const config = switch (payload_kind) {
        .msl => wgsl_runtime_compile.compute_runtime_robustness_config(),
        .spirv => wgsl_runtime_compile.vulkan_compute_runtime_robustness_config(),
    };
    var flags: u32 = 0;
    if (config.elide_proven_bounds) flags |= FLAG_BOUNDS_ELISION;
    if (config.elide_proven_texture_bounds) flags |= FLAG_TEXTURE_BOUNDS_ELISION;
    if (config.elide_dispatch_validated_bounds) flags |= FLAG_DISPATCH_VALIDATED_BOUNDS_ELISION;
    if (config.elide_uniform_validated_bounds) flags |= FLAG_UNIFORM_VALIDATED_BOUNDS_ELISION;
    if (config.elide_dispatch_validated_global_bounds) flags |= FLAG_DISPATCH_VALIDATED_GLOBAL_BOUNDS_ELISION;
    return flags;
}

fn encodePayload(
    allocator: std.mem.Allocator,
    payload_source: []const u8,
    info: *const TranslationInfo,
    payload_kind: PayloadKind,
) ![]u8 {
    const dispatch_bytes_len = info.dispatch_preconditions.len * @sizeOf(ir.DispatchPrecondition);
    const texture_bytes_len = info.texture_dispatch_preconditions.len * @sizeOf(ir.TextureDispatchPrecondition);
    const total_len =
        @sizeOf(Header) +
        payload_source.len +
        dispatch_bytes_len +
        texture_bytes_len;
    const payload = try allocator.alloc(u8, total_len);
    var offset: usize = 0;
    const header = Header{
        .magic = CACHE_MAGIC,
        .version = CACHE_VERSION,
        .flags = currentFlags(info, payload_kind),
        .payload_kind = @intFromEnum(payload_kind),
        .workgroup_x = info.workgroup_size[0],
        .workgroup_y = info.workgroup_size[1],
        .workgroup_z = info.workgroup_size[2],
        .dispatch_count = @intCast(info.dispatch_preconditions.len),
        .texture_dispatch_count = @intCast(info.texture_dispatch_preconditions.len),
        .dispatch_stride = @sizeOf(ir.DispatchPrecondition),
        .texture_dispatch_stride = @sizeOf(ir.TextureDispatchPrecondition),
        .payload_len = @intCast(payload_source.len),
        .contract_digest = translationContractDigest(payload_kind),
    };
    writeBytes(payload, &offset, std.mem.asBytes(&header));
    writeBytes(payload, &offset, payload_source);
    writeStructSlice(ir.DispatchPrecondition, payload, &offset, info.dispatch_preconditions);
    writeStructSlice(ir.TextureDispatchPrecondition, payload, &offset, info.texture_dispatch_preconditions);
    return payload;
}

fn decodePayload(
    allocator: std.mem.Allocator,
    payload: []const u8,
    expected_kind: PayloadKind,
) ?CachedPayload {
    if (payload.len < @sizeOf(Header)) return null;
    var offset: usize = 0;
    const header = readHeader(payload, &offset) orelse return null;
    if (header.magic != CACHE_MAGIC or header.version != CACHE_VERSION) return null;
    if (header.payload_kind != @intFromEnum(expected_kind)) return null;
    if (header.flags & ~FLAG_NEEDS_SIZES_BUF != compilerModeFlags(expected_kind)) return null;
    const expected_contract_digest = translationContractDigest(expected_kind);
    if (!std.mem.eql(u8, header.contract_digest[0..], expected_contract_digest[0..])) return null;

    const payload_len: usize = @intCast(header.payload_len);
    const dispatch_count: usize = @intCast(header.dispatch_count);
    const texture_dispatch_count: usize = @intCast(header.texture_dispatch_count);
    if (header.dispatch_stride != @sizeOf(ir.DispatchPrecondition)) return null;
    if (header.texture_dispatch_stride != @sizeOf(ir.TextureDispatchPrecondition)) return null;
    const dispatch_bytes_len = dispatch_count * @sizeOf(ir.DispatchPrecondition);
    const texture_bytes_len = texture_dispatch_count * @sizeOf(ir.TextureDispatchPrecondition);
    if (offset + payload_len + dispatch_bytes_len + texture_bytes_len != payload.len) return null;

    const payload_copy = allocator.dupe(u8, payload[offset .. offset + payload_len]) catch return null;
    offset += payload_len;
    var published = false;
    defer if (!published) allocator.free(payload_copy);

    const dispatch_preconditions = duplicateStructSlice(
        allocator,
        ir.DispatchPrecondition,
        payload[offset .. offset + dispatch_bytes_len],
        dispatch_count,
    ) orelse return null;
    offset += dispatch_bytes_len;
    defer if (!published and dispatch_preconditions.len > 0) allocator.free(dispatch_preconditions);

    const texture_dispatch_preconditions = duplicateStructSlice(
        allocator,
        ir.TextureDispatchPrecondition,
        payload[offset .. offset + texture_bytes_len],
        texture_dispatch_count,
    ) orelse return null;

    published = true;
    return .{
        .payload = payload_copy,
        .info = .{
            .workgroup_size = .{ header.workgroup_x, header.workgroup_y, header.workgroup_z },
            .needs_sizes_buf = (header.flags & FLAG_NEEDS_SIZES_BUF) != 0,
            .dispatch_preconditions = dispatch_preconditions,
            .texture_dispatch_preconditions = texture_dispatch_preconditions,
        },
    };
}

fn readHeader(payload: []const u8, offset: *usize) ?Header {
    if (payload.len < @sizeOf(Header)) return null;
    const bytes = payload[offset.* .. offset.* + @sizeOf(Header)];
    offset.* += @sizeOf(Header);
    return std.mem.bytesToValue(Header, bytes[0..@sizeOf(Header)]);
}

fn writeBytes(payload: []u8, offset: *usize, bytes: []const u8) void {
    @memcpy(payload[offset.* .. offset.* + bytes.len], bytes);
    offset.* += bytes.len;
}

fn writeStructSlice(
    comptime T: type,
    payload: []u8,
    offset: *usize,
    items: []const T,
) void {
    if (items.len == 0) return;
    const bytes = std.mem.sliceAsBytes(items);
    writeBytes(payload, offset, bytes);
}

fn duplicateStructSlice(
    allocator: std.mem.Allocator,
    comptime T: type,
    bytes: []const u8,
    count: usize,
) ?[]const T {
    if (count == 0) return &.{};
    const items = allocator.alloc(T, count) catch return null;
    @memcpy(std.mem.sliceAsBytes(items), bytes);
    return items;
}

test "shader translation cache payload roundtrips" {
    var dispatch = [_]ir.DispatchPrecondition{.{
        .gid_axis = 0,
        .storage_binding = .{ .group = 0, .binding = 1 },
        .element_stride_bytes = 4,
    }};
    var texture = [_]ir.TextureDispatchPrecondition{.{
        .kind = .gid_coords_2d,
        .texture_binding = .{ .group = 0, .binding = 2 },
        .mip_level = 0,
    }};
    const info = TranslationInfo{
        .workgroup_size = .{ 8, 4, 1 },
        .needs_sizes_buf = true,
        .dispatch_preconditions = dispatch[0..],
        .texture_dispatch_preconditions = texture[0..],
    };
    const payload = try encodePayload(std.testing.allocator, "kernel msl", &info, .msl);
    defer std.testing.allocator.free(payload);

    var decoded = decodePayload(std.testing.allocator, payload, .msl) orelse return error.TestExpectedEqual;
    defer decoded.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("kernel msl", decoded.payload);
    try std.testing.expect(decoded.info.needs_sizes_buf);
    try std.testing.expectEqual(@as(u32, 8), decoded.info.workgroup_size[0]);
    try std.testing.expectEqual(@as(usize, 1), decoded.info.dispatch_preconditions.len);
    try std.testing.expectEqual(@as(usize, 1), decoded.info.texture_dispatch_preconditions.len);
}

test "shader translation cache spirv payload roundtrips" {
    const spirv_bytes = [_]u8{
        0x03, 0x02, 0x23, 0x07,
        0x00, 0x00, 0x01, 0x00,
    };
    const info = TranslationInfo{
        .workgroup_size = .{ 16, 1, 1 },
        .needs_sizes_buf = false,
    };
    const payload = try encodePayload(std.testing.allocator, &spirv_bytes, &info, .spirv);
    defer std.testing.allocator.free(payload);

    var decoded = decodePayload(std.testing.allocator, payload, .spirv) orelse return error.TestExpectedEqual;
    defer decoded.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &spirv_bytes, decoded.payload);
    try std.testing.expectEqual(@as(u32, 16), decoded.info.workgroup_size[0]);
    try std.testing.expectEqual(@as(usize, 0), decoded.info.dispatch_preconditions.len);
    try std.testing.expectEqual(@as(usize, 0), decoded.info.texture_dispatch_preconditions.len);
}

test "shader translation cache key separates backend payload kinds" {
    const wgsl = "@compute @workgroup_size(1) fn main() {}";
    const msl_key = buildComputeKey(wgsl, .msl).derive();
    const spirv_key = buildComputeKey(wgsl, .spirv).derive();

    try std.testing.expect(!std.mem.eql(u8, msl_key[0..], spirv_key[0..]));
}

test "shader translation cache rejects stale contract digest" {
    const info = TranslationInfo{
        .workgroup_size = .{ 1, 1, 1 },
        .needs_sizes_buf = false,
    };
    const payload = try encodePayload(std.testing.allocator, "kernel msl", &info, .msl);
    defer std.testing.allocator.free(payload);

    payload[@offsetOf(Header, "contract_digest")] ^= 0xff;
    try std.testing.expect(decodePayload(std.testing.allocator, payload, .msl) == null);
}

fn decodeWithAllocationFailures(allocator: std.mem.Allocator, payload: []const u8) !void {
    var decoded = decodePayload(allocator, payload, .msl) orelse return error.OutOfMemory;
    defer decoded.deinit(allocator);
    try std.testing.expectEqualStrings("kernel msl", decoded.payload);
    try std.testing.expectEqual(@as(usize, 1), decoded.info.dispatch_preconditions.len);
    try std.testing.expectEqual(@as(usize, 1), decoded.info.texture_dispatch_preconditions.len);
}

test "shader translation cache cleans partial optional results on allocation failure" {
    const dispatch = [_]ir.DispatchPrecondition{.{
        .gid_axis = 0,
        .storage_binding = .{ .group = 0, .binding = 1 },
        .element_stride_bytes = 4,
    }};
    const texture = [_]ir.TextureDispatchPrecondition{.{
        .kind = .gid_coords_2d,
        .texture_binding = .{ .group = 0, .binding = 2 },
        .mip_level = 0,
    }};
    const info = TranslationInfo{
        .workgroup_size = .{ 1, 1, 1 },
        .needs_sizes_buf = false,
        .dispatch_preconditions = &dispatch,
        .texture_dispatch_preconditions = &texture,
    };
    const payload = try encodePayload(std.testing.allocator, "kernel msl", &info, .msl);
    defer std.testing.allocator.free(payload);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, decodeWithAllocationFailures, .{payload});
}

pub fn metalLibraryConfiguration() [32]u8 {
    return translationContractDigest(.msl);
}
