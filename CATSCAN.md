# CATSCAN: Doe

Parent: none

## Target

Deliver governed, program-identity-preserving GPU execution for a declared application and hardware matrix.

## Authority

- Owns Doe's repository-wide execution, evidence, and component-boundary law.
- Does not own application planning, browser policy, model selection, or external hardware governance.

## Scope

- Includes files beneath this directory except child-chartered components, which narrow this authority.

## Contracts

Inputs:
- Mission and durable goals: [`GOALS.md`](GOALS.md).
- Product strategy: [`docs/thesis.md`](docs/thesis.md).
- Process law: [`docs/process.md`](docs/process.md).

Outputs:
- Public package, native runtime, compiler, evidence, and governed expansion artifacts.
- Component authority index: [`docs/component-index.md`](docs/component-index.md).

## Invariants

- Provider, backend, program, hardware, fallback, and result identity remain explicit.
- Unsupported or unproved behavior fails closed at its declared boundary.
- Package, native, browser, simulator, and hardware evidence never inherit one another's claims.
- Runtime ownership receives credit only through the governed ownership comparison.

## Acceptance

- Component charters and their generated index pass the blocking CATSCAN gate.
- Evidence: [`bench/gates/catscan_gate.py`](bench/gates/catscan_gate.py).

## Non-goals

- Universal WebGPU compatibility, universal Dawn replacement, or a general agent framework without separately promoted evidence.

## Freedom

Any mechanism is permitted if it preserves these boundaries and passes the acceptance evidence.
