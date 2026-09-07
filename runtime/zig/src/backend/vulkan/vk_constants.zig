// Vulkan constants, extern struct types, and extern function declarations.
//
// Centralizes all Vulkan API identifiers so runtime modules reference
// named constants instead of bare magic numbers.

const std = @import("std");
const vk = @import("vulkan_types.zig");
const structs = @import("vk_structs.zig");
const capability_structs = @import("vk_capability_structs.zig");
const functions = @import("vk_functions.zig");
const vulkan_errors = @import("vulkan_errors.zig");

pub const VkBool32 = vk.VkBool32;
pub const VkFlags = vk.VkFlags;
pub const VkDeviceSize = vk.VkDeviceSize;
pub const VkStructureType = vk.VkStructureType;
pub const VkResult = vk.VkResult;
pub const VkInstance = vk.VkInstance;
pub const VkPhysicalDevice = vk.VkPhysicalDevice;
pub const VkDevice = vk.VkDevice;
pub const VkQueue = vk.VkQueue;
pub const VkCommandBuffer = vk.VkCommandBuffer;
pub const VkPipelineCache = vk.VkPipelineCache;
pub const VkCommandPool = vk.VkCommandPool;
pub const VkFence = vk.VkFence;
pub const VkBuffer = vk.VkBuffer;
pub const VkDeviceMemory = vk.VkDeviceMemory;
pub const VkShaderModule = vk.VkShaderModule;
pub const VkPipelineLayout = vk.VkPipelineLayout;
pub const VkPipeline = vk.VkPipeline;
pub const VkQueryPool = vk.VkQueryPool;
pub const VkDescriptorSetLayout = vk.VkDescriptorSetLayout;
pub const VkDescriptorPool = vk.VkDescriptorPool;
pub const VkDescriptorSet = vk.VkDescriptorSet;
pub const VkImage = vk.VkImage;
pub const VkImageView = vk.VkImageView;
pub const VkRenderPass = vk.VkRenderPass;
pub const VkFramebuffer = vk.VkFramebuffer;
pub const VkSemaphore = vk.VkSemaphore;
pub const VkSampler = vk.VkSampler;
pub const VK_NULL_U64 = vk.VK_NULL_U64;
pub const VkAllocationCallbacks = vk.VkAllocationCallbacks;

