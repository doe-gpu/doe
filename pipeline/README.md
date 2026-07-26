# Pipeline

`pipeline/` contains the supporting platform pipeline around the Doe runtime:

- `pipeline/agent/`
  - checked-out source quirk mining and normalization
- `pipeline/upstream_intelligence/`
  - update-aware Dawn Gerrit and Chromium issue synchronization
  - deterministic relevance, versioned LLM review, and promotion receipts
- `pipeline/lean/`
  - proof artifacts and eliminations
- `pipeline/trace/`
  - trace replay and comparison tooling

`config/` remains top-level for path stability, but it is conceptually part of
the same pipeline family.
