# Doe licensing and third-party usage

## Doe (this project)

Doe is an independent WebGPU implementation. No Dawn or wgpu source code is copied
into Doe runtime paths. Doe calls native graphics APIs (Metal, Vulkan, D3D12) directly.

## Dawn (BSD 3-Clause)

Dawn is vendored at `bench/vendor/dawn/` as a benchmark oracle and comparison baseline.
The BSD 3-Clause license (`bench/vendor/dawn/LICENSE`) governs all Dawn source in this tree.

### What BSD 3-Clause permits

1. **Mining Gerrit and public issue metadata**
   (`pipeline/upstream_intelligence/`; archived predecessor
   `dawn-research/`): Public commit and issue metadata are used as factual
   evidence. Review packets retain source URLs and do not copy upstream code
   into Doe runtime paths.

2. **Vendoring Dawn as benchmark oracle** (`bench/vendor/dawn/`): Permitted. Attribution
   is satisfied by the vendored LICENSE file retained in the source tree.

3. **Building Doe as a competing implementation**: BSD 3-Clause places no restriction
   on competing implementations, studying public source code, or reimplementing APIs.
   There is no copyleft (GPL), no patent retaliation (Apache 2.0), and no non-compete
   clause.

4. **Calling Dawn via dawn_delegate/dawn_oracle**: Permitted as dynamic linking against
   a BSD-licensed library.

5. **Mining Dawn source for driver quirk patterns** (`pipeline/agent/mine_upstream_quirks.py`):
   Extracting toggle names, vendor guard patterns, and workaround descriptions from
   BSD-licensed source is permitted. The miner reads Dawn source to identify behavioral
   patterns; no Dawn code is copied into Doe runtime paths.

### BSD 3-Clause obligations

1. **Retain copyright notice**: Done. `bench/vendor/dawn/LICENSE` is present and
   unmodified in the source tree.

2. **Reproduce notice in binary distributions**: If shipping a binary that includes
   Dawn code (e.g. the dawn_delegate benchmark binary), the BSD notice must appear
   in accompanying documentation.

3. **No endorsement**: Do not use "Dawn", "Tint", or "Google" names to endorse or
   promote Doe.

### What to watch

If any verbatim Dawn source code were copied into Doe runtime paths (`runtime/zig/src/`),
that code would carry the BSD 3-Clause attribution requirement. As of this writing,
no Dawn source has been copied -- Doe calls native APIs directly, and the
dawn_delegate paths link against Dawn as a separate binary.

## wgpu

wgpu is referenced as a baseline comparison target. No wgpu source is vendored or
linked. If wgpu source is vendored in the future, its license (MIT/Apache 2.0) must
be retained and the same attribution discipline applied.

## ONNX Runtime plugin EP headers (MIT)

Doe vendors ONNX Runtime public plugin-EP headers under:

- `runtime/bridge/onnxruntime-ep/vendor/onnxruntime/include/onnxruntime_c_api.h`
- `runtime/bridge/onnxruntime-ep/vendor/onnxruntime/include/onnxruntime_ep_c_api.h`

The upstream ONNX Runtime license is retained at:

- `runtime/bridge/onnxruntime-ep/vendor/onnxruntime/LICENSE`

These headers are used only for the repo-only ONNX Runtime plugin EP bridge
surface. They do not make ONNX Runtime a Doe runtime dependency, and they do
not change the public `doe-gpu` package contract.

## Cerebras SDK

Doe may reference public Cerebras SDK API names and documentation when
describing CSL compilation and runtime orchestration. Doe-owned source,
schemas, gates, generated CSL source, and redacted JSON receipts may be tracked
when they do not copy SDK-distributed source or bundle SDK artifacts.

Do not track Cerebras SDK packages, EULA PDFs, `csl-extras` contents, SDK
container images, compiled ELF products, raw simulator logs, core dumps,
simfabric traces, SDK GUI dumps, disassembly, or hardware endpoint secrets.
Those files are local evidence only unless the applicable Cerebras license or
written permission explicitly allows redistribution.

The blocking guard is:

`python3 bench/gates/cerebras_artifact_gate.py`
