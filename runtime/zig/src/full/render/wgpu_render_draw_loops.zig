const model_render_types = @import("../../contracts/model/model_render_types.zig");
const abi_base = @import("../../core/abi/wgpu_handle_types.zig");
const render_api_mod = @import("wgpu_render_api.zig");
const render_resource_mod = @import("wgpu_render_resources.zig");

const RENDER_UNIFORM_BINDING_INDEX: u32 = render_resource_mod.RENDER_UNIFORM_BINDING_INDEX;
const RenderUniformBindingResources = render_resource_mod.RenderUniformBindingResources;

pub fn encode_render_bundle_draw_nonindexed(
    render_api: render_api_mod.RenderApi,
    render_bundle_encoder: render_api_mod.RenderBundleEncoder,
    render: model_render_types.RenderDrawCommand,
    render_pipeline: abi_base.WGPURenderPipeline,
    render_uniform_resources: RenderUniformBindingResources,
    dynamic_offsets: []const u32,
) void {
    var draw_index: u32 = 0;
    switch (render.pipeline_mode) {
        .static => switch (render.bind_group_mode) {
            .no_change => while (draw_index < render.draw_count) : (draw_index += 1) {
                render_api.render_bundle_encoder_draw(
                    render_bundle_encoder,
                    render.vertex_count,
                    render.instance_count,
                    render.first_vertex,
                    render.first_instance,
                );
            },
            .redundant => while (draw_index < render.draw_count) : (draw_index += 1) {
                render_api.render_bundle_encoder_set_bind_group(
                    render_bundle_encoder,
                    RENDER_UNIFORM_BINDING_INDEX,
                    render_uniform_resources.bind_group,
                    dynamic_offsets.len,
                    dynamic_offsets.ptr,
                );
                render_api.render_bundle_encoder_draw(
                    render_bundle_encoder,
                    render.vertex_count,
                    render.instance_count,
                    render.first_vertex,
                    render.first_instance,
                );
            },
        },
        .redundant => switch (render.bind_group_mode) {
            .no_change => while (draw_index < render.draw_count) : (draw_index += 1) {
                render_api.render_bundle_encoder_set_pipeline(render_bundle_encoder, render_pipeline);
                render_api.render_bundle_encoder_draw(
                    render_bundle_encoder,
                    render.vertex_count,
                    render.instance_count,
                    render.first_vertex,
                    render.first_instance,
                );
            },
            .redundant => while (draw_index < render.draw_count) : (draw_index += 1) {
                render_api.render_bundle_encoder_set_pipeline(render_bundle_encoder, render_pipeline);
                render_api.render_bundle_encoder_set_bind_group(
                    render_bundle_encoder,
                    RENDER_UNIFORM_BINDING_INDEX,
                    render_uniform_resources.bind_group,
                    dynamic_offsets.len,
                    dynamic_offsets.ptr,
                );
                render_api.render_bundle_encoder_draw(
                    render_bundle_encoder,
                    render.vertex_count,
                    render.instance_count,
                    render.first_vertex,
                    render.first_instance,
                );
            },
        },
    }
}

pub fn encode_render_bundle_draw_indexed(
    render_api: render_api_mod.RenderApi,
    render_bundle_encoder: render_api_mod.RenderBundleEncoder,
    render: model_render_types.RenderDrawCommand,
    render_pipeline: abi_base.WGPURenderPipeline,
    render_uniform_resources: RenderUniformBindingResources,
    dynamic_offsets: []const u32,
    index_count: u32,
) void {
    var draw_index: u32 = 0;
    switch (render.pipeline_mode) {
        .static => switch (render.bind_group_mode) {
            .no_change => while (draw_index < render.draw_count) : (draw_index += 1) {
                render_api.render_bundle_encoder_draw_indexed(
                    render_bundle_encoder,
                    index_count,
                    render.instance_count,
                    render.first_index,
                    render.base_vertex,
                    render.first_instance,
                );
            },
            .redundant => while (draw_index < render.draw_count) : (draw_index += 1) {
                render_api.render_bundle_encoder_set_bind_group(
                    render_bundle_encoder,
                    RENDER_UNIFORM_BINDING_INDEX,
                    render_uniform_resources.bind_group,
                    dynamic_offsets.len,
                    dynamic_offsets.ptr,
                );
                render_api.render_bundle_encoder_draw_indexed(
                    render_bundle_encoder,
                    index_count,
                    render.instance_count,
                    render.first_index,
                    render.base_vertex,
                    render.first_instance,
                );
            },
        },
        .redundant => switch (render.bind_group_mode) {
            .no_change => while (draw_index < render.draw_count) : (draw_index += 1) {
                render_api.render_bundle_encoder_set_pipeline(render_bundle_encoder, render_pipeline);
                render_api.render_bundle_encoder_draw_indexed(
                    render_bundle_encoder,
                    index_count,
                    render.instance_count,
                    render.first_index,
                    render.base_vertex,
                    render.first_instance,
                );
            },
            .redundant => while (draw_index < render.draw_count) : (draw_index += 1) {
                render_api.render_bundle_encoder_set_pipeline(render_bundle_encoder, render_pipeline);
                render_api.render_bundle_encoder_set_bind_group(
                    render_bundle_encoder,
                    RENDER_UNIFORM_BINDING_INDEX,
                    render_uniform_resources.bind_group,
                    dynamic_offsets.len,
                    dynamic_offsets.ptr,
                );
                render_api.render_bundle_encoder_draw_indexed(
                    render_bundle_encoder,
                    index_count,
                    render.instance_count,
                    render.first_index,
                    render.base_vertex,
                    render.first_instance,
                );
            },
        },
    }
}

