# Doe JavaScript style guide

This guide is the JavaScript style contract for `packages/doe-gpu`.

## Core principles

- Pure ESM throughout. No CommonJS, no dynamic `require()`.
- Runtime validation over static types. Use JSDoc for public API intent.
- Fail fast with path-based error context.
- Freeze constant objects. Prefer `Object.freeze()` for enum-like tables.

## Modules

- All modules are ESM via `"type": "module"` in `package.json`.
- Use named imports: `import { x, y } from './module.js'`.
- Always include the `.js` extension in import paths.
- Avoid new default exports in authored internal modules. Vendor-synced
  compatibility modules may retain upstream defaults, and package entrypoints
  may use either named or default exports when that keeps the public surface
  explicit.

```javascript
import { createDoeNamespace } from './vendor/doe-namespace.js';
import { KNOWN_FEATURES } from './vendor/webgpu/shared/capabilities.js';
import { assertObject } from './vendor/webgpu/shared/resource-lifecycle.js';
import { normalizeEnumKey } from './vendor/webgpu/shared/validation.js';
```

## File naming

- `kebab-case.js` for all source files.
- No `.mjs` extension. ESM is declared via `package.json`, not file extension.
- Test files: `test-<scope>.js` (e.g. `test-smoke-load.js`,
  `test-integration-gpu-namespace.js`).
- Runtime shims: named by runtime (`bun.js`, `deno.js`, `browser.js`).

## Naming

- Functions and methods: `camelCase`
- Variables and properties: `camelCase`
- Boolean predicates: `is`/`has`/`should` prefix (`isBCFormat()`,
  `hasStencilAspect()`)
- Classes: `PascalCase`
- Constants: `UPPER_SNAKE_CASE` (`UINT32_MAX`, `ALL_BUFFER_USAGE_BITS`)
- WeakMap metadata keys: `UPPER_SNAKE_CASE` (`DOE_BUFFER_META`,
  `DOE_PENDING_ENCODERS`)
- Private/internal properties: leading underscore (`_native`, `_destroyed`)
- WebGPU enum values: kebab-case strings matching the spec (`'read-only-storage'`,
  `'non-filtering'`)

## Constants

- Use `Object.freeze()` for enum-like lookup objects.
- No bare magic numbers. Name all thresholds and limits.
- Place constants at file top, after imports.

```javascript
const SAMPLER_BINDING_TYPES = Object.freeze({
  filtering: 'filtering',
  'non-filtering': 'non-filtering',
  comparison: 'comparison',
});
```

## Exports

- Prefer named exports grouped at the end of authored modules.
- Small facades, package entrypoints, and vendor-synced modules may export
  inline when that is clearer.
- Re-export barrels use `export * from` or `export { name } from`.

```javascript
export {
  MAX_SAFE_U64,
  failValidation,
  describeResourceLabel,
};
```

## Error handling

- Use `failValidation(path, message)` for WebGPU validation errors.
- Include descriptor path context: `descriptor.entries[${i}].buffer.type`.
- Throw `Error` directly; do not subclass unless the caller needs to
  discriminate.
- Attaching stable machine-readable fields to `Error` objects is acceptable
  when callers need structured diagnostics.
- Use try-catch only for expected failure modes (import probing, optional
  features).

```javascript
function failValidation(path, message) {
  throw new Error(`${path}: ${message}`);
}
```

## Validation

- Validate at API boundaries using runtime type checks.
- Keep JSON schema, runtime validator field tables, and `.d.ts` declarations in
  parity. `npm run check:plan-schema` is the plan/capture contract check.
- Validation failures expose stable `code`, `path`, `expected`, and `received`
  fields in addition to a readable message.
- Use helper functions (`assertObject`, `assertArray`, `assertBoolean`,
  `assertNonEmptyString`, `assertIntegerInRange`, `assertOptionalIntegerInRange`,
  `normalizeEnumKey`, and the format-specific normalizers in `validation.js`)
  rather than inline `typeof` checks.
- Nullish coalescing for optional descriptor fields:
  `descriptor?.label ?? ''`.

## Comments

- File header: 1-3 line `//` comment identifying the module.
- Section separators for large files: `// === Section name ===`.
- JSDoc `/** */` blocks for public API functions and classes.
- Inline `//` comments only for non-obvious constraints or rationale.
- No TODO/FIXME inline; track follow-ups in the status log (`docs/status.md`, with dated entries in the current `docs/status/*.md` shard).

```javascript
// doe-gpu — compute surface
//
// Narrower entrypoint for compute-only workloads.
```

## Formatting

- 2-space indentation.
- Semicolons required.
- Line length: prefer under 100 characters.
- Prefer single quotes in authored package code. Follow the surrounding file's
  existing quote style in vendor-synced or generated modules.
- No trailing commas in function parameter lists.
- Trailing commas in array/object literals.

## Testing

- No test framework. Vanilla Node.js assertions with `check(label, condition,
  detail?)` helpers.
- Smoke tests: sequential checks, exit 0/1, output `ok:` or `FAIL:` lines.
- Integration tests: discovered by pattern (`test-integration-*.js`), spawned
  as subprocesses.
- Test files live in `test/smoke/` and `test/integration/`.

## Dependencies

- Zero runtime dependencies in the published package.
- Dev tooling uses Node.js built-ins only (`child_process`, `path`, `fs`).
- No bundler, no transpiler. Ship source JS directly.

## Scripts

- CLI scripts start with `#!/usr/bin/env node`.
- Scripts live in `scripts/` and are referenced from `package.json`.
