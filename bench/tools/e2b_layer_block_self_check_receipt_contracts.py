"""Receipt, kernel, and real-weight fixture contracts for E2B self-check."""

from __future__ import annotations

import ast
import json
import subprocess
from typing import Any

from e2b_layer_block_self_check_context import SelfCheckPaths, sha256_file


def run_receipt_contracts(
    paths: SelfCheckPaths,
) -> tuple[list[str], dict[str, Any], dict[str, Any]]:
    REPO_ROOT = paths.repo_root
    runner_path = paths.runner_path
    kernel_path = paths.kernel_path
    synthetic_path = paths.synthetic_path
    receipt_path = paths.receipt_path
    schema_path = paths.schema_path
    failures: list[str] = []

    # C1: live kernel sha == synthetic trace's kernelSourceSha256InTrace
    if not synthetic_path.is_file():
        failures.append("C1: synthetic trace missing at " + str(synthetic_path))
    else:
        live_sha = sha256_file(kernel_path)
        syn = json.loads(synthetic_path.read_text(encoding="utf-8"))
        in_trace = syn.get("layerBlockSmoke", {}).get("kernelSourceSha256")
        if in_trace == live_sha:
            print(
                "  C1 PASS: synthetic trace kernel sha matches live kernel "
                f"({live_sha[:16]}...)"
            )
        else:
            failures.append(
                f"C1 FAIL: synthetic trace kernel sha {in_trace} "
                f"!= live kernel sha {live_sha}"
            )

    # C2: receipt validates
    try:
        import jsonschema
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
        jsonschema.validate(receipt, schema)
        print("  C2 PASS: receipt validates against schema")
    except ImportError:
        print("  C2 SKIP: jsonschema not importable")
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    except jsonschema.ValidationError as e:
        failures.append(
            f"C2 FAIL: receipt schema violation at "
            f"{list(e.absolute_path)}: {e.message[:200]}"
        )
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    except Exception as e:
        failures.append(f"C2 FAIL: {type(e).__name__}: {str(e)[:200]}")
        receipt = {}

    lbk = (
        receipt.get("streamingExecutorPrimitivesEvidence", {})
        .get("layerBlockKernelEvidence", {})
    )

    # C3: receipt.syntheticTrace.exists + sha matches on-disk
    syn_block = lbk.get("syntheticTrace", {})
    if syn_block.get("exists") is True:
        recorded_sha = syn_block.get("sha256")
        on_disk_sha = sha256_file(synthetic_path) if synthetic_path.is_file() else None
        if recorded_sha == on_disk_sha:
            print(
                "  C3 PASS: receipt.syntheticTrace.sha256 matches on-disk "
                f"({recorded_sha[:16]}...)"
            )
        else:
            failures.append(
                f"C3 FAIL: receipt.syntheticTrace.sha256={recorded_sha} "
                f"!= on-disk={on_disk_sha}"
            )
    else:
        failures.append(
            "C3 FAIL: receipt.syntheticTrace.exists is not True "
            f"({syn_block.get('exists')!r})"
        )

    # C4: receipt.crossRuntimeParityCheck.exists + promotionEligible field present
    pc_block = lbk.get("crossRuntimeParityCheck", {})
    if pc_block.get("exists") is True and "promotionEligible" in pc_block:
        print(
            "  C4 PASS: receipt.crossRuntimeParityCheck.promotionEligible "
            f"= {pc_block.get('promotionEligible')}"
        )
    else:
        failures.append(
            f"C4 FAIL: parity check block invalid "
            f"(exists={pc_block.get('exists')}, "
            f"has promotionEligible={'promotionEligible' in pc_block})"
        )

    # C5: runner regen produced a parseable Python file
    if runner_path.is_file():
        try:
            ast.parse(runner_path.read_text(encoding="utf-8"))
            print("  C5 PASS: regenerated runner parses as Python")
        except SyntaxError as e:
            failures.append(f"C5 FAIL: runner syntax error: {e.msg} at line {e.lineno}")
    else:
        failures.append(f"C5 FAIL: runner missing at {runner_path}")

    # C6: receipt.kernelStage matches the synthetic trace's kernelStage.
    # The kernelStage string is hardcoded in three places (runner source,
    # synthetic emitter, receipt builder). If any one drifts relative to
    # the others the evidence chain silently misrepresents the kernel.
    # This assertion catches receipt-vs-synthetic drift; the runner source
    # is caught transitively when its smoke trace is eventually re-run
    # and compared via the cross-runtime parity check (P2).
    receipt_stage = lbk.get("kernelStage")
    syn_stage = (
        syn.get("layerBlockSmoke", {}).get("kernelStage")
        if synthetic_path.is_file() else None
    )
    if receipt_stage and syn_stage and receipt_stage == syn_stage:
        print(
            "  C6 PASS: receipt.kernelStage matches synthetic trace "
            f"kernelStage ({receipt_stage[:48]}...)"
        )
    else:
        failures.append(
            "C6 FAIL: receipt.kernelStage vs synthetic kernelStage drift:\n"
            f"    receipt:   {receipt_stage!r}\n"
            f"    synthetic: {syn_stage!r}"
        )

    # C7: executionStatus reflects the parity verdict correctly.
    # Locks the flip wire in build_model_runtime_receipt.py — if the
    # wire is accidentally reverted to a hardcoded 'not_attempted' or
    # a false 'simulator_success' sneaks in without matching parity
    # evidence, C7 flips red. The flip requires: promotionEligible=true
    # AND structural gates pass AND modelId is E2B.
    pc_block_c7 = lbk.get("crossRuntimeParityCheck", {})
    pc_eligible = pc_block_c7.get("promotionEligible") is True
    model_id = receipt.get("modelId", "") or ""
    parity_applies = "e2b" in model_id.lower()
    structural_ok = (
        receipt.get("laneStatus") == "structural_full_coverage"
    )
    _rw_criteria = (
        (receipt.get("realWeightEvidence") or {})
        .get("promotionCriteriaMet") or {}
    )
    _rw_promoted = (
        _rw_criteria.get("weightHashMatched") is True
        and _rw_criteria.get("outputParityPassed") is True
    )
    if pc_eligible and parity_applies and structural_ok and _rw_promoted:
        expected_status = "real_weight_layer_block_success"
    elif pc_eligible and parity_applies and structural_ok:
        expected_status = "simulator_success"
    else:
        expected_status = "not_attempted"
    expected_blocker = (
        "none"
        if (pc_eligible and parity_applies and structural_ok)
        else None
    )
    actual_status = receipt.get("executionStatus")
    actual_blocker = receipt.get("executionBlocker")
    status_ok = actual_status == expected_status
    blocker_ok = (expected_blocker is None) or (actual_blocker == expected_blocker)
    if status_ok and blocker_ok:
        print(
            "  C7 PASS: executionStatus reflects parity verdict "
            f"(promotionEligible={pc_eligible}, "
            f"status={actual_status!r}, blocker={actual_blocker!r})"
        )
    else:
        failures.append(
            "C7 FAIL: executionStatus flip wire inconsistent with "
            "parity verdict:\n"
            f"    promotionEligible: {pc_eligible}\n"
            f"    parityApplies:     {parity_applies}\n"
            f"    structuralOk:      {structural_ok}\n"
            f"    realWeightPromoted: {_rw_promoted}\n"
            f"    expected status:   {expected_status!r}\n"
            f"    actual status:     {actual_status!r}\n"
            f"    expected blocker:  {expected_blocker!r}\n"
            f"    actual blocker:    {actual_blocker!r}"
        )

    # C8: the auto-regenerated CSL reference parity sample passes
    # its own gate. Schema validation + internal consistency checks
    # (cslRun.traceSha256 matches on-disk, cslRun.kernelStage matches
    # the trace, manifest/graph path+sha match). Catches structural
    # regressions in emit_csl_reference_parity_sample.py that schema-
    # only validation (C2) wouldn't catch.
    sample_path = (
        "examples/"
        "doe-csl-reference-parity.gemma-4-e2b-layer-block.sample.json"
    )
    sample_gate = subprocess.run(
        ["python3", "bench/gates/csl_reference_parity_gate.py",
         "--receipt", sample_path],
        cwd=str(REPO_ROOT), capture_output=True, text=True,
    )
    if sample_gate.returncode == 0:
        print(
            "  C8 PASS: CSL reference parity sample passes its gate"
        )
    else:
        failures.append(
            "C8 FAIL: CSL reference parity gate rejected the sample:\n"
            f"    stdout: {sample_gate.stdout.strip()[:400]}\n"
            f"    stderr: {sample_gate.stderr.strip()[:200]}"
        )

    # C9: 31B receipt link integrity. Catches drift between the 31B
    # receipt and its underlying host-plan / memory-plan / runtime-
    # config / simulator-plan on disk. E2B gets its own link-integrity
    # via STEP 5 after the E2B regen in STEP 4; 31B is not regen'd in
    # this pipeline (Build-order step 7 material), but its receipt
    # must still link cleanly to match the plan's "receipts link
    # cleanly" mechanical-defensibility criterion.
    b31_receipt = (
        REPO_ROOT / "bench/out/31b-full-graph/gemma-4-31b-runtime-receipt.json"
    )
    if b31_receipt.is_file():
        b31_link_gate = subprocess.run(
            ["python3", "bench/tools/validate_e2b_receipt_links.py",
             "--receipt", str(b31_receipt.relative_to(REPO_ROOT))],
            cwd=str(REPO_ROOT), capture_output=True, text=True,
        )
        if b31_link_gate.returncode == 0:
            last = [
                ln for ln in b31_link_gate.stdout.strip().splitlines()
                if ln.strip().startswith("PASS")
            ]
            summary = last[-1].strip() if last else "PASS"
            print(f"  C9 PASS: 31B receipt link integrity ({summary})")
        else:
            failures.append(
                "C9 FAIL: 31B receipt link-integrity gate rejected:\n"
                f"    stdout: {b31_link_gate.stdout.strip()[:400]}\n"
                f"    stderr: {b31_link_gate.stderr.strip()[:200]}"
            )
    else:
        failures.append(
            f"C9 FAIL: 31B receipt missing at {b31_receipt}"
        )

    # C12: repo-wide audit — no CSL kernel outside diagnostic probes
    # uses raw `math.sqrt` without wrapping it in the sqrt_nr NR-
    # refined form. The WSE hardware sqrt is 1-ULP off from IEEE-
    # correct-rounded at some input magnitudes (that was the L2
    # drift unlocking simulator_success); future kernels adopting
    # sqrt must use the sqrt_nr pattern. Diagnostic probe files in
    # e2b-layer-block-source/ (stage*_probe.csl, stage3_*_only.csl,
    # stage3_rms_*.csl) are scratch and exempted.
    production_probe_suffixes = (
        "_probe.csl", "_only.csl", "_f64.csl", "_nr.csl",
    )
    csl_audit_skip_prefixes = (
        "bench/out/scratch/",
        "bench/out/scratch/csl-sdk-tmp/",
        # Dated/deprecated generated runs are provenance, not the live
        # production kernel contract this self-check gates.
        "bench/out/overnight/",
        "bench/out/doppler-reference/gemma-3-1b-doe-csl-hostplan/",
    )
    audit_fails = []
    audit_scanned = 0
    for _csl in REPO_ROOT.rglob("*.csl"):
        _rel = _csl.relative_to(REPO_ROOT).as_posix()
        if any(_rel.startswith(prefix) for prefix in csl_audit_skip_prefixes):
            continue
        if _csl.name.endswith(production_probe_suffixes):
            continue
        audit_scanned += 1
        try:
            _text = _csl.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        if "math.sqrt(" in _text and "fn sqrt_nr(" not in _text:
            audit_fails.append(_rel)
    if not audit_fails:
        print(
            "  C12 PASS: no CSL production kernel uses raw math.sqrt "
            "outside the sqrt_nr NR-refined wrapper "
            f"(scanned {audit_scanned} CSL files)"
        )
    else:
        failures.append(
            "C12 FAIL: CSL kernels using raw math.sqrt without "
            "sqrt_nr NR-refined wrapper:\n"
            + "\n".join("    " + p for p in audit_fails)
            + "\n    Apply the `math.sqrt(x) + 0.5*(y + x/y)` "
            "pattern (see transformer_layer_shape.csl sqrt_nr)."
        )

    # C11: sqrt_nr function in the canonical E2B kernel uses the
    # math.sqrt(x) + one-Newton-Raphson-step form that unlocked
    # simulator_success. The prior body — a 16-iteration NR loop
    # starting from y=1.0/y=x — converged to a value 1 ULP off from
    # IEEE-correctly-rounded at L2 magnitudes (mean_sq2 ~ 1229),
    # which drifted inv_rms2 by 1 ULP and cascaded through stage 4
    # to a 4.959e-05 L2 output error. Reject that form if it
    # reappears (silent revert).
    kernel_src = kernel_path.read_text(encoding="utf-8")
    import re as _re
    m = _re.search(
        r"fn sqrt_nr\(x: f32\) f32 \{(.*?)\n\}",
        kernel_src,
        flags=_re.DOTALL,
    )
    if m is None:
        failures.append("C11 FAIL: sqrt_nr function not found in kernel")
    else:
        body = m.group(1)
        has_math_sqrt_seed = "math.sqrt(x)" in body
        has_nr_step = (
            "0.5 * (y0 + x / y0)" in body
            or "0.5 * (y + x / y)" in body
        )
        looks_like_old_loop = (
            "@range(u16, 16)" in body
            or "for (@range(u16, 16))" in body
        )
        if has_math_sqrt_seed and has_nr_step and not looks_like_old_loop:
            print(
                "  C11 PASS: sqrt_nr uses math.sqrt + 1 NR step "
                "(IEEE-correctly-rounded f32 sqrt form)"
            )
        else:
            failures.append(
                "C11 FAIL: sqrt_nr body regression. Expected "
                "`math.sqrt(x)` seed + `0.5 * (y0 + x / y0)` NR step; "
                "reject the 16-iteration loop.\n"
                f"    has_math_sqrt_seed: {has_math_sqrt_seed}\n"
                f"    has_nr_step:        {has_nr_step}\n"
                f"    looks_like_old_loop: {looks_like_old_loop}\n"
                f"    body (first 300 chars):\n{body[:300]}"
            )

    # C13: 31B receipt's crossRuntimeParityCheck.promotionEligible
    # is True AND links to the 31B-specific parity artifact.
    # Symmetric with C4 for E2B. Locks tick-11 per-model parity
    # lane so 31B can't silently revert to binding the E2B artifact
    # or losing its parity evidence.
    if b31_receipt.is_file():
        try:
            _b31 = json.loads(b31_receipt.read_text(encoding="utf-8"))
        except json.JSONDecodeError as e:
            failures.append(
                f"C13 FAIL: 31B receipt JSON parse: {e}"
            )
        else:
            _b31_pc = (
                _b31.get("streamingExecutorPrimitivesEvidence", {})
                .get("layerBlockKernelEvidence", {})
                .get("crossRuntimeParityCheck", {})
            )
            _expected_path_fragment = "gemma-4-31b-layer-block"
            _pc_path = _b31_pc.get("path") or ""
            if (
                _b31_pc.get("exists") is True
                and _b31_pc.get("promotionEligible") is True
                and _expected_path_fragment in _pc_path
            ):
                print(
                    "  C13 PASS: 31B receipt binds its own parity "
                    f"artifact, promotionEligible=True "
                    f"({_pc_path[-60:]})"
                )
            else:
                failures.append(
                    "C13 FAIL: 31B receipt's parity binding off:\n"
                    f"    exists: {_b31_pc.get('exists')}\n"
                    f"    promotionEligible: {_b31_pc.get('promotionEligible')}\n"
                    f"    path: {_pc_path!r}\n"
                    f"    expected path contains: {_expected_path_fragment!r}"
                )

    # C10: 31B receipt validates against the model-runtime-receipt
    # schema, symmetric with C2 for E2B. Locks T16/T17 improvements
    # so the 31B receipt can't silently drift out of schema shape.
    if b31_receipt.is_file():
        try:
            import jsonschema as _js
            b31_json = json.loads(b31_receipt.read_text(encoding="utf-8"))
            _schema = json.loads(schema_path.read_text(encoding="utf-8"))
            _js.validate(b31_json, _schema)
            print("  C10 PASS: 31B receipt validates against schema")
        except ImportError:
            print("  C10 SKIP: jsonschema not importable")
        except _js.ValidationError as e:
            failures.append(
                "C10 FAIL: 31B receipt schema violation at "
                f"{list(e.absolute_path)}: {e.message[:200]}"
            )
        except Exception as e:
            failures.append(
                f"C10 FAIL: 31B receipt validation error: "
                f"{type(e).__name__}: {str(e)[:200]}"
            )

    # C14: real-weight fixture bundle integrity. Every sha256 the
    # fixture pins for manifest/graph/input must match the bytes on
    # disk. If any artifact drifts, the eventual parity run would
    # silently compare the wrong program — this is the regression
    # lock that catches the drift at self-check time instead.
    _fixture_path = REPO_ROOT / "config/gemma-4-e2b-real-weight-fixture.json"
    if _fixture_path.is_file():
        try:
            _fix = json.loads(_fixture_path.read_text(encoding="utf-8"))
            import hashlib as _hashlib_c14
            _c14_misses = []
            for _label, _node_path in [
                ("manifest", ("bundle", "manifest")),
                ("graph", ("bundle", "graph")),
                ("input", ("input",)),
            ]:
                _node = _fix
                for _k in _node_path:
                    _node = (_node or {}).get(_k, {})
                _rel = _node.get("path")
                _expected = _node.get("sha256")
                if not (_rel and _expected):
                    _c14_misses.append(f"fixture missing path/sha for {_label}")
                    continue
                _abs = REPO_ROOT / _rel
                if not _abs.is_file():
                    _c14_misses.append(f"{_label} path {_rel} not on disk")
                    continue
                _h = _hashlib_c14.sha256()
                with _abs.open("rb") as _fh:
                    for _ch in iter(lambda: _fh.read(1 << 20), b""):
                        _h.update(_ch)
                _actual = _h.hexdigest()
                if _actual != _expected:
                    _c14_misses.append(
                        f"{_label} {_rel} sha256 drift: fixture={_expected[:12]}... "
                        f"actual={_actual[:12]}..."
                    )
            if not _c14_misses:
                print(
                    "  C14 PASS: real-weight fixture bundle integrity "
                    "(manifest+graph+input shas match on-disk bytes)"
                )
            else:
                for _m in _c14_misses:
                    failures.append(f"C14 FAIL: {_m}")

            # C15: parity harness state is coherent with the local
            # real-weight materialization state. Fresh clones still pass
            # with blocked_weights_absent; hosts with materialized weights
            # must at least pass the weights audit, and promoted hosts must
            # show parity_passed with tolerance evidence. parity_failed is
            # always a regression.
            import subprocess as _subprocess_c15
            _c15_canonical = (
                REPO_ROOT / "bench/out/gemma-4-e2b-real-weight-parity-L1.json"
            )
            _fixture_sha_c15 = sha256_file(_fixture_path)
            _canonical_current_fixture = False
            if _c15_canonical.is_file():
                try:
                    _canonical_current_fixture = (
                        json.loads(
                            _c15_canonical.read_text(encoding="utf-8")
                        ).get("fixtureSha256")
                        == _fixture_sha_c15
                    )
                except (OSError, ValueError, json.JSONDecodeError):
                    _canonical_current_fixture = False
            _weights_rel = (
                (_fix.get("weightsDir") or {}).get("pathPlaceholder") or ""
            )
            _weights_abs = REPO_ROOT / _weights_rel
            if (
                _weights_abs.is_dir()
                and _c15_canonical.is_file()
                and _canonical_current_fixture
            ):
                _c15_out = _c15_canonical
                _c15 = None
            else:
                _c15_out = (
                    REPO_ROOT
                    / "bench/out/scratch/gemma-4-e2b-real-weight-parity-C15.json"
                )
                _c15_out.parent.mkdir(parents=True, exist_ok=True)
                _c15 = _subprocess_c15.run(
                    ["python3", "bench/tools/run_e2b_real_weight_l1_parity.py",
                     "--out-json", str(_c15_out.relative_to(REPO_ROOT))],
                    cwd=REPO_ROOT, capture_output=True, text=True, timeout=1800,
                )
            if _c15 is not None and _c15.returncode != 0:
                failures.append(
                    f"C15 FAIL: parity harness returned {_c15.returncode}: "
                    f"{_c15.stderr[-200:]}"
                )
            elif not _c15_out.is_file():
                failures.append("C15 FAIL: parity harness wrote no verdict")
            else:
                _v = json.loads(_c15_out.read_text(encoding="utf-8"))
                _verdict = _v.get("verdict")
                _bundle_ok = _v.get("bundleIdentityMatched")
                _weights_present = _v.get("weightsDirPresent")
                _audit_ok = _v.get("weightsAuditPassed")
                _expected_weight_sha = (
                    (_fix.get("weightsDir") or {})
                    .get("expectedWeightSetSha256")
                )
                _actual_weight_sha = _v.get("weightSetSha256")
                _weight_sha_ok = (
                    _expected_weight_sha is None
                    or _actual_weight_sha == _expected_weight_sha
                )
                _parity = _v.get("parity") or {}
                _tolerance_ok = bool(
                    _parity.get("outputDigestMatch")
                    or _parity.get("tolerancePassed")
                )
                if _verdict == "blocked_weights_absent" and _bundle_ok is True:
                    print(
                        "  C15 PASS: parity harness skeleton exits "
                        "blocked_weights_absent with bundleIdentityMatched=true"
                    )
                elif (
                    _verdict == "lane_incomplete"
                    and _bundle_ok is True
                    and _weights_present is True
                    and _audit_ok is True
                    and _weight_sha_ok
                ):
                    print(
                        "  C15 PASS: real-weight harness audited weights "
                        "but a runtime lane is incomplete on this host "
                        f"(weightSetSha256={str(_actual_weight_sha)[:16]}...)"
                    )
                elif (
                    _verdict == "parity_passed"
                    and _bundle_ok is True
                    and _weights_present is True
                    and _audit_ok is True
                    and _weight_sha_ok
                    and _tolerance_ok
                ):
                    print(
                        "  C15 PASS: real-weight L1 parity passed with "
                        "bundle identity + weights audit + tolerance evidence "
                        f"(weightSetSha256={str(_actual_weight_sha)[:16]}...)"
                    )
                else:
                    failures.append(
                        f"C15 FAIL: parity harness verdict={_verdict!r} "
                        f"bundleIdentityMatched={_bundle_ok!r}, "
                        f"weightsDirPresent={_weights_present!r}, "
                        f"weightsAuditPassed={_audit_ok!r}, "
                        f"weightShaOk={_weight_sha_ok!r}, "
                        f"toleranceOk={_tolerance_ok!r}; expected either "
                        "blocked_weights_absent for fresh clones, "
                        "lane_incomplete with audited weights, or "
                        "parity_passed with audited weights + tolerance."
                    )
        except (OSError, ValueError, json.JSONDecodeError) as _e:
            failures.append(f"C14/C15 FAIL: fixture evaluation error: {_e}")
    else:
        failures.append(
            f"C14 FAIL: fixture missing at {_fixture_path.relative_to(REPO_ROOT)}"
        )


    return failures, receipt, lbk
