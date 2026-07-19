"""Pin the 1-layer == 61-layer per-kernel byte-identity property
(attention-canary precondition).

Refinement 8 in `docs/cerebras-model-ledgers.md` claims:

  > The host-plan tool already accepts numLayers; verify in
  > runtime/zig/src/spatial/csl/csl_host_plan_tool.zig that 1-layer emission keeps
  > the per-kernel artifacts identical to the 60-layer emission
  > (kernel CSL is per-class, not per-layer-instance).

This test pins it as a regression. It runs the host-plan tool against
two configurations that differ only in `modelConfig.numLayers` (1 vs
the upstream 31B value, currently 61) and asserts every shared kernel
emits the same `layout.csl`, `pe_program.csl`, and
`pe_program.metadata.json` bytes on both sides.

A failure here is a host-plan emit bug — the per-kernel CSL would have
become a function of layer instance rather than layer class, breaking
the L=1 stand-in setup that attention-canary first-token parity relies on. The
test compares the Zig host-plan tool's `--mode steps` output without
invoking `cslc`; it only exercises the layout/pe_program emitter.

Skipped automatically when the `doe-csl-host-plan-tool` binary or the
upstream 61-layer compile root are unavailable, so the test does not
fail on a clean checkout that hasn't built the Zig binary yet.
"""

from __future__ import annotations

import copy
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
UPSTREAM_31B_CONFIG = (
    REPO_ROOT
    / "runtime"
    / "zig"
    / "examples"
    / "execution-v1"
    / "gemma-4-31b-smoke.json"
)

def _emit_bundle(*, num_layers: int, bundle_root: Path) -> None:
    """Run doe-csl-host-plan-tool against a config patched with the
    given numLayers, materializing layout.csl + pe_program.csl per
    kernel under <bundle_root>/compile/<kernel>/. cslc is intentionally
    NOT invoked (no --cslc-executable) — we only exercise the emitter."""
    config = json.loads(UPSTREAM_31B_CONFIG.read_text(encoding="utf-8"))
    config["modelConfig"]["numLayers"] = num_layers
    cfg_path = bundle_root / f"gemma-4-31b-{num_layers}L.json"
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
    config = json.loads(UPSTREAM_31B_CONFIG.read_text(encoding="utf-8"))
    return int(config["modelConfig"]["numLayers"])


class OneLayerByteIdentityTest(unittest.TestCase):

    @classmethod
    def setUpClass(cls) -> None:
        if not HOST_PLAN_TOOL.is_file():
            raise unittest.SkipTest(
                f"doe-csl-host-plan-tool not built at {HOST_PLAN_TOOL}"
            )

    def test_one_layer_emits_byte_identical_per_kernel_artifacts_to_61L(
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
                label_left="61L",
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
            # Belt-and-suspenders: the kernel set must not differ either.
            # 1-layer is a strict numLayers reduction, not a structural
            # change, so the emitted kernel classes must be the same.
            self.assertEqual(
                receipt["leftOnlyKernels"], [],
                "61L emitted a kernel that 1L did not",
            )
            self.assertEqual(
                receipt["rightOnlyKernels"], [],
                "1L emitted a kernel that 61L did not",
            )

    def test_one_layer_vs_one_layer_is_byte_stable(self) -> None:
        # Cross-check the test harness itself: emitting 1L twice must
        # produce byte-identical output. If this fails, the property
        # we're trying to assert is unobservable from this test setup
        # (e.g. nondeterministic output ordering).
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
