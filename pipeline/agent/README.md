# Doe agent module

Purpose:
- mine upstream quirk/workaround signals from Dawn source trees
- normalize recognized patterns into unverified, provenance-bound candidates
- turn Fawn matrix failures into deterministic replay and minimization work
- hand candidates to verification without changing runtime or release policy

## Pipeline

```
Dawn source tree          mine_upstream_quirks.py          quirks.json
      |                           |                            |
      v                           v                            v
 Toggle:: patterns ──> extract + classify ──> toggle records (informational)
 vendor workarounds     map known patterns     use_temporary_buffer candidates
 limit overrides        behavioral toggles     no_op records (informational)
                        via TOGGLE_PROMOTIONS
                              |
                              v
                        manifest.json (hash chain, hit counts, provenance)
```

## Deterministic candidate action mapping

The miner maps known Dawn behavioral toggle patterns from `action: toggle` to an
unverified `action: use_temporary_buffer` candidate when:
1. The toggle name matches a key in `TOGGLE_PROMOTIONS`
2. The activation context is `default_on` or `force_on` (not bare `reference`)

Currently recognized candidate patterns:
- `use_temporary_buffer_in_texture_to_texture_copy` (Vulkan compressed tex-to-tex)
- `use_temp_buffer_in_small_format_texture_to_texture_copy_from_greater_to_less_mip_level` (Intel Gen9/Gen11 D3D12)
- `d3d12_use_temp_buffer_in_depth_stencil_texture_and_buffer_copy_with_non_zero_buffer_offset` (D3D12 depth-stencil)
- `d3d12_use_temp_buffer_in_texture_to_texture_copy_between_different_dimensions` (D3D12 cross-dimension)

Adding support for a new Dawn toggle class requires one table entry in
`TOGGLE_PROMOTIONS`. The historical constant name is retained for compatibility;
the output remains candidate evidence and has no promotion authority.

## Fawn matrix learning handoff

`fawn_matrix_learning_bridge.py` consumes a raw four-lane matrix artifact. It
preserves each failed sample, clusters repeats by observed boundary and failure
class, records exact replay selectors, and emits required minimization steps. Every
resulting investigation proposal is `unverified`, has an `unestablished` hypothesis,
and may advance only to `verify`. The bridge explicitly prohibits runtime-policy
mutation, candidate promotion, and release claims. Its artifact contract is
`config/doe-lab-fawn-matrix-learning.schema.json`.

## Non-toggle workaround mining

The miner also extracts non-toggle workaround patterns from Dawn source:
- `limit_override` — vendor-specific limit adjustments (`limits->v1.field = value`)
- `alignment` — alignment constant assignments inside vendor guards
- `feature_guard` — feature disable/enable patterns inside vendor blocks

These are emitted as `no_op` records with workaround metadata in the manifest.

## Sources

- Dawn and wgpu source trees as external references

## Tools

- `mine_upstream_quirks.py` — automated miner
  - scans source roots for Toggle:: signals and vendor workaround patterns
  - maps known behavioral toggle patterns via `TOGGLE_PROMOTIONS`
  - emits `quirks.schema`-valid candidate records (`schemaVersion: 2`)
  - emits a hash-linked mining manifest (`config/quirk-mining-manifest.schema.json`)
  - keeps output reproducible with sorted candidate order and deterministic hash chaining
- `watchdog.py` — legacy MVP parser (retained for reference)

## Usage

```bash
# Full mining (toggles + non-toggle workarounds)
python3 pipeline/agent/mine_upstream_quirks.py \
  --source-root bench/vendor/dawn/src/dawn/native \
  --source-repo dawn/main \
  --source-commit <commit> \
  --vendor all \
  --api all \
  --output bench/out/mined-quirks.json \
  --manifest-output bench/out/mined-quirks.manifest.json

# Toggle-only mining (backward compatible)
python3 pipeline/agent/mine_upstream_quirks.py \
  --source-root bench/vendor/dawn/src/dawn/native/vulkan \
  --source-repo dawn/main \
  --source-commit <commit> \
  --vendor amd \
  --api vulkan \
  --toggle-only \
  --output bench/out/mined-quirks.json \
  --manifest-output bench/out/mined-quirks.manifest.json
```

## Relationship to upstream intelligence and dawn-research

`pipeline/upstream_intelligence/` is the active Gerrit and Chromium issue
history pipeline. It preserves updates, resolves current-revision commit/file
metadata, produces schema-backed human review packets, and records review
receipts.

This module (`pipeline/agent/`) is the independent source corroboration lane:
it reads checked-out Dawn source files and emits machine-consumable quirk
records that feed the Zig runtime via `--quirks`. `dawn-research/` is retained
only as a deprecated archive and replay corpus.
