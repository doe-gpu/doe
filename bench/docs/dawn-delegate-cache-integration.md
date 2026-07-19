# Dawn delegate MTLBinaryArchive-equivalent persistent cache — integration design

Audience: engineers scoping the follow-on work that makes Apple Metal Dawn-vs-Doe compute comparisons fair-*warm* instead of only fair-*cold*.

See also: `bench/docs/pipeline-cache-backend-audit.md` — the three-backend cache-direction audit that scopes this integration to Metal and names the parallel Vulkan + D3D12 cache-implementation program as a separate track. On Vulkan and D3D12 the asymmetry reverses: Dawn caches, Doe does not. The Metal shim in this doc does not apply there.

## Status

Scoping-only as of 2026-04-16. The fair-cold lane is the current default: both sides run under `--no-pipeline-cache`, both sides record `trace_meta.pipelineCache.state="disabled"`, and the comparability gate no longer auto-flags `pathAsymmetry: true` on cache-membership grounds for those workloads (see `bench/docs/metal-pipeline-cache-policy.md`). That lane is genuinely apples-to-apples but measures first-run compile cost on both sides, not steady-state cached-PSO performance.

The fair-warm lane requires wiring a Dawn-side persistent cache equivalent to Doe's `MTLBinaryArchive`. This document scopes that work without introducing placeholder Zig code (CLAUDE.md non-negotiable #2 forbids runtime-behavior placeholders in the Zig execution path).

## Vendored Dawn build verification (2026-04-16)

A binary audit of the vendored `bench/vendor/dawn/out/Release/libwebgpu_dawn.so` blocks the most straightforward integration path and **materially reshapes the landing plan below**.

What the verification found:

- The vendored shared library exports the `wgpu*` C ABI only. `nm -D --defined-only` returns 507 dynamic symbols and every `T` (global text) entry is a `wgpu*` function.
- `dawn::platform::Platform::GetCachingInterface()` **is in the binary** (`nm --defined-only` finds `_ZN4dawn8platform8Platform19GetCachingInterfaceEv`) but as a lowercase `t` (local text) — linked in but not exported.
- No `dawn::*` or `dawn_*` C++ symbols are exported dynamically. `DAWN_NATIVE_EXPORT` is defined to expand to `__attribute__((visibility("default")))` only when both `DAWN_NATIVE_IMPLEMENTATION` and `DAWN_NATIVE_SHARED_LIBRARY` are set at build time (`bench/vendor/dawn/include/dawn/native/dawn_native_export.h:31-47`). The vendored `args.gn` is minimal (`is_debug = false` and nothing else), so the default monolithic build is what landed: C ABI only, C++ hidden.
- `bench/vendor/dawn/include/dawn/native/DawnNative.h:117-121` declares `DawnInstanceDescriptor.platform = dawn::platform::Platform*` as the chained-descriptor hook for injecting a custom platform into `wgpuCreateInstance`. The API surface is correct and documented; the binary simply does not expose the C++ symbols required to construct a subclass against it.
- `dawn/dawn_proc.h` exposes `dawnProcSetProcs(const DawnProcTable* procs)` as the only C ABI escape hatch, but that is a proctable-dispatch mechanism for redirecting `wgpu*` calls, not a platform-injection hook. It cannot be used to install a `CachingInterface`.

What this blocks:

- The original Push 4 plan assumed a C++ shim could link against `libwebgpu_dawn.so` as-is, subclass `dawn::platform::Platform` and `dawn::platform::CachingInterface`, and install the resulting object via `DawnInstanceDescriptor.platform`. With the current vendored build, that shim will not link: the base-class vtable slots, constructor, and destructor symbols are not exported.

What unblocks it:

- **Option A — Rebuild Dawn with exported C++ visibility.** Regenerate `bench/vendor/dawn/out/Release/libwebgpu_dawn.so` with both `DAWN_NATIVE_IMPLEMENTATION` and `DAWN_NATIVE_SHARED_LIBRARY` set, or add the visibility flag globally. The shim in Doe's tree then links and works as designed. Dawn build config change only; no source patch required.
- **Option B — Build Dawn's component form.** Dawn's GN config supports producing separate `libdawn_native` / `libdawn_platform` libraries (the configuration Chrome uses internally). The shim links against those directly. Also a Dawn build config change, no source patch.
- **Option C — Patch Dawn source to expose a C ABI cache hook in-tree.** Add an `extern "C" void dawnInstallProcessCachingInterface(const char* cache_dir, size_t len)` entry point somewhere in Dawn's native source that constructs the platform+cache objects internally and threads them through to instance creation. Doe's Zig side then calls a single C function through `wgpu_loader`-style FFI with no C++ linkage. Source patch, not build config. Requires maintaining the patch across Dawn updates.

