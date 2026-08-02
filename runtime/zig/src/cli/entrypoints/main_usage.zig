pub fn printUsage(stdout: anytype) !void {
    try stdout.print(
        \\doe-zig-runtime --quirks <path> [--commands <path>] [--quirk-mode off|trace|active] [--vendor X] [--api X] [--family X] [--driver X.Y.Z] [--trace]
        \\ [--trace-jsonl <path>] [--trace-meta <path>] [--backend trace|native] [--backend-lane metal_doe_app|metal_doe_directional|metal_doe_comparable|metal_doe_release|metal_dawn_release|vulkan_doe_app|vulkan_doe_comparable|vulkan_doe_release|vulkan_dawn_release|d3d12_doe_app|d3d12_doe_directional|d3d12_doe_comparable|d3d12_doe_release|d3d12_dawn_release]
        \\ [--command-repeat N]
        \\ [--upload-buffer-usage copy-dst-copy-src|copy-dst] [--upload-submit-every N]
        \\ [--gpu-timestamp-mode auto|off|require]
        \\ [--queue-wait-mode process-events|wait-any]
        \\ [--webgpu-ffi-queue-wait-timeout-ns N]
        \\ [--queue-sync-mode per-command|deferred]
        \\ [--numeric-stability-execution-profile <id>]  (experimental)
        \\ [--kernel-root <path>]
        \\ [--replay <path>]
        \\ [--execute]
        \\ [--validate-output-oracles]
        \\commands file examples:
        \\  upload | buffer_upload
        \\  buffer_write | write_buffer | queue_write_buffer
        \\  copy_buffer_to_texture | texture_copy | copy_texture | copy_buffer_to_buffer | copy_texture_to_buffer | copy_texture_to_texture
        \\  dispatch | dispatch_workgroups | dispatch_invocations
        \\  dispatch_indirect
        \\  kernel_dispatch (requires a kernel string)
        \\  render_draw | draw | draw_call | draw_indexed
        \\  draw_indirect | draw_indexed_indirect | render_pass (render_draw-compatible payload fields)
        \\  sampler_create | create_sampler
        \\  sampler_destroy | destroy_sampler
        \\  texture_write | write_texture | queue_write_texture
        \\  texture_query | query_texture (optional expected width/height/depth/format/dimension/viewDimension/sampleCount/usage assertions)
        \\  texture_destroy | destroy_texture
        \\  surface_create | create_surface
        \\  surface_capabilities | get_surface_capabilities
        \\  surface_configure | configure_surface
        \\  surface_acquire | acquire_surface_texture
        \\  surface_present | present_surface
        \\  surface_unconfigure | unconfigure_surface
        \\  surface_release | release_surface
        \\  async_diagnostics | pipeline_async_diagnostics
        \\    optional fields: mode=pipeline_async|capability_introspection|resource_table_immediates|lifecycle_refcount|full, iterations>0
        \\  command can be expressed as "kind", "command", or "command_kind"
        \\  kernel can be expressed as "kernel" or "kernel_name"
        \\  kernel_dispatch repeatSynchronization can be dependent or independent; default is dependent.
        \\  kernel_dispatch output_oracle is verified only with --validate-output-oracles.
        \\--quirk-mode controls how quirks affect command execution.
        \\  off: no quirk processing; commands pass through unmodified.
        \\  trace: quirks are matched and traced, but commands are not modified for execution (default).
        \\  active: quirks are matched, traced, and command modifications are consumed by backends.
        \\If --quirks is omitted, the embedded sample profile is used.
        \\If --commands is omitted, the embedded sample command list is used.
        \\If --emit-normalized is set, emit canonicalized commands as ndjson and exit.
        \\Runtime output includes Lean-required flags when a matching quirk is selected.
        \\--trace prints machine-readable ndjson rows to stdout.
        \\--trace-jsonl writes machine-readable ndjson rows to a file.
        \\--trace-meta writes a deterministic run summary JSON artifact.
        \\--backend chooses execution backend when --execute is enabled.
        \\  trace: do not execute commands (trace-only mode)
        \\  native: execute through webgpu-native; dispatch/kernel_dispatch lower to compute passes, render_draw lowers to render-pass or render-bundle mode, and sampler/texture/surface/async diagnostics commands run through explicit WebGPU API contracts.
        \\--backend-lane selects backend selection policy lane when native execution is enabled.
        \\  metal_doe_app, metal_doe_directional, metal_doe_comparable, metal_doe_release, metal_dawn_release, vulkan_doe_app, vulkan_doe_comparable, vulkan_doe_release, vulkan_dawn_release, d3d12_doe_app, d3d12_doe_directional, d3d12_doe_comparable, d3d12_doe_release, d3d12_dawn_release
        \\--command-repeat replays the loaded command stream N times in one execution.
        \\  benchmark runners use this instead of materializing repeated JSON arrays.
        \\--upload-buffer-usage selects upload buffer usage when --execute is enabled.
        \\  copy-dst-copy-src: create upload buffers with CopyDst|CopySrc (default).
        \\  copy-dst: create upload buffers with CopyDst only.
        \\--upload-submit-every submits and waits after every N upload commands (default: 1).
        \\--gpu-timestamp-mode controls native GPU timestamp query usage for kernel dispatch timings.
        \\  auto: use GPU timestamps when feature/query artifacts are available (default).
        \\  off: disable GPU timestamp attempts and rely on non-timestamp operation timing sources.
        \\  require: fail command execution when timestamp capture is unavailable or invalid.
        \\--queue-wait-mode controls queue completion waiting strategy for native execution.
        \\  process-events: callback + process-events loop (default).
        \\  wait-any: callback + wgpuInstanceWaitAny wait path (fails explicitly when unsupported).
        \\--webgpu-ffi-queue-wait-timeout-ns controls the delegate WebGPU FFI queue wait guard.
        \\--queue-sync-mode controls when queue synchronization occurs.
        \\  per-command: waitForQueue after every submit (default).
        \\  deferred: skip per-submit waits; one final flush after the command loop.
        \\--numeric-stability-execution-profile selects the experimental
        \\  ordinary-execution numeric-governance profile from
        \\  config/numeric-stability-policy.json.
        \\  current built-in profiles:
        \\    numeric-stability/default-ordinary-execution-v1
        \\    numeric-stability/cautious-ordinary-execution-v1
        \\    numeric-stability/observe-only-ordinary-execution-v1
        \\--kernel-root provides a filesystem root for kernel lookup when kernel_dispatch is used.
        \\--replay validates current dispatch rows against a replay artifact path.
        \\
    , .{});
}
