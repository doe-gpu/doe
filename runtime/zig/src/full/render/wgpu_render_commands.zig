const std = @import("std");
const log = std.log.scoped(.wgpu_render_commands);
const model_resource_types = @import("../../contracts/model/model_resource_types.zig");
const model_gpu_types = @import("../../contracts/model/model_texture_value_types.zig");
const model_render_types = @import("../../contracts/model/model_render_types.zig");
const proc_types = @import("../../core/abi/wgpu_proc_types.zig");
const abi_base = proc_types.base;
const abi_descriptor = proc_types.descriptor;
const abi_execution = @import("../../core/abi/wgpu_execution_types.zig");
const loader = @import("../../core/abi/wgpu_loader.zig");
const resources = @import("../../core/resource/wgpu_resources.zig");
const async_procs_mod = @import("../../core/abi/procs/wgpu_async_procs.zig");
const render_assets = @import("wgpu_render_assets.zig");
const render_api_mod = @import("wgpu_render_api.zig");
const render_indexing = @import("wgpu_render_indexing.zig");
const render_p0_mod = @import("wgpu_render_p0.zig");
const render_resource_mod = @import("wgpu_render_resources.zig");
const render_draw_loops = @import("wgpu_render_draw_loops.zig");
const render_types_mod = @import("wgpu_render_types.zig");
const render_temp_texture = @import("wgpu_render_temp_texture.zig");
const rc = @import("wgpu_render_constants.zig");
const DEFAULT_MAX_DRAW_COUNT: u64 = 50_000_000;

fn writeRepeatedIndirectArgs(
    comptime Args: type,
    allocator: std.mem.Allocator,
    write_buffer: anytype,
    encoder: abi_base.WGPUCommandEncoder,
    indirect_buffer: abi_base.WGPUBuffer,
    draw_count: u32,
    args: Args,
) bool {
    const count = @as(usize, @intCast(draw_count));
    const record_size = @sizeOf(Args);
    const total_bytes = std.math.mul(usize, count, record_size) catch return false;
    const bytes = allocator.alloc(u8, total_bytes) catch return false;
    defer allocator.free(bytes);

    const record = std.mem.asBytes(&args);
    var offset: usize = 0;
    while (offset < total_bytes) : (offset += record_size) {
        @memcpy(bytes[offset .. offset + record_size], record);
    }

    write_buffer(encoder, indirect_buffer, 0, bytes.ptr, @as(u64, @intCast(bytes.len)));
    return true;
}

