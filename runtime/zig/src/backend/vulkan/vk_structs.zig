const vk = @import("vulkan_types.zig");

pub const VkApplicationInfo = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    pApplicationName: ?[*:0]const u8,
    applicationVersion: u32,
    pEngineName: ?[*:0]const u8,
    engineVersion: u32,
    apiVersion: u32,
};

pub const VkInstanceCreateInfo = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    flags: vk.VkFlags,
    pApplicationInfo: ?*const VkApplicationInfo,
    enabledLayerCount: u32,
    ppEnabledLayerNames: ?[*]const [*:0]const u8,
    enabledExtensionCount: u32,
    ppEnabledExtensionNames: ?[*]const [*:0]const u8,
};

pub const VkDeviceQueueCreateInfo = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    flags: vk.VkFlags,
    queueFamilyIndex: u32,
    queueCount: u32,
    pQueuePriorities: [*]const f32,
};

pub const VkDeviceCreateInfo = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    flags: vk.VkFlags,
    queueCreateInfoCount: u32,
    pQueueCreateInfos: [*]const VkDeviceQueueCreateInfo,
    enabledLayerCount: u32,
    ppEnabledLayerNames: ?[*]const [*:0]const u8,
    enabledExtensionCount: u32,
    ppEnabledExtensionNames: ?[*]const [*:0]const u8,
    pEnabledFeatures: ?*const anyopaque,
};

pub const VkCommandPoolCreateInfo = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    flags: vk.VkFlags,
    queueFamilyIndex: u32,
};

pub const VkCommandBufferAllocateInfo = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    commandPool: vk.VkCommandPool,
    level: i32,
    commandBufferCount: u32,
};

pub const VkFenceCreateInfo = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    flags: vk.VkFlags,
};

pub const VkBufferCreateInfo = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    flags: vk.VkFlags,
    size: vk.VkDeviceSize,
    usage: vk.VkFlags,
    sharingMode: i32,
    queueFamilyIndexCount: u32,
    pQueueFamilyIndices: ?[*]const u32,
};

pub const VkExtent3D = extern struct {
    width: u32,
    height: u32,
    depth: u32,
};

pub const VkImageCreateInfo = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    flags: vk.VkFlags,
    imageType: u32,
    format: u32,
    extent: VkExtent3D,
    mipLevels: u32,
    arrayLayers: u32,
    samples: u32,
    tiling: u32,
    usage: vk.VkFlags,
    sharingMode: i32,
    queueFamilyIndexCount: u32,
    pQueueFamilyIndices: ?[*]const u32,
    initialLayout: u32,
};

pub const VkMemoryAllocateInfo = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    allocationSize: vk.VkDeviceSize,
    memoryTypeIndex: u32,
};

pub const VkMemoryRequirements = extern struct {
    size: vk.VkDeviceSize,
    alignment: vk.VkDeviceSize,
    memoryTypeBits: u32,
};

pub const VkCommandBufferInheritanceInfo = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    renderPass: vk.VkRenderPass,
    subpass: u32,
    framebuffer: vk.VkFramebuffer,
    occlusionQueryEnable: vk.VkBool32,
    queryFlags: vk.VkFlags,
    pipelineStatistics: vk.VkFlags,
};

pub const VkCommandBufferBeginInfo = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    flags: vk.VkFlags,
    pInheritanceInfo: ?*const VkCommandBufferInheritanceInfo,
};

pub const VkSubmitInfo = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    waitSemaphoreCount: u32,
    pWaitSemaphores: ?[*]const u64,
    pWaitDstStageMask: ?[*]const vk.VkFlags,
    commandBufferCount: u32,
    pCommandBuffers: [*]const vk.VkCommandBuffer,
    signalSemaphoreCount: u32,
    pSignalSemaphores: ?[*]const u64,
};

pub const VkShaderModuleCreateInfo = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    flags: vk.VkFlags,
    codeSize: usize,
    pCode: [*]const u32,
};

pub const VkPipelineCacheCreateInfo = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    flags: vk.VkFlags,
    initialDataSize: usize,
    pInitialData: ?*const anyopaque,
};

pub const VkPipelineLayoutCreateInfo = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    flags: vk.VkFlags,
    setLayoutCount: u32,
    pSetLayouts: ?[*]const u64,
    pushConstantRangeCount: u32,
    pPushConstantRanges: ?*const anyopaque,
};

pub const VkPipelineShaderStageCreateInfo = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    flags: vk.VkFlags,
    stage: vk.VkFlags,
    module: vk.VkShaderModule,
    pName: ?[*:0]const u8,
    pSpecializationInfo: ?*const anyopaque,
};

