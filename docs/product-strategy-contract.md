# Doe product strategy contract

`config/doe-product-strategy.json` is the schema-validated projection of
[`thesis.md`](thesis.md). Schema version 3 and strategy 2.0.0 replace the
qualification-first priority in version 2: DoeRuntime is primary, DoeProof is
its supporting provider-neutral feature, and Fawn is secondary. This is an
intent migration, not a runtime rename, package removal, or evidence promotion.
Historical qualification receipts remain valid for their original claims.

## Product roles

| Surface | Role | Acceptance |
| --- | --- | --- |
| DoeRuntime | Primary product | Unchanged external non-Doppler application adopts for a material advantage and retains across another release or workload |
| DoeProof | Supporting feature | Independently qualifies incumbent and DoeRuntime without interfering with execution |
| Fawn | Secondary browser product | Earns its own shell value and only distributes DoeRuntime where browser substitution is physically proved |
| DoeLab | Operating model | Turns retained failures into minimized regressions and qualified corrections |

## Comparison and adoption law

Freeze the strongest eligible incumbent, exact application/WGSL/inputs, independent
oracle, hardware and driver, fallback policy, cache state, timing scope, reliability
gates, and material threshold. Preserve I0, I1, W0, D0, and credible eligible P0
controls. A W0 qualification alone is feature value, not runtime adoption. D0
testing does not require a preceding paid DoeProof engagement.

Start with AMD/Vulkan unless a real customer supplies a stronger target.
Each host and backend earns support independently. Require unchanged provider
integration, parity, lifecycle and recovery, raw measurements, an external
maintainer's adoption decision, and repeat retention. Payment, internal
benchmarks, compiler breadth, receipts, and Doppler interoperability cannot
substitute for these evidence fields; the schema enforces their presence.

The browser comparison policy preserves A/B/C/D causal meanings and separate
K0 eligibility. Its version 2 changes product priority, not comparison semantics.
Fawn's B-over-A result does not grant DoeRuntime C-over-B credit. D-over-C still
isolates Direct Protocol. Ineligible K0 work never becomes a Fawn win.
`doe-gpu/browser` is an incumbent wrapper until Doe occupies the Chromium seam.

## Evidence custody and current state

Customer content never crosses products by default. Customer-derived knowledge
requires explicit authorization; only sanitized failures or reproducible backend
defects enter shared learning under the declared custody rules.

The strategy records intended admission rules, not achieved support or adoption.
[`doe-support-matrix.md`](doe-support-matrix.md), `reports/claim-index.json`, and
Fawn milestone artifacts remain the evidence authorities. Reordered milestones
retain their unestablished or diagnostic assessments. No result is promoted by
this intent change.

Validate with:

```bash
python3 -m unittest bench.tests.test_config_schemas bench.tests.test_browser_product_comparison_policy
```
