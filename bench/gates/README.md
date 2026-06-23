# bench/gates

Blocking and advisory gates over benchmark / evidence artifacts.

The canonical entrypoint is
[`bench/runners/run_blocking_gates.py`](../runners/run_blocking_gates.py),
which loads gate policy from
[`config/gates.json`](../../config/gates.json) and invokes the gates
listed there. Each gate is a single Python module with a `main()` that
reads artifacts, evaluates policy, and exits with a typed status.

Gate classes:

- **Correctness** (`check_correctness.py`, `claim_*.py`,
  `claim_discipline_gate.py`) — block release when claim language
  drifts from artifact reality.
  `claim_gate.py` also requires claimable Doe package rows to carry
  receipt-visible package telemetry, including native fast-path flags,
  write breakdowns, readback mode, selected setup-timing scope, and the
  effective readback-path comparability obligation.
- **Compiler evidence** (`tint_compiler_evidence_gate.py`) — block
  Doe-vs-Tint compiler claims unless reports carry schema-valid corpus,
  toolchain, hash, validation, timing-phase, and comparability evidence.
- **Cerebras lane** (`cerebras_artifact_gate.py`,
  `doe_private_strategy_leak_gate.py`) — claim discipline + leak
  prevention for Doppler → Doe → Cerebras evidence.
- **Backend selection** (`backend_selection_gate.py`) — fail closed
  on capability drift between source and runtime.
- **Fixture regen** (`cluster_b_fixture_regen_gate.py`) — pin fixture
  freshness for cross-repo bring-up lanes.

Per `docs/process.md`:
- blocking in v0: schema, correctness, trace, verification
- advisory in v0: performance

Adding a new gate: extend `config/gates.json` with the gate name and
mode; add the module here; add a focused test in `bench/tests/`.
