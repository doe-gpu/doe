# Browser lane

This is a routing note, not a task list or status log.

- Product and package boundary:
  [`runtime-surface-boundary.md`](runtime-surface-boundary.md)
- Canonical browser tasks:
  [`chromium-webgpu-task-list.md`](chromium-webgpu-task-list.md)
- Acceptance plan:
  [`../browser/chromium/plan.md`](../browser/chromium/plan.md)
- Integration-layer usage:
  [`../browser/chromium/README.md`](../browser/chromium/README.md)
- Machine-owned milestone state:
  [`../browser/chromium/bench/workflows/browser-milestones.json`](../browser/chromium/bench/workflows/browser-milestones.json)
- Live runtime and benchmark status:
  [`status/runtime-backends-and-bench.md`](status/runtime-backends-and-bench.md)
- External product comparison policy:
  [`../config/browser-product-comparison-policy.json`](../config/browser-product-comparison-policy.json)

`doe-gpu/browser` delegates to the browser's existing `navigator.gpu`. Only a
forced-Doe Chromium artifact can support browser-runtime claims.

## Four-lane Fawn-Doe experimental matrix

The vertical product thesis evaluates four distinct operational lanes:

- **Lane A:** Stock Chromium + Playwright + Dawn
- **Lane B:** Fawn + Playwright + Dawn
- **Lane C:** Fawn + Playwright + Doe
- **Lane D:** Fawn Direct Protocol + Doe

These four lanes retain their causal semantics. **K0** is Cloudflare Browser
Run plus Kitesurf. It is measured beside A/B/C/D as an external product
comparator and is never treated as a component substitution lane. The policy
records Cloudflare's official
[announcement](https://blog.cloudflare.com/kitesurf/) and
[documentation](https://developers.cloudflare.com/browser-run/kitesurf/), the
comparator freshness rule, fork authorities, and claim boundary.

## Frozen product suites

The shared suite covers HTML extraction, screenshots, navigation, automation
success, wall time, tokens, memory, cost, compatibility failures, unsupported
features, retries, recovery, and total task outcomes.

The differentiation suite covers persistent authentication, restart recovery,
offline local operation, WebGL, WebGPU, private state, and long-running
sessions. K0 runs only on workloads admitted by its documented product
boundary. Unsupported rows remain `ineligible`: they are retained, are never
scored as Fawn wins, and do not prove Fawn quality or customer value. Fawn must
still pass its own application oracle, lifecycle, and release gates.

### Falsifiable decision rules

1. **If B beats A but C does not beat B:**  
   The Fawn browser shell and agent features have standalone value; DoeRuntime has not earned browser ownership.
2. **If C beats B but D does not beat C:**  
   DoeRuntime provides demonstrable browser acceleration; the Direct Protocol is unnecessary or immature.
3. **If D reduces tokens but increases total task time:**  
   Retain Direct Protocol only for workloads where context cost dominates wall-clock latency.
4. **If none beat A:**  
   Do not rationalize the result; redirect DoeRuntime focus to Node/Bun/Electron package lanes.
5. **If D materially beats A across task success, latency, memory, and recovery:**  
   Record an end-to-end challenger outcome only; it does not bypass the B/A,
   C/B, or D/C attribution gates.
6. **If K0 wins shared tasks and customers do not value differentiation:**
   Stop treating Fawn as a product.
7. **If B does not beat A:**
   Fawn has not earned standalone shell value.
8. **If C does not beat B:**
   DoeRuntime has not earned browser execution for that tuple.
9. **If D does not beat C on the declared total task outcome:**
   Stop funding Direct Protocol for that workload.

Contract Markdown under `browser/chromium/contracts/` owns detailed browser
artifact requirements. Do not duplicate those requirements here.
