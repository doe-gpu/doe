const handles = @import("wgpu_handle_types.zig");
const upstream = @import("generated/webgpu_upstream.zig");
const layout = @import("../../contracts/model/model_texture_layout_value_types.zig");
const execution_types = @import("wgpu_execution_types.zig");

pub const NativeExecutionStatus = execution_types.NativeExecutionStatus;
pub const NativeExecutionResult = execution_types.NativeExecutionResult;

pub const WGPUInstance = handles.WGPUInstance;
pub const WGPUAdapter = handles.WGPUAdapter;
pub const WGPUDevice = handles.WGPUDevice;
pub const WGPUQueue = handles.WGPUQueue;
pub const WGPUBuffer = handles.WGPUBuffer;
pub const WGPUTexture = handles.WGPUTexture;
pub const WGPUTextureView = handles.WGPUTextureView;
pub const WGPUExternalTexture = handles.WGPUExternalTexture;
pub const WGPUShaderModule = handles.WGPUShaderModule;
pub const WGPUSampler = handles.WGPUSampler;
pub const WGPUComputePipeline = handles.WGPUComputePipeline;
pub const WGPURenderPipeline = handles.WGPURenderPipeline;
pub const WGPUComputePassEncoder = handles.WGPUComputePassEncoder;
pub const WGPURenderPassEncoder = handles.WGPURenderPassEncoder;
pub const WGPUBindGroupLayout = handles.WGPUBindGroupLayout;
pub const WGPUBindGroup = handles.WGPUBindGroup;
pub const WGPUPipelineLayout = handles.WGPUPipelineLayout;
pub const WGPUCommandEncoder = handles.WGPUCommandEncoder;
pub const WGPUCommandBuffer = handles.WGPUCommandBuffer;
pub const WGPUQuerySet = handles.WGPUQuerySet;
pub const WGPUFuture = handles.WGPUFuture;
pub const WGPUStringView = handles.WGPUStringView;

pub const WGPUBool = handles.WGPUBool;
pub const WGPUFlags = layout.WGPUFlags;
pub const WGPUBufferUsage = WGPUFlags;
pub const WGPUMapMode = WGPUFlags;
pub const WGPUAlphaMode = u32;
pub const WGPUSType = layout.WGPUSType;

pub const WGPUSType_ShaderSourceWGSL: WGPUSType = 0x00000002;
pub const WGPUSType_ShaderSourceMSL: WGPUSType = 0x00000003;
pub const WGPUSType_ShaderSourceSPIRV: WGPUSType = 0x00000004;
pub const WGPUSType_ShaderSourceHLSL: WGPUSType = 0x00000005;
pub const WGPUSType_RenderPassMaxDrawCount: WGPUSType = 0x00000003;
pub const WGPUSType_TextureComponentSwizzleDescriptor: WGPUSType = 0x0000000C;
pub const WGPUSType_ExternalTextureBindingEntry: WGPUSType = 0x00050001;
pub const WGPUSType_ExternalTextureBindingLayout: WGPUSType = 0x00050002;

pub const WGPU_STRLEN = handles.WGPU_STRLEN;
pub const WGPU_FALSE: WGPUBool = handles.WGPU_FALSE;
pub const WGPU_TRUE: WGPUBool = handles.WGPU_TRUE;
pub const WGPU_COPY_STRIDE_UNDEFINED: u32 = layout.WGPUCopyStrideUndefined;
pub const WGPU_WHOLE_SIZE: u64 = layout.WGPUWholeSize;
pub const WGPU_MIP_LEVEL_COUNT_UNDEFINED: u32 = 0xFFFFFFFF;
pub const WGPU_ARRAY_LAYER_COUNT_UNDEFINED: u32 = 0xFFFFFFFF;

pub const WGPUBufferUsage_None: WGPUBufferUsage = 0;
pub const WGPUBufferUsage_MapRead: WGPUBufferUsage = 0x0000000000000001;
pub const WGPUBufferUsage_MapWrite: WGPUBufferUsage = 0x0000000000000002;
pub const WGPUBufferUsage_CopySrc: WGPUBufferUsage = 0x0000000000000004;
pub const WGPUBufferUsage_CopyDst: WGPUBufferUsage = 0x0000000000000008;
pub const WGPUBufferUsage_Index: WGPUBufferUsage = 0x0000000000000010;
pub const WGPUBufferUsage_Vertex: WGPUBufferUsage = 0x0000000000000020;
pub const WGPUBufferUsage_Uniform: WGPUBufferUsage = 0x0000000000000040;
pub const WGPUBufferUsage_Storage: WGPUBufferUsage = 0x0000000000000080;
pub const WGPUBufferUsage_QueryResolve: WGPUBufferUsage = 0x0000000000000200;

pub const WGPUQueryType = upstream.WGPUQueryType;
pub const WGPUQueryType_Timestamp: WGPUQueryType = 0x00000002;

pub const WGPUMapMode_Read: WGPUMapMode = 0x0000000000000001;
pub const WGPUMapMode_Write: WGPUMapMode = 0x0000000000000002;

pub const WGPUMapAsyncStatus = upstream.WGPUMapAsyncStatus;
pub const WGPUMapAsyncStatus_Success: WGPUMapAsyncStatus = 1;
pub const WGPUBufferMapAsyncStatus = WGPUMapAsyncStatus;
pub const WGPUBufferMapAsyncStatus_Success = WGPUMapAsyncStatus_Success;

pub const WGPUStatus = handles.WGPUStatus;
pub const WGPUStatus_Success: WGPUStatus = handles.WGPUStatus_Success;
pub const TIMESTAMP_BUFFER_SIZE: u64 = 16;