pub const VkPipelineShaderStageRequiredSubgroupSizeCreateInfo = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    requiredSubgroupSize: u32,
};

pub const VkDescriptorSetLayoutBinding = extern struct {
    binding: u32,
    descriptorType: u32,
    descriptorCount: u32,
    stageFlags: vk.VkFlags,
    pImmutableSamplers: ?*const anyopaque,
};

pub const VkDescriptorSetLayoutCreateInfo = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    flags: vk.VkFlags,
    bindingCount: u32,
    pBindings: ?[*]const VkDescriptorSetLayoutBinding,
};

pub const VkDescriptorPoolSize = extern struct {
    type: u32,
    descriptorCount: u32,
};

pub const VkDescriptorPoolCreateInfo = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    flags: vk.VkFlags,
    maxSets: u32,
    poolSizeCount: u32,
    pPoolSizes: ?[*]const VkDescriptorPoolSize,
};

pub const VkDescriptorSetAllocateInfo = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    descriptorPool: vk.VkDescriptorPool,
    descriptorSetCount: u32,
    pSetLayouts: [*]const vk.VkDescriptorSetLayout,
};

pub const VkDescriptorBufferInfo = extern struct {
    buffer: vk.VkBuffer,
    offset: vk.VkDeviceSize,
    range: vk.VkDeviceSize,
};

pub const VkDescriptorImageInfo = extern struct {
    sampler: u64,
    imageView: vk.VkImageView,
    imageLayout: u32,
};

pub const VkWriteDescriptorSet = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    dstSet: vk.VkDescriptorSet,
    dstBinding: u32,
    dstArrayElement: u32,
    descriptorCount: u32,
    descriptorType: u32,
    pImageInfo: ?*const anyopaque,
    pBufferInfo: ?[*]const VkDescriptorBufferInfo,
    pTexelBufferView: ?*const anyopaque,
};

pub const VkComputePipelineCreateInfo = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    flags: vk.VkFlags,
    stage: VkPipelineShaderStageCreateInfo,
    layout: vk.VkPipelineLayout,
    basePipelineHandle: vk.VkPipeline,
    basePipelineIndex: i32,
};

pub const VkBufferCopy = extern struct {
    srcOffset: vk.VkDeviceSize,
    dstOffset: vk.VkDeviceSize,
    size: vk.VkDeviceSize,
};

pub const VkQueryPoolCreateInfo = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    flags: vk.VkFlags,
    queryType: u32,
    queryCount: u32,
    pipelineStatistics: vk.VkFlags,
};

pub const VkComponentMapping = extern struct {
    r: u32,
    g: u32,
    b: u32,
    a: u32,
};

pub const VkImageSubresourceRange = extern struct {
    aspectMask: vk.VkFlags,
    baseMipLevel: u32,
    levelCount: u32,
    baseArrayLayer: u32,
    layerCount: u32,
};

pub const VkImageViewCreateInfo = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    flags: vk.VkFlags,
    image: vk.VkImage,
    viewType: u32,
    format: u32,
    components: VkComponentMapping,
    subresourceRange: VkImageSubresourceRange,
};

pub const VkImageSubresourceLayers = extern struct {
    aspectMask: vk.VkFlags,
    mipLevel: u32,
    baseArrayLayer: u32,
    layerCount: u32,
};

pub const VkOffset3D = extern struct {
    x: i32,
    y: i32,
    z: i32,
};

pub const VkBufferImageCopy = extern struct {
    bufferOffset: vk.VkDeviceSize,
    bufferRowLength: u32,
    bufferImageHeight: u32,
    imageSubresource: VkImageSubresourceLayers,
    imageOffset: VkOffset3D,
    imageExtent: VkExtent3D,
};

pub const VkImageCopy = extern struct {
    srcSubresource: VkImageSubresourceLayers,
    srcOffset: VkOffset3D,
    dstSubresource: VkImageSubresourceLayers,
    dstOffset: VkOffset3D,
    extent: VkExtent3D,
};

pub const VkMemoryBarrier = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    srcAccessMask: vk.VkFlags,
    dstAccessMask: vk.VkFlags,
};

pub const VkBufferMemoryBarrier = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    srcAccessMask: vk.VkFlags,
    dstAccessMask: vk.VkFlags,
    srcQueueFamilyIndex: u32,
    dstQueueFamilyIndex: u32,
    buffer: vk.VkBuffer,
    offset: vk.VkDeviceSize,
    size: vk.VkDeviceSize,
};

