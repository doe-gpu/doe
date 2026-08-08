# Doe package model

Doe has one public npm package: `doe-gpu`.

The authoritative package contract is:

- [`../packages/doe-gpu/package.json`](../packages/doe-gpu/package.json) for
  exports, engines, files, scripts, and optional dependencies;
- [`../packages/doe-gpu/README.md`](../packages/doe-gpu/README.md) for user
  installation and usage;
- [`internal-tooling.md`](internal-tooling.md) for the public versus repo-only
  boundary.

Do not copy the export list into this document. Platform packages must publish
before the wrapper version that references them. Legacy `@simulatte/*` names
are migration history, not separate product families.
