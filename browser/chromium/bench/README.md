# Browser benchmark layer

This directory owns browser workload projection and milestone configuration.
It does not own native benchmark policy, browser strategy, or public claims.

## Layer model

- `L0`: native backend workload and oracle
- `L1`: the same operation through browser WebGPU
- `L2`: browser application workflow including browser lifecycle costs

Projection rows are generated from core workload contracts. Do not maintain a
parallel handwritten workload list.

## Source of truth

- Projection rules: `projection-rules.json`
- Generated projections: `generated/`
- Workflow definitions: `workflows/browser-workflow-manifest.json`
- Promotion approvals: `workflows/browser-promotion-approvals.json`
- Milestones: `workflows/browser-milestones.json`
- Browser methodology:
  [`../contracts/browser-claim-methodology.contract.md`](../contracts/browser-claim-methodology.contract.md)

Schemas adjacent to those files own their shapes.

## Run

From the repository root:

```bash
npm --prefix browser/chromium ci
./browser/chromium/scripts/run-bench.sh
```

For same-binary Dawn versus forced-Doe diagnostics:

```bash
./browser/chromium/scripts/run-fawn-runtime-bench.sh --headless true
```

For stock-browser versus Doe-browser consumer diagnostics:

```bash
./browser/chromium/scripts/run-consumer-bench.sh --headless true --strict-run
```

Use script `--help` for filters, schedules, executables, and platform options.
Do not copy the changing option inventory here.

## Promotion rules

- Both modes must prove active runtime identity.
- Promoted rows require independent output oracles.
- Work, cache, synchronization, readback, and timing scopes must match.
- Order-sensitive, focused, asymmetric, or incomplete rows remain diagnostic.
- Scores summarize diagnostic evidence; they do not create claimability.
- Browser claims require the published-browser release contract, not this
  benchmark alone.

Generated reports and score sidecars belong under browser artifacts or
`bench/out/`. Stable public rows enter `reports/claim-index.json` only after
their browser release, correctness, comparability, and claim gates pass.
