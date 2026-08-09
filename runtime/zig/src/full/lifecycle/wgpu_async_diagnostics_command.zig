const std = @import("std");
const log = std.log.scoped(.wgpu_async_diagnostics);
const model_gpu_types = @import("../../contracts/model/model_texture_value_types.zig");
const model_async_types = @import("../../contracts/model/model_async_types.zig");
const proc_types = @import("../../core/abi/wgpu_proc_types.zig");
const abi_base = proc_types.base;
const abi_descriptor = proc_types.descriptor;
const abi_execution = @import("../../core/abi/wgpu_execution_types.zig");
const abi_proc_aliases = @import("../../core/abi/wgpu_type_proc_aliases.zig");
const loader = @import("../../core/abi/wgpu_loader.zig");
const resources = @import("../../core/resource/wgpu_resources.zig");
const p0_procs_mod = @import("../../core/abi/procs/wgpu_p0_procs.zig");
const p1_resource_table_procs_mod = @import("../../core/abi/procs/wgpu_p1_resource_table_procs.zig");
const p2_lifecycle_procs_mod = @import("../../core/abi/procs/wgpu_p2_lifecycle_procs.zig");
const async_procs_mod = @import("../../core/abi/procs/wgpu_async_procs.zig");
const async_pixel_local_storage_mod = @import("wgpu_async_pixel_local_storage.zig");
const render_api_mod = @import("../render/wgpu_render_api.zig");
const render_resource_mod = @import("../render/wgpu_render_resources.zig");
const render_types_mod = @import("../render/wgpu_render_types.zig");
const surface_procs_mod = @import("../surface/wgpu_surface_procs.zig");
const texture_procs_mod = @import("../../core/abi/procs/wgpu_texture_procs.zig");
const rc = @import("../render/wgpu_render_constants.zig");
const DIAG_RESOURCE_TABLE_BUFFER_HANDLE: u64 = 0x8C9F_2B00_0000_0000;
const DIAG_RESOURCE_TABLE_BUFFER_SIZE: u64 = 256;
const DIAG_RESOURCE_TABLE_SIZE: u32 = 8;
const DIAG_RENDER_TARGET_HANDLE: u64 = 0x8C9F_2C00_0000_0000;
const DIAG_RENDER_TARGET_WIDTH: u32 = 4;
const DIAG_RENDER_TARGET_HEIGHT: u32 = 4;
const DIAG_MAX_DRAW_COUNT: u64 = 50_000_000;
const WGPUFeatureName_ChromiumExperimentalSamplingResourceTable: abi_base.WGPUFeatureName = 0x0005003A;

const DIAGNOSTIC_SHADER_SOURCE =
    \\@vertex
    \\fn vs_main(@builtin(vertex_index) idx: u32) -> @builtin(position) vec4f {
    \\  var p = array<vec2f, 3>(
    \\    vec2f(0.0, 0.5),
    \\    vec2f(-0.5, -0.5),
    \\    vec2f(0.5, -0.5),
    \\  );
    \\  let pos = p[idx];
    \\  return vec4f(pos, 0.0, 1.0);
    \\}
    \\@fragment
    \\fn fs_main() -> @location(0) vec4f {
    \\  return vec4f(0.0, 0.0, 0.0, 1.0);
    \\}
;

const DIAGNOSTIC_COMPUTE_SHADER_SOURCE =
    \\@compute @workgroup_size(1)
    \\fn main() {}
;

