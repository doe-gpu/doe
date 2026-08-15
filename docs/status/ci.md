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
under both Node and a pinned Bun runtime. Each lane must execute its shipped
first-kernel oracle without resolving a workspace library before the workflow
performs the stale-artifact rejection check. The same job also requires the
bounded repeated-process and concurrent-process reliability diagnostics for
both runtimes.

The normal package pull-request workflow runs the complete package contract,
smoke, and integration suite, checks the public tool surface, and inspects the
packed contents. Hosted execution may skip native checks when staged platform
artifacts or physical GPUs are absent; the manual self-hosted workflow owns
those runtime-specific gates. Repository-wide performance remains advisory
rather than a promoted Node/Bun release requirement.