The three options differ in maintenance burden:

- **A** and **B** are reversible without patching Dawn source, but whoever rebuilds Dawn in this repo (or downstream of it) has to remember the flag. A build-config contract is needed in `bench/vendor/dawn/args.gn` and in whatever tool rebuilds that tree.
- **C** survives Dawn rebuilds but needs a stable patch-apply step in the vendor-refresh workflow.

This verification step was run on Linux against the committed vendored build. The Mac-host vendored build (if one exists under `bench/vendor/dawn/out/Release/` on `mac.lan`) must be re-verified separately — it may have different `args.gn` and may already expose the C++ surface.

### Linux rebuild attempt — libstdc++ 10 atomic.wait gap

Following the verification above, a Linux rebuild was attempted under `bench/vendor/dawn/out/ComponentTest/` with:

```
is_debug = false
is_component_build = true
dawn_complete_static_libs = false
use_custom_libcxx = false
dawn_use_swiftshader = false
angle_enable_swiftshader = false
```

`gn gen` succeeded (999 targets generated). Targeted build of `src/dawn/platform:shared` reached 254/258 steps before `src/dawn/platform/WorkerThread.cpp` failed to compile:

```
WorkerThread.cpp:72: error: no member named 'wait' in 'std::atomic<bool>'
WorkerThread.cpp:82: error: no member named 'notify_all' in 'std::atomic<bool>'
```

`std::atomic<T>::wait` and `notify_all` are C++20 features, but Dawn's bundled Debian bullseye sysroot under `bench/vendor/dawn/build/linux/debian_bullseye_amd64-sysroot/usr/include/c++/10/atomic` ships libstdc++ 10, which does not implement them (added in libstdc++ 11). The bundled clang 23 supports `-std=c++20` but is relying on the sysroot's stdlib, so the feature does not land.

Two fix paths, both Linux-executable:

- **Option A.1 — flip `use_custom_libcxx = true`.** Switches Dawn to compile and link against Chromium's in-tree libc++, which implements `atomic::wait`. Adds ~1200 compile steps (full libc++/libc++abi build) but produces a self-contained `libdawn_platform.so` / `libdawn_native.so` with exported C++ symbols. This is the recommended Linux unblocker; Dawn's documentation warns the resulting library can only be consumed by code that also uses Chromium's libc++ ABI, which is acceptable for a benchmark fixture.
- **Option A.2 — source patch in vendored Dawn.** Replace the three-line atomic.wait / notify_all usage in `src/dawn/platform/WorkerThread.cpp` with the pre-C++20 condvar+mutex pattern. Smaller disk/time cost but adds a patch-apply step to the vendor-refresh workflow, and the patch has to be re-applied on every Dawn upgrade.

Either path leaves the integration plan's Step 0 "rebuild with exposed visibility" requirement satisfied on Linux. The Mac-host vendored build on `mac.lan` may already use Chromium's libc++ by default (Apple toolchain overrides differ), so it may not hit this issue at all — verify there separately.

### Linux rebuild attempt — successful libdawn_platform.so proof-of-build (2026-04-16)

Option A.1 landed the full Linux rebuild. With the args.gn above plus `use_custom_libcxx = true`, `ninja -C bench/vendor/dawn/out/ComponentTest src/dawn/platform:shared` completed 1451/1451 steps in ~13 minutes on the current host and produced:

```
bench/vendor/dawn/out/ComponentTest/libdawn_platform.so  (37,648 bytes)
```

`nm -D --defined-only` on the resulting `.so` confirms every C++ symbol the shim needs is exported as `T` (global text):

- `dawn::platform::Platform::Platform()` (default constructor)
- `dawn::platform::Platform::~Platform()` (virtual destructor)
- `dawn::platform::Platform::GetCachingInterface()` (base implementation — returns nullptr; the shim overrides this)
- `dawn::platform::CachingInterface::CachingInterface()` / `~CachingInterface()` (default constructor / virtual destructor)
- all other `dawn::platform::Platform` member functions that the shim needs to leave default-implemented

