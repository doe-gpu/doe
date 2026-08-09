const core = @import("wgpu_dropin_ext_a_core.zig");
const process_roots = @import("../runtime/process_roots.zig");
const std = core.std;
const types = core.types;
const p0 = core.p0;
const async_procs = core.async_procs;
const native = core.native;
const singleflight = core.singleflight;
const pipeline_cache_integration = core.pipeline_cache_integration;

pub const string_view_slice = core.string_view_slice;
pub const dup_string_view = core.dup_string_view;
pub const make_string_view = core.make_string_view;

pub const RenderStringView = extern struct {
    data: ?[*]const u8,
    length: usize,
};

pub const RenderBlendComponent = extern struct {
    operation: u32,
    srcFactor: u32,
    dstFactor: u32,
};

pub const RenderBlendState = extern struct {
    color: RenderBlendComponent,
    alpha: RenderBlendComponent,
};

pub const RenderColorTargetState = extern struct {
    nextInChain: ?*anyopaque,
    format: u32,
    blend: ?*const RenderBlendState,
    writeMask: u64,
};

pub const RenderVertexState = extern struct {
    nextInChain: ?*anyopaque,
    module: ?*anyopaque,
    entryPoint: RenderStringView,
    constantCount: usize,
    constants: ?*anyopaque,
    bufferCount: usize,
    buffers: ?*anyopaque,
};

pub const RenderFragmentState = extern struct {
    nextInChain: ?*anyopaque,
    module: ?*anyopaque,
    entryPoint: RenderStringView,
    constantCount: usize,
    constants: ?*anyopaque,
    targetCount: usize,
    targets: ?[*]const RenderColorTargetState,
};

pub const RenderPrimitiveState = extern struct {
    nextInChain: ?*anyopaque,
    topology: u32,
    stripIndexFormat: u32,
    frontFace: u32,
    cullMode: u32,
    unclippedDepth: u32,
};

pub const RenderMultisampleState = extern struct {
    nextInChain: ?*anyopaque,
    count: u32,
    mask: u32,
    alphaToCoverageEnabled: u32,
};

pub const RenderVertexAttribute = extern struct {
    nextInChain: ?*anyopaque,
    format: u32,
    offset: u64,
    shaderLocation: u32,
};

pub const RenderVertexBufferLayout = extern struct {
    nextInChain: ?*anyopaque,
    stepMode: u32,
    arrayStride: u64,
    attributeCount: usize,
    attributes: ?[*]const RenderVertexAttribute,
};

pub const RenderDepthStencilDesc = extern struct {
    nextInChain: ?*anyopaque,
    format: u32,
    depthWriteEnabled: u32,
    depthCompare: u32,
    stencilFront: extern struct {
        compare: u32,
        failOp: u32,
        depthFailOp: u32,
        passOp: u32,
    },
    stencilBack: extern struct {
        compare: u32,
        failOp: u32,
        depthFailOp: u32,
        passOp: u32,
    },
    stencilReadMask: u32,
    stencilWriteMask: u32,
    depthBias: i32,
    depthBiasSlopeScale: f32,
    depthBiasClamp: f32,
};

pub const RenderPipelineDesc = extern struct {
    nextInChain: ?*anyopaque,
    label: RenderStringView,
    layout: ?*anyopaque,
    vertex: RenderVertexState,
    primitive: RenderPrimitiveState,
    depthStencil: ?*anyopaque,
    multisample: RenderMultisampleState,
    fragment: ?*const RenderFragmentState,
};

pub var g_next_async_future_id = std.atomic.Value(u64).init(32);
pub var g_compute_inflight = singleflight.Registry(ComputePipelineAsyncRequest).init(process_roots.dropinAsyncPipelineAllocator());
pub var g_render_inflight = singleflight.Registry(RenderPipelineAsyncRequest).init(process_roots.dropinAsyncPipelineAllocator());

pub fn next_async_future_id() u64 {
    return g_next_async_future_id.fetchAdd(1, .monotonic);
}

pub fn render_string_view_slice(view: RenderStringView) []const u8 {
    const data = view.data orelse return "";
    return data[0..view.length];
}

pub fn dup_render_string_view(view: RenderStringView) ?[]u8 {
    const src = render_string_view_slice(view);
    if (src.len == 0) return null;
    return std.heap.c_allocator.dupe(u8, src) catch null;
}

