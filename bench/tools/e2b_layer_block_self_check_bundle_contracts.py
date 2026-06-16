"""Evidence-bundle governance contracts for E2B self-check."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

from e2b_layer_block_self_check_context import SelfCheckPaths


def run_bundle_contracts(paths: SelfCheckPaths) -> list[str]:
    REPO_ROOT = paths.repo_root
    failures: list[str] = []
    # C22: packager's INCLUDE_FILES and CLAIM_ROLE dict stay in sync.
    # Every archive path in INCLUDE_FILES must have a CLAIM_ROLE entry
    # (otherwise MANIFEST.txt shows 'UNLABELED'); every CLAIM_ROLE key
    # must appear in INCLUDE_FILES (otherwise the label is dead code).
    # Imports the packager module to read the live tuples.
    _packer_py = REPO_ROOT / "bench/tools/pack_cerebras_validation_archive.py"
    if _packer_py.is_file():
        try:
            import importlib.util as _ilu_c22
            _pspec = _ilu_c22.spec_from_file_location(
                "_doe_packer", str(_packer_py)
            )
            _pmod = _ilu_c22.module_from_spec(_pspec)
            _pspec.loader.exec_module(_pmod)  # type: ignore[union-attr]
            _archive_paths = set()
            for _entry in _pmod.INCLUDE_FILES:
                if isinstance(_entry, tuple):
                    _archive_paths.add(_entry[1])
                else:
                    _archive_paths.add(_entry)
            _role_keys = set(_pmod.CLAIM_ROLE.keys())
            _c22_fails = []
            _unlabeled = _archive_paths - _role_keys
            if _unlabeled:
                _c22_fails.append(
                    f"INCLUDE_FILES without CLAIM_ROLE entry: "
                    f"{sorted(_unlabeled)}"
                )
            _dead = _role_keys - _archive_paths
            if _dead:
                _c22_fails.append(
                    f"CLAIM_ROLE entries without INCLUDE_FILES match "
                    f"(dead code): {sorted(_dead)}"
                )
            if _c22_fails:
                for _f in _c22_fails:
                    failures.append(f"C22 FAIL: {_f}")
            else:
                print(
                    f"  C22 PASS: packager INCLUDE_FILES and CLAIM_ROLE "
                    f"in sync ({len(_archive_paths)} archive paths, "
                    f"{len(_role_keys)} claim-role entries)"
                )
        except (OSError, ImportError, AttributeError) as _e22:
            failures.append(f"C22 FAIL: cannot import packer: {_e22}")
    else:
        failures.append(
            f"C22 FAIL: packer missing at "
            f"{_packer_py.relative_to(REPO_ROOT)}"
        )

    # C21: MoE TODO receipts use artifactKind=doe_moe_<component>_todo,
    # NOT ...*_receipt. If a TODO were renamed to end in _receipt, the
    # claim-discipline gate's find_moe_receipt() would false-unlock
    # the MoE-claim gate. Lock the 6 TODOs' artifactKind shape here
    # so a rename is caught at self-check time, not at claim-leak time.
    _moe_todo_expected = {
        "bench/out/26b-moe-lane/router-todo.json":
            "doe_moe_router_todo",
        "bench/out/26b-moe-lane/topk-selection-todo.json":
            "doe_moe_topk_selection_todo",
        "bench/out/26b-moe-lane/token-dispatch-todo.json":
            "doe_moe_token_dispatch_todo",
        "bench/out/26b-moe-lane/shared-expert-todo.json":
            "doe_moe_shared_expert_todo",
        "bench/out/26b-moe-lane/output-combine-todo.json":
            "doe_moe_output_combine_todo",
        "bench/out/26b-moe-lane/per-expert-batching-todo.json":
            "doe_moe_per_expert_batching_todo",
    }
    _c21_fails = []
    for _rel, _expected in _moe_todo_expected.items():
        _p = REPO_ROOT / _rel
        if not _p.is_file():
            _c21_fails.append(f"{_rel}: missing")
            continue
        try:
            _d = json.loads(_p.read_text(encoding="utf-8"))
        except json.JSONDecodeError as _e21:
            _c21_fails.append(f"{_rel}: unreadable: {_e21}")
            continue
        _ak = _d.get("artifactKind") or ""
        if _ak != _expected:
            _c21_fails.append(
                f"{_rel}: artifactKind={_ak!r}, expected {_expected!r}"
            )
        if _ak.endswith("_receipt"):
            _c21_fails.append(
                f"{_rel}: artifactKind ends in '_receipt' — this "
                f"would false-unlock the MoE claim-discipline gate"
            )
    if _c21_fails:
        for _f in _c21_fails:
            failures.append(f"C21 FAIL: {_f}")
    else:
        print(
            "  C21 PASS: 6 MoE TODO files use _todo artifactKinds "
            "(none ends in _receipt so the MoE claim gate stays ACTIVE)"
        )

    # C20: lane-label consistency across fixtures + MoE lane-status.
    # The three lane labels express the target-ordering commitment
    # (E2B=primary_correctness_target, 31B=dense_scale_target,
    # 26B/A4B MoE=blocked_efficiency_lane) recorded in the
    # hardware-validation appendix. Regression-lock by file so a
    # rename in one place without the others is caught immediately.
    _lane_label_checks = [
        (
            "config/gemma-4-e2b-real-weight-fixture.json",
            "laneLabel",
            "primary_correctness_target",
        ),
        (
            "config/gemma-4-31b-real-weight-fixture.json",
            "laneLabel",
            "dense_scale_target",
        ),
        (
            "bench/out/26b-moe-lane/lane-status.json",
            "laneLabel",
            "blocked_efficiency_lane",
        ),
    ]
    _c20_fails = []
    for _rel, _field, _expected in _lane_label_checks:
        _p = REPO_ROOT / _rel
        if not _p.is_file():
            _c20_fails.append(f"{_rel}: missing")
            continue
        try:
            _d = json.loads(_p.read_text(encoding="utf-8"))
        except json.JSONDecodeError as _e20:
            _c20_fails.append(f"{_rel}: unreadable JSON: {_e20}")
            continue
        _actual = _d.get(_field)
        if _actual != _expected:
            _c20_fails.append(
                f"{_rel}: {_field}={_actual!r}, expected {_expected!r}"
            )
    if _c20_fails:
        for _f in _c20_fails:
            failures.append(f"C20 FAIL: {_f}")
    else:
        print(
            "  C20 PASS: lane labels consistent across E2B fixture "
            "(primary_correctness_target), 31B fixture "
            "(dense_scale_target), 26B/A4B lane-status "
            "(blocked_efficiency_lane)"
        )

    # C19: evidence-bundle summary shape. Reads
    # bench/out/cerebras-evidence-bundle/summary.json and asserts the
    # shape every downstream consumer depends on: verdict in
    # {passed, failed}, totalSteps == len(steps), each step carries
    # (step, status, returnCode, elapsedMs). Regression-locks the
    # bundle runner's output so the jq summary script, the verifier,
    # and the packager's inclusion of summary.json all continue to
    # see a stable contract.
    _bundle_summary = REPO_ROOT / "bench/out/cerebras-evidence-bundle/summary.json"
    if _bundle_summary.is_file():
        try:
            _bs = json.loads(_bundle_summary.read_text(encoding="utf-8"))
            _c19_fails = []
            if _bs.get("artifactKind") != "doe_cerebras_evidence_bundle_summary":
                _c19_fails.append(
                    f"artifactKind={_bs.get('artifactKind')!r}, "
                    "expected 'doe_cerebras_evidence_bundle_summary'"
                )
            if _bs.get("verdict") not in ("passed", "failed"):
                _c19_fails.append(
                    f"verdict={_bs.get('verdict')!r}, "
                    "expected one of passed/failed"
                )
            _steps = _bs.get("steps") or []
            if _bs.get("totalSteps") != len(_steps):
                _c19_fails.append(
                    f"totalSteps={_bs.get('totalSteps')} but "
                    f"len(steps)={len(_steps)}"
                )
            _required_step_keys = {"step", "status", "returnCode", "elapsedMs"}
            _any_failed_step = False
            for _i, _step in enumerate(_steps):
                if not isinstance(_step, dict):
                    _c19_fails.append(f"steps[{_i}] not a dict")
                    continue
                _missing = _required_step_keys - set(_step.keys())
                if _missing:
                    _c19_fails.append(
                        f"steps[{_i}] missing keys: {sorted(_missing)}"
                    )
                # Explicit None rejection for elapsedMs (user #14): a
                # key-present-but-null slipped past the set-difference
                # check. Require a numeric value.
                if not isinstance(_step.get("elapsedMs"), (int, float)):
                    _c19_fails.append(
                        f"steps[{_i}] elapsedMs="
                        f"{_step.get('elapsedMs')!r} (must be numeric)"
                    )
                if _step.get("status") == "failed":
                    _any_failed_step = True
            # verdict/steps consistency (user #13): verdict=passed
            # with any failed step inside is a category-1 lie — the
            # summary claims success while individual steps disagree.
            if _bs.get("verdict") == "passed" and _any_failed_step:
                _c19_fails.append(
                    "verdict='passed' but at least one step has "
                    "status='failed' — inconsistent summary"
                )
            if _c19_fails:
                for _f in _c19_fails:
                    failures.append(f"C19 FAIL: {_f}")
            else:
                print(
                    "  C19 PASS: evidence-bundle summary has "
                    f"{len(_steps)} steps with stable shape"
                )
        except (OSError, json.JSONDecodeError) as _e19:
            failures.append(f"C19 FAIL: summary unreadable: {_e19}")
    else:
        # Fresh clone / never-run state: summary hasn't been produced
        # yet. Skip cleanly rather than forcing the self-check to
        # invoke the 15s+ bundle runner. C16 covers pack/verify; C19
        # only validates the shape when a summary exists.
        print(
            "  C19 SKIP: evidence-bundle summary not yet produced "
            "(run bench/tools/run_cerebras_evidence_bundle.py to "
            "generate)"
        )

    # C18: demo HTML structural sanity. Confirms the three Gemma-4-
    # facing demo pages exist with balanced <main> tags, at least one
    # <script> reference, and cross-link anchors to the sibling two.
    # Catches accidental deletion, major HTML breakage, or nav
    # regression. Purely string-level — no HTML parser dependency.
    _demo_checks = [
        (
            "demos/doe-status-dashboard/index.html",
            ["../gemma4-e2b-csl-sim/", "../doe-sdk-gui-viewer/"],
        ),
        (
            "demos/gemma4-e2b-csl-sim/index.html",
            ["../doe-status-dashboard/", "../doe-sdk-gui-viewer/"],
        ),
        (
            "demos/doe-sdk-gui-viewer/index.html",
            ["../doe-status-dashboard/", "../gemma4-e2b-csl-sim/"],
        ),
    ]
    _c18_fails = []
    for _rel, _expected_links in _demo_checks:
        _p = REPO_ROOT / _rel
        if not _p.is_file():
            _c18_fails.append(f"{_rel}: missing")
            continue
        _html = _p.read_text(encoding="utf-8", errors="replace")
        if _html.count("<main") < 1 or _html.count("</main>") < 1:
            _c18_fails.append(f"{_rel}: missing balanced <main> tags")
        if "<script" not in _html:
            _c18_fails.append(f"{_rel}: missing <script> reference")
        for _link in _expected_links:
            if _link not in _html:
                _c18_fails.append(f"{_rel}: missing cross-link to {_link}")
        if _rel == "demos/doe-sdk-gui-viewer/index.html":
            for _needle in [
                "sdk-command-copy",
                "bundle-runner-command-copy",
                "archive-pack-command-copy",
                "archive-verify-command-copy",
                "color-list",
                "fabric-grid",
                "pe-coordinate-input",
                "timeline-controls",
                "timeline-rows",
                "data-copy-for=\"sdk-command\"",
                "data-copy-for=\"archive-verify-command\"",
            ]:
                if _needle not in _html:
                    _c18_fails.append(
                        f"{_rel}: missing command control {_needle}"
                    )
    if _c18_fails:
        for _f in _c18_fails:
            failures.append(f"C18 FAIL: {_f}")
    else:
        print(
            "  C18 PASS: 3 demo HTML pages have balanced <main>, "
            "<script> reference, sibling cross-links, and SDK-GUI "
            "fabric/timeline/command controls"
        )

    # C17: SDK-GUI viewer server routes regression lock. Imports
    # DemoHandler from demos/gemma4-e2b-csl-sim/server.py and calls
    # its inspection methods directly (passing None as self — the
    # methods don't use self). Positive path: a known compile dir +
    # known trace path return ok=True with expected keys. Negative:
    # traversal + missing both return ok=False with clear errors.
    # Without this, the /api routes can silently break and the
    # viewer goes dark without self-check noticing.
    _server_py = REPO_ROOT / "demos/gemma4-e2b-csl-sim/server.py"
    if _server_py.is_file():
        try:
            import importlib.util as _ilu_c17
            _spec = _ilu_c17.spec_from_file_location(
                "_doe_demo_server", str(_server_py)
            )
            _mod = _ilu_c17.module_from_spec(_spec)
            _spec.loader.exec_module(_mod)  # type: ignore[union-attr]
            _inspect_dir = _mod.DemoHandler.inspect_workdir
            _inspect_trace = _mod.DemoHandler.inspect_trace_host_io
            _inspect_bundle = _mod.DemoHandler.inspect_bundle_summary
            _inspect_commands = _mod.DemoHandler.inspect_evidence_commands

            _positive_dir = _inspect_dir(
                None, "bench/out/scratch/gemma4-e2b-csl-sim/compile-L1"
            )
            _positive_trace = _inspect_trace(
                None, "bench/out/scratch/gemma4-e2b-csl-sim/csl-L1-live-trace.json"
            )
            _positive_commands = _inspect_commands(None)
            _neg_traversal = _inspect_dir(None, "../../etc")
            _neg_absolute = _inspect_trace(None, "/tmp")
            _neg_missing = _inspect_trace(None, "bench/out/nonexistent-trace.json")

            # Bundle-summary route: shape-check only; the absent path
            # case is exercised elsewhere. Here we just assert that
            # when a summary exists it's reported with verdict and
            # step counts, and when absent the route returns
            # {ok: false, hint} (fail-closed).
            _positive_bundle = _inspect_bundle(None)
            _c17_problems = []
            if not (_positive_dir.get("ok") and _positive_dir.get("numSdkArtifacts", 0) > 0):
                _c17_problems.append(
                    f"positive workdir path did not return SDK artifacts: "
                    f"{_positive_dir}"
                )
            if not (_positive_trace.get("ok") and _positive_trace.get("hostIoLayout")):
                _c17_problems.append(
                    f"positive trace path did not return hostIoLayout"
                )
            _commands = _positive_commands.get("commands") or {}
            _copyable = _positive_commands.get("copyable") or {}
            for _cmd_key, _substring in [
                ("bundleRunner", "run_cerebras_evidence_bundle.py"),
                ("archivePack", "pack_cerebras_validation_archive.py"),
                ("archiveVerify", "verify_cerebras_validation_archive.py"),
            ]:
                if _substring not in (_commands.get(_cmd_key) or ""):
                    _c17_problems.append(
                        f"evidence-commands missing {_substring} "
                        f"in {_cmd_key}: {_positive_commands}"
                    )
            if _copyable.get("bundleRunner") is not True:
                _c17_problems.append(
                    "evidence-commands bundleRunner must be copyable"
                )
            if _copyable.get("archivePack") is not True:
                _c17_problems.append(
                    "evidence-commands archivePack must be copyable"
                )
            # bundle-summary: either ok=true with verdict+totalSteps,
            # OR ok=false with a hint string — both are valid fail-
            # closed shapes; silent bad shape (e.g. ok=true but no
            # verdict) is the regression we lock against.
            if _positive_bundle.get("ok") is True:
                if _positive_bundle.get("verdict") not in ("passed", "failed"):
                    _c17_problems.append(
                        f"bundle-summary ok=true but "
                        f"verdict={_positive_bundle.get('verdict')!r}"
                    )
                if not isinstance(_positive_bundle.get("totalSteps"), int):
                    _c17_problems.append(
                        f"bundle-summary ok=true but totalSteps not int"
                    )
            else:
                # ok=false must carry a hint string so the cockpit
                # can surface it honestly rather than show a spinner.
                if not _positive_bundle.get("hint"):
                    _c17_problems.append(
                        f"bundle-summary ok=false but no hint — "
                        f"cockpit has nothing to tell the reviewer"
                    )
            for tag, result in [
                ("traversal", _neg_traversal),
                ("absolute", _neg_absolute),
                ("missing", _neg_missing),
            ]:
                if result.get("ok") is not False:
                    _c17_problems.append(
                        f"negative {tag} path unexpectedly returned ok=True: {result}"
                    )

            if _c17_problems:
                for p in _c17_problems:
                    failures.append(f"C17 FAIL: {p}")
            else:
                print(
                    "  C17 PASS: SDK-GUI viewer /api routes respond "
                    "correctly on positive + negative paths, including "
                    "evidence command metadata"
                )
        except (OSError, ImportError, AttributeError) as _e17:
            failures.append(f"C17 FAIL: cannot import server inspection functions: {_e17}")
    else:
        failures.append(
            f"C17 FAIL: server.py missing at {_server_py.relative_to(REPO_ROOT)}"
        )

    # C16: Cerebras evidence bundle pack + verify round-trip. Packs a
    # fresh archive to a scratch location, runs the verifier against
    # it, asserts both exit 0. Catches: missing governance doc (any
    # of CLAIM_SCOPE/README/CEREBRAS_ASK/LOCAL_INSPECTION) dropping
    # out of INCLUDE_FILES, claim-discipline drift inside packed
    # archive docs, manifest sha integrity regression, BUNDLE_META
    # schema drift. This is the end-to-end lock on the whole
    # Cerebras-facing bundle pipeline.
    try:
        import subprocess as _subprocess_c16
        import tempfile as _tempfile_c16
        with _tempfile_c16.TemporaryDirectory() as _scratch:
            _scratch_archive = (
                Path(_scratch) / "doe-cerebras-evidence-selfcheck.tar.gz"
            )
            _c16_pack = _subprocess_c16.run(
                ["python3", "bench/tools/pack_cerebras_validation_archive.py",
                 "--allow-dirty", "--out", str(_scratch_archive)],
                cwd=REPO_ROOT, capture_output=True, text=True, check=False,
            )
            if _c16_pack.returncode != 0:
                failures.append(
                    f"C16 FAIL: pack_cerebras_validation_archive.py "
                    f"returned {_c16_pack.returncode}: "
                    f"{_c16_pack.stderr[-200:]}"
                )
            elif not _scratch_archive.is_file():
                failures.append(
                    "C16 FAIL: packer reported success but archive "
                    "was not written"
                )
            else:
                _c16_verify = _subprocess_c16.run(
                    ["python3",
                     "bench/tools/verify_cerebras_validation_archive.py",
                     "--archive", str(_scratch_archive)],
                    cwd=REPO_ROOT, capture_output=True, text=True, check=False,
                )
                if _c16_verify.returncode != 0:
                    failures.append(
                        f"C16 FAIL: verifier returned "
                        f"{_c16_verify.returncode} on freshly packed "
                        f"archive: {_c16_verify.stdout[-300:]}"
                    )
                else:
                    print(
                        "  C16 PASS: Cerebras evidence bundle "
                        "pack+verify round-trip clean"
                    )
    except (OSError, subprocess.TimeoutExpired) as _e16:
        failures.append(
            f"C16 FAIL: bundle round-trip error: {_e16}"
        )

    print()

    return failures
