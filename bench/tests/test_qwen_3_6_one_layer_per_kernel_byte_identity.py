"""Pin the 1-layer == 64-layer per-kernel byte-identity property for
Qwen 3.6 27B (parallel to the Gemma 4 31B test).

Same shape as ``bench/tests/test_one_layer_per_kernel_byte_identity.py``,
just against the Qwen smoke config and bundle root. The host-plan tool
already accepts numLayers; this test pins that emitting the 64-layer
config produces byte-identical per-kernel CSL to emitting the 1-layer
config (kernel CSL is per-class, not per-layer-instance).

The 1-of-64-layer property is what makes a single Qwen layer's
correctness receipt extend to all 64 layers. A failure here would mean
per-kernel CSL is a function of the layer instance, breaking that
inference.

The test compares ``--mode steps`` output without invoking ``cslc``;
it only exercises the layout/pe_program emitter. Skipped automatically
when the ``doe-csl-host-plan-tool`` binary or the upstream Qwen compile
root are unavailable (the latter requires materializing
``bench/out/r3-2-27b-manifest-fullgraph-compile-steps`` via the
host-plan tool first).
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bench.tools.verify_per_kernel_byte_identity import (  # noqa: E402
    build_receipt,
)

HOST_PLAN_TOOL = (
    REPO_ROOT / "runtime" / "zig" / "zig-out" / "bin" / "doe-csl-host-plan-tool"
)
QWEN_SMOKE_CONFIG = (
    REPO_ROOT
    / "runtime"
    / "zig"
    / "examples"
    / "execution-v1"
    / "qwen-3-6-27b-smoke.json"
)

def _emit_bundle(*, num_layers: int, bundle_root: Path) -> None:
    """Run doe-csl-host-plan-tool against a Qwen smoke config patched
    with the given numLayers, materializing layout.csl + pe_program.csl
    per kernel under <bundle_root>/compile/<kernel>/. cslc is
    intentionally NOT invoked — only the emitter is exercised."""
    config = json.loads(QWEN_SMOKE_CONFIG.read_text(encoding="utf-8"))
    config["modelConfig"]["numLayers"] = num_layers
    cfg_path = bundle_root / f"qwen-3-6-27b-{num_layers}L.json"
    cfg_path.write_text(json.dumps(config, indent=2), encoding="utf-8")
    subprocess.run(
        [
            str(HOST_PLAN_TOOL),
            "--input",
            str(cfg_path),
            "--bundle-root",
            str(bundle_root),
            "--mode",
            "steps",
        ],
        check=True,
        capture_output=True,
        text=True,
    )


def _configured_num_layers() -> int:
    config = json.loads(QWEN_SMOKE_CONFIG.read_text(encoding="utf-8"))
    return int(config["modelConfig"]["numLayers"])


class Qwen3_6_OneLayerByteIdentityTest(unittest.TestCase):

    @classmethod
    def setUpClass(cls) -> None:
        if not HOST_PLAN_TOOL.is_file():
            raise unittest.SkipTest(
                f"doe-csl-host-plan-tool not built at {HOST_PLAN_TOOL}"
            )
        if not QWEN_SMOKE_CONFIG.is_file():
            raise unittest.SkipTest(
                f"Qwen smoke config missing: {QWEN_SMOKE_CONFIG}"
            )

    def test_one_layer_emits_byte_identical_per_kernel_artifacts_to_64L(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as tmp_full, \
             tempfile.TemporaryDirectory() as tmp_one:
            full_root = Path(tmp_full)
            one_root = Path(tmp_one)
            _emit_bundle(num_layers=_configured_num_layers(), bundle_root=full_root)
            _emit_bundle(num_layers=1, bundle_root=one_root)
            full_compile = full_root / "compile"
            one_layer_compile = one_root / "compile"
            self.assertTrue(
                one_layer_compile.is_dir(),
                f"1L compile root not produced: {one_layer_compile}",
            )

            receipt = build_receipt(
                left_root=full_compile,
                right_root=one_layer_compile,
                label_left="64L",
                label_right="1L",
            )
            self.assertEqual(
                receipt["verdict"],
                "bound",
                f"verdict={receipt['verdict']!r} blocker={receipt['blocker']!r} "
                f"totals={receipt['totals']!r}; "
                f"leftOnly={receipt['leftOnlyKernels']} "
                f"rightOnly={receipt['rightOnlyKernels']}",
            )
            self.assertGreater(
                receipt["totals"]["sharedKernelCount"],
                0,
                "no kernels in common — emitter shape regression",
            )
            self.assertEqual(
                receipt["totals"]["mismatchCount"],
                0,
                f"per-kernel mismatch: kernels={receipt['kernels']}",
            )
            # 1-layer is a strict numLayers reduction, not a structural
            # change, so the emitted kernel classes must be the same on
            # both sides.
            self.assertEqual(
                receipt["leftOnlyKernels"], [],
                "64L emitted a kernel that 1L did not",
            )
            self.assertEqual(
                receipt["rightOnlyKernels"], [],
                "1L emitted a kernel that 64L did not",
            )

    def test_one_layer_vs_one_layer_is_byte_stable(self) -> None:
        # Cross-check the harness itself: emitting 1L twice must produce
        # byte-identical output. If this fails, the property we're
        # asserting is unobservable from this test setup (e.g.
        # nondeterministic output ordering).
        with tempfile.TemporaryDirectory() as tmp_a, \
             tempfile.TemporaryDirectory() as tmp_b:
            _emit_bundle(num_layers=1, bundle_root=Path(tmp_a))
            _emit_bundle(num_layers=1, bundle_root=Path(tmp_b))
            receipt = build_receipt(
                left_root=Path(tmp_a) / "compile",
                right_root=Path(tmp_b) / "compile",
                label_left="1L_a", label_right="1L_b",
            )
            self.assertEqual(receipt["verdict"], "bound")


if __name__ == "__main__":
    unittest.main()
