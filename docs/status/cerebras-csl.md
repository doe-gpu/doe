# Doe status: Cerebras and CSL

This is the live status front door for the Doppler to Doe to Cerebras lane.
Do not copy launch counts, verdicts, hashes, or transcript results into this
file.

## Current boundary

The generated snapshot is the current status surface:

- `bench/out/r3-cerebras-status/snapshot.json`
- `bench/out/r3-cerebras-status/snapshot.md`

Refresh it with the command documented in [`../cerebras.md`](../cerebras.md).
Each row must point to its underlying receipt.

## Active blockers

- Complete real-session token, logits, and KV transcript evidence.
- Close the live TSIR-to-CSL execution wiring rather than relying on parallel
  classifier/template paths.
- Produce hardware receipts before making hardware execution, parity,
  performance, or efficiency claims.
- Keep model-specific acceptance bars in
  [`../cerebras-model-ledgers.md`](../cerebras-model-ledgers.md).

## Ground truth

- Lane front door: [`../cerebras.md`](../cerebras.md)
- Hardware procedure: [`../cerebras-hardware-runbook.md`](../cerebras-hardware-runbook.md)
- Claim rules: [`../claim-discipline.md`](../claim-discipline.md)
- Historical entries:
  [`archive/2026-04-to-2026-07-cerebras-csl.md`](archive/2026-04-to-2026-07-cerebras-csl.md)