pub const VkApplicationInfo = structs.VkApplicationInfo;
pub const VkInstanceCreateInfo = structs.VkInstanceCreateInfo;
pub const VkDeviceQueueCreateInfo = structs.VkDeviceQueueCreateInfo;
pub const VkDeviceCreateInfo = structs.VkDeviceCreateInfo;
pub const VkCommandPoolCreateInfo = structs.VkCommandPoolCreateInfo;
pub const VkCommandBufferAllocateInfo = structs.VkCommandBufferAllocateInfo;
pub const VkFenceCreateInfo = structs.VkFenceCreateInfo;
pub const VkBufferCreateInfo = structs.VkBufferCreateInfo;
pub const VkExtent3D = structs.VkExtent3D;
pub const VkImageCreateInfo = structs.VkImageCreateInfo;
pub const VkMemoryAllocateInfo = structs.VkMemoryAllocateInfo;
pub const VkMemoryRequirements = structs.VkMemoryRequirements;
pub const VkCommandBufferInheritanceInfo = structs.VkCommandBufferInheritanceInfo;
pub const VkCommandBufferBeginInfo = structs.VkCommandBufferBeginInfo;
pub const VkSubmitInfo = structs.VkSubmitInfo;
pub const VkShaderModuleCreateInfo = structs.VkShaderModuleCreateInfo;
pub const VkPipelineCacheCreateInfo = structs.VkPipelineCacheCreateInfo;
pub const VkPipelineLayoutCreateInfo = structs.VkPipelineLayoutCreateInfo;
pub const VkPipelineShaderStageCreateInfo = structs.VkPipelineShaderStageCreateInfo;
pub const VkPipelineShaderStageRequiredSubgroupSizeCreateInfo = structs.VkPipelineShaderStageRequiredSubgroupSizeCreateInfo;
pub const VkDescriptorSetLayoutBinding = structs.VkDescriptorSetLayoutBinding;
pub const VkDescriptorSetLayoutCreateInfo = structs.VkDescriptorSetLayoutCreateInfo;
pub const VkDescriptorPoolSize = structs.VkDescriptorPoolSize;
pub const VkDescriptorPoolCreateInfo = structs.VkDescriptorPoolCreateInfo;
pub const VkDescriptorSetAllocateInfo = structs.VkDescriptorSetAllocateInfo;
pub const VkDescriptorBufferInfo = structs.VkDescriptorBufferInfo;
pub const VkDescriptorImageInfo = structs.VkDescriptorImageInfo;
pub const VkWriteDescriptorSet = structs.VkWriteDescriptorSet;
pub const VkComputePipelineCreateInfo = structs.VkComputePipelineCreateInfo;
pub const VkBufferCopy = structs.VkBufferCopy;
pub const VkQueryPoolCreateInfo = structs.VkQueryPoolCreateInfo;
pub const VkComponentMapping = structs.VkComponentMapping;
pub const VkImageSubresourceRange = structs.VkImageSubresourceRange;
pub const VkImageViewCreateInfo = structs.VkImageViewCreateInfo;
pub const VkImageSubresourceLayers = structs.VkImageSubresourceLayers;
pub const VkOffset3D = structs.VkOffset3D;
pub const VkBufferImageCopy = structs.VkBufferImageCopy;
pub const VkImageCopy = structs.VkImageCopy;
pub const VkBufferMemoryBarrier = structs.VkBufferMemoryBarrier;
pub const VkImageMemoryBarrier = structs.VkImageMemoryBarrier;
pub const VkMemoryBarrier = structs.VkMemoryBarrier;
pub const VkAttachmentDescription = structs.VkAttachmentDescription;
pub const VkAttachmentReference = structs.VkAttachmentReference;
pub const VkSubpassDescription = structs.VkSubpassDescription;
pub const VkSubpassDependency = structs.VkSubpassDependency;
pub const VkRenderPassCreateInfo = structs.VkRenderPassCreateInfo;
pub const VkFramebufferCreateInfo = structs.VkFramebufferCreateInfo;
pub const VkOffset2D = structs.VkOffset2D;
pub const VkExtent2D = structs.VkExtent2D;
pub const VkRect2D = structs.VkRect2D;
pub const VkClearColorValue = structs.VkClearColorValue;
pub const VkClearDepthStencilValue = structs.VkClearDepthStencilValue;
pub const VkClearValue = structs.VkClearValue;
pub const VkRenderPassBeginInfo = structs.VkRenderPassBeginInfo;
pub const VkViewport = structs.VkViewport;
pub const VkVertexInputBindingDescription = structs.VkVertexInputBindingDescription;
pub const VkVertexInputAttributeDescription = structs.VkVertexInputAttributeDescription;
pub const VkPipelineVertexInputStateCreateInfo = structs.VkPipelineVertexInputStateCreateInfo;
pub const VkPipelineInputAssemblyStateCreateInfo = structs.VkPipelineInputAssemblyStateCreateInfo;
pub const VkPipelineViewportStateCreateInfo = structs.VkPipelineViewportStateCreateInfo;
pub const VkPipelineRasterizationStateCreateInfo = structs.VkPipelineRasterizationStateCreateInfo;
pub const VkPipelineMultisampleStateCreateInfo = structs.VkPipelineMultisampleStateCreateInfo;
pub const VkPipelineColorBlendAttachmentState = structs.VkPipelineColorBlendAttachmentState;
pub const VkPipelineColorBlendStateCreateInfo = structs.VkPipelineColorBlendStateCreateInfo;
pub const VkPipelineDynamicStateCreateInfo = structs.VkPipelineDynamicStateCreateInfo;
pub const VkGraphicsPipelineCreateInfo = structs.VkGraphicsPipelineCreateInfo;
pub const VkSamplerCreateInfo = structs.VkSamplerCreateInfo;
pub const VkQueueFamilyProperties = structs.VkQueueFamilyProperties;
pub const VkMemoryType = structs.VkMemoryType;
pub const VkMemoryHeap = structs.VkMemoryHeap;
pub const VkPhysicalDeviceMemoryProperties = structs.VkPhysicalDeviceMemoryProperties;
pub const VkPipelineRasterizationDepthClipStateCreateInfoEXT = structs.VkPipelineRasterizationDepthClipStateCreateInfoEXT;
pub const VkExtensionProperties = structs.VkExtensionProperties;
pub const VkFormatProperties = capability_structs.VkFormatProperties;
pub const VkPhysicalDeviceFeatures = capability_structs.VkPhysicalDeviceFeatures;
pub const VkPhysicalDeviceFeatures2 = capability_structs.VkPhysicalDeviceFeatures2;
pub const VkPhysicalDeviceLimits = capability_structs.VkPhysicalDeviceLimits;
pub const VkPhysicalDeviceProperties = capability_structs.VkPhysicalDeviceProperties;
pub const VkPhysicalDeviceProperties2 = capability_structs.VkPhysicalDeviceProperties2;
pub const VkPhysicalDeviceSubgroupProperties = capability_structs.VkPhysicalDeviceSubgroupProperties;
pub const VkPhysicalDeviceSubgroupSizeControlProperties = capability_structs.VkPhysicalDeviceSubgroupSizeControlProperties;
pub const VkPhysicalDevice16BitStorageFeatures = capability_structs.VkPhysicalDevice16BitStorageFeatures;
pub const VkPhysicalDeviceVariablePointersFeatures = capability_structs.VkPhysicalDeviceVariablePointersFeatures;
pub const VkPhysicalDeviceSubgroupSizeControlFeatures = capability_structs.VkPhysicalDeviceSubgroupSizeControlFeatures;
pub const VkPhysicalDeviceVulkan12Features = capability_structs.VkPhysicalDeviceVulkan12Features;

