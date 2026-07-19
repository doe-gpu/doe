const model_commands = @import("../../contracts/model/model_commands.zig");
const execution = @import("../../runtime/execution.zig");

const model = struct {
    pub const Command = model_commands.Command;
    pub const command_kind = model_commands.command_kind;
    pub const command_kind_name = model_commands.command_kind_name;
};

fn printJsonIntArray(stdout: anytype, values: anytype) !void {
    try stdout.writeByte('[');
    for (values, 0..) |value, idx| {
        if (idx != 0) try stdout.writeByte(',');
        try stdout.print("{}", .{value});
    }
    try stdout.writeByte(']');
}

pub fn commandName(command: model.Command) []const u8 {
    return model.command_kind_name(model.command_kind(command));
}

pub fn commandKernel(command: model.Command) ?[]const u8 {
    return switch (command) {
        .kernel_dispatch => |dispatch| dispatch.kernel,
        else => null,
    };
}

pub fn printNormalizedCommand(stdout: anytype, seq: usize, command: model.Command) !void {
    switch (command) {
        .upload => |upload| {
            try stdout.writeAll("{\"seq\":");
            try stdout.print("{}", .{seq});
            try stdout.writeAll(",\"kind\":\"upload\",\"bytes\":");
            try stdout.print("{}", .{upload.bytes});
            try stdout.writeAll(",\"alignBytes\":");
            try stdout.print("{}", .{upload.align_bytes});
            try stdout.writeAll("}\n");
        },
        .buffer_write => |buffer_write| {
            try stdout.writeAll("{\"seq\":");
            try stdout.print("{}", .{seq});
            try stdout.writeAll(",\"kind\":\"buffer_write\",\"handle\":");
            try stdout.print("{}", .{buffer_write.handle});
            try stdout.writeAll(",\"offset\":");
            try stdout.print("{}", .{buffer_write.offset});
            try stdout.writeAll(",\"bufferSize\":");
            try stdout.print("{}", .{buffer_write.buffer_size});
            try stdout.writeAll(",\"data\":");
            try stdout.print("{any}", .{buffer_write.data});
            try stdout.writeAll("}\n");
        },
        .copy_buffer_to_texture => |copy| {
            try stdout.writeAll("{\"seq\":");
            try stdout.print("{}", .{seq});
            try stdout.writeAll(",\"kind\":\"copy_buffer_to_texture\",\"direction\":\"");
            try stdout.writeAll(@tagName(copy.direction));
            try stdout.writeAll("\",\"srcHandle\":");
            try stdout.print("{}", .{copy.src.handle});
            try stdout.writeAll(",\"dstHandle\":");
            try stdout.print("{}", .{copy.dst.handle});
            try stdout.writeAll(",\"bytes\":");
            try stdout.print("{}", .{copy.bytes});
            try stdout.writeAll(",\"usesTemporaryBuffer\":");
            try stdout.print("{}", .{copy.uses_temporary_buffer});
            try stdout.writeAll(",\"temporaryBufferAlignment\":");
            try stdout.print("{}", .{copy.temporary_buffer_alignment});
            try stdout.writeAll("}\n");
        },
        .dispatch, .dispatch_indirect => |dispatch_cmd| {
            const dispatch_kind = model.command_kind_name(model.command_kind(command));
            try stdout.writeAll("{\"seq\":");
            try stdout.print("{}", .{seq});
            try stdout.writeAll(",\"kind\":\"");
            try stdout.writeAll(dispatch_kind);
            try stdout.writeAll("\",\"x\":");
            try stdout.print("{}", .{dispatch_cmd.x});
            try stdout.writeAll(",\"y\":");
            try stdout.print("{}", .{dispatch_cmd.y});
            try stdout.writeAll(",\"z\":");
            try stdout.print("{}", .{dispatch_cmd.z});
            try stdout.writeAll("}\n");
        },
        .kernel_dispatch => |kernel_cmd| {
            try stdout.writeAll("{\"seq\":");
            try stdout.print("{}", .{seq});
            try stdout.writeAll(",\"kind\":\"kernel_dispatch\",\"kernel\":\"");
            try stdout.print("{s}\",\"x\":", .{kernel_cmd.kernel});
            try stdout.print("{}", .{kernel_cmd.x});
            try stdout.writeAll(",\"y\":");
            try stdout.print("{}", .{kernel_cmd.y});
            try stdout.writeAll(",\"z\":");
            try stdout.print("{}", .{kernel_cmd.z});
            try stdout.writeAll(",\"repeat\":");
            try stdout.print("{}", .{kernel_cmd.repeat});
            try stdout.writeAll(",\"repeatSynchronization\":\"");
            try stdout.writeAll(@tagName(kernel_cmd.repeat_synchronization));
            try stdout.writeAll("\"");
            try stdout.writeAll("}\n");
        },
        .render_draw, .draw_indirect, .draw_indexed_indirect, .render_pass => |render_cmd| {
            const render_kind = model.command_kind_name(model.command_kind(command));
            try stdout.writeAll("{\"seq\":");
            try stdout.print("{}", .{seq});
            try stdout.writeAll(",\"kind\":\"");
            try stdout.writeAll(render_kind);
            try stdout.writeAll("\",\"drawCount\":");
            try stdout.print("{}", .{render_cmd.draw_count});
            try stdout.writeAll(",\"vertexCount\":");
            try stdout.print("{}", .{render_cmd.vertex_count});
            try stdout.writeAll(",\"instanceCount\":");
            try stdout.print("{}", .{render_cmd.instance_count});
            try stdout.writeAll(",\"firstVertex\":");
            try stdout.print("{}", .{render_cmd.first_vertex});
            try stdout.writeAll(",\"firstInstance\":");
            try stdout.print("{}", .{render_cmd.first_instance});
            if (render_cmd.index_count) |index_count| {
                try stdout.writeAll(",\"indexCount\":");
                try stdout.print("{}", .{index_count});
                try stdout.writeAll(",\"firstIndex\":");
                try stdout.print("{}", .{render_cmd.first_index});
                try stdout.writeAll(",\"baseVertex\":");
                try stdout.print("{}", .{render_cmd.base_vertex});
                if (render_cmd.index_data) |index_data| {
                    try stdout.writeAll(",\"indexFormat\":\"");
                    switch (index_data) {
                        .uint16 => |values| {
                            try stdout.writeAll("uint16\",\"indexData\":");
                            try printJsonIntArray(stdout, values);
                        },
                        .uint32 => |values| {
                            try stdout.writeAll("uint32\",\"indexData\":");
                            try printJsonIntArray(stdout, values);
                        },
                    }
                }
            }
            try stdout.writeAll(",\"targetHandle\":");
            try stdout.print("{}", .{render_cmd.target_handle});
            try stdout.writeAll(",\"targetWidth\":");
            try stdout.print("{}", .{render_cmd.target_width});
            try stdout.writeAll(",\"targetHeight\":");
            try stdout.print("{}", .{render_cmd.target_height});
            try stdout.writeAll(",\"targetFormat\":");
            try stdout.print("{}", .{render_cmd.target_format});
            try stdout.writeAll(",\"pipelineMode\":\"");
            try stdout.print("{s}\",", .{@tagName(render_cmd.pipeline_mode)});
            try stdout.writeAll("\"bindGroupMode\":\"");
            try stdout.print("{s}\",\"encodeMode\":\"", .{@tagName(render_cmd.bind_group_mode)});
            try stdout.print("{s}\"", .{@tagName(render_cmd.encode_mode)});
            try stdout.writeAll(",\"viewportX\":");
            try stdout.print("{d}", .{render_cmd.viewport_x});
            try stdout.writeAll(",\"viewportY\":");
            try stdout.print("{d}", .{render_cmd.viewport_y});
            if (render_cmd.viewport_width) |viewport_width| {
                try stdout.writeAll(",\"viewportWidth\":");
                try stdout.print("{d}", .{viewport_width});
            }
            if (render_cmd.viewport_height) |viewport_height| {
                try stdout.writeAll(",\"viewportHeight\":");
                try stdout.print("{d}", .{viewport_height});
            }
            try stdout.writeAll(",\"viewportMinDepth\":");
            try stdout.print("{d}", .{render_cmd.viewport_min_depth});
            try stdout.writeAll(",\"viewportMaxDepth\":");
            try stdout.print("{d}", .{render_cmd.viewport_max_depth});
            try stdout.writeAll(",\"scissorX\":");
            try stdout.print("{}", .{render_cmd.scissor_x});
            try stdout.writeAll(",\"scissorY\":");
            try stdout.print("{}", .{render_cmd.scissor_y});
            if (render_cmd.scissor_width) |scissor_width| {
                try stdout.writeAll(",\"scissorWidth\":");
                try stdout.print("{}", .{scissor_width});
            }
            if (render_cmd.scissor_height) |scissor_height| {
                try stdout.writeAll(",\"scissorHeight\":");
                try stdout.print("{}", .{scissor_height});
            }
            try stdout.writeAll(",\"blend\":[");
            try stdout.print("{d},{d},{d},{d}]", .{
                render_cmd.blend_constant[0],
                render_cmd.blend_constant[1],
                render_cmd.blend_constant[2],
                render_cmd.blend_constant[3],
            });
            try stdout.writeAll(",\"stencilReference\":");
            try stdout.print("{}", .{render_cmd.stencil_reference});
            if (render_cmd.bind_group_dynamic_offsets) |offsets| {
                try stdout.writeAll(",\"bindGroupDynamicOffsets\":");
                try printJsonIntArray(stdout, offsets);
            }
            try stdout.writeAll("}\n");
        },
        .barrier => |barrier_cmd| {
            try stdout.writeAll("{\"seq\":");
            try stdout.print("{}", .{seq});
            try stdout.writeAll(",\"kind\":\"barrier\",\"dependencyCount\":");
            try stdout.print("{}", .{barrier_cmd.dependency_count});
            try stdout.writeAll("}\n");
        },
        .sampler_create => |sampler_cmd| {
            try stdout.writeAll("{\"seq\":");
            try stdout.print("{}", .{seq});
            try stdout.writeAll(",\"kind\":\"sampler_create\",\"handle\":");
            try stdout.print("{}", .{sampler_cmd.handle});
            try stdout.writeAll("}\n");
        },
        .sampler_destroy => |sampler_cmd| {
            try stdout.writeAll("{\"seq\":");
            try stdout.print("{}", .{seq});
            try stdout.writeAll(",\"kind\":\"sampler_destroy\",\"handle\":");
            try stdout.print("{}", .{sampler_cmd.handle});
            try stdout.writeAll("}\n");
        },
        .texture_write => |texture_cmd| {
            try stdout.writeAll("{\"seq\":");
            try stdout.print("{}", .{seq});
            try stdout.writeAll(",\"kind\":\"texture_write\",\"handle\":");
            try stdout.print("{}", .{texture_cmd.texture.handle});
            try stdout.writeAll(",\"width\":");
            try stdout.print("{}", .{texture_cmd.texture.width});
            try stdout.writeAll(",\"height\":");
            try stdout.print("{}", .{texture_cmd.texture.height});
            try stdout.writeAll(",\"dataBytes\":");
            try stdout.print("{}", .{texture_cmd.data.len});
            try stdout.writeAll("}\n");
        },
        .texture_query => |texture_cmd| {
            try stdout.writeAll("{\"seq\":");
            try stdout.print("{}", .{seq});
            try stdout.writeAll(",\"kind\":\"texture_query\",\"handle\":");
            try stdout.print("{}", .{texture_cmd.handle});
            if (texture_cmd.expected_width) |expected| {
                try stdout.writeAll(",\"expectedWidth\":");
                try stdout.print("{}", .{expected});
            }
            if (texture_cmd.expected_height) |expected| {
                try stdout.writeAll(",\"expectedHeight\":");
                try stdout.print("{}", .{expected});
            }
            if (texture_cmd.expected_depth_or_array_layers) |expected| {
                try stdout.writeAll(",\"expectedDepthOrArrayLayers\":");
                try stdout.print("{}", .{expected});
            }
            try stdout.writeAll("}\n");
        },
        .texture_destroy => |texture_cmd| {
            try stdout.writeAll("{\"seq\":");
            try stdout.print("{}", .{seq});
            try stdout.writeAll(",\"kind\":\"texture_destroy\",\"handle\":");
            try stdout.print("{}", .{texture_cmd.handle});
            try stdout.writeAll("}\n");
        },
        .surface_create => |surface_cmd| {
            try stdout.writeAll("{\"seq\":");
            try stdout.print("{}", .{seq});
            try stdout.writeAll(",\"kind\":\"surface_create\",\"handle\":");
            try stdout.print("{}", .{surface_cmd.handle});
            try stdout.writeAll("}\n");
        },
        .surface_capabilities => |surface_cmd| {
            try stdout.writeAll("{\"seq\":");
            try stdout.print("{}", .{seq});
            try stdout.writeAll(",\"kind\":\"surface_capabilities\",\"handle\":");
            try stdout.print("{}", .{surface_cmd.handle});
            try stdout.writeAll("}\n");
        },
        .surface_configure => |surface_cmd| {
            try stdout.writeAll("{\"seq\":");
            try stdout.print("{}", .{seq});
            try stdout.writeAll(",\"kind\":\"surface_configure\",\"handle\":");
            try stdout.print("{}", .{surface_cmd.handle});
            try stdout.writeAll(",\"width\":");
            try stdout.print("{}", .{surface_cmd.width});
            try stdout.writeAll(",\"height\":");
            try stdout.print("{}", .{surface_cmd.height});
            try stdout.writeAll("}\n");
        },
        .surface_acquire => |surface_cmd| {
            try stdout.writeAll("{\"seq\":");
            try stdout.print("{}", .{seq});
            try stdout.writeAll(",\"kind\":\"surface_acquire\",\"handle\":");
            try stdout.print("{}", .{surface_cmd.handle});
            try stdout.writeAll("}\n");
        },
        .surface_present => |surface_cmd| {
            try stdout.writeAll("{\"seq\":");
            try stdout.print("{}", .{seq});
            try stdout.writeAll(",\"kind\":\"surface_present\",\"handle\":");
            try stdout.print("{}", .{surface_cmd.handle});
            try stdout.writeAll("}\n");
        },
        .surface_unconfigure => |surface_cmd| {
            try stdout.writeAll("{\"seq\":");
            try stdout.print("{}", .{seq});
            try stdout.writeAll(",\"kind\":\"surface_unconfigure\",\"handle\":");
            try stdout.print("{}", .{surface_cmd.handle});
            try stdout.writeAll("}\n");
        },
        .surface_release => |surface_cmd| {
            try stdout.writeAll("{\"seq\":");
            try stdout.print("{}", .{seq});
            try stdout.writeAll(",\"kind\":\"surface_release\",\"handle\":");
            try stdout.print("{}", .{surface_cmd.handle});
            try stdout.writeAll("}\n");
        },
        .async_diagnostics => |diag_cmd| {
            try stdout.writeAll("{\"seq\":");
            try stdout.print("{}", .{seq});
            try stdout.writeAll(",\"kind\":\"async_diagnostics\",\"targetFormat\":");
            try stdout.print("{}", .{diag_cmd.target_format});
            try stdout.writeAll(",\"mode\":\"");
            try stdout.writeAll(@tagName(diag_cmd.mode));
            try stdout.writeAll("\",\"iterations\":");
            try stdout.print("{}", .{diag_cmd.iterations});
            try stdout.writeAll("}\n");
        },
        .map_async => |map_cmd| {
            try stdout.writeAll("{\"seq\":");
            try stdout.print("{}", .{seq});
            try stdout.writeAll(",\"kind\":\"map_async\",\"mode\":\"");
            try stdout.writeAll(@tagName(map_cmd.mode));
            try stdout.writeAll("\",\"bytes\":");
            try stdout.print("{}", .{map_cmd.bytes});
            try stdout.writeAll("}\n");
        },
    }
}