pub fn make_render_string_view(bytes: ?[]u8) RenderStringView {
    if (bytes) |owned| {
        return .{ .data = owned.ptr, .length = owned.len };
    }
    return .{ .data = null, .length = 0 };
}

pub fn optional_ptr_id(raw: ?*anyopaque) usize {
    if (raw) |ptr| return @intFromPtr(ptr);
    return 0;
}

pub fn compute_pipeline_request_key(req: *const ComputePipelineAsyncRequest) u64 {
    var hasher = std.hash.Wyhash.init(0);
    const device_ptr = optional_ptr_id(req.device);
    const module_ptr = optional_ptr_id(req.descriptor.compute.module);
    const layout_ptr = optional_ptr_id(req.descriptor.layout);
    hasher.update(std.mem.asBytes(&device_ptr));
    hasher.update(std.mem.asBytes(&module_ptr));
    hasher.update(std.mem.asBytes(&layout_ptr));
    hasher.update(string_view_slice(req.descriptor.compute.entryPoint));
    if (req.constants) |constants| {
        for (constants) |entry| {
            hasher.update(string_view_slice(entry.key));
            hasher.update(std.mem.asBytes(&entry.value));
        }
    }
    return hasher.final();
}

pub fn render_pipeline_request_key(req: *const RenderPipelineAsyncRequest) u64 {
    var hasher = std.hash.Wyhash.init(0);
    const device_ptr = optional_ptr_id(req.device);
    const layout_ptr = optional_ptr_id(req.descriptor.layout);
    const vertex_module_ptr = optional_ptr_id(req.descriptor.vertex.module);
    const fragment_module_ptr = if (req.descriptor.fragment) |frag| optional_ptr_id(frag.module) else 0;
    hasher.update(std.mem.asBytes(&device_ptr));
    hasher.update(std.mem.asBytes(&layout_ptr));
    hasher.update(std.mem.asBytes(&vertex_module_ptr));
    hasher.update(std.mem.asBytes(&fragment_module_ptr));
    hasher.update(render_string_view_slice(req.descriptor.vertex.entryPoint));
    if (req.descriptor.fragment) |frag| {
        hasher.update(render_string_view_slice(frag.entryPoint));
        hasher.update(std.mem.asBytes(&frag.targetCount));
        if (req.fragment_targets) |targets| {
            for (targets) |target| {
                hasher.update(std.mem.asBytes(&target.format));
                hasher.update(std.mem.asBytes(&target.writeMask));
            }
        }
    }
    hasher.update(std.mem.asBytes(&req.descriptor.multisample.count));
    return hasher.final();
}

pub const ComputePipelineAsyncRequest = struct {
    next: ?*ComputePipelineAsyncRequest = null,
    device: types.WGPUDevice,
    descriptor: types.WGPUComputePipelineDescriptor,
    callback_info: p0.CreateComputePipelineAsyncCallbackInfo,
    label_bytes: ?[]u8 = null,
    entry_point_bytes: ?[]u8 = null,
    constants: ?[]types.WGPUConstantEntry = null,
    constant_key_bytes: ?[]?[]u8 = null,
    pipeline: types.WGPUComputePipeline = null,
    status: u32 = p0.CREATE_COMPUTE_PIPELINE_ASYNC_STATUS_SUCCESS,
    message_bytes: ?[]u8 = null,
};

pub const ComputeInflightEntry = singleflight.Registry(ComputePipelineAsyncRequest).Entry;

pub const RenderPipelineAsyncRequest = struct {
    next: ?*RenderPipelineAsyncRequest = null,
    device: types.WGPUDevice,
    descriptor: RenderPipelineDesc,
    callback_info: async_procs.CreateRenderPipelineAsyncCallbackInfo,
    label_bytes: ?[]u8 = null,
    vertex_entry_bytes: ?[]u8 = null,
    fragment_entry_bytes: ?[]u8 = null,
    vertex_buffers: ?[]RenderVertexBufferLayout = null,
    vertex_attributes: ?[]RenderVertexAttribute = null,
    fragment_state: ?*RenderFragmentState = null,
    fragment_targets: ?[]RenderColorTargetState = null,
    depth_stencil: ?*RenderDepthStencilDesc = null,
    pipeline: types.WGPURenderPipeline = null,
    status: u32 = async_procs.CREATE_PIPELINE_ASYNC_STATUS_SUCCESS,
    message_bytes: ?[]u8 = null,
};

