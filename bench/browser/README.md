# Browser evidence

Browser-lane gates for the Chromium WebGPU compare surface. Currently
`browser_gate.py` and `browser_claim_gate.py`, which evaluate the
Playwright-driven smoke output at
`browser/chromium/artifacts/.../dawn-vs-doe.browser.playwright-smoke.diagnostic.json`
against gate policy.

Browser executors and harvesters live in
[`bench/executors/`](../executors/) (`run-browser-ort-bench.py`,
`harvest-doppler-browser-*.js`); the Chromium build itself lives under
`browser/chromium/`. Smoke-artifact production is documented in
[`bench/README.md`](../README.md) and the platform-specific
`bench/docs/` pages.

Gate output is consumed by `bench/runners/run_blocking_gates.py`
through [`config/gates.json`](../../config/gates.json).

## Release receipt validation

[`release/receipts.py`](release/receipts.py) composes the browser release receipt
checks used by the claim-index gate and replacement-readiness report.

| Responsibility | Implementation |
| --- | --- |
| Receipt file paths, bytes, and hashes | [artifacts.py](release/artifacts.py) |
| Shader, provider, fallback, and timing state | [receipt_state.py](release/receipt_state.py) |
| Execution receipt payloads and command coverage | [execution_receipts.py](release/execution_receipts.py) |
| Comparison work and release identity joins | [comparison_receipts.py](release/comparison_receipts.py) |
| Proof-page receipt and visible content | [proof_page_receipts.py](release/proof_page_receipts.py) |
| Gallery receipt and visible content | [gallery.py](release/gallery.py) |

Use the existing commands to inspect admission or build readiness reports:

```bash
python3 -m bench.gates.claim_index_gate --help
python3 -m bench.tools.build_dawn_replacement_readiness_report --help
```

Their arguments, artifact schemas, and retained receipt paths are unchanged.
The release package owns validation; it does not grant release eligibility.
Claim admission remains in `bench/gates/claim_index_browser_release.py`;
archive assembly and standalone verification remain under `bench/tools/`.
The existing regressions are
[`test_claim_index_gate.py`](../tests/test_claim_index_gate.py) and
[`test_claim_index_browser_release_receipts.py`](../tests/test_claim_index_browser_release_receipts.py).
Historical artifacts keep the source paths of the checkout that produced them.