pub fn executeAsyncDiagnostics(self: anytype, diagnostics: model_async_types.AsyncDiagnosticsCommand) !abi_execution.NativeExecutionResult {
    const setup_start_ns = std.time.nanoTimestamp();
    var iteration: u32 = 0;
    while (iteration < diagnostics.iterations) : (iteration += 1) {
        const mode_result = switch (diagnostics.mode) {
            .pipeline_async => runPipelineAsyncDiagnostics(self, diagnostics.target_format),
            .capability_introspection => runCapabilityIntrospectionDiagnostics(self),
            .resource_table_immediates => runResourceTableImmediatesDiagnostics(self, diagnostics.target_format),
            .lifecycle_refcount => runLifecycleRefcountDiagnostics(self, diagnostics.target_format),
            .pixel_local_storage => async_pixel_local_storage_mod.runPixelLocalStorageDiagnostics(self, diagnostics.target_format),
            .full => runFullDiagnostics(self, diagnostics.target_format, diagnostics.feature_policy),
        };
        mode_result catch |err| {
            if (shouldEmulateUnavailableFeature(diagnostics.feature_policy, diagnostics.mode, err)) {
                if (diagnostics.mode == .resource_table_immediates) {
                    runResourceTableImmediatesDiagnosticsEmulated(self, diagnostics.target_format) catch |emulated_err| {
                        if (unsupportedDiagnosticsMessage(emulated_err)) |message| {
                            return .{
                                .status = .unsupported,
                                .status_message = message,
                            };
                        }
                        return .{
                            .status = .@"error",
                            .status_message = @errorName(emulated_err),
                        };
                    };
                } else if (diagnostics.mode == .pixel_local_storage) {
                    async_pixel_local_storage_mod.runPixelLocalStorageDiagnosticsEmulated(self, diagnostics.target_format) catch |emulated_err| {
                        if (unsupportedDiagnosticsMessage(emulated_err)) |message| {
                            return .{
                                .status = .unsupported,
                                .status_message = message,
                            };
                        }
                        return .{
                            .status = .@"error",
                            .status_message = @errorName(emulated_err),
                        };
                    };
                }
                continue;
            }
            if (unsupportedDiagnosticsMessage(err)) |message| {
                return .{
                    .status = .unsupported,
                    .status_message = message,
                };
            }
            return .{
                .status = .@"error",
                .status_message = @errorName(err),
            };
        };
    }

    const setup_end_ns = std.time.nanoTimestamp();
    const setup_ns = if (setup_end_ns > setup_start_ns)
        @as(u64, @intCast(setup_end_ns - setup_start_ns))
    else
        0;
    return .{
        .status = .ok,
        .status_message = switch (diagnostics.mode) {
            .pipeline_async => "async diagnostics pipeline mode completed",
            .capability_introspection => "async diagnostics capability introspection completed",
            .resource_table_immediates => switch (diagnostics.feature_policy) {
                .strict => "async diagnostics resource-table/immediates completed",
                .emulate_when_unavailable => "async diagnostics resource-table/immediates completed (emulate-when-unavailable policy)",
            },
            .lifecycle_refcount => "async diagnostics lifecycle/refcount completed",
            .pixel_local_storage => switch (diagnostics.feature_policy) {
                .strict => "async diagnostics pixel-local-storage completed",
                .emulate_when_unavailable => "async diagnostics pixel-local-storage completed (emulate-when-unavailable policy)",
            },
            .full => "async diagnostics full mode completed",
        },
        .setup_ns = setup_ns,
    };
}

fn runFullDiagnostics(
    self: anytype,
    target_format: abi_base.WGPUTextureFormat,
    feature_policy: model_async_types.AsyncDiagnosticsFeaturePolicy,
) !void {
    try runPipelineAsyncDiagnostics(self, target_format);
    try runCapabilityIntrospectionDiagnostics(self);
    runResourceTableImmediatesDiagnostics(self, target_format) catch |err| {
        if (shouldEmulateUnavailableFeature(feature_policy, .resource_table_immediates, err)) {
            try runResourceTableImmediatesDiagnosticsEmulated(self, target_format);
        } else {
            return err;
        }
    };
    try runLifecycleRefcountDiagnostics(self, target_format);
    async_pixel_local_storage_mod.runPixelLocalStorageDiagnostics(self, target_format) catch |err| {
        if (shouldEmulateUnavailableFeature(feature_policy, .pixel_local_storage, err)) {
            try async_pixel_local_storage_mod.runPixelLocalStorageDiagnosticsEmulated(self, target_format);
        } else {
            return err;
        }
    };
}

fn runCapabilityIntrospectionDiagnostics(self: anytype) !void {
    try self.runCapabilityIntrospection();
}

fn runPipelineAsyncDiagnostics(self: anytype, target_format: abi_base.WGPUTextureFormat) !void {
    const procs = self.core.procs orelse return error.ProceduralNotReady;
    const render_api = render_api_mod.loadRenderApi(procs, self.core.dyn_lib) orelse return error.RenderApiUnavailable;
    const pipeline = try createRenderPipelineForDiagnostics(self, target_format);
    render_api.render_pipeline_release(pipeline);
}

