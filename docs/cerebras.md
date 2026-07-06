# Doe ↔ Cerebras

Index for the Doppler → Doe → Cerebras lane: current status, source locations,
hardware runbook, bundle pointer, and claim scope.

## Progress at a glance

```bash
python3 bench/tools/cerebras_status_snapshot.py
```

Writes `bench/out/r3-cerebras-status/snapshot.{json,md}`. The snapshot is a
per-lane verdict table built from receipts and carries the current counts.

Live narrative status: [`docs/status/cerebras-csl.md`](status/cerebras-csl.md).
Per-model evidence checklists with acceptance bars and active blocker queues:
[`cerebras-model-ledgers.md`](cerebras-model-ledgers.md).

## Source code

| Surface | Path |
|---|---|
| TSIR (semantic + planner + emitters) | `runtime/zig/src/tsir/` |
| CSL emit (classifier/template path) | `runtime/zig/src/doe_wgsl/emit_csl_*.zig` |
| Hardware runners (Gemma/Qwen HostPlan + bounded cells) | `bench/runners/csl-runners/` |
| Bundle / verify / status tools | `bench/tools/cerebras_*`, `bench/tools/*evidence*`, `bench/tools/synthesize_*` |
| TSIR architecture plan | [`docs/tsir-lowering-plan.md`](tsir-lowering-plan.md) |
| CSL abstraction stack | [`docs/csl-architecture.md`](csl-architecture.md) |

## Reproduce

Use the operator runbook for exact commands:
[`docs/cerebras-hardware-runbook.md`](cerebras-hardware-runbook.md).

The status snapshot command above is intentionally the only command repeated in
this front door.

For local pre-hardware classification, refresh the snapshot and then run:

```bash
python3 bench/tools/check_cerebras_no_hardware_readiness.py
```

That gate checks that Qwen local evidence, local blockers, and the missing WSE
receipt are all typed. It is not a hardware execution claim.

## Run on hardware

Operator runbook: commands, hardware receipt paths, required receipt fields,
publication boundaries, and email text:
[`docs/cerebras-hardware-runbook.md`](cerebras-hardware-runbook.md).

Bundle pointer with archive sha256, pinned commit, regenerated timestamp, and
verification commands:
[`docs/cerebras-evidence-bundle-pointer.md`](cerebras-evidence-bundle-pointer.md).

Bundle source. The packer extracts archive-root files like `README.md`,
`CLAIM_SCOPE.md`, `MODEL_ACCESS.md`, `CEREBRAS_ASK.md`, and
`LOCAL_INSPECTION.md` from marked sections of this file:
[`docs/cerebras-evidence-bundle.md`](cerebras-evidence-bundle.md).

Governance + claim scope: [`docs/hardware-validation-appendix.md`](hardware-validation-appendix.md).

## Why

- Project rationale: [`docs/thesis.md`](thesis.md).
- Practitioner pain points: [`docs/problems-addressed.md`](problems-addressed.md).
- Model target rationale: dense Gemma plus hybrid Qwen, both on the Q4K → f16
  contract. See the public page copy and the per-model ledgers above.

## Scope notes

- Embedded pass totals. Run the snapshot.
- Roadmap timing. Status snapshot + evidence ledgers carry current state;
  blockers are named without estimates.
- Internal iteration jargon. Build-iteration vs parity-iteration discipline
  for the TSIR rewrite lives in [`docs/loop-protocol.md`](loop-protocol.md);
  it sits outside the Cerebras lane progress signal.
