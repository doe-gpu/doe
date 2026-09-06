// doe_instance_device_native.zig — Instance, adapter, and device lifecycle exports.
// Sharded from doe_wgpu_native.zig to stay under the line-limit policy.
//
// Backend selection: DOE_BACKEND explicitly selects the runtime backend. When
// DOE_BACKEND is absent, FAWN_BACKEND_LANE provides the Chromium/browser lane
// contract that Doe should honor.

const std = @import("std");
const builtin = @import("builtin");
const has_vulkan = (builtin.os.tag == .linux);
const abi_base = @import("../../core/abi/wgpu_handle_types.zig");
const abi_callback = @import("../../core/abi/wgpu_callback_descriptor_types.zig");
const abi_feature = @import("../../core/abi/wgpu_feature_base_types.zig");
const backend_capabilities = @import("../../backend/dropin_capabilities.zig");
const backend_lifecycle = @import("../../backend/dropin_lifecycle.zig");
const native_types = @import("../support/doe_native_object_types.zig");
const native_helpers = @import("../support/doe_native_object_helpers.zig");
const package_metal_pipeline_cache = @import("../cache/doe_package_metal_pipeline_cache.zig");
const device_caps = @import("../support/doe_device_caps.zig");
const future_ids = @import("../support/doe_future_ids.zig");

const alloc = native_helpers.alloc;
const make = native_helpers.make;
const cast = native_helpers.cast;
const toOpaque = native_helpers.toOpaque;
const label_store = native_helpers.label_store;

const DoeInstance = native_types.DoeInstance;
const DoeAdapter = native_types.DoeAdapter;
const DoeDevice = native_types.DoeDevice;
const DoeQueue = native_types.DoeQueue;
const NativeVulkanRuntime = backend_lifecycle.NativeVulkanRuntime;
const NativeD3D12Runtime = backend_lifecycle.NativeD3D12Runtime;
const d3d12_device_caps = backend_capabilities.d3d12_device_caps;
const vk_feature_caps = if (has_vulkan) backend_capabilities.vk_feature_caps else struct {};
const vk_device_caps = if (has_vulkan) backend_capabilities.vk_device_caps else struct {};
const vk_adapter_probe = if (has_vulkan) backend_capabilities.vk_adapter_probe else struct {};
const vulkan_feature_cache = if (has_vulkan) @import("../vulkan/vulkan_feature_cache.zig") else struct {};
const backend_policy = @import("../../backend/backend_policy.zig");
const runtime_types = @import("../../contracts/runtime_types.zig");

const metal_bridge_create_default_device = backend_lifecycle.metal_bridge_create_default_device;
const metal_bridge_device_new_command_queue = backend_lifecycle.metal_bridge_device_new_command_queue;
const metal_bridge_device_new_shared_event = backend_lifecycle.metal_bridge_device_new_shared_event;
const metal_bridge_release = backend_lifecycle.metal_bridge_release;

const WGPU_WAIT_STATUS_SUCCESS: u32 = 1;
const WGPU_WAIT_STATUS_TIMED_OUT: u32 = 2;
const WGPU_REQUEST_STATUS_SUCCESS: u32 = 1;
const WGPU_REQUEST_STATUS_UNAVAILABLE: u32 = 3;
const WGPU_REQUEST_STATUS_ERROR: u32 = 4;
const MSG_ADAPTER_UNAVAILABLE = "metal default device unavailable";
const MSG_ADAPTER_ALLOCATION_FAILED = "adapter allocation failed";
const MSG_VK_ADAPTER_PROBE_FAILED = "vulkan physical adapter probe failed";
const MSG_INVALID_ADAPTER = "invalid adapter handle";
const MSG_QUEUE_UNAVAILABLE = "metal command queue unavailable";
const MSG_DEVICE_ALLOCATION_FAILED = "device allocation failed";
const MSG_VK_RUNTIME_INIT_FAILED = "vulkan runtime init failed";
const MSG_D3D12_RUNTIME_INIT_FAILED = "d3d12 runtime init failed";
const MSG_RUNTIME_POLICY_INVALID = "backend runtime policy invalid";
const MSG_DEVICE_DESCRIPTOR_INVALID = "invalid device feature descriptor";
const MSG_REQUIRED_FEATURE_UNSUPPORTED = "required device feature unsupported";

