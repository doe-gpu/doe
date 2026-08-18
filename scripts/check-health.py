#!/usr/bin/env python3
"""Fawn repository health checker.

Validates code-health invariants across the repo:
  - Zig file size limits (runtime/zig/src/, ≤999 lines, excluding *_test.zig)
  - Python file size limits (bench/ + pipeline/, ≤1200 lines)
  - Config schema coverage (every config/*.json has a schema)
  - Schema validation (config JSON validates against its schema)
  - Orphaned top-level directories (/fawn/, /lean/, /zig/)
  - doe-gpu vendor freshness (doe-namespace.js vs webgpu-doe index.js)

Run from repo root:  python3 scripts/check-health.py
Requires: Python 3.10+, jsonschema (pip install jsonschema)
"""

from __future__ import annotations

import glob
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

ZIG_SRC_DIR = REPO_ROOT / "runtime" / "zig" / "src"
ZIG_MAX_LINES = 999

PYTHON_DIRS = [REPO_ROOT / "bench", REPO_ROOT / "pipeline"]
PYTHON_MAX_LINES = 1200

CONFIG_DIR = REPO_ROOT / "config"
SCHEMA_TARGETS_PATH = CONFIG_DIR / "schema-targets.json"

ORPHAN_DIRS = ["fawn", "lean", "zig"]

VENDOR_FILE = REPO_ROOT / "packages" / "doe-gpu" / "src" / "vendor" / "doe-namespace.js"
UPSTREAM_FILE = REPO_ROOT / "packages" / "webgpu-doe" / "src" / "index.js"


def count_lines(path: Path) -> int:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return sum(1 for _ in f)


GOVERNED_OVERSIZE_ZIG = {
    "runtime/zig/src/backend/vulkan/native_runtime.zig",
    "runtime/zig/src/compiler/wgsl/emit/spirv/emit_spirv_fn.zig",
    "runtime/zig/src/core/abi/generated/webgpu_upstream.zig",
    "runtime/zig/src/native/shader/doe_shader_native.zig",
    "runtime/zig/src/native/vulkan/vulkan_compute_native.zig",
}

GOVERNED_OVERSIZE_PYTHON = {
    "bench/browser/browser_gate.py",
    "bench/gates/claim_index_browser_release.py",
    "bench/gates/claim_index_browser_release_proof.py",
    "bench/gates/claim_index_browser_release_receipts.py",
    "bench/lib/ecosystem_registry.py",
    "bench/native-compare/compare_doe_vs_tint_compilation.py",
    "bench/native_compare_modules/compare_assessment.py",
    "bench/runners/blocking_gates_args.py",
    "bench/runners/csl-runners/e2b_layer_block_smoke.py",
    "bench/runners/csl-runners/gemma_4_31b_layer_block_smoke.py",
    "bench/runners/csl-runners/manifest_dense_gemv_tiles.py",
    "bench/runners/csl-runners/manifest_kernel_probe_runner.py",
    "bench/tests/test_browser_benchmark_superset_checker.py",
    "bench/tests/test_browser_published_proof_surface.py",
    "bench/tests/test_browser_release_artifact_bundle.py",
    "bench/tests/test_browser_runtime_frontier_bundle.py",
    "bench/tests/test_claim_index_gate.py",
    "bench/tests/test_dawn_replacement_readiness_report.py",
    "bench/tests/test_int4ple_hostplan_runtime_timeout.py",
    "bench/tests/test_int4ple_scheduler_readiness.py",
    "bench/tests/test_manifest_kernel_probe_runner.py",
    "bench/tests/test_node_webgpu_executor.py",
    "bench/tools/build_dawn_replacement_readiness_report.py",
    "bench/tools/check_browser_published_proof_surface.py",
    "bench/tools/check_browser_release_artifact_bundle.py",
    "bench/tools/check_browser_release_package_inputs.py",
    "bench/tools/check_tint_compiler_frontier_bundle.py",
    "bench/tools/generate_e2b_layer_block_runner.py",
    "bench/tools/run_doe_csl_int4ple_transcript.py",
}


# ---------- check 1: Zig file sizes ----------

def check_zig_sizes() -> list[str]:
    failures: list[str] = []
    if not ZIG_SRC_DIR.is_dir():
        return [f"directory not found: {ZIG_SRC_DIR}"]
    for p in sorted(ZIG_SRC_DIR.rglob("*.zig")):
        if p.name.endswith("_test.zig"):
            continue
        rel = str(p.relative_to(REPO_ROOT))
        if rel in GOVERNED_OVERSIZE_ZIG:
            continue
        n = count_lines(p)
        if n > ZIG_MAX_LINES:
            failures.append(f"  {rel}: {n} lines (max {ZIG_MAX_LINES})")
    return failures


