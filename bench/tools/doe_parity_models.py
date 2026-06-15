"""Data model and taxonomy constants for the Doe parity harness."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


VALID_EXACTNESS = frozenset({"bit_exact_solo", "algorithm_exact", "tolerance_bounded"})
BOOTSTRAP_ORACLE_KERNELS = frozenset({"fused_gemv", "gather", "rms_norm"})
KERNEL_ALIASES = {
    "rmsnorm": "rms_norm",
    "rms-norm": "rms_norm",
    "fused-gemv": "fused_gemv",
}

# Reference-source taxonomy under the re-scope (see docs/tsir-lowering-plan.md
# Step 1 "Real-kernel regime" and Step 8 "Backend lane rules").
REFERENCE_SOURCE_ZIG = "zig-tsir-oracle"
REFERENCE_SOURCE_DOPPLER = "doppler-reference-transcript"
REFERENCE_TRANSCRIPT_SCHEMA_ID = "doppler.reference-transcript/v1"

REJECTION_REASONS = frozenset(
    {
        "tsir_subgroup_unlowerable",
        "tsir_pe_budget_exhausted",
        "tsir_collective_not_representable",
        "tsir_dependence_unanalyzable",
        "tsir_source_not_affine",
        "tsir_target_unfit",
    }
)


@dataclass
class ComparisonOutcome:
    backend: str
    status: str
    backend_hash: str | None = None
    detail: str | None = None
    metric: str | None = None
    metric_value: float | None = None
    metric_epsilon: float | None = None


@dataclass(frozen=True)
class TolerancePolicy:
    metric: str
    epsilon: float


@dataclass
class ReferenceSource:
    """Names which oracle regime produced the reference hash."""

    kind: str
    execution_graph_hash: str | None = None
    source_hash: str | None = None
    transcript_path: str | None = None
    detail: str | None = None

    def to_json(self) -> dict[str, Any]:
        if self.kind == REFERENCE_SOURCE_ZIG:
            doc: dict[str, Any] = {"kind": REFERENCE_SOURCE_ZIG}
            if self.detail is not None:
                doc["detail"] = self.detail
            return doc
        if self.kind == REFERENCE_SOURCE_DOPPLER:
            if self.execution_graph_hash is None or self.source_hash is None:
                raise ValueError(
                    "doppler reference source requires executionGraphHash "
                    "and sourceHash."
                )
            doc = {
                "kind": REFERENCE_SOURCE_DOPPLER,
                "executionGraphHash": self.execution_graph_hash,
                "sourceHash": self.source_hash,
            }
            if self.transcript_path is not None:
                doc["transcriptPath"] = self.transcript_path
            if self.detail is not None:
                doc["detail"] = self.detail
            return doc
        raise ValueError(f"unknown reference source kind: {self.kind!r}")


class BootstrapOracleNotImplemented(RuntimeError):
    """Raised when the bootstrap oracle cannot honestly execute a case."""


class DopplerTranscriptInvalid(ValueError):
    """Raised when a supplied Doppler transcript fails validation."""


@dataclass(frozen=True)
class LoweringIdentity:
    tsir_semantic_digest: str
    tsir_realization_digest: str
    emitter_digest: str
    target_descriptor_correctness_hash: str

    def to_json(self) -> dict[str, str]:
        return {
            "emitterDigest": self.emitter_digest,
            "targetDescriptorCorrectnessHash": (
                self.target_descriptor_correctness_hash
            ),
            "tsirRealizationDigest": self.tsir_realization_digest,
            "tsirSemanticDigest": self.tsir_semantic_digest,
        }


@dataclass
class ParityReceipt:
    schema_version: int
    artifact_kind: str
    kernel: str
    exactness_class: str
    reference_hash: str | None
    inputs_digest: str
    comparisons: list[ComparisonOutcome] = field(default_factory=list)
    rejection_reasons: list[str] = field(default_factory=list)
    lowering_identity: LoweringIdentity | None = None
    reference_source: ReferenceSource | None = None

    def to_json(self) -> dict[str, Any]:
        def comparison_to_json(c: ComparisonOutcome) -> dict[str, Any]:
            doc: dict[str, Any] = {
                "backend": c.backend,
                "status": c.status,
                "backendHash": c.backend_hash,
                "detail": c.detail,
            }
            if (
                c.metric is not None
                or c.metric_value is not None
                or c.metric_epsilon is not None
            ):
                doc["numeric"] = {
                    "metric": c.metric,
                    "value": c.metric_value,
                    "epsilon": c.metric_epsilon,
                }
            return doc

        doc: dict[str, Any] = {
            "schemaVersion": self.schema_version,
            "artifactKind": self.artifact_kind,
            "kernel": self.kernel,
            "exactnessClass": self.exactness_class,
            "referenceHash": self.reference_hash,
            "inputsDigest": self.inputs_digest,
            "comparisons": [comparison_to_json(c) for c in self.comparisons],
            "rejectionReasons": self.rejection_reasons,
        }
        if self.reference_source is not None:
            doc["referenceSource"] = self.reference_source.to_json()
        if self.lowering_identity is not None:
            doc["loweringIdentity"] = self.lowering_identity.to_json()
        return doc