fn runResourceTableImmediatesDiagnostics(self: anytype, target_format: abi_base.WGPUTextureFormat) !void {
    const procs = self.core.procs orelse return error.ProceduralNotReady;
    const render_api = render_api_mod.loadRenderApi(procs, self.core.dyn_lib) orelse return error.RenderApiUnavailable;
    const resource_table_procs = self.getResourceTableProcs() orelse return error.ResourceTableProcUnavailable;
    if (!p1_resource_table_procs_mod.isResourceTableReady(resource_table_procs)) return error.ResourceTableProcUnavailable;
    try requireResourceTableFeature(procs, self.core.device.?);

    const buffer = try resources.getOrCreateBuffer(
        self,
        DIAG_RESOURCE_TABLE_BUFFER_HANDLE,
        DIAG_RESOURCE_TABLE_BUFFER_SIZE,
        abi_base.WGPUBufferUsage_Storage | abi_base.WGPUBufferUsage_CopyDst,
    );
    var table_descriptor = p1_resource_table_procs_mod.initResourceTableDescriptor(DIAG_RESOURCE_TABLE_SIZE);
    const create_resource_table = resource_table_procs.device_create_resource_table orelse return error.ResourceTableProcUnavailable;
    const table = create_resource_table(self.core.device.?, &table_descriptor);
    if (table == null) return error.ResourceTableCreationFailed;
    defer if (resource_table_procs.resource_table_release) |release_resource_table| release_resource_table(table);
    defer if (resource_table_procs.resource_table_destroy) |destroy_resource_table| destroy_resource_table(table);

    const get_resource_table_size = resource_table_procs.resource_table_get_size orelse return error.ResourceTableProcUnavailable;
    if (get_resource_table_size(table) < DIAG_RESOURCE_TABLE_SIZE) return error.ResourceTableSizeMismatch;

    var binding_resource = p1_resource_table_procs_mod.initBindingResource(buffer, 0, 64);
    const insert_binding = resource_table_procs.resource_table_insert_binding orelse return error.ResourceTableProcUnavailable;
    const slot = insert_binding(table, &binding_resource);
    const update_binding = resource_table_procs.resource_table_update orelse return error.ResourceTableProcUnavailable;
    if (update_binding(table, slot, &binding_resource) != abi_base.WGPUStatus_Success) return error.ResourceTableUpdateFailed;
    const remove_binding = resource_table_procs.resource_table_remove_binding orelse return error.ResourceTableProcUnavailable;
    if (remove_binding(table, slot) != abi_base.WGPUStatus_Success) return error.ResourceTableRemoveFailed;
    _ = insert_binding(table, &binding_resource);

    const encoder = procs.wgpuDeviceCreateCommandEncoder(self.core.device.?, &abi_descriptor.WGPUCommandEncoderDescriptor{
        .nextInChain = null,
        .label = loader.emptyStringView(),
    });
    if (encoder == null) return error.CommandEncoderCreationFailed;
    defer procs.wgpuCommandEncoderRelease(encoder);

    const immediate_data = [_]u8{ 0, 0, 0, 0 };
    const compute_pass = procs.wgpuCommandEncoderBeginComputePass(
        encoder,
        &abi_descriptor.WGPUComputePassDescriptor{
            .nextInChain = null,
            .label = loader.emptyStringView(),
            .timestampWrites = null,
        },
    );
    if (compute_pass == null) return error.ComputePassCreationFailed;
    defer procs.wgpuComputePassEncoderRelease(compute_pass);
    p1_resource_table_procs_mod.setComputeResourceTable(resource_table_procs, compute_pass, table);
    p1_resource_table_procs_mod.setComputeImmediates(resource_table_procs, compute_pass, 0, immediate_data[0..].ptr, 0);
    procs.wgpuComputePassEncoderEnd(compute_pass);

    const target_texture = try getOrCreateDiagnosticTexture(self, normalizeDiagnosticFormat(target_format));
    const target_view = try createDiagnosticTextureView(procs, target_texture, normalizeDiagnosticFormat(target_format));
    defer procs.wgpuTextureViewRelease(target_view);

    var color_attachment = render_types_mod.RenderPassColorAttachment{
        .nextInChain = null,
        .view = target_view,
        .depthSlice = std.math.maxInt(u32),
        .resolveTarget = null,
        .loadOp = rc.RENDER_LOAD_OP_CLEAR,
        .storeOp = rc.RENDER_STORE_OP_STORE,
        .clearValue = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
    };
    const render_pass = render_api.command_encoder_begin_render_pass(
        encoder,
        &render_types_mod.RenderPassDescriptor{
            .nextInChain = null,
            .label = loader.emptyStringView(),
            .colorAttachmentCount = 1,
            .colorAttachments = @ptrCast(&color_attachment),
            .depthStencilAttachment = null,
            .occlusionQuerySet = null,
            .timestampWrites = null,
            .maxDrawCount = DIAG_MAX_DRAW_COUNT,
        },
    );
    if (render_pass == null) return error.RenderPassCreationFailed;
    defer render_api.render_pass_encoder_release(render_pass);
    p1_resource_table_procs_mod.setRenderPassResourceTable(resource_table_procs, render_pass, table);
    p1_resource_table_procs_mod.setRenderPassImmediates(resource_table_procs, render_pass, 0, immediate_data[0..].ptr, 0);
    render_api.render_pass_encoder_end(render_pass);

    const color_formats = [_]abi_base.WGPUTextureFormat{normalizeDiagnosticFormat(target_format)};
    const render_bundle_encoder = render_api.device_create_render_bundle_encoder(
        self.core.device.?,
        &render_types_mod.RenderBundleEncoderDescriptor{
            .nextInChain = null,
            .label = loader.stringView("doe.resource_table.bundle"),
            .colorFormatCount = 1,
            .colorFormats = color_formats[0..].ptr,
            .depthStencilFormat = abi_base.WGPUTextureFormat_Undefined,
            .sampleCount = 1,
            .depthReadOnly = abi_base.WGPU_FALSE,
            .stencilReadOnly = abi_base.WGPU_FALSE,
        },
    );
    if (render_bundle_encoder == null) return error.RenderBundleEncoderCreationFailed;
    defer render_api.render_bundle_encoder_release(render_bundle_encoder);
    p1_resource_table_procs_mod.setRenderBundleResourceTable(resource_table_procs, @ptrCast(render_bundle_encoder), table);
    p1_resource_table_procs_mod.setRenderBundleImmediates(resource_table_procs, @ptrCast(render_bundle_encoder), 0, immediate_data[0..].ptr, 0);
    const render_bundle = render_api.render_bundle_encoder_finish(
        render_bundle_encoder,
        &render_types_mod.RenderBundleDescriptor{
            .nextInChain = null,
            .label = loader.stringView("doe.resource_table.bundle"),
        },
    );
    if (render_bundle == null) return error.RenderBundleFinishFailed;
    render_api.render_bundle_release(render_bundle);

    const command_buffer = procs.wgpuCommandEncoderFinish(
        encoder,
        &abi_descriptor.WGPUCommandBufferDescriptor{
            .nextInChain = null,
            .label = loader.emptyStringView(),
        },
    );
    if (command_buffer == null) return error.CommandBufferFinishFailed;
    procs.wgpuCommandBufferRelease(command_buffer);
}

