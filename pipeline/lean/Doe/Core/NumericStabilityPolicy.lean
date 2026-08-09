-- Doe/Core/NumericStabilityPolicy.lean
--
-- Numeric-stability route-decision contract: when fast/stable/exact-reference
-- disagreement occurs, which route does the policy choose? This mirrors the
-- named policies routed by the runtime (prefer-stable, abstain, etc.).
--
-- Mirrors: runtime/zig/src/runtime/numeric_stability/policy.zig
--          (route selection + NumericInstabilityChecks fields)
-- Classification: comptime_verified (finite boolean-tuple exhaustion) plus
-- lean_verified (quantified over NumericInstabilityChecks records).

inductive RouteDecision where
  | acceptFast
  | preferStable
  | abstain
  deriving Repr, DecidableEq

structure NumericInstabilityChecks where
  firstDivergencePresent : Bool
  sensitiveOperatorMatched : Bool
  selectedTokenDisagreement : Bool
  stableMatchesExactReference : Bool
  fastMissesExactReference : Bool
  deriving Repr, DecidableEq

def selectedTokenReferenceImprovementTriggered (checks : NumericInstabilityChecks) : Bool :=
  checks.firstDivergencePresent &&
    checks.sensitiveOperatorMatched &&
    checks.selectedTokenDisagreement &&
    checks.stableMatchesExactReference &&
    checks.fastMissesExactReference

theorem selectedTokenReferenceImprovementTriggered_iff_all_checks
    (checks : NumericInstabilityChecks) :
    selectedTokenReferenceImprovementTriggered checks = true ↔
      checks.firstDivergencePresent = true ∧
      checks.sensitiveOperatorMatched = true ∧
      checks.selectedTokenDisagreement = true ∧
      checks.stableMatchesExactReference = true ∧
      checks.fastMissesExactReference = true := by
  unfold selectedTokenReferenceImprovementTriggered
  cases hFirst : checks.firstDivergencePresent <;>
    cases hSensitive : checks.sensitiveOperatorMatched <;>
    cases hDisagreement : checks.selectedTokenDisagreement <;>
    cases hStable : checks.stableMatchesExactReference <;>
    cases hFast : checks.fastMissesExactReference <;>
    simp [hFirst, hSensitive, hDisagreement, hStable, hFast]

def routeDecisionForTrigger
    (triggeredDecision fallbackDecision : RouteDecision)
    (triggered : Bool) : RouteDecision :=
  if triggered then triggeredDecision else fallbackDecision

def selectedValueForRoute {α : Type}
    (fastValue stableValue : α)
    (routeDecision : RouteDecision) : Option α :=
  match routeDecision with
  | .acceptFast => some fastValue
  | .preferStable => some stableValue
  | .abstain => none

theorem routeDecisionForTrigger_prefers_triggered_decision_when_true
    (triggeredDecision fallbackDecision : RouteDecision) :
    routeDecisionForTrigger triggeredDecision fallbackDecision true = triggeredDecision := by
  simp [routeDecisionForTrigger]

theorem routeDecisionForTrigger_prefers_fallback_decision_when_false
    (triggeredDecision fallbackDecision : RouteDecision) :
    routeDecisionForTrigger triggeredDecision fallbackDecision false = fallbackDecision := by
  simp [routeDecisionForTrigger]

theorem selectedValueForRoute_acceptFast_returns_fast
    {α : Type} (fastValue stableValue : α) :
    selectedValueForRoute fastValue stableValue .acceptFast = some fastValue := by
  simp [selectedValueForRoute]

theorem selectedValueForRoute_preferStable_returns_stable
    {α : Type} (fastValue stableValue : α) :
    selectedValueForRoute fastValue stableValue .preferStable = some stableValue := by
  simp [selectedValueForRoute]

theorem selectedValueForRoute_abstain_returns_none
    {α : Type} (fastValue stableValue : α) :
    selectedValueForRoute fastValue stableValue .abstain = none := by
  simp [selectedValueForRoute]
