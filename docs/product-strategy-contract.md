# Doe product strategy contract

`config/doe-product-strategy.json` is the validated, machine-readable projection
of Doe's canonical strategy. [`thesis.md`](thesis.md) remains the narrative
authority. This contract makes the commercial offer, internal product roles,
comparison law, evidence custody, platform sequence, and milestone claim
boundaries testable instead of leaving them scattered across prose.

## Product roles

| Surface | Portfolio role | Market job |
| --- | --- | --- |
| DoeProof | Enabling capability | First sellable wedge: physical compute qualification under shadow governance |
| DoeRuntime | Enabling capability | Selectively own execution where `D0` earns it |
| Fawn | Product vector | Breakout distribution product tested through independent A/B/C/D lanes |
| DoeLab | Operating model | Turn retained failures into minimized, qualified improvements |

“First sellable wedge” and “breakout distribution product” are deliberately
different. A customer can buy DoeProof while retaining its incumbent. Fawn can
beat stock Chromium without proving DoeRuntime. DoeRuntime can own one
capability without becoming a universal runtime replacement.

## Physical Compute Qualification

The offer freezes one application workload, independent oracle, hardware tuple,
and strongest eligible incumbent. Doe first supplies `W0`: the pinned incumbent
under DoeProof. `D0` is proposed only when the governed incumbent cannot satisfy
the frozen outcome. A conditional `P0` tests whether the smallest viable
incumbent patch solves the problem at lower durable cost.

The delivered decision is blocking and may qualify, reject, or require
requalification. It binds exact application, shader, runtime, binary, adapter,
driver, backend, fallback, output, lifecycle, comparison, and replay evidence.
The offer's commercial promotion gate is not an internal certificate: an
external customer must pay for a qualification and later depend on or pay for
a repeat requalification.

## Evidence custody

Customer content never crosses products by default. Customer-specific derived
knowledge requires explicit authorization. Only sanitized generic runtime
failures or independently reproducible backend defects may enter shared learning
under the narrower rules declared in the contract. A receipt does not grant a
license to reuse its inputs.

## Current-state boundary

The strategy contract records admission rules, not benchmark success. Current
support remains in [`doe-support-matrix.md`](doe-support-matrix.md); current
claims remain in `reports/claim-index.json`; browser promotion remains in the
Fawn milestone artifacts. The three named milestones intentionally remain
`unestablished`, `unestablished`, and `diagnostic` until their external or
physical evidence exists.

Validate the contract with:

```bash
python3 -m unittest bench.tests.test_config_schemas
```
