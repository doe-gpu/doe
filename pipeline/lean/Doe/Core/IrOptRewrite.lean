-- Doe/Core/IrOptRewrite.lean
--
-- Proof hooks for backend-independent WGSL IR integer/bool identity rewrites.
-- Mirrors: runtime/zig/src/compiler/wgsl/ir/ir_opt_rewrite.zig
--
-- The Zig pass only rewrites identities that preserve the required dynamic
-- operand: x + 0, 0 + x, x - 0, x * 1, 1 * x, x / 1, x | 0, 0 | x,
-- x ^ 0, 0 ^ x, x << 0, x >> 0, x * 0, 0 * x, x & 0, 0 & x,
-- x && true, true && x, x || false, and false || x.
--
-- Classification: lean_verified (quantified over unbounded Nat / Bool values).

import Init.Data.Nat.Bitwise.Lemmas

namespace Doe.Core.IrOptRewrite

-- ---------------------------------------------------------------------------
-- Integer identities
-- ---------------------------------------------------------------------------

-- Classification: lean_verified.
theorem intAddZeroRight (x : Nat) :
    x + 0 = x := by
  exact Nat.add_zero x

-- Classification: lean_verified.
theorem intZeroAddLeft (x : Nat) :
    0 + x = x := by
  exact Nat.zero_add x

-- Classification: lean_verified.
theorem intSubZeroRight (x : Nat) :
    x - 0 = x := by
  exact Nat.sub_zero x

-- Classification: lean_verified.
theorem intMulOneRight (x : Nat) :
    x * 1 = x := by
  exact Nat.mul_one x

-- Classification: lean_verified.
theorem intOneMulLeft (x : Nat) :
    1 * x = x := by
  exact Nat.one_mul x

-- Classification: lean_verified.
theorem intMulZeroRight (x : Nat) :
    x * 0 = 0 := by
  exact Nat.mul_zero x

-- Classification: lean_verified.
theorem intZeroMulLeft (x : Nat) :
    0 * x = 0 := by
  exact Nat.zero_mul x

-- Classification: lean_verified.
theorem intDivOneRight (x : Nat) :
    x / 1 = x := by
  exact Nat.div_one x

-- Classification: lean_verified.
theorem intOrZeroRight (x : Nat) :
    x ||| 0 = x := by
  exact Nat.or_zero x

-- Classification: lean_verified.
theorem intZeroOrLeft (x : Nat) :
    0 ||| x = x := by
  exact Nat.zero_or x

-- Classification: lean_verified.
theorem intAndZeroRight (x : Nat) :
    x &&& 0 = 0 := by
  exact Nat.and_zero x

-- Classification: lean_verified.
theorem intZeroAndLeft (x : Nat) :
    0 &&& x = 0 := by
  exact Nat.zero_and x

-- Classification: lean_verified.
theorem intXorZeroRight (x : Nat) :
    x ^^^ 0 = x := by
  exact Nat.xor_zero x

-- Classification: lean_verified.
theorem intZeroXorLeft (x : Nat) :
    0 ^^^ x = x := by
  exact Nat.zero_xor x

-- Classification: lean_verified.
theorem intShiftLeftZeroRight (x : Nat) :
    x <<< 0 = x := by
  exact Nat.shiftLeft_zero

-- Classification: lean_verified.
theorem intShiftRightZeroRight (x : Nat) :
    x >>> 0 = x := by
  exact Nat.shiftRight_zero

-- ---------------------------------------------------------------------------
-- Boolean identities
-- ---------------------------------------------------------------------------

-- Classification: lean_verified.
theorem boolAndTrueRight (x : Bool) :
    (x && true) = x := by
  cases x <;> rfl

-- Classification: lean_verified.
theorem boolTrueAndLeft (x : Bool) :
    (true && x) = x := by
  cases x <;> rfl

-- Classification: lean_verified.
theorem boolOrFalseRight (x : Bool) :
    (x || false) = x := by
  cases x <;> rfl

-- Classification: lean_verified.
theorem boolFalseOrLeft (x : Bool) :
    (false || x) = x := by
  cases x <;> rfl

end Doe.Core.IrOptRewrite