pub const RenderInflightEntry = singleflight.Registry(RenderPipelineAsyncRequest).Entry;

pub fn free_compute_pipeline_request(req: *ComputePipelineAsyncRequest) void {
    if (req.label_bytes) |bytes| std.heap.c_allocator.free(bytes);
    if (req.entry_point_bytes) |bytes| std.heap.c_allocator.free(bytes);
    if (req.constant_key_bytes) |all_keys| {
        for (all_keys) |maybe_key| {
            if (maybe_key) |key| std.heap.c_allocator.free(key);
        }
        std.heap.c_allocator.free(all_keys);
    }
    if (req.constants) |constants| std.heap.c_allocator.free(constants);
    if (req.message_bytes) |bytes| std.heap.c_allocator.free(bytes);
    if (req.descriptor.layout != null) native.doeNativePipelineLayoutRelease(req.descriptor.layout);
    if (req.descriptor.compute.module != null) native.doeNativeShaderModuleRelease(req.descriptor.compute.module);
    native.doeNativeDeviceRelease(req.device);
    std.heap.c_allocator.destroy(req);
}

pub fn copy_compute_pipeline_request(
    device: types.WGPUDevice,
    desc: *const types.WGPUComputePipelineDescriptor,
    callback_info: p0.CreateComputePipelineAsyncCallbackInfo,
) ?*ComputePipelineAsyncRequest {
    const req = std.heap.c_allocator.create(ComputePipelineAsyncRequest) catch return null;
    errdefer std.heap.c_allocator.destroy(req);

    req.* = .{
        .device = device,
        .descriptor = desc.*,
        .callback_info = callback_info,
    };

    native.doeNativeDeviceAddRef(device);
    if (desc.compute.module != null) native.object_add_ref(native.DoeShaderModule, desc.compute.module);
    if (desc.layout != null) native.object_add_ref(native.DoePipelineLayout, desc.layout);

    req.label_bytes = dup_string_view(desc.label);
    req.descriptor.label = make_string_view(req.label_bytes);

    req.entry_point_bytes = dup_string_view(desc.compute.entryPoint);
    req.descriptor.compute.entryPoint = make_string_view(req.entry_point_bytes);

    if (desc.compute.constantCount > 0 and desc.compute.constants != null) {
        const count = desc.compute.constantCount;
        const constants = std.heap.c_allocator.alloc(types.WGPUConstantEntry, count) catch {
            free_compute_pipeline_request(req);
            return null;
        };
        const key_bytes = std.heap.c_allocator.alloc(?[]u8, count) catch {
            std.heap.c_allocator.free(constants);
            free_compute_pipeline_request(req);
            return null;
        };
        @memset(key_bytes, null);
        for (constants, 0..) |*entry, index| {
            entry.* = desc.compute.constants.?[index];
            key_bytes[index] = dup_string_view(entry.key);
            entry.key = make_string_view(key_bytes[index]);
        }
        req.constants = constants;
        req.constant_key_bytes = key_bytes;
        req.descriptor.compute.constants = constants.ptr;
        req.descriptor.compute.constantCount = count;
    } else {
        req.descriptor.compute.constants = null;
        req.descriptor.compute.constantCount = 0;
    }

    return req;
}

pub fn set_compute_pipeline_request_error(req: *ComputePipelineAsyncRequest, message: []const u8) void {
    req.status = 2;
    req.message_bytes = std.heap.c_allocator.dupe(u8, message) catch null;
}

