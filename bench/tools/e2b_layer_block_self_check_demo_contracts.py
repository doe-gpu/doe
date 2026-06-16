"""Demo, shell, and tooling structural contracts for E2B self-check."""

from __future__ import annotations

import subprocess
from pathlib import Path

from e2b_layer_block_self_check_context import SelfCheckPaths


def run_demo_tooling_contracts(paths: SelfCheckPaths) -> list[str]:
    REPO_ROOT = paths.repo_root
    failures: list[str] = []

    # C27: emulator lane's runCslWebGpuEmulator() soft-fails the CSL
    # contract check when a matching-depth trace is absent — WGSL
    # must always execute, contract check is an independent axis.
    # Structural regression lock: isolate the function body and assert
    # (1) a try/catch wraps loadCslSemanticTrace, (2) the catch branch
    # sets status="unchecked", (3) the return object emits cslContract.
    # Checking inside the function body (not the whole file) prevents
    # false-passes from comments or variable-name coincidences.
    _main_js = REPO_ROOT / "demos/gemma4-e2b-csl-sim/main.js"
    if _main_js.is_file():
        _js = _main_js.read_text(encoding="utf-8")
        _c27_fails = []
        _sig = "async function runCslWebGpuEmulator()"
        _sig_idx = _js.find(_sig)
        if _sig_idx < 0:
            _c27_fails.append("runCslWebGpuEmulator signature missing from main.js")
        else:
            # Extract the function body by brace-matching from the
            # first '{' after the signature.
            _brace_open = _js.find("{", _sig_idx)
            _depth = 0
            _brace_close = -1
            for _i in range(_brace_open, len(_js)):
                _ch = _js[_i]
                if _ch == "{":
                    _depth += 1
                elif _ch == "}":
                    _depth -= 1
                    if _depth == 0:
                        _brace_close = _i
                        break
            if _brace_close < 0:
                _c27_fails.append(
                    "could not find matching closing brace for "
                    "runCslWebGpuEmulator — parse failure"
                )
            else:
                _body = _js[_brace_open : _brace_close + 1]
                # Strip single-line and block comments so comment text
                # can't satisfy the structural requirements.
                import re as _re_c27
                _body_code = _re_c27.sub(r"//[^\n]*", "", _body)
                _body_code = _re_c27.sub(
                    r"/\*.*?\*/", "", _body_code, flags=_re_c27.DOTALL
                )
                if "loadCslSemanticTrace(" not in _body_code:
                    _c27_fails.append(
                        "runCslWebGpuEmulator no longer calls "
                        "loadCslSemanticTrace — contract check path removed"
                    )
                if "try" not in _body_code or "catch" not in _body_code:
                    _c27_fails.append(
                        "runCslWebGpuEmulator lost its try/catch around "
                        "loadCslSemanticTrace — L>=2 will hard-fail "
                        "without a trace"
                    )
                # Ordering invariant: executeLayerBlockWebGpu() must
                # run BEFORE the try/catch, so WGSL executes regardless
                # of trace availability. If someone moves it inside the
                # try, the whole soft-fail contract breaks.
                _exec_idx = _body_code.find("executeLayerBlockWebGpu(")
                _try_idx = _body_code.find("try")
                if _exec_idx < 0:
                    _c27_fails.append(
                        "runCslWebGpuEmulator no longer calls "
                        "executeLayerBlockWebGpu — WGSL path removed"
                    )
                elif _try_idx >= 0 and _exec_idx > _try_idx:
                    _c27_fails.append(
                        "runCslWebGpuEmulator now calls "
                        "executeLayerBlockWebGpu inside or after the "
                        "try/catch — WGSL would be skipped on trace "
                        "failure, breaking soft-fail contract"
                    )
                if 'status: "unchecked"' not in _body_code and \
                   "status: 'unchecked'" not in _body_code:
                    _c27_fails.append(
                        "runCslWebGpuEmulator no longer sets "
                        'status: "unchecked" in the catch branch — '
                        "soft-fail contract removed"
                    )
                if "cslContract:" not in _body_code:
                    _c27_fails.append(
                        "runCslWebGpuEmulator return object no longer "
                        "emits cslContract field — viewers can't "
                        "distinguish verified from unchecked"
                    )
        if _c27_fails:
            for _f in _c27_fails:
                failures.append(f"C27 FAIL: {_f}")
        else:
            print(
                "  C27 PASS: emulator lane soft-fails CSL contract "
                "check when no matching-depth trace exists (WGSL runs "
                "before try/catch + unchecked branch + cslContract field)"
            )

    # C28: three-way sync for bundle-doc skip lists. The packer
    # promotes marked sections from the source doc to archive-root
    # names. Both the repo
    # claim-discipline gate (source paths) and the archive verifier
    # (archive-root paths) must skip these — they are rule-enumerating
    # by design and name the forbidden phrases the gate rejects. If
    # someone adds a new bundle doc without updating both lists, the
    # next run will either flag the doc's rule prose (false positive)
    # or silently skip a doc that isn't actually governance-grade.
    _packer_path = REPO_ROOT / "bench/tools/pack_cerebras_validation_archive.py"
    _gate_path = REPO_ROOT / "bench/gates/claim_discipline_gate.py"
    _verifier_path = REPO_ROOT / "bench/tools/verify_cerebras_validation_archive.py"
    _c28_fails: list[str] = []
    if not _packer_path.is_file():
        _c28_fails.append("packer missing")
    elif not _gate_path.is_file():
        _c28_fails.append("claim-discipline gate missing")
    elif not _verifier_path.is_file():
        _c28_fails.append("verifier missing")
    else:
        import ast as _ast_c28
        _packer_tree = _ast_c28.parse(_packer_path.read_text(encoding="utf-8"))
        _include_files_tuples: list[tuple[str, str]] = []
        for _node in _ast_c28.walk(_packer_tree):
            _tgt_name = None
            _val = None
            if isinstance(_node, _ast_c28.Assign):
                for _tgt in _node.targets:
                    if isinstance(_tgt, _ast_c28.Name):
                        _tgt_name = _tgt.id
                        _val = _node.value
                        break
            elif isinstance(_node, _ast_c28.AnnAssign):
                if isinstance(_node.target, _ast_c28.Name):
                    _tgt_name = _node.target.id
                    _val = _node.value
            if _tgt_name == "INCLUDE_FILES" and isinstance(
                _val, (_ast_c28.Tuple, _ast_c28.List)
            ):
                for _elt in _val.elts:
                    if (isinstance(_elt, (_ast_c28.Tuple, _ast_c28.List))
                            and len(_elt.elts) == 2
                            and isinstance(_elt.elts[0], _ast_c28.Constant)
                            and isinstance(_elt.elts[1], _ast_c28.Constant)):
                        _include_files_tuples.append(
                            (_elt.elts[0].value, _elt.elts[1].value)
                        )
        _bundle_doc_pairs = []
        for _src, _dst in _include_files_tuples:
            _src_doc = _src.split("#", 1)[0]
            if (_src_doc.startswith("docs/cerebras-evidence-bundle")
                    and _src_doc.endswith(".md")):
                _bundle_doc_pairs.append((_src_doc, _dst))
        if not _bundle_doc_pairs:
            _c28_fails.append(
                "packer INCLUDE_FILES has no cerebras-evidence-bundle "
                "docs — inventory lost?"
            )
        # Use AST to extract the actual literal values, not string
        # slicing (which trips on parens inside comments). For the gate,
        # SKIP_PREFIXES is annotated-assigned to a Tuple[Constant, ...];
        # for the verifier, CLAIM_SCAN_SKIP_ARCHIVE_PATHS is assigned to
        # a Set[Constant, ...].
        def _extract_string_literals(path: Path, var_name: str) -> set[str]:
            _tree = _ast_c28.parse(path.read_text(encoding="utf-8"))
            for _n in _ast_c28.walk(_tree):
                _tn = None
                _tv = None
                if isinstance(_n, _ast_c28.Assign):
                    for _t in _n.targets:
                        if isinstance(_t, _ast_c28.Name) and _t.id == var_name:
                            _tn, _tv = _t.id, _n.value
                            break
                elif isinstance(_n, _ast_c28.AnnAssign):
                    if (isinstance(_n.target, _ast_c28.Name)
                            and _n.target.id == var_name):
                        _tn, _tv = _n.target.id, _n.value
                if _tn == var_name and isinstance(
                    _tv, (_ast_c28.Tuple, _ast_c28.List, _ast_c28.Set)
                ):
                    out: set[str] = set()
                    for _e in _tv.elts:
                        if isinstance(_e, _ast_c28.Constant) and isinstance(
                            _e.value, str
                        ):
                            out.add(_e.value)
                    return out
            return set()

        _gate_skip_paths = _extract_string_literals(
            _gate_path, "SKIP_PREFIXES"
        )
        _verifier_skip_paths = _extract_string_literals(
            _verifier_path, "CLAIM_SCAN_SKIP_ARCHIVE_PATHS"
        )
        if not _gate_skip_paths:
            _c28_fails.append(
                "could not extract SKIP_PREFIXES literals from gate"
            )
        if not _verifier_skip_paths:
            _c28_fails.append(
                "could not extract CLAIM_SCAN_SKIP_ARCHIVE_PATHS "
                "literals from verifier"
            )
        for _src, _dst in sorted(set(_bundle_doc_pairs)):
            if _gate_skip_paths and _src not in _gate_skip_paths:
                _c28_fails.append(
                    f"gate SKIP_PREFIXES missing bundle doc "
                    f"source path: {_src}"
                )
            if _verifier_skip_paths and _dst not in _verifier_skip_paths:
                _c28_fails.append(
                    f"verifier CLAIM_SCAN_SKIP_ARCHIVE_PATHS missing "
                    f"archive-root path: {_dst}"
                )
    if _c28_fails:
        for _f in _c28_fails:
            failures.append(f"C28 FAIL: {_f}")
    else:
        print(
            f"  C28 PASS: bundle-doc skip-lists in sync across packer + "
            f"gate + verifier ({len(set(_bundle_doc_pairs))} archive docs)"
        )

    # C29: negative contract. docs/cerebras-evidence-bundle-pointer.md
    # must NOT appear in packer INCLUDE_FILES. The prep script writes
    # the pointer AFTER pack, so including it would always ship a
    # stale-lag copy with the previous build's archive hash. Comment
    # at packer line ~77 records this intent; C29 enforces it.
    # Walk the INCLUDE_FILES AST subtree for any Constant whose value
    # is the pointer path — catches both bare-string entries and
    # tuple-form (src, dst) entries without a scan of the raw text.
    _pointer_src = "docs/cerebras-evidence-bundle-pointer.md"
    _pointer_in_packer_literal = False
    _packer_tree2 = _ast_c28.parse(_packer_path.read_text(encoding="utf-8"))
    for _n in _ast_c28.walk(_packer_tree2):
        _tv = None
        if isinstance(_n, _ast_c28.AnnAssign) and isinstance(
            _n.target, _ast_c28.Name
        ) and _n.target.id == "INCLUDE_FILES":
            _tv = _n.value
        elif isinstance(_n, _ast_c28.Assign):
            for _t in _n.targets:
                if isinstance(_t, _ast_c28.Name) and _t.id == "INCLUDE_FILES":
                    _tv = _n.value
                    break
        if _tv is not None:
            for _const in _ast_c28.walk(_tv):
                if (isinstance(_const, _ast_c28.Constant)
                        and _const.value == _pointer_src):
                    _pointer_in_packer_literal = True
                    break
    if _pointer_in_packer_literal:
        failures.append(
            f"C29 FAIL: {_pointer_src} is in packer INCLUDE_FILES — "
            "bundling the pointer doc always ships stale-lag hashes "
            "(prep script writes it AFTER pack). Remove it from "
            "INCLUDE_FILES; BUNDLE_META.json inside the archive is "
            "the authoritative reference."
        )
    else:
        print(
            f"  C29 PASS: {_pointer_src} is NOT in packer "
            "INCLUDE_FILES (stale-lag guard holds)"
        )

    # C30: prep-script stage ordering is load-bearing. The shell script
    # chains gates -> pack -> verify -> pointer-write. `set -euo
    # pipefail` means any failing earlier stage aborts the chain, so
    # the pointer is never written from an unverified bundle -- but
    # only if the pointer-write block is AFTER verify in file order.
    # If someone refactors the script and moves the pointer block up
    # (before verify), a bundle that fails verify still mints a
    # pointer doc that lies about what was built. Regression-lock the
    # ordering by substring position.
    _prep_path = REPO_ROOT / "bench/tools/prepare_cerebras_validation_bundle.sh"
    _c30_fails: list[str] = []
    if not _prep_path.is_file():
        _c30_fails.append("prep script missing")
    else:
        _prep_src = _prep_path.read_text(encoding="utf-8")
        _gates_idx = _prep_src.find("run_cerebras_evidence_bundle.py")
        _pack_idx = _prep_src.find("pack_cerebras_validation_archive.py")
        _verify_idx = _prep_src.find("verify_cerebras_validation_archive.py")
        _pointer_write_idx = _prep_src.find('cat > "$POINTER"')
        if _gates_idx < 0:
            _c30_fails.append("prep script no longer invokes gates stage")
        if _pack_idx < 0:
            _c30_fails.append("prep script no longer invokes pack stage")
        if _verify_idx < 0:
            _c30_fails.append("prep script no longer invokes verify stage")
        if _pointer_write_idx < 0:
            _c30_fails.append(
                'prep script no longer writes pointer '
                '(cat > "$POINTER" missing)'
            )
        if not _c30_fails:
            # Use the step-label strings as unique anchors — the script names
            # themselves appear in docstrings and heredocs too.
            _step_gates = _prep_src.find('"1/4  gates:')
            _step_guard = _prep_src.find('"2/4  prepack guard:')
            _step_pack = _prep_src.find('"3/4  pack:')
            _step_verify = _prep_src.find('"4/4  verify:')
            if (
                _step_gates < 0
                or _step_guard < 0
                or _step_pack < 0
                or _step_verify < 0
            ):
                _c30_fails.append(
                    "prep script step labels drifted; expected "
                    '"1/4  gates:", "2/4  prepack guard:", '
                    '"3/4  pack:", "4/4  verify:"'
                )
            elif not (_step_gates < _step_guard < _step_pack < _step_verify):
                _c30_fails.append(
                    "prep script stage order drifted from "
                    "gates -> prepack guard -> pack -> verify"
                )
            elif _pointer_write_idx < _step_verify:
                _c30_fails.append(
                    "prep script writes pointer doc BEFORE verify "
                    "stage — a failing verify would still produce "
                    "a pointer that lies about what was built"
                )
    if _c30_fails:
        for _f in _c30_fails:
            failures.append(f"C30 FAIL: {_f}")
    else:
        print(
            "  C30 PASS: prep-script ordering holds "
            "(gates -> prepack guard -> pack -> verify -> pointer-write)"
        )

    # C31: cerebras-evidence-bundle-tools.md lists every on-disk
    # cerebras-* tool in bench/tools/. Catches drift when a new tool
    # is added without being documented, or when a tool is renamed
    # without updating the index. Narrow by design: only scans
    # bench/tools/*cerebras* (the scope the index doc claims).
    _tools_dir = REPO_ROOT / "bench/tools"
    _index_path = _tools_dir / "cerebras-evidence-bundle-tools.md"
    _c31_fails: list[str] = []
    if not _index_path.is_file():
        _c31_fails.append("bundle tools index missing")
    else:
        _tool_files = sorted(
            p.name for p in _tools_dir.iterdir()
            if p.is_file()
            and "cerebras" in p.name.lower()
            and p.name != _index_path.name
        )
        if not _tool_files:
            _c31_fails.append(
                "no bench/tools/*cerebras* files found — did the "
                "tool directory move?"
            )
        else:
            _index_src = _index_path.read_text(encoding="utf-8")
            _missing = [t for t in _tool_files if t not in _index_src]
            if _missing:
                _c31_fails.append(
                    "bundle tools index does not mention "
                    + ", ".join(_missing)
                )
    if _c31_fails:
        for _f in _c31_fails:
            failures.append(f"C31 FAIL: {_f}")
    else:
        print(
            f"  C31 PASS: bundle tools index lists all {len(_tool_files)} "
            f"cerebras-* tools in bench/tools/"
        )

    # C33: every error-to-preview path in the E2B demo must pipe
    # through stripAnsi(). cs_python's stderr preserves ANSI escape
    # codes that render as literal garbage in the browser; an earlier
    # tick added stripAnsi() but a refactor could silently drop the
    # wrapper. Structural lock: (1) stripAnsi function exists, (2)
    # every `el("<lane>-preview").textContent = String(err...)` call
    # is wrapped. If a new lane's error path forgets stripAnsi, C33
    # fires.
    _main_js_c33 = REPO_ROOT / "demos/gemma4-e2b-csl-sim/main.js"
    _c33_fails: list[str] = []
    if not _main_js_c33.is_file():
        _c33_fails.append("demo main.js missing")
    else:
        _js_c33 = _main_js_c33.read_text(encoding="utf-8")
        if "function stripAnsi(" not in _js_c33:
            _c33_fails.append(
                "stripAnsi() function missing from main.js — ANSI "
                "codes will leak back into the error preview panes"
            )
        if "function formatRunnerError(" not in _js_c33:
            _c33_fails.append(
                "formatRunnerError() function missing from main.js — "
                "runner-failure JSON will render as raw text with \\n "
                "literals instead of unescaped stderr"
            )
        if not _c33_fails:
            import re as _re_c33
            # Find every `.textContent = ...err...` assignment. If the
            # RHS doesn't contain stripAnsi, that's a bypass.
            _leaks = []
            for _m in _re_c33.finditer(
                r'\.textContent\s*=\s*([^;]*err[^;]*);',
                _js_c33,
            ):
                _rhs = _m.group(1)
                if "stripAnsi" not in _rhs:
                    _leaks.append(_rhs.strip()[:80])
            if _leaks:
                _c33_fails.append(
                    "error-to-preview assignment(s) bypass "
                    f"stripAnsi: {_leaks}"
                )
    if _c33_fails:
        for _f in _c33_fails:
            failures.append(f"C33 FAIL: {_f}")
    else:
        print(
            "  C33 PASS: demo error-to-preview paths all pipe "
            "through stripAnsi (no ANSI leak)"
        )

    # C26: summarize_cerebras_evidence_archive.sh succeeds against
    # the most recent archive. Integration-lock: catches a format drift
    # in BUNDLE_META / MANIFEST / lane-status that would break the jq
    # one-liner before a reviewer tries to run it on their copy.
    # Skips cleanly when no archive exists yet.
    import subprocess as _subprocess_c26
    import glob as _glob_c26
    _archives = sorted(
        _glob_c26.glob(str(REPO_ROOT / "bench/out/doe-cerebras-evidence-*.tar.gz")),
        key=lambda p: Path(p).stat().st_mtime if Path(p).is_file() else 0,
        reverse=True,
    )
    if not _archives:
        print(
            "  C26 SKIP: no doe-cerebras-evidence-*.tar.gz archive "
            "present; run prepare_cerebras_validation_bundle.sh to "
            "produce one"
        )
    else:
        _latest = _archives[0]
        _c26_proc = _subprocess_c26.run(
            ["bash",
             str(REPO_ROOT / "bench/tools/summarize_cerebras_evidence_archive.sh"),
             _latest],
            capture_output=True, text=True, check=False, timeout=30,
        )
        if _c26_proc.returncode != 0:
            failures.append(
                f"C26 FAIL: summarize script returned "
                f"{_c26_proc.returncode} on {Path(_latest).name}: "
                f"{_c26_proc.stderr.strip()[:200]}"
            )
        elif "BUNDLE META" not in _c26_proc.stdout:
            failures.append(
                "C26 FAIL: summarize output missing expected "
                "'BUNDLE META' section header — format drift?"
            )
        else:
            print(
                f"  C26 PASS: summarize script runs cleanly on "
                f"{Path(_latest).name} and emits expected sections"
            )

    # C25: every data-copy-for attribute in the SDK-GUI viewer HTML
    # points at an element with matching id in the same file. Catches
    # the class of bug where a copy button references a source id
    # that was renamed or removed — the button would silently do
    # nothing at runtime.
    _viewer_html = REPO_ROOT / "demos/doe-sdk-gui-viewer/index.html"
    if _viewer_html.is_file():
        import re as _re_c25
        _html = _viewer_html.read_text(encoding="utf-8")
        _copy_for_ids = _re_c25.findall(r'data-copy-for="([^"]+)"', _html)
        _element_ids = set(_re_c25.findall(r'\bid="([^"]+)"', _html))
        _missing_targets = [
            tid for tid in _copy_for_ids if tid not in _element_ids
        ]
        if _missing_targets:
            for _m in _missing_targets:
                failures.append(
                    f"C25 FAIL: data-copy-for={_m!r} has no matching id in "
                    f"demos/doe-sdk-gui-viewer/index.html — copy button "
                    f"would silently no-op"
                )
        else:
            print(
                f"  C25 PASS: all {len(_copy_for_ids)} data-copy-for "
                f"targets in SDK-GUI viewer resolve to real element ids"
            )

    # C24: bash -n syntax check on the bundle shell scripts. Catches
    # shell syntax errors (unclosed if, missing fi, stray backticks,
    # malformed heredocs) without executing the pipeline. Fast — it
    # parses only, does not invoke bash subshells.
    _shell_scripts = [
        "bench/tools/prepare_cerebras_validation_bundle.sh",
        "bench/tools/summarize_cerebras_evidence_archive.sh",
    ]
    _c24_fails = []
    for _rel in _shell_scripts:
        _p = REPO_ROOT / _rel
        if not _p.is_file():
            _c24_fails.append(f"{_rel}: missing")
            continue
        import subprocess as _subprocess_c24
        _c24_proc = _subprocess_c24.run(
            ["bash", "-n", str(_p)],
            capture_output=True, text=True, check=False, timeout=15,
        )
        if _c24_proc.returncode != 0:
            _c24_fails.append(
                f"{_rel}: bash -n failed (rc={_c24_proc.returncode}): "
                f"{_c24_proc.stderr.strip()[:200]}"
            )
    if _c24_fails:
        for _f in _c24_fails:
            failures.append(f"C24 FAIL: {_f}")
    else:
        print(
            f"  C24 PASS: {len(_shell_scripts)} bundle shell scripts "
            "parse with bash -n"
        )

    # C23: packer's extension deny-list matches verifier's
    # FORBIDDEN_EXTENSIONS. Both protect against SDK binaries, tensor
    # bytes, and log content. They're maintained in separate files
    # and drift between them is a real risk — e.g. the packer blocks
    # `.f32` but if the verifier didn't, a hand-edited archive could
    # slip those in. Lock the intersection here.
    _packer_py_c23 = REPO_ROOT / "bench/tools/pack_cerebras_validation_archive.py"
    _verifier_py_c23 = REPO_ROOT / "bench/tools/verify_cerebras_validation_archive.py"
    if _packer_py_c23.is_file() and _verifier_py_c23.is_file():
        try:
            import importlib.util as _ilu_c23
            _p_spec = _ilu_c23.spec_from_file_location("_p_c23", str(_packer_py_c23))
            _p_mod = _ilu_c23.module_from_spec(_p_spec)
            _p_spec.loader.exec_module(_p_mod)  # type: ignore[union-attr]
            _v_spec = _ilu_c23.spec_from_file_location("_v_c23", str(_verifier_py_c23))
            _v_mod = _ilu_c23.module_from_spec(_v_spec)
            _v_spec.loader.exec_module(_v_mod)  # type: ignore[union-attr]
            # Packer stores path-fragment denials; extract the subset
            # that are extensions (start with '.' and have no '/').
            _packer_exts = {
                _s for _s in _p_mod.EXCLUDE_SUBSTRINGS
                if _s.startswith(".") and "/" not in _s
            }
            _verifier_exts = set(_v_mod.FORBIDDEN_EXTENSIONS)
            _c23_fails = []
            _only_in_packer = _packer_exts - _verifier_exts
            _only_in_verifier = _verifier_exts - _packer_exts
            if _only_in_packer:
                _c23_fails.append(
                    f"extensions in packer deny-list but not verifier's "
                    f"FORBIDDEN_EXTENSIONS: {sorted(_only_in_packer)}"
                )
            if _only_in_verifier:
                _c23_fails.append(
                    f"extensions in verifier FORBIDDEN_EXTENSIONS but not "
                    f"packer deny-list: {sorted(_only_in_verifier)}"
                )
            if _c23_fails:
                for _f in _c23_fails:
                    failures.append(f"C23 FAIL: {_f}")
            else:
                print(
                    f"  C23 PASS: packer deny-list extensions and "
                    f"verifier FORBIDDEN_EXTENSIONS in sync "
                    f"({len(_packer_exts)} extensions)"
                )

            # C32: path-substring deny-list sync. Mirrors C23 for
            # non-extension entries: packer's EXCLUDE_SUBSTRINGS has
            # path fragments like '/scratch/', '/compile/',
            # 'simulator.log' that would slip past an extension-only
            # verifier check. Sync with verifier FORBIDDEN_PATH_SUBSTRINGS.
            _packer_path_substrs = {
                _s for _s in _p_mod.EXCLUDE_SUBSTRINGS
                if not (_s.startswith(".") and "/" not in _s)
            }
            _verifier_path_substrs = set(
                getattr(_v_mod, "FORBIDDEN_PATH_SUBSTRINGS", set())
            )
            _c32_fails = []
            _only_in_pack_substrs = _packer_path_substrs - _verifier_path_substrs
            _only_in_ver_substrs = _verifier_path_substrs - _packer_path_substrs
            if _only_in_pack_substrs:
                _c32_fails.append(
                    f"path substrings in packer deny-list but not "
                    f"verifier FORBIDDEN_PATH_SUBSTRINGS: "
                    f"{sorted(_only_in_pack_substrs)}"
                )
            if _only_in_ver_substrs:
                _c32_fails.append(
                    f"path substrings in verifier "
                    f"FORBIDDEN_PATH_SUBSTRINGS but not packer "
                    f"deny-list: {sorted(_only_in_ver_substrs)}"
                )
            if _c32_fails:
                for _f in _c32_fails:
                    failures.append(f"C32 FAIL: {_f}")
            else:
                print(
                    f"  C32 PASS: packer path-substring deny-list and "
                    f"verifier FORBIDDEN_PATH_SUBSTRINGS in sync "
                    f"({len(_packer_path_substrs)} substrings)"
                )
        except (OSError, ImportError, AttributeError) as _e23:
            failures.append(f"C23 FAIL: cannot import packer/verifier: {_e23}")

    # C34: governance docs name both hardware-validation paths
    # (Path A = endpoint access, Path B = Cerebras-assisted bundle run).
    # Matches the ask in the external email so the bundle's story
    # doesn't drift from what we told Cerebras. Each doc is checked
    # independently — if any one silently drops Path B, C34 fires with
    # a distinct message pointing at the specific doc.
    _two_path_docs = [
        "docs/cerebras-evidence-bundle.md",
        "docs/hardware-validation-appendix.md",
    ]
    _c34_fails: list[str] = []
    for _rel in _two_path_docs:
        _p = REPO_ROOT / _rel
        if not _p.is_file():
            _c34_fails.append(f"governance doc missing: {_rel}")
            continue
        _body = _p.read_text(encoding="utf-8").lower()
        # Path A marker: endpoint access / --cmaddr. Path B marker:
        # "cerebras-assisted" or "bundle run" phrasing. Both must be
        # mentioned somewhere in the body for the doc to reflect the
        # external ask correctly.
        _has_path_a = ("endpoint" in _body and
                       ("--cmaddr" in _body or "access" in _body))
        _has_path_b = "cerebras-assisted" in _body or "bundle run" in _body
        if not _has_path_a:
            _c34_fails.append(
                f"{_rel} no longer mentions Path A (endpoint access "
                "or --cmaddr)"
            )
        if not _has_path_b:
            _c34_fails.append(
                f"{_rel} no longer mentions Path B "
                "(Cerebras-assisted bundle run)"
            )
    if _c34_fails:
        for _f in _c34_fails:
            failures.append(f"C34 FAIL: {_f}")
    else:
        print(
            f"  C34 PASS: {len(_two_path_docs)} governance docs all "
            "name both hardware-validation paths (A endpoint / B "
            "Cerebras-assisted)"
        )

    # C35: emit_depth_coverage_matrix.DECLARED_DEPTHS must match the
    # cockpit HTML's num-layers-select options. Drift here lies to the
    # viewer: either the tool enumerates depths the UI doesn't offer,
    # or the UI offers depths the tool never evaluates. The honest
    # labeling depends on one source of truth; the check locks them.
    _c35_fails: list[str] = []
    _c35_tool = REPO_ROOT / "bench/tools/emit_depth_coverage_matrix.py"
    _c35_html = REPO_ROOT / "demos/gemma4-e2b-csl-sim/index.html"
    if not _c35_tool.is_file():
        _c35_fails.append(
            "emit_depth_coverage_matrix.py missing — required for C35"
        )
    if not _c35_html.is_file():
        _c35_fails.append(
            "demos/gemma4-e2b-csl-sim/index.html missing — required for C35"
        )
    if not _c35_fails:
        try:
            import importlib.util as _ilu_c35
            _spec35 = _ilu_c35.spec_from_file_location(
                "_doe_depth_tool", str(_c35_tool)
            )
            _mod35 = _ilu_c35.module_from_spec(_spec35)
            _spec35.loader.exec_module(_mod35)  # type: ignore[union-attr]
            _tool_depths = tuple(_mod35.DECLARED_DEPTHS)
        except (OSError, AttributeError, ImportError) as _e35:
            _tool_depths = None
            _c35_fails.append(
                "could not import DECLARED_DEPTHS from "
                f"emit_depth_coverage_matrix.py: {_e35}"
            )
        if _tool_depths is not None:
            _html = _c35_html.read_text(encoding="utf-8")
            # Narrow scan to the num-layers-select <select>...</select>
            # block so other unrelated <option> tags on the page cannot
            # accidentally satisfy the contract.
            _sel_start = _html.find('id="num-layers-select"')
            _sel_end = _html.find("</select>", _sel_start) if _sel_start >= 0 else -1
            if _sel_start < 0 or _sel_end < 0:
                _c35_fails.append(
                    "num-layers-select <select> block not found in "
                    "cockpit index.html"
                )
            else:
                _block = _html[_sel_start:_sel_end]
                import re as _re_c35
                _html_depths = tuple(
                    int(_m) for _m in _re_c35.findall(
                        r'value="(\d+)"', _block
                    )
                )
                if _tool_depths != _html_depths:
                    _c35_fails.append(
                        f"depth drift: tool={list(_tool_depths)} "
                        f"cockpit={list(_html_depths)} "
                        "(order and membership both matter — the cockpit "
                        "selector order is user-visible)"
                    )
    if _c35_fails:
        for _f in _c35_fails:
            failures.append(f"C35 FAIL: {_f}")
    else:
        print(
            "  C35 PASS: DECLARED_DEPTHS in emit_depth_coverage_matrix.py "
            "matches cockpit num-layers-select options (order + "
            f"membership) — {list(_tool_depths)}"
        )


    return failures
