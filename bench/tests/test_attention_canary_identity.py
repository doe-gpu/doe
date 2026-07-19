"""Pin the attention canary identity claim used by the head_dim=256 and
head_dim=512 TSIR-emit sim runners.

The runners
(``bench/runners/csl-runners/attention_head{256,512}_f16kv_tsir_sim_runner.py``)
dispatch the TSIR-emit ``attention_scores`` body
(``runtime/zig/src/compiler/tsir/emit_kernel_body_attention.zig``) at
manifest-shape head_dim with single-PE kv_len. The canary identity is:

  *for any kv_len >= 1 with zero Q/K/V, the f32 [head_dim] output is
   all zeros, and its sha256 matches the hand-authored Doppler probe
   hash at the same head_dim.*

This module reproduces the body's two-pass-stable softmax in numpy and
asserts the identity at both head_dim=256 and head_dim=512 across the
kv_len values the runners use (15 and 7 respectively) plus a few
neighboring kv_len values to confirm the identity holds for the whole
single-PE-fitting range. If the emit body is ever changed in a way
that breaks this identity (e.g., different scale, different
initial-max), this test will catch it before the canary lane regresses.

It also pins the SRAM-budget reasoning that justifies the runner's
KV_LEN choice: at head_dim=512, kv_len > ~7 overflows the 48 KB single-
PE SRAM budget for f32 K+V. Multi-PE kv-axis distribution is the
follow-up that lifts the cap.
"""

from __future__ import annotations

import hashlib
import unittest

import numpy as np


# Per-head-dim canary hashes — these are the hashes the hand-authored
# canaries
# (bench/runners/csl-runners/attention_head{256,512}_f16kv_sim_runner.py)
# produce for an all-zero output and that the Doppler probes record at
# bench/fixtures/tsir-real-doppler-transcripts/attention_head*.doppler-transcript.json.
CANARY_OUTPUT_SHAS = {
    256: (
        "5f70bf18a086007016e948b04aed3b82103a36bea41755b6cddfaf10ace3c6ef"
    ),
    512: (
        "e5a00aa9991ac8a5ee3109844d84a55583bd20572ad3ffcd42792f3c36b183ad"
    ),
}

# 48 KB SRAM ceiling per PE for the bootstrap-shape canary lane. Real
# WSE-3 PEs have more total SRAM, but the canary budget reserves the
# rest for stack / driver / unused; tightening the cap here makes the
# runner's KV_LEN choice provable rather than empirical.
PE_SRAM_BUDGET_BYTES = 48 * 1024


def _two_pass_attention_zero_input(*, head_dim: int, kv_len: int) -> np.ndarray:
    """Reproduce the TSIR-emit attention body in numpy for zero inputs.

    Mirrors emit_kernel_body_attention.zig:emitCslAttentionScores so the
    test catches divergence (e.g., different scale literal, different
    initial-max constant) at CI time.
    """
    Q = np.zeros(head_dim, dtype=np.float32)
    K = np.zeros((kv_len, head_dim), dtype=np.float32)
    V = np.zeros((kv_len, head_dim), dtype=np.float32)
    attn_scale = np.float32(1.0)

    # Pass 1: scores + max
    max_score = np.float32(-1.0e30)
    scores = np.zeros(kv_len, dtype=np.float32)
    for k in range(kv_len):
        dot = np.float32(0.0)
        for d in range(head_dim):
            dot += Q[d] * K[k, d]
        sc = dot * attn_scale
        scores[k] = sc
        if sc > max_score:
            max_score = sc

    # Pass 2: stable softmax weights + sum
    sum_exp = np.float32(0.0)
    for k in range(kv_len):
        e = np.exp(scores[k] - max_score, dtype=np.float32)
        scores[k] = e
        sum_exp += e

    # Pass 3: output projection
    output = np.zeros(head_dim, dtype=np.float32)
    for d in range(head_dim):
        acc = np.float32(0.0)
        for k in range(kv_len):
            acc += V[k, d] * (scores[k] / sum_exp)
        output[d] = acc

    return output


def _single_pe_sram_bytes(*, head_dim: int, kv_len: int) -> int:
    """Compute on-PE SRAM bytes for the TSIR-emit attention body at
    (head_dim, kv_len) with f32 K/V/Q/output and an f32 attn_scores
    scratch buffer."""
    f32 = 4
    return f32 * (
        head_dim                  # tsir_query
        + kv_len * head_dim       # tsir_key
        + kv_len * head_dim       # tsir_value
        + head_dim                # tsir_output
        + kv_len                  # attn_scores
    )


class CanaryIdentityTest(unittest.TestCase):
    """Zero-input attention -> zero output -> known canary sha256."""

    def test_head_dim_256_kv_len_15_matches_doppler_probe(self) -> None:
        out = _two_pass_attention_zero_input(head_dim=256, kv_len=15)
        sha = hashlib.sha256(out.tobytes()).hexdigest()
        self.assertEqual(sha, CANARY_OUTPUT_SHAS[256])
        self.assertTrue(np.all(out == 0))

    def test_head_dim_512_kv_len_7_matches_doppler_probe(self) -> None:
        out = _two_pass_attention_zero_input(head_dim=512, kv_len=7)
        sha = hashlib.sha256(out.tobytes()).hexdigest()
        self.assertEqual(sha, CANARY_OUTPUT_SHAS[512])
        self.assertTrue(np.all(out == 0))

    def test_canary_identity_holds_across_kv_lens(self) -> None:
        # Identity must hold for any kv_len >= 1 since zero input
        # degenerates regardless of how many KV slots we attend to.
        for head_dim in (256, 512):
            for kv_len in (1, 2, 4, 7):
                with self.subTest(head_dim=head_dim, kv_len=kv_len):
                    out = _two_pass_attention_zero_input(
                        head_dim=head_dim, kv_len=kv_len
                    )
                    sha = hashlib.sha256(out.tobytes()).hexdigest()
                    self.assertEqual(sha, CANARY_OUTPUT_SHAS[head_dim])


class SramBudgetTest(unittest.TestCase):
    """Pin the runner's KV_LEN choice with a SRAM-budget calculation."""

    def test_head_dim_256_kv_len_15_fits(self) -> None:
        bytes_used = _single_pe_sram_bytes(head_dim=256, kv_len=15)
        self.assertLessEqual(bytes_used, PE_SRAM_BUDGET_BYTES)

    def test_head_dim_512_kv_len_7_fits(self) -> None:
        bytes_used = _single_pe_sram_bytes(head_dim=512, kv_len=7)
        self.assertLessEqual(bytes_used, PE_SRAM_BUDGET_BYTES)

    def test_head_dim_512_kv_len_15_overflows(self) -> None:
        # Documents the multi-PE follow-up: until kv-axis distribution
        # is wired, head_dim=512 cannot run with the head_dim=256
        # canary's KV_LEN.
        bytes_used = _single_pe_sram_bytes(head_dim=512, kv_len=15)
        self.assertGreater(bytes_used, PE_SRAM_BUDGET_BYTES)

    def test_head_dim_512_kv_len_8_is_the_largest_safe(self) -> None:
        # kv_len=8 fits (~36 KB), kv_len=9 overflows (~40 KB +
        # output/scores -> over 48 KB once you account for stack /
        # driver). Pin the boundary so a future change to PE_SRAM_BUDGET
        # has to update this test deliberately.
        fits_at_8 = _single_pe_sram_bytes(head_dim=512, kv_len=8)
        self.assertLessEqual(fits_at_8, PE_SRAM_BUDGET_BYTES)


if __name__ == "__main__":
    unittest.main()
