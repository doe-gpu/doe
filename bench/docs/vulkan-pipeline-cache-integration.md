# Doe Vulkan persistent pipeline cache — integration design

Audience: engineers implementing Doe-side persistent `VkPipelineCache` to close the cache asymmetry against Dawn on AMD Vulkan and any future Vulkan board.

## Status

Implemented and refactored to provider-instance ownership as of 2026-08-23.
Doe passes a real cache handle to compute and graphics pipeline creation when
the selected Vulkan provider successfully opens its cache. This document
retains the design rationale and records the landed ownership shape.

See also:

- `bench/docs/pipeline-cache-backend-audit.md` -- the three-backend audit that identified this asymmetry
- `bench/docs/dawn-delegate-cache-integration.md` -- the parallel Metal-only Dawn-cache shim work
- `bench/docs/compute-matvec-regression-trace.md` -- the matvec regression that is most likely caused by the missing Vulkan cache

## What Doe has today

- `runtime/zig/src/backend/vulkan/vk_pipeline_cache.zig` is an *in-memory* per-device state cache of descriptor-set / pipeline / layout handles. It is not a persistent `VkPipelineCache` and not disk-backed.
- `vk_pipeline_cache_persistent.zig` owns the real per-provider Vulkan cache,
  including disk persistence and warmup telemetry.
- Compute and graphics pipeline creation consume that instance handle.
- `--no-pipeline-cache` and an explicit mutable cache directory flow through
  `ExecutionSession` construction for both Doe Metal and Doe Vulkan.
- `trace_meta.pipelineCache.{state,reason,warmupCount,warmupNs}` is populated
  through provider telemetry.

## Vulkan API surface required

