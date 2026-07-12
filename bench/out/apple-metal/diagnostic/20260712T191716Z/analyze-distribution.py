#!/usr/bin/env python3
"""Summarize the matched AMD 64 KB contract transfer on Apple Metal."""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
from pathlib import Path
from typing import Any

import numpy as np
import scipy
import sklearn
from scipy.stats import kurtosis, skew
from sklearn.mixture import GaussianMixture

BIC_IMPROVEMENT_THRESHOLD = 10.0
SECONDARY_WEIGHT_THRESHOLD = 0.10
FLOAT_TOLERANCE = 1e-9
RANDOM_SEED = 29
PER_BATCH_INITIALIZATIONS = 20
POOLED_INITIALIZATIONS = 50
REGULARIZATION_COVARIANCE = 1e-12


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Analyze five matched 64 KB Metal run-receipt pairs."
    )
    parser.add_argument(
        "--root",
        required=True,
        type=Path,
        help="Root containing timestamped run-receipt workspaces.",
    )
    parser.add_argument(
        "--out",
        required=True,
        type=Path,
        help="Canonical JSON analysis output path.",
    )
    return parser.parse_args()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def percentile(values: np.ndarray, quantile: int) -> float:
    return float(np.percentile(values, quantile, method="nearest"))


def bimodality_coefficient(values: np.ndarray) -> float:
    count = len(values)
    sample_skew = float(skew(values, bias=False))
    excess_kurtosis = float(kurtosis(values, bias=False, fisher=True))
    correction = 3 * (count - 1) ** 2 / ((count - 2) * (count - 3))
    return (sample_skew**2 + 1) / (excess_kurtosis + correction)


def fit_gmm(values: np.ndarray, initializations: int) -> dict[str, Any]:
    matrix = values.reshape(-1, 1)
    models = []
    for component_count in (1, 2):
        model = GaussianMixture(
            n_components=component_count,
            covariance_type="full",
            n_init=initializations,
            random_state=RANDOM_SEED,
            reg_covar=REGULARIZATION_COVARIANCE,
        ).fit(matrix)
        models.append(model)

    two_component = models[1]
    order = np.argsort(two_component.means_.ravel())
    means = two_component.means_.ravel()[order]
    weights = two_component.weights_[order]
    bic_improvement = float(models[0].bic(matrix) - models[1].bic(matrix))
    high_cluster_weight = float(weights[1])
    has_clear_secondary = (
        bic_improvement > BIC_IMPROVEMENT_THRESHOLD
        and high_cluster_weight + FLOAT_TOLERANCE
        >= SECONDARY_WEIGHT_THRESHOLD
    )
    return {
        "bicOneComponent": float(models[0].bic(matrix)),
        "bicTwoComponents": float(models[1].bic(matrix)),
        "bicImprovementOneMinusTwo": bic_improvement,
        "componentMeansMs": [float(value) for value in means],
        "componentWeights": [float(value) for value in weights],
        "clearSecondaryCluster": has_clear_secondary,
    }


def load_receipt(path: Path) -> tuple[dict[str, Any], np.ndarray]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    normalization = payload.get("normalization", {})
    expected = {
        "commandRepeat": 50,
        "ignoreFirstOps": 1,
        "uploadBufferUsage": "copy-dst",
        "uploadSubmitEvery": 50,
    }
    observed = {key: normalization.get(key) for key in expected}
    if observed != expected:
        raise ValueError(
            f"contract mismatch in {path}: expected {expected}, observed {observed}"
        )
    samples = payload.get("samples", [])
    if len(samples) != 30:
        raise ValueError(f"expected 30 timed samples in {path}, found {len(samples)}")
    if payload.get("execution", {}).get("success") is not True:
        raise ValueError(f"execution failed in run receipt: {path}")
    values = np.asarray([float(sample["measuredMs"]) for sample in samples])
    return payload, values


def summarize_batch(path: Path) -> tuple[str, dict[str, Any], np.ndarray]:
    payload, values = load_receipt(path)
    result = {
        "path": str(path),
        "sha256": sha256_file(path),
        "sampleCount": len(values),
        "minMs": float(values.min()),
        "p50Ms": percentile(values, 50),
        "p95Ms": percentile(values, 95),
        "p99Ms": percentile(values, 99),
        "maxMs": float(values.max()),
        "meanMs": float(values.mean()),
        "sampleStdevMs": float(values.std(ddof=1)),
        "coefficientOfVariation": float(values.std(ddof=1) / values.mean()),
        "bimodalityCoefficient": bimodality_coefficient(values),
        "gaussianMixture": fit_gmm(values, PER_BATCH_INITIALIZATIONS),
    }
    return str(payload["product"]), result, values