pub const vkCreateInstance = functions.vkCreateInstance;
pub const vkDestroyInstance = functions.vkDestroyInstance;
pub const vkEnumerateInstanceExtensionProperties = functions.vkEnumerateInstanceExtensionProperties;
pub const vkEnumeratePhysicalDevices = functions.vkEnumeratePhysicalDevices;
pub const vkGetPhysicalDeviceQueueFamilyProperties = functions.vkGetPhysicalDeviceQueueFamilyProperties;
pub const vkCreateDevice = functions.vkCreateDevice;
pub const vkDestroyDevice = functions.vkDestroyDevice;
pub const vkGetDeviceQueue = functions.vkGetDeviceQueue;
pub const vkCreateCommandPool = functions.vkCreateCommandPool;
pub const vkDestroyCommandPool = functions.vkDestroyCommandPool;
pub const vkAllocateCommandBuffers = functions.vkAllocateCommandBuffers;
pub const vkFreeCommandBuffers = functions.vkFreeCommandBuffers;
pub const vkResetCommandPool = functions.vkResetCommandPool;
pub const vkCreateFence = functions.vkCreateFence;
pub const vkDestroyFence = functions.vkDestroyFence;
pub const vkResetFences = functions.vkResetFences;
pub const vkGetFenceStatus = functions.vkGetFenceStatus;
pub const vkWaitForFences = functions.vkWaitForFences;
pub const vkQueueSubmit = functions.vkQueueSubmit;
pub const vkQueueWaitIdle = functions.vkQueueWaitIdle;
pub const vkBeginCommandBuffer = functions.vkBeginCommandBuffer;
pub const vkEndCommandBuffer = functions.vkEndCommandBuffer;
pub const vkResetCommandBuffer = functions.vkResetCommandBuffer;
pub const vkCmdBindPipeline = functions.vkCmdBindPipeline;
pub const vkCmdDispatch = functions.vkCmdDispatch;
pub const vkCmdDispatchIndirect = functions.vkCmdDispatchIndirect;
pub const vkCmdCopyBuffer = functions.vkCmdCopyBuffer;
pub const vkCmdFillBuffer = functions.vkCmdFillBuffer;
pub const vkCmdCopyBufferToImage = functions.vkCmdCopyBufferToImage;
pub const vkCmdCopyImageToBuffer = functions.vkCmdCopyImageToBuffer;
pub const vkCmdCopyImage = functions.vkCmdCopyImage;
pub const vkCmdPipelineBarrier = functions.vkCmdPipelineBarrier;
pub const vkCreateBuffer = functions.vkCreateBuffer;
pub const vkDestroyBuffer = functions.vkDestroyBuffer;
pub const vkGetBufferMemoryRequirements = functions.vkGetBufferMemoryRequirements;
pub const vkCreateImage = functions.vkCreateImage;
pub const vkDestroyImage = functions.vkDestroyImage;
pub const vkGetImageMemoryRequirements = functions.vkGetImageMemoryRequirements;
pub const vkBindImageMemory = functions.vkBindImageMemory;
pub const vkCreateImageView = functions.vkCreateImageView;
pub const vkDestroyImageView = functions.vkDestroyImageView;
pub const vkAllocateMemory = functions.vkAllocateMemory;
pub const vkFreeMemory = functions.vkFreeMemory;
pub const vkBindBufferMemory = functions.vkBindBufferMemory;
pub const vkMapMemory = functions.vkMapMemory;
pub const vkUnmapMemory = functions.vkUnmapMemory;
pub const vkGetPhysicalDeviceMemoryProperties = functions.vkGetPhysicalDeviceMemoryProperties;
pub const vkGetPhysicalDeviceFeatures2 = functions.vkGetPhysicalDeviceFeatures2;
pub const vkGetPhysicalDeviceProperties2 = functions.vkGetPhysicalDeviceProperties2;
pub const vkGetPhysicalDeviceFormatProperties = functions.vkGetPhysicalDeviceFormatProperties;
pub const vkCreateShaderModule = functions.vkCreateShaderModule;
pub const vkCreatePipelineCache = functions.vkCreatePipelineCache;
pub const vkDestroyPipelineCache = functions.vkDestroyPipelineCache;
pub const vkGetPipelineCacheData = functions.vkGetPipelineCacheData;
pub const vkDestroyShaderModule = functions.vkDestroyShaderModule;
pub const vkCreateDescriptorSetLayout = functions.vkCreateDescriptorSetLayout;
pub const vkDestroyDescriptorSetLayout = functions.vkDestroyDescriptorSetLayout;
pub const vkCreateDescriptorPool = functions.vkCreateDescriptorPool;
pub const vkDestroyDescriptorPool = functions.vkDestroyDescriptorPool;
pub const vkAllocateDescriptorSets = functions.vkAllocateDescriptorSets;
pub const vkUpdateDescriptorSets = functions.vkUpdateDescriptorSets;
pub const vkCreatePipelineLayout = functions.vkCreatePipelineLayout;
pub const vkDestroyPipelineLayout = functions.vkDestroyPipelineLayout;
pub const vkCreateComputePipelines = functions.vkCreateComputePipelines;
pub const vkDestroyPipeline = functions.vkDestroyPipeline;
pub const vkCmdBindDescriptorSets = functions.vkCmdBindDescriptorSets;
pub const vkCreateQueryPool = functions.vkCreateQueryPool;
pub const vkDestroyQueryPool = functions.vkDestroyQueryPool;
pub const vkCmdWriteTimestamp = functions.vkCmdWriteTimestamp;
pub const vkCmdResetQueryPool = functions.vkCmdResetQueryPool;
pub const vkCmdCopyQueryPoolResults = functions.vkCmdCopyQueryPoolResults;
pub const vkGetQueryPoolResults = functions.vkGetQueryPoolResults;
pub const vkCmdBeginQuery = functions.vkCmdBeginQuery;
pub const vkCmdEndQuery = functions.vkCmdEndQuery;
pub const vkCreateRenderPass = functions.vkCreateRenderPass;
pub const vkDestroyRenderPass = functions.vkDestroyRenderPass;
pub const vkCreateFramebuffer = functions.vkCreateFramebuffer;
pub const vkDestroyFramebuffer = functions.vkDestroyFramebuffer;
pub const vkCreateGraphicsPipelines = functions.vkCreateGraphicsPipelines;
pub const vkCreateSampler = functions.vkCreateSampler;
pub const vkDestroySampler = functions.vkDestroySampler;
pub const vkCmdBeginRenderPass = functions.vkCmdBeginRenderPass;
pub const vkCmdEndRenderPass = functions.vkCmdEndRenderPass;
pub const vkCmdNextSubpass = functions.vkCmdNextSubpass;
pub const vkCmdSetViewport = functions.vkCmdSetViewport;
pub const vkCmdSetScissor = functions.vkCmdSetScissor;
pub const vkCmdBindVertexBuffers = functions.vkCmdBindVertexBuffers;
pub const vkCmdBindIndexBuffer = functions.vkCmdBindIndexBuffer;
pub const vkCmdDraw = functions.vkCmdDraw;
pub const vkCmdDrawIndexed = functions.vkCmdDrawIndexed;
pub const vkCmdDrawIndirect = functions.vkCmdDrawIndirect;
pub const vkCmdDrawIndexedIndirect = functions.vkCmdDrawIndexedIndirect;
pub const vkCmdExecuteCommands = functions.vkCmdExecuteCommands;
pub const vkCmdSetDepthBias = functions.vkCmdSetDepthBias;
pub const vkCmdSetStencilReference = functions.vkCmdSetStencilReference;
pub const vkEnumerateDeviceExtensionProperties = functions.vkEnumerateDeviceExtensionProperties;
pub const check_vk = functions.check_vk;
pub const map_vk_result = functions.map_vk_result;

