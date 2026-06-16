# Runtime selector and fallback contract

## Status

`draft`

## Goal

Define deterministic runtime selection for Chromium WebGPU execution:

1. `dawn` path.
2. `doe` path.
3. `auto` policy path.

Ensure immediate fallback with explicit reasons and no hidden behavior switches.

## Scope

In scope:

1. Runtime selection controls.
2. Kill switch policy.
3. Adapter/profile denylist policy.
4. Fallback reason taxonomy.
5. Fallback-to-evidence-blocker mapping.
6. Required observability fields.

Out of scope:

1. Browser process-model changes.
2. Non-WebGPU subsystem selection.
3. Implicit policy heuristics.

## Schema-backed policy

The runtime selector policy is
[`config/browser-runtime-selector-policy.json`](../../../config/browser-runtime-selector-policy.json)
and validates against
[`config/browser-runtime-selector-policy.schema.json`](../../../config/browser-runtime-selector-policy.schema.json).
The policy records the selection modes, control precedence, emergency kill
switch, auto-mode preconditions, denylist reason, fallback taxonomy,
fallback-to-evidence-blocker mapping, forced-Doe failure behavior, and required
observability fields.
Chromium source adapter filtering must also carry denylist detail once adapter
identity is available: `adapter_denylist_detail` includes
`profile_denylisted`, vendor/device IDs, adapter/backend type, and the
blocklist reason before the adapter is rejected.

The forced-Doe Chromium proc surface is
[`config/doe-chromium-proc-surface.json`](../../../config/doe-chromium-proc-surface.json)
and validates against
[`config/doe-chromium-proc-surface.schema.json`](../../../config/doe-chromium-proc-surface.schema.json).
The proc-surface checker verifies the selected Doe WebGPU library exports the
browser-facing WGPU symbols, resolves the generated Dawn wire proc table
through `wgpuGetProcAddress`, verifies required browser interop procs are
mapped in the Doe local resolver before native fallback, and can bootstrap a Doe
`WGPUInstance` before Chromium injects that instance into the WebGPU wire
server. It also checks the browser shared-memory implementation source so
error-object constructors allocate tagged Doe handles, macOS shared texture
memory imports IOSurface handles through Doe, and shared buffer/fence imports
stay explicitly unsupported until Chromium exposes native handle sources. Shared
texture, shared buffer, and shared fence proc names must be Doe-owned before
native fallback can satisfy the generated wire proc table. Error-object procs
must be Doe-owned and return releasable Doe error handles, not null
native-fallback placeholders. Chromium texture mailbox paths must use the loaded
Doe proc table and raw `WGPUTexture` handles rather than generated Dawn C++
wrapper calls when forced Doe is active; active-Doe present teardown must end Doe
shared texture access before clearing the association. Chromium buffer mailbox
paths must fail closed before wire injection when forced Doe is active and no
native buffer handle source is available.

## Control surfaces

Candidate control surfaces (precedence high -> low):

1. Emergency global kill switch.
2. Explicit command-line/runtime override (`dawn` or `doe`).
3. Enterprise/policy override (if present in integration target).
4. Auto selection policy based on adapter/profile support.
5. Default baseline (`dawn`) when none provided.

## Selection modes

1. `dawn`
   - force incumbent runtime; no fallback is allowed or reported.
2. `doe`
   - force Doe path; initialization failure is a Doe failure, not a Dawn
     fallback.
3. `auto`
   - diagnostic policy mode. The browser runners attempt Doe only when the
     runtime artifact is available and the emergency kill switch is inactive;
     otherwise they select Dawn and emit a typed fallback reason.

## Auto mode preconditions

All required:

1. Emergency disable inactive.
2. Runtime artifact available.
3. Runtime artifact load success.
4. Runtime artifact initializes.
5. Required symbol surface available.
6. Required wire proc table available.
7. Required browser interop procs resolve locally.
8. Required capability checks pass.
9. Profile not denylisted.

If any precondition fails, select `dawn` with explicit fallback reason.
The current Playwright diagnostic selector implements the emergency-disable,
runtime-artifact-availability, and explicit profile-denylist checks. Later
Chromium-integrated selectors must fill in runtime load, symbol, capability,
and adapter-derived profile checks before auto output can support claim
language.