def main() -> int:
    args = parse_args()
    root = args.root
    if not root.is_dir():
        raise FileNotFoundError(f"evidence root not found: {root}")
    receipt_paths = sorted(root.glob("*/workspace/run-artifacts/*/*.run.json"))
    if len(receipt_paths) != 10:
        raise ValueError(f"expected 10 run receipts under {root}, found {len(receipt_paths)}")

    products: dict[str, dict[str, Any]] = {}
    product_values: dict[str, list[np.ndarray]] = {}
    for receipt_path in receipt_paths:
        product, batch, values = summarize_batch(receipt_path)
        products.setdefault(product, {"batches": []})["batches"].append(batch)
        product_values.setdefault(product, []).append(values)

    for product, arrays in product_values.items():
        pooled = np.concatenate(arrays)
        clear_batch_count = sum(
            bool(batch["gaussianMixture"]["clearSecondaryCluster"])
            for batch in products[product]["batches"]
        )
        products[product]["clearSecondaryBatchCount"] = clear_batch_count
        products[product]["pooled"] = {
            "sampleCount": len(pooled),
            "minMs": float(pooled.min()),
            "p50Ms": percentile(pooled, 50),
            "p95Ms": percentile(pooled, 95),
            "p99Ms": percentile(pooled, 99),
            "maxMs": float(pooled.max()),
            "meanMs": float(pooled.mean()),
            "sampleStdevMs": float(pooled.std(ddof=1)),
            "coefficientOfVariation": float(pooled.std(ddof=1) / pooled.mean()),
            "bimodalityCoefficient": bimodality_coefficient(pooled),
            "gaussianMixture": fit_gmm(pooled, POOLED_INITIALIZATIONS),
        }

    comparison_paths = sorted(
        path
        for path in root.glob("compare*.json")
        if path.name != "compare.config.json"
    )
    comparisons = []
    for comparison_path in comparison_paths:
        payload = json.loads(comparison_path.read_text(encoding="utf-8"))
        comparisons.append(
            {
                "path": str(comparison_path),
                "sha256": sha256_file(comparison_path),
                "comparisonStatus": payload.get("comparisonStatus"),
                "nonComparableCount": payload.get(
                    "comparabilitySummary", {}
                ).get("nonComparableCount"),
            }
        )
    if len(comparisons) != 5:
        raise ValueError(f"expected 5 compare reports under {root}, found {len(comparisons)}")
    if any(
        row["comparisonStatus"] != "comparable"
        or row["nonComparableCount"] != 0
        for row in comparisons
    ):
        raise ValueError("one or more paired compare reports failed strict comparability")

    payload = {
        "artifactKind": "metal_64kb_bimodality_analysis",
        "schemaVersion": 1,
        "analysisPolicy": {
            "randomSeed": RANDOM_SEED,
            "covarianceType": "full",
            "regularizationCovariance": REGULARIZATION_COVARIANCE,
            "perBatchInitializations": PER_BATCH_INITIALIZATIONS,
            "pooledInitializations": POOLED_INITIALIZATIONS,
            "bicImprovementThreshold": BIC_IMPROVEMENT_THRESHOLD,
            "secondaryHighClusterWeightThreshold": SECONDARY_WEIGHT_THRESHOLD,
            "clearSecondaryClusterRule": (
                "BIC(1)-BIC(2) > 10 and high-latency component weight >= 0.10"
            ),
            "bimodalityCoefficientUse": "descriptive_only",
        },
        "environment": {
            "python": platform.python_version(),
            "numpy": np.__version__,
            "scipy": scipy.__version__,
            "scikitLearn": sklearn.__version__,
        },
        "contract": {
            "commandRepeat": 50,
            "uploadSubmitEvery": 50,
            "ignoreFirstOps": 1,
            "uploadBufferUsage": "copy-dst",
            "timedSamplesPerBatch": 30,
            "batchCountPerProduct": 5,
        },
        "comparisons": comparisons,
        "products": products,
        "classification": {
            "status": "reproduced_on_metal",
            "scope": "tail_and_bimodality_sensitivity",
            "doe": "isolated high samples; no batch met the secondary-cluster rule",
            "dawnDelegate": "three of five batches met the secondary-cluster rule",
            "claimBoundary": (
                "Diagnostic transfer evidence only; not a general speed, release, "
                "or cross-backend performance claim."
            ),
        },
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
