# Doe Python style guide

This guide is the Python style contract for `bench/`, `pipeline/`, `scripts/`,
and Python helper tooling under `runtime/zig/tools/`.

## Core principles

- Fail fast with descriptive errors. No silent fallbacks.
- Type-annotate all function signatures.
- Prefer `pathlib.Path` over `os.path`.
- Keep modules focused. Shard at 1200 lines.
- Fairness before speed: benchmark code must prove both sides did equivalent
  work before presenting a faster result as evidence.
- Read raw timing before percent deltas. Use `baselineStatsMs` and
  `comparisonStatsMs` to compute the speed ratio before saying a result is a
  win.
- Treat speedups at or above the configured
  `reliability.suspiciousSpeedupRatio` as suspected path or measurement
  differences until the report proves otherwise. Check cache/prepared-session
  state, skipped work, one-sided setup/upload/submit/readback costs, hidden
  fallback, stale artifacts, and timing scope before accepting the result.

## File naming

- Modules: `snake_case.py` (e.g. `bench_utils.py`, `config_validation.py`).
- Test files: `test_<module>.py` (e.g. `test_mine_quirks.py`,
  `test_config_schemas.py`).
- Shell-invoked entry points: prefer `kebab-case.py`
  (e.g. `check-health.py`).
- Imported utility modules may stay `snake_case.py` even when they are also
  runnable as scripts.

## Imports

- Use `from __future__ import annotations` in new files and keep it at the top
  when present.
- Standard library first, then third-party, then local.
- Use absolute imports. No relative imports.
- Prefer `pathlib.Path` for new code; legacy files still use `os.path` in a
  few places.

```python
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any
```

## Naming

- Functions: `snake_case` (`load_json`, `build_match_object`,
  `detect_repo_root`)
- Classes: `PascalCase` (`ToggleHit`, `SchemaTargetEntry`)
- Variables and fields: `snake_case` (`toggle_candidates`, `scanned_files`)
- Constants: `UPPER_SNAKE_CASE` (`HASH_SEED`, `ZIG_MAX_LINES`,
  `DEFAULT_ALLOWED_SUFFIXES`)
- Private functions: leading underscore (`_infer_schema_path`,
  `_format_path`)
- Boolean variables: `is_`/`has_`/`should_` prefix when the bare name is
  ambiguous

## Type hints

- Annotate all function parameters and return types.
- Use modern union syntax: `str | None`, not `Optional[str]`.
- Use built-in generic syntax: `list[str]`, `dict[str, Any]`, not
  `List[str]`.
- Use `Any` sparingly. Prefer narrow types when the shape is known.

```python
def load_validated_config(
    config_path: str | Path,
    schema_path: str | Path | None = None,
) -> dict[str, Any]:
```

## Docstrings

- NumPy-style with triple double quotes.
- Module-level docstrings for all non-trivial modules.
- Function docstrings for public functions. Omit for trivial helpers.
- Use `Parameters`, `Returns`, `Raises` sections for complex signatures.

```python
def load_json(path: Path) -> Any:
    """Load a JSON or JSONL file and return its parsed content.

    For ``.json`` files the return type mirrors the top-level JSON value.
    For ``.jsonl`` files a list of parsed objects is returned.
    """
```

## Error handling

- Raise specific exception types: `FileNotFoundError`, `ValueError`,
  `json.JSONDecodeError`.
- Include actionable context: what was expected, what was received, which
  file.
- Use `from exc` for exception chaining.
- Prefer specific exception types. Bare `Exception` still appears in a few
  legacy aggregation paths that need to keep processing, but it should be
  avoided in new code.

```python
if not config_path.exists():
    raise FileNotFoundError(f"config file not found: {config_path}")
```

## Entry points

- Use `def main() -> int:` returning 0/1.
- Prefer `if __name__ == "__main__": raise SystemExit(main())` for new
  scripts.
- Most entry points parse arguments in a separate `parse_args()` function, but
  small legacy helpers may inline CLI setup.

```python
def main() -> int:
    args = parse_args()
    # ... work ...
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
```

## CLI arguments

- Use `argparse` with structured argument definitions.
- Hyphenated names: `--source-root`, `--allow-suffix`.
- `help` text for every argument.
- `required=True` for mandatory arguments.
- `choices=[]` for enumerated values.

## JSON handling

- Always specify `encoding="utf-8"` in file operations.
- Canonical output: `json.dumps(value, indent=2, sort_keys=True) + "\n"`.
- JSONL: one object per line, skip blank lines on read.

```python
path.write_text(
    json.dumps(payload, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
```

## Data classes

- Use `@dataclass` for simple structured data.
- Use `@dataclass(frozen=True)` for immutable records.
- Prefer dataclasses over raw dicts for typed internal state.

## Formatting

- Line length: prefer 80 characters in new and touched files; the tree is not
  uniformly enforced yet.
- 4-space indentation (PEP 8 default).
- Run formatters before commit. No specific tool mandated, but output must
  comply with line length and PEP 8.

## Testing

- Use `unittest.TestCase` class-based tests.
- Test naming: `test_<what_is_being_tested>` (descriptive, snake_case).
- Dynamic test generation with `setattr` for schema fuzz tests.
- Run with `python -m unittest discover` or direct `unittest.main()`.

```python
class TestSchemaCompliance(unittest.TestCase):
    def test_reference_toggle_schema(self):
        record = self._make_candidate()
        errors = _validate_quirk_record(record)
        self.assertEqual(errors, [], f"schema errors: {errors}")
```

## Comments

- Comments explain why, not what.
- Section separators: `# ---` or `# ===` for major sections in large files.
- No TODO/FIXME inline. Track follow-ups in the status log (`docs/status.md`, with dated entries in the current `docs/status/*.md` shard).

## File size

- 1200 lines max per Python file.
- When exceeded, add a tracked sharding follow-up in the current status shard.
- Split by cohesive functionality, not arbitrary line count.
