# bench/tools

Receipt synthesizers, validators, aggregators, and bundle packers. Tools
read existing artifacts and emit new artifacts; they do not run workloads
themselves (that's `bench/runners/`).

Categories:

- **Cerebras lane** — `cerebras_status_snapshot.py`,
  `check_cerebras_no_hardware_readiness.py`,
  `prepare_cerebras_validation_bundle.sh`,
  `verify_cerebras_validation_archive.py`,
  `pack_cerebras_emulator_source_archive.py`,
  `summarize_cerebras_evidence_archive.sh`. Front door:
  [`docs/cerebras.md`](../../docs/cerebras.md).
- **Receipt synthesizers** (`synthesize_*.py`) — emit typed receipts from
  raw runner artifacts. Each receipt class has a fixed schema and a
  hash-link guard.
- **Aggregators** (`aggregate_*.py`) — cross-model / cross-lane joins
  (e.g. `aggregate_cross_model_parity.py`).
- **Validators** (`validate_*.py`, `verify_*.py`) — schema + hash-chain
  checks; fail closed on drift.
- **Audit + preflight** (`audit_*.py`, `*_preflight.py`) — guard rails
  before expensive runs.
- **Internal helpers** (`_*.py`) — prefixed with `_`; not invoked
  directly.

Tools must not silently downgrade or skip; missing inputs produce
typed "blocked" receipts, not partial evidence.
