# bench/gates

Blocking and advisory gates over benchmark / evidence artifacts.

The canonical entrypoint is
[`bench/runners/run_blocking_gates.py`](../runners/run_blocking_gates.py),
which loads gate policy from
[`config/gates.json`](../../config/gates.json) and invokes the gates
listed there. Each gate is a single Python module with a `main()` that
reads artifacts, evaluates policy, and exits with a typed status.

Gate classes:

- **Component intent** (`catscan_gate.py`) — block when recursive component
  charters omit required authority fields, name the wrong parent, contain
  broken contract or acceptance links, exceed the charter size ceiling, reuse
  a component identifier, or drift from the generated component index.
- **Correctness** (`check_correctness.py`, `claim_*.py`,
  `claim_discipline_gate.py`) — block release when claim language
  drifts from artifact reality.
  `claim_index_gate.py` protects the public README claim inventory:
  claim-indexed rows must name a claim sidecar and carry claimable/comparable
  status, while diagnostic and status-only rows stay out of public speed
  claims.
  `dawn_replacement_frontier_gate.py` protects the Dawn/Tint replacement
  frontier: every native/package/browser/compiler/conformance/drop-in row must
  stay evidence-linked, blocker codes must have exit criteria, and universal
  replacement language is blocked unless product rows are claim-allowed and
  evidence-release rows are covered or claimable.
  `claim_gate.py` also requires claimable Doe package rows to carry
  receipt-visible package telemetry, including native fast-path flags,
  write breakdowns, readback mode, the effective readback-path list,
  selected setup-timing scope, and the effective readback-path comparability
  obligation.
- **Compiler evidence** (`tint_compiler_evidence_gate.py`) — block
  Doe-vs-Tint compiler claims unless reports carry schema-valid corpus,
  toolchain, hash, validation, timing-phase, and comparability evidence.
- **Cerebras lane** (`cerebras_artifact_gate.py`,
  `doe_private_strategy_leak_gate.py`) — claim discipline + leak
  prevention for Doppler → Doe → Cerebras evidence.
- **Backend selection** (`backend_selection_gate.py`) — fail closed
  on capability drift between source and runtime.
- **Native backend coverage** (`check_native_backend_coverage_matrix.py`) —
  fail when Metal, Vulkan, or D3D12 coverage rows drift from the required
  native runtime classes.
- **Tool surfaces** (`tool_surface_gate.py`) — fail when the public/internal
  surface manifest drifts from shipped package exports or declared files.
- **Native package candidates** (`doe_gpu_native_release_candidate_gate.py`) —
  require one self-contained retained-tarball bundle for Node, Bun, and
  Electron; verify the declared source commit, package members, receipt
  digests, physical tuple, oracle, replay, lifecycle, and reliability joins.
- **Fixture regen** (`cluster_b_fixture_regen_gate.py`) — pin fixture
  freshness for cross-repo bring-up lanes.

Per `docs/process.md`:
- blocking in v0: schema, correctness, trace, verification
- advisory in v0: performance

Adding a new gate: extend `config/gates.json` with the gate name and
mode; add the module here; add a focused test in `bench/tests/`.
