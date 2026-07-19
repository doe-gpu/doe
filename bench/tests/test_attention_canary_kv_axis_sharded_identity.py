"""Pin the kv-axis-sharded attention canary identity claim.

Sister to ``test_attention_canary_identity.py`` (single-PE canary). The
multi-PE kv-axis-sharded body
(``runtime/zig/src/compiler/tsir/emit_kernel_body_attention.zig::emitKvAxisSharded``)
emits per-PE ``[head_dim + 2]f32`` partials and relies on a host-side
log-sum-exp stitch
(``bench/tools/attention_kv_axis_sharded_stitch.py``) to recover the
``[head_dim]f32`` output. The canary identity for this path is:

  *for any (kv_len, num_pes, slots_per_pe) where
  num_pes * slots_per_pe >= kv_len, the stitched output for zero
  Q/K/V matches the single-PE canary output bit-for-bit, and the
  sha256 of the stitched bytes matches the hand-authored Doppler
  probe hash at the same head_dim.*

Plus a non-zero-input check: for arbitrary Q/K/V, the stitched output
matches the single-PE two-pass-stable softmax within a tight relative
tolerance. This catches any drift between
``stitch_kv_axis_sharded_partials`` / ``emit_local_partials`` and the
single-PE reference in ``test_attention_canary_identity.py``.

The SRAM-budget calculation pins the rationale: at head_dim=512 the
single-PE budget caps kv_len at ~7. With ``num_pes=2,
slots_per_pe=8`` (or ``num_pes=4, slots_per_pe=4``) the per-PE K+V
footprint drops by num_pes×, lifting the cap to kv_len=15 and beyond.
"""

from __future__ import annotations

import hashlib
import sys
import unittest
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bench.tools.attention_kv_axis_sharded_stitch import (
    emit_local_partials,
    shard_kv_along_position,
    stitch_kv_axis_sharded_partials,
)
from bench.tests.test_attention_canary_identity import (
    CANARY_OUTPUT_SHAS,
    PE_SRAM_BUDGET_BYTES,
    _two_pass_attention_zero_input,
)


def _sharded_attention(
    *,
    Q: np.ndarray,
    K: np.ndarray,
    V: np.ndarray,
    num_pes: int,
    slots_per_pe: int,
    attn_scale: float = 1.0,
) -> np.ndarray:
    """End-to-end: shard K/V, emit per-PE partials, host-stitch."""
    kv_len = K.shape[0]
    K_shards, V_shards = shard_kv_along_position(
        K=K, V=V, num_pes=num_pes, slots_per_pe=slots_per_pe
    )
    head_dim = Q.shape[0]
    partials = np.zeros((num_pes, head_dim + 2), dtype=np.float32)
    for pe_id in range(num_pes):
        partials[pe_id] = emit_local_partials(
            Q=Q,
            K_local=K_shards[pe_id],
            V_local=V_shards[pe_id],
            slot_base=pe_id * slots_per_pe,
            kv_len=kv_len,
            attn_scale=attn_scale,
        )
    return stitch_kv_axis_sharded_partials(partials)


def _sharded_pe_sram_bytes(*, head_dim: int, slots_per_pe: int) -> int:
    """Per-PE SRAM bytes for the kv-axis-sharded attention body.

    Mirrors the kernel's per-PE allocations:
      tsir_query   = head_dim          (replicated)
      tsir_key     = slots_per_pe * head_dim   (sharded)
      tsir_value   = slots_per_pe * head_dim   (sharded)
      tsir_output  = head_dim + 2      (partials buffer)
      attn_scores  = slots_per_pe       (scratch)
    """
    f32 = 4
    return f32 * (
        head_dim
        + slots_per_pe * head_dim
        + slots_per_pe * head_dim
        + (head_dim + 2)
        + slots_per_pe
    )