This proves the integration plan's Step 0 is achievable on this Linux host with the args.gn shown above. The build directory is under `bench/vendor/dawn/out/ComponentTest/` (gitignored via `bench/vendor/` wildcard) so this is a disposable artifact, not a tracked rebuild.

Remaining Step 0 work before Step 1 (the C++ shim) can proceed:

- ~~make the rebuild contract durable~~ **Done 2026-04-16**: `bench/tools/regenerate_dawn_component_build.py` is the tracked regenerator. `python3 bench/tools/regenerate_dawn_component_build.py` writes the canonical `args.gn` and runs `gn gen`; `--build` runs `ninja` for `libdawn_platform.so` and `libdawn_native.so`; `--verify` checks the required `dawn::platform::*` and `dawn::native::*` symbols are exported. `--summary-out` emits a JSON summary for audit.
- ~~confirm `libdawn_native.so` similarly links under the same args~~ **Done 2026-04-16**: `ninja src/dawn/native:shared` completed 1158/1158 steps and produced `libdawn_native.so` (11,915,168 bytes) with `dawn::native::DawnInstanceDescriptor::DawnInstanceDescriptor()`, `dawn::native::Instance::Instance(...)`, `dawn::native::Instance::SetPlatformForTesting(dawn::platform::Platform*)`, `dawn::native::InstanceProcessEvents(...)`, and the rest of the C++ native surface exported as `T`. The libc++ rebuild from the platform build is cached, so the native delta was ~1158 steps rather than 1417+1200.
- decide the build-product location contract: `ComponentTest/` is fine for a verification fixture, but the shim's linker search path needs a stable directory once Step 1 lands

### Shim proof-of-build (2026-04-16)

A compile-check skeleton at `bench/vendor/dawn/out/ComponentTest/dawn_cache_shim_skeleton.cpp` (gitignored, local-only) proves that Step 1's shim surface compiles and links against the ComponentTest Dawn build. The skeleton:

- subclasses `dawn::platform::CachingInterface` with no-op `LoadData` / `StoreData` stubs (real file-backed I/O is deferred to the tracked Step 1 landing)
- subclasses `dawn::platform::Platform` with a `GetCachingInterface()` override that returns the cache singleton
- exposes four `extern "C"` entry points with `__attribute__((visibility("default")))`: `doe_dawn_install_persistent_cache(const char*, size_t)`, `doe_dawn_teardown_persistent_cache()`, `doe_dawn_get_platform_ptr()`, `doe_dawn_cache_entry_count()`

Compile command (from repo root):

```
bench/vendor/dawn/third_party/llvm-build/Release+Asserts/bin/clang++ \
  -std=c++20 -fPIC -fvisibility=hidden \
  -I bench/vendor/dawn/include \
  -I bench/vendor/dawn/out/ComponentTest/gen/include \
  -c bench/vendor/dawn/out/ComponentTest/dawn_cache_shim_skeleton.cpp \
  -o bench/vendor/dawn/out/ComponentTest/dawn_cache_shim_skeleton.o
```

Link command:

```
bench/vendor/dawn/third_party/llvm-build/Release+Asserts/bin/clang++ \
  -shared -fPIC \
  -L bench/vendor/dawn/out/ComponentTest \
  -Wl,-rpath,\$ORIGIN \
  bench/vendor/dawn/out/ComponentTest/dawn_cache_shim_skeleton.o \
  -ldawn_platform \
  -o bench/vendor/dawn/out/ComponentTest/libdoe_dawn_cache_shim.so
```

Verification:

- `nm -D --defined-only libdoe_dawn_cache_shim.so | grep doe_dawn` shows all four C ABI functions exported as `T`.
- `nm -D --undefined-only libdoe_dawn_cache_shim.so | c++filt | grep dawn::platform::` shows the expected undefined references to `dawn::platform::Platform::*` and `dawn::platform::CachingInterface::*`; these are supplied at runtime by `libdawn_platform.so`.

Two toolchain notes carried by this step:

