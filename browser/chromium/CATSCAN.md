# CATSCAN: Fawn Chromium integration

Parent: [Browser](../CATSCAN.md)

## Target

Produce an installable Chromium-family artifact that runs a named unchanged application through forced Doe with independently validated output.

## Authority

- Owns Chromium integration contracts, runtime selection, artifact packaging, browser lifecycle probes, and release evidence.
- Does not own Chromium policy outside the WebGPU seam or inherit package evidence.

## Scope

- Includes files beneath this directory except child-chartered components, which narrow this authority.

## Contracts

Inputs:
- Acceptance plan: [`plan.md`](plan.md).
- Browser contracts: [`contracts/README.md`](contracts/README.md).

Outputs:
- Hash-bound browser archives, forced-provider receipts, application results, diagnostics, and release decisions.

## Invariants

- Release candidates pass isolated clean installation using only packaged inputs.
- Forced Doe fails closed; governed fallback remains explicit and typed.
- Browser launch alone is integration evidence, not application or performance value.

## Acceptance

- The machine-owned milestone manifest defines and passes the applicable browser gates.
- Evidence: [`bench/workflows/browser-milestones.json`](bench/workflows/browser-milestones.json).

## Non-goals

- General Chromium ownership, browser-wide agent orchestration, or claim promotion from local smoke tests.

## Freedom

Any mechanism is permitted if it preserves these boundaries and passes the acceptance evidence.
