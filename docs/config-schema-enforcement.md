# Config and schema enforcement

Doe runtime-visible behavior must be explainable from config, schema, and
artifacts.

## Runtime-visible field rule

Any field that changes runtime behavior, benchmark interpretation, claim
classification, artifact shape, or backend selection must have one of:

- a schema entry,
- a documented config entry,
- a migration note,
- or an explicit unsupported/error taxonomy.

Fields used only inside archived receipts do not need new schema work unless a
current producer still emits them.

## Hidden-toggle rule

Production behavior must not depend on undocumented manual toggles.

Allowed toggles:

- documented CLI flags,
- schema/config fields,
- benchmark/operator flags in repo-only tooling,
- environment variables documented next to their owning surface.

Disallowed toggles:

- hidden runtime env vars that change package/native behavior,
- ad-hoc fallback flags not represented in config,
- benchmark-only switches reused as product behavior.

## Cleanup rule

When removing code or docs:

- remove dead implementation only when reference scans show it is unused;
- preserve historical receipts and archived evidence unless they are superseded
  presentation assets;
- do not delete artifacts that are named by current reports, claims, schemas, or
  status docs;
- prefer typed unsupported behavior over placeholder runtime paths.

## Proof/runtime rule

Proof work should delete runtime branches or discharge blocking obligations.
If a proof artifact does not remove runtime work or gate a claim, keep the
runtime check explicit in Zig and record the condition as current dynamic
behavior.
