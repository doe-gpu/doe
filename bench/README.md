# Doe benchmark and evidence tooling

`bench/` owns repository-only correctness, compatibility, reliability,
performance, comparison, and claim tooling. It is not part of the public npm
package.

## Start here

```bash
python3 bench/cli.py --help
python3 bench/cli.py workload --help
python3 bench/cli.py compare --help
python3 bench/cli.py claim --help
python3 bench/cli.py external --help
python3 bench/cli.py program --help
```

Use [`docs/operator-runbook.md`](../docs/operator-runbook.md) for platform
procedures and [`bench/docs/benchmark-writing-guide.md`](docs/benchmark-writing-guide.md)
for adding workloads.

External application reproduction starts at
[`external-projects/README.md`](external-projects/README.md). The
`external reproduce` command owns source preparation, host admission, Doe
build identity, policy gates, workload execution, and receipt routing; a
passing command is still not a public claim.

Declared compute programs use `program prepare-lif`, `program evaluate`,
`program qualify-package`, `program verify`, and `program verify-native`.
Use `program evaluate --package-qualification <summary.json>` to compare
applications using the exact archives retained by package qualification.
Install the pinned comparator dependencies with `npm ci --prefix bench`.
Their policy and evidence boundaries are documented in
[`reusable-compute-programs.md`](../docs/reusable-compute-programs.md).

## First benchmark matrix

Use the physical backend runner matching the host. It performs host preflight,
separate Doe and Dawn runs, strict receipt comparison, output-oracle checks,
and cumulative recomposition evidence capture:

| Host/backend | Command |
| --- | --- |
| Linux / AMD Vulkan | `python3 bench/runners/run_recomposition_backend_evidence.py --backend vulkan` |
| macOS / Apple Metal | `python3 bench/runners/run_recomposition_backend_evidence.py --backend metal` |
| Windows / D3D12 | `python3 bench/runners/run_recomposition_backend_evidence.py --backend d3d12` |

Inspect the full promoted surface before choosing a broader run:

```bash
python3 bench/cli.py compare --list-promoted
```

The runner requires built Doe and Dawn native artifacts. It fails preflight
with the missing dependency instead of substituting another backend.

## Evidence flow

The required order is:

1. define a workload and independent output oracle;
2. run each provider separately and retain raw artifacts;
3. verify runtime identity, successful work, output, and synchronization;
4. compare only structurally equivalent executions;
5. evaluate claim policy separately;
6. publish only reviewed, claim-eligible artifacts.

Timing from an invalid or unequal execution is diagnostic.

## Core contracts

- Workload identity and execution adapters:
  [`docs/workload-system.md`](../docs/workload-system.md)
- Compare vocabulary and axes:
  [`docs/benchmark-taxonomy.md`](../docs/benchmark-taxonomy.md)
- Correctness and performance methodology:
  [`docs/performance-strategy.md`](../docs/performance-strategy.md)
- Release stage and failure precedence:
  [`docs/process.md`](../docs/process.md)
- Public wording:
  [`docs/public-claim-boundary.md`](../docs/public-claim-boundary.md)

Configuration and schemas own thresholds, allowed values, workload catalogs,
backend policies, and claim rules. Do not copy mutable values into this README.

## Directory map

| Path | Responsibility |
| --- | --- |
| `bench/cli.py` | Stable operator front door |
| `bench/workloads/` | Workload definitions, assets, and metadata |
| `bench/oracles/` | Independent correctness oracles |
| `bench/runners/` | Governed orchestration |
| `bench/browser/` | Browser smoke and release evidence validation |
| `bench/gates/` | Blocking and advisory decisions |
| `bench/tools/` | Builders, checkers, and reports |
| `bench/docs/` | Focused operator and integration references |
| `bench/out/` | Generated run artifacts and receipts |

`config/tool-surfaces.json` owns whether any tool is public or repo-only.
Browser release receipt ownership and existing admission commands are mapped in
[`browser/README.md`](browser/README.md). Shared admission policy stays in the
gates; artifact-family validation belongs to the workflow that consumes it.

## Comparability rules

A comparable row requires the same:

- source workload and inputs;
- output oracle;
- command, dispatch, and repeat shape;
- preparation and cache state;
- upload, completion, and readback behavior;
- hardware and driver environment;
- timing scope and normalization;
- sample policy.

Reject comparison when work is skipped, output is unchecked, dispatch counts
diverge, one side omits a material timing phase, or provider/fallback identity
is uncertain.

## Performance reporting

Report the complete user-visible operation first. Phase timing is attribution,
not a substitute. Keep cold and warm runs separate, include latency tails and
memory, and record failures, retries, and fallbacks beside performance.

Suspiciously large wins trigger a fairness audit. Hardware-path shortcuts and
different effective readback paths require explicit diagnostic classification.

## Artifacts

Generated runs belong under grouped `bench/out/<lane>/<run-id>/` directories.
Stable reviewed reports belong under `reports/`. Public rows enter
`reports/claim-index.json` only after their report and claim sidecar are
reviewed and current.

Do not cite scratch paths as durable evidence. Do not edit generated artifacts
to change a verdict; fix the producer, workload, or gate and rerun it.

## Release checks

The canonical gate runners live under `bench/runners/`. Hardware-specific
lanes may remain manual, but a promoted release must record which required
checks ran, which were unavailable, and why. Optional flags are not evidence
that a check protected the release.

## Focused references

- [`bench/docs/benchmark-writing-guide.md`](docs/benchmark-writing-guide.md)
- [`bench/docs/dawn-delegate-cache-integration.md`](docs/dawn-delegate-cache-integration.md)
- [`bench/docs/vulkan-pipeline-cache-integration.md`](docs/vulkan-pipeline-cache-integration.md)
- [`bench/docs/operator-diff-demo-runbook.md`](docs/operator-diff-demo-runbook.md)
- [`bench/tools/cerebras-evidence-bundle-tools.md`](tools/cerebras-evidence-bundle-tools.md)

Historical commands and benchmark findings belong in status archives and git
history, not this entrypoint.
