"""Host-side stitch for the kv-axis-sharded attention partials kernel.

Companion to the multi-PE TSIR-CSL emit body
(``runtime/zig/src/compiler/tsir/emit_kernel_body_attention.zig::emitKvAxisSharded``).
Each PE writes a ``[head_dim + 2]f32`` partials buffer:

    output[0..head_dim] = local_O[d]   (un-normalized: sum_k weights[k] * V_local[k, d])
    output[head_dim]    = local_max
    output[head_dim+1]  = local_sum_exp

The kernel does NOT divide by sum_exp internally — that would require a
cross-PE reduce inside the kernel. Instead each PE's partials are
host-stitched via the standard distributed log-sum-exp recipe:

    global_max     = max_i local_max_i
    rescale_i      = exp(local_max_i - global_max)
    global_sum_exp = sum_i rescale_i * local_sum_exp_i
    O[d]           = (sum_i rescale_i * local_O_i[d]) / global_sum_exp

This mirrors the slot-sharded KV pattern: kernels emit per-PE pieces,
host plan stitches. Numerics are f32-equivalent to the single-PE
two-pass-stable softmax up to sum reordering.

The on-hardware host plan reads each PE's exported ``output`` buffer
into a ``[num_pes, head_dim + 2]f32`` array and calls
``stitch_kv_axis_sharded_partials`` to recover the single-PE-equivalent
``[head_dim]f32`` output. This module is also the in-tree numerical
reference that
``bench/tests/test_attention_canary_kv_axis_sharded_identity.py``
asserts against.
"""

from __future__ import annotations

from typing import Final

import numpy as np

# Sentinel used by the kernel for tail slots (gk >= kv_len) and as the
# initial-max value before the local-pass-1 scan. -1e30 is the same
# constant the single-PE body uses; per-PE local_max defaults to it
# when a PE has no valid slots (its slot_base is already past kv_len).
_NEG_INF_SENTINEL: Final[np.float32] = np.float32(-1.0e30)


def stitch_kv_axis_sharded_partials(partials: np.ndarray) -> np.ndarray:
    """Stitch per-PE attention partials into a single-PE-equivalent O[d].

    Args:
        partials: ``[num_pes, head_dim + 2]`` ``float32`` array. Row
            ``i`` is PE ``i``'s ``[local_O[0..head_dim], local_max,
            local_sum_exp]`` block. Must be ``np.float32``.

    Returns:
        ``[head_dim]`` ``float32`` array equal to the single-PE
        reference output up to f32 sum-reorder noise.

    Raises:
        ValueError: shape or dtype mismatch.
    """
    if partials.dtype != np.float32:
        raise ValueError(
            "stitch_kv_axis_sharded_partials: partials must be float32, "
            f"got {partials.dtype}"
        )
    if partials.ndim != 2 or partials.shape[1] < 3:
        raise ValueError(
            "stitch_kv_axis_sharded_partials: expected shape "
            "[num_pes, head_dim + 2], got "
            f"{tuple(partials.shape)}"
        )
    head_dim = partials.shape[1] - 2
    local_O = partials[:, :head_dim]            # [num_pes, head_dim]
    local_max = partials[:, head_dim]           # [num_pes]
    local_sum_exp = partials[:, head_dim + 1]   # [num_pes]

    # If every PE saw zero valid slots (e.g. kv_len < num_pes and the
    # caller still ran every PE), local_max stays at the -1e30 sentinel
    # everywhere; global_max is also the sentinel and rescale_i is
    # exp(0) = 1, but local_sum_exp is 0 so global_sum_exp is 0. That
    # matches the no-attention case; we fall through to a zero output
    # via the divide-by-zero guard below.
    global_max = np.float32(np.max(local_max))
    rescale = np.exp(local_max - global_max, dtype=np.float32)
    global_sum_exp = np.float32(np.sum(rescale * local_sum_exp, dtype=np.float32))
    if global_sum_exp == np.float32(0.0):
        return np.zeros(head_dim, dtype=np.float32)
    weighted_O = (rescale[:, None] * local_O).astype(np.float32)
    summed_O = np.sum(weighted_O, axis=0, dtype=np.float32).astype(np.float32)
    return (summed_O / global_sum_exp).astype(np.float32)


