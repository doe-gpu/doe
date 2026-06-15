Local bench output mirror

Most of this directory is intentionally ignored by git. Local A/B runs,
timestamped workspaces, bulky NDJSON, and harvested benchmark corpora should
stay local unless they are deliberately promoted.

Promoted evidence should have a clear source command and a durability reason
such as a release, claim, reproducibility contract, or small fixture needed by
tests. Prefer curated reports or manifests over committing entire timestamped
workspaces.

Tracked stable mirrors have historically lived under `bench/out/cube/latest/`
and `bench/out/visualization/latest/`. Treat any new tracked `bench/out/`
content as an explicit exception, not the default.

Layout

- `apple-metal-full-greedy-16step/`
  Mirrored archive copy from `models2`. Treat as read-only.
- `apple-metal-sample-only-tie-break/20260328T190156Z-reviewed/`
  Historical Apple Metal seatbelt determinism evidence bundle with Doe
  `stable-token`, `stable-choice`, and `reviewed-choice` receipts plus paired
  Doe/Dawn sample-only replay artifacts.
- `apple-metal-dawn-full-greedy-16step/`
  Mirrored archive copy from `models2`. Treat as read-only.
- `apple-metal-webkit-full-greedy-16step/`
  Mirrored archive copy from `models2`. Treat as read-only.
- `amd-vulkan-full-greedy-16step/`
  Mirrored archive copy from `models2`. Treat as read-only. This tree contains historical reruns for some batches.
- `amd-vulkan-*/`, `apple-metal-*.json`
  Mirrored analysis artifacts and operator-level receipts copied from `models2`.
- `_wip/amd-vulkan-dawn-full-greedy-16step-partial-20260403/`
  Quarantined partial local rerun for `AMD Dawn / gemma270m / 16step`. Not part of the canonical mirrored archive set.

Current intent

- Keep the mirrored archive roots stable for analysis and blog work.
- Keep partial or failed reruns under `_wip/`.
- If `AMD Dawn / 16step` is rerun cleanly, write it to `amd-vulkan-dawn-full-greedy-16step/` at the top level and then move or delete the partial `_wip/` copy.
