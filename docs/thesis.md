# Doe thesis

## Product objective

Doe should become the fastest, most reliable WebGPU compute runtime for Node
and Bun on a deliberately narrow supported surface.

The defensible claim is bounded:

> Doe is faster and more reliable than the declared baseline for these named
> workloads, runtime versions, operating systems, adapters, and drivers.

Doe expands only after real applications depend on that passing surface.

## Why developers adopt it

The admission order is:

1. correct output;
2. operational reliability;
3. compatibility with real applications;
4. material end-to-end speed;
5. frictionless installation;
6. receipts, replay, governance, and support.

Receipts are essential evidence and an enterprise retention advantage. They
are not compensation for an incompatible or slower runtime.

## Technical thesis

Doe preserves one program identity across source, intermediate
representations, backend binaries, command graphs, execution results, and
receipts. That identity makes correctness and performance claims auditable
across Metal, Vulkan, D3D12, and later execution targets.

The implementation principles are:

- source-preserving lowering;
- explicit provider and backend selection;
- typed unsupported behavior;
- independent output oracles;
- deterministic schemas and artifact hashes;
- no hidden fallback in promoted lanes;
- user-visible operation timing rather than isolated internal phases;
- machine-owned support and claim state.

## Expansion lanes

Two longer-range paths reuse the same contracts:

- Chromium-family WebGPU integration beneath `navigator.gpu`;
- Doppler Program Bundle to TSIR, HostPlan, CSL, simulator, and Cerebras
  hardware execution.

Neither lane inherits promotion from Node/Bun evidence. Each must pass its own
compatibility, correctness, reliability, installation, and performance gates.

## Success condition

A project can replace its existing Node/Bun provider with Doe, receive the same
correct result, observe fewer operational failures, and obtain a material
end-to-end performance win. The receipt proves exactly what ran and why the
result is eligible.

## Non-goals

- claiming universal WebGPU compatibility from internal command coverage;
- claiming broad speed from one workload or machine;
- using governance language to mask runtime gaps;
- treating browser wrappers as Chromium runtime replacement;
- treating simulator evidence as hardware evidence.

See [`architecture.md`](architecture.md), [`process.md`](process.md), and
[`node-bun-developer-wedge.md`](node-bun-developer-wedge.md) for implementation
boundaries.