pub const VK_SUCCESS = vk.VK_SUCCESS;
pub const VK_NOT_READY = vk.VK_NOT_READY;
pub const VK_TRUE = vk.VK_TRUE;
pub const VK_FALSE = vk.VK_FALSE;
pub const VK_API_VERSION_1_0: u32 = 0x00400000;
pub const VK_API_VERSION_1_1: u32 = 0x00401000;
pub const VK_API_VERSION_1_2: u32 = 0x00402000;

// --- VkStructureType values ---
pub const VK_STRUCTURE_TYPE_APPLICATION_INFO: i32 = 0;
pub const VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO: i32 = 1;
pub const VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO: i32 = 2;
pub const VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO: i32 = 3;
pub const VK_STRUCTURE_TYPE_SUBMIT_INFO: i32 = 4;
pub const VK_STRUCTURE_TYPE_FENCE_CREATE_INFO: i32 = 8;
pub const VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO: i32 = 11;
pub const VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO: i32 = 12;
pub const VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO: i32 = 14;
pub const VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO: i32 = 15;
pub const VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO: i32 = 16;
pub const VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO: i32 = 17;
// Canonical value is 5 per vulkan_core.h. Previously 17 (colliding with
// VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO). The AMDGPU driver ignored
// the mismatch in release builds because validation layers are off and
// VkMemoryAllocateInfo's first four fields (sType, pNext, allocationSize,
// memoryTypeIndex) line up with VkPipelineCacheCreateInfo. Every
// vkAllocateMemory call in the backend used this sType.
pub const VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO: i32 = 5;
pub const VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO: i32 = 18;
pub const VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO: i32 = 29;
pub const VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO: i32 = 30;
pub const VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO: i32 = 32;
pub const VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO: i32 = 33;
pub const VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO: i32 = 34;
pub const VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET: i32 = 35;
pub const VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO: i32 = 39;
pub const VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO: i32 = 40;
pub const VK_STRUCTURE_TYPE_COMMAND_BUFFER_INHERITANCE_INFO: i32 = 41;
pub const VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO: i32 = 42;
pub const VK_STRUCTURE_TYPE_MEMORY_BARRIER: i32 = 46;
pub const VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER: i32 = 44;
pub const VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER: i32 = 45;
pub const VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SUBGROUP_PROPERTIES: i32 = 1000094000;
pub const VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_16BIT_STORAGE_FEATURES: i32 = 1000083000;
pub const VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VARIABLE_POINTERS_FEATURES: i32 = 1000120000;
pub const VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SUBGROUP_SIZE_CONTROL_PROPERTIES: i32 = 1000225000;
pub const VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_REQUIRED_SUBGROUP_SIZE_CREATE_INFO: i32 = 1000225001;
pub const VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SUBGROUP_SIZE_CONTROL_FEATURES: i32 = 1000225002;
pub const VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2: i32 = 1000059000;
pub const VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2: i32 = 1000059001;
pub const VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES: i32 = 51;

