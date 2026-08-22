#!/usr/bin/env python3
"""Fail closed unless a Fawn-Doe aggregate qualifies for a release passport."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bench.fawn_matrix.harness.live_evidence import (  # noqa: E402
    LiveEvidenceError,
    validate_passport_candidate,
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--aggregate", type=Path, required=True)
    args = parser.parse_args()
    with args.aggregate.open(encoding="utf-8") as handle:
        validate_passport_candidate(json.load(handle))
    print("PASS")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except LiveEvidenceError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1) from None
