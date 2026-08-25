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

`doe-gpu/browser` delegates to the browser's existing `navigator.gpu`. Only a
forced-Doe Chromium artifact can support browser-runtime claims.

## Four-lane Fawn-Doe experimental matrix

The vertical product thesis evaluates four distinct operational lanes:

- **Lane A:** Stock Chromium + Playwright + Dawn
- **Lane B:** Fawn + Playwright + Dawn
- **Lane C:** Fawn + Playwright + Doe
- **Lane D:** Fawn Direct Protocol + Doe

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
   The vertically integrated agent-compute thesis is validated.

Contract Markdown under `browser/chromium/contracts/` owns detailed browser
artifact requirements. Do not duplicate those requirements here.

## External product comparator

The causal A/B/C/D matrix remains local and unchanged. A remote browser service
changes engine, process location, network path, resource accounting,
isolation, and service policy simultaneously, so it cannot be inserted as a
fifth component lane.

- **K0:** Cloudflare Browser Run + Kitesurf

K0 is evaluated beside A/B/C/D only on workloads admitted by its documented
product boundary. Current Cloudflare documentation positions Kitesurf for
stateless, bursty agent work and excludes long-running authenticated sessions,
WebGL, video, and real TLS bot handshakes. Those rows remain `ineligible`; they
are not counted as Fawn wins.

The comparison freezes two suites:

1. **Shared agent tasks:** HTML extraction, screenshots, navigation,
   automation success, complete wall time, context tokens, observable CPU and
   memory, and total customer cost.
2. **Local persistent tasks:** persistent authentication, restart recovery,
   offline/local operation, WebGL/WebGPU capability, private endpoint state,
   local model execution, and long-running sessions.

K0 winning the shared suite rejects a generic stateless Fawn product. Fawn
survives only if an external application assigns material value to the second
suite and B beats A. C must still beat B before DoeRuntime earns browser
execution, and D must beat C before the Direct Protocol survives.

Cloudflare sources:

- https://blog.cloudflare.com/kitesurf/
- https://developers.cloudflare.com/browser-run/kitesurf/
