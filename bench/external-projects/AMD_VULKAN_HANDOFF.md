# AMD Vulkan evidence handoff

This runbook transfers the physical-Vulkan evidence work without transferring
unreviewed claims. Start from a clean Doe checkout containing this file. Record
the exact Doe commit used; do not substitute a branch name for that identity in
the returned artifacts.

The AMD host has two jobs:

1. rerun the pinned cpp-ml MNIST provider-swap harness on an accessible physical
   AMD Vulkan adapter; and
2. run the canonical AMD Vulkan smoke lane to capture representative native
   compute output for the recomposition evidence boundary.

Do not edit runtime, shader, command-registry, or provider code as part of this
handoff. A failure is a diagnostic result to return with its receipts. It is
not permission to patch the failing boundary or promote a public claim.

## Host admission

Required software and access:

- Linux x86-64 with an AMD Vulkan device and production AMD/RADV driver;
- Node.js 22;
- Python 3;
- `git`, `npm`, `vulkaninfo`, and `sha256sum`;
- read and write access to at least one `/dev/dri/renderD*` node; and
- network access to the schema-pinned Zig archive declared in
  `config/toolchains.json`.

From the Doe checkout, set explicit paths and a stable run identifier:

```bash
export DOE_ROOT=/absolute/path/to/doe
export DOE_RUN_ID=amd-vulkan-cpp-ml-01
export DOE_CPP_ML_UPSTREAM="$DOE_ROOT/bench/out/external-projects/electronicarts-cpp-ml-intro/upstream"
export DOE_AMD_VULKAN_ICD=/absolute/path/to/the/amd-only-icd.json
export VK_ICD_FILENAMES="$DOE_AMD_VULKAN_ICD"
cd "$DOE_ROOT"
test -r "$DOE_AMD_VULKAN_ICD"
sha256sum "$DOE_AMD_VULKAN_ICD"
git status --short
git rev-parse HEAD
node --version
python3 bench/tools/bootstrap_zig.py
./.tooling/zig-0.15.2/zig version
vulkaninfo --summary
ls -l /dev/dri/renderD*
```

Use an ICD manifest that exposes only the intended AMD driver; do not include a
software ICD in `VK_ICD_FILENAMES`. Stop admission if the Doe worktree is dirty,
the device is CPU/llvmpipe, `vulkaninfo` does not identify the AMD adapter and
driver, or no render node is both readable and writable. Preserve the command
output as diagnostic host evidence instead of running comparisons.

Create the run directory and capture host/backend identity without overwriting
the checked-in recomposition report:

```bash
mkdir -p "$DOE_ROOT/bench/out/external-projects/electronicarts-cpp-ml-intro/$DOE_RUN_ID"
vulkaninfo --summary > "$DOE_ROOT/bench/out/external-projects/electronicarts-cpp-ml-intro/$DOE_RUN_ID/vulkaninfo-summary.txt" 2>&1
python3 runtime/zig/tools/capture_backend_evidence.py \
  --output "bench/out/external-projects/electronicarts-cpp-ml-intro/$DOE_RUN_ID/backend-evidence.json"
```

The generated `backend-evidence.json` must report
`backends.vulkan.physicalGpuEligible=true`. That proves host eligibility, not a
representative compute output.

The canonical end-to-end command is:

```bash
python3 bench/cli.py external reproduce \
  --actor electronicarts-cpp-ml-intro \
  --harness mnist-webgpu-demo \
  --run-id "$DOE_RUN_ID"
```

It executes the schema-backed bootstrap, tool-version capture, hardware probe,
pinned checkout, dependency installation, Doe build, policy gates, workload,
and evidence hashing. It writes `preparation.json`, `reproduction.json`, and
complete process logs under the run directory. The manual commands below are
the inspectable boundaries behind that orchestration and remain useful for
isolating a failure.

## Build and pin the external workload

Build the exact runtime consumed by `packages/doe-gpu`:

```bash
cd "$DOE_ROOT/runtime/zig"
../../.tooling/zig-0.15.2/zig build
../../.tooling/zig-0.15.2/zig build test-wgsl
cd "$DOE_ROOT"
```

Create or verify the ignored upstream clone at the manifest-pinned commit:

