"""Receipt-first compare expansion for release pipeline runs."""

from __future__ import annotations

import subprocess
from pathlib import Path
from typing import Any

from bench.lib.bench_utils import load_json_object as load_json


def resolve_product_names(config_path: Path) -> tuple[str, str]:
    config_payload = load_json(config_path)
    baseline_payload = config_payload.get("baseline", {})
    comparison_payload = config_payload.get("comparison", {})
    baseline_name = "doe"
    comparison_name = "dawn"
    if isinstance(baseline_payload, dict):
        candidate = baseline_payload.get("name")
        if isinstance(candidate, str) and candidate.strip():
            baseline_name = candidate.strip()
    if isinstance(comparison_payload, dict):
        candidate = comparison_payload.get("name")
        if isinstance(candidate, str) and candidate.strip():
            comparison_name = candidate.strip()
    return baseline_name, comparison_name


def resolve_compare_options(config_path: Path) -> dict[str, str]:
    config_payload = load_json(config_path)
    comparability_payload = config_payload.get("comparability", {})
    resource_payload = config_payload.get("resource", {})
    benchmark_policy_payload = config_payload.get("benchmarkPolicy", {})
    options = {
        "comparability": "strict",
        "requireTimingClass": "operation",
        "resourceProbe": "none",
        "resourceSampleTargetCount": "0",
        "benchmarkPolicy": "",
    }
    if isinstance(comparability_payload, dict):
        mode = comparability_payload.get("mode")
        if isinstance(mode, str) and mode.strip():
            options["comparability"] = mode.strip()
        timing_class = comparability_payload.get("requireTimingClass")
        if isinstance(timing_class, str) and timing_class.strip():
            options["requireTimingClass"] = timing_class.strip()
    if isinstance(resource_payload, dict):
        probe = resource_payload.get("probe")
        if isinstance(probe, str) and probe.strip():
            options["resourceProbe"] = probe.strip()
        target_count = resource_payload.get("sampleTargetCount")
        if isinstance(target_count, int):
            options["resourceSampleTargetCount"] = str(target_count)
    if isinstance(benchmark_policy_payload, dict):
        policy_path = benchmark_policy_payload.get("path")
        if isinstance(policy_path, str) and policy_path.strip():
            options["benchmarkPolicy"] = policy_path.strip()
    return options


def run_step(label: str, command: list[str], *, dry_run: bool) -> None:
    print(f"[pipeline] {label}: {' '.join(command)}", flush=True)
    if dry_run:
        return
    subprocess.run(command, check=True)


def snapshot_run_receipts(workspace_path: Path, product: str) -> set[Path]:
    artifact_dir = workspace_path / "run-artifacts" / product
    if not artifact_dir.exists():
        return set()
    return set(artifact_dir.glob("*.run.json"))


def collect_run_receipts(
    workspace_path: Path,
    product: str,
    *,
    timestamp: str,
    before: set[Path],
) -> list[Path]:
    artifact_dir = workspace_path / "run-artifacts" / product
    if not artifact_dir.exists():
        raise FileNotFoundError(
            f"missing run artifact directory for product {product!r}: {artifact_dir}"
        )
    if timestamp:
        receipts = sorted(artifact_dir.glob(f"{product}-*-{timestamp}.run.json"))
    else:
        receipts = sorted(set(artifact_dir.glob("*.run.json")) - before)
    if not receipts:
        raise FileNotFoundError(
            f"no run receipts found for product {product!r} under {artifact_dir}"
        )
    return receipts


def run_receipt_first_compare(
    *,
    python_exe: str,
    compare: Path,
    config_path: Path,
    report_path: Path,
    workspace_path: Path,
    output_timestamp: str,
    timestamp_output: bool,
    dry_run: bool,
) -> None:
    baseline_product, comparison_product = resolve_product_names(config_path)
    compare_options = resolve_compare_options(config_path)
    baseline_before = snapshot_run_receipts(workspace_path, baseline_product)
    comparison_before = snapshot_run_receipts(workspace_path, comparison_product)
    common_run_config_args = [
        "--config",
        str(config_path),
        "--workspace",
        str(workspace_path),
    ]
    if timestamp_output:
        common_run_config_args.extend(["--timestamp", output_timestamp])
    else:
        common_run_config_args.append("--no-timestamp-output")

    run_step(
        "compare-baseline-run",
        [
            python_exe,
            str(compare),
            "run-config",
            "--side",
            "baseline",
            *common_run_config_args,
        ],
        dry_run=dry_run,
    )
    run_step(
        "compare-comparison-run",
        [
            python_exe,
            str(compare),
            "run-config",
            "--side",
            "comparison",
            *common_run_config_args,
        ],
        dry_run=dry_run,
    )

    if dry_run:
        run_step(
            "compare",
            [
                python_exe,
                str(compare),
                "compare",
                f"{workspace_path}/run-artifacts/{baseline_product}/*.run.json",
                f"{workspace_path}/run-artifacts/{comparison_product}/*.run.json",
                "--baseline-product",
                baseline_product,
                "--comparison-product",
                comparison_product,
                "--out",
                str(report_path),
            ],
            dry_run=True,
        )
        return

    baseline_receipts = collect_run_receipts(
        workspace_path,
        baseline_product,
        timestamp=output_timestamp if timestamp_output else "",
        before=baseline_before,
    )
    comparison_receipts = collect_run_receipts(
        workspace_path,
        comparison_product,
        timestamp=output_timestamp if timestamp_output else "",
        before=comparison_before,
    )
    if len(baseline_receipts) != len(comparison_receipts):
        raise RuntimeError(
            "receipt count mismatch: "
            f"{baseline_product}={len(baseline_receipts)} "
            f"{comparison_product}={len(comparison_receipts)}"
        )

    compare_command = [
        python_exe,
        str(compare),
        "compare",
        *[str(path) for path in baseline_receipts],
        *[str(path) for path in comparison_receipts],
        "--baseline-product",
        baseline_product,
        "--comparison-product",
        comparison_product,
        "--out",
        str(report_path),
        "--comparability",
        compare_options["comparability"],
        "--require-timing-class",
        compare_options["requireTimingClass"],
        "--resource-probe",
        compare_options["resourceProbe"],
        "--resource-sample-target-count",
        compare_options["resourceSampleTargetCount"],
    ]
    if compare_options["benchmarkPolicy"]:
        compare_command.extend(
            ["--benchmark-policy", compare_options["benchmarkPolicy"]]
        )
    run_step("compare", compare_command, dry_run=False)