// --- Queue and command bits ---
pub const VK_QUEUE_GRAPHICS_BIT: u32 = 0x00000001;
pub const VK_QUEUE_COMPUTE_BIT: u32 = 0x00000002;
pub const VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT: u32 = 0x00000002;
pub const VK_COMMAND_POOL_CREATE_TRANSIENT_BIT: u32 = 0x00000001;
pub const VK_COMMAND_BUFFER_LEVEL_PRIMARY: i32 = 0;
pub const VK_COMMAND_BUFFER_LEVEL_SECONDARY: i32 = 1;
pub const VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT: u32 = 0x00000001;
pub const VK_COMMAND_BUFFER_USAGE_RENDER_PASS_CONTINUE_BIT: u32 = 0x00000002;
pub const VK_PIPELINE_BIND_POINT_COMPUTE: i32 = 1;

// --- Shader and pipeline stage bits ---
pub const VK_SHADER_STAGE_VERTEX_BIT: u32 = 0x00000001;
pub const VK_SHADER_STAGE_FRAGMENT_BIT: u32 = 0x00000010;
pub const VK_SHADER_STAGE_COMPUTE_BIT: u32 = 0x00000020;
pub const VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT: u32 = 0x00000001;
pub const VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT: u32 = 0x00000002;
pub const VK_PIPELINE_STAGE_VERTEX_SHADER_BIT: u32 = 0x00000008;
pub const VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT: u32 = 0x00000400;
pub const VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT: u32 = 0x00000800;
pub const VK_PIPELINE_STAGE_TRANSFER_BIT: u32 = 0x00001000;
pub const VK_PIPELINE_STAGE_HOST_BIT: u32 = 0x00004000;
pub const VK_PIPELINE_BIND_POINT_GRAPHICS: i32 = 0;
pub const VK_SUBGROUP_FEATURE_BASIC_BIT: u32 = 0x00000001;
pub const VK_SUBGROUP_FEATURE_VOTE_BIT: u32 = 0x00000002;
pub const VK_SUBGROUP_FEATURE_ARITHMETIC_BIT: u32 = 0x00000004;
pub const VK_SUBGROUP_FEATURE_BALLOT_BIT: u32 = 0x00000008;
pub const VK_SUBGROUP_FEATURE_SHUFFLE_BIT: u32 = 0x00000010;
pub const VK_SUBGROUP_FEATURE_SHUFFLE_RELATIVE_BIT: u32 = 0x00000020;

// --- Query ---
pub const VK_QUERY_TYPE_TIMESTAMP: u32 = 2;
pub const VK_QUERY_RESULT_64_BIT: u32 = 0x00000001;
pub const VK_QUERY_RESULT_WAIT_BIT: u32 = 0x00000002;

// --- Buffer usage ---
pub const VK_BUFFER_USAGE_TRANSFER_SRC_BIT: u32 = 0x00000001;
pub const VK_BUFFER_USAGE_TRANSFER_DST_BIT: u32 = 0x00000002;
pub const VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT: u32 = 0x00000010;
pub const VK_BUFFER_USAGE_STORAGE_BUFFER_BIT: u32 = 0x00000020;
pub const VK_BUFFER_USAGE_INDEX_BUFFER_BIT: u32 = 0x00000040;
pub const VK_BUFFER_USAGE_VERTEX_BUFFER_BIT: u32 = 0x00000080;
pub const VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT: u32 = 0x00000100;

// --- Image usage ---
pub const VK_IMAGE_USAGE_TRANSFER_SRC_BIT: u32 = 0x00000001;
pub const VK_IMAGE_USAGE_TRANSFER_DST_BIT: u32 = 0x00000002;
pub const VK_IMAGE_USAGE_SAMPLED_BIT: u32 = 0x00000004;
pub const VK_IMAGE_USAGE_STORAGE_BIT: u32 = 0x00000008;
pub const VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT: u32 = 0x00000010;