pub fn printCommandSummary(stdout: anytype, target: model.Command, execute_result: ?execution.ExecutionResult) !void {
    switch (target) {
        .copy_buffer_to_texture => |copy| {
            try stdout.print("  -> copy bytes={} temp={} align={}\\n", .{
                copy.bytes,
                copy.uses_temporary_buffer,
                copy.temporary_buffer_alignment,
            });
        },
        .upload => |upload| {
            try stdout.print("  -> upload bytes={} align={}\\n", .{ upload.bytes, upload.align_bytes });
        },
        .buffer_write => |buffer_write| {
            try stdout.print("  -> buffer_write handle={} offset={} words={} size={}\\n", .{
                buffer_write.handle,
                buffer_write.offset,
                buffer_write.data.len,
                buffer_write.buffer_size,
            });
        },
        .kernel_dispatch => |kernel_cmd| {
            try stdout.print("  -> kernel={s} dispatch {}x{}x{} repeat={}\\n", .{ kernel_cmd.kernel, kernel_cmd.x, kernel_cmd.y, kernel_cmd.z, kernel_cmd.repeat });
        },
        .dispatch, .dispatch_indirect => |dispatch_cmd| {
            const dispatch_kind = model.command_kind_name(model.command_kind(target));
            try stdout.print("  -> {s} {}x{}x{}\\n", .{ dispatch_kind, dispatch_cmd.x, dispatch_cmd.y, dispatch_cmd.z });
        },
        .render_draw, .draw_indirect, .draw_indexed_indirect, .render_pass => |render_cmd| {
            const render_kind = model.command_kind_name(model.command_kind(target));
            try stdout.print(
                "  -> {s} draws={} vertices={} instances={} firstVertex={} firstInstance={} indexCount={any} firstIndex={} baseVertex={} target={}x{} handle={} pipelineMode={s} bindGroupMode={s} encodeMode={s} viewport=({d},{d},{any},{any},{d},{d}) scissor=({},{},{any},{any}) stencilRef={} dynamicOffsets={any}\\n",
                .{
                    render_kind,
                    render_cmd.draw_count,
                    render_cmd.vertex_count,
                    render_cmd.instance_count,
                    render_cmd.first_vertex,
                    render_cmd.first_instance,
                    render_cmd.index_count,
                    render_cmd.first_index,
                    render_cmd.base_vertex,
                    render_cmd.target_width,
                    render_cmd.target_height,
                    render_cmd.target_handle,
                    @tagName(render_cmd.pipeline_mode),
                    @tagName(render_cmd.bind_group_mode),
                    @tagName(render_cmd.encode_mode),
                    render_cmd.viewport_x,
                    render_cmd.viewport_y,
                    render_cmd.viewport_width,
                    render_cmd.viewport_height,
                    render_cmd.viewport_min_depth,
                    render_cmd.viewport_max_depth,
                    render_cmd.scissor_x,
                    render_cmd.scissor_y,
                    render_cmd.scissor_width,
                    render_cmd.scissor_height,
                    render_cmd.stencil_reference,
                    render_cmd.bind_group_dynamic_offsets,
                },
            );
        },
        .barrier => |barrier_cmd| {
            try stdout.print("  -> barrier {} dependencies\\n", .{barrier_cmd.dependency_count});
        },
        .sampler_create => |sampler_cmd| {
            try stdout.print("  -> sampler_create handle={}\\n", .{sampler_cmd.handle});
        },
        .sampler_destroy => |sampler_cmd| {
            try stdout.print("  -> sampler_destroy handle={}\\n", .{sampler_cmd.handle});
        },
        .texture_write => |texture_cmd| {
            try stdout.print("  -> texture_write handle={} extent={}x{}x{} bytes={}\\n", .{
                texture_cmd.texture.handle,
                texture_cmd.texture.width,
                texture_cmd.texture.height,
                texture_cmd.texture.depth_or_array_layers,
                texture_cmd.data.len,
            });
        },
        .texture_query => |texture_cmd| {
            try stdout.print(
                "  -> texture_query handle={} expectedWidth={any} expectedHeight={any} expectedDepth={any} expectedFormat={any} expectedDimension={any} expectedViewDimension={any} expectedSampleCount={any} expectedUsage={any}\\n",
                .{
                    texture_cmd.handle,
                    texture_cmd.expected_width,
                    texture_cmd.expected_height,
                    texture_cmd.expected_depth_or_array_layers,
                    texture_cmd.expected_format,
                    texture_cmd.expected_dimension,
                    texture_cmd.expected_view_dimension,
                    texture_cmd.expected_sample_count,
                    texture_cmd.expected_usage,
                },
            );
        },
        .texture_destroy => |texture_cmd| {
            try stdout.print("  -> texture_destroy handle={}\\n", .{texture_cmd.handle});
        },
        .surface_create => |surface_cmd| {
            try stdout.print("  -> surface_create handle={}\\n", .{surface_cmd.handle});
        },
        .surface_capabilities => |surface_cmd| {
            try stdout.print("  -> surface_capabilities handle={}\\n", .{surface_cmd.handle});
        },
        .surface_configure => |surface_cmd| {
            try stdout.print("  -> surface_configure handle={} size={}x{}\\n", .{ surface_cmd.handle, surface_cmd.width, surface_cmd.height });
        },
        .surface_acquire => |surface_cmd| {
            try stdout.print("  -> surface_acquire handle={}\\n", .{surface_cmd.handle});
        },
        .surface_present => |surface_cmd| {
            try stdout.print("  -> surface_present handle={}\\n", .{surface_cmd.handle});
        },
        .surface_unconfigure => |surface_cmd| {
            try stdout.print("  -> surface_unconfigure handle={}\\n", .{surface_cmd.handle});
        },
        .surface_release => |surface_cmd| {
            try stdout.print("  -> surface_release handle={}\\n", .{surface_cmd.handle});
        },
        .async_diagnostics => |diag_cmd| {
            try stdout.print(
                "  -> async_diagnostics targetFormat={} mode={s} iterations={}\\n",
                .{ diag_cmd.target_format, @tagName(diag_cmd.mode), diag_cmd.iterations },
            );
        },
        .map_async => |map_cmd| {
            try stdout.print("  -> map_async mode={s} bytes={}\\n", .{ @tagName(map_cmd.mode), map_cmd.bytes });
        },
    }
    if (execute_result) |exec| {
        try stdout.print(
            "  -> exec backend={s} status={s} statusCode={s} durationNs={} setupNs={} encodeNs={} submitWaitNs={} dispatchCount={} gpuTimestampNs={} gpuTimestampAttempted={} gpuTimestampValid={}\\n",
            .{
                exec.backend,
                execution.executionStatusName(exec.status),
                exec.status_code,
                exec.duration_ns,
                exec.setup_ns,
                exec.encode_ns,
                exec.submit_wait_ns,
                exec.dispatch_count,
                exec.gpu_timestamp_ns,
                exec.gpu_timestamp_attempted,
                exec.gpu_timestamp_valid,
            },
        );
    }
}
