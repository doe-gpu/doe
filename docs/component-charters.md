# Component charter protocol

CATSCAN charters make component intent recursive, discoverable, and
mechanically guarded without constraining internal algorithms.

## Authority files

| File | Owns |
| --- | --- |
| `GOALS.md` | Repository mission, value, and durable goals |
| `CATSCAN.md` | One component's target, authority, scope, contracts, invariants, and acceptance |
| `AGENTS.md` | Charter discovery, precedence, and change protocol |
| `README.md` | Human usage and navigation |
| ADR or design document | Why a mechanism was selected |
| Tests, registries, reports, receipts | Current evidence and status |

A charter states what must remain true, not how to implement it. Existing code
does not override a charter.

## Recursive rule

Before changing a file, read the nearest `AGENTS.md`, canonical project goals,
and every `CATSCAN.md` from the repository root to the target directory. For
multi-directory changes, read the union of applicable chains. Children may
narrow their parent but cannot broaden authority, weaken invariants, or
contradict it.

Explicit user direction may change intent. Update the affected charter with the
implementation; never rewrite a charter merely to excuse failing behavior or
evidence.

Discover charters with:

```bash
rg --files -g CATSCAN.md
```

Add a charter only for an independently meaningful outcome, persisted contract,
state authority, policy or promotion boundary, or testable subsystem. Generated,
vendored, cache, fixture, utility, and mechanical directories inherit.

## Required shape

```markdown
# CATSCAN: <Component>

Parent: [<parent component>](../CATSCAN.md)

## Target
<One observable outcome.>

## Authority
- Owns <state, decisions, or contracts>.
- Does not own <adjacent authority>.

## Scope
- Includes <governed behavior or paths>.

## Contracts
- Input: <shape and canonical link>.
- Output: <shape and canonical link>.

## Invariants
- <Condition that remains true>.
- <Failure, fallback, or claim that remains explicit>.

## Acceptance
- <Observable check, command, test, or receipt>.
- Evidence: [CATSCAN gate](../bench/gates/catscan_gate.py).

## Non-goals
- <Tempting adjacent responsibility rejected here>.

## Freedom
Any implementation is permitted if it preserves these boundaries and passes the acceptance evidence.
```

The repository root uses `Parent: none`. Keep charters below 250 words. Put
algorithms, history, roadmaps, tutorials, and current status in linked owners.

## Mechanical validation

```bash
python3 bench/gates/catscan_gate.py --write-index
python3 bench/gates/catscan_gate.py
python3 -m unittest bench.tests.test_catscan_gate
```

The gate validates shape, nearest parents, identifiers, local links, acceptance
evidence, size, and the generated [`component-index.md`](component-index.md).
Semantic alignment remains a review obligation.

Handoffs state:

```text
Component: <name>
Intent: preserved | changed
Acceptance evidence: <commands or artifacts>
Boundary effects: none | <named components>
```