pub const VkImageMemoryBarrier = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    srcAccessMask: vk.VkFlags,
    dstAccessMask: vk.VkFlags,
    oldLayout: u32,
    newLayout: u32,
    srcQueueFamilyIndex: u32,
    dstQueueFamilyIndex: u32,
    image: vk.VkImage,
    subresourceRange: VkImageSubresourceRange,
};

pub const VkAttachmentDescription = extern struct {
    flags: vk.VkFlags,
    format: u32,
    samples: u32,
    loadOp: u32,
    storeOp: u32,
    stencilLoadOp: u32,
    stencilStoreOp: u32,
    initialLayout: u32,
    finalLayout: u32,
};

pub const VkAttachmentReference = extern struct {
    attachment: u32,
    layout: u32,
};

pub const VkSubpassDescription = extern struct {
    flags: vk.VkFlags,
    pipelineBindPoint: i32,
    inputAttachmentCount: u32,
    pInputAttachments: ?[*]const VkAttachmentReference,
    colorAttachmentCount: u32,
    pColorAttachments: ?[*]const VkAttachmentReference,
    pResolveAttachments: ?[*]const VkAttachmentReference,
    pDepthStencilAttachment: ?*const VkAttachmentReference,
    preserveAttachmentCount: u32,
    pPreserveAttachments: ?[*]const u32,
};

pub const VkSubpassDependency = extern struct {
    srcSubpass: u32,
    dstSubpass: u32,
    srcStageMask: vk.VkFlags,
    dstStageMask: vk.VkFlags,
    srcAccessMask: vk.VkFlags,
    dstAccessMask: vk.VkFlags,
    dependencyFlags: vk.VkFlags,
};

pub const VkRenderPassCreateInfo = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    flags: vk.VkFlags,
    attachmentCount: u32,
    pAttachments: ?[*]const VkAttachmentDescription,
    subpassCount: u32,
    pSubpasses: ?[*]const VkSubpassDescription,
    dependencyCount: u32,
    pDependencies: ?[*]const VkSubpassDependency,
};

pub const VkFramebufferCreateInfo = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    flags: vk.VkFlags,
    renderPass: vk.VkRenderPass,
    attachmentCount: u32,
    pAttachments: ?[*]const vk.VkImageView,
    width: u32,
    height: u32,
    layers: u32,
};

pub const VkOffset2D = extern struct {
    x: i32,
    y: i32,
};

pub const VkExtent2D = extern struct {
    width: u32,
    height: u32,
};

pub const VkRect2D = extern struct {
    offset: VkOffset2D,
    extent: VkExtent2D,
};

pub const VkClearColorValue = extern union {
    float32: [4]f32,
    int32: [4]i32,
    uint32: [4]u32,
};

pub const VkClearDepthStencilValue = extern struct {
    depth: f32,
    stencil: u32,
};

pub const VkClearValue = extern union {
    color: VkClearColorValue,
    depthStencil: VkClearDepthStencilValue,
};

pub const VkRenderPassBeginInfo = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    renderPass: vk.VkRenderPass,
    framebuffer: vk.VkFramebuffer,
    renderArea: VkRect2D,
    clearValueCount: u32,
    pClearValues: ?[*]const VkClearValue,
};

pub const VkViewport = extern struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    minDepth: f32,
    maxDepth: f32,
};

pub const VkVertexInputBindingDescription = extern struct {
    binding: u32,
    stride: u32,
    inputRate: u32,
};

pub const VkVertexInputAttributeDescription = extern struct {
    location: u32,
    binding: u32,
    format: u32,
    offset: u32,
};

pub const VkPipelineVertexInputStateCreateInfo = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    flags: vk.VkFlags,
    vertexBindingDescriptionCount: u32,
    pVertexBindingDescriptions: ?[*]const VkVertexInputBindingDescription,
    vertexAttributeDescriptionCount: u32,
    pVertexAttributeDescriptions: ?[*]const VkVertexInputAttributeDescription,
};

pub const VkPipelineInputAssemblyStateCreateInfo = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    flags: vk.VkFlags,
    topology: u32,
    primitiveRestartEnable: vk.VkBool32,
};

pub const VkPipelineViewportStateCreateInfo = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    flags: vk.VkFlags,
    viewportCount: u32,
    pViewports: ?[*]const VkViewport,
    scissorCount: u32,
    pScissors: ?[*]const VkRect2D,
};

