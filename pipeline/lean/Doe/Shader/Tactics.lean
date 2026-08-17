-- Doe/Shader/Tactics.lean
--
-- Custom domain tactics and decision procedures for bounds solving.
-- Uses Lean 4's Presburger arithmetic decision procedure (omega)
-- to automate affine bounds and dispatch precondition proofs.

import Lean

open Lean Elab Tactic

/-- Domain tactic to automatically discharge linear and affine shader bounds.
    Unfolds single-dimension global invocation ID definitions and invokes `omega`. -/
macro "bounds_solve" : tactic =>
  `(tactic| (
    try unfold globalInvocationId
    try unfold BoundsMatcherAxisDispatch.gid
    omega
  ))
