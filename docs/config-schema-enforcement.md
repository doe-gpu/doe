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
