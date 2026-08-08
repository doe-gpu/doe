# Public claim boundary

## Source of truth

`reports/claim-index.json` owns public measured rows. A claim is no stronger
than the exact report and claim sidecar referenced by its index entry.

## Required scope

Every performance statement must name or make unambiguous:

- product surface and version;
- runtime host;
- operating system and architecture;
- backend, adapter, and driver;
- comparator;
- workload and input contract;
- timing class and metric direction;
- claim state and evidence path.

Do not generalize across missing cells.

## Evidence states

- `claim-indexed`: eligible only for its declared row.
- `diagnostic`: engineering evidence, not promoted wording.
- `status-only`: capability or support statement without measured superiority.
- `scaffolded`: implementation or configuration exists without sufficient
  execution evidence.

## Claim rules

- Validate output before promoting timing.
- Require structural work and timing-scope equivalence.
- Keep package, native, browser, and hardware lanes separate.
- Keep simulator and hardware execution separate.
- Treat suspiciously large wins as methodology audits.
- Link the artifact instead of copying percentages into prose.
- Never convert missing evidence into a broad qualitative claim.

## Browser claims

Browser replacement requires the published-browser contract and its checked
artifacts under `browser/chromium/contracts/`. Package browser wrappers, native
runtime rows, and local browser diagnostics do not satisfy that contract.

## Public documentation

The public claim checker scans the root and package READMEs plus the compact
public-boundary documents. It rejects stale chart references, malformed claim
index entries, and unbound package percentages.

Run:

```bash
python3 scripts/check-public-claim-surfaces.py
```

The checker is a publication guard, not a substitute for correctness,
comparability, reliability, or performance gates.
