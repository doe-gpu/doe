import Doe.Core.Model

def comparabilityContractSha256 : String := "20f2d04f010cac8815c545dd03b5eca9e24be40aa60214a608a96e9103895a9a"

inductive ComparabilityObligationId where
  | workloadMarkedComparable
  | leftSamplesPresent
  | rightSamplesPresent
  | leftSingleTimingClass
  | rightSingleTimingClass
  | leftRequiredTimingClass
  | rightRequiredTimingClass
  | baselineComparisonTimingClassMatch
  | baselineComparisonTraceMetaSourceMatch
  | baselineComparisonTimingSelectionPolicyMatch
  | baselineComparisonQueueSyncModeMatch
  | baselineComparisonSubmitScopeMatch
  | baselineComparisonEffectiveReadbackPathMatch
  | baselineComparisonTimingPhaseMatch
  | baselineComparisonPackageResidentBufferLoadModeMatch
  | baselineComparisonPackageResidentBufferLoadShapeMatch
  | baselineComparisonShaderSourceReceiptsMatch
  | baselineComparisonExecutionShapeMatch
  | baselineComparisonReadbackCaptureMatch
  | baselineComparisonHardwarePathMatch
  | baselineComparisonExplicitNativeShaderArtifactMatch
  | baselineNativeOperationTimingForWebgpuFfi
  | baselineUploadIgnoreFirstScopeConsistent
  | comparisonUploadIgnoreFirstScopeConsistent
  | baselineComparisonUploadBufferUsageMatch
  | baselineComparisonUploadSubmitCadenceMatch
  | baselineExecutionEvidencePresent
  | baselineSuccessfulExecutionPresent
  | baselineSuccessOrUnsupportedOrSkipped
  | baselineExecutionErrorsAbsent
  | comparisonExecutionErrorsAbsent
  | baselineComparisonTimingPlausibility
  | baselineResourceProbeAvailable
  | comparisonResourceProbeAvailable
  | strictResourceSampleTargetPositive
  | baselineResourceSampleTargetMatch
  | comparisonResourceSampleTargetMatch
  | baselineResourceSamplingNotTruncated
  | comparisonResourceSamplingNotTruncated
  | baselineResourceSampleDensitySufficient
  | comparisonResourceSampleDensitySufficient
  deriving Repr, DecidableEq

structure ComparabilityObligation where
  id : ComparabilityObligationId
  blocking : Bool
  applicable : Bool
  passes : Bool
  deriving Repr, DecidableEq

def isFailedBlocking (item : ComparabilityObligation) : Bool :=
  item.blocking && item.applicable && !item.passes

def failedBlockingObligations (items : List ComparabilityObligation) : List ComparabilityObligation :=
  items.filter isFailedBlocking

def comparableFromObligations (items : List ComparabilityObligation) : Bool :=
  (failedBlockingObligations items).isEmpty

structure ComparabilityFacts where
  workloadMarkedComparable : Bool
  leftSamplesPresent : Bool
  rightSamplesPresent : Bool
  leftSingleTimingClass : Bool
  rightSingleTimingClass : Bool
  requiredTimingClassApplies : Bool
  leftRequiredTimingClass : Bool
  rightRequiredTimingClass : Bool
  timingClassMatchApplies : Bool
  baselineComparisonTimingClassMatch : Bool
  traceMetaSourceMatchApplies : Bool
  baselineComparisonTraceMetaSourceMatch : Bool
  timingSelectionPolicyMatchApplies : Bool
  baselineComparisonTimingSelectionPolicyMatch : Bool
  queueSyncModeMatchApplies : Bool
  baselineComparisonQueueSyncModeMatch : Bool
  submitScopeMatchApplies : Bool
  baselineComparisonSubmitScopeMatch : Bool
  effectiveReadbackPathMatchApplies : Bool
  baselineComparisonEffectiveReadbackPathMatch : Bool
  timingPhaseMatchApplies : Bool
  baselineComparisonTimingPhaseMatch : Bool
  packageResidentBufferLoadModeMatchApplies : Bool
  baselineComparisonPackageResidentBufferLoadModeMatch : Bool
  packageResidentBufferLoadShapeMatchApplies : Bool
  baselineComparisonPackageResidentBufferLoadShapeMatch : Bool
  packageShaderSourceReceiptsMatchApplies : Bool
  baselineComparisonShaderSourceReceiptsMatch : Bool
  executionShapeMatchApplies : Bool
  baselineComparisonExecutionShapeMatch : Bool
  readbackCaptureMatchApplies : Bool
  baselineComparisonReadbackCaptureMatch : Bool
  hardwarePathMatchApplies : Bool
  baselineComparisonHardwarePathMatch : Bool
  explicitNativeShaderArtifactMatchApplies : Bool
  baselineComparisonExplicitNativeShaderArtifactMatch : Bool
  operationTimingClassRequired : Bool
  baselineNativeOperationTimingForWebgpuFfi : Bool
  uploadDomain : Bool
  baselineUploadIgnoreFirstScopeConsistent : Bool
  comparisonUploadIgnoreFirstScopeConsistent : Bool
  baselineComparisonUploadBufferUsageMatch : Bool
  baselineComparisonUploadSubmitCadenceMatch : Bool
  allowBaselineNoExecution : Bool
  baselineExecutionEvidencePresent : Bool
  baselineSuccessfulExecutionPresent : Bool
  baselineSuccessOrUnsupportedOrSkipped : Bool
  baselineExecutionErrorsAbsent : Bool
  comparisonExecutionErrorsAbsent : Bool
  baselineComparisonTimingPlausibility : Bool
  resourceProbeEnabled : Bool
  baselineResourceProbeAvailable : Bool
  comparisonResourceProbeAvailable : Bool
  strictComparability : Bool
  resourceSampleTargetPositive : Bool
  baselineResourceSampleTargetMatch : Bool
  comparisonResourceSampleTargetMatch : Bool
  baselineResourceSamplingNotTruncated : Bool
  comparisonResourceSamplingNotTruncated : Bool
  baselineResourceSampleDensitySufficient : Bool
  comparisonResourceSampleDensitySufficient : Bool
  deriving Repr, DecidableEq

