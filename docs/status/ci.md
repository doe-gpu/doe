# CI status

GitHub-hosted push and pull-request checks cover deterministic workflow,
compiler, proof, package, and source-contract surfaces. Hardware-dependent AMD
Vulkan, drop-in, macOS browser, release, and claim-trend lanes remain explicit
manual workflows.

The machine-owned workflow inventory and trigger policy are checked by
`bench/tests/test_ci_workflow_surface.py`. Workflow files under
`.github/workflows/` are the source of truth.

Open gap: the normal package pull-request workflow does not run the complete
package smoke and integration suite, and repository-wide performance remains
advisory rather than a promoted Node/Bun release requirement.
