# Doe agent module

Purpose:
- mine upstream quirk/workaround signals from Dawn source trees
- auto-promote known behavioral toggles to runtime-actionable records
- normalize all output into schema-valid quirk records for the Zig runtime

## Pipeline

```
Dawn source tree          mine_upstream_quirks.py          quirks.json
      |                           |                            |
      v                           v                            v
 Toggle:: patterns ──> extract + classify ──> toggle records (informational)
 vendor workarounds     auto-promote known     use_temporary_buffer records (behavioral)
 limit overrides        behavioral toggles     no_op records (informational)
                        via TOGGLE_PROMOTIONS
                              |
                              v
                        manifest.json (hash chain, hit counts, provenance)
```

## Toggle promotion (zero HITL)

The miner auto-promotes known Dawn behavioral toggles from `action: toggle` to
`action: use_temporary_buffer` when:
1. The toggle name matches a key in `TOGGLE_PROMOTIONS`
2. The activation context is `default_on` or `force_on` (not bare `reference`)

Currently promoted toggles:
- `use_temporary_buffer_in_texture_to_texture_copy` (Vulkan compressed tex-to-tex)
- `use_temp_buffer_in_small_format_texture_to_texture_copy_from_greater_to_less_mip_level` (Intel Gen9/Gen11 D3D12)
- `d3d12_use_temp_buffer_in_depth_stencil_texture_and_buffer_copy_with_non_zero_buffer_offset` (D3D12 depth-stencil)
- `d3d12_use_temp_buffer_in_texture_to_texture_copy_between_different_dimensions` (D3D12 cross-dimension)

Adding support for a new Dawn toggle class requires one table entry in `TOGGLE_PROMOTIONS`.

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
  - auto-promotes known behavioral toggles via `TOGGLE_PROMOTIONS`
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