## Fallback reason taxonomy

1. `global_disable_active`
2. `runtime_artifact_missing`
3. `runtime_artifact_load_failed`
4. `runtime_initialization_failed`
5. `symbol_surface_incomplete`
6. `wire_proc_table_incomplete`
7. `profile_denylisted`
8. `capability_requirement_failed`
9. `runtime_health_degraded`
10. `explicit_operator_override`
11. `unknown_selection_error`

No free-form fallback reasons in reporting; reasons must be typed from this taxonomy.

## Evidence blocker mapping

Each fallback reason in the browser policy must map through
`evidenceBlockerMap` to a shared code from
[`config/evidence-blocker-taxonomy.json`](../../../config/evidence-blocker-taxonomy.json).
Browser reports keep the browser-specific `fallbackReasonCode`, while Doe
receipts and gates can interpret the same state through the shared blocker
vocabulary. Forced-Doe failures must never map to `none`.

## Required observability fields

Per runtime session:

1. `selectionMode` (`dawn|doe|auto`)
2. `selectedRuntime` (`dawn|doe`)
3. `forcedMode` (`dawn|doe` for forced claim lanes)
4. `fallbackApplied` (boolean)
5. `fallbackReasonCode` (taxonomy value or empty when not applicable)
6. `hiddenFallbackAllowed` (boolean)
7. `profile`:
   - `vendor`,
   - `api`,
   - `deviceFamily`,
   - `driver`.
8. `adapterDenylist`:
   - `matched`,
   - `reasonCode`,
   - `profileId`,
   - `vendor`,
   - `api`,
   - `deviceFamily`,
   - `driverPattern`.
9. `selectorVersion`
10. `artifactIdentity`:
   - `browserExecutablePath`,
   - `browserExecutableSha256`,
   - `dawnRuntimePath`,
   - `dawnRuntimeSha256`,
   - `doeLibPath`,
   - `doeLibSha256`.
11. `launchArgsHash`

## Trace and report contract

1. Selection fields are emitted in run metadata and trace meta.
2. Fallback events are emitted once per session and linked to run identity.
3. Selection logs must be deterministic for identical profile and controls.

## Failure policy

1. Selector failures must fail closed to `dawn` unless explicit forced mode says otherwise.
2. Forced `doe` mode must fail fast with actionable error if runtime cannot initialize.
3. No silent mode mutation after first successful runtime selection in a session.

## Gating requirements

Blocking before promotion:

1. Schema gate for new selection fields.
2. Correctness gate for mode precedence behavior.
3. Trace gate for selection event and reason consistency.
4. Drop-in gate when artifact lane depends on drop-in ABI.

Advisory:

1. Performance and reliability trend tracking.

## Negative tests

1. Missing artifact -> deterministic fallback with `runtime_artifact_missing`.
2. Missing required symbols -> deterministic fallback with `symbol_surface_incomplete`.
3. Denylisted profile -> deterministic fallback with `profile_denylisted`
   in `auto` mode and an `adapterDenylist` detail row in forced modes.
   Chromium source selection must emit equivalent adapter denylist detail at
   adapter filtering time.
4. Global kill switch -> deterministic fallback with `global_disable_active`.
5. Forced `doe` with failed init -> explicit hard failure, not silent Dawn selection.
6. Forced `doe` with a runtime artifact that cannot create a Doe
   `WGPUInstance` -> explicit `runtime_initialization_failed` hard failure.
7. Forced `doe` with a missing browser-facing WGPU proc -> explicit
   `symbol_surface_incomplete` hard failure.
8. Forced `doe` with a missing local browser interop proc mapping -> explicit
   `wire_proc_table_incomplete` hard failure before native fallback can satisfy
   the generated wire proc table.

## Rollback contract

1. Rollback can be executed via global kill switch without rebuild.
2. Rollback event must include reason and timestamp in run metadata.
3. Rollback does not alter schema or artifact history contracts.

## Promotion preconditions

1. Control-surface precedence implemented and tested.
2. Fallback taxonomy implemented and schema-backed.
3. Fallback-to-evidence-blocker mapping implemented and schema-backed.
4. Required observability fields present in artifacts.
5. Required negative tests pass in CI for target matrix.
