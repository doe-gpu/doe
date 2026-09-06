# Config and schema enforcement

Runtime behavior, benchmark interpretation, support state, and claim state must
be explainable from versioned config, schema, and artifacts.

Required rules:

- runtime-visible fields have a schema or explicit migration;
- production behavior does not depend on undocumented environment variables or
  benchmark-only switches;
- fallback policy is declared and emits its original cause;
- removed fields and changed defaults carry migration notes;
- proof artifacts either discharge a named obligation or remain advisory;
- archives may preserve old shapes, but current producers must validate against
  current schemas.

The normative stage and gate order lives in [`process.md`](process.md).
Machine-owned tool boundaries live in `config/tool-surfaces.json`.

## Schema target registry migration

Registry version 2 preserves fixed `schema` targets and adds `schemasByKind`
for globs containing different report types. Each glob declares exactly one
selection form. The gate reads the report's explicit `kind`, requires a
registered mapping, then validates its complete body with that schema. Missing
or unknown kinds fail; directory suffixes do not establish report type.

The existing compute-program final-summary glob now routes matrices and package
qualification separately. Its scope is unchanged, preserving historical
observations rather than rewriting them to satisfy a different report contract.
Current accepted package and application summaries are registered explicitly.