From `bench/vendor/dawn/include/vulkan/vulkan_core.h` (and the equivalents in Doe's vendored Vulkan headers):

```c
VkResult vkCreatePipelineCache(
    VkDevice device,
    const VkPipelineCacheCreateInfo* pCreateInfo,
    const VkAllocationCallbacks* pAllocator,
    VkPipelineCache* pPipelineCache);

void vkDestroyPipelineCache(
    VkDevice device,
    VkPipelineCache pipelineCache,
    const VkAllocationCallbacks* pAllocator);

VkResult vkGetPipelineCacheData(
    VkDevice device,
    VkPipelineCache pipelineCache,
    size_t* pDataSize,
    void* pData);

VkResult vkMergePipelineCaches(
    VkDevice device,
    VkPipelineCache dstCache,
    uint32_t srcCacheCount,
    const VkPipelineCache* pSrcCaches);

typedef struct VkPipelineCacheCreateInfo {
    VkStructureType sType;              // VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO = 17
    const void* pNext;
    VkPipelineCacheCreateFlags flags;
    size_t initialDataSize;
    const void* pInitialData;
} VkPipelineCacheCreateInfo;

typedef struct VkPipelineCacheHeaderVersionOne {
    uint32_t headerSize;                // must be 32
    VkPipelineCacheHeaderVersion headerVersion;
    uint32_t vendorID;
    uint32_t deviceID;
    uint8_t pipelineCacheUUID[VK_UUID_SIZE];
} VkPipelineCacheHeaderVersionOne;
```

`VkMergePipelineCaches` is optional; the first implementation can ignore it.

## Integration plan

### 1. FFI additions -- `runtime/zig/src/backend/vulkan/vk_functions.zig` + `vk_constants.zig`

Add:

- extern declarations for `vkCreatePipelineCache`, `vkDestroyPipelineCache`, `vkGetPipelineCacheData`
- `VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO: i32 = 17` in `vk_constants.zig`
- `VkPipelineCacheCreateInfo` struct in the existing `vulkan_types.zig` or a structs module

Must be used by the new module below; the current Zig convention is that every FFI declaration is referenced somewhere in the backend tree.

### 2. Persistent cache module -- `runtime/zig/src/backend/vulkan/vk_pipeline_cache_persistent.zig`

The landed module is provider-instance owned:

```zig
pub const VulkanPipelineCacheState = enum { disabled, enabled, enabled_reloaded };
pub const VulkanPipelineCache = struct {
    pub fn init(configuration: PipelineCacheConfiguration) VulkanPipelineCache;
    pub fn create(self: *VulkanPipelineCache, device: c.VkDevice) !void;
    pub fn deinit(self: *VulkanPipelineCache, device: c.VkDevice) void;
    pub fn flush(self: *VulkanPipelineCache, device: c.VkDevice) void;
    pub fn handleForPipelineCreation(self: *const VulkanPipelineCache) c.VkPipelineCache;
    pub fn active(self: *const VulkanPipelineCache) bool;
    pub fn warmupTelemetry(self: *const VulkanPipelineCache) WarmupTelemetry;
};
```

Key behaviors:

- `create` reads the existing blob when configured and lets the Vulkan driver
  accept or discard incompatible initial data as required by the API.
- `handleForPipelineCreation` returns the instance handle when active, else
  `VK_NULL_U64`.
- `deinit` serializes via `vkGetPipelineCacheData`, writes atomically
  (`*.tmp` + `rename`), and destroys the cache before its device.

Telemetry mirrors Metal's shape so the existing reader side (`bench/native_compare_modules/run_artifact.py::_pipeline_cache_telemetry`) works without changes.

### 3. Provider-owned configuration and telemetry

The process-global wrapper design was superseded on 2026-08-23.
`ExecutionSession` now passes `PipelineCacheConfiguration` through
`composition/backend_factory.zig`; `NativeVulkanRuntime` owns the cache handle,
device binding, persistence path, enablement, and warmup telemetry. This keeps
the import fence while allowing independent concurrent provider sessions.

### 4. Pipeline-creation callsite changes

Compute and render pipeline creation read
`self.pipeline_cache.handleForPipelineCreation()` from the selected runtime.

This is the one-line runtime change that actually activates the cache. Everything else is infrastructure.

### 5. CLI + options

`--no-pipeline-cache` is parsed by the CLI and becomes construction-time
provider configuration through `ExecutionSession`.

Optional new flag: `--pipeline-cache-dir <path>` to override the default cache location. Default location is `${XDG_CACHE_HOME:-~/.cache}/doe/pipeline-cache/vulkan/`.

### 6. Trace schema

The existing `trace_meta.pipelineCache.{state, reason}` fields are Metal-specific today. Two options:

a. **Extend the same field to cover whichever backend is active.** When the active backend is Vulkan, populate `pipelineCache.state` from the Vulkan module. Cleaner schema (single field set) but requires the reader to understand the backend context.

b. **Add a parallel `vulkanPipelineCache` object.** More schema fields but each backend owns its own.

Recommended: option (a), with an added `backend` field inside `pipelineCache` (`"metal" | "vulkan" | "d3d12" | null`) so readers can disambiguate. Keep the same `{state, reason, warmupCount, warmupNs}` payload shape.

### 7. Executor registry updates

Mirror the Metal pattern from the G18 push: introduce `doe_direct_vulkan_no_cache` and `doe_direct_vulkan_cache` executor templates in `bench/native_compare_modules/executor_registry.py`. The default `doe_direct_vulkan` can pick either; recommend making the cache-enabled variant the default (matches user-code behavior) and keeping the no-cache variant as an explicit opt-in for cache-contribution lanes.

### 8. Tests

- `bench/tests/test_vulkan_pipeline_cache_state.py` -- mirrors `test_pipeline_cache_state.py`. Unit tests the reader, resolver, and executor template presence.
- `runtime/zig/src/backend/vulkan/vk_pipeline_cache_persistent_test.zig` -- inline Zig test for the header validation and round-trip serialize/deserialize.

### 9. Documentation

- Update `bench/docs/pipeline-cache-backend-audit.md` "Follow-up queue" item 1 to reference this doc and the landed implementation.
- Extend `bench/docs/pipeline-cache-contribution-lane.md` "Per-backend applicability" table row for AMD Vulkan from "No -- Doe does not yet implement persistent VkPipelineCache" to "Yes, via `doe_direct_vulkan_no_cache` / `doe_direct_vulkan_cache`".
- Add a status shard entry.

## Scoping by platform

| Step | Linux-executable | Other hosts |
| --- | --- | --- |
| 1. FFI additions | yes (compile-green) | same |
| 2. Persistent cache module | yes (compile-green; behavior-inert until wired) | same |
| 3. Cross-platform wrapper | yes | same |
| 4. Pipeline-creation callsite | yes (Linux has Vulkan hardware here) | same |
| 5. CLI + options | yes | same |
| 6. Trace schema | yes | same |
| 7. Executor templates | yes | same |
| 8. Tests | yes (Zig inline + Python unit) | same |
| 9. Docs | yes | same |

Unlike the Metal Dawn shim (which needs Mac hardware for end-to-end validation), the Doe Vulkan cache can be fully implemented and validated on Linux with AMD Vulkan hardware (which this host has).

## Expected outcome for "Doe faster than Dawn across all boards"

Confirming directionally only; actual delta will be measured against current artifacts post-landing:

- **Cold-first-compile workloads** (`pipeline_compile_stress`, workloads that create pipelines in the timed loop): Doe gains parity or slight advantage because both sides now cache. Today Doe is winning on `pipeline_compile_stress` by +48% despite no cache -- that delta should widen.
- **Steady-state compute workloads** (`compute_matvec_*`, `compute_workgroup_*`): Doe's first-iteration per-process cost drops. Whether the steady-state `p50` improves depends on whether the matvec regression is in the shader code itself or in the cold-compile cost. Hypothesis 1 in `compute-matvec-regression-trace.md` predicts matvec improves materially under cache; if it does not, the regression is shader-side and needs the RGP follow-up.
- **Upload workloads**: no effect (they don't create pipelines).

## Risks

- **Cache blob UUID mismatch across driver upgrades.** Vulkan spec requires the header UUID to match exactly; an older cache blob from a previous driver version is invalid. The implementation must reject mismatched blobs silently and recreate the cache from scratch, not fail the device init.
- **Thread safety.** `vkCreatePipelineCache` and pipeline creation calls are externally synchronized. A process-level cache accessed from multiple devices would need a mutex, or the cache must be per-device. Recommended: per-device cache, one per `ZigVulkanBackend.init`. The "process-level" framing in the Metal module should be reviewed before mirroring -- Metal's `MTLBinaryArchive` has different threading semantics.
- **Disk I/O in hot path.** The atomic write at `destroy_process_pipeline_cache` can be deferred to an explicit flush hook so it does not slow benchmark teardown.
- **Cache blob size growth.** Pipeline caches can grow unbounded in a long-running process. The first implementation can ignore this; a cap + LRU eviction is a follow-up.

## Follow-up queue

1. Land Steps 1-4 as a single focused push -- minimal plumbing + the one-line callsite change. Validates that Doe-side Vulkan caching works end-to-end on AMD Vulkan hardware.
2. Land Steps 5-7 in a follow-up push -- CLI flag parity, trace schema, executor templates.
3. Re-run the matvec compare and the `pipeline_compile_stress` compare; document the deltas.
4. Parallel track: implement D3D12 `CachedPSO` persistence with the same design shape (once a Windows host is in rotation).