- the skeleton must be compiled with `-I bench/vendor/dawn/out/ComponentTest/gen/include` because `dawn/platform/DawnPlatform.h` transitively includes `webgpu/webgpu.h`, which in turn includes `dawn/webgpu.h` — a generated header that only exists in the build's `gen/include/` tree
- `-fvisibility=hidden` is recommended for the shim so only the `doe_dawn_*` C ABI is exported; each entry point needs an explicit `__attribute__((visibility("default")))` to survive the default-hidden policy

This proves Step 1's C++ shim is buildable today on this Linux host against the ComponentTest Dawn build. The skeleton is intentionally NOT installed into `runtime/zig/src/backend/dawn/`: CLAUDE.md non-negotiable #2 forbids runtime-behavior placeholders in the execution path, and the skeleton's `LoadData` / `StoreData` are no-ops. The tracked Step 1 landing implements real file-backed persistence and wires the shim into `dawn_cache.zig` + `cli/runtime_cli.zig` in a single push.

## What Doe has today

- `runtime/zig/src/backend/metal/metal_pipeline_cache.zig` opens an `MTLBinaryArchive` at `metal_native_runtime.zig:380-402` when `HAS_PIPELINE_CACHE` (macOS 11+) and the CLI flag `--no-pipeline-cache` is not set
- the archive is backed by a committed benchmark fixture at `bench/kernels/doe_pipeline_archive.metallib` with manifest at `bench/kernels/doe_pipeline_archive.manifest`
- `--no-pipeline-cache` (see `runtime/zig/src/cli/runtime_cli_args.zig:205-206`) disables cache init for a given run; the runtime records `trace_meta.pipelineCache.state="disabled" reason="cli-flag"`
- `set_metal_pipeline_cache_disabled` in `runtime/zig/src/backend/backend_runtime_telemetry.zig` is a cross-platform-safe wrapper that is a no-op on non-Mac, preserving the `cli/ -> backend/metal/` import fence

## What Dawn needs

Dawn's persistent cache surface is `dawn::platform::CachingInterface` in `bench/vendor/dawn/include/dawn/platform/DawnPlatform.h:48-70`:

```cpp
class CachingInterface {
 public:
  virtual size_t LoadData(const void* key, size_t keySize,
                          void* valueOut, size_t valueSize) = 0;
  virtual void StoreData(const void* key, size_t keySize,
                         const void* value, size_t valueSize) = 0;
};
```

The caching interface is reached through `dawn::platform::Platform::GetCachingInterface()` (line 187-189 of the same header). Dawn's Metal backend serializes MTLLibrary / pipeline state objects through this interface when it is wired into the Dawn instance at creation time. `dawn::native::PerformIdleTasks()` (in `DawnNative.h:361-363`) is the hook Dawn uses to flush cache writes when idle.

The interface is a **C++ virtual contract**, not a C ABI. `bench/vendor/dawn/include/webgpu/webgpu.h` (the standard C header Doe loads via `runtime/zig/src/core/abi/wgpu_loader.zig`) does not expose cache installation. Adding the cache lane therefore requires a small in-tree C++ shim that links against `libdawn_native` and exposes a C ABI the Zig side can call.

## Integration plan

### 0. Dawn build-config prerequisite (new — added from the 2026-04-16 verification)