fn runResourceTableImmediatesDiagnosticsEmulated(self: anytype, target_format: abi_base.WGPUTextureFormat) !void {
    const procs = self.core.procs orelse return error.ProceduralNotReady;
    const render_api = render_api_mod.loadRenderApi(procs, self.core.dyn_lib) orelse return error.RenderApiUnavailable;

    const encoder = procs.wgpuDeviceCreateCommandEncoder(self.core.device.?, &abi_descriptor.WGPUCommandEncoderDescriptor{
        .nextInChain = null,
        .label = loader.emptyStringView(),
    });
    if (encoder == null) return error.CommandEncoderCreationFailed;
    defer procs.wgpuCommandEncoderRelease(encoder);

    const compute_pass = procs.wgpuCommandEncoderBeginComputePass(
        encoder,
        &abi_descriptor.WGPUComputePassDescriptor{
            .nextInChain = null,
            .label = loader.emptyStringView(),
            .timestampWrites = null,
        },
    );
    if (compute_pass == null) return error.ComputePassCreationFailed;
    defer procs.wgpuComputePassEncoderRelease(compute_pass);
    procs.wgpuComputePassEncoderEnd(compute_pass);

    const normalized_target_format = normalizeDiagnosticFormat(target_format);
    const target_texture = try getOrCreateDiagnosticTexture(self, normalized_target_format);
    const target_view = try createDiagnosticTextureView(procs, target_texture, normalized_target_format);
    defer procs.wgpuTextureViewRelease(target_view);

    var color_attachment = render_types_mod.RenderPassColorAttachment{
        .nextInChain = null,
        .view = target_view,
        .depthSlice = std.math.maxInt(u32),
        .resolveTarget = null,
        .loadOp = rc.RENDER_LOAD_OP_CLEAR,
        .storeOp = rc.RENDER_STORE_OP_STORE,
        .clearValue = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
    };
    const render_pass = render_api.command_encoder_begin_render_pass(
        encoder,
        &render_types_mod.RenderPassDescriptor{
            .nextInChain = null,
            .label = loader.emptyStringView(),
            .colorAttachmentCount = 1,
            .colorAttachments = @ptrCast(&color_attachment),
            .depthStencilAttachment = null,
            .occlusionQuerySet = null,
            .timestampWrites = null,
            .maxDrawCount = DIAG_MAX_DRAW_COUNT,
        },
    );
    if (render_pass == null) return error.RenderPassCreationFailed;
    defer render_api.render_pass_encoder_release(render_pass);
    render_api.render_pass_encoder_end(render_pass);

    const color_formats = [_]abi_base.WGPUTextureFormat{normalized_target_format};
    const render_bundle_encoder = render_api.device_create_render_bundle_encoder(
        self.core.device.?,
        &render_types_mod.RenderBundleEncoderDescriptor{
            .nextInChain = null,
            .label = loader.stringView("doe.resource_table.bundle.emulated"),
            .colorFormatCount = 1,
            .colorFormats = color_formats[0..].ptr,
            .depthStencilFormat = abi_base.WGPUTextureFormat_Undefined,
            .sampleCount = 1,
            .depthReadOnly = abi_base.WGPU_FALSE,
            .stencilReadOnly = abi_base.WGPU_FALSE,
        },
    );
    if (render_bundle_encoder == null) return error.RenderBundleEncoderCreationFailed;
    defer render_api.render_bundle_encoder_release(render_bundle_encoder);
    const render_bundle = render_api.render_bundle_encoder_finish(
        render_bundle_encoder,
        &render_types_mod.RenderBundleDescriptor{
            .nextInChain = null,
            .label = loader.stringView("doe.resource_table.bundle.emulated"),
        },
    );
    if (render_bundle == null) return error.RenderBundleFinishFailed;
    render_api.render_bundle_release(render_bundle);

    const command_buffer = procs.wgpuCommandEncoderFinish(
        encoder,
        &abi_descriptor.WGPUCommandBufferDescriptor{
            .nextInChain = null,
            .label = loader.emptyStringView(),
        },
    );
    if (command_buffer == null) return error.CommandBufferFinishFailed;
    procs.wgpuCommandBufferRelease(command_buffer);
}