pub fn copy_render_pipeline_request(
    device: types.WGPUDevice,
    desc_raw: *const anyopaque,
    callback_info: async_procs.CreateRenderPipelineAsyncCallbackInfo,
) ?*RenderPipelineAsyncRequest {
    const src: *const RenderPipelineDesc = @ptrCast(@alignCast(desc_raw));
    const req = std.heap.c_allocator.create(RenderPipelineAsyncRequest) catch return null;
    errdefer std.heap.c_allocator.destroy(req);

    req.* = .{
        .device = device,
        .descriptor = src.*,
        .callback_info = callback_info,
    };

    native.doeNativeDeviceAddRef(device);
    if (src.layout != null) native.object_add_ref(native.DoePipelineLayout, src.layout);
    if (src.vertex.module != null) native.object_add_ref(native.DoeShaderModule, src.vertex.module);
    if (src.fragment) |frag| {
        if (frag.module != null) native.object_add_ref(native.DoeShaderModule, frag.module);
    }

    req.label_bytes = dup_render_string_view(src.label);
    req.descriptor.label = make_render_string_view(req.label_bytes);
    req.vertex_entry_bytes = dup_render_string_view(src.vertex.entryPoint);
    req.descriptor.vertex.entryPoint = make_render_string_view(req.vertex_entry_bytes);

    if (src.vertex.bufferCount > 0 and src.vertex.buffers != null) {
        const src_bufs = @as([*]const RenderVertexBufferLayout, @ptrCast(@alignCast(src.vertex.buffers)))[0..src.vertex.bufferCount];
        const dst_bufs = std.heap.c_allocator.alloc(RenderVertexBufferLayout, src_bufs.len) catch {
            free_render_pipeline_request(req);
            return null;
        };
        var attr_total: usize = 0;
        for (src_bufs) |buf| attr_total += buf.attributeCount;
        const dst_attrs = if (attr_total > 0)
            std.heap.c_allocator.alloc(RenderVertexAttribute, attr_total) catch {
                std.heap.c_allocator.free(dst_bufs);
                free_render_pipeline_request(req);
                return null;
            }
        else
            null;
        req.vertex_buffers = dst_bufs;
        req.vertex_attributes = dst_attrs;
        req.descriptor.vertex.buffers = @ptrCast(dst_bufs.ptr);
        req.descriptor.vertex.bufferCount = dst_bufs.len;

        var attr_index: usize = 0;
        for (src_bufs, 0..) |src_buf, index| {
            dst_bufs[index] = src_buf;
            dst_bufs[index].nextInChain = null;
            if (src_buf.attributeCount > 0 and src_buf.attributes != null and dst_attrs != null) {
                const src_attrs = src_buf.attributes.?[0..src_buf.attributeCount];
                const dst_slice = dst_attrs.?[attr_index .. attr_index + src_buf.attributeCount];
                for (src_attrs, 0..) |src_attr, attr_offset| {
                    dst_slice[attr_offset] = src_attr;
                    dst_slice[attr_offset].nextInChain = null;
                }
                dst_bufs[index].attributes = dst_slice.ptr;
                attr_index += src_buf.attributeCount;
            } else {
                dst_bufs[index].attributes = null;
                dst_bufs[index].attributeCount = 0;
            }
        }
    } else {
        req.descriptor.vertex.buffers = null;
        req.descriptor.vertex.bufferCount = 0;
    }

    if (src.fragment) |frag| {
        const frag_copy = std.heap.c_allocator.create(RenderFragmentState) catch {
            free_render_pipeline_request(req);
            return null;
        };
        frag_copy.* = frag.*;
        req.fragment_state = frag_copy;
        req.fragment_entry_bytes = dup_render_string_view(frag.entryPoint);
        frag_copy.entryPoint = make_render_string_view(req.fragment_entry_bytes);
        if (frag.targetCount > 0 and frag.targets != null) {
            const targets = std.heap.c_allocator.alloc(RenderColorTargetState, frag.targetCount) catch {
                free_render_pipeline_request(req);
                return null;
            };
            @memcpy(targets, frag.targets.?[0..frag.targetCount]);
            for (targets) |*target| target.nextInChain = null;
            req.fragment_targets = targets;
            frag_copy.targets = targets.ptr;
            frag_copy.targetCount = targets.len;
        } else {
            frag_copy.targets = null;
            frag_copy.targetCount = 0;
        }
        req.descriptor.fragment = frag_copy;
    } else {
        req.descriptor.fragment = null;
    }

    if (src.depthStencil) |depth_raw| {
        const src_depth: *const RenderDepthStencilDesc = @ptrCast(@alignCast(depth_raw));
        const depth_copy = std.heap.c_allocator.create(RenderDepthStencilDesc) catch {
            free_render_pipeline_request(req);
            return null;
        };
        depth_copy.* = src_depth.*;
        depth_copy.nextInChain = null;
        req.depth_stencil = depth_copy;
        req.descriptor.depthStencil = @ptrCast(depth_copy);
    } else {
        req.descriptor.depthStencil = null;
    }

    return req;
}