def emit_local_partials(
    *,
    Q: np.ndarray,
    K_local: np.ndarray,
    V_local: np.ndarray,
    slot_base: int,
    kv_len: int,
    attn_scale: float = 1.0,
) -> np.ndarray:
    """Reproduce the kv-axis-sharded body for one PE in numpy.

    Mirrors ``emit_kernel_body_attention.zig::emitKvAxisSharded`` so
    callers (the identity test, future host-plan rehearsals) can
    generate per-PE partials without a hardware run. Tail-slot masking
    matches the kernel: any local slot whose global position
    ``gk = slot_base + k >= kv_len`` is forced to ``-1e30`` pre-exp so
    its contribution to ``local_sum_exp`` and ``local_O`` is zero.

    Args:
        Q: ``[head_dim]`` ``float32``. Replicated across all PEs.
        K_local: ``[slots_per_pe, head_dim]`` ``float32``. PE-local K
            slice.
        V_local: ``[slots_per_pe, head_dim]`` ``float32``. PE-local V
            slice.
        slot_base: global position of this PE's first slot
            (``pe_id * slots_per_pe``).
        kv_len: total kv length across all PEs (used for tail mask).
        attn_scale: must match the kernel's ``attn_scale`` literal.

    Returns:
        ``[head_dim + 2]`` ``float32`` partials block matching the
        kernel's output layout.
    """
    if Q.dtype != np.float32 or K_local.dtype != np.float32 or V_local.dtype != np.float32:
        raise ValueError("emit_local_partials: Q/K_local/V_local must be float32")
    head_dim = Q.shape[0]
    slots_per_pe = K_local.shape[0]
    if K_local.shape != (slots_per_pe, head_dim) or V_local.shape != (slots_per_pe, head_dim):
        raise ValueError(
            "emit_local_partials: K_local / V_local shape mismatch — "
            f"K:{K_local.shape} V:{V_local.shape} expected "
            f"({slots_per_pe}, {head_dim})"
        )
    scale = np.float32(attn_scale)

    # Local pass 1: scores + local_max with tail mask. Use the same
    # -1e30 sentinel as the kernel; tail slots cannot win the max.
    local_max = _NEG_INF_SENTINEL
    scores = np.full(slots_per_pe, _NEG_INF_SENTINEL, dtype=np.float32)
    for k in range(slots_per_pe):
        gk = slot_base + k
        if gk >= kv_len:
            continue
        dot = np.float32(0.0)
        for d in range(head_dim):
            dot += Q[d] * K_local[k, d]
        sc = np.float32(dot * scale)
        scores[k] = sc
        if sc > local_max:
            local_max = sc

    # Local pass 2: weights + local_sum_exp. Tail-slot weights collapse
    # to exp(-1e30 - local_max) = 0 in f32.
    local_sum_exp = np.float32(0.0)
    for k in range(slots_per_pe):
        e = np.float32(np.exp(scores[k] - local_max, dtype=np.float32))
        scores[k] = e
        local_sum_exp += e

    # Local pass 3: un-normalized local_O[d] = sum_k weights[k] * V[k,d].
    local_O = np.zeros(head_dim, dtype=np.float32)
    for d in range(head_dim):
        acc = np.float32(0.0)
        for k in range(slots_per_pe):
            acc += np.float32(V_local[k, d] * scores[k])
        local_O[d] = acc

    out = np.empty(head_dim + 2, dtype=np.float32)
    out[:head_dim] = local_O
    out[head_dim] = local_max
    out[head_dim + 1] = local_sum_exp
    return out


def shard_kv_along_position(
    *, K: np.ndarray, V: np.ndarray, num_pes: int, slots_per_pe: int
) -> tuple[np.ndarray, np.ndarray]:
    """Slice full ``[kv_len_max, head_dim]`` K/V into per-PE shards.

    Convenience wrapper: pads K/V along the position axis up to
    ``num_pes * slots_per_pe`` with zeros (matching the kernel's
    "tail slots are masked" assumption — they read garbage but the
    score path forces them to ``-1e30`` so they contribute nothing).

    Returns ``(K_shards, V_shards)`` both shaped
    ``[num_pes, slots_per_pe, head_dim]``.
    """
    if K.shape != V.shape:
        raise ValueError(
            f"shard_kv_along_position: K/V shape mismatch K:{K.shape} V:{V.shape}"
        )
    if K.ndim != 2:
        raise ValueError(
            "shard_kv_along_position: expected 2D K/V, got "
            f"{K.ndim}D"
        )
    kv_len_actual, head_dim = K.shape
    total_slots = num_pes * slots_per_pe
    if kv_len_actual > total_slots:
        raise ValueError(
            "shard_kv_along_position: kv_len "
            f"{kv_len_actual} exceeds num_pes*slots_per_pe = {total_slots}"
        )
    pad = total_slots - kv_len_actual
    K_padded = np.concatenate(
        [K, np.zeros((pad, head_dim), dtype=K.dtype)], axis=0
    ) if pad > 0 else K
    V_padded = np.concatenate(
        [V, np.zeros((pad, head_dim), dtype=V.dtype)], axis=0
    ) if pad > 0 else V
    K_shards = K_padded.reshape(num_pes, slots_per_pe, head_dim)
    V_shards = V_padded.reshape(num_pes, slots_per_pe, head_dim)
    return K_shards.astype(np.float32), V_shards.astype(np.float32)
