import sys

with open("webgpu_ffi.zig", "r") as f:
    lines = f.readlines()

new_lines = []
for i, line in enumerate(lines):
    line_num = i + 1
    if 470 <= line_num <= 585:
        if line_num == 470:
            # Zig 0.15: explicit re-exports instead of pub usingnamespace
            sync_funcs = [
                "syncAfterSubmit", "submitEmpty", "submitCommandBuffers", "submitInternal",
                "flushQueue", "waitForQueue", "waitForQueueOnce", "shouldRetryQueueWait",
                "waitForQueueProcessEvents", "waitForQueueWaitAny", "readTimestampBuffer",
                "readTimestampBufferOnce", "shouldRetryTimestampMap", "processEventsUntil"
            ]
            for f in sync_funcs:
                new_lines.append(f'    pub const {f} = @import("core/queue/wgpu_ffi_sync.zig").{f};\n')
            surface_funcs = [
                "createSurface", "getSurfaceCapabilities", "freeSurfaceCapabilities",
                "configureSurface", "getCurrentSurfaceTexture", "presentSurface",
                "unconfigureSurface", "releaseSurface"
            ]
            for f in surface_funcs:
                new_lines.append(f'    pub const {f} = @import("full/surface/wgpu_ffi_surface.zig").{f};\n')
        continue
    if 608 <= line_num <= 804:
        continue
    new_lines.append(line)

with open("webgpu_ffi.zig", "w") as f:
    f.writelines(new_lines)
