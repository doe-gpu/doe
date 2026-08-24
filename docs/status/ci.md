# CI status

GitHub-hosted push and pull-request checks cover deterministic workflow,
compiler, proof, package, and source-contract surfaces. Hardware-dependent AMD
Vulkan, drop-in, macOS browser, release, and claim-trend lanes remain explicit
manual workflows.

The AMD Vulkan smoke and release, Fawn matrix, and Windows D3D12 qualification
workflows require an exact full Git revision and an approved self-hosted runner
name. AMD Vulkan workflows run the migrated Zig build and gate sequence before
strict physical comparison. The Fawn matrix retains each workload attempt,
emits DoeLab learning records from raw evidence, keeps hardware-host suites
unsigned, and uploads evidence even when a lane fails. Windows D3D12 has a
separate manual workflow around the governed local D3D12 runner. These
qualification workflows seal collected files with SHA-256 and upload failures
as well as successful results; protected signing remains a separate
environment-owned step.

The machine-owned workflow inventory and trigger policy are checked by
`bench/tests/test_ci_workflow_surface.py`. Workflow files under
`.github/workflows/` are the source of truth.

The manual self-hosted Linux native-freshness job rebuilds and stages the
platform package, then clean-installs the wrapper and staged platform tarballs
under Node, a pinned Bun runtime, and a pinned Electron main-process runtime.
Each lane must execute its shipped first-kernel oracle without resolving a
workspace library before the workflow performs the stale-artifact rejection
check. The same job also requires the bounded repeated-process,
concurrent-process, and same-process lifecycle diagnostics for all three
runtimes. Electron uses an explicitly installed executable, creates no
renderer, and earns no browser evidence.

The normal package pull-request workflow runs the complete package contract,
smoke, and integration suite, checks the public tool surface, and inspects the
packed contents. It also verifies that the reviewed HoloScript Electron
diagnostic remains hash-bound to every tracked input and retains exact hashes
for its declared external capture inputs, native library, incumbent, and
zero-credit decision. The hosted checkout does not contain those external raw
bytes, so this deterministic contract check does not claim to revalidate them.
It replays no GPU work and grants no new evidence; the manual self-hosted
workflow owns runtime-specific execution. Hosted execution may skip native
checks when staged platform artifacts or physical GPUs are absent.
Repository-wide performance remains advisory rather than a promoted
JavaScript-runtime release requirement.