# ---------- check 2: Python file sizes ----------

def check_python_sizes() -> list[str]:
    failures: list[str] = []
    for d in PYTHON_DIRS:
        if not d.is_dir():
            continue
        for p in sorted(d.rglob("*.py")):
            # Skip vendored third-party code
            try:
                rel_parts = p.relative_to(d).parts
            except ValueError:
                rel_parts = ()
            if "vendor" in rel_parts:
                continue
            rel = str(p.relative_to(REPO_ROOT))
            if rel in GOVERNED_OVERSIZE_PYTHON:
                continue
            n = count_lines(p)
            if n > PYTHON_MAX_LINES:
                failures.append(f"  {rel}: {n} lines (max {PYTHON_MAX_LINES})")
    return failures


# ---------- check 3: Config schema coverage ----------

def check_schema_coverage() -> list[str]:
    """Report config/*.json files that have no corresponding schema."""
    failures: list[str] = []
    if not CONFIG_DIR.is_dir():
        return [f"directory not found: {CONFIG_DIR}"]

    # Build set of data files that are covered by schema-targets.json
    covered: set[str] = set()
    if SCHEMA_TARGETS_PATH.is_file():
        with open(SCHEMA_TARGETS_PATH, "r") as f:
            st = json.load(f)
        for entry in st.get("targets", []):
            data_path = (REPO_ROOT / entry["data"]).resolve()
            covered.add(str(data_path))
        for entry in st.get("globTargets", []):
            for match in glob.glob(str(REPO_ROOT / entry["glob"])):
                covered.add(str(Path(match).resolve()))

    for p in sorted(CONFIG_DIR.glob("*.json")):
        if p.name.endswith(".schema.json"):
            continue
        resolved = str(p.resolve())
        if resolved in covered:
            continue
        # Fallback: check naming convention (foo.json -> foo.schema.json)
        stem = p.stem
        # Handle multi-dot names: foo.policy.json -> foo.policy.schema.json
        candidate = p.with_name(stem + ".schema.json")
        if candidate.is_file():
            continue
        # Also try stripping last dot-segment: foo.policy.json -> foo.schema.json
        if "." in stem:
            base = stem.rsplit(".", 1)[0]
            candidate2 = CONFIG_DIR / (base + ".schema.json")
            if candidate2.is_file():
                continue
        rel = p.relative_to(REPO_ROOT)
        failures.append(f"  {rel}: no schema found")
    return failures


# ---------- check 4: Schema validation ----------

def check_schema_validation() -> list[str]:
    """Validate config JSON files against their schemas."""
    try:
        import jsonschema
    except ImportError:
        return ["  jsonschema not installed — skipping schema validation (pip install jsonschema)"]

    failures: list[str] = []

    pairs: list[tuple[Path, Path]] = []  # (schema_path, data_path)

    if SCHEMA_TARGETS_PATH.is_file():
        with open(SCHEMA_TARGETS_PATH, "r") as f:
            st = json.load(f)
        for entry in st.get("targets", []):
            schema_path = REPO_ROOT / entry["schema"]
            data_path = REPO_ROOT / entry["data"]
            if schema_path.is_file() and data_path.is_file():
                pairs.append((schema_path, data_path))
        for entry in st.get("globTargets", []):
            schema_path = REPO_ROOT / entry["schema"]
            if not schema_path.is_file():
                continue
            for match in sorted(glob.glob(str(REPO_ROOT / entry["glob"]))):
                pairs.append((schema_path, Path(match)))
    else:
        # Fallback: infer from naming convention
        for p in sorted(CONFIG_DIR.glob("*.json")):
            if p.name.endswith(".schema.json"):
                continue
            candidate = p.with_name(p.stem + ".schema.json")
            if candidate.is_file():
                pairs.append((candidate, p))

    for schema_path, data_path in pairs:
        try:
            with open(schema_path, "r") as f:
                schema = json.load(f)
            if str(data_path).endswith(".jsonl"):
                # JSONL: validate each line independently
                with open(data_path, "r") as f:
                    for i, line in enumerate(f, 1):
                        line = line.strip()
                        if not line:
                            continue
                        row = json.loads(line)
                        jsonschema.validate(instance=row, schema=schema)
                continue
            with open(data_path, "r") as f:
                data = json.load(f)
            jsonschema.validate(instance=data, schema=schema)
        except json.JSONDecodeError as e:
            rel = data_path.relative_to(REPO_ROOT)
            failures.append(f"  {rel}: invalid JSON — {e}")
        except jsonschema.ValidationError as e:
            rel_data = data_path.relative_to(REPO_ROOT)
            failures.append(f"  {rel_data}: {e.message}")
        except jsonschema.SchemaError as e:
            rel_schema = schema_path.relative_to(REPO_ROOT)
            failures.append(f"  {rel_schema} (schema error): {e.message}")
        except Exception as e:
            rel_data = data_path.relative_to(REPO_ROOT)
            failures.append(f"  {rel_data}: unexpected error — {e}")

    return failures