pub const VkPipelineRasterizationStateCreateInfo = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    flags: vk.VkFlags,
    depthClampEnable: vk.VkBool32,
    rasterizerDiscardEnable: vk.VkBool32,
    polygonMode: u32,
    cullMode: vk.VkFlags,
    frontFace: u32,
    depthBiasEnable: vk.VkBool32,
    depthBiasConstantFactor: f32,
    depthBiasClamp: f32,
    depthBiasSlopeFactor: f32,
    lineWidth: f32,
};

pub const VkPipelineMultisampleStateCreateInfo = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    flags: vk.VkFlags,
    rasterizationSamples: u32,
    sampleShadingEnable: vk.VkBool32,
    minSampleShading: f32,
    pSampleMask: ?*const u32,
    alphaToCoverageEnable: vk.VkBool32,
    alphaToOneEnable: vk.VkBool32,
};

pub const VkPipelineColorBlendAttachmentState = extern struct {
    blendEnable: vk.VkBool32,
    srcColorBlendFactor: u32,
    dstColorBlendFactor: u32,
    colorBlendOp: u32,
    srcAlphaBlendFactor: u32,
    dstAlphaBlendFactor: u32,
    alphaBlendOp: u32,
    colorWriteMask: vk.VkFlags,
};

pub const VkPipelineColorBlendStateCreateInfo = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    flags: vk.VkFlags,
    logicOpEnable: vk.VkBool32,
    logicOp: u32,
    attachmentCount: u32,
    pAttachments: ?[*]const VkPipelineColorBlendAttachmentState,
    blendConstants: [4]f32,
};

pub const VkPipelineDynamicStateCreateInfo = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    flags: vk.VkFlags,
    dynamicStateCount: u32,
    pDynamicStates: ?[*]const u32,
};

pub const VkGraphicsPipelineCreateInfo = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    flags: vk.VkFlags,
    stageCount: u32,
    pStages: [*]const VkPipelineShaderStageCreateInfo,
    pVertexInputState: *const VkPipelineVertexInputStateCreateInfo,
    pInputAssemblyState: *const VkPipelineInputAssemblyStateCreateInfo,
    pTessellationState: ?*const anyopaque,
    pViewportState: *const VkPipelineViewportStateCreateInfo,
    pRasterizationState: *const VkPipelineRasterizationStateCreateInfo,
    pMultisampleState: *const VkPipelineMultisampleStateCreateInfo,
    pDepthStencilState: ?*const anyopaque,
    pColorBlendState: *const VkPipelineColorBlendStateCreateInfo,
    pDynamicState: ?*const VkPipelineDynamicStateCreateInfo,
    layout: vk.VkPipelineLayout,
    renderPass: vk.VkRenderPass,
    subpass: u32,
    basePipelineHandle: vk.VkPipeline,
    basePipelineIndex: i32,
};

pub const VkSamplerCreateInfo = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    flags: vk.VkFlags,
    magFilter: u32,
    minFilter: u32,
    mipmapMode: u32,
    addressModeU: u32,
    addressModeV: u32,
    addressModeW: u32,
    mipLodBias: f32,
    anisotropyEnable: vk.VkBool32,
    maxAnisotropy: f32,
    compareEnable: vk.VkBool32,
    compareOp: u32,
    minLod: f32,
    maxLod: f32,
    borderColor: u32,
    unnormalizedCoordinates: vk.VkBool32,
};

pub const VkQueueFamilyProperties = extern struct {
    queueFlags: vk.VkFlags,
    queueCount: u32,
    timestampValidBits: u32,
    minImageTransferGranularity: VkExtent3D,
};

pub const VkMemoryType = extern struct {
    propertyFlags: vk.VkFlags,
    heapIndex: u32,
};

pub const VkMemoryHeap = extern struct {
    size: vk.VkDeviceSize,
    flags: vk.VkFlags,
};

pub const VkPhysicalDeviceMemoryProperties = extern struct {
    memoryTypeCount: u32,
    memoryTypes: [32]VkMemoryType,
    memoryHeapCount: u32,
    memoryHeaps: [16]VkMemoryHeap,
};

// VK_EXT_depth_clip_enable: extension struct chained into rasterization state
// to explicitly disable depth clipping (unclippedDepth in WebGPU).
pub const VkPipelineRasterizationDepthClipStateCreateInfoEXT = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    flags: vk.VkFlags,
    depthClipEnable: vk.VkBool32,
};

pub const VkExtensionProperties = extern struct {
    extensionName: [256]u8,
    specVersion: u32,
};