pub fn encode_render_pass_draw_nonindexed(
    render_api: render_api_mod.RenderApi,
    render_pass: abi_base.WGPURenderPassEncoder,
    render: model_render_types.RenderDrawCommand,
    render_pipeline: abi_base.WGPURenderPipeline,
    render_uniform_resources: RenderUniformBindingResources,
    dynamic_offsets: []const u32,
) void {
    var draw_index: u32 = 0;
    switch (render.pipeline_mode) {
        .static => switch (render.bind_group_mode) {
            .no_change => while (draw_index < render.draw_count) : (draw_index += 1) {
                render_api.render_pass_encoder_draw(
                    render_pass,
                    render.vertex_count,
                    render.instance_count,
                    render.first_vertex,
                    render.first_instance,
                );
            },
            .redundant => while (draw_index < render.draw_count) : (draw_index += 1) {
                render_api.render_pass_encoder_set_bind_group(
                    render_pass,
                    RENDER_UNIFORM_BINDING_INDEX,
                    render_uniform_resources.bind_group,
                    dynamic_offsets.len,
                    dynamic_offsets.ptr,
                );
                render_api.render_pass_encoder_draw(
                    render_pass,
                    render.vertex_count,
                    render.instance_count,
                    render.first_vertex,
                    render.first_instance,
                );
            },
        },
        .redundant => switch (render.bind_group_mode) {
            .no_change => while (draw_index < render.draw_count) : (draw_index += 1) {
                render_api.render_pass_encoder_set_pipeline(render_pass, render_pipeline);
                render_api.render_pass_encoder_draw(
                    render_pass,
                    render.vertex_count,
                    render.instance_count,
                    render.first_vertex,
                    render.first_instance,
                );
            },
            .redundant => while (draw_index < render.draw_count) : (draw_index += 1) {
                render_api.render_pass_encoder_set_pipeline(render_pass, render_pipeline);
                render_api.render_pass_encoder_set_bind_group(
                    render_pass,
                    RENDER_UNIFORM_BINDING_INDEX,
                    render_uniform_resources.bind_group,
                    dynamic_offsets.len,
                    dynamic_offsets.ptr,
                );
                render_api.render_pass_encoder_draw(
                    render_pass,
                    render.vertex_count,
                    render.instance_count,
                    render.first_vertex,
                    render.first_instance,
                );
            },
        },
    }
}

pub fn encode_render_pass_draw_indexed(
    render_api: render_api_mod.RenderApi,
    render_pass: abi_base.WGPURenderPassEncoder,
    render: model_render_types.RenderDrawCommand,
    render_pipeline: abi_base.WGPURenderPipeline,
    render_uniform_resources: RenderUniformBindingResources,
    dynamic_offsets: []const u32,
    index_count: u32,
) void {
    var draw_index: u32 = 0;
    switch (render.pipeline_mode) {
        .static => switch (render.bind_group_mode) {
            .no_change => while (draw_index < render.draw_count) : (draw_index += 1) {
                render_api.render_pass_encoder_draw_indexed(
                    render_pass,
                    index_count,
                    render.instance_count,
                    render.first_index,
                    render.base_vertex,
                    render.first_instance,
                );
            },
            .redundant => while (draw_index < render.draw_count) : (draw_index += 1) {
                render_api.render_pass_encoder_set_bind_group(
                    render_pass,
                    RENDER_UNIFORM_BINDING_INDEX,
                    render_uniform_resources.bind_group,
                    dynamic_offsets.len,
                    dynamic_offsets.ptr,
                );
                render_api.render_pass_encoder_draw_indexed(
                    render_pass,
                    index_count,
                    render.instance_count,
                    render.first_index,
                    render.base_vertex,
                    render.first_instance,
                );
            },
        },
        .redundant => switch (render.bind_group_mode) {
            .no_change => while (draw_index < render.draw_count) : (draw_index += 1) {
                render_api.render_pass_encoder_set_pipeline(render_pass, render_pipeline);
                render_api.render_pass_encoder_draw_indexed(
                    render_pass,
                    index_count,
                    render.instance_count,
                    render.first_index,
                    render.base_vertex,
                    render.first_instance,
                );
            },
            .redundant => while (draw_index < render.draw_count) : (draw_index += 1) {
                render_api.render_pass_encoder_set_pipeline(render_pass, render_pipeline);
                render_api.render_pass_encoder_set_bind_group(
                    render_pass,
                    RENDER_UNIFORM_BINDING_INDEX,
                    render_uniform_resources.bind_group,
                    dynamic_offsets.len,
                    dynamic_offsets.ptr,
                );
                render_api.render_pass_encoder_draw_indexed(
                    render_pass,
                    index_count,
                    render.instance_count,
                    render.first_index,
                    render.base_vertex,
                    render.first_instance,
                );
            },
        },
    }
}
