const immediates_external = @import("../command/doe_immediates_external_native.zig");
pub const doeNativeBindingCommandsSetImmediates = immediates_external.doeNativeBindingCommandsSetImmediates;
pub const doeNativeComputePassSetImmediates = immediates_external.doeNativeComputePassSetImmediates;
pub const doeNativeRenderPassSetImmediates = immediates_external.doeNativeRenderPassSetImmediates;
pub const doeNativeRenderBundleEncoderSetImmediates = immediates_external.doeNativeRenderBundleEncoderSetImmediates;

const external_texture_native = @import("../resource/doe_external_texture_native.zig");
pub const doeNativeDeviceImportExternalTexture = external_texture_native.doeNativeDeviceImportExternalTexture;
pub const doeNativeDeviceCreateExternalTexture = external_texture_native.doeNativeDeviceCreateExternalTexture;
pub const doeNativeExternalTextureAddRef = external_texture_native.doeNativeExternalTextureAddRef;
pub const doeNativeExternalTextureRelease = external_texture_native.doeNativeExternalTextureRelease;
pub const doeNativeExternalTextureDestroy = external_texture_native.doeNativeExternalTextureDestroy;
pub const doeNativeExternalTextureExpire = external_texture_native.doeNativeExternalTextureExpire;
pub const doeNativeExternalTextureRefresh = external_texture_native.doeNativeExternalTextureRefresh;
pub const doeNativeExternalTextureSetLabel = external_texture_native.doeNativeExternalTextureSetLabel;

const adapter_info = @import("../support/doe_adapter_info_native.zig");
const shader_compilation_info = @import("../shader/doe_shader_compilation_info_native.zig");

// Force both modules into the build so their exports are linked.
comptime {
    _ = adapter_info;
    _ = shader_compilation_info;
}

pub const doeNativeAdapterGetInfo = adapter_info.doeNativeAdapterGetInfo;
pub const doeNativeAdapterFreeInfo = adapter_info.doeNativeAdapterFreeInfo;
pub const doeNativeAdapterGetPciIdentity = adapter_info.doeNativeAdapterGetPciIdentity;

pub const doeNativeShaderModuleGetCompilationInfo = shader_compilation_info.doeNativeShaderModuleGetCompilationInfo;

pub const label_store = @import("../support/doe_label_store.zig");
pub const doeNativeObjectSetLabel = label_store.doeNativeObjectSetLabel;
pub const doeNativeObjectGetLabel = label_store.doeNativeObjectGetLabel;
pub const doeNativeObjectRemoveLabel = label_store.doeNativeObjectRemoveLabel;