fn runLifecycleRefcountDiagnostics(self: anytype, target_format: abi_base.WGPUTextureFormat) !void {
    const procs = self.core.procs orelse return error.ProceduralNotReady;
    const render_api = render_api_mod.loadRenderApi(procs, self.core.dyn_lib) orelse return error.RenderApiUnavailable;
    const lifecycle = self.getLifecycleProcs() orelse return error.LifecycleProcUnavailable;
    const resource_table_procs = self.getResourceTableProcs();

    touchAddRefAndRelease(abi_base.WGPUInstance, lifecycle.instance_add_ref, procs.wgpuInstanceRelease, self.core.instance);
    touchAddRefAndRelease(abi_base.WGPUAdapter, lifecycle.adapter_add_ref, procs.wgpuAdapterRelease, self.core.adapter);
    touchAddRefAndRelease(abi_base.WGPUDevice, lifecycle.device_add_ref, procs.wgpuDeviceRelease, self.core.device);
    touchAddRefAndRelease(abi_base.WGPUQueue, lifecycle.queue_add_ref, procs.wgpuQueueRelease, self.core.queue);

    const binding_resources = try render_resource_mod.getOrCreateRenderUniformBindingResources(self);
    touchAddRefAndRelease(abi_base.WGPUBindGroupLayout, lifecycle.bind_group_layout_add_ref, procs.wgpuBindGroupLayoutRelease, binding_resources.bind_group_layout);
    touchAddRefAndRelease(abi_base.WGPUBindGroup, lifecycle.bind_group_add_ref, procs.wgpuBindGroupRelease, binding_resources.bind_group);
    const texture_procs = texture_procs_mod.loadTextureProcs(self.core.dyn_lib) orelse return error.TextureProcUnavailable;
    touchAddRefAndRelease(abi_base.WGPUSampler, lifecycle.sampler_add_ref, texture_procs.sampler_release, self.full.render_sampler);

    const buffer = try resources.getOrCreateBuffer(
        self,
        DIAG_RESOURCE_TABLE_BUFFER_HANDLE,
        DIAG_RESOURCE_TABLE_BUFFER_SIZE,
        abi_base.WGPUBufferUsage_Storage | abi_base.WGPUBufferUsage_CopyDst,
    );
    touchAddRefAndRelease(abi_base.WGPUBuffer, lifecycle.buffer_add_ref, procs.wgpuBufferRelease, buffer);

    const texture = try getOrCreateDiagnosticTexture(self, normalizeDiagnosticFormat(target_format));
    touchAddRefAndRelease(abi_base.WGPUTexture, lifecycle.texture_add_ref, procs.wgpuTextureRelease, texture);
    const texture_view = try createDiagnosticTextureView(procs, texture, normalizeDiagnosticFormat(target_format));
    defer procs.wgpuTextureViewRelease(texture_view);
    touchAddRefAndRelease(abi_base.WGPUTextureView, lifecycle.texture_view_add_ref, procs.wgpuTextureViewRelease, texture_view);

    const shader_module = try resources.createShaderModule(self, DIAGNOSTIC_COMPUTE_SHADER_SOURCE);
    defer procs.wgpuShaderModuleRelease(shader_module);
    touchAddRefAndRelease(abi_base.WGPUShaderModule, lifecycle.shader_module_add_ref, procs.wgpuShaderModuleRelease, shader_module);

    const pipeline_layout = try resources.createPipelineLayout(self, &[_]abi_base.WGPUBindGroupLayout{binding_resources.bind_group_layout});
    defer procs.wgpuPipelineLayoutRelease(pipeline_layout);
    touchAddRefAndRelease(abi_base.WGPUPipelineLayout, lifecycle.pipeline_layout_add_ref, procs.wgpuPipelineLayoutRelease, pipeline_layout);

    const compute_pipeline = try resources.createComputePipeline(
        self,
        "doe.lifecycle.compute",
        shader_module,
        "main",
        pipeline_layout,
    );
    defer procs.wgpuComputePipelineRelease(compute_pipeline);
    touchAddRefAndRelease(abi_base.WGPUComputePipeline, lifecycle.compute_pipeline_add_ref, procs.wgpuComputePipelineRelease, compute_pipeline);

    const encoder = procs.wgpuDeviceCreateCommandEncoder(self.core.device.?, &abi_descriptor.WGPUCommandEncoderDescriptor{
        .nextInChain = null,
        .label = loader.emptyStringView(),
    });
    if (encoder == null) return error.CommandEncoderCreationFailed;
    defer procs.wgpuCommandEncoderRelease(encoder);
    touchAddRefAndRelease(abi_base.WGPUCommandEncoder, lifecycle.command_encoder_add_ref, procs.wgpuCommandEncoderRelease, encoder);

    const compute_pass = procs.wgpuCommandEncoderBeginComputePass(
        encoder,
        &abi_descriptor.WGPUComputePassDescriptor{
            .nextInChain = null,
            .label = loader.emptyStringView(),
            .timestampWrites = null,
        },
    );
    if (compute_pass == null) return error.ComputePassCreationFailed;
    defer procs.wgpuComputePassEncoderRelease(compute_pass);
    touchAddRefAndRelease(abi_base.WGPUComputePassEncoder, lifecycle.compute_pass_encoder_add_ref, procs.wgpuComputePassEncoderRelease, compute_pass);
    procs.wgpuComputePassEncoderSetPipeline(compute_pass, compute_pipeline);
    procs.wgpuComputePassEncoderEnd(compute_pass);

    var color_attachment = render_types_mod.RenderPassColorAttachment{
        .nextInChain = null,
        .view = texture_view,
        .depthSlice = std.math.maxInt(u32),
        .resolveTarget = null,
        .loadOp = rc.RENDER_LOAD_OP_CLEAR,
        .storeOp = rc.RENDER_STORE_OP_STORE,
        .clearValue = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
    };
    const render_pass = render_api.command_encoder_begin_render_pass(
        encoder,
        &render_types_mod.RenderPassDescriptor{
            .nextInChain = null,
            .label = loader.emptyStringView(),
            .colorAttachmentCount = 1,
            .colorAttachments = @ptrCast(&color_attachment),
            .depthStencilAttachment = null,
            .occlusionQuerySet = null,
            .timestampWrites = null,
            .maxDrawCount = DIAG_MAX_DRAW_COUNT,
        },
    );
    if (render_pass == null) return error.RenderPassCreationFailed;
    defer render_api.render_pass_encoder_release(render_pass);
    touchAddRefAndRelease(abi_base.WGPURenderPassEncoder, lifecycle.render_pass_encoder_add_ref, render_api.render_pass_encoder_release, render_pass);
    render_api.render_pass_encoder_end(render_pass);

    const command_buffer = procs.wgpuCommandEncoderFinish(
        encoder,
        &abi_descriptor.WGPUCommandBufferDescriptor{
            .nextInChain = null,
            .label = loader.emptyStringView(),
        },
    );
    if (command_buffer == null) return error.CommandBufferFinishFailed;
    defer procs.wgpuCommandBufferRelease(command_buffer);
    touchAddRefAndRelease(abi_base.WGPUCommandBuffer, lifecycle.command_buffer_add_ref, procs.wgpuCommandBufferRelease, command_buffer);

    const query_set = procs.wgpuDeviceCreateQuerySet(self.core.device.?, &abi_descriptor.WGPUQuerySetDescriptor{
        .nextInChain = null,
        .label = loader.emptyStringView(),
        .type = abi_base.WGPUQueryType_Timestamp,
        .count = 1,
    });
    if (query_set != null) {
        defer procs.wgpuQuerySetRelease(query_set);
        touchAddRefAndRelease(abi_base.WGPUQuerySet, lifecycle.query_set_add_ref, procs.wgpuQuerySetRelease, query_set);
        const p0_procs = p0_procs_mod.loadP0Procs(self.core.dyn_lib);
        p0_procs_mod.destroyQuerySet(p0_procs, query_set);
    }

    const render_pipeline = try createRenderPipelineForDiagnostics(self, normalizeDiagnosticFormat(target_format));
    defer render_api.render_pipeline_release(render_pipeline);
    touchAddRefAndOptionalRelease(abi_base.WGPURenderPipeline, lifecycle.render_pipeline_add_ref, render_api.render_pipeline_release, render_pipeline);

    if (resource_table_procs) |table_procs| {
        if (p1_resource_table_procs_mod.isResourceTableReady(table_procs)) {
            if (requireResourceTableFeature(procs, self.core.device.?)) |_| {
                var table_descriptor = p1_resource_table_procs_mod.initResourceTableDescriptor(DIAG_RESOURCE_TABLE_SIZE);
                const create_resource_table = table_procs.device_create_resource_table.?;
                const table = create_resource_table(self.core.device.?, &table_descriptor);
                if (table != null) {
                    defer if (table_procs.resource_table_release) |release_resource_table| release_resource_table(table);
                    defer if (table_procs.resource_table_destroy) |destroy_resource_table| destroy_resource_table(table);
                    touchAddRefAndOptionalRelease(
                        p1_resource_table_procs_mod.WGPUResourceTable,
                        lifecycle.resource_table_add_ref,
                        table_procs.resource_table_release,
                        table,
                    );
                }
            } else |_| {
                // ResourceTable object lifetime probes are skipped when feature is unavailable.
            }
        }
    }

    if (surface_procs_mod.loadSurfaceProcs(self.core.dyn_lib)) |surface_procs| {
        var surface_it = self.full.surfaces.valueIterator();
        if (surface_it.next()) |managed_surface| {
            const surface = managed_surface.*.surface;
            if (surface != null) {
                if (lifecycle.surface_add_ref) |add_ref| {
                    add_ref(@ptrCast(surface));
                    surface_procs.surface_release(surface);
                }
            }
        }
    }
}