```bash
git clone https://github.com/electronicarts/cpp-ml-intro.git "$DOE_CPP_ML_UPSTREAM"
git -C "$DOE_CPP_ML_UPSTREAM" checkout --detach c46a47b4fcee5ec48dbda7321210b1287b262b06
test "$(git -C "$DOE_CPP_ML_UPSTREAM" rev-parse HEAD)" = c46a47b4fcee5ec48dbda7321210b1287b262b06
npm install --prefix bench --no-save --no-package-lock webgpu@0.4.0 pngjs@7.0.0
python3 bench/gates/schema_gate.py
python3 bench/gates/ecosystem_registry_gate.py
```

If the clone already exists, omit `git clone`; the detached-checkout and exact
commit assertion remain mandatory.

## Run cpp-ml

Run the reviewed diagnostic boundary first:

```bash
node bench/external-projects/electronicarts-cpp-ml-intro/run-suite.mjs \
  --upstream "$DOE_CPP_ML_UPSTREAM" \
  --run-id "$DOE_RUN_ID" \
  --clean-process-runs 3 \
  --require-all-pass
```

`--require-all-pass` must remain enabled. A nonzero exit is expected while the
known Doe Presentation-WGSL failure remains; the runner still writes:

- `bench/out/external-projects/electronicarts-cpp-ml-intro/<run-id>/raw-suite.json`
- `bench/out/external-projects/electronicarts-cpp-ml-intro/<run-id>/receipt-summary.json`

Accept the physical run only when both provider probes have matching provider
identity and `hardwareEligible=true`, no software fallback is present, and the
paired `vulkaninfo` and backend-evidence artifacts supply a complete AMD
adapter/driver identity, and the recorded `VK_ICD_FILENAMES` contains only the
hashed AMD ICD. Correctness requires both providers to complete all ten inputs
in every clean process, match the independent CPU argmax, emit finite outputs,
stay within the oracle error bound, and report no native compiler/runtime
diagnostic.

If that boundary passes, repeat with `--clean-process-runs 30` under a new run
ID. This satisfies only the clean-process floor. It does not supply the warm,
concurrency, teardown, stress, memory-growth, replay, production-installation,
or receipt-overhead evidence required by
`config/external-project-promotion-policy.json`.

## Run the canonical native Vulkan smoke lane

The recomposition capability script does not execute a representative kernel.
Use the same native smoke command as the self-hosted AMD workflow:

```bash
cd "$DOE_ROOT"
python3 bench/runners/run_release_pipeline.py \
  --config bench/native-compare/compare.config.amd.vulkan.smoke.gpu.json \
  --report bench/out/dawn-vs-doe.amd.vulkan.smoke.gpu.compute.json \
  --strict-amd-vulkan \
  --local-vulkan-lane vulkan_doe_comparable \
  --verify-smoke-report bench/out/dawn-vs-doe.amd.vulkan.smoke.gpu.compute.json \
  --verify-smoke-require-comparable
```

Return the report, its run workspace, trace/receipt artifacts, and the strict
preflight output. Do not check the recomposition physical-backend item merely
because preflight passed: the reviewed evidence must bind physical adapter and
driver identity to successful representative output. Metal and D3D12 remain
separate host obligations.

## Return bundle and review boundary

Hash every result before transfer:

```bash
sha256sum \
  "bench/out/external-projects/electronicarts-cpp-ml-intro/$DOE_RUN_ID/raw-suite.json" \
  "bench/out/external-projects/electronicarts-cpp-ml-intro/$DOE_RUN_ID/receipt-summary.json" \
  "bench/out/external-projects/electronicarts-cpp-ml-intro/$DOE_RUN_ID/backend-evidence.json" \
  "bench/out/external-projects/electronicarts-cpp-ml-intro/$DOE_RUN_ID/vulkaninfo-summary.txt"
```

The receiving reviewer needs the exact Doe commit, clean-worktree assertion,
tool versions, `vulkaninfo` summary, render-node permissions, raw cpp-ml suite,
receipt summary, backend capability output, AMD ICD path and hash, native smoke
report/workspace, process exit codes, and SHA-256 values. Keep generated evidence under
`bench/out/`; promote only a reviewed schema-backed summary under
`reports/ecosystem/`. Do not add a claim-index entry unless all correctness,
equivalence, reliability, physical-hardware, and claim gates pass.
