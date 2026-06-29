# Reports

Tracked report fixtures and parity receipts that are small enough to keep in
tree.

Use `bench/out/` for generated run workspaces, large benchmark outputs, and
machine-local evidence. Keep files here only when they are stable reference
artifacts that tests, docs, or reviews may inspect directly.

- `claim-index.json` lists the benchmark receipt paths that support the public
  README claim charts without requiring broad historical `bench/out` retention.
  `claim-indexed` entries must carry `comparisonStatus=comparable`,
  `claimStatus=claimable`, and a claim sidecar path. Diagnostic and status-only
  entries may stay visible, but they are not public speed claims.