fn createRenderPipelineForDiagnostics(self: anytype, target_format: abi_base.WGPUTextureFormat) !abi_base.WGPURenderPipeline {
    const procs = self.core.procs orelse return error.ProceduralNotReady;
    const render_api = render_api_mod.loadRenderApi(procs, self.core.dyn_lib) orelse return error.RenderApiUnavailable;
    const async_procs = async_procs_mod.loadAsyncProcs(self.core.dyn_lib) orelse return error.AsyncProcUnavailable;

    const shader_module = resources.createShaderModule(self, DIAGNOSTIC_SHADER_SOURCE) catch |err| {
        return switch (err) {
            error.KernelModuleCreationFailed => error.DiagnosticShaderModuleCreationFailed,
            else => error.DiagnosticShaderModuleCreationFailed,
        };
    };
    defer procs.wgpuShaderModuleRelease(shader_module);

    const compilation_state = async_procs_mod.requestShaderCompilationInfoAndWait(
        async_procs,
        self.core.instance.?,
        procs,
        shader_module,
    ) catch return error.DiagnosticCompilationInfoFailed;
    if (compilation_state.status != async_procs_mod.COMPILATION_INFO_STATUS_SUCCESS) {
        return error.DiagnosticCompilationInfoFailed;
    }

    async_procs_mod.pushErrorScope(async_procs, self.core.device.?, async_procs_mod.ERROR_FILTER_VALIDATION);
    async_procs_mod.pushErrorScope(async_procs, self.core.device.?, async_procs_mod.ERROR_FILTER_INTERNAL);
    async_procs_mod.pushErrorScope(async_procs, self.core.device.?, async_procs_mod.ERROR_FILTER_OUT_OF_MEMORY);

    var color_target = render_types_mod.RenderColorTargetState{
        .nextInChain = null,
        .format = normalizeDiagnosticFormat(target_format),
        .blend = null,
        .writeMask = rc.RENDER_COLOR_WRITE_MASK_ALL,
    };
    var fragment_state = render_types_mod.RenderFragmentState{
        .nextInChain = null,
        .module = shader_module,
        .entryPoint = loader.stringView("fs_main"),
        .constantCount = 0,
        .constants = null,
        .targetCount = 1,
        .targets = @ptrCast(&color_target),
    };
    const pipeline_desc = render_types_mod.RenderPipelineDescriptor{
        .nextInChain = null,
        .label = loader.stringView("doe.async_diagnostics"),
        .layout = null,
        .vertex = .{
            .nextInChain = null,
            .module = shader_module,
            .entryPoint = loader.stringView("vs_main"),
            .constantCount = 0,
            .constants = null,
            .bufferCount = 0,
            .buffers = null,
        },
        .primitive = .{
            .nextInChain = null,
            .topology = rc.RENDER_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
            .stripIndexFormat = 0,
            .frontFace = rc.RENDER_FRONT_FACE_CCW,
            .cullMode = rc.RENDER_CULL_MODE_NONE,
            .unclippedDepth = abi_base.WGPU_FALSE,
        },
        .depthStencil = null,
        .multisample = .{
            .nextInChain = null,
            .count = 1,
            .mask = rc.RENDER_MULTISAMPLE_MASK_ALL,
            .alphaToCoverageEnabled = abi_base.WGPU_FALSE,
        },
        .fragment = &fragment_state,
    };
    const pipeline = async_procs_mod.createRenderPipelineAsyncAndWait(
        async_procs,
        self.core.instance.?,
        procs,
        self.core.device.?,
        @ptrCast(&pipeline_desc),
    ) catch {
        inline for (0..3) |i| {
            _ = async_procs_mod.popErrorScopeAndWait(async_procs, self.core.instance.?, procs, self.core.device.?) catch |err|
                log.warn("popErrorScope[{d}] cleanup: {s}", .{ i, @errorName(err) });
        }
        return error.DiagnosticPipelineCreationFailed;
    };

    const out_of_memory_scope = async_procs_mod.popErrorScopeAndWait(async_procs, self.core.instance.?, procs, self.core.device.?) catch {
        render_api.render_pipeline_release(pipeline);
        return error.DiagnosticErrorScopeFailed;
    };
    const internal_scope = async_procs_mod.popErrorScopeAndWait(async_procs, self.core.instance.?, procs, self.core.device.?) catch {
        render_api.render_pipeline_release(pipeline);
        return error.DiagnosticErrorScopeFailed;
    };
    const validation_scope = async_procs_mod.popErrorScopeAndWait(async_procs, self.core.instance.?, procs, self.core.device.?) catch {
        render_api.render_pipeline_release(pipeline);
        return error.DiagnosticErrorScopeFailed;
    };
    const no_error = @as(u32, @intFromEnum(abi_descriptor.WGPUErrorType.noError));
    if (out_of_memory_scope.status != async_procs_mod.POP_ERROR_SCOPE_STATUS_SUCCESS or
        internal_scope.status != async_procs_mod.POP_ERROR_SCOPE_STATUS_SUCCESS or
        validation_scope.status != async_procs_mod.POP_ERROR_SCOPE_STATUS_SUCCESS or
        out_of_memory_scope.error_type != no_error or
        internal_scope.error_type != no_error or
        validation_scope.error_type != no_error)
    {
        render_api.render_pipeline_release(pipeline);
        return error.DiagnosticErrorScopeFailed;
    }
    return pipeline;
}

