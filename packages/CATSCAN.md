# CATSCAN: Packages

Parent: [Doe](../CATSCAN.md)

## Target

Ship installable public packages and platform binaries whose exports, dependencies, provenance, and support tuples are explicit.

## Authority

- Owns package composition, platform-package resolution, publication ordering, and shipped public files.
- Does not own native runtime semantics, browser replacement, or support claims beyond package evidence.

## Scope

- Includes files beneath this directory except child-chartered components, which narrow this authority.

## Contracts

Inputs:
- Package model: [`../docs/package-model.md`](../docs/package-model.md).
- Tool surface manifest: [`../config/tool-surfaces.json`](../config/tool-surfaces.json).

Outputs:
- JavaScript package and optional native platform packages consumed by supported applications.

## Invariants

- Package exports match the declared public tooling surface.
- Supported installation does not require a local Zig build.
- Package evidence cannot promote native, browser, or hardware claims.

## Acceptance

- Exported entrypoints and declared package paths pass the tool-surface gate.
- Evidence: [`../bench/gates/tool_surface_gate.py`](../bench/gates/tool_surface_gate.py).

## Non-goals

- Treating every platform artifact or compatibility wrapper as a promoted runtime surface.

## Freedom

Any mechanism is permitted if it preserves these boundaries and passes the acceptance evidence.
