// Compatibility facade for runtime WGSL translation.
// Shipped consumers import runtime compute or graphics translation directly.

pub const translation_info = @import("runtime_translation_info.zig");
pub const compute = @import("runtime_compute_translation.zig");
pub const graphics = @import("runtime_graphics_translation.zig");

pub const TranslationInfo = translation_info.TranslationInfo;
pub const TranslationResult = translation_info.TranslationResult;
pub const TimedTranslationResult = translation_info.TimedTranslationResult;
pub const compute_runtime_robustness_config = compute.compute_runtime_robustness_config;
pub const vulkan_compute_runtime_robustness_config = compute.vulkan_compute_runtime_robustness_config;
pub const translateToMslForComputeRuntime = compute.translateToMslForComputeRuntime;
pub const translateToMslForComputeRuntimeTimed = compute.translateToMslForComputeRuntimeTimed;
pub const translateToSpirvForComputeRuntime = compute.translateToSpirvForComputeRuntime;
pub const translateToSpirvTimed = compute.translateToSpirvTimed;
pub const translateToSpirvForVulkanComputeRuntime = compute.translateToSpirvForVulkanComputeRuntime;

pub const VertexInputAttr = graphics.VertexInputAttr;
pub const InterStageVar = graphics.InterStageVar;
pub const GraphicsTranslationResult = graphics.GraphicsTranslationResult;
pub const translateToSpirvForGraphicsRuntime = graphics.translateToSpirvForGraphicsRuntime;