pub fn free_render_pipeline_request(req: *RenderPipelineAsyncRequest) void {
    if (req.label_bytes) |bytes| std.heap.c_allocator.free(bytes);
    if (req.vertex_entry_bytes) |bytes| std.heap.c_allocator.free(bytes);
    if (req.fragment_entry_bytes) |bytes| std.heap.c_allocator.free(bytes);
    if (req.vertex_buffers) |bufs| std.heap.c_allocator.free(bufs);
    if (req.vertex_attributes) |attrs| std.heap.c_allocator.free(attrs);
    if (req.fragment_targets) |targets| std.heap.c_allocator.free(targets);
    if (req.fragment_state) |frag| std.heap.c_allocator.destroy(frag);
    if (req.depth_stencil) |depth| std.heap.c_allocator.destroy(depth);
    if (req.message_bytes) |bytes| std.heap.c_allocator.free(bytes);
    if (req.descriptor.layout != null) native.doeNativePipelineLayoutRelease(req.descriptor.layout);
    if (req.descriptor.vertex.module != null) native.doeNativeShaderModuleRelease(req.descriptor.vertex.module);
    if (req.descriptor.fragment) |frag| {
        if (frag.module != null) native.doeNativeShaderModuleRelease(frag.module);
    }
    native.doeNativeDeviceRelease(req.device);
    std.heap.c_allocator.destroy(req);
}

pub fn set_render_pipeline_request_error(req: *RenderPipelineAsyncRequest, message: []const u8) void {
    req.status = 2;
    req.message_bytes = std.heap.c_allocator.dupe(u8, message) catch null;
}

pub fn run_compute_pipeline_async(ctx_raw: ?*anyopaque) void {
    const entry: *ComputeInflightEntry = @ptrCast(@alignCast(ctx_raw orelse return));
    const head = g_compute_inflight.take(entry) orelse return;
    const lead = head;
    lead.pipeline = @ptrCast(native.doeNativeDeviceCreateComputePipeline(lead.device, &lead.descriptor));
    pipeline_cache_integration.recordComputePipelineCreation(if (lead.entry_point_bytes) |ep| ep else null);
    if (lead.pipeline == null) {
        set_compute_pipeline_request_error(lead, "pipeline creation failed");
    }
    var req: ?*ComputePipelineAsyncRequest = head;
    var first = true;
    while (req) |current| {
        const next = current.next;
        current.status = lead.status;
        if (lead.pipeline != null) {
            current.pipeline = lead.pipeline;
            if (!first) native.object_add_ref(native.DoeComputePipeline, current.pipeline);
        } else if (current != lead) {
            set_compute_pipeline_request_error(current, "pipeline creation failed");
        }
        if (current.callback_info.callback) |cb| {
            cb(current.status, current.pipeline, make_string_view(current.message_bytes), current.callback_info.userdata1, current.callback_info.userdata2);
        }
        free_compute_pipeline_request(current);
        first = false;
        req = next;
    }
}

pub fn run_render_pipeline_async(ctx_raw: ?*anyopaque) void {
    const entry: *RenderInflightEntry = @ptrCast(@alignCast(ctx_raw orelse return));
    const head = g_render_inflight.take(entry) orelse return;
    const lead = head;
    lead.pipeline = @ptrCast(native.doeNativeDeviceCreateRenderPipeline(lead.device, @ptrCast(&lead.descriptor)));
    pipeline_cache_integration.recordRenderPipelineCreation();
    if (lead.pipeline == null) {
        set_render_pipeline_request_error(lead, "render pipeline creation failed");
    }
    var req: ?*RenderPipelineAsyncRequest = head;
    var first = true;
    while (req) |current| {
        const next = current.next;
        current.status = lead.status;
        if (lead.pipeline != null) {
            current.pipeline = lead.pipeline;
            if (!first) native.object_add_ref(native.DoeRenderPipeline, current.pipeline);
        } else if (current != lead) {
            set_render_pipeline_request_error(current, "render pipeline creation failed");
        }
        if (current.callback_info.callback) |cb| {
            cb(current.status, current.pipeline, make_string_view(current.message_bytes), current.callback_info.userdata1, current.callback_info.userdata2);
        }
        free_render_pipeline_request(current);
        first = false;
        req = next;
    }
}