def obligationsFromFacts (facts : ComparabilityFacts) : List ComparabilityObligation :=
  [
    { id := .workloadMarkedComparable
      blocking := true
      applicable := true
      passes := facts.workloadMarkedComparable },
    { id := .leftSamplesPresent
      blocking := true
      applicable := true
      passes := facts.leftSamplesPresent },
    { id := .rightSamplesPresent
      blocking := true
      applicable := true
      passes := facts.rightSamplesPresent },
    { id := .leftSingleTimingClass
      blocking := true
      applicable := true
      passes := facts.leftSingleTimingClass },
    { id := .rightSingleTimingClass
      blocking := true
      applicable := true
      passes := facts.rightSingleTimingClass },
    { id := .leftRequiredTimingClass
      blocking := true
      applicable := facts.requiredTimingClassApplies
      passes := facts.leftRequiredTimingClass },
    { id := .rightRequiredTimingClass
      blocking := true
      applicable := facts.requiredTimingClassApplies
      passes := facts.rightRequiredTimingClass },
    { id := .baselineComparisonTimingClassMatch
      blocking := true
      applicable := facts.timingClassMatchApplies
      passes := facts.baselineComparisonTimingClassMatch },
    { id := .baselineComparisonTraceMetaSourceMatch
      blocking := true
      applicable := facts.traceMetaSourceMatchApplies
      passes := facts.baselineComparisonTraceMetaSourceMatch },
    { id := .baselineComparisonTimingSelectionPolicyMatch
      blocking := true
      applicable := facts.timingSelectionPolicyMatchApplies
      passes := facts.baselineComparisonTimingSelectionPolicyMatch },
    { id := .baselineComparisonQueueSyncModeMatch
      blocking := true
      applicable := facts.queueSyncModeMatchApplies
      passes := facts.baselineComparisonQueueSyncModeMatch },
    { id := .baselineComparisonSubmitScopeMatch
      blocking := true
      applicable := facts.submitScopeMatchApplies
      passes := facts.baselineComparisonSubmitScopeMatch },
    { id := .baselineComparisonEffectiveReadbackPathMatch
      blocking := true
      applicable := facts.effectiveReadbackPathMatchApplies
      passes := facts.baselineComparisonEffectiveReadbackPathMatch },
    { id := .baselineComparisonTimingPhaseMatch
      blocking := true
      applicable := facts.timingPhaseMatchApplies
      passes := facts.baselineComparisonTimingPhaseMatch },
    { id := .baselineComparisonPackageResidentBufferLoadModeMatch
      blocking := true
      applicable := facts.packageResidentBufferLoadModeMatchApplies
      passes := facts.baselineComparisonPackageResidentBufferLoadModeMatch },
    { id := .baselineComparisonPackageResidentBufferLoadShapeMatch
      blocking := true
      applicable := facts.packageResidentBufferLoadShapeMatchApplies
      passes := facts.baselineComparisonPackageResidentBufferLoadShapeMatch },
    { id := .baselineComparisonShaderSourceReceiptsMatch
      blocking := true
      applicable := facts.packageShaderSourceReceiptsMatchApplies
      passes := facts.baselineComparisonShaderSourceReceiptsMatch },
    { id := .baselineComparisonExecutionShapeMatch
      blocking := true
      applicable := facts.executionShapeMatchApplies
      passes := facts.baselineComparisonExecutionShapeMatch },
    { id := .baselineComparisonReadbackCaptureMatch
      blocking := true
      applicable := facts.readbackCaptureMatchApplies
      passes := facts.baselineComparisonReadbackCaptureMatch },
    { id := .baselineComparisonHardwarePathMatch
      blocking := true
      applicable := facts.hardwarePathMatchApplies
      passes := facts.baselineComparisonHardwarePathMatch },
    { id := .baselineComparisonExplicitNativeShaderArtifactMatch
      blocking := true
      applicable := facts.explicitNativeShaderArtifactMatchApplies
      passes := facts.baselineComparisonExplicitNativeShaderArtifactMatch },
    { id := .baselineNativeOperationTimingForWebgpuFfi
      blocking := true
      applicable := facts.operationTimingClassRequired
      passes := facts.baselineNativeOperationTimingForWebgpuFfi },
    { id := .baselineUploadIgnoreFirstScopeConsistent
      blocking := true
      applicable := facts.uploadDomain
      passes := facts.baselineUploadIgnoreFirstScopeConsistent },
    { id := .comparisonUploadIgnoreFirstScopeConsistent
      blocking := true
      applicable := facts.uploadDomain
      passes := facts.comparisonUploadIgnoreFirstScopeConsistent },
    { id := .baselineComparisonUploadBufferUsageMatch
      blocking := true
      applicable := facts.uploadDomain
      passes := facts.baselineComparisonUploadBufferUsageMatch },
    { id := .baselineComparisonUploadSubmitCadenceMatch
      blocking := true
      applicable := facts.uploadDomain
      passes := facts.baselineComparisonUploadSubmitCadenceMatch },
    { id := .baselineExecutionEvidencePresent
      blocking := true
      applicable := !(facts.allowBaselineNoExecution)
      passes := facts.baselineExecutionEvidencePresent },
    { id := .baselineSuccessfulExecutionPresent
      blocking := true
      applicable := !(facts.allowBaselineNoExecution)
      passes := facts.baselineSuccessfulExecutionPresent },
    { id := .baselineSuccessOrUnsupportedOrSkipped
      blocking := true
      applicable := facts.allowBaselineNoExecution
      passes := facts.baselineSuccessOrUnsupportedOrSkipped },
    { id := .baselineExecutionErrorsAbsent
      blocking := true
      applicable := true
      passes := facts.baselineExecutionErrorsAbsent },
    { id := .comparisonExecutionErrorsAbsent
      blocking := true
      applicable := true
      passes := facts.comparisonExecutionErrorsAbsent },
    { id := .baselineComparisonTimingPlausibility
      blocking := true
      applicable := true
      passes := facts.baselineComparisonTimingPlausibility },
    { id := .baselineResourceProbeAvailable
      blocking := true
      applicable := facts.resourceProbeEnabled
      passes := facts.baselineResourceProbeAvailable },
    { id := .comparisonResourceProbeAvailable
      blocking := true
      applicable := facts.resourceProbeEnabled
      passes := facts.comparisonResourceProbeAvailable },
    { id := .strictResourceSampleTargetPositive
      blocking := true
      applicable := (facts.resourceProbeEnabled) && (facts.strictComparability)
      passes := facts.resourceSampleTargetPositive },
    { id := .baselineResourceSampleTargetMatch
      blocking := true
      applicable := (facts.resourceProbeEnabled) && (facts.strictComparability) && (facts.resourceSampleTargetPositive)
      passes := facts.baselineResourceSampleTargetMatch },
    { id := .comparisonResourceSampleTargetMatch
      blocking := true
      applicable := (facts.resourceProbeEnabled) && (facts.strictComparability) && (facts.resourceSampleTargetPositive)
      passes := facts.comparisonResourceSampleTargetMatch },
    { id := .baselineResourceSamplingNotTruncated
      blocking := true
      applicable := (facts.resourceProbeEnabled) && (facts.strictComparability) && (facts.resourceSampleTargetPositive)
      passes := facts.baselineResourceSamplingNotTruncated },
    { id := .comparisonResourceSamplingNotTruncated
      blocking := true
      applicable := (facts.resourceProbeEnabled) && (facts.strictComparability) && (facts.resourceSampleTargetPositive)
      passes := facts.comparisonResourceSamplingNotTruncated },
    { id := .baselineResourceSampleDensitySufficient
      blocking := true
      applicable := (facts.resourceProbeEnabled) && (!(facts.strictComparability))
      passes := facts.baselineResourceSampleDensitySufficient },
    { id := .comparisonResourceSampleDensitySufficient
      blocking := true
      applicable := (facts.resourceProbeEnabled) && (!(facts.strictComparability))
      passes := facts.comparisonResourceSampleDensitySufficient }
  ]

def comparableFromFacts (facts : ComparabilityFacts) : Bool :=
  comparableFromObligations (obligationsFromFacts facts)
