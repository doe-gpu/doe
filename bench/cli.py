"""Doe benchmark CLI.

Product-based benchmark runner with isolated runs, compare reports, and claim
reports.

Usage:
    python3 bench/cli.py workload --suite config/doe-workload-suite.json
    python3 bench/cli.py run     --product doe --executor-id doe_direct_vulkan ...
    python3 bench/cli.py run-config --config bench/native-compare/foo.json --side baseline
    python3 bench/cli.py compare <receipt1.run.json> <receipt2.run.json> ...
    python3 bench/cli.py claim   bench/out/foo.compare.json --mode local
    python3 bench/cli.py list    --products | --executors | --workloads FILE
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[1]

if __name__ == "__main__" and not __package__:
    environment = os.environ.copy()
    existing_python_path = environment.get("PYTHONPATH")
    environment["PYTHONPATH"] = (
        f"{REPO_ROOT}{os.pathsep}{existing_python_path}"
        if existing_python_path
        else str(REPO_ROOT)
    )
    os.execve(
        sys.executable,
        [sys.executable, "-m", "bench.cli", *sys.argv[1:]],
        environment,
    )


def _utc_timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")

# ---------------------------------------------------------------------------
# workload subcommand
# ---------------------------------------------------------------------------


def _add_workload_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--suite",
        default="config/doe-workload-suite.json",
        help="Unified workload suite contract path",
    )
    parser.add_argument(
        "--workload-id",
        default="",
        help="Run one workload from the suite",
    )
    parser.add_argument(
        "--out",
        default="",
        help="Consolidated workload ledger path",
    )


def _cmd_workload(args: argparse.Namespace) -> int:
    from bench.workload_runner import run_suite

    timestamp = _utc_timestamp()
    output_path = Path(args.out) if args.out else Path(
        f"bench/out/workloads/{timestamp}/doe-workload-ledger.json"
    )
    try:
        ledger = run_suite(
            REPO_ROOT / args.suite,
            REPO_ROOT / output_path,
            REPO_ROOT,
            workload_id=args.workload_id,
        )
    except (
        FileExistsError,
        FileNotFoundError,
        ValueError,
        json.JSONDecodeError,
    ) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    print(output_path)
    return 0 if ledger["summary"]["status"] == "pass" else 1


# ---------------------------------------------------------------------------
# run subcommand
# ---------------------------------------------------------------------------


def _add_run_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--product", required=True, help="Product identifier (doe, dawn, tint, ...)")
    parser.add_argument("--executor-id", required=True, help="Executor registry ID")
    parser.add_argument("--workloads", required=True, help="Workload contract JSON path")
    parser.add_argument("--workload-id", default="", help="Single workload ID (omit for all)")
    parser.add_argument("--iterations", type=int, default=10)
    parser.add_argument("--warmup", type=int, default=1)
    parser.add_argument("--command-repeat", type=int, default=0, help="Override per-workload commandRepeat (0=use workload default)")
    parser.add_argument("--ignore-first-ops", type=int, default=0)
    parser.add_argument("--timing-divisor", type=float, default=0.0, help="Override per-workload timingDivisor (0=use workload default)")
    parser.add_argument("--upload-buffer-usage", default="", help="Override per-workload uploadBufferUsage")
    parser.add_argument("--upload-submit-every", type=int, default=0, help="Override per-workload uploadSubmitEvery (0=use workload default)")
    parser.add_argument("--resource-probe", default="none", choices=["none", "rocm-smi"])
    parser.add_argument("--resource-sample-ms", type=int, default=100)
    parser.add_argument("--resource-sample-target-count", type=int, default=0)
    parser.add_argument("--comparability-mode", default="strict", choices=["strict", "warn", "off"])
    parser.add_argument("--require-timing-class", default="operation", choices=["any", "operation", "process-wall"])
    parser.add_argument("--benchmark-policy", default="", help="Benchmark methodology policy path")
    parser.add_argument("--cohort", default="all", help="Workload cohort filter")
    parser.add_argument("--benchmark-class", default="", help="Filter by benchmarkClass (comparable, directional)")
    parser.add_argument("--out", default="bench/out/runs", help="Output directory for run artifacts")


def _cmd_run(args: argparse.Namespace) -> int:
    from bench.native_compare_modules.artifact_benchmarking import run_product_bundle
    from bench.native_compare_modules.config_support import (
        load_benchmark_methodology_policy,
        load_workloads,
    )
    from bench.native_compare_modules.executor_registry import resolve_executor_command_template

    template = resolve_executor_command_template(args.executor_id)
    benchmark_policy = load_benchmark_methodology_policy(args.benchmark_policy)
    workloads_path = Path(args.workloads)
    workloads = load_workloads(
        workloads_path,
        workload_filter=args.workload_id,
        include_noncomparable=True,
        include_extended=True,
        workload_cohort=args.cohort,
    )
    if not workloads:
        print(f"error: no workloads matched", file=sys.stderr)
        return 1

    timestamp = _utc_timestamp()
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    written = run_product_bundle(
        product=args.product,
        display_name=args.product,
        executor_id=args.executor_id,
        template=template,
        workloads=workloads,
        iterations=args.iterations,
        warmup=args.warmup,
        workspace=out_dir,
        workload_contract_path=workloads_path,
        gpu_memory_probe=args.resource_probe,
        resource_sample_ms=args.resource_sample_ms,
        resource_sample_target_count=args.resource_sample_target_count,
        required_timing_class=args.require_timing_class,
        comparability_mode=args.comparability_mode,
        benchmark_policy=benchmark_policy,
        workload_cooldown_ms=0,
        emit_shell=False,
        timestamp=timestamp,
        command_repeat_override=args.command_repeat,
        ignore_first_ops_override=args.ignore_first_ops,
        timing_divisor_override=args.timing_divisor,
        upload_buffer_usage_override=args.upload_buffer_usage,
        upload_submit_every_override=args.upload_submit_every,
    )
    for artifact_path in written:
        print(f"  {artifact_path}")

    print(f"\n{len(written)} run artifact(s) written under {out_dir}/")
    return 0


# ---------------------------------------------------------------------------
# compare subcommand
# ---------------------------------------------------------------------------


def _add_compare_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("artifacts", nargs="*", help="Run artifact JSON paths")
    parser.add_argument(
        "--config",
        default="",
        help=(
            "Deprecated inline compare config path. Use "
            "`bench/cli.py run-config --config ... --side baseline|comparison` "
            "and compare the emitted receipts."
        ),
    )
    parser.add_argument("--catalog", default="config/promoted-compare-catalog.json", help="Promoted compare catalog path")
    parser.add_argument("--profile", default="", help="Exact promoted compare profile id")
    parser.add_argument("--backend", default="", help="Promoted backend id, e.g. apple-metal")
    parser.add_argument("--boundary", default="", choices=["backend_native", "direct_plan", "package_surface"], help="Execution boundary for promoted compare resolution")
    parser.add_argument("--surface", default="", choices=["backend", "plan", "package"], help="Promoted surface selector")
    parser.add_argument("--preset", default="", help="Promoted preset for backend surfaces")
    parser.add_argument("--workload", default="", help="Promoted workload alias")
    parser.add_argument("--runtime-host", default="", choices=["none", "node", "bun", "deno"], help="Promoted runtime host selector")
    parser.add_argument("--package-runtime", default="", choices=["node", "bun", "deno"], help="Promoted package runtime selector")
    parser.add_argument("--temperature", default="", choices=["default", "cold", "warm"], help="Promoted temperature selector")
    parser.add_argument("--mode", default="", choices=["default", "cold", "warm"], help="Temperature alias for promoted compare resolution")
    parser.add_argument("--list-promoted", action="store_true", help="List promoted compare profiles and exit")
    parser.add_argument("--dry-run", action="store_true", help="Print the resolved receipt-first run commands and exit")
    parser.add_argument(
        "--products",
        default="",
        help="Removed inline shortcut. Run each product separately with `bench/cli.py run`.",
    )
    parser.add_argument("--executor-ids", default="", help="Legacy inline-compare option; no longer executed.")
    parser.add_argument("--workloads", default="", help="Legacy inline-compare option; no longer executed.")
    parser.add_argument("--workload-id", default="", help="Single workload ID filter")
    parser.add_argument("--iterations", type=int, default=10)
    parser.add_argument("--warmup", type=int, default=1)
    parser.add_argument("--comparability", default="strict", choices=["strict", "warn", "off"])
    parser.add_argument("--require-timing-class", default="operation", choices=["any", "operation", "process-wall"])
    parser.add_argument("--resource-probe", default="none", choices=["none", "rocm-smi"])
    parser.add_argument("--resource-sample-ms", type=int, default=100)
    parser.add_argument("--resource-sample-target-count", type=int, default=0)
    parser.add_argument("--benchmark-policy", default="", help="Benchmark methodology policy path")
    parser.add_argument("--baseline-product", default="", help="Explicit baseline product id")
    parser.add_argument("--comparison-product", default="", help="Explicit comparison product id")
    parser.add_argument("--workspace", default="", help="Workspace path override for config-backed receipt expansion")
    parser.add_argument("--workload-filter", default="", help="Config-backed workload filter override")
    parser.add_argument("--emit-shell", action="store_true", help="Print commands instead of executing them in `run-config`")
    parser.add_argument("--no-timestamp-output", action="store_true", help="Disable timestamped config compare outputs")
    parser.add_argument("--include-noncomparable-workloads", action="store_true", help="Include non-comparable workloads in config-backed receipt expansion")
    parser.add_argument("--include-extended-workloads", action="store_true", help="Include extended workloads in config-backed receipt expansion")
    parser.add_argument("--workload-cohort", default="", help="Config-backed workload cohort filter")
    parser.add_argument("--baseline-provider-id", default="", help="Config-backed baseline provider id")
    parser.add_argument("--comparison-provider-id", default="", help="Config-backed comparison provider id")
    parser.add_argument("--baseline-name", default="", help="Config-backed baseline display name")
    parser.add_argument("--comparison-name", default="", help="Config-backed comparison display name")
    parser.add_argument("--baseline-executor-id", default="", help="Config-backed baseline executor id")
    parser.add_argument("--comparison-executor-id", default="", help="Config-backed comparison executor id")
    parser.add_argument("--comparison-view", default="", help="Config-backed comparison view")
    parser.add_argument("--provider-set", default="", help="Config-backed provider set")
    parser.add_argument("--out", default="bench/out/compare-report.json", help="Output report path")


def _add_claim_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("report", help="Compare report JSON path")
    parser.add_argument("--config", default="", help="Optional compare config for claim defaults")
    parser.add_argument("--mode", default="", choices=["", "local", "release"], help="Claim mode override")
    parser.add_argument("--min-timed-samples", type=int, default=0, help="Claim sample-floor override")
    parser.add_argument("--benchmark-policy", default="", help="Benchmark methodology policy path override")
    parser.add_argument("--out", default="", help="Output claim report path")


def _ordered_products(artifacts: list[dict[str, Any]]) -> list[str]:
    products: list[str] = []
    for artifact in artifacts:
        product = str(artifact.get("product", "")).strip()
        if product and product not in products:
            products.append(product)
    return products


def _print_receipt_first_commands(commands: list[list[str]], *, stream: Any) -> None:
    for command in commands:
        print(shlex.join(command), file=stream)


def _cmd_compare(
    args: argparse.Namespace,
    *,
    raw_compare_argv: list[str] | None = None,
) -> int:
    raw_compare_argv = list(raw_compare_argv or [])

    if args.config:
        print(
            "error: config-backed inline compare has been removed; "
            "run each side independently and compare receipts post-hoc.",
            file=sys.stderr,
        )
        print("\nRun each side explicitly:", file=sys.stderr)
        print(
            f"  {sys.executable} bench/cli.py run-config --config {args.config} --side baseline",
            file=sys.stderr,
        )
        print(
            f"  {sys.executable} bench/cli.py run-config --config {args.config} --side comparison",
            file=sys.stderr,
        )
        print(
            "\nThen compare the emitted .run.json receipts with:\n"
            f"  {sys.executable} bench/cli.py compare <baseline.run.json> <comparison.run.json>",
            file=sys.stderr,
        )
        return 1

    if (
        args.list_promoted
        or args.profile
        or args.backend
        or args.surface
        or args.boundary
        or args.preset
        or args.workload
    ):
        from bench.native_compare_modules import promoted_compare as promoted_compare_mod

        catalog_path = Path(args.catalog)
        entries = promoted_compare_mod.load_catalog(catalog_path)
        if args.list_promoted:
            filtered = promoted_compare_mod.filter_entries(
                entries,
                backend=args.backend,
                boundary=args.boundary,
                runtime_host=args.runtime_host,
                temperature=args.temperature,
                surface=args.surface,
                preset=args.preset,
                workload=args.workload,
                mode=args.mode,
                package_runtime=args.package_runtime,
            )
            for entry in sorted(
                filtered,
                key=lambda item: (
                    item.backend,
                    item.boundary,
                    item.runtime_host,
                    item.preset or item.workload,
                    item.temperature,
                    item.id,
                ),
            ):
                print(promoted_compare_mod.format_entry(entry))
            return 0

        entry = promoted_compare_mod.resolve_entry(
            entries,
            profile_id=args.profile,
            backend=args.backend,
            boundary=args.boundary,
            runtime_host=args.runtime_host,
            temperature=args.temperature,
            surface=args.surface,
            preset=args.preset,
            workload=args.workload,
            mode=args.mode,
            package_runtime=args.package_runtime,
        )
        argv_out = promoted_compare_mod.build_run_config_argvs(
            entry,
            catalog_path=catalog_path,
            passthrough=promoted_compare_mod.filter_selection_passthrough(
                raw_compare_argv
            ),
        )
        if args.dry_run:
            _print_receipt_first_commands(argv_out, stream=sys.stdout)
            print("# then compare the emitted .run.json receipts with `python3 bench/cli.py compare ...`", file=sys.stdout)
            return 0
        print(
            "error: promoted compare execution is receipt-first only now; "
            "run each side independently with these commands:",
            file=sys.stderr,
        )
        _print_receipt_first_commands(argv_out, stream=sys.stderr)
        print(
            "Then compare the emitted .run.json receipts with "
            f"`{sys.executable} bench/cli.py compare ...`",
            file=sys.stderr,
        )
        return 1

    from bench.native_compare_modules.compare_from_artifacts import (
        build_compare_report,
        compare_workload_from_artifacts,
        group_run_artifacts_by_workload,
        write_compare_report,
    )
    from bench.native_compare_modules.config_support import load_benchmark_methodology_policy
    from bench.native_compare_modules.run_artifact import load_run_artifact

    benchmark_policy = load_benchmark_methodology_policy(args.benchmark_policy)
    artifact_paths = list(args.artifacts)

    if args.products and not artifact_paths:
        print(
            "error: inline run+compare has been removed; run each product "
            "independently with `bench/cli.py run`, then compare the emitted "
            "receipts post-hoc.",
            file=sys.stderr,
        )
        return 1

    if len(artifact_paths) < 2:
        print("error: compare requires at least 2 run artifact paths", file=sys.stderr)
        return 1

    artifacts: list[dict[str, Any]] = []
    for path in artifact_paths:
        artifact = load_run_artifact(path)
        artifact["_receiptPath"] = path
        artifacts.append(artifact)
    products_seen = _ordered_products(artifacts)
    if len(products_seen) != 2:
        print(
            f"error: compare currently supports exactly 2 products, found {products_seen}",
            file=sys.stderr,
        )
        return 1
    baseline_product = args.baseline_product or products_seen[0]
    comparison_product = args.comparison_product or products_seen[1]
    if baseline_product == comparison_product:
        print(
            "error: baseline and comparison products must differ",
            file=sys.stderr,
        )
        return 1
    baseline_artifact = next(
        (
            artifact
            for artifact in artifacts
            if artifact["product"] == baseline_product
        ),
        None,
    )
    comparison_artifact = next(
        (
            artifact
            for artifact in artifacts
            if artifact["product"] == comparison_product
        ),
        None,
    )
    if baseline_artifact is None or comparison_artifact is None:
        print(
            "error: selected baseline/comparison products are missing from the artifact set",
            file=sys.stderr,
        )
        return 1
    out_path = Path(args.out)
    grouped = group_run_artifacts_by_workload(artifacts)
    workload_entries: list[dict[str, Any]] = []
    for workload_id in sorted(grouped):
        workload_group = grouped[workload_id]
        if baseline_product not in workload_group or comparison_product not in workload_group:
            print(
                "error: compare currently requires both selected products for each workload; "
                f"missing side for {workload_id}",
                file=sys.stderr,
            )
            return 1
        workload_entries.append(
            compare_workload_from_artifacts(
                baseline=workload_group[baseline_product],
                comparison=workload_group[comparison_product],
                comparability_mode=args.comparability,
                required_timing_class=args.require_timing_class,
                resource_probe=args.resource_probe,
                resource_sample_target_count=args.resource_sample_target_count,
                primary_metric="measured_ms",
            )
        )
    report = build_compare_report(
        workload_entries=workload_entries,
        baseline_artifact=baseline_artifact,
        comparison_artifact=comparison_artifact,
        comparability_mode=args.comparability,
        required_timing_class=args.require_timing_class,
        primary_metric="measured_ms",
        out_path=str(out_path),
        run_artifact_paths=artifact_paths,
        comparability_min_timed_samples=benchmark_policy.comparability_min_timed_samples,
        smoke_comparability_min_timed_samples=benchmark_policy.smoke_comparability_min_timed_samples,
        benchmark_policy_path=benchmark_policy.source_path,
    )
    write_compare_report(report, out_path)
    print(f"\nCompare report: {out_path}")
    return 0


def _cmd_run_config(raw_run_config_argv: list[str] | None = None) -> int:
    from bench.native_compare_modules import run_receipts_from_config as run_receipts_from_config_mod

    return run_receipts_from_config_mod.main(raw_run_config_argv)


def _cmd_claim(args: argparse.Namespace) -> int:
    from bench.native_compare_modules import claim_from_config as claim_from_config_mod

    argv = [args.report]
    if args.config:
        argv.extend(["--config", args.config])
    if args.mode:
        argv.extend(["--mode", args.mode])
    if args.min_timed_samples > 0:
        argv.extend(["--min-timed-samples", str(args.min_timed_samples)])
    if args.benchmark_policy:
        argv.extend(["--benchmark-policy", args.benchmark_policy])
    if args.out:
        argv.extend(["--out", args.out])
    return claim_from_config_mod.main(argv)


# ---------------------------------------------------------------------------
# list subcommand
# ---------------------------------------------------------------------------


def _add_list_args(parser: argparse.ArgumentParser) -> None:
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--products", action="store_true", help="List known products from taxonomy")
    group.add_argument("--executors", action="store_true", help="List executor registry entries")
    group.add_argument("--workloads", default="", metavar="FILE", help="List workloads from contract JSON")
    group.add_argument("--surfaces", action="store_true", help="List known surfaces from taxonomy")


def _cmd_list(args: argparse.Namespace) -> int:
    if args.products or args.surfaces:
        taxonomy_path = Path("config/compare-taxonomy.json")
        if not taxonomy_path.exists():
            print(f"error: taxonomy not found at {taxonomy_path}", file=sys.stderr)
            return 1
        taxonomy = json.loads(taxonomy_path.read_text(encoding="utf-8"))
        if args.products:
            print("Products:")
            for p in taxonomy["axes"]["products"]:
                print(f"  {p}")
        else:
            print("Surfaces:")
            for s in taxonomy["axes"]["surfaces"]:
                print(f"  {s}")
        return 0

    if args.executors:
        from bench.native_compare_modules.executor_registry import _REGISTRY
        print("Executors:")
        for eid, spec in sorted(_REGISTRY.items()):
            print(f"  {eid:40s}  boundary={spec.execution_boundary}")
        return 0

    if args.workloads:
        wl_path = Path(args.workloads)
        if not wl_path.exists():
            print(f"error: workload file not found: {wl_path}", file=sys.stderr)
            return 1
        data = json.loads(wl_path.read_text(encoding="utf-8"))
        workloads = data.get("workloads", [])
        print(f"Workloads ({len(workloads)}) from {wl_path}:")
        for w in workloads:
            wid = w.get("id", "?")
            domain = w.get("domain", "?")
            cls = w.get("benchmarkClass", "?")
            comparable = w.get("comparable", False)
            print(f"  {wid:55s}  domain={domain:15s}  class={cls:14s}  comparable={comparable}")
        return 0

    return 0


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------


def main() -> int:
    argv = sys.argv[1:]
    parser = argparse.ArgumentParser(
        prog="doe-bench",
        description=(
            "Doe workload and benchmark CLI: execute correctness workloads, "
            "run products independently, compare receipts, and evaluate claims."
        ),
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    workload_parser = subparsers.add_parser(
        "workload",
        help="Run correctness-bearing workloads and emit one ledger",
    )
    _add_workload_args(workload_parser)

    run_parser = subparsers.add_parser("run", help="Run one product on workload(s)")
    _add_run_args(run_parser)

    subparsers.add_parser(
        "run-config",
        help="Expand a compare config into one-side run receipts (`--side baseline|comparison`)",
    )

    compare_parser = subparsers.add_parser(
        "compare",
        help="Compare existing run artifacts; config/profile shortcuts are now receipt-first resolvers only",
    )
    _add_compare_args(compare_parser)

    claim_parser = subparsers.add_parser("claim", help="Evaluate claim policy from an existing compare report")
    _add_claim_args(claim_parser)

    list_parser = subparsers.add_parser("list", help="List products, executors, workloads, or surfaces")
    _add_list_args(list_parser)

    if argv and argv[0] == "compare":
        compare_parser = argparse.ArgumentParser(
            prog="doe-bench compare",
            description="Compare run artifacts or resolve receipt-first commands from config/promoted profiles.",
        )
        _add_compare_args(compare_parser)
        compare_args, _ = compare_parser.parse_known_args(argv[1:])
        return _cmd_compare(compare_args, raw_compare_argv=argv[1:])

    if argv and argv[0] == "run-config":
        return _cmd_run_config(raw_run_config_argv=argv[1:])

    args = parser.parse_args(argv)

    if args.command == "run":
        return _cmd_run(args)
    if args.command == "workload":
        return _cmd_workload(args)
    if args.command == "run-config":
        return _cmd_run_config([])
    if args.command == "compare":
        return _cmd_compare(args)
    if args.command == "claim":
        return _cmd_claim(args)
    if args.command == "list":
        return _cmd_list(args)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
