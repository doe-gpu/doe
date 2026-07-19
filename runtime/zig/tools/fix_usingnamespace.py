import sys

with open("webgpu_ffi.zig", "r") as f:
    content = f.read()

sync_funcs = [
    "syncAfterSubmit", "submitEmpty", "submitCommandBuffers", "submitInternal",
    "flushQueue", "waitForQueue", "waitForQueueOnce", "shouldRetryQueueWait",
    "waitForQueueProcessEvents", "waitForQueueWaitAny", "readTimestampBuffer",
    "readTimestampBufferOnce", "shouldRetryTimestampMap", "processEventsUntil"
]

surface_funcs = [
    "createSurface", "getSurfaceCapabilities", "freeSurfaceCapabilities",
    "configureSurface", "getCurrentSurfaceTexture", "presentSurface",
    "unconfigureSurface", "releaseSurface"
]

sync_decl = "\n".join([f'    pub const {f} = @import("core/queue/wgpu_ffi_sync.zig").{f};' for f in sync_funcs])
surface_decl = "\n".join([f'    pub const {f} = @import("full/surface/wgpu_ffi_surface.zig").{f};' for f in surface_funcs])

content = content.replace('    pub usingnamespace @import("wgpu_ffi_sync.zig");', sync_decl)
content = content.replace('    pub usingnamespace @import("wgpu_ffi_surface.zig");', surface_decl)

with open("webgpu_ffi.zig", "w") as f:
    f.write(content)