// --- Memory and sharing ---
pub const VK_SHARING_MODE_EXCLUSIVE: i32 = 0;
pub const VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT: u32 = 0x00000001;
pub const VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT: u32 = 0x00000002;
pub const VK_MEMORY_PROPERTY_HOST_COHERENT_BIT: u32 = 0x00000004;
pub const VK_MEMORY_PROPERTY_HOST_CACHED_BIT: u32 = 0x00000008;

// --- Access flags ---
pub const VK_ACCESS_INDIRECT_COMMAND_READ_BIT: u32 = 0x00000001;
pub const VK_ACCESS_SHADER_READ_BIT: u32 = 0x00000020;
pub const VK_ACCESS_SHADER_WRITE_BIT: u32 = 0x00000040;
pub const VK_ACCESS_COLOR_ATTACHMENT_READ_BIT: u32 = 0x00000080;
pub const VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT: u32 = 0x00000100;
pub const VK_ACCESS_TRANSFER_READ_BIT: u32 = 0x00000800;
pub const VK_ACCESS_TRANSFER_WRITE_BIT: u32 = 0x00001000;
pub const VK_ACCESS_HOST_READ_BIT: u32 = 0x00002000;
pub const VK_ACCESS_HOST_WRITE_BIT: u32 = 0x00004000;
pub const VK_ACCESS_MEMORY_READ_BIT: u32 = 0x00008000;
pub const VK_ACCESS_MEMORY_WRITE_BIT: u32 = 0x00010000;

// --- Descriptor types ---
pub const VK_DESCRIPTOR_TYPE_SAMPLER: u32 = 0;
pub const VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE: u32 = 2;
pub const VK_DESCRIPTOR_TYPE_STORAGE_IMAGE: u32 = 3;
pub const VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER: u32 = 6;
pub const VK_DESCRIPTOR_TYPE_STORAGE_BUFFER: u32 = 7;
pub const VK_WHOLE_SIZE: u64 = std.math.maxInt(u64);
pub const VK_QUEUE_FAMILY_IGNORED: u32 = std.math.maxInt(u32);
pub const MAX_DESCRIPTOR_SETS: usize = 4;
pub const MAX_DESCRIPTOR_SETS_U32: u32 = 4;

// --- Image format and layout ---
pub const VK_IMAGE_TYPE_1D: u32 = 0;
pub const VK_IMAGE_TYPE_2D: u32 = 1;
pub const VK_IMAGE_TYPE_3D: u32 = 2;
pub const VK_IMAGE_VIEW_TYPE_1D: u32 = 0;
pub const VK_IMAGE_VIEW_TYPE_2D: u32 = 1;
pub const VK_IMAGE_VIEW_TYPE_3D: u32 = 2;
pub const VK_IMAGE_VIEW_TYPE_CUBE: u32 = 3;
pub const VK_IMAGE_VIEW_TYPE_1D_ARRAY: u32 = 4;
pub const VK_IMAGE_VIEW_TYPE_2D_ARRAY: u32 = 5;
pub const VK_IMAGE_VIEW_TYPE_CUBE_ARRAY: u32 = 6;
pub const VK_IMAGE_TILING_OPTIMAL: u32 = 0;
pub const VK_IMAGE_LAYOUT_UNDEFINED: u32 = 0;
pub const VK_IMAGE_LAYOUT_GENERAL: u32 = 1;
pub const VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL: u32 = 2;
pub const VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL: u32 = 6;
pub const VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL: u32 = 7;
pub const VK_IMAGE_LAYOUT_PRESENT_SRC_KHR: u32 = 1000001002;
pub const VK_IMAGE_ASPECT_COLOR_BIT: u32 = 0x00000001;
pub const VK_SAMPLE_COUNT_1_BIT: u32 = 0x00000001;
pub const VK_COMPONENT_SWIZZLE_IDENTITY: u32 = 0;
pub const VK_COMPONENT_SWIZZLE_ZERO: u32 = 1;
pub const VK_COMPONENT_SWIZZLE_ONE: u32 = 2;
pub const VK_COMPONENT_SWIZZLE_R: u32 = 3;
pub const VK_COMPONENT_SWIZZLE_G: u32 = 4;
pub const VK_COMPONENT_SWIZZLE_B: u32 = 5;
pub const VK_COMPONENT_SWIZZLE_A: u32 = 6;
pub const VK_SAMPLE_COUNT_2_BIT: u32 = 0x00000002;
pub const VK_SAMPLE_COUNT_4_BIT: u32 = 0x00000004;
pub const VK_SAMPLE_COUNT_8_BIT: u32 = 0x00000008;
pub const VK_SAMPLE_COUNT_16_BIT: u32 = 0x00000010;
pub const VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT: u32 = 0x00000010;
pub const VK_FORMAT_R8G8B8A8_UNORM: u32 = 37;