fn getOrCreateDiagnosticTexture(self: anytype, target_format: abi_base.WGPUTextureFormat) !abi_base.WGPUTexture {
    return resources.getOrCreateTexture(
        self,
        .{
            .handle = DIAG_RENDER_TARGET_HANDLE,
            .kind = .texture,
            .width = DIAG_RENDER_TARGET_WIDTH,
            .height = DIAG_RENDER_TARGET_HEIGHT,
            .depth_or_array_layers = 1,
            .format = target_format,
            .usage = abi_base.WGPUTextureUsage_RenderAttachment | abi_base.WGPUTextureUsage_CopyDst | abi_base.WGPUTextureUsage_CopySrc | abi_base.WGPUTextureUsage_TextureBinding,
            .dimension = model_gpu_types.WGPUTextureDimension_2D,
            .view_dimension = model_gpu_types.WGPUTextureViewDimension_2D,
            .mip_level = 0,
            .sample_count = 1,
            .aspect = model_gpu_types.WGPUTextureAspect_All,
            .bytes_per_row = 0,
            .rows_per_image = 0,
            .offset = 0,
        },
        abi_base.WGPUTextureUsage_RenderAttachment | abi_base.WGPUTextureUsage_CopyDst | abi_base.WGPUTextureUsage_CopySrc | abi_base.WGPUTextureUsage_TextureBinding,
    );
}