One of the three options above (A: rebuild Dawn with exported C++ visibility, B: build Dawn's component form, or C: patch Dawn source to expose a C ABI cache hook) must land before any of the Doe-side steps below can succeed. Recommended default: **Option A**, because it is the smallest Dawn-side change, requires no source patch, and brings the vendored build into line with Dawn's intended shared-library configuration.

Concrete work for Option A:
- update `bench/vendor/dawn/out/Release/args.gn` to set the shared-library flags that expose `DAWN_NATIVE_EXPORT` symbols (exact flag naming is determined by Dawn's `build/config`; likely `is_component_build = true` or `dawn_complete_static_libs = false`)
- document the rebuild contract in `bench/vendor/dawn/README.md` (or equivalent) so future Dawn refreshes do not drop the flag
- verify with `nm -D --defined-only bench/vendor/dawn/out/Release/libwebgpu_dawn.so | grep -E "dawn::(native|platform)"` that at least `dawn::platform::Platform::GetCachingInterface`, `CachingInterface::~CachingInterface`, and the `Platform::Platform`/`~Platform` constructors/destructors are exported as `T` symbols

Until this prerequisite lands, steps 1-7 below cannot proceed.

### 1. C++ shim — `runtime/zig/src/backend/dawn/dawn_cache_shim.cpp` (new)

Compiled against Dawn's headers and linked against `libdawn_native`. Provides:

```c
// C ABI exposed to Zig FFI
extern "C" int doe_dawn_install_caching_interface(const char* cache_dir_utf8,
                                                   size_t cache_dir_len);
extern "C" void doe_dawn_perform_idle_tasks_all_devices(void);
extern "C" int doe_dawn_caching_supported(void);  // 1 if libdawn_native was linked
```

Internally:
- subclasses `dawn::platform::Platform` with a `GetCachingInterface()` that returns
- subclasses `dawn::platform::CachingInterface` with `LoadData` / `StoreData` backed by an on-disk key-value store rooted at `cache_dir_utf8`
- sets the platform on the `dawn::native::Instance` before any device is created
- provides a safe idle-flush entry point so Zig-side teardown can drive `dawn::native::PerformIdleTasks()` deterministically before benchmarking ends

Key-value storage choice: start with a directory of files named by SHA-256 of the cache key, with the value blob as file contents. This is intentionally simpler than Dawn's own chromium-side disk cache, which uses LevelDB. The value blob format is opaque to Doe; Dawn decides its contents.

### 2. Zig FFI — `runtime/zig/src/backend/dawn/dawn_cache.zig` (new)

Cross-platform surface that mirrors the shape of `backend/metal/metal_pipeline_cache.zig`:

```zig
pub fn setProcessDawnCacheDir(path: ?[]const u8) void;  // null disables
pub fn isProcessDawnCacheEnabled() bool;
pub fn dawnCachingSupported() bool;  // links/detects libdawn_native
pub fn performIdleTasksForAllDevices() void;
```

Implementation on non-Mac OR non-Dawn builds: returns `false` from `dawnCachingSupported()`, makes `setProcessDawnCacheDir` a no-op, and records that state so `trace_meta.dawnPipelineCache.state="disabled" reason="platform-unsupported"` (or `"dawn-delegate-not-in-build"`) rather than silently succeeding.

This module must respect the existing `cli/ -> backend/` import fence. The shim is called only from `runtime/zig/src/backend/backend_runtime_telemetry.zig` via a new cross-platform wrapper (parallel to `set_metal_pipeline_cache_disabled`), which `cli/runtime_cli.zig` invokes pre-`ExecutionContext.init`.

### 3. CLI + options — `runtime/zig/src/cli/runtime_cli_args.zig`

Add to `RunOptions`:

```zig
dawn_cache_dir: ?[]const u8 = null,
```

Parse `--dawn-cache-dir <path>`. CLI must reject the flag with a typed unsupported error (CLAUDE.md non-negotiable #4) when `dawnCachingSupported() == false`, naming the taxonomy: "dawn-delegate-cache-unavailable; either link libdawn_native into this build (non-Linux hosts) or omit --dawn-cache-dir to use the fair-cold lane".

### 4. Trace schema — `runtime/zig/src/runtime/trace/trace.zig`

Add nested `dawnPipelineCache` to `TraceRunSummary`, matching the shape of `pipelineCache`:

```
dawnPipelineCache: {
  state: "enabled" | "disabled",
  reason: "default" | "cli-flag" | "dawn-delegate-not-in-build" | "platform-unsupported",
  entryCount: integer,    // number of on-disk cache keys at end of run
}
```

State derivation:
- `enabled` only when the Dawn delegate lane is active, `--dawn-cache-dir` is set, and the shim confirms it installed the caching interface
- `disabled` otherwise, with the reason code distinguishing the three failure modes

### 5. Executor templates — `bench/native_compare_modules/executor_registry.py`

Add `dawn_delegate_metal_cache` (and the Doe-side `doe_direct_metal_cache` already exists from the G18 push). Both templates pass their respective cache flags, and their pairing is the fair-warm Dawn-vs-Doe lane:

```
doe_direct_metal_cache           -> doe-zig-runtime ... --backend-lane metal_doe_comparable (no --no-pipeline-cache)
dawn_delegate_metal_cache        -> doe-zig-runtime ... --backend-lane metal_dawn_release --dawn-cache-dir <path>
```

Run-receipts from both sides must carry their respective `pipelineCache.state="enabled"` / `dawnPipelineCache.state="enabled"` for the compare to accept the lane as fair-warm.

### 6. Comparability resolver — `bench/native_compare_modules/run_artifact.py`

`_resolve_metal_cache_asymmetry` currently consults only `pipelineCache.state`. Extend it to also consult `dawnPipelineCache.state`: if both are `enabled` (and their cache keyspace overlap is confirmed), then the workload is fair-warm and the Metal cache-membership auto-flag is skipped. If only one is enabled, the auto-flag still fires as today.

Cache keyspace overlap is the honest tricky part: Doe's archive enumerates named kernels; Dawn's cache keys are opaque blobs. The simplest check is "both sides had at least one cache hit on this workload" — pulled from `dawnPipelineCache.entryCount` growing across an intentional warmup pass.

### 7. Documentation

- `bench/docs/metal-pipeline-cache-policy.md` — extend with a "fair-warm lane" section
- `bench/README.md` — add the fair-warm Metal lane to the "First benchmark matrix" once the shim lands and a real run produces a claim-grade artifact on Mac
- `docs/status.md` / current shard — one entry per landing push (shim, Zig FFI, CLI flag, trace schema, executor templates, resolver change)

## Scoping by platform

| Step | Linux-executable | Mac-only |
| --- | --- | --- |
| 1. C++ shim | yes (compile check only; no dawn linkage on Linux unless Dawn is built for Linux too) | yes (real validation) |
| 2. Zig FFI surface | yes (cross-platform-safe no-op on non-Mac) | yes |
| 3. CLI flag plumbing | yes | yes |
| 4. Trace schema addition | yes (Linux builds emit `state="disabled" reason="platform-unsupported"`) | yes |
| 5. Executor templates | yes (dry-run / list-promoted only) | yes (live execution) |
| 6. Resolver change | yes (unit tests with synthetic artifacts) | yes (real artifacts) |
| 7. Docs | yes | yes |

Linux can land 1-4 and 6-7 as compile-green contract. Step 5's live execution and the full end-to-end "fair-warm lane produces claimable compute workload" validation are Mac-only.

## Risks and open questions

- **Dawn build shape.** ~~The repo ships Dawn as vendored headers under `bench/vendor/dawn/include/`. Does the local Dawn build produce `libdawn_native` with the `dawn::platform::Platform` hook exported?~~ **Answered 2026-04-16 by binary audit**: no, the vendored `libwebgpu_dawn.so` exports only the `wgpu*` C ABI and hides all C++ symbols including the `dawn::platform::Platform` vtable slots needed for a `CachingInterface` shim. Step 0 above names the three options that unblock the integration; Option A (rebuild Dawn with exposed C++ visibility) is the recommended default.
- **Cache keyspace overlap verification.** Doe's manifest is named; Dawn's cache keys are hashed. The resolver cannot confirm "both caches served the same kernel" — only "both caches were exercised". Downgrading that to "both caches warm within this workload" via warmup-pass entry-count growth is the pragmatic bound.
- **Idle-flush ordering.** Dawn flushes cache writes from `PerformIdleTasks()`. The shim must drive this before process exit so the cache directory is not half-written. The Zig side's new `performIdleTasksForAllDevices()` must be invoked deterministically (e.g., from `cli/runtime_cli.zig` before `execution_context.deinit`).
- **Mac-only validation scope.** The entire end-to-end validation pipeline (lane runs, artifacts with `dawnPipelineCache.state="enabled"`, resolver skips auto-flag, compare report accepts fair-warm claim) requires Mac hardware. The 7 cache-asymmetric compute workloads currently held diagnostic pending Mac re-run become the first target set once the shim lands.
- **Schema and obligation drift.** Adding `dawnPipelineCache` to `TraceRunSummary` is a runtime-visible behavior change; schema and migration notes must land in the same change per CLAUDE.md #9. Obligation entries (if any) for the fair-warm lane must be added to the comparability obligation schema under the same push.

## Not-yet-landed contract summary

Nothing in the Doe runtime, bench harness, or docs changes as a result of this design doc in isolation. The only deliverable here is this document; it exists so the next Dawn-cache push has an explicit map instead of re-deriving the integration surface from scratch.