// --- VkResult error codes (canonical definitions in vulkan_errors.zig) ---
pub const VK_ERROR_TOO_MANY_OBJECTS = vulkan_errors.VK_ERROR_TOO_MANY_OBJECTS;
pub const VK_ERROR_FORMAT_NOT_SUPPORTED = vulkan_errors.VK_ERROR_FORMAT_NOT_SUPPORTED;
pub const VK_ERROR_FRAGMENTED_POOL = vulkan_errors.VK_ERROR_FRAGMENTED_POOL;
pub const VK_ERROR_UNKNOWN = vulkan_errors.VK_ERROR_UNKNOWN;

// --- Surface / present mode constants (shared with configure_surface) ---
pub const VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR: u32 = 0x00000001;
pub const VK_PRESENT_MODE_FIFO_KHR: u32 = 0x00000002;

// --- Default frame latency for surface configuration ---
pub const DEFAULT_SURFACE_MAX_FRAME_LATENCY: u32 = 2;

// --- Render pass constants ---
pub const VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL: u32 = 3;
pub const VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT: u32 = 0x00000100;
pub const VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT: u32 = 0x00000200;
pub const VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT: u32 = 0x00000200;
pub const VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT: u32 = 0x00000400;
pub const VK_ATTACHMENT_LOAD_OP_LOAD: u32 = 0;
pub const VK_ATTACHMENT_LOAD_OP_CLEAR: u32 = 1;
pub const VK_ATTACHMENT_LOAD_OP_DONT_CARE: u32 = 2;
pub const VK_ATTACHMENT_STORE_OP_STORE: u32 = 0;
pub const VK_ATTACHMENT_STORE_OP_DONT_CARE: u32 = 1;
pub const VK_SUBPASS_EXTERNAL: u32 = std.math.maxInt(u32);
pub const VK_DEPENDENCY_BY_REGION_BIT: u32 = 0x00000001;
pub const VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT: u32 = 0x00000080;
pub const VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT: u32 = 0x00002000;
pub const VK_PIPELINE_STAGE_ALL_COMMANDS_BIT: u32 = 0x00010000;
pub const VK_ACCESS_INPUT_ATTACHMENT_READ_BIT: u32 = 0x00000010;
pub const VK_IMAGE_USAGE_INPUT_ATTACHMENT_BIT: u32 = 0x00000080;
pub const VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL: u32 = 5;
pub const VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT: u32 = 10;

// --- Graphics pipeline structure type IDs ---
pub const VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO: i32 = 38;
pub const VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO: i32 = 37;
pub const VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO: i32 = 28;
pub const VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO: i32 = 19;
pub const VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO: i32 = 20;
pub const VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO: i32 = 22;
pub const VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO: i32 = 23;
pub const VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO: i32 = 24;
pub const VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO: i32 = 26;
pub const VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO: i32 = 27;
pub const VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO: i32 = 43;
pub const VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO: i32 = 31;
pub const VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO: i32 = 25;

// --- VK_EXT_depth_clip_enable ---
// Canonical value is 1000102001 per vulkan_core.h; 1000102000 is actually
// VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DEPTH_CLIP_ENABLE_FEATURES_EXT.
pub const VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_DEPTH_CLIP_STATE_CREATE_INFO_EXT: i32 = 1000102001;
pub const VK_EXT_DEPTH_CLIP_ENABLE_EXTENSION_NAME: [*:0]const u8 = "VK_EXT_depth_clip_enable";
pub const VK_EXT_SUBGROUP_SIZE_CONTROL_EXTENSION_NAME: [*:0]const u8 = "VK_EXT_subgroup_size_control";

// --- Graphics topology and polygon mode ---
pub const VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST: u32 = 3;
pub const VK_PRIMITIVE_TOPOLOGY_POINT_LIST: u32 = 0;
pub const VK_PRIMITIVE_TOPOLOGY_LINE_LIST: u32 = 1;
pub const VK_PRIMITIVE_TOPOLOGY_LINE_STRIP: u32 = 2;
pub const VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP: u32 = 4;
pub const VK_POLYGON_MODE_FILL: u32 = 0;
pub const VK_CULL_MODE_NONE: u32 = 0;
pub const VK_CULL_MODE_FRONT_BIT: u32 = 0x00000001;
pub const VK_CULL_MODE_BACK_BIT: u32 = 0x00000002;
pub const VK_FRONT_FACE_COUNTER_CLOCKWISE: u32 = 0;
pub const VK_FRONT_FACE_CLOCKWISE: u32 = 1;
pub const VK_LOGIC_OP_CLEAR: u32 = 0;

