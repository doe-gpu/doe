# CI status

GitHub-hosted push and pull-request checks cover deterministic workflow,
compiler, proof, package, and source-contract surfaces. Hardware-dependent AMD
Vulkan, drop-in, macOS browser, release, and claim-trend lanes remain explicit
manual workflows.

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
diagnostic remains hash-bound to its current plan, runner, application seam,
native library, incumbent, and zero-credit decision. This hosted check replays
no GPU work and grants no new evidence; the manual self-hosted workflow owns
runtime-specific execution. Hosted execution may skip native checks when staged
platform artifacts or physical GPUs are absent. Repository-wide performance
remains advisory rather than a promoted JavaScript-runtime release requirement.