# ---------- check 5: Orphaned directories ----------

def check_orphaned_dirs() -> list[str]:
    failures: list[str] = []
    for name in ORPHAN_DIRS:
        d = REPO_ROOT / name
        if d.is_dir():
            failures.append(f"  {name}/: orphaned top-level directory exists")
    return failures


# ---------- check 6: doe-gpu vendor freshness ----------

def _strip_leading_block(lines: list[str], is_header: callable) -> list[str]:
    """Strip leading header lines and one blank line separator."""
    i = 0
    while i < len(lines) and is_header(lines[i]):
        i += 1
    # Skip one blank separator line
    if i < len(lines) and lines[i].strip() == "":
        i += 1
    return lines[i:]


def _strip_deprecation_block(lines: list[str]) -> list[str]:
    """Strip the deprecation warning if/block and trailing blank line."""
    i = 0
    # Find the closing `}` of the top-level if block
    if i < len(lines) and lines[i].strip().startswith("if ("):
        brace_depth = 0
        while i < len(lines):
            line = lines[i]
            brace_depth += line.count("{") - line.count("}")
            i += 1
            if brace_depth <= 0:
                break
    # Skip one blank separator line
    if i < len(lines) and lines[i].strip() == "":
        i += 1
    return lines[i:]

def check_vendor_freshness() -> list[str]:
    if not VENDOR_FILE.is_file():
        return [f"  vendor file not found: {VENDOR_FILE.relative_to(REPO_ROOT)}"]
    if not UPSTREAM_FILE.is_file():
        # packages/webgpu-doe was retired after package consolidation into packages/doe-gpu
        return []

    def read_lines(path: Path) -> list[str]:
        with open(path, "r", encoding="utf-8") as f:
            return f.readlines()

    vendor_lines = read_lines(VENDOR_FILE)
    upstream_lines = read_lines(UPSTREAM_FILE)

    # Strip vendor header: leading // comment lines and the blank line after them
    vendor_body = _strip_leading_block(vendor_lines, lambda l: l.startswith("//"))

    # Strip upstream deprecation warning: everything up through the closing }
    # and the blank line that follows it
    upstream_body = _strip_deprecation_block(upstream_lines)

    if vendor_body == upstream_body:
        return []

    # Find first difference for reporting
    max_lines = max(len(vendor_body), len(upstream_body))
    for i in range(max_lines):
        v = vendor_body[i] if i < len(vendor_body) else "<EOF>"
        u = upstream_body[i] if i < len(upstream_body) else "<EOF>"
        if v != u:
            return [
                f"  files diverged at content line {i + 1}:",
                f"    vendor:   {v.rstrip()!r}",
                f"    upstream: {u.rstrip()!r}",
                f"  vendor body: {len(vendor_body)} lines, upstream body: {len(upstream_body)} lines",
            ]
    return [f"  line count mismatch: vendor={len(vendor_body)}, upstream={len(upstream_body)}"]


# ---------- runner ----------

def main() -> int:
    all_pass = True

    checks: list[tuple[str, callable]] = [
        ("Zig file sizes (runtime/zig/src/, max 999 lines)", check_zig_sizes),
        ("Python file sizes (bench/ + pipeline/, max 1200 lines)", check_python_sizes),
        ("Config schema coverage", check_schema_coverage),
        ("Schema validation", check_schema_validation),
        ("Orphaned top-level directories", check_orphaned_dirs),
        ("doe-gpu vendor freshness", check_vendor_freshness),
    ]

    for title, fn in checks:
        print(f"--- {title} ---")
        failures = fn()
        if failures:
            all_pass = False
            print("FAIL")
            for line in failures:
                print(line)
        else:
            print("PASS")
        print()

    if all_pass:
        print("All checks passed.")
        return 0
    else:
        print("Some checks failed.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