pub fn executeRenderDraw(self: anytype, render: model_render_types.RenderDrawCommand, allow_multi_draw_indirect: bool) !abi_execution.NativeExecutionResult {
    if (render.draw_count == 0) {
        return .{ .status = .unsupported, .status_message = "render_draw draw_count must be > 0" };
    }
    if (render.vertex_count == 0) {
        return .{ .status = .unsupported, .status_message = "render_draw vertex_count must be > 0" };
    }
    if (render.instance_count == 0) {
        return .{ .status = .unsupported, .status_message = "render_draw instance_count must be > 0" };
    }
    if (render.target_width == 0 or render.target_height == 0) {
        return .{ .status = .unsupported, .status_message = "render_draw target dimensions must be > 0" };
    }
    if (render.index_count != null and render.index_count.? == 0) {
        return .{ .status = .unsupported, .status_message = "render_draw index_count must be > 0 when provided" };
    }

    const procs = self.core.procs orelse return error.ProceduralNotReady;
    const render_api = render_api_mod.loadRenderApi(procs, self.core.dyn_lib) orelse {
        return .{ .status = .unsupported, .status_message = "render_draw requires full render api surface" };
    };

    const setup_start_ns = std.time.nanoTimestamp();
    const target_resource = model_resource_types.CopyTextureResource{
        .handle = render.target_handle,
        .kind = .texture,
        .width = render.target_width,
        .height = render.target_height,
        .depth_or_array_layers = 1,
        .format = render.target_format,
        .usage = abi_base.WGPUTextureUsage_RenderAttachment | abi_base.WGPUTextureUsage_CopySrc | abi_base.WGPUTextureUsage_CopyDst,
        .dimension = model_gpu_types.WGPUTextureDimension_2D,
        .view_dimension = model_gpu_types.WGPUTextureViewDimension_2D,
        .mip_level = 0,
        .sample_count = 1,
        .aspect = model_gpu_types.WGPUTextureAspect_All,
        .bytes_per_row = 0,
        .rows_per_image = 0,
        .offset = 0,
    };
    const target_texture = try resources.getOrCreateTexture(
        self,
        target_resource,
        abi_base.WGPUTextureUsage_RenderAttachment | abi_base.WGPUTextureUsage_CopySrc | abi_base.WGPUTextureUsage_CopyDst,
    );
    const render_vertex_bytes = std.mem.sliceAsBytes(render_assets.RENDER_DRAW_VERTEX_DATA[0..]);
    const render_vertex_usage = abi_base.WGPUBufferUsage_Vertex | abi_base.WGPUBufferUsage_CopyDst;
    const render_vertex_bytes_u64 = @as(u64, @intCast(render_vertex_bytes.len));
    const should_upload_vertex_data = blk: {
        if (self.core.buffers.get(rc.RENDER_VERTEX_BUFFER_HANDLE)) |existing| {
            if (existing.size >= render_vertex_bytes_u64 and
                (existing.usage & render_vertex_usage) == render_vertex_usage)
            {
                break :blk false;
            }
        }
        break :blk true;
    };
    const render_vertex_buffer = try resources.getOrCreateBuffer(
        self,
        rc.RENDER_VERTEX_BUFFER_HANDLE,
        render_vertex_bytes_u64,
        render_vertex_usage,
    );
    if (should_upload_vertex_data) {
        procs.wgpuQueueWriteBuffer(
            self.core.queue.?,
            render_vertex_buffer,
            0,
            render_vertex_bytes.ptr,
            render_vertex_bytes.len,
        );
    }
    const prepared_index = render_indexing.prepareIndexBuffer(self, render) catch |err| {
        return .{
            .status = if (err == error.InvalidIndexedDrawData) .unsupported else .@"error",
            .status_message = switch (err) {
                error.InvalidIndexedDrawData => "render_draw indexed mode requires valid index_data and bounds",
                else => "render_draw index buffer setup failed",
            },
        };
    };
    const indexed_draw = prepared_index != null;
    const viewport_width = render.viewport_width orelse @as(f32, @floatFromInt(render.target_width));
    const viewport_height = render.viewport_height orelse @as(f32, @floatFromInt(render.target_height));
    if (viewport_width <= 0 or viewport_height <= 0) {
        return .{ .status = .unsupported, .status_message = "render_draw viewport dimensions must be > 0" };
    }
    const scissor_width = render.scissor_width orelse render.target_width;
    const scissor_height = render.scissor_height orelse render.target_height;
    if (scissor_width == 0 or scissor_height == 0) {
        return .{ .status = .unsupported, .status_message = "render_draw scissor dimensions must be > 0" };
    }
    const requested_dynamic_offsets = render.bind_group_dynamic_offsets orelse &[_]u32{};
    if (requested_dynamic_offsets.len > 1) {
        return .{ .status = .unsupported, .status_message = "render_draw supports exactly one dynamic bind-group offset" };
    }
    var dynamic_offsets = [_]u32{0};
    if (requested_dynamic_offsets.len == 1) {
        dynamic_offsets[0] = requested_dynamic_offsets[0];
    }
    if (dynamic_offsets[0] % @as(u32, @intCast(rc.RENDER_UNIFORM_DYNAMIC_STRIDE_BYTES)) != 0) {
        return .{ .status = .unsupported, .status_message = "render_draw dynamic offset must align to uniform stride" };
    }
    if (@as(u64, dynamic_offsets[0]) + rc.RENDER_UNIFORM_MIN_BINDING_SIZE_BYTES > rc.RENDER_UNIFORM_TOTAL_BYTES) {
        return .{ .status = .unsupported, .status_message = "render_draw dynamic offset exceeds uniform buffer bounds" };
    }

    const normalized_target_format = resources.normalizeTextureFormat(render.target_format);
    const target_format = if (normalized_target_format == abi_base.WGPUTextureFormat_Undefined)
        model_gpu_types.WGPUTextureFormat_RGBA8Unorm
    else
        normalized_target_format;
    const depth_handle = render.target_handle ^ rc.RENDER_DEPTH_ATTACHMENT_HANDLE_MASK;
    const depth_resource = model_resource_types.CopyTextureResource{
        .handle = depth_handle,
        .kind = .texture,
        .width = render.target_width,
        .height = render.target_height,
        .depth_or_array_layers = 1,
        .format = rc.RENDER_DEPTH_STENCIL_FORMAT,
        .usage = abi_base.WGPUTextureUsage_RenderAttachment,
        .dimension = model_gpu_types.WGPUTextureDimension_2D,
        .view_dimension = model_gpu_types.WGPUTextureViewDimension_2D,
        .mip_level = 0,
        .sample_count = 1,
        .aspect = model_gpu_types.WGPUTextureAspect_All,
        .bytes_per_row = 0,
        .rows_per_image = 0,
        .offset = 0,
    };
    const depth_texture = try resources.getOrCreateTexture(
        self,
        depth_resource,
        abi_base.WGPUTextureUsage_RenderAttachment,
    );
    const target_view = render_resource_mod.getOrCreateCachedRenderTextureView(
        self,
        &self.full.render_target_view_cache,
        render.target_handle,
        target_texture,
        render.target_width,
        render.target_height,
        target_format,
        abi_base.WGPUTextureUsage_RenderAttachment,
    ) catch |err| {
        return .{
            .status = .@"error",
            .status_message = switch (err) {
                error.ProceduralNotReady => "backend not ready",
                error.TextureViewCreationFailed => "render_draw texture view creation failed",
                error.TextureViewCacheInsertFailed => "render_draw texture view cache insert failed",
            },
        };
    };
    const depth_view = render_resource_mod.getOrCreateCachedRenderTextureView(
        self,
        &self.full.render_depth_view_cache,
        depth_handle,
        depth_texture,
        render.target_width,
        render.target_height,
        rc.RENDER_DEPTH_STENCIL_FORMAT,
        abi_base.WGPUTextureUsage_RenderAttachment,
    ) catch |err| {
        return .{
            .status = .@"error",
            .status_message = switch (err) {
                error.ProceduralNotReady => "backend not ready",
                error.TextureViewCreationFailed => "render_draw depth view creation failed",
                error.TextureViewCacheInsertFailed => "render_draw depth view cache insert failed",
            },
        };
    };
    const render_uniform_resources = render_resource_mod.getOrCreateRenderUniformBindingResources(self) catch |err| {
        return .{
            .status = .@"error",
            .status_message = switch (err) {
                error.ProceduralNotReady => "backend not ready",
                error.BufferAllocationFailed => "render_draw uniform buffer allocation failed",
                error.BindGroupLayoutCreationFailed => "render_draw uniform bind group layout creation failed",
                error.BindGroupCreationFailed => "render_draw uniform bind group creation failed",
                error.TextureProcUnavailable => "render_draw texture proc surface unavailable",
                error.SamplerCreationFailed => "render_draw sampler creation failed",
                else => "render_draw uniform setup failed",
            },
        };
    };

    const render_pipeline = if (self.full.render_pipeline_cache.get(target_format)) |cached|
        cached.pipeline
    else blk: {
        const shader_module = resources.createShaderModule(self, render_assets.RENDER_DRAW_SHADER_SOURCE) catch |err| {
            return .{
                .status = .@"error",
                .status_message = switch (err) {
                    error.KernelModuleCreationFailed => "render_draw shader module creation failed",
                    error.ProceduralNotReady => "backend not ready",
                },
            };
        };

        var color_target = rc.RenderColorTargetState{
            .nextInChain = null,
            .format = target_format,
            .blend = null,
            .writeMask = rc.RENDER_COLOR_WRITE_MASK_ALL,
        };
        const vertex_attribute = rc.RenderVertexAttribute{
            .nextInChain = null,
            .format = rc.RENDER_VERTEX_FORMAT_FLOAT32X4,
            .offset = 0,
            .shaderLocation = 0,
        };
        const vertex_buffer_layout = rc.RenderVertexBufferLayout{
            .nextInChain = null,
            .stepMode = rc.RENDER_VERTEX_STEP_MODE_VERTEX,
            .arrayStride = rc.RENDER_VERTEX_STRIDE_BYTES,
            .attributeCount = 1,
            .attributes = @ptrCast(&vertex_attribute),
        };
        var fragment_state = rc.RenderFragmentState{
            .nextInChain = null,
            .module = shader_module,
            .entryPoint = loader.stringView("fs_main"),
            .constantCount = 0,
            .constants = null,
            .targetCount = 1,
            .targets = @ptrCast(&color_target),
        };
        const stencil_face_state = rc.RenderStencilFaceState{
            .compare = rc.RENDER_COMPARE_FUNCTION_ALWAYS,
            .failOp = rc.RENDER_STENCIL_OPERATION_KEEP,
            .depthFailOp = rc.RENDER_STENCIL_OPERATION_KEEP,
            .passOp = rc.RENDER_STENCIL_OPERATION_KEEP,
        };
        const depth_stencil_state = rc.RenderDepthStencilState{
            .nextInChain = null,
            .format = rc.RENDER_DEPTH_STENCIL_FORMAT,
            .depthWriteEnabled = rc.RENDER_OPTIONAL_BOOL_FALSE,
            .depthCompare = rc.RENDER_COMPARE_FUNCTION_ALWAYS,
            .stencilFront = stencil_face_state,
            .stencilBack = stencil_face_state,
            .stencilReadMask = rc.RENDER_STENCIL_MASK_DEFAULT,
            .stencilWriteMask = rc.RENDER_STENCIL_MASK_DEFAULT,
            .depthBias = 0,
            .depthBiasSlopeScale = 0,
            .depthBiasClamp = 0,
        };
        const render_pipeline_layout = resources.createPipelineLayout(
            self,
            &[_]abi_base.WGPUBindGroupLayout{render_uniform_resources.bind_group_layout},
        ) catch {
            procs.wgpuShaderModuleRelease(shader_module);
            return .{ .status = .@"error", .status_message = "render_draw pipeline layout creation failed" };
        };
        defer procs.wgpuPipelineLayoutRelease(render_pipeline_layout);
        const async_procs = async_procs_mod.loadAsyncProcs(self.core.dyn_lib) orelse {
            procs.wgpuShaderModuleRelease(shader_module);
            return .{ .status = .unsupported, .status_message = "render_draw requires async diagnostics api surface" };
        };

        const compilation_state = async_procs_mod.requestShaderCompilationInfoAndWait(
            async_procs,
            self.core.instance.?,
            procs,
            shader_module,
        ) catch {
            procs.wgpuShaderModuleRelease(shader_module);
            return .{ .status = .@"error", .status_message = "render_draw shader compilation info request failed" };
        };
        if (compilation_state.status != async_procs_mod.COMPILATION_INFO_STATUS_SUCCESS) {
            procs.wgpuShaderModuleRelease(shader_module);
            return .{ .status = .@"error", .status_message = "render_draw shader compilation info status not successful" };
        }

        async_procs_mod.pushErrorScope(async_procs, self.core.device.?, async_procs_mod.ERROR_FILTER_VALIDATION);
        async_procs_mod.pushErrorScope(async_procs, self.core.device.?, async_procs_mod.ERROR_FILTER_INTERNAL);
        async_procs_mod.pushErrorScope(async_procs, self.core.device.?, async_procs_mod.ERROR_FILTER_OUT_OF_MEMORY);

        const pipeline_desc = rc.RenderPipelineDescriptor{
            .nextInChain = null,
            .label = loader.stringView("doe.render_draw"),
            .layout = render_pipeline_layout,
            .vertex = .{
                .nextInChain = null,
                .module = shader_module,
                .entryPoint = loader.stringView("vs_main"),
                .constantCount = 0,
                .constants = null,
                .bufferCount = 1,
                .buffers = @ptrCast(&vertex_buffer_layout),
            },
            .primitive = .{
                .nextInChain = null,
                .topology = rc.RENDER_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
                .stripIndexFormat = 0,
                .frontFace = rc.RENDER_FRONT_FACE_CCW,
                .cullMode = rc.RENDER_CULL_MODE_NONE,
                .unclippedDepth = abi_base.WGPU_FALSE,
            },
            .depthStencil = &depth_stencil_state,
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
            _ = async_procs_mod.popErrorScopeAndWait(async_procs, self.core.instance.?, procs, self.core.device.?) catch |err| {
                log.warn("popErrorScope[0] cleanup: {s}", .{@errorName(err)});
            };
            _ = async_procs_mod.popErrorScopeAndWait(async_procs, self.core.instance.?, procs, self.core.device.?) catch |err| {
                log.warn("popErrorScope[1] cleanup: {s}", .{@errorName(err)});
            };
            _ = async_procs_mod.popErrorScopeAndWait(async_procs, self.core.instance.?, procs, self.core.device.?) catch |err| {
                log.warn("popErrorScope[2] cleanup: {s}", .{@errorName(err)});
            };
            procs.wgpuShaderModuleRelease(shader_module);
            return .{ .status = .@"error", .status_message = "render_draw async pipeline creation failed" };
        };

        const out_of_memory_scope = async_procs_mod.popErrorScopeAndWait(async_procs, self.core.instance.?, procs, self.core.device.?) catch {
            render_api.render_pipeline_release(pipeline);
            procs.wgpuShaderModuleRelease(shader_module);
            return .{ .status = .@"error", .status_message = "render_draw out-of-memory scope pop failed" };
        };
        const internal_scope = async_procs_mod.popErrorScopeAndWait(async_procs, self.core.instance.?, procs, self.core.device.?) catch {
            render_api.render_pipeline_release(pipeline);
            procs.wgpuShaderModuleRelease(shader_module);
            return .{ .status = .@"error", .status_message = "render_draw internal scope pop failed" };
        };
        const validation_scope = async_procs_mod.popErrorScopeAndWait(async_procs, self.core.instance.?, procs, self.core.device.?) catch {
            render_api.render_pipeline_release(pipeline);
            procs.wgpuShaderModuleRelease(shader_module);
            return .{ .status = .@"error", .status_message = "render_draw validation scope pop failed" };
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
            procs.wgpuShaderModuleRelease(shader_module);
            return .{ .status = .@"error", .status_message = "render_draw error-scope validation failed" };
        }

        self.full.render_pipeline_cache.put(target_format, .{
            .shader_module = shader_module,
            .pipeline = pipeline,
        }) catch {
            render_api.render_pipeline_release(pipeline);
            procs.wgpuShaderModuleRelease(shader_module);
            return .{ .status = .@"error", .status_message = "render_draw pipeline cache insert failed" };
        };
        break :blk pipeline;
    };
    const p0_state = render_p0_mod.prepare(
        self,
        procs,
        render_api,
        indexed_draw,
        allow_multi_draw_indirect,
        render.draw_count,
        rc.RENDER_MULTI_DRAW_INDIRECT_BUFFER_HANDLE,
    );
    defer render_p0_mod.deinit(p0_state, procs);
    const command_encoder_write_buffer = p0_state.command_encoder_write_buffer;
    const occlusion_query_set = p0_state.occlusion_query_set;
    const render_indirect_buffer = p0_state.indirect_buffer;
    const setup_end_ns = std.time.nanoTimestamp();
    // Treat render-bundle recording as encode work so render-domain strict
    // comparability can use encode-only timing semantics consistently.
    const encode_start_ns = std.time.nanoTimestamp();

    var prepared_render_bundle: render_api_mod.RenderBundle = null;
    defer if (prepared_render_bundle != null) {
        render_api.render_bundle_release(prepared_render_bundle);
    };
    if (render.encode_mode != .render_pass) {
        const bundle_color_formats = [_]abi_base.WGPUTextureFormat{target_format};
        const render_bundle_encoder = render_api.device_create_render_bundle_encoder(
            self.core.device.?,
            &rc.RenderBundleEncoderDescriptor{
                .nextInChain = null,
                .label = loader.stringView("doe.render_bundle_encoder"),
                .colorFormatCount = 1,
                .colorFormats = bundle_color_formats[0..].ptr,
                .depthStencilFormat = rc.RENDER_DEPTH_STENCIL_FORMAT,
                .sampleCount = 1,
                .depthReadOnly = abi_base.WGPU_FALSE,
                .stencilReadOnly = abi_base.WGPU_FALSE,
            },
        );
        if (render_bundle_encoder == null) {
            return .{ .status = .@"error", .status_message = "render_draw bundle encoder creation failed" };
        }
        defer render_api.render_bundle_encoder_release(render_bundle_encoder);

        if (render.pipeline_mode == .static) {
            render_api.render_bundle_encoder_set_pipeline(render_bundle_encoder, render_pipeline);
        }
        render_api.render_bundle_encoder_set_vertex_buffer(
            render_bundle_encoder,
            0,
            render_vertex_buffer,
            0,
            abi_base.WGPU_WHOLE_SIZE,
        );
        if (indexed_draw) {
            render_api.render_bundle_encoder_set_index_buffer(
                render_bundle_encoder,
                prepared_index.?.buffer,
                prepared_index.?.format,
                0,
                abi_base.WGPU_WHOLE_SIZE,
            );
        }
        if (render.bind_group_mode == .no_change) {
            render_api.render_bundle_encoder_set_bind_group(render_bundle_encoder, rc.RENDER_UNIFORM_BINDING_INDEX, render_uniform_resources.bind_group, dynamic_offsets.len, dynamic_offsets[0..].ptr);
        }

        if (indexed_draw) {
            render_draw_loops.encode_render_bundle_draw_indexed(
                render_api,
                render_bundle_encoder,
                render,
                render_pipeline,
                render_uniform_resources,
                dynamic_offsets[0..],
                render.index_count.?,
            );
        } else {
            render_draw_loops.encode_render_bundle_draw_nonindexed(
                render_api,
                render_bundle_encoder,
                render,
                render_pipeline,
                render_uniform_resources,
                dynamic_offsets[0..],
            );
        }

        prepared_render_bundle = render_api.render_bundle_encoder_finish(
            render_bundle_encoder,
            &rc.RenderBundleDescriptor{
                .nextInChain = null,
                .label = loader.stringView("doe.render_bundle"),
            },
        );
        if (prepared_render_bundle == null) {
            return .{ .status = .@"error", .status_message = "render_draw bundle finish failed" };
        }
    }
    const encoder = procs.wgpuDeviceCreateCommandEncoder(self.core.device.?, &abi_descriptor.WGPUCommandEncoderDescriptor{
        .nextInChain = null,
        .label = loader.emptyStringView(),
    });
    if (encoder == null) {
        return .{ .status = .@"error", .status_message = "deviceCreateCommandEncoder returned null" };
    }
    defer procs.wgpuCommandEncoderRelease(encoder);
    var use_multi_draw_indexed = render.encode_mode == .render_pass and
        indexed_draw and
        render.pipeline_mode == .static and
        render.bind_group_mode == .no_change and
        render_indirect_buffer != null and
        command_encoder_write_buffer != null and
        render_api.render_pass_encoder_multi_draw_indexed_indirect != null;
    var use_multi_draw = render.encode_mode == .render_pass and
        !indexed_draw and
        render.pipeline_mode == .static and
        render.bind_group_mode == .no_change and
        render_indirect_buffer != null and
        command_encoder_write_buffer != null and
        render_api.render_pass_encoder_multi_draw_indirect != null;
    if (use_multi_draw_indexed) {
        const draw_args = render_types_mod.RenderDrawIndexedIndirectArgs{
            .index_count = render.index_count.?,
            .instance_count = render.instance_count,
            .first_index = render.first_index,
            .base_vertex = render.base_vertex,
            .first_instance = render.first_instance,
        };
        use_multi_draw_indexed = writeRepeatedIndirectArgs(
            render_types_mod.RenderDrawIndexedIndirectArgs,
            self.core.allocator,
            command_encoder_write_buffer.?,
            encoder,
            render_indirect_buffer,
            render.draw_count,
            draw_args,
        );
    } else if (use_multi_draw) {
        const draw_args = render_types_mod.RenderDrawIndirectArgs{
            .vertex_count = render.vertex_count,
            .instance_count = render.instance_count,
            .first_vertex = render.first_vertex,
            .first_instance = render.first_instance,
        };
        use_multi_draw = writeRepeatedIndirectArgs(
            render_types_mod.RenderDrawIndirectArgs,
            self.core.allocator,
            command_encoder_write_buffer.?,
            encoder,
            render_indirect_buffer,
            render.draw_count,
            draw_args,
        );
    }

    const temp_result = render_temp_texture.setupTempRenderTexture(
        self,
        render,
        target_format,
        target_resource,
    ) catch {
        return .{ .status = .@"error", .status_message = "render_draw temp render texture view creation failed" };
    };

    const effective_view = if (temp_result.view) |tv| tv else target_view;

    var color_attachment = rc.RenderPassColorAttachment{
        .nextInChain = null,
        .view = effective_view,
        .depthSlice = rc.RENDER_TARGET_DEPTH_SLICE_UNDEFINED,
        .resolveTarget = null,
        .loadOp = rc.RENDER_LOAD_OP_CLEAR,
        .storeOp = rc.RENDER_STORE_OP_STORE,
        .clearValue = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
    };
    const depth_stencil_attachment = rc.RenderPassDepthStencilAttachment{
        .nextInChain = null,
        .view = depth_view,
        .depthLoadOp = rc.RENDER_LOAD_OP_CLEAR,
        .depthStoreOp = rc.RENDER_STORE_OP_STORE,
        .depthClearValue = rc.RENDER_DEPTH_STENCIL_CLEAR_VALUE,
        .depthReadOnly = abi_base.WGPU_FALSE,
        .stencilLoadOp = rc.RENDER_LOAD_OP_CLEAR,
        .stencilStoreOp = rc.RENDER_STORE_OP_STORE,
        .stencilClearValue = rc.RENDER_STENCIL_CLEAR_VALUE,
        .stencilReadOnly = abi_base.WGPU_FALSE,
    };
    const render_pass = render_api.command_encoder_begin_render_pass(encoder, &rc.RenderPassDescriptor{
        .nextInChain = null,
        .label = loader.emptyStringView(),
        .colorAttachmentCount = 1,
        .colorAttachments = @ptrCast(&color_attachment),
        .depthStencilAttachment = &depth_stencil_attachment,
        .occlusionQuerySet = occlusion_query_set,
        .timestampWrites = null,
        .maxDrawCount = DEFAULT_MAX_DRAW_COUNT,
    });
    if (render_pass == null) {
        return .{ .status = .@"error", .status_message = "render_draw begin render pass failed" };
    }
    defer render_api.render_pass_encoder_release(render_pass);
    render_p0_mod.beginPass(p0_state, render_api, render_pass);

    render_api.render_pass_encoder_set_viewport(
        render_pass,
        render.viewport_x,
        render.viewport_y,
        viewport_width,
        viewport_height,
        render.viewport_min_depth,
        render.viewport_max_depth,
    );
    render_api.render_pass_encoder_set_scissor_rect(
        render_pass,
        render.scissor_x,
        render.scissor_y,
        scissor_width,
        scissor_height,
    );
    // WebGPU render pass initial state is blend=(0,0,0,0), stencil=0.
    // Skip these calls when at default values to avoid redundant Metal API overhead.
    const blend_is_default = render.blend_constant[0] == 0 and render.blend_constant[1] == 0 and
        render.blend_constant[2] == 0 and render.blend_constant[3] == 0;
    if (!blend_is_default) {
        const blend_constant = rc.RenderColor{
            .r = render.blend_constant[0],
            .g = render.blend_constant[1],
            .b = render.blend_constant[2],
            .a = render.blend_constant[3],
        };
        render_api.render_pass_encoder_set_blend_constant(render_pass, &blend_constant);
    }
    if (render.stencil_reference != 0) {
        render_api.render_pass_encoder_set_stencil_reference(render_pass, render.stencil_reference);
    }
    render_api.render_pass_encoder_set_vertex_buffer(
        render_pass,
        0,
        render_vertex_buffer,
        0,
        abi_base.WGPU_WHOLE_SIZE,
    );
    if (indexed_draw) {
        render_api.render_pass_encoder_set_index_buffer(
            render_pass,
            prepared_index.?.buffer,
            prepared_index.?.format,
            0,
            abi_base.WGPU_WHOLE_SIZE,
        );
    }
    if (render.encode_mode == .render_pass and render.pipeline_mode == .static) {
        render_api.render_pass_encoder_set_pipeline(render_pass, render_pipeline);
    }
    if (render.encode_mode == .render_pass and render.bind_group_mode == .no_change) {
        render_api.render_pass_encoder_set_bind_group(render_pass, rc.RENDER_UNIFORM_BINDING_INDEX, render_uniform_resources.bind_group, dynamic_offsets.len, dynamic_offsets[0..].ptr);
    }

    if (render.encode_mode == .render_pass) {
        if (indexed_draw) {
            if (use_multi_draw_indexed) {
                render_api.render_pass_encoder_multi_draw_indexed_indirect.?(
                    render_pass,
                    render_indirect_buffer,
                    0,
                    render.draw_count,
                    null,
                    0,
                );
            } else {
                render_draw_loops.encode_render_pass_draw_indexed(
                    render_api,
                    render_pass,
                    render,
                    render_pipeline,
                    render_uniform_resources,
                    dynamic_offsets[0..],
                    render.index_count.?,
                );
            }
        } else {
            if (use_multi_draw) {
                render_api.render_pass_encoder_multi_draw_indirect.?(
                    render_pass,
                    render_indirect_buffer,
                    0,
                    render.draw_count,
                    null,
                    0,
                );
            } else {
                render_draw_loops.encode_render_pass_draw_nonindexed(
                    render_api,
                    render_pass,
                    render,
                    render_pipeline,
                    render_uniform_resources,
                    dynamic_offsets[0..],
                );
            }
        }
    } else {
        if (prepared_render_bundle == null) {
            return .{ .status = .@"error", .status_message = "render_draw bundle setup missing prepared bundle" };
        }
        var bundles = [_]render_api_mod.RenderBundle{prepared_render_bundle};
        render_api.render_pass_encoder_execute_bundles(render_pass, bundles.len, bundles[0..].ptr);
    }
    render_p0_mod.endPass(p0_state, render_api, render_pass);
    render_api.render_pass_encoder_end(render_pass);

    if (temp_result.needs_copy_back) {
        try render_temp_texture.copyBackTempRenderTexture(
            self,
            procs,
            encoder,
            render,
            target_texture,
            target_resource,
        );
    }

    const command_buffer = procs.wgpuCommandEncoderFinish(encoder, &abi_descriptor.WGPUCommandBufferDescriptor{
        .nextInChain = null,
        .label = loader.emptyStringView(),
    });
    if (command_buffer == null) {
        return .{ .status = .@"error", .status_message = "commandEncoderFinish returned null" };
    }
    defer procs.wgpuCommandBufferRelease(command_buffer);
    const encode_end_ns = std.time.nanoTimestamp();

    var commands = [_]abi_base.WGPUCommandBuffer{command_buffer};
    const submit_wait_ns = try self.submitCommandBuffers(commands[0..]);

    const setup_ns = if (setup_end_ns > setup_start_ns)
        @as(u64, @intCast(setup_end_ns - setup_start_ns))
    else
        0;
    const encode_ns = if (encode_end_ns > encode_start_ns)
        @as(u64, @intCast(encode_end_ns - encode_start_ns))
    else
        0;

    return .{
        .status = .ok,
        .status_message = "render_draw command submitted",
        .setup_ns = setup_ns,
        .encode_ns = encode_ns,
        .submit_wait_ns = submit_wait_ns,
        .dispatch_count = render.draw_count,
        .gpu_timestamp_ns = 0,
    };
}