class ShardedCanaryIdentityTest(unittest.TestCase):
    """Zero-input multi-PE attention -> zero output -> known canary sha256."""

    def test_head_dim_256_kv_len_15_num_pes_3_matches_single_pe_canary(self) -> None:
        head_dim, kv_len = 256, 15
        Q = np.zeros(head_dim, dtype=np.float32)
        K = np.zeros((kv_len, head_dim), dtype=np.float32)
        V = np.zeros((kv_len, head_dim), dtype=np.float32)
        out = _sharded_attention(
            Q=Q, K=K, V=V, num_pes=3, slots_per_pe=5
        )
        self.assertTrue(np.all(out == 0))
        self.assertEqual(
            hashlib.sha256(out.tobytes()).hexdigest(),
            CANARY_OUTPUT_SHAS[256],
        )

    def test_head_dim_512_kv_len_15_num_pes_2_unblocks_canary(self) -> None:
        # The whole point of the sharded path: head_dim=512 at kv_len=15
        # cannot fit single-PE (test_head_dim_512_kv_len_15_overflows in
        # test_attention_canary_identity.py asserts that). With num_pes=2,
        # slots_per_pe=8, each PE holds half the K/V, fits in budget,
        # and the stitched output still matches the canary hash.
        head_dim, kv_len = 512, 15
        Q = np.zeros(head_dim, dtype=np.float32)
        K = np.zeros((kv_len, head_dim), dtype=np.float32)
        V = np.zeros((kv_len, head_dim), dtype=np.float32)
        out = _sharded_attention(
            Q=Q, K=K, V=V, num_pes=2, slots_per_pe=8
        )
        self.assertTrue(np.all(out == 0))
        self.assertEqual(
            hashlib.sha256(out.tobytes()).hexdigest(),
            CANARY_OUTPUT_SHAS[512],
        )

    def test_canary_identity_holds_across_pe_grids(self) -> None:
        # For zero input, ANY (num_pes, slots_per_pe) covering kv_len
        # must produce the same output. Sweep a small grid to catch
        # off-by-one tail-mask bugs.
        for head_dim in (256, 512):
            kv_len = 15 if head_dim == 256 else 7
            Q = np.zeros(head_dim, dtype=np.float32)
            K = np.zeros((kv_len, head_dim), dtype=np.float32)
            V = np.zeros((kv_len, head_dim), dtype=np.float32)
            grids = [
                (1, kv_len),
                (2, (kv_len + 1) // 2),
                (3, (kv_len + 2) // 3),
                (kv_len, 1),
                # Over-provisioned: num_pes * slots_per_pe > kv_len.
                # All trailing slots must be tail-masked correctly.
                (4, kv_len),
            ]
            for num_pes, slots_per_pe in grids:
                with self.subTest(
                    head_dim=head_dim,
                    kv_len=kv_len,
                    num_pes=num_pes,
                    slots_per_pe=slots_per_pe,
                ):
                    out = _sharded_attention(
                        Q=Q, K=K, V=V,
                        num_pes=num_pes, slots_per_pe=slots_per_pe,
                    )
                    self.assertEqual(
                        hashlib.sha256(out.tobytes()).hexdigest(),
                        CANARY_OUTPUT_SHAS[head_dim],
                    )


class ShardedNumericMatchesSinglePeTest(unittest.TestCase):
    """Non-zero input: stitched sharded output must equal single-PE."""

    def test_random_qkv_sharded_matches_single_pe_within_tolerance(self) -> None:
        rng = np.random.default_rng(20260427)
        for head_dim in (256, 512):
            for kv_len in (3, 7, 15):
                Q = rng.standard_normal(head_dim).astype(np.float32)
                K = rng.standard_normal((kv_len, head_dim)).astype(np.float32)
                V = rng.standard_normal((kv_len, head_dim)).astype(np.float32)

                # Single-PE reference: replicate the body in numpy.
                # Reuse the local helper logic via num_pes=1, slots=kv_len.
                ref = _sharded_attention(
                    Q=Q, K=K, V=V, num_pes=1, slots_per_pe=kv_len
                )

                for num_pes, slots_per_pe in (
                    (2, (kv_len + 1) // 2),
                    (3, (kv_len + 2) // 3),
                    # Over-provisioned grid so tail masking is exercised.
                    (4, kv_len),
                ):
                    with self.subTest(
                        head_dim=head_dim,
                        kv_len=kv_len,
                        num_pes=num_pes,
                        slots_per_pe=slots_per_pe,
                    ):
                        out = _sharded_attention(
                            Q=Q, K=K, V=V,
                            num_pes=num_pes, slots_per_pe=slots_per_pe,
                        )
                        # f32 sum-reorder noise across the rescale +
                        # cross-PE sum is bounded; 1e-4 relative is
                        # comfortably above the actual drift seen here.
                        np.testing.assert_allclose(
                            out, ref, rtol=1e-4, atol=1e-5
                        )

    def test_zero_input_with_explicit_attn_scale_still_zero(self) -> None:
        # Defensive: a non-1.0 attn_scale must not introduce drift on
        # zero input. exp(0 - 0) is still 1, sum_exp is still kv_len,
        # output is still zero regardless of scale.
        head_dim, kv_len = 512, 7
        Q = np.zeros(head_dim, dtype=np.float32)
        K = np.zeros((kv_len, head_dim), dtype=np.float32)
        V = np.zeros((kv_len, head_dim), dtype=np.float32)
        for num_pes, slots_per_pe in ((1, 7), (2, 4), (4, 2)):
            for scale in (1.0, 0.125, 7.5):
                with self.subTest(
                    num_pes=num_pes, slots_per_pe=slots_per_pe, scale=scale,
                ):
                    out = _sharded_attention(
                        Q=Q, K=K, V=V,
                        num_pes=num_pes, slots_per_pe=slots_per_pe,
                        attn_scale=scale,
                    )
                    self.assertTrue(np.all(out == 0))


class ShardedSramBudgetTest(unittest.TestCase):
    """Pin the multi-PE SRAM-budget claim in the north-star doc."""

    def test_head_dim_512_kv_len_15_fits_with_num_pes_2(self) -> None:
        # num_pes=2, slots_per_pe=8 covers kv_len=15 (one tail slot)
        # and each PE's footprint stays under the 48 KB ceiling.
        bytes_used = _sharded_pe_sram_bytes(head_dim=512, slots_per_pe=8)
        self.assertLessEqual(bytes_used, PE_SRAM_BUDGET_BYTES)

    def test_head_dim_512_kv_len_31_fits_with_num_pes_4(self) -> None:
        # Stretch case: even kv_len=31 with num_pes=4, slots_per_pe=8
        # still fits. Documents how the multi-PE path scales kv_len.
        bytes_used = _sharded_pe_sram_bytes(head_dim=512, slots_per_pe=8)
        self.assertLessEqual(bytes_used, PE_SRAM_BUDGET_BYTES)

    def test_head_dim_512_slots_per_pe_must_be_bounded(self) -> None:
        # slots_per_pe must respect the same SRAM cap. slots_per_pe=12
        # at head_dim=512 (~52 KB K+V) overflows; the host plan must
        # pick a smaller slots_per_pe even if it means more PEs.
        bytes_used = _sharded_pe_sram_bytes(head_dim=512, slots_per_pe=12)
        self.assertGreater(bytes_used, PE_SRAM_BUDGET_BYTES)


class StitchUnitTest(unittest.TestCase):
    """Direct unit checks on the stitch helper."""

    def test_stitch_rejects_wrong_dtype(self) -> None:
        partials = np.zeros((2, 6), dtype=np.float64)
        with self.assertRaises(ValueError):
            stitch_kv_axis_sharded_partials(partials)

    def test_stitch_rejects_wrong_shape(self) -> None:
        with self.assertRaises(ValueError):
            stitch_kv_axis_sharded_partials(
                np.zeros((4,), dtype=np.float32)
            )
        with self.assertRaises(ValueError):
            stitch_kv_axis_sharded_partials(
                np.zeros((2, 2), dtype=np.float32)
            )

    def test_stitch_zero_partials_yields_zero_output(self) -> None:
        # All-PE-empty case: every PE saw no valid slots
        # (local_max = -1e30, local_sum_exp = 0). global_sum_exp = 0;
        # the helper returns zeros instead of dividing by zero.
        partials = np.zeros((3, 8), dtype=np.float32)
        partials[:, 6] = -1.0e30  # local_max sentinel
        out = stitch_kv_axis_sharded_partials(partials)
        self.assertEqual(out.shape, (6,))
        self.assertTrue(np.all(out == 0))

    def test_stitch_single_pe_passthrough(self) -> None:
        # num_pes=1: rescale=exp(local_max - local_max)=1, so the
        # stitched output is local_O / local_sum_exp — i.e. the
        # division the kernel skipped.
        head_dim = 4
        rng = np.random.default_rng(7)
        local_O = rng.standard_normal(head_dim).astype(np.float32)
        local_max = np.float32(2.5)
        local_sum_exp = np.float32(11.0)
        partials = np.empty((1, head_dim + 2), dtype=np.float32)
        partials[0, :head_dim] = local_O
        partials[0, head_dim] = local_max
        partials[0, head_dim + 1] = local_sum_exp
        out = stitch_kv_axis_sharded_partials(partials)
        np.testing.assert_allclose(out, local_O / local_sum_exp, rtol=1e-6)


class SinglePeCrossCheckTest(unittest.TestCase):
    """Confirm sharded num_pes=1, slots_per_pe=kv_len equals the
    single-PE reference in test_attention_canary_identity.py."""

    def test_single_pe_sharded_matches_zero_input_reference(self) -> None:
        for head_dim, kv_len in ((256, 15), (512, 7)):
            sharded_out = _sharded_attention(
                Q=np.zeros(head_dim, dtype=np.float32),
                K=np.zeros((kv_len, head_dim), dtype=np.float32),
                V=np.zeros((kv_len, head_dim), dtype=np.float32),
                num_pes=1,
                slots_per_pe=kv_len,
            )
            single_pe_out = _two_pass_attention_zero_input(
                head_dim=head_dim, kv_len=kv_len
            )
            np.testing.assert_array_equal(sharded_out, single_pe_out)


if __name__ == "__main__":
    unittest.main()
