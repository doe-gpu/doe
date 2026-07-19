const model_commands = @import("../contracts/model/model_commands.zig");

pub const sample_quirks =
    \\[
    \\  {
    \\    "schemaVersion": 2,
    \\    "quirkId": "vulkan.intel.gen12.use_temp_buffer_compressed_copy",
    \\    "scope": "memory",
    \\    "match": {
    \\      "vendor": "intel",
    \\      "deviceFamily": "gen12",
    \\      "driverRange": ">=31.0.101,<32.0.0",
    \\      "api": "vulkan"
    \\    },
    \\    "action": {
    \\      "kind": "use_temporary_buffer",
    \\      "params": {
    \\        "bufferAlignmentBytes": 4
    \\      }
    \\    },
    \\    "safetyClass": "high",
    \\    "verificationMode": "lean_preferred",
    \\    "proofLevel": "guarded",
    \\    "provenance": {
    \\      "sourceRepo": "dawn",
    \\      "sourcePath": "src/dawn/native/Toggles.cpp",
    \\      "sourceCommit": "example",
    \\      "observedAt": "2026-02-17T00:00:00Z"
    \\    }
    \\  }
    \\]
;

pub const default_commands = [_]model_commands.Command{
    .{ .copy_buffer_to_texture = .{ .direction = .buffer_to_texture, .src = .{ .handle = 0x1000 }, .dst = .{ .handle = 0x2000 }, .bytes = 4096 } },
    .{ .upload = .{ .bytes = 4096, .align_bytes = 4 } },
    .{ .buffer_write = .{ .handle = 0x3000, .buffer_size = 16, .data = @constCast(&[_]u32{ 1, 2, 3, 4 }) } },
    .{ .kernel_dispatch = .{ .kernel = "bench/kernels/shader_compile_pipeline_stress.wgsl", .x = 2, .y = 1, .z = 1 } },
    .{ .barrier = .{ .dependency_count = 3 } },
};
