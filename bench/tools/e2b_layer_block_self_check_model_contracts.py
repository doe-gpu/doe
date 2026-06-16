"""Model-depth and capture evidence contracts for E2B self-check."""

from __future__ import annotations

import json
import subprocess
from typing import Any

from e2b_layer_block_self_check_context import SelfCheckPaths


def run_model_contracts(
    paths: SelfCheckPaths,
    receipt: dict[str, Any],
) -> list[str]:
    REPO_ROOT = paths.repo_root
    failures: list[str] = []
    # C36: Doe can structurally consume the local Doppler RDRR/int4ple
    # artifact without pretending Q4_K_M dequant or production-output
    # parity is complete. Fresh clones may skip as blocked_artifact_absent;
    # hosts with ../doppler/models/local/... must validate the manifest,
    # selected shard hash, tensor spans, and int4 PLE metadata.
    _rdrr_fixture = (
        REPO_ROOT
        / "config/gemma-4-e2b-doppler-rdrr-int4ple-fixture.json"
    )
    _rdrr_probe_script = REPO_ROOT / "bench/tools/probe_doppler_rdrr_artifact.py"
    _c36_errors: list[str] = []
    if not _rdrr_fixture.is_file():
        _c36_errors.append(
            f"fixture missing at {_rdrr_fixture.relative_to(REPO_ROOT)}"
        )
    elif not _rdrr_probe_script.is_file():
        _c36_errors.append(
            f"probe missing at {_rdrr_probe_script.relative_to(REPO_ROOT)}"
        )
    else:
        try:
            _rdrr_fix = json.loads(_rdrr_fixture.read_text(encoding="utf-8"))
            _probe_rel = (
                (_rdrr_fix.get("probe") or {}).get("outputPath")
                or "bench/out/doppler-rdrr/gemma-4-e2b-int4ple-rdrr-probe.json"
            )
            _probe_out = REPO_ROOT / _probe_rel
            _c36 = subprocess.run(
                [
                    "python3",
                    "bench/tools/probe_doppler_rdrr_artifact.py",
                    "--fixture",
                    str(_rdrr_fixture.relative_to(REPO_ROOT)),
                    "--out-json",
                    str(_probe_out.relative_to(REPO_ROOT)),
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                timeout=600,
            )
            if _c36.returncode != 0:
                _c36_errors.append(
                    f"probe returned {_c36.returncode}: {_c36.stderr[-300:]}"
                )
            elif not _probe_out.is_file():
                _c36_errors.append("probe did not write its output artifact")
            else:
                _probe = json.loads(_probe_out.read_text(encoding="utf-8"))
                _status = _probe.get("status")
                if _status == "blocked_artifact_absent":
                    print(
                        "  C36 SKIP: Doppler RDRR/int4ple artifact absent; "
                        "probe emitted blocked_artifact_absent"
                    )
                else:
                    _shard_ok = (
                        ((_probe.get("shardAudit") or {})
                         .get("selectedShardHashAudit") or {})
                        .get("status") == "passed"
                    )
                    _tensor_ok = (
                        ((_probe.get("tensorAudit") or {}).get("status"))
                        == "passed"
                    )
                    _dequant = _probe.get("dequantStatus") or {}
                    _q4_blocked = (
                        _dequant.get("q4k") == "blocked_not_implemented"
                    )
                    _ple_meta = (
                        _dequant.get("int4Ple")
                        == "metadata_validated_no_runtime_dequant"
                    )
                    _summary = _probe.get("artifactSummary") or {}
                    _expected_extra = (
                        (_rdrr_fix.get("expected") or {})
                        .get("extraLocalShards") or []
                    )
                    _extra_ok = (
                        _summary.get("extraLocalShards")
                        == _expected_extra
                    )
                    if (
                        _status == "succeeded"
                        and _shard_ok
                        and _tensor_ok
                        and _q4_blocked
                        and _ple_meta
                        and _extra_ok
                    ):
                        print(
                            "  C36 PASS: Doppler RDRR/int4ple artifact "
                            "structural probe passed (manifest+target "
                            "shard+tensor spans; Q4 dequant still blocked)"
                        )
                    else:
                        _c36_errors.append(
                            "unexpected probe state: "
                            f"status={_status!r}, shardOk={_shard_ok!r}, "
                            f"tensorOk={_tensor_ok!r}, "
                            f"q4Blocked={_q4_blocked!r}, "
                            f"pleMeta={_ple_meta!r}, extraOk={_extra_ok!r}"
                        )
        except (OSError, ValueError, json.JSONDecodeError) as _e:
            _c36_errors.append(
                f"fixture/probe evaluation error: {type(_e).__name__}: {_e}"
            )
    for _err in _c36_errors:
        failures.append(f"C36 FAIL: {_err}")

    # C37: Optional Doppler RDRR Q4_K_M L1 parity verdict, when
    # generated, must preserve the narrow smoke-contract claim
    # boundary. The evidence-bundle runner is responsible for
    # generating it; fresh clones or hosts without the local Doppler
    # artifact may be absent/blocked here.
    _q4k_parity = (
        REPO_ROOT
        / "bench/out/doppler-rdrr/gemma-4-e2b-int4ple-q4k-parity.json"
    )
    if _q4k_parity.is_file():
        try:
            _q4k = json.loads(_q4k_parity.read_text(encoding="utf-8"))
            _status = _q4k.get("status")
            _verdict = _q4k.get("verdict")
            if _verdict == "blocked_artifact_absent":
                print(
                    "  C37 SKIP: Doppler RDRR Q4_K_M parity blocked "
                    "because the local artifact is absent"
                )
            else:
                _criteria = _q4k.get("promotionCriteriaMet") or {}
                _parity = _q4k.get("paritySummary") or {}
                _claim_scope = _q4k.get("claimScope") or {}
                _not_claimable = _claim_scope.get("notClaimable") or []
                _blocks_full = any(
                    "Full Gemma-4 E2B execution" in str(item)
                    for item in _not_claimable
                )
                _blocks_hardware = any(
                    "Cerebras hardware" in str(item)
                    for item in _not_claimable
                )
                if (
                    _status == "succeeded"
                    and _verdict == "rdrr_q4k_l1_parity_passed"
                    and _criteria.get("structuralProbePassed") is True
                    and _criteria.get("q4kSmokeSlicesExtracted") is True
                    and _criteria.get("weightsAuditPassed") is True
                    and _criteria.get("crossRuntimeParityPassed") is True
                    and _criteria.get("fullModelDepthExecuted") is False
                    and _criteria.get("hardwareExecuted") is False
                    and _parity.get("tolerancePassed") is True
                    and int(_parity.get("layersCompared", 0)) == 1
                    and _blocks_full
                    and _blocks_hardware
                ):
                    print(
                        "  C37 PASS: Doppler RDRR Q4_K_M L1 "
                        "smoke-contract parity passed while full-model "
                        "and hardware claims remain blocked"
                    )
                elif (
                    _status == "blocked"
                    and _verdict == "rdrr_q4k_l1_parity_lane_incomplete"
                    and _criteria.get("q4kSmokeSlicesExtracted") is True
                    and _criteria.get("weightsAuditPassed") is True
                ):
                    print(
                        "  C37 PASS: Doppler RDRR Q4_K_M slices were "
                        "extracted and audited, but a runtime lane is "
                        "incomplete on this host"
                    )
                else:
                    failures.append(
                        "C37 FAIL: unexpected RDRR Q4_K_M parity state: "
                        f"status={_status!r}, verdict={_verdict!r}, "
                        f"criteria={_criteria!r}, parity={_parity!r}"
                    )
        except (OSError, ValueError, json.JSONDecodeError) as _e:
            failures.append(
                "C37 FAIL: q4k parity verdict unreadable: "
                f"{type(_e).__name__}: {_e}"
            )
    else:
        print(
            "  C37 SKIP: Doppler RDRR Q4_K_M parity verdict not yet "
            "generated"
        )

    # C38: Optional real-weight diagnostics, when generated, must either
    # pass exactly their requested smoke-chain depth or honestly report a
    # lane-incomplete runtime boundary while preserving the non-full-model
    # claim boundary. These artifacts are CSL strategy steps after L1;
    # they are not required on fresh clones.
    _diagnostic_depths = (2, 4, 8, 35)
    _c38_seen = False
    _c38_errors = []
    for _depth in _diagnostic_depths:
        _bf16_path = (
            REPO_ROOT
            / f"bench/out/gemma-4-e2b-real-weight-parity-L{_depth}.json"
        )
        if _bf16_path.is_file():
            _c38_seen = True
            try:
                _bf16 = json.loads(_bf16_path.read_text(encoding="utf-8"))
                _bf16_parity = _bf16.get("parity") or {}
                _bf16_lanes = _bf16.get("lanes") or {}
                _bf16_webgpu_status = (
                    (_bf16_lanes.get("doppler-webgpu") or {}).get("status")
                )
                _bf16_csl_status = (
                    (_bf16_lanes.get("csl-sdklayout") or {}).get("status")
                )
                if _bf16.get("verdict") == "blocked_weights_absent":
                    print(
                        "  C38 SKIP: BF16-derived E2B diagnostic depth "
                        f"{_depth} blocked because local weight slices "
                        "are absent"
                    )
                elif (
                    _bf16.get("verdict") == "parity_passed"
                    and int(_bf16.get("numLayers", 0)) == _depth
                    and _bf16.get("weightsAuditPassed") is True
                    and _bf16_parity.get("tolerancePassed") is True
                    and int(_bf16_parity.get("layersCompared", 0)) == _depth
                ):
                    print(
                        "  C38 PASS: BF16-derived E2B diagnostic depth "
                        f"{_depth} succeeded with matching layer count"
                    )
                elif (
                    _bf16.get("verdict") == "lane_incomplete"
                    and int(_bf16.get("numLayers", 0)) == _depth
                    and _bf16.get("weightsAuditPassed") is True
                    and _bf16_webgpu_status == "succeeded"
                    and _bf16_csl_status in ("blocked", "failed")
                ):
                    print(
                        "  C38 PASS: BF16-derived E2B diagnostic depth "
                        f"{_depth} is honestly lane-incomplete on this host "
                        "with weights audited and no parity promotion"
                    )
                else:
                    _c38_errors.append(
                        f"BF16 depth {_depth} unexpected state: "
                        f"verdict={_bf16.get('verdict')!r}, "
                        f"numLayers={_bf16.get('numLayers')!r}, "
                        "weightsAuditPassed="
                        f"{_bf16.get('weightsAuditPassed')!r}, "
                        f"parity={_bf16_parity!r}"
                    )
            except (OSError, ValueError, json.JSONDecodeError) as _e:
                _c38_errors.append(
                    f"BF16 depth {_depth} verdict unreadable: "
                    f"{type(_e).__name__}: {_e}"
                )

        _rdrr_path = (
            REPO_ROOT
            / (
                "bench/out/doppler-rdrr/"
                f"gemma-4-e2b-int4ple-q4k-parity-L{_depth}.json"
            )
        )
        if _rdrr_path.is_file():
            _c38_seen = True
            try:
                _rdrr = json.loads(_rdrr_path.read_text(encoding="utf-8"))
                _criteria = _rdrr.get("promotionCriteriaMet") or {}
                _parity = _rdrr.get("paritySummary") or {}
                _claim_scope = _rdrr.get("claimScope") or {}
                _not_claimable = _claim_scope.get("notClaimable") or []
                _blocks_full = any(
                    "Full Gemma-4 E2B execution" in str(item)
                    for item in _not_claimable
                )
                _blocks_hardware = any(
                    "Cerebras hardware" in str(item)
                    for item in _not_claimable
                )
                if _rdrr.get("verdict") == "blocked_artifact_absent":
                    print(
                        "  C38 SKIP: Doppler RDRR Q4_K_M diagnostic "
                        f"depth {_depth} blocked because the local "
                        "artifact is absent"
                    )
                elif (
                    _rdrr.get("status") == "succeeded"
                    and _rdrr.get("verdict")
                    == f"rdrr_q4k_l{_depth}_parity_passed"
                    and int(_rdrr.get("numLayers", 0)) == _depth
                    and _criteria.get("structuralProbePassed") is True
                    and _criteria.get("q4kSmokeSlicesExtracted") is True
                    and _criteria.get("weightsAuditPassed") is True
                    and _criteria.get("crossRuntimeParityPassed") is True
                    and _criteria.get("fullModelDepthExecuted") is False
                    and _criteria.get("hardwareExecuted") is False
                    and _parity.get("tolerancePassed") is True
                    and int(_parity.get("layersCompared", 0)) == _depth
                    and _blocks_full
                    and _blocks_hardware
                ):
                    print(
                        "  C38 PASS: Doppler RDRR Q4_K_M diagnostic "
                        f"depth {_depth} succeeded with full-model and "
                        "hardware claims blocked"
                    )
                elif (
                    _rdrr.get("status") == "blocked"
                    and _rdrr.get("verdict")
                    == f"rdrr_q4k_l{_depth}_parity_lane_incomplete"
                    and int(_rdrr.get("numLayers", 0)) == _depth
                    and _criteria.get("structuralProbePassed") is True
                    and _criteria.get("q4kSmokeSlicesExtracted") is True
                    and _criteria.get("weightsAuditPassed") is True
                    and _criteria.get("crossRuntimeParityPassed") is False
                    and _criteria.get("fullModelDepthExecuted") is False
                    and _criteria.get("hardwareExecuted") is False
                    and _criteria.get("productionInferencePathExecuted") is False
                    and _parity.get("tolerancePassed") is False
                    and _blocks_full
                    and _blocks_hardware
                ):
                    print(
                        "  C38 PASS: Doppler RDRR Q4_K_M diagnostic "
                        f"depth {_depth} is honestly lane-incomplete on "
                        "this host with source/audit evidence intact"
                    )
                else:
                    _c38_errors.append(
                        f"RDRR depth {_depth} unexpected state: "
                        f"status={_rdrr.get('status')!r}, "
                        f"verdict={_rdrr.get('verdict')!r}, "
                        f"numLayers={_rdrr.get('numLayers')!r}, "
                        f"criteria={_criteria!r}, parity={_parity!r}"
                    )
            except (OSError, ValueError, json.JSONDecodeError) as _e:
                _c38_errors.append(
                    f"RDRR depth {_depth} verdict unreadable: "
                    f"{type(_e).__name__}: {_e}"
                )
    if not _c38_seen:
        print(
            "  C38 SKIP: E2B real-weight diagnostic verdicts not yet "
            "generated for declared depths"
        )
    for _err in _c38_errors:
        failures.append(f"C38 FAIL: {_err}")

    # C39: Manifest-shape blocker is explicit and source-backed. The
    # probe reads the upstream E2B config + SafeTensors header and
    # records the current Doe manifest mismatch instead of leaving the
    # head-dim/global-head contract as implicit lore. Fresh clones may
    # emit the source-absent blocker; hosts with /home/x/model-downloads
    # must show tensor shapes pass and the manifest contract block.
    _shape_probe_script = (
        REPO_ROOT / "bench/tools/probe_gemma4_e2b_manifest_shape.py"
    )
    _shape_probe_out = (
        REPO_ROOT
        / "bench/out/manifest-shape/gemma-4-e2b-manifest-shape-probe.json"
    )
    if not _shape_probe_script.is_file():
        failures.append("C39 FAIL: manifest-shape probe script missing")
    else:
        try:
            _c39 = subprocess.run(
                [
                    "python3",
                    str(_shape_probe_script.relative_to(REPO_ROOT)),
                    "--out-json",
                    str(_shape_probe_out.relative_to(REPO_ROOT)),
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                timeout=120,
            )
            if _c39.returncode != 0:
                failures.append(
                    "C39 FAIL: manifest-shape probe returned "
                    f"{_c39.returncode}: {_c39.stderr[-300:]}"
                )
            elif not _shape_probe_out.is_file():
                failures.append(
                    "C39 FAIL: manifest-shape probe did not write output"
                )
            else:
                _probe = json.loads(
                    _shape_probe_out.read_text(encoding="utf-8")
                )
                _verdict = _probe.get("verdict")
                _status = _probe.get("status")
                if _verdict == "manifest_shape_probe_blocked_source_absent":
                    print(
                        "  C39 SKIP: manifest-shape source checkpoint "
                        "absent; probe recorded source-absent blocker"
                    )
                else:
                    _tensor_ok = all(
                        bool(item.get("passed"))
                        for item in (_probe.get("tensorAudit") or [])
                    )
                    _blockers = "\n".join(_probe.get("blockers") or [])
                    _has_head = "modelConfig.headDim" in _blockers
                    _has_global = "modelConfig.globalHeadDim" in _blockers
                    _has_kv_heads = "modelConfig.numKeyValueHeads" in _blockers
                    _has_q_shape = "q_proj" in _blockers
                    _has_o_shape = "o_proj" in _blockers
                    _upstream = _probe.get("upstreamConfig") or {}
                    _local_head_ok = _upstream.get("headDim") == 256
                    _global_head_ok = _upstream.get("globalHeadDim") == 512
                    _kv_heads_ok = _upstream.get("numKeyValueHeads") == 1
                    if (
                        _status == "blocked"
                        and _verdict
                        == "manifest_shape_probe_blocked_contract_mismatch"
                        and _tensor_ok
                        and _has_head
                        and _has_global
                        and _has_kv_heads
                        and _has_q_shape
                        and _has_o_shape
                        and _local_head_ok
                        and _global_head_ok
                        and _kv_heads_ok
                    ):
                        print(
                            "  C39 PASS: manifest-shape probe records "
                            "upstream E2B local/global head contract and "
                            "blocks stale Doe manifest shape"
                        )
                    elif _status == "succeeded":
                        print(
                            "  C39 PASS: manifest-shape probe passes; "
                            "Doe manifest fields match upstream tensor "
                            "metadata"
                        )
                    else:
                        failures.append(
                            "C39 FAIL: unexpected manifest-shape probe "
                            f"state: status={_status!r}, "
                            f"verdict={_verdict!r}, tensorOk={_tensor_ok!r}, "
                            f"blockers={_probe.get('blockers')!r}, "
                            f"upstream={_upstream!r}"
                        )
        except (OSError, ValueError, json.JSONDecodeError) as _e:
            failures.append(
                "C39 FAIL: manifest-shape probe evaluation error: "
                f"{type(_e).__name__}: {_e}"
            )

    # C40: The raw BF16 E2B checkpoint can execute as a text-only
    # CPU/Numpy manifest-shape oracle through all 35 decoder layers,
    # final norm, and tied lm-head top-k. This is deliberately NOT a
    # Doe/CSL runtime promotion; the artifact must keep those blockers
    # explicit while proving the upstream tensor dimensions are
    # executable with finite outputs.
    _shape_exec_script = (
        REPO_ROOT / "bench/tools/run_gemma4_e2b_manifest_shape_execution.py"
    )
    _shape_exec_out = (
        REPO_ROOT
        / "bench/out/manifest-shape/gemma-4-e2b-manifest-shape-execution.json"
    )
    if not _shape_exec_script.is_file():
        failures.append("C40 FAIL: manifest-shape execution script missing")
    else:
        try:
            _c40 = subprocess.run(
                [
                    "python3",
                    str(_shape_exec_script.relative_to(REPO_ROOT)),
                    "--out-json",
                    str(_shape_exec_out.relative_to(REPO_ROOT)),
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                timeout=300,
            )
            if _c40.returncode != 0:
                failures.append(
                    "C40 FAIL: manifest-shape execution returned "
                    f"{_c40.returncode}: {_c40.stderr[-300:]}"
                )
            elif not _shape_exec_out.is_file():
                failures.append(
                    "C40 FAIL: manifest-shape execution wrote no output"
                )
            else:
                _exec = json.loads(
                    _shape_exec_out.read_text(encoding="utf-8")
                )
                _verdict = _exec.get("verdict")
                _status = _exec.get("status")
                if _verdict == "manifest_shape_execution_blocked_source_absent":
                    print(
                        "  C40 SKIP: manifest-shape execution source "
                        "checkpoint absent; probe recorded blocker"
                    )
                else:
                    _summary = _exec.get("executionSummary") or {}
                    _criteria = _exec.get("promotionCriteriaMet") or {}
                    _output = _exec.get("output") or {}
                    _blockers = set(_exec.get("blockers") or [])
                    _layers = _exec.get("layerRecords") or []
                    _all_layers_finite = all(
                        bool(row.get("hiddenFinite")) for row in _layers
                    )
                    _global_layers = _summary.get("globalAttentionLayerIndices")
                    _local_head_ok = _summary.get("localHeadDim") == 256
                    _global_head_ok = _summary.get("globalHeadDim") == 512
                    _depth_ok = (
                        _summary.get("numLayers") == 35
                        and _summary.get("layersExecuted") == 35
                        and len(_layers) == 35
                    )
                    _lm_ok = (
                        (_output.get("lmHeadSummary") or {}).get("finite")
                        is True
                        and len(_output.get("lmHeadTopK") or []) >= 1
                    )
                    _runtime_blocked = (
                        _criteria.get("doeRuntimeExecuted") is False
                        and _criteria.get("cslRuntimeExecuted") is False
                        and _criteria.get("hardwareExecuted") is False
                        and "doe_csl_manifest_shape_runtime_not_executed"
                        in _blockers
                    )
                    if (
                        _status == "succeeded"
                        and _verdict
                        == "manifest_shape_cpu_full_text_forward_passed"
                        and _criteria.get("manifestShapeExecuted") is True
                        and _criteria.get("fullLayerDepthExecuted") is True
                        and _criteria.get("lmHeadTopKComputed") is True
                        and _runtime_blocked
                        and _depth_ok
                        and _local_head_ok
                        and _global_head_ok
                        and _global_layers == [4, 9, 14, 19, 24, 29, 34]
                        and _summary.get("allLayerOutputsFinite") is True
                        and _output.get("finalHiddenFinite") is True
                        and _all_layers_finite
                        and _lm_ok
                    ):
                        print(
                            "  C40 PASS: manifest-shape CPU oracle "
                            "executes E2B text stack through 35 layers "
                            "and lm-head top-k while Doe/CSL runtime "
                            "claims remain blocked"
                        )
                    else:
                        failures.append(
                            "C40 FAIL: unexpected manifest-shape "
                            "execution state:\n"
                            f"    status={_status!r}, verdict={_verdict!r}\n"
                            f"    summary={_summary!r}\n"
                            f"    criteria={_criteria!r}\n"
                            f"    outputKeys={list(_output.keys())!r}\n"
                            f"    blockers={sorted(_blockers)!r}"
                        )
        except (OSError, ValueError, json.JSONDecodeError) as _e:
            failures.append(
                "C40 FAIL: manifest-shape execution evaluation error: "
                f"{type(_e).__name__}: {_e}"
            )

    # C41: Cerebras SDK 2.10 source compatibility. The active CSL
    # emitter surface must not reintroduce removed SDK-1.4-only
    # constructs, and fabric DSD declarations need explicit queues so
    # simulator/hardware receipts bind colors through queues instead
    # of removed/ deprecated SDK-1.4-era behavior.
    try:
        _c41_paths = list((REPO_ROOT / "runtime/zig/src/doe_wgsl").glob("emit_csl*.zig"))
        _c41_paths += list((REPO_ROOT / "runtime/zig/src/doe_wgsl").glob("csl_spec.zig"))
        _c41_paths += list(
            (REPO_ROOT / "runtime/zig/examples/simulator").glob(
                "*/compile/*/pe_program.csl"
            )
        )
        _c41_paths += list((REPO_ROOT / "examples/csl").glob("*/pe_program.csl"))
        _c41_bad = []
        for _path in sorted(set(_c41_paths)):
            if _path.name == "emit_csl_validate.zig":
                continue
            _rel = _path.relative_to(REPO_ROOT)
            _text = _path.read_text(encoding="utf-8")
            for _token in ("comptime_struct", "@concat_struct"):
                if _token in _text:
                    _c41_bad.append(f"{_rel}: removed SDK 2.10 token {_token}")
            _lines = _text.splitlines()
            for _idx, _line in enumerate(_lines):
                _window = "\n".join(_lines[_idx : _idx + 8])
                if "@get_dsd(fabin_dsd" in _line:
                    if ".input_queue" not in _window:
                        _c41_bad.append(
                            f"{_rel}:{_idx + 1}: fabin_dsd missing input_queue"
                        )
                    if ".fabric_color" in _window:
                        _c41_bad.append(
                            f"{_rel}:{_idx + 1}: fabin_dsd still uses fabric_color"
                        )
                if "@get_dsd(fabout_dsd" in _line:
                    if ".output_queue" not in _window:
                        _c41_bad.append(
                            f"{_rel}:{_idx + 1}: fabout_dsd missing output_queue"
                        )
                    if ".fabric_color" in _window:
                        _c41_bad.append(
                            f"{_rel}:{_idx + 1}: fabout_dsd still uses fabric_color"
                        )
        _spec_text = (
            REPO_ROOT / "runtime/zig/src/doe_wgsl/csl_spec.zig"
        ).read_text(encoding="utf-8")
        if 'CSLC_SDK_MIN_VERSION: []const u8 = "2.10.0"' not in _spec_text:
            _c41_bad.append("csl_spec.zig does not declare SDK 2.10.0 floor")
        if _c41_bad:
            failures.extend(f"C41 FAIL: {_bad}" for _bad in _c41_bad)
        else:
            print(
                "  C41 PASS: CSL emitters target SDK 2.10 params and "
                "queue-bound fabric DSDs"
            )
    except OSError as _e41:
        failures.append(f"C41 FAIL: SDK 2.10 source scan error: {_e41}")

    # C42: model-level SdkLayout layer-block execution promotion block.
    # The generated runner's successful simfabric run must be visible as
    # first-class model receipt evidence, not only nested primitive text.
    _sdk = receipt.get("sdkLayoutModelExecutionEvidence") or {}
    _c42_bad = []
    if not _sdk:
        _c42_bad.append("sdkLayoutModelExecutionEvidence missing")
    else:
        if _sdk.get("promotionStatus") != "sdk_layout_layer_block_smoke_promoted":
            _c42_bad.append(
                "promotionStatus="
                f"{_sdk.get('promotionStatus')!r}, expected promoted"
            )
        if _sdk.get("blockers") != []:
            _c42_bad.append(f"blockers not empty: {_sdk.get('blockers')!r}")
        _kernel = _sdk.get("kernelSource") or {}
        if _kernel.get("kernelIsStub") is not False:
            _c42_bad.append("kernelSource.kernelIsStub is not false")
        _plan = _sdk.get("streamExecutionPlan") or {}
        if not _plan.get("sha256"):
            _c42_bad.append("streamExecutionPlan.sha256 missing")
        _counts = _sdk.get("sendReceiveCounts") or {}
        if _counts.get("sends") != 3 or _counts.get("receives") != 1:
            _c42_bad.append(f"sendReceiveCounts mismatch: {_counts!r}")
        _stop = _sdk.get("runtimeStop") or {}
        if _stop.get("reached") is not True:
            _c42_bad.append("runtimeStop.reached is not true")
        _parity = _sdk.get("parity") or {}
        if _parity.get("promotionEligible") is not True:
            _c42_bad.append("parity.promotionEligible is not true")
        if _parity.get("tolerancePassed") is not True:
            _c42_bad.append("parity.tolerancePassed is not true")
        _telemetry = _sdk.get("hostSdkTelemetry") or {}
        if _telemetry.get("measurementSource") != "host_sdk_task_handles":
            _c42_bad.append("hostSdkTelemetry.measurementSource mismatch")
        _streams = _telemetry.get("streams") or []
        _stream_ids = {
            s.get("streamId") for s in _streams if isinstance(s, dict)
        }
        _expected_stream_ids = {
            "ple_rows_stream",
            "ple_projection_stream",
            "layer_weights_stream",
            "activation_out_stream",
        }
        if _stream_ids != _expected_stream_ids:
            _c42_bad.append(f"stream telemetry ids mismatch: {_stream_ids!r}")
        _host_io = _sdk.get("hostIoLayout") or []
        _host_io_ids = {
            s.get("streamId") for s in _host_io if isinstance(s, dict)
        }
        if _host_io_ids != _expected_stream_ids:
            _c42_bad.append(f"hostIoLayout ids mismatch: {_host_io_ids!r}")
        _artifacts = _sdk.get("simulatorArtifacts") or {}
        for _name in ("trace", "output"):
            _link = _artifacts.get(_name) or {}
            _path = _link.get("path")
            if not (_path and (REPO_ROOT / _path).is_file()):
                _c42_bad.append(f"simulatorArtifacts.{_name}.path missing")
            if not _link.get("sha256"):
                _c42_bad.append(f"simulatorArtifacts.{_name}.sha256 missing")
        _compile_dir = (_artifacts.get("compileDir") or {}).get("path")
        if not (_compile_dir and (REPO_ROOT / _compile_dir).is_dir()):
            _c42_bad.append("simulatorArtifacts.compileDir missing")
    if _c42_bad:
        failures.extend(f"C42 FAIL: {_bad}" for _bad in _c42_bad)
    else:
        print(
            "  C42 PASS: model receipt promotes generated E2B SdkLayout "
            "layer-block smoke with stream graph, telemetry, rt.stop, "
            "and parity evidence"
        )

    # C43: full-depth smoke diagnostics are model-receipt-visible but
    # still non-claimable. This locks the next step toward full E2B
    # without allowing L35 smoke-chain files to masquerade as manifest-
    # shape or hardware evidence.
    _depth_diag = receipt.get("sdkLayoutDepthDiagnosticEvidence") or {}
    _c43_bad = []
    if not _depth_diag:
        _c43_bad.append("sdkLayoutDepthDiagnosticEvidence missing")
    else:
        _depth_status = _depth_diag.get("status")
        _depth_passed = _depth_status == "full_depth_smoke_diagnostic_passed"
        _depth_blocked = _depth_status == "blocked"
        if not (_depth_passed or _depth_blocked):
            _c43_bad.append(
                "status="
                f"{_depth_status!r}, expected diagnostic_passed or blocked"
            )
        if _depth_diag.get("claimable") is not False:
            _c43_bad.append("claimable is not false")
        if _depth_diag.get("manifestShapeRuntimeExecuted") is not False:
            _c43_bad.append("manifestShapeRuntimeExecuted is not false")
        if _depth_diag.get("declaredModelDepth") != 35:
            _c43_bad.append("declaredModelDepth is not 35")
        _remaining = set(_depth_diag.get("remainingClaimBlockers") or [])
        for _expected in (
            "full_manifest_shape_doe_csl_runtime_execution",
            "doppler_production_inference_parity",
            "cerebras_hardware_receipt",
        ):
            if _expected not in _remaining:
                _c43_bad.append(
                    f"remainingClaimBlockers missing {_expected}"
                )
        _diagnostics = _depth_diag.get("diagnostics") or []
        _sources = {
            d.get("sourceLabel") for d in _diagnostics
            if isinstance(d, dict)
        }
        _expected_sources = {
            "bf16_safetensors",
            "doppler_rdrr_q4k_int4ple",
        }
        if _sources != _expected_sources:
            _c43_bad.append(f"diagnostic sources mismatch: {_sources!r}")
        for _diag in _diagnostics:
            if not isinstance(_diag, dict):
                _c43_bad.append("diagnostic entry is not an object")
                continue
            _source = _diag.get("sourceLabel")
            if _diag.get("numLayers") != 35:
                _c43_bad.append(f"{_source}: numLayers is not 35")
            if _diag.get("claimable") is not False:
                _c43_bad.append(f"{_source}: claimable is not false")
            _diag_blockers = _diag.get("blockers") or []
            _diag_blocker_set = set(_diag_blockers)
            _expected_lane_blockers = {
                "parity_not_passed",
                "tolerance_not_passed",
            }
            if _depth_passed and _diag_blockers != []:
                _c43_bad.append(
                    f"{_source}: diagnostic blockers not empty: "
                    f"{_diag_blockers!r}"
                )
            _parity = _diag.get("parity") or {}
            _diag_parity_passed = (
                _parity.get("verdict") == "parity_passed"
                and _parity.get("tolerancePassed") is True
                and _parity.get("layersCompared") == 35
            )
            _diag_lane_incomplete = (
                _depth_blocked
                and _diag_blocker_set == _expected_lane_blockers
                and _parity.get("verdict") == "lane_incomplete"
                and _parity.get("tolerancePassed") is False
                and _parity.get("layersCompared") == 0
            )
            if not (_diag_parity_passed or _diag_lane_incomplete):
                _c43_bad.append(
                    f"{_source}: expected parity_passed or honest "
                    "lane_incomplete diagnostic, got "
                    f"parity={_parity!r}, blockers={_diag_blockers!r}"
                )
            for _label, _link in (
                ("parity", _parity),
                ("weightsAudit", _parity.get("weightsAudit") or {}),
                ("trace", _diag.get("trace") or {}),
                ("output", ((_diag.get("trace") or {}).get("output") or {})),
            ):
                _path = _link.get("path")
                if not (_path and (REPO_ROOT / _path).is_file()):
                    _c43_bad.append(f"{_source}: {_label} path missing")
                if not _link.get("sha256"):
                    _c43_bad.append(f"{_source}: {_label} sha256 missing")
            _trace = _diag.get("trace") or {}
            if _trace.get("status") != "succeeded":
                _c43_bad.append(f"{_source}: trace status not succeeded")
            if _trace.get("numLayersChained") != 35:
                _c43_bad.append(
                    f"{_source}: trace numLayersChained is not 35"
                )
            if _trace.get("runtimeStopReached") is not True:
                _c43_bad.append(f"{_source}: runtimeStop not reached")
            if _trace.get("kernelIsStub") is not False:
                _c43_bad.append(f"{_source}: kernelIsStub is not false")
            _counts = _trace.get("sendReceiveCounts") or {}
            if _counts.get("sends") != 3 or _counts.get("receives") != 1:
                _c43_bad.append(
                    f"{_source}: sendReceiveCounts mismatch: {_counts!r}"
                )
            _telemetry = _trace.get("hostSdkTelemetry") or {}
            if _telemetry.get("measurementSource") != "host_sdk_task_handles":
                _c43_bad.append(f"{_source}: telemetry source mismatch")
            if _telemetry.get("streamCount") != 4:
                _c43_bad.append(f"{_source}: streamCount is not 4")
    if _c43_bad:
        failures.extend(f"C43 FAIL: {_bad}" for _bad in _c43_bad)
    else:
        print(
            "  C43 PASS: model receipt binds full-depth E2B SdkLayout "
            "smoke diagnostics as non-claimable BF16 + RDRR evidence"
        )

    # C44: first manifest-shape SdkLayout runtime slice is visible in
    # the model receipt as partial evidence. This is intentionally
    # narrower than executionStatus: it proves the local/global head
    # dimensions plus grouped-KV attention-core diagnostic ran and
    # matched its CPU oracle, while full attention semantics, decoder
    # stack, logits, hardware, and performance remain blocked.
    _partial = receipt.get("manifestShapePartialExecutionEvidence") or {}
    _c44_bad = []
    if not _partial:
        _c44_bad.append("manifestShapePartialExecutionEvidence missing")
    else:
        if _partial.get("status") != "attention_core_runtime_slice_passed":
            _c44_bad.append(
                f"status={_partial.get('status')!r}, expected slice_passed"
            )
        if _partial.get("claimable") is not False:
            _c44_bad.append("claimable is not false")
        if _partial.get("blockers") != []:
            _c44_bad.append(f"blockers not empty: {_partial.get('blockers')!r}")
        _receipt_link = _partial.get("attentionCoreReceipt") or {}
        _receipt_path = _receipt_link.get("path")
        if not (_receipt_path and (REPO_ROOT / _receipt_path).is_file()):
            _c44_bad.append("attentionCoreReceipt path missing")
        if not _receipt_link.get("sha256"):
            _c44_bad.append("attentionCoreReceipt sha256 missing")
        _contract = _partial.get("manifestShapeContract") or {}
        if _contract.get("localHeadDim") != 256:
            _c44_bad.append("localHeadDim is not 256")
        if _contract.get("globalHeadDim") != 512:
            _c44_bad.append("globalHeadDim is not 512")
        if _contract.get("numKeyValueHeads") != 1:
            _c44_bad.append("numKeyValueHeads is not 1")
        _coverage = _partial.get("coverage") or {}
        for _field in (
            "localHeadDimExecuted",
            "globalHeadDimExecuted",
            "groupedKvExecuted",
            "attentionCoreCslRuntimeExecuted",
        ):
            if _coverage.get(_field) is not True:
                _c44_bad.append(f"coverage.{_field} is not true")
        for _field in (
            "embedUnembedExecuted",
            "logitsParityExecuted",
            "hardwareExecuted",
            "claimable",
        ):
            if _coverage.get(_field) is not False:
                _c44_bad.append(f"coverage.{_field} is not false")
        _semantic = _partial.get("semanticParity") or {}
        if _semantic.get("scope") != "attention_core_cpu_oracle_bit_exact":
            _c44_bad.append("semanticParity.scope mismatch")
        if _semantic.get("passed") is not True:
            _c44_bad.append("semanticParity.passed is not true")
        if _semantic.get("maxAbsErr") != 0.0:
            _c44_bad.append("semanticParity.maxAbsErr is not 0")
        if _semantic.get("queryHeadsCompared") != 16:
            _c44_bad.append("semanticParity.queryHeadsCompared is not 16")
        _grouped = _partial.get("groupedKvEvidence") or {}
        if _grouped.get("executed") is not True:
            _c44_bad.append("groupedKvEvidence.executed is not true")
        if _grouped.get("queryHeadsPerKvHead") != 8:
            _c44_bad.append("queryHeadsPerKvHead is not 8")
        _runs = _partial.get("shapeRuns") or []
        _run_kinds = {
            run.get("attentionKind") for run in _runs
            if isinstance(run, dict)
        }
        if _run_kinds != {"local", "global"}:
            _c44_bad.append(f"shape run kinds mismatch: {_run_kinds!r}")
        for _run in _runs:
            if not isinstance(_run, dict):
                _c44_bad.append("shape run is not an object")
                continue
            _kind = _run.get("attentionKind")
            if _run.get("status") != "succeeded":
                _c44_bad.append(f"{_kind}: status not succeeded")
            if _run.get("compileStatus") != "succeeded":
                _c44_bad.append(f"{_kind}: compileStatus not succeeded")
            if _run.get("runStatus") != "succeeded":
                _c44_bad.append(f"{_kind}: runStatus not succeeded")
            if _run.get("runtimeStopReached") is not True:
                _c44_bad.append(f"{_kind}: runtimeStop not reached")
            _parity = _run.get("numericalParity") or {}
            if _parity.get("passed") is not True:
                _c44_bad.append(f"{_kind}: numericalParity not passed")
            if _run.get("queryHeadsCompared") != 8:
                _c44_bad.append(f"{_kind}: queryHeadsCompared is not 8")
            if _run.get("queryHeadsPassed") != 8:
                _c44_bad.append(f"{_kind}: queryHeadsPassed is not 8")
            _compile_dir = (_run.get("compileDir") or {}).get("path")
            if not (_compile_dir and (REPO_ROOT / _compile_dir).is_dir()):
                _c44_bad.append(f"{_kind}: compileDir missing")
        _remaining = set(_partial.get("remainingClaimBlockers") or [])
        for _expected in (
            "full_attention_semantics_parity",
            "full_decoder_block_manifest_shape_execution",
            "embed_unembed_and_logits_parity",
            "cerebras_hardware_receipt",
        ):
            if _expected not in _remaining:
                _c44_bad.append(
                    f"remainingClaimBlockers missing {_expected}"
                )
    if _c44_bad:
        failures.extend(f"C44 FAIL: {_bad}" for _bad in _c44_bad)
    else:
        print(
            "  C44 PASS: model receipt binds partial manifest-shape "
            "attention-core SdkLayout execution with local/global heads, "
            "grouped KV, and CPU-oracle parity while full claims stay blocked"
        )

    # C45: Doppler WebGPU capture graph is model-receipt-visible. This
    # locks the shared-input contract: Doppler installs Doe's capture
    # provider through its normal Node WebGPU bootstrap, records WGSL
    # and command graph hashes, and still blocks HostPlan/SdkLayout/CSL
    # lowering claims until the captured graph is consumed downstream.
    _capture = receipt.get("dopplerWebgpuCaptureEvidence") or {}
    _c45_bad = []
    if not _capture:
        _c45_bad.append("dopplerWebgpuCaptureEvidence missing")
    else:
        if _capture.get("status") != "capture_graph_recorded":
            _c45_bad.append(
                f"status={_capture.get('status')!r}, expected recorded"
            )
        if _capture.get("claimable") is not False:
            _c45_bad.append("claimable is not false")
        if _capture.get("blockers") != []:
            _c45_bad.append(
                f"blockers not empty: {_capture.get('blockers')!r}"
            )
        _graph = _capture.get("captureGraph") or {}
        _graph_path = _graph.get("path")
        if not (_graph_path and (REPO_ROOT / _graph_path).is_file()):
            _c45_bad.append("captureGraph.path missing")
        if not _graph.get("sha256"):
            _c45_bad.append("captureGraph.sha256 missing")
        if not _graph.get("graphSha256"):
            _c45_bad.append("captureGraph.graphSha256 missing")
        _bootstrap = _capture.get("bootstrap") or {}
        if _bootstrap.get("sourceRepo") != ".":
            _c45_bad.append("bootstrap.sourceRepo mismatch")
        if _bootstrap.get("sourcePath") != "packages/doe-gpu/src/node-webgpu.js":
            _c45_bad.append("bootstrap.sourcePath mismatch")
        if _bootstrap.get("providerModule") != "packages/doe-gpu/src/capture.js":
            _c45_bad.append("bootstrap.providerModule mismatch")
        if _bootstrap.get("providerInstalled") is not True:
            _c45_bad.append("providerInstalled is not true")
        if _bootstrap.get("adapterProbeSucceeded") is not True:
            _c45_bad.append("adapterProbeSucceeded is not true")
        _model = _capture.get("model") or {}
        if _model.get("modelId") != "gemma-4-e2b-it-q4k-ehf16-af32":
            _c45_bad.append("model.modelId mismatch")
        _arch = _model.get("architecture") or {}
        if _arch.get("headDim") != 256:
            _c45_bad.append("architecture.headDim is not 256")
        if _arch.get("globalHeadDim") != 512:
            _c45_bad.append("architecture.globalHeadDim is not 512")
        if _arch.get("numKeyValueHeads") != 1:
            _c45_bad.append("architecture.numKeyValueHeads is not 1")
        _subset = _capture.get("webgpuSubset") or {}
        if "device.createShaderModule" not in (
            _subset.get("supportedWebgpuMethods") or []
        ):
            _c45_bad.append("supportedWebgpuMethods missing shader module")
        if _subset.get("recordedUnsupportedCalls") != []:
            _c45_bad.append("recordedUnsupportedCalls not empty")
        if not _subset.get("shaderWgslSha256"):
            _c45_bad.append("shaderWgslSha256 missing")
        _counts = _capture.get("counts") or {}
        for _field in (
            "buffers",
            "bufferWrites",
            "shaderModules",
            "computePipelines",
            "commandBuffers",
            "submissions",
            "readbacks",
        ):
            if int(_counts.get(_field, 0)) < 1:
                _c45_bad.append(f"counts.{_field} < 1")
        if _counts.get("unsupported") != 0:
            _c45_bad.append("counts.unsupported is not 0")
        _lowering = _capture.get("lowering") or {}
        if _lowering.get("status") != "pending_hostplan_lowering":
            _c45_bad.append("lowering.status mismatch")
        if _lowering.get("hostPlanLinked") is not False:
            _c45_bad.append("lowering.hostPlanLinked is not false")
        if not _lowering.get("sourceGraphSha256"):
            _c45_bad.append("lowering.sourceGraphSha256 missing")
        _remaining = set(_capture.get("remainingClaimBlockers") or [])
        for _expected in (
            "captured_graph_to_hostplan_lowering",
            "hostplan_to_sdklayout_compile",
            "csl_simulator_parity_against_doppler_runtime",
            "cerebras_hardware_receipt",
        ):
            if _expected not in _remaining:
                _c45_bad.append(
                    f"remainingClaimBlockers missing {_expected}"
                )
    if _c45_bad:
        failures.extend(f"C45 FAIL: {_bad}" for _bad in _c45_bad)
    else:
        print(
            "  C45 PASS: model receipt binds Doppler Gemma-4 WebGPU "
            "capture graph as shared JS/WGSL input while full graph "
            "lowering claims remain blocked"
        )

    # C46: first captured-graph lowering receipt is model-receipt-visible.
    # This does not promote full inference. It proves the current capture
    # graph hash is consumed by the attention-core SdkLayout/CSL slice and
    # that the resulting simulator parity remains CPU-oracle scoped.
    _capture_lowering = (
        receipt.get("dopplerWebgpuCaptureLoweringEvidence") or {}
    )
    _c46_bad = []
    if not _capture_lowering:
        _c46_bad.append("dopplerWebgpuCaptureLoweringEvidence missing")
    else:
        if _capture_lowering.get("status") != (
            "attention_core_capture_slice_lowered_and_simulated"
        ):
            _c46_bad.append(
                f"status={_capture_lowering.get('status')!r}, "
                "expected attention-core lowering"
            )
        if _capture_lowering.get("claimable") is not False:
            _c46_bad.append("claimable is not false")
        if _capture_lowering.get("blockers") != []:
            _c46_bad.append(
                f"blockers not empty: {_capture_lowering.get('blockers')!r}"
            )
        _lowering_receipt = _capture_lowering.get("loweringReceipt") or {}
        _lowering_path = _lowering_receipt.get("path")
        if not (_lowering_path and (REPO_ROOT / _lowering_path).is_file()):
            _c46_bad.append("loweringReceipt.path missing")
        if not _lowering_receipt.get("sha256"):
            _c46_bad.append("loweringReceipt.sha256 missing")
        _capture_graph_sha = (
            (receipt.get("dopplerWebgpuCaptureEvidence") or {})
            .get("captureGraph", {})
            .get("graphSha256")
        )
        if _lowering_receipt.get("sourceGraphSha256") != _capture_graph_sha:
            _c46_bad.append("sourceGraphSha256 does not match capture graph")
        _lowering_source = _capture_lowering.get("source") or {}
        _lowering_graph = _lowering_source.get("captureGraph") or {}
        if _lowering_graph.get("graphSha256") != _capture_graph_sha:
            _c46_bad.append("source.captureGraph.graphSha256 mismatch")
        if not (_lowering_source.get("shaderModules") or []):
            _c46_bad.append("source.shaderModules missing")
        _host_view = _capture_lowering.get("capturedHostPlanView") or {}
        if _host_view.get("workload") != (
            "gemma4_e2b_manifest_shape_grouped_kv_capture_smoke"
        ):
            _c46_bad.append("capturedHostPlanView.workload mismatch")
        if int(_host_view.get("workgroupDispatchCount", 0)) < 1:
            _c46_bad.append("workgroupDispatchCount < 1")
        if int(_host_view.get("bindingCount", 0)) < 4:
            _c46_bad.append("bindingCount < 4")
        if "grouped_kv_projection_input" not in (
            _host_view.get("bufferRoles") or []
        ):
            _c46_bad.append("grouped KV buffer role missing")
        _lowered = _capture_lowering.get("loweredArtifacts") or {}
        if _lowered.get("sdkVersionFloor") != "2.10.0":
            _c46_bad.append("sdkVersionFloor mismatch")
        for _field in (
            "pythonSdkLayoutRunner",
            "cslKernel",
            "attentionCoreReceipt",
        ):
            _link = _lowered.get(_field) or {}
            _path = _link.get("path")
            if not (_path and (REPO_ROOT / _path).is_file()):
                _c46_bad.append(f"loweredArtifacts.{_field}.path missing")
            if not _link.get("sha256"):
                _c46_bad.append(f"loweredArtifacts.{_field}.sha256 missing")
        _sim = _capture_lowering.get("simulatorEvidence") or {}
        _semantic = _sim.get("semanticParity") or {}
        if _sim.get("status") != "succeeded":
            _c46_bad.append("simulatorEvidence.status mismatch")
        if _sim.get("hardwareExecuted") is not False:
            _c46_bad.append("hardwareExecuted is not false")
        if _semantic.get("passed") is not True:
            _c46_bad.append("semanticParity.passed is not true")
        if _semantic.get("scope") != "attention_core_cpu_oracle_bit_exact":
            _c46_bad.append("semanticParity.scope mismatch")
        if _semantic.get("againstDopplerProductionInference") is not False:
            _c46_bad.append(
                "semanticParity claims Doppler production inference"
            )
        _remaining = set(_capture_lowering.get("remainingClaimBlockers") or [])
        for _expected in (
            "ordinary_doppler_inference_graph_capture",
            "full_captured_webgpu_graph_to_hostplan_lowering",
            "automated_wgsl_to_csl_kernel_lowering",
            "embed_unembed_decoder_logits_parity",
            "cerebras_hardware_receipt",
        ):
            if _expected not in _remaining:
                _c46_bad.append(
                    f"remainingClaimBlockers missing {_expected}"
                )
    if _c46_bad:
        failures.extend(f"C46 FAIL: {_bad}" for _bad in _c46_bad)
    else:
        print(
            "  C46 PASS: model receipt binds the captured WebGPU graph "
            "to the first attention-core SdkLayout/CSL lowering receipt "
            "with CPU-oracle parity and full-inference blockers intact"
        )

    return failures