const RequestedBackend = enum {
    metal,
    vulkan,
    d3d12,
};

var cached_selected_backend: RequestedBackend = switch (builtin.os.tag) {
    .macos => .metal,
    .windows => .d3d12,
    else => .vulkan,
};
var selected_backend_initialized = false;
var selected_backend_mutex: std.Thread.Mutex = .{};

fn instance_add_ref(inst: *DoeInstance) void {
    native_helpers.object_add_ref(DoeInstance, toOpaque(inst));
}

fn adapter_add_ref(adapter: *DoeAdapter) void {
    native_helpers.object_add_ref(DoeAdapter, toOpaque(adapter));
}

fn device_add_ref(device: *DoeDevice) void {
    native_helpers.object_add_ref(DoeDevice, toOpaque(device));
}

fn parse_requested_backend(raw: []const u8) ?RequestedBackend {
    inline for (@typeInfo(RequestedBackend).@"enum".fields) |field| {
        if (std.ascii.eqlIgnoreCase(raw, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn requested_backend_from_lane(raw: []const u8) ?RequestedBackend {
    const lane = backend_policy.parse_lane(raw) orelse return null;
    return switch (lane) {
        .metal_doe_app, .metal_doe_directional, .metal_doe_comparable, .metal_doe_release, .metal_dawn_release, .metal_webkit_release, .metal_webkit_comparable => .metal,
        .vulkan_doe_app,
        .vulkan_doe_comparable,
        .vulkan_doe_compute_only_diagnostic,
        .vulkan_doe_compute_only_fence_diagnostic,
        .vulkan_doe_release,
        .vulkan_dawn_release,
        => .vulkan,
        .d3d12_doe_app, .d3d12_doe_directional, .d3d12_doe_comparable, .d3d12_doe_release, .d3d12_dawn_release => .d3d12,
    };
}

fn selected_backend() RequestedBackend {
    selected_backend_mutex.lock();
    defer selected_backend_mutex.unlock();
    if (selected_backend_initialized) {
        return cached_selected_backend;
    }

    const backend = blk: {
        const explicit_backend = std.process.getEnvVarOwned(alloc, "DOE_BACKEND") catch null;
        if (explicit_backend) |raw_backend| {
            defer alloc.free(raw_backend);
            if (parse_requested_backend(raw_backend)) |parsed_backend| break :blk parsed_backend;
        }

        const lane_value = std.process.getEnvVarOwned(alloc, "FAWN_BACKEND_LANE") catch null;
        if (lane_value) |raw_lane| {
            defer alloc.free(raw_lane);
            if (requested_backend_from_lane(raw_lane)) |parsed_backend| break :blk parsed_backend;
        }

        break :blk switch (builtin.os.tag) {
            .macos => .metal,
            .windows => .d3d12,
            else => .vulkan,
        };
    };

    cached_selected_backend = backend;
    selected_backend_initialized = true;
    return backend;
}

fn selected_backend_lane() ?backend_policy.BackendLane {
    const explicit_backend = std.process.getEnvVarOwned(alloc, "DOE_BACKEND") catch null;
    if (explicit_backend) |raw_backend| {
        defer alloc.free(raw_backend);
        if (parse_requested_backend(raw_backend) != null) return null;
    }

    const lane_value = std.process.getEnvVarOwned(alloc, "FAWN_BACKEND_LANE") catch return null;
    defer alloc.free(lane_value);
    return backend_policy.parse_lane(lane_value);
}

const SelectedVulkanRuntimePolicy = struct {
    queue_family_policy: runtime_types.QueueFamilyPolicy,
    deferred_submission_sync_policy: runtime_types.DeferredSubmissionSyncPolicy,
    vulkan_subgroup_size_policy: backend_policy.VulkanSubgroupSizePolicy,
};

fn selected_vulkan_policy() CreateDeviceError!SelectedVulkanRuntimePolicy {
    const lane = selected_backend_lane() orelse {
        const policy = backend_policy.default_policy_for_lane(.vulkan_doe_app);
        return .{
            .queue_family_policy = policy.queue_family_policy,
            .deferred_submission_sync_policy = policy.deferred_submission_sync_policy,
            .vulkan_subgroup_size_policy = policy.vulkan_subgroup_size_policy,
        };
    };
    const loaded_policy = backend_policy.load_policy_for_lane(
        alloc,
        backend_policy.DEFAULT_RUNTIME_POLICY_PATH,
        lane,
    ) catch return error.RuntimePolicyInvalid;
    defer alloc.free(loaded_policy.owned_policy_hash);
    return .{
        .queue_family_policy = loaded_policy.policy.queue_family_policy,
        .deferred_submission_sync_policy = loaded_policy.policy.deferred_submission_sync_policy,
        .vulkan_subgroup_size_policy = loaded_policy.policy.vulkan_subgroup_size_policy,
    };
}

fn probe_d3d12_adapter_caps() d3d12_device_caps.D3D12DeviceCaps {
    var rt = NativeD3D12Runtime.init(alloc, null) catch return .{};
    defer rt.deinit();
    return rt.device_caps;
}

fn stringView(comptime message: []const u8) abi_base.WGPUStringView {
    return .{ .data = message.ptr, .length = message.len };
}

fn call_request_adapter_callback(
    info: abi_callback.WGPURequestAdapterCallbackInfo,
    status: abi_callback.WGPURequestAdapterStatus,
    adapter: ?*anyopaque,
    message: abi_base.WGPUStringView,
) void {
    const callback = info.callback orelse return;
    callback(status, @ptrCast(adapter), message, info.userdata1, info.userdata2);
}

fn call_request_device_callback(
    info: abi_callback.WGPURequestDeviceCallbackInfo,
    status: abi_callback.WGPURequestDeviceStatus,
    device: ?*anyopaque,
    message: abi_base.WGPUStringView,
) void {
    const callback = info.callback orelse return;
    callback(status, @ptrCast(device), message, info.userdata1, info.userdata2);
}

const CreateDeviceError = error{
    QueueUnavailable,
    DeviceAllocationFailed,
    VkRuntimeInitFailed,
    D3D12RuntimeInitFailed,
    RuntimePolicyInvalid,
    DeviceDescriptorInvalid,
    RequiredFeatureUnsupported,
};

const CreateAdapterError = error{
    AdapterUnavailable,
    AdapterAllocationFailed,
    VkAdapterProbeFailed,
};

fn create_device_error_message(err: CreateDeviceError) abi_base.WGPUStringView {
    return switch (err) {
        error.QueueUnavailable => stringView(MSG_QUEUE_UNAVAILABLE),
        error.DeviceAllocationFailed => stringView(MSG_DEVICE_ALLOCATION_FAILED),
        error.VkRuntimeInitFailed => stringView(MSG_VK_RUNTIME_INIT_FAILED),
        error.D3D12RuntimeInitFailed => stringView(MSG_D3D12_RUNTIME_INIT_FAILED),
        error.RuntimePolicyInvalid => stringView(MSG_RUNTIME_POLICY_INVALID),
        error.DeviceDescriptorInvalid => stringView(MSG_DEVICE_DESCRIPTOR_INVALID),
        error.RequiredFeatureUnsupported => stringView(MSG_REQUIRED_FEATURE_UNSUPPORTED),
    };
}

fn create_adapter_error_message(err: CreateAdapterError) abi_base.WGPUStringView {
    return switch (err) {
        error.AdapterUnavailable => stringView(MSG_ADAPTER_UNAVAILABLE),
        error.AdapterAllocationFailed => stringView(MSG_ADAPTER_ALLOCATION_FAILED),
        error.VkAdapterProbeFailed => stringView(MSG_VK_ADAPTER_PROBE_FAILED),
    };
}

fn create_adapter_for_instance(inst: ?*anyopaque) CreateAdapterError!*DoeAdapter {
    const retained_instance = cast(DoeInstance, inst);

    switch (selected_backend()) {
        .d3d12 => {
            const adapter = make(DoeAdapter) orelse return error.AdapterAllocationFailed;
            if (retained_instance) |instance_ref| instance_add_ref(instance_ref);
            adapter.* = .{ .backend = .d3d12, .instance = retained_instance };
            d3d12_device_caps.set_adapter_caps(toOpaque(adapter), probe_d3d12_adapter_caps());
            return adapter;
        },
        .vulkan => {
            if (comptime has_vulkan) {
                const selected_policy = selected_vulkan_policy() catch {
                    return error.VkAdapterProbeFailed;
                };
                const adapter_probe = vk_adapter_probe.probe_selected_adapter(
                    alloc,
                    selected_policy.queue_family_policy,
                ) catch return error.VkAdapterProbeFailed;
                const identity = adapter_probe.identity;
                const adapter = make(DoeAdapter) orelse return error.AdapterAllocationFailed;
                if (retained_instance) |instance_ref| instance_add_ref(instance_ref);
                adapter.* = .{
                    .backend = .vulkan,
                    .instance = retained_instance,
                    .vendor_id = identity.vendor_id,
                    .device_id = identity.device_id,
                    .driver_version = identity.driver_version,
                    .device_name = identity.device_name,
                    .device_name_len = identity.device_name_len,
                };
                vulkan_feature_cache.set_adapter(toOpaque(adapter), adapter_probe.feature_caps);
                vulkan_feature_cache.set_adapter_device_caps(toOpaque(adapter), adapter_probe.device_caps);
                return adapter;
            }
        },
        .metal => {},
    }

    const device = metal_bridge_create_default_device();
    if (device == null) return error.AdapterUnavailable;
    const adapter = make(DoeAdapter) orelse {
        metal_bridge_release(device);
        return error.AdapterAllocationFailed;
    };
    if (retained_instance) |instance_ref| instance_add_ref(instance_ref);
    adapter.* = .{ .instance = retained_instance, .mtl_device = device };
    return adapter;
}

fn copy_enabled_features(
    adapter_raw: ?*anyopaque,
    desc: ?*const abi_callback.WGPUDeviceDescriptor,
) CreateDeviceError![]abi_feature.WGPUFeatureName {
    const descriptor = desc orelse return &.{};
    if (descriptor.requiredFeatureCount == 0) return &.{};
    const requested = descriptor.requiredFeatures orelse return error.DeviceDescriptorInvalid;
    const owned = alloc.alloc(
        abi_feature.WGPUFeatureName,
        descriptor.requiredFeatureCount,
    ) catch return error.DeviceAllocationFailed;
    errdefer alloc.free(owned);

    for (requested[0..descriptor.requiredFeatureCount], 0..) |feature, index| {
        const embedder_feature = feature == abi_feature.WGPUFeatureName_DawnInternalUsages;
        if (!embedder_feature and device_caps.doeNativeAdapterHasFeature(adapter_raw, feature) == 0) {
            return error.RequiredFeatureUnsupported;
        }
        for (owned[0..index]) |enabled_feature| {
            if (enabled_feature == feature) return error.DeviceDescriptorInvalid;
        }
        owned[index] = feature;
    }
    return owned;
}

fn create_device_for_adapter(
    adapter: *DoeAdapter,
    adapter_raw: ?*anyopaque,
    desc: ?*const abi_callback.WGPUDeviceDescriptor,
) CreateDeviceError!*DoeDevice {
    const enabled_features = try copy_enabled_features(adapter_raw, desc);
    errdefer if (enabled_features.len > 0) alloc.free(enabled_features);

    if (comptime has_vulkan) {
        if (adapter.backend == .vulkan) {
            const dev = make(DoeDevice) orelse return error.DeviceAllocationFailed;
            const rt = alloc.create(NativeVulkanRuntime) catch {
                alloc.destroy(dev);
                return error.DeviceAllocationFailed;
            };
            const selected_policy = try selected_vulkan_policy();
            rt.* = NativeVulkanRuntime.init_with_backend_policy(
                alloc,
                null,
                selected_policy.queue_family_policy,
                selected_policy.deferred_submission_sync_policy,
                selected_policy.vulkan_subgroup_size_policy,
            ) catch {
                alloc.destroy(rt);
                alloc.destroy(dev);
                return error.VkRuntimeInitFailed;
            };
            const runtime_identity = vk_adapter_probe.query_identity(rt.physical_device);
            if (!vk_adapter_probe.identity_matches_fields(
                adapter.vendor_id,
                adapter.device_id,
                adapter.driver_version,
                adapter.device_name[0..adapter.device_name_len],
                runtime_identity,
            )) {
                rt.deinit();
                alloc.destroy(rt);
                alloc.destroy(dev);
                return error.VkRuntimeInitFailed;
            }
            adapter_add_ref(adapter);
            dev.* = .{
                .backend = .vulkan,
                .adapter = adapter,
                .vk_runtime = @ptrCast(rt),
                .enabled_features = enabled_features,
            };
            const feature_caps: vk_feature_caps.VulkanFeatureCaps = blk: {
                if (vulkan_feature_cache.get_adapter(adapter_raw)) |cached| break :blk cached;
                const queried = vk_feature_caps.query(rt.physical_device).caps;
                vulkan_feature_cache.set_adapter(adapter_raw, queried);
                break :blk queried;
            };
            vulkan_feature_cache.set_device(toOpaque(dev), feature_caps);
            // Propagate hardware-queried device caps from adapter, or re-query from runtime.
            if (vulkan_feature_cache.get_adapter_device_caps(adapter_raw)) |adapter_hw_caps| {
                vulkan_feature_cache.set_device_device_caps(toOpaque(dev), adapter_hw_caps);
            } else {
                const runtime_caps = vk_device_caps.query_device_caps(
                    rt.physical_device,
                    if (rt.timestamp_query_supported_value) 36 else 0,
                );
                vulkan_feature_cache.set_adapter_device_caps(adapter_raw, runtime_caps);
                vulkan_feature_cache.set_device_device_caps(toOpaque(dev), runtime_caps);
            }
            return dev;
        }
    }

    if (adapter.backend == .d3d12) {
        const dev = make(DoeDevice) orelse return error.DeviceAllocationFailed;
        const rt = alloc.create(NativeD3D12Runtime) catch {
            alloc.destroy(dev);
            return error.DeviceAllocationFailed;
        };
        rt.* = NativeD3D12Runtime.init(alloc, null) catch {
            alloc.destroy(rt);
            alloc.destroy(dev);
            return error.D3D12RuntimeInitFailed;
        };
        adapter_add_ref(adapter);
        dev.* = .{
            .backend = .d3d12,
            .adapter = adapter,
            .mtl_device = rt.device,
            .mtl_queue = rt.queue,
            .d3d12_runtime = @ptrCast(rt),
            .enabled_features = enabled_features,
        };
        return dev;
    }

    const queue = metal_bridge_device_new_command_queue(adapter.mtl_device);
    if (queue == null) return error.QueueUnavailable;
    const dev = make(DoeDevice) orelse {
        metal_bridge_release(queue);
        return error.DeviceAllocationFailed;
    };
    adapter_add_ref(adapter);
    dev.* = .{
        .adapter = adapter,
        .mtl_device = adapter.mtl_device,
        .mtl_queue = queue,
        .metal_libraries = .{ .ops = .{ .retain = backend_lifecycle.metal_bridge_retain, .release = backend_lifecycle.metal_bridge_release } },
        .enabled_features = enabled_features,
    };
    return dev;
}

// ============================================================
// Instance
// ============================================================

pub export fn doeNativeCreateInstance(desc: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = desc;
    const inst = make(DoeInstance) orelse return null;
    inst.* = .{};
    return toOpaque(inst);
}

pub export fn doeNativeInstanceAddRef(raw: ?*anyopaque) callconv(.c) void {
    const inst = cast(DoeInstance, raw) orelse return;
    instance_add_ref(inst);
}

pub export fn doeNativeInstanceRelease(raw: ?*anyopaque) callconv(.c) void {
    if (cast(DoeInstance, raw)) |inst| {
        // Guard: prevent destruction while external textures still reference this
        // Instance. The Chromium wire client may release its Instance handle before
        // external textures are freed; the external-texture backref path will call
        // InstanceRelease again when the last external texture is destroyed.
        const ext_tex = @import("../resource/doe_external_texture_native.zig");
        if (ext_tex.instance_external_texture_count(raw) > 0) {
            var count = @atomicLoad(u32, &inst.ref_count, .monotonic);
            while (count > 1) {
                count = @cmpxchgWeak(u32, &inst.ref_count, count, count - 1, .acq_rel, .monotonic) orelse break;
            }
            return;
        }
        if (!native_helpers.object_should_destroy(inst)) return;
        native_helpers.label_store.remove(raw);
        alloc.destroy(inst);
    }
}

pub export fn doeNativeInstanceWaitAny(inst: ?*anyopaque, count: usize, infos: [*]abi_callback.WGPUFutureWaitInfo, timeout_ns: u64) callconv(.c) u32 {
    _ = inst;
    _ = timeout_ns;
    if (count == 0) return WGPU_WAIT_STATUS_SUCCESS;
    var any_completed = false;
    for (infos[0..count]) |*info| {
        if (future_ids.is_device_lost_future_id(info.future.id)) {
            info.completed = 0;
        } else {
            info.completed = 1;
            any_completed = true;
        }
    }
    return if (any_completed) WGPU_WAIT_STATUS_SUCCESS else WGPU_WAIT_STATUS_TIMED_OUT;
}

// ============================================================
// Adapter
// ============================================================

// Flat adapter request: callback(status, adapter, message, userdata1, userdata2)
pub export fn doeNativeRequestAdapterFlat(
    inst: ?*anyopaque,
    _: ?*anyopaque, // options
    _: u32, // callback mode
    callback: ?*const fn (u32, ?*anyopaque, abi_base.WGPUStringView, ?*anyopaque, ?*anyopaque) callconv(.c) void,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) abi_base.WGPUFuture {
    const adapter = create_adapter_for_instance(inst) catch |err| {
        const status: u32 = switch (err) {
            error.AdapterUnavailable => WGPU_REQUEST_STATUS_UNAVAILABLE,
            error.AdapterAllocationFailed, error.VkAdapterProbeFailed => WGPU_REQUEST_STATUS_ERROR,
        };
        if (callback) |cb| cb(status, null, create_adapter_error_message(err), userdata1, userdata2);
        return .{ .id = 1 };
    };
    if (callback) |cb| cb(WGPU_REQUEST_STATUS_SUCCESS, toOpaque(adapter), stringView(""), userdata1, userdata2);
    return .{ .id = 1 };
}

pub export fn doeNativeInstanceCreateAdapter(
    inst: ?*anyopaque,
    options: ?*const abi_callback.WGPURequestAdapterOptions,
) callconv(.c) ?*anyopaque {
    _ = options;
    const adapter = create_adapter_for_instance(inst) catch return null;
    return toOpaque(adapter);
}

// Standard-signature wrapper for routing layer compatibility.
pub export fn doeNativeInstanceRequestAdapter(
    inst: ?*anyopaque,
    options: ?*const abi_callback.WGPURequestAdapterOptions,
    info: abi_callback.WGPURequestAdapterCallbackInfo,
) callconv(.c) abi_base.WGPUFuture {
    _ = options;
    const adapter = create_adapter_for_instance(inst) catch |err| {
        const status: abi_callback.WGPURequestAdapterStatus = switch (err) {
            error.AdapterUnavailable => .unavailable,
            error.AdapterAllocationFailed, error.VkAdapterProbeFailed => .@"error",
        };
        call_request_adapter_callback(info, status, null, create_adapter_error_message(err));
        return .{ .id = 1 };
    };
    call_request_adapter_callback(info, .success, toOpaque(adapter), stringView(""));
    return .{ .id = 1 };
}

pub export fn doeNativeAdapterAddRef(raw: ?*anyopaque) callconv(.c) void {
    const adapter = cast(DoeAdapter, raw) orelse return;
    adapter_add_ref(adapter);
}

pub export fn doeNativeAdapterGetInstance(raw: ?*anyopaque) callconv(.c) ?*anyopaque {
    const adapter = cast(DoeAdapter, raw) orelse return null;
    const instance = adapter.instance orelse return null;
    instance_add_ref(instance);
    return toOpaque(instance);
}

pub export fn doeNativeAdapterRelease(raw: ?*anyopaque) callconv(.c) void {
    // Every DoeDevice retains its adapter; the adapter owns their shared Metal device.
    if (cast(DoeAdapter, raw)) |a| {
        if (!native_helpers.object_should_destroy(a)) return;
        label_store.remove(raw);
        if (comptime has_vulkan) {
            if (a.backend == .vulkan) vulkan_feature_cache.remove_adapter(raw);
        }
        if (a.backend == .d3d12) d3d12_device_caps.remove_adapter_caps(raw);
        if (a.backend == .metal) if (a.mtl_device) |device| metal_bridge_release(device);
        if (a.instance) |instance_ref| doeNativeInstanceRelease(toOpaque(instance_ref));
        alloc.destroy(a);
    }
}

// ============================================================
// Device
// ============================================================

pub export fn doeNativeAdapterRequestDevice(
    adapter_raw: ?*anyopaque,
    desc: ?*const abi_callback.WGPUDeviceDescriptor,
    info: abi_callback.WGPURequestDeviceCallbackInfo,
) callconv(.c) abi_base.WGPUFuture {
    const adapter = cast(DoeAdapter, adapter_raw) orelse {
        call_request_device_callback(info, .@"error", null, stringView(MSG_INVALID_ADAPTER));
        return .{ .id = 2 };
    };
    const dev = create_device_for_adapter(adapter, adapter_raw, desc) catch |err| {
        call_request_device_callback(info, .@"error", null, create_device_error_message(err));
        return .{ .id = 2 };
    };
    call_request_device_callback(info, .success, toOpaque(dev), stringView(""));
    return .{ .id = 2 };
}

pub export fn doeNativeAdapterCreateDevice(
    adapter_raw: ?*anyopaque,
    desc: ?*const abi_callback.WGPUDeviceDescriptor,
) callconv(.c) ?*anyopaque {
    const adapter = cast(DoeAdapter, adapter_raw) orelse return null;
    const dev = create_device_for_adapter(adapter, adapter_raw, desc) catch return null;
    return toOpaque(dev);
}

// Flat device request.
pub export fn doeNativeRequestDeviceFlat(
    adapter_raw: ?*anyopaque,
    descriptor_raw: ?*anyopaque,
    _: u32,
    callback: ?*const fn (u32, ?*anyopaque, abi_base.WGPUStringView, ?*anyopaque, ?*anyopaque) callconv(.c) void,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) abi_base.WGPUFuture {
    const adapter = cast(DoeAdapter, adapter_raw) orelse {
        if (callback) |cb| cb(WGPU_REQUEST_STATUS_ERROR, null, stringView(MSG_INVALID_ADAPTER), userdata1, userdata2);
        return .{ .id = 2 };
    };
    const desc: ?*const abi_callback.WGPUDeviceDescriptor = if (descriptor_raw) |ptr|
        @ptrCast(@alignCast(ptr))
    else
        null;
    const dev = create_device_for_adapter(adapter, adapter_raw, desc) catch |err| {
        if (callback) |cb| cb(WGPU_REQUEST_STATUS_ERROR, null, create_device_error_message(err), userdata1, userdata2);
        return .{ .id = 2 };
    };
    if (callback) |cb| cb(WGPU_REQUEST_STATUS_SUCCESS, toOpaque(dev), stringView(""), userdata1, userdata2);
    return .{ .id = 2 };
}

pub export fn doeNativeDeviceAddRef(raw: ?*anyopaque) callconv(.c) void {
    const device = cast(DoeDevice, raw) orelse return;
    device_add_ref(device);
}

pub export fn doeNativeDeviceGetAdapter(raw: ?*anyopaque) callconv(.c) ?*anyopaque {
    const device = cast(DoeDevice, raw) orelse return null;
    const adapter = device.adapter orelse return null;
    adapter_add_ref(adapter);
    return toOpaque(adapter);
}

pub export fn doeNativeDeviceRelease(raw: ?*anyopaque) callconv(.c) void {
    if (cast(DoeDevice, raw)) |d| {
        if (!native_helpers.object_should_destroy(d)) return;
        label_store.remove(raw);
        if (d.metal_libraries) |*cache| cache.deinit(alloc);
        // Fire the device-lost callback with reason "destroyed" before teardown.
        const multi_adapter = @import("../../runtime/device/multi_adapter.zig");
        multi_adapter.notify_device_released(raw);
        if (comptime has_vulkan) {
            if (d.backend == .vulkan) {
                vulkan_feature_cache.remove_device(raw);
                // Deinit and free the Vulkan runtime (releases all VkBuffer/VkDevice etc.).
                if (d.vk_runtime) |ptr| {
                    const rt: *NativeVulkanRuntime = @ptrCast(@alignCast(ptr));
                    rt.deinit();
                    alloc.destroy(rt);
                }
            } else if (d.backend == .d3d12) {
                if (d.d3d12_runtime) |ptr| {
                    const rt: *NativeD3D12Runtime = @ptrCast(@alignCast(ptr));
                    rt.deinit();
                    alloc.destroy(rt);
                }
            } else {
                package_metal_pipeline_cache.deinitForDevice(d);
                if (d.mtl_queue) |q| metal_bridge_release(q);
            }
        } else if (d.backend == .d3d12) {
            if (d.d3d12_runtime) |ptr| {
                const rt: *NativeD3D12Runtime = @ptrCast(@alignCast(ptr));
                rt.deinit();
                alloc.destroy(rt);
            }
        } else {
            package_metal_pipeline_cache.deinitForDevice(d);
            if (d.mtl_queue) |q| metal_bridge_release(q);
        }
        if (d.enabled_features.len > 0) alloc.free(d.enabled_features);
        const adapter = d.adapter;
        alloc.destroy(d);
        if (adapter) |adapter_ref| doeNativeAdapterRelease(toOpaque(adapter_ref));
    }
}

pub export fn doeNativeDeviceGetQueue(raw: ?*anyopaque) callconv(.c) ?*anyopaque {
    const dev = cast(DoeDevice, raw) orelse return null;
    if (dev.queue) |q| {
        native_helpers.object_add_ref(DoeQueue, toOpaque(q));
        return toOpaque(q);
    }
    const q = make(DoeQueue) orelse return null;
    device_add_ref(dev);
    q.* = .{ .dev = dev };
    // MTLSharedEvent is only used for Metal GPU-CPU synchronization.
    if (dev.backend == .metal) {
        q.mtl_event = metal_bridge_device_new_shared_event(dev.mtl_device);
    }
    dev.queue = q;
    return toOpaque(q);
}