// --- Color blend ---
pub const VK_COLOR_COMPONENT_R_BIT: u32 = 0x00000001;
pub const VK_COLOR_COMPONENT_G_BIT: u32 = 0x00000002;
pub const VK_COLOR_COMPONENT_B_BIT: u32 = 0x00000004;
pub const VK_COLOR_COMPONENT_A_BIT: u32 = 0x00000008;
pub const VK_BLEND_FACTOR_ONE: u32 = 1;
pub const VK_BLEND_FACTOR_ZERO: u32 = 0;
pub const VK_BLEND_FACTOR_SRC_COLOR: u32 = 2;
pub const VK_BLEND_FACTOR_ONE_MINUS_SRC_COLOR: u32 = 3;
pub const VK_BLEND_FACTOR_SRC_ALPHA: u32 = 6;
pub const VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA: u32 = 7;
pub const VK_BLEND_FACTOR_DST_COLOR: u32 = 4;
pub const VK_BLEND_FACTOR_ONE_MINUS_DST_COLOR: u32 = 5;
pub const VK_BLEND_FACTOR_DST_ALPHA: u32 = 8;
pub const VK_BLEND_FACTOR_ONE_MINUS_DST_ALPHA: u32 = 9;
// Previously SRC_ALPHA_SATURATE=10, CONSTANT_COLOR=11, ONE_MINUS_CONSTANT_COLOR=12.
// Canonical vulkan_core.h: CONSTANT_COLOR=10, ONE_MINUS_CONSTANT_COLOR=11,
// CONSTANT_ALPHA=12, ONE_MINUS_CONSTANT_ALPHA=13, SRC_ALPHA_SATURATE=14.
// The three Doe values above permuted CONSTANT_COLOR / ONE_MINUS_CONSTANT_COLOR
// / SRC_ALPHA_SATURATE, so render pipelines requesting any of those blend
// factors would have received the wrong mode (ONE_MINUS_CONSTANT_COLOR for
// CONSTANT_COLOR, CONSTANT_ALPHA for ONE_MINUS_CONSTANT_COLOR, and
// CONSTANT_COLOR for SRC_ALPHA_SATURATE). Latent in the compute-only cohort.
pub const VK_BLEND_FACTOR_CONSTANT_COLOR: u32 = 10;
pub const VK_BLEND_FACTOR_ONE_MINUS_CONSTANT_COLOR: u32 = 11;
pub const VK_BLEND_FACTOR_SRC_ALPHA_SATURATE: u32 = 14;
pub const VK_BLEND_FACTOR_SRC1_COLOR: u32 = 15;
pub const VK_BLEND_FACTOR_ONE_MINUS_SRC1_COLOR: u32 = 16;
pub const VK_BLEND_FACTOR_SRC1_ALPHA: u32 = 17;
pub const VK_BLEND_FACTOR_ONE_MINUS_SRC1_ALPHA: u32 = 18;
pub const VK_BLEND_OP_ADD: u32 = 0;
pub const VK_BLEND_OP_SUBTRACT: u32 = 1;
pub const VK_BLEND_OP_REVERSE_SUBTRACT: u32 = 2;
pub const VK_BLEND_OP_MIN: u32 = 3;
pub const VK_BLEND_OP_MAX: u32 = 4;

// --- Dynamic state ---
// Canonical VkDynamicState enum values: VIEWPORT=0, SCISSOR=1, LINE_WIDTH=2,
// DEPTH_BIAS=3, BLEND_CONSTANTS=4, DEPTH_BOUNDS=5, STENCIL_COMPARE_MASK=6,
// STENCIL_WRITE_MASK=7, STENCIL_REFERENCE=8. Previously DEPTH_BIAS=6 (actually
// STENCIL_COMPARE_MASK) and STENCIL_REFERENCE=10 (out of range in core spec).
pub const VK_DYNAMIC_STATE_VIEWPORT: u32 = 0;
pub const VK_DYNAMIC_STATE_SCISSOR: u32 = 1;
pub const VK_DYNAMIC_STATE_DEPTH_BIAS: u32 = 3;
pub const VK_DYNAMIC_STATE_STENCIL_REFERENCE: u32 = 8;

// --- Stencil face flags ---
pub const VK_STENCIL_FACE_FRONT_AND_BACK: u32 = 0x00000003;

// --- Sampler constants ---
pub const VK_FILTER_NEAREST: u32 = 0;
pub const VK_SAMPLER_MIPMAP_MODE_NEAREST: u32 = 0;
pub const VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE: u32 = 2;
pub const VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK: u32 = 0;
pub const VK_COMPARE_OP_NEVER: u32 = 0;

// --- Index type ---
pub const VK_INDEX_TYPE_UINT16: u32 = 0;
pub const VK_INDEX_TYPE_UINT32: u32 = 1;

// --- Descriptor type for combined image sampler ---
pub const VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER: u32 = 1;

// --- Subpass contents ---
pub const VK_SUBPASS_CONTENTS_INLINE: u32 = 0;
pub const VK_SUBPASS_CONTENTS_SECONDARY_COMMAND_BUFFERS: u32 = 1;

// --- Indirect draw command strides ---
pub const VK_DRAW_INDIRECT_COMMAND_STRIDE: u32 = 16; // sizeof(VkDrawIndirectCommand)
pub const VK_DRAW_INDEXED_INDIRECT_COMMAND_STRIDE: u32 = 20; // sizeof(VkDrawIndexedIndirectCommand)
