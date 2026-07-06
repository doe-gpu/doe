# Backend evidence matrix

This is the compact backend evidence front door. The source rows are current
claim metadata, support matrix status, and status shards. Do not treat this as a
replacement for the underlying artifacts.

| Backend | Surface | Current claim state | Evidence boundary | Next concrete blocker |
| --- | --- | --- | --- | --- |
| Apple Metal | native strict/release | `claim-indexed` | Current public claim rows live in `reports/claim-index.json`. | Keep claim index and README summary aligned with current artifacts. |
| Apple Metal | package | `claim-indexed` | Node/Bun package rows are indexed in `reports/claim-index.json`. | Keep package docs from hardcoding stale percentages. |
| Apple Metal | ORT provider | `diagnostic` | ORT rows are indexed separately and remain artifact-owned diagnostics. | Promote only when the ORT claim sidecars are claimable. |
| Apple Metal | browser ORT / browser diagnostics | `diagnostic` for current browser ORT row | Browser replacement claims remain separate from package/browser shim claims. | Promote only through browser-lane gates. |
| AMD Vulkan | native release | `claim-indexed` | Current public claim row lives in `reports/claim-index.json`. | Keep claim index and README summary aligned with current artifacts. |
| AMD Vulkan | package | `claim-indexed` | Node/Bun package rows are indexed in `reports/claim-index.json`. | Keep package claims tied to current manifest receipts. |
| D3D12 | native/runtime | `scaffolded` | Contracts and runtime path exist. | Fresh Windows evidence artifact and D3D12-specific Dawn mapping validation. |
| Chromium browser runtime | browser integration | `diagnostic` | Governed browser lane exists separately from `doe-gpu/browser`. | Browser compatibility/runtime promotion gates. |

## Rules

- Do not compare rows across machines, backends, or timing scopes.
- Use `claim-indexed` rows for public performance language.
- Use `diagnostic` rows for engineering attribution.
- Use `scaffolded` rows to name missing evidence explicitly.
- Keep generated README summaries and claim metadata aligned before publishing.

## Related files

- `reports/claim-index.json`
- `assets/readme/backend-evidence-summary.svg`
- `docs/doe-support-matrix.md`
- `docs/status/runtime-backends-and-bench.md`
- `docs/public-claim-boundary.md`
- `docs/runtime-surface-boundary.md`