fn createDiagnosticTextureView(
    procs: abi_proc_aliases.Procs,
    texture: abi_base.WGPUTexture,
    target_format: abi_base.WGPUTextureFormat,
) !abi_base.WGPUTextureView {
    const view = procs.wgpuTextureCreateView(texture, &abi_descriptor.WGPUTextureViewDescriptor{
        .nextInChain = null,
        .label = loader.emptyStringView(),
        .format = target_format,
        .dimension = abi_base.WGPUTextureViewDimension_2D,
        .baseMipLevel = 0,
        .mipLevelCount = 1,
        .baseArrayLayer = 0,
        .arrayLayerCount = 1,
        .aspect = abi_base.WGPUTextureAspect_All,
        .usage = abi_base.WGPUTextureUsage_RenderAttachment,
    });
    if (view == null) return error.TextureViewCreationFailed;
    return view;
}

fn normalizeDiagnosticFormat(raw: abi_base.WGPUTextureFormat) abi_base.WGPUTextureFormat {
    const normalized = resources.normalizeTextureFormat(raw);
    return if (normalized == abi_base.WGPUTextureFormat_Undefined) model_gpu_types.WGPUTextureFormat_RGBA8Unorm else normalized;
}
fn requireResourceTableFeature(procs: abi_proc_aliases.Procs, device: abi_base.WGPUDevice) !void {
    const has_feature = procs.wgpuDeviceHasFeature orelse return error.ResourceTableFeatureUnavailable;
    if (has_feature(device, WGPUFeatureName_ChromiumExperimentalSamplingResourceTable) == abi_base.WGPU_FALSE) {
        return error.ResourceTableFeatureUnavailable;
    }
}

fn shouldEmulateUnavailableFeature(
    feature_policy: model_async_types.AsyncDiagnosticsFeaturePolicy,
    mode: model_async_types.AsyncDiagnosticsMode,
    err: anyerror,
) bool {
    if (feature_policy != .emulate_when_unavailable) return false;
    return switch (mode) {
        .resource_table_immediates => switch (err) {
            error.ResourceTableProcUnavailable,
            error.ResourceTableFeatureUnavailable,
            => true,
            else => false,
        },
        .pixel_local_storage => switch (err) {
            error.PixelLocalStorageFeatureUnavailable,
            error.PixelLocalStorageBarrierUnavailable,
            => true,
            else => false,
        },
        else => false,
    };
}

fn unsupportedDiagnosticsMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.RenderApiUnavailable => "render api surface unavailable",
        error.AsyncProcUnavailable => "async proc surface unavailable",
        error.ResourceTableProcUnavailable => "resource-table proc surface unavailable",
        error.ResourceTableFeatureUnavailable => "resource-table feature unavailable",
        error.LifecycleProcUnavailable => "lifecycle proc surface unavailable",
        error.PixelLocalStorageFeatureUnavailable => "pixel-local-storage feature unavailable",
        error.PixelLocalStorageBarrierUnavailable => "pixel-local-storage barrier proc unavailable",
        else => null,
    };
}

fn touchAddRefAndRelease(
    comptime T: type,
    add_ref: ?*const fn (T) callconv(.c) void,
    release: *const fn (T) callconv(.c) void,
    object: T,
) void {
    if (object == null) return;
    if (add_ref) |add_ref_fn| {
        add_ref_fn(object);
        release(object);
    }
}

fn touchAddRefAndOptionalRelease(
    comptime T: type,
    add_ref: ?*const fn (T) callconv(.c) void,
    release: ?*const fn (T) callconv(.c) void,
    object: T,
) void {
    if (object == null) return;
    if (add_ref) |add_ref_fn| {
        if (release) |release_fn| {
            add_ref_fn(object);
            release_fn(object);
        }
    }
}
